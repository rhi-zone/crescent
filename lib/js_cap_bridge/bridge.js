// lib/js_cap_bridge/bridge.js
//
// Runtime capability bridge between a pack realm (sandboxed iframe or
// future ShadowRealm) and the host stub page. ESM module. Pure protocol
// implementation: the postMessage transport and the message-handler
// registration are injected by the caller, so the same code paths run
// in `node:vm`-style test contexts (paired bridges wired via callbacks)
// and in real iframes (wired to `window.postMessage` and `message`
// events).
//
// Protocol summary (the message envelope is the spec -- keep it stable):
//
//   Realm -> Host (call):
//     { id: number, kind: "call", cap: string, args: any[] }
//
//   Realm -> Host (cancel):
//     { id: number, kind: "cancel" }
//     Issued when an AbortSignal passed as a cap arg fires. The host
//     aborts the controller it allocated for that call's correlation id;
//     the impl's underlying operation (fetch, setTimeout wrapper, ...)
//     responds to the abort and produces an AbortError, which is sent
//     back as a normal `error` envelope. No response is sent for the
//     cancel message itself.
//
//   Host -> Realm (result):
//     { id: number, kind: "result", value: any }
//
//   Host -> Realm (error):
//     { id: number, kind: "error", error: { type: string, message: string } }
//
//   `type` values:
//     "denied"    -- cap not granted to this pack
//     "missing"   -- cap granted but no impl registered
//     "throw"     -- cap impl threw / returned a rejected promise
//     "malformed" -- envelope failed validation (host responds when id
//                    is recoverable; otherwise silently dropped)
//
// AbortSignal wire marker (see docs/platform_isolation.md §4
// "Cancellation via AbortSignal"):
//
//   { __cap_signal: true, ref: number }
//
// The realm bridge replaces top-level AbortSignal instances in the call
// args with this marker before postMessage. The host bridge scans
// incoming args, allocates a fresh AbortController per marker, and
// substitutes `controller.signal` in the args delivered to the impl.
// Nested signals (inside arrays/objects) are NOT detected in v1 --
// signals must be passed as top-level cap arguments.
//
// Design notes (from docs/platform_isolation.md §4 + adversarial review):
//
// - No implicit coercion of pack-supplied args. The host bridge treats
//   args as opaque structured-clone values and never does `String(arg)`,
//   arithmetic, or interpolation against them before invoking the cap
//   impl. The impl is responsible for validating shape against its
//   declared types.
//
// - Foreign thenable hazard. Cap impls may return a value or a Promise;
//   the host bridge wraps the invocation in `Promise.resolve().then(() =>
//   capImpls.get(cap)(...args))` rather than `await`-ing the impl result
//   directly. Across a real postMessage boundary structured-clone would
//   strip functions anyway, but in test contexts (and to be defensive
//   inside the same realm if the bridge is ever used colocated) we never
//   `Promise.resolve(externalValue)` because that triggers a
//   `.then` lookup on the value.
//
// - Realm-side cap shells are non-constructable. Each `caps[name]` is
//   produced via concise-method syntax (`{ async [name](...) {} }[name]`)
//   so `new caps.foo(...)` throws TypeError. This matches the
//   `lib/js_realm_sandbox/sandbox.js` non-constructable-wrapper rule;
//   the shells are designed to be installed onto `globalThis.__cap__` by
//   the sandbox bootstrap.
//
// - Id reuse / unknown id / malformed messages are silently dropped on
//   the realm side. The host side responds with a `malformed` error when
//   the id is recoverable so the realm's pending promise resolves
//   instead of leaking; if even the id is unrecoverable the host drops.
//
// See docs/platform_isolation.md §4 "Capability bridge protocol".

// ---------------------------------------------------------------------
// Envelope validation helpers.
// ---------------------------------------------------------------------

/**
 * @param {unknown} msg
 * @returns {msg is { id: number, kind: "call", cap: string, args: unknown[] }}
 */
function isCallEnvelope(msg) {
  if (msg === null || typeof msg !== "object") return false;
  const m = /** @type {Record<string, unknown>} */ (msg);
  if (typeof m.id !== "number") return false;
  if (m.kind !== "call") return false;
  if (typeof m.cap !== "string") return false;
  if (!Array.isArray(m.args)) return false;
  return true;
}

/**
 * @param {unknown} msg
 * @returns {msg is { id: number, kind: "cancel" }}
 */
function isCancelEnvelope(msg) {
  if (msg === null || typeof msg !== "object") return false;
  const m = /** @type {Record<string, unknown>} */ (msg);
  if (typeof m.id !== "number") return false;
  if (m.kind !== "cancel") return false;
  return true;
}

/**
 * Detect AbortSignal instances across realms. `instanceof AbortSignal`
 * works in the same realm; the structural Object.prototype.toString tag
 * matches across realms (the @@toStringTag for AbortSignal is the
 * string "AbortSignal").
 *
 * @param {unknown} v
 * @returns {boolean}
 */
function isAbortSignal(v) {
  if (v === null || typeof v !== "object") return false;
  if (typeof AbortSignal !== "undefined" && v instanceof AbortSignal) return true;
  return Object.prototype.toString.call(v) === "[object AbortSignal]";
}

/**
 * Detect the realm-side cap-signal wire marker.
 *
 * @param {unknown} v
 * @returns {v is { __cap_signal: true, ref: number }}
 */
function isCapSignalMarker(v) {
  if (v === null || typeof v !== "object") return false;
  const o = /** @type {Record<string, unknown>} */ (v);
  if (o.__cap_signal !== true) return false;
  if (typeof o.ref !== "number") return false;
  return true;
}

/**
 * @param {unknown} msg
 * @returns {msg is { id: number, kind: "result", value: unknown }
 *                 | { id: number, kind: "error", error: { type: string, message: string } }}
 */
function isResponseEnvelope(msg) {
  if (msg === null || typeof msg !== "object") return false;
  const m = /** @type {Record<string, unknown>} */ (msg);
  if (typeof m.id !== "number") return false;
  if (m.kind === "result") return true;
  if (m.kind === "error") {
    const e = /** @type {Record<string, unknown>} */ (m.error);
    if (e === null || typeof e !== "object") return false;
    if (typeof e.type !== "string") return false;
    if (typeof e.message !== "string") return false;
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------
// Realm-side bridge.
// ---------------------------------------------------------------------

/**
 * Build the realm-side cap bridge.
 *
 * @param {{
 *   capNames: string[],
 *   postMessage: (msg: unknown) => void,
 *   registerMessageHandler?: (handler: (msg: unknown) => void) => void,
 * }} opts
 *
 * @returns {{
 *   caps: { [name: string]: (...args: unknown[]) => Promise<unknown> },
 *   dispatch: (msg: unknown) => void,
 * }}
 *
 * Each `caps[name]` is an async function (concise-method syntax, so no
 * `[[Construct]]` -- `new caps.foo()` throws). Calling it:
 *   1. Allocates a fresh per-session id (counter, never reused).
 *   2. Stores `{resolve, reject}` in a pending-correlations map.
 *   3. Invokes `postMessage({ id, kind: "call", cap: name, args })`.
 *   4. Returns the promise.
 *
 * `dispatch(msg)` is called when a host-bound response arrives. On
 * malformed input, on unknown id, or on second-response-for-same-id,
 * the call is silently dropped (no console noise -- the realm should
 * not be observable from the message channel beyond fulfilling pending
 * promises).
 */
export function createRealmBridge(opts) {
  if (!opts || typeof opts !== "object") {
    throw new TypeError("createRealmBridge: opts is required");
  }
  if (!Array.isArray(opts.capNames)) {
    throw new TypeError("createRealmBridge: opts.capNames must be an array");
  }
  if (typeof opts.postMessage !== "function") {
    throw new TypeError("createRealmBridge: opts.postMessage must be a function");
  }

  const postMessage = opts.postMessage;
  /** @type {Map<number, { resolve: (v: unknown) => void, reject: (e: unknown) => void, signalRefs: number[] }>} */
  const pending = new Map();
  /** @type {Map<number, { signal: AbortSignal, onAbort: () => void }>} */
  const signals = new Map();
  let nextId = 1;
  let nextSignalRef = 1;

  /** @param {number} callId */
  function releaseSignals(callId) {
    const entry = pending.get(callId);
    if (!entry) return;
    for (let i = 0; i < entry.signalRefs.length; i++) {
      const ref = entry.signalRefs[i];
      const s = signals.get(ref);
      if (s) {
        try { s.signal.removeEventListener("abort", s.onAbort); }
        catch (_e) { /* removeEventListener never throws in practice */ }
        signals.delete(ref);
      }
    }
  }

  /** @param {unknown} msg */
  function dispatch(msg) {
    if (!isResponseEnvelope(msg)) return; // silently drop
    const entry = pending.get(msg.id);
    if (!entry) return; // unknown id, silently drop
    releaseSignals(msg.id);
    pending.delete(msg.id); // first response wins; subsequent dropped
    if (msg.kind === "result") {
      entry.resolve(msg.value);
    } else {
      // msg.kind === "error"
      const err = new Error(msg.error.message);
      // Annotate with the protocol-level type so callers can switch on it.
      /** @type {Error & { type?: string }} */ (err).type = msg.error.type;
      entry.reject(err);
    }
  }

  /** @type {{ [name: string]: (...args: unknown[]) => Promise<unknown> }} */
  const caps = { __proto__: null };
  for (let i = 0; i < opts.capNames.length; i++) {
    const name = opts.capNames[i];
    if (typeof name !== "string") {
      throw new TypeError("createRealmBridge: opts.capNames entries must be strings");
    }
    // Non-constructable async shell via concise-method syntax. Mirrors
    // lib/js_realm_sandbox/sandbox.js makeCapShell. `new caps[name]()`
    // throws TypeError because concise methods have no [[Construct]].
    const shell = {
      async [name](/** @type {unknown[]} */ ...args) {
        const id = nextId++;
        // Walk top-level args; replace AbortSignal instances with
        // { __cap_signal: true, ref } markers and register listeners
        // that emit cancel messages keyed to the call's correlation id.
        const wireArgs = new Array(args.length);
        /** @type {number[]} */
        const signalRefs = [];
        let alreadyAborted = false;
        for (let j = 0; j < args.length; j++) {
          const v = args[j];
          if (isAbortSignal(v)) {
            const sig = /** @type {AbortSignal} */ (v);
            const ref = nextSignalRef++;
            signalRefs.push(ref);
            wireArgs[j] = { __cap_signal: true, ref };
            if (sig.aborted) {
              alreadyAborted = true;
            } else {
              const onAbort = () => {
                // The listener might fire after the call already settled
                // (response races abort). pending.delete is idempotent.
                try { postMessage({ id, kind: "cancel" }); }
                catch (_e) { /* transport down -- response path will reject */ }
              };
              sig.addEventListener("abort", onAbort, { once: true });
              signals.set(ref, { signal: sig, onAbort });
            }
          } else {
            wireArgs[j] = v;
          }
        }
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, signalRefs });
          try {
            postMessage({ id, kind: "call", cap: name, args: wireArgs });
          } catch (err) {
            // postMessage threw synchronously -- reject and clean up.
            releaseSignals(id);
            pending.delete(id);
            reject(err);
            return;
          }
          if (alreadyAborted) {
            // Signal was aborted before the call was issued: send the
            // cancel immediately so the host can abort the controller
            // it just allocated.
            try { postMessage({ id, kind: "cancel" }); }
            catch (_e) { /* swallow; the abort itself will fail downstream */ }
          }
        });
      },
    }[name];
    caps[name] = shell;
  }

  if (typeof opts.registerMessageHandler === "function") {
    opts.registerMessageHandler(dispatch);
  }

  return { caps, dispatch };
}

// ---------------------------------------------------------------------
// Host-side bridge.
// ---------------------------------------------------------------------

/**
 * Build the host-side cap bridge.
 *
 * @param {{
 *   grantedCaps: Set<string>,
 *   capImpls: Map<string, (...args: unknown[]) => unknown>,
 *   audit: (entry: {
 *     cap: string,
 *     args: unknown[],
 *     ok?: boolean,
 *     error?: unknown,
 *     denied?: string,
 *   }) => void,
 *   postMessage: (msg: unknown) => void,
 * }} opts
 *
 * @returns {{ dispatch: (msg: unknown) => void }}
 *
 * `dispatch(msg)` handles realm-bound messages. Validation order:
 *   1. Envelope shape -- bad shape responds `malformed` (if id is a
 *      number, so the realm pending entry can be released) or drops.
 *   2. Cap grant -- not in `grantedCaps` -> audit denied, respond
 *      `denied`.
 *   3. Cap impl present -- not in `capImpls` -> audit (denied:
 *      "missing impl"), respond `missing`.
 *   4. Invoke via `Promise.resolve().then(() => impl(...args))` -- the
 *      then-callback isolates the impl call from the realm's possibly
 *      thenable return value (foreign thenable hazard). On resolve,
 *      audit `{ok:true}` and respond `result`. On reject, audit
 *      `{ok:false, error}` and respond `error` with `type: "throw"`.
 *
 * No implicit coercion. The bridge never reads from args beyond passing
 * the array to the impl; `cap` is the only string it inspects.
 */
export function createHostBridge(opts) {
  if (!opts || typeof opts !== "object") {
    throw new TypeError("createHostBridge: opts is required");
  }
  if (!(opts.grantedCaps instanceof Set)) {
    throw new TypeError("createHostBridge: opts.grantedCaps must be a Set");
  }
  if (!(opts.capImpls instanceof Map)) {
    throw new TypeError("createHostBridge: opts.capImpls must be a Map");
  }
  if (typeof opts.audit !== "function") {
    throw new TypeError("createHostBridge: opts.audit must be a function");
  }
  if (typeof opts.postMessage !== "function") {
    throw new TypeError("createHostBridge: opts.postMessage must be a function");
  }

  const grantedCaps = opts.grantedCaps;
  const capImpls = opts.capImpls;
  const audit = opts.audit;
  const postMessage = opts.postMessage;

  /** @type {Map<number, AbortController>} */
  const pendingControllers = new Map();

  /** @param {unknown} msg */
  function dispatch(msg) {
    if (isCancelEnvelope(msg)) {
      // Cancel arrives by correlation id. The controller may already be
      // gone (call settled before cancel arrived) or never have been
      // created (cancel for unknown id) -- in both cases silently drop.
      const c = pendingControllers.get(msg.id);
      if (c) c.abort();
      return;
    }
    if (!isCallEnvelope(msg)) {
      // Try to salvage an id so the realm's pending entry isn't leaked.
      let recoveredId = null;
      if (msg !== null && typeof msg === "object") {
        const m = /** @type {Record<string, unknown>} */ (msg);
        if (typeof m.id === "number") recoveredId = m.id;
      }
      if (recoveredId !== null) {
        postMessage({
          id: recoveredId,
          kind: "error",
          error: { type: "malformed", message: "malformed call envelope" },
        });
      }
      return;
    }

    const id = msg.id;
    const cap = msg.cap;
    const rawArgs = msg.args;

    // Scan top-level args for cap-signal markers. For each, allocate a
    // fresh AbortController on the host realm and substitute its
    // signal in the args the impl sees. Multiple markers share one
    // controller per call id -- if either signal aborts, the impl
    // sees a single abort (mirroring what a caller would observe if it
    // ANDed two signals upstream). This keeps the host bookkeeping
    // one-controller-per-call, which matches the wire-level
    // {kind: "cancel"} (no per-signal id on cancel).
    /** @type {unknown[]} */
    const args = new Array(rawArgs.length);
    /** @type {AbortController | null} */
    let controller = null;
    for (let j = 0; j < rawArgs.length; j++) {
      const v = rawArgs[j];
      if (isCapSignalMarker(v)) {
        if (controller === null) controller = new AbortController();
        args[j] = controller.signal;
      } else {
        args[j] = v;
      }
    }
    if (controller !== null) pendingControllers.set(id, controller);

    if (!grantedCaps.has(cap)) {
      pendingControllers.delete(id);
      audit({ cap, args, denied: "not granted" });
      postMessage({
        id,
        kind: "error",
        error: { type: "denied", message: "cap not granted: " + cap },
      });
      return;
    }

    const impl = capImpls.get(cap);
    if (typeof impl !== "function") {
      pendingControllers.delete(id);
      audit({ cap, args, denied: "missing impl" });
      postMessage({
        id,
        kind: "error",
        error: { type: "missing", message: "cap impl missing: " + cap },
      });
      return;
    }

    // Foreign-thenable hazard: never `await impl(...args)` nor
    // `Promise.resolve(impl(...args))` -- the impl might return a
    // pack-controlled thenable that runs synchronous host code in its
    // `.then`. Wrap the invocation in a then-callback on an already-
    // resolved promise; the runtime adopts the returned value as a
    // promise via the standard promise-resolution procedure inside the
    // then-callback's microtask, not synchronously on the host stack.
    Promise.resolve().then(() => impl(...args)).then(
      function onResolve(value) {
        pendingControllers.delete(id);
        audit({ cap, args, ok: true });
        postMessage({ id, kind: "result", value });
      },
      function onReject(err) {
        pendingControllers.delete(id);
        audit({ cap, args, ok: false, error: err });
        const message = (err && typeof err === "object" && "message" in err
          && typeof (/** @type {{ message: unknown }} */ (err)).message === "string")
          ? /** @type {{ message: string }} */ (err).message
          : String(err);
        postMessage({
          id,
          kind: "error",
          error: { type: "throw", message },
        });
      },
    );
  }

  return { dispatch };
}
