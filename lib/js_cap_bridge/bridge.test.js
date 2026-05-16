// lib/js_cap_bridge/bridge.test.js
//
// Self-tests for createRealmBridge / createHostBridge. To run:
//
//   bun lib/js_cap_bridge/bridge.test.js
//
// Test groups (mirrored by needles in parity_test.lua):
//   - happy path        : echo, concurrent ids, host-Promise return
//   - authorization     : denied (not granted), missing (granted but no impl)
//   - error propagation : impl throws, impl returns rejected Promise
//   - malformed         : alien response, host-side malformed call
//   - non-constructable : `new caps.foo()` throws TypeError
//   - no implicit coercion: host never triggers Symbol.toPrimitive on args

import { createRealmBridge, createHostBridge } from "./bridge.js";

// ---------------------------------------------------------------------
// Tiny test harness.
// ---------------------------------------------------------------------

/** @type {{ name: string, fn: () => Promise<void> | void }[]} */
const TESTS = [];

/** @param {string} name @param {() => Promise<void> | void} fn */
function test(name, fn) { TESTS.push({ name, fn }); }

function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error("assert eq failed (" + (label || "") + "): " +
      "expected " + e + " got " + a);
  }
}

function ok(cond, label) {
  if (!cond) throw new Error("assert ok failed: " + (label || ""));
}

async function rejects(promise, label) {
  try {
    await promise;
  } catch (e) {
    return e;
  }
  throw new Error("expected rejection: " + (label || ""));
}

// ---------------------------------------------------------------------
// Paired-bridge fixture.
//
// Build a realm bridge and a host bridge whose postMessages route to
// each other's dispatch. This models the real iframe<->stub wiring
// where one side's postMessage triggers the other side's message-event
// handler. No structured-clone is performed (bun's `node:vm` would
// strip functions, but we want some tests -- e.g. the coercion test --
// to verify the host bridge itself never reaches into args).
// ---------------------------------------------------------------------

/**
 * @param {{ capNames: string[], grantedCaps: Set<string>,
 *           capImpls: Map<string, (...args: any[]) => any>,
 *           audit?: (entry: any) => void }} cfg
 */
function pair(cfg) {
  /** @type {(msg: any) => void} */
  let realmDispatch = () => { /* set below */ };
  /** @type {(msg: any) => void} */
  let hostDispatch = () => { /* set below */ };

  /** @type {any[]} */
  const auditLog = [];
  const audit = cfg.audit || ((e) => auditLog.push(e));

  const host = createHostBridge({
    grantedCaps: cfg.grantedCaps,
    capImpls: cfg.capImpls,
    audit,
    postMessage: (msg) => realmDispatch(msg),
  });
  hostDispatch = host.dispatch;

  const realm = createRealmBridge({
    capNames: cfg.capNames,
    postMessage: (msg) => hostDispatch(msg),
    registerMessageHandler: (handler) => { realmDispatch = handler; },
  });

  return { realm, host, auditLog };
}

// ---------------------------------------------------------------------
// Happy path.
// ---------------------------------------------------------------------

test("happy path: echo returns host value", async () => {
  const { realm, auditLog } = pair({
    capNames: ["echo"],
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", (s) => s + "-resp"]]),
  });
  const out = await realm.caps.echo("hi");
  eq(out, "hi-resp", "echo round-trip");
  eq(auditLog.length, 1, "one audit entry");
  ok(auditLog[0].ok === true, "audit ok=true");
  eq(auditLog[0].cap, "echo");
});

test("happy path: multiple concurrent calls correlate by id", async () => {
  let delayCount = 0;
  const { realm } = pair({
    capNames: ["slow"],
    grantedCaps: new Set(["slow"]),
    capImpls: new Map([["slow", async (n) => {
      // Resolve out-of-order: first call yields more microtasks than second.
      const yields = (delayCount++ === 0) ? 5 : 1;
      for (let i = 0; i < yields; i++) await Promise.resolve();
      return n * 10;
    }]]),
  });
  const [a, b, c] = await Promise.all([
    realm.caps.slow(1),
    realm.caps.slow(2),
    realm.caps.slow(3),
  ]);
  eq(a, 10);
  eq(b, 20);
  eq(c, 30);
});

test("happy path: host returns a Promise", async () => {
  const { realm } = pair({
    capNames: ["async_echo"],
    grantedCaps: new Set(["async_echo"]),
    capImpls: new Map([["async_echo", (s) => Promise.resolve(s + "-async")]]),
  });
  const out = await realm.caps.async_echo("zz");
  eq(out, "zz-async");
});

// ---------------------------------------------------------------------
// Authorization.
// ---------------------------------------------------------------------

test("auth: cap not in grantedCaps rejects with denied", async () => {
  const { realm, auditLog } = pair({
    capNames: ["http_client"],
    grantedCaps: new Set(), // nothing granted
    capImpls: new Map([["http_client", () => "should not run"]]),
  });
  const err = /** @type {any} */ (await rejects(
    realm.caps.http_client("/get"), "denied cap should reject",
  ));
  eq(err.type, "denied");
  ok(err.message.indexOf("http_client") >= 0, "denied message names cap");
  eq(auditLog.length, 1);
  eq(auditLog[0].denied, "not granted");
});

test("auth: cap granted but impl missing rejects with missing", async () => {
  const { realm, auditLog } = pair({
    capNames: ["clipboard"],
    grantedCaps: new Set(["clipboard"]),
    capImpls: new Map(), // grant present but impl absent
  });
  const err = /** @type {any} */ (await rejects(realm.caps.clipboard("x")));
  eq(err.type, "missing");
  ok(err.message.indexOf("clipboard") >= 0);
  eq(auditLog[0].denied, "missing impl");
});

// ---------------------------------------------------------------------
// Error propagation.
// ---------------------------------------------------------------------

test("error: impl throws", async () => {
  const { realm, auditLog } = pair({
    capNames: ["boom"],
    grantedCaps: new Set(["boom"]),
    capImpls: new Map([["boom", () => { throw new Error("kaboom"); }]]),
  });
  const err = /** @type {any} */ (await rejects(realm.caps.boom()));
  eq(err.type, "throw");
  eq(err.message, "kaboom");
  eq(auditLog[0].ok, false);
});

test("error: impl returns rejected promise", async () => {
  const { realm } = pair({
    capNames: ["boom"],
    grantedCaps: new Set(["boom"]),
    capImpls: new Map([["boom", () => Promise.reject(new Error("rejected!"))]]),
  });
  const err = /** @type {any} */ (await rejects(realm.caps.boom()));
  eq(err.type, "throw");
  eq(err.message, "rejected!");
});

// ---------------------------------------------------------------------
// Malformed protocol.
// ---------------------------------------------------------------------

test("malformed: realm drops alien response with unknown id", async () => {
  // Build only the realm bridge so we can inject crafted host messages.
  const sent = /** @type {any[]} */ ([]);
  /** @type {(msg: any) => void} */
  let _handler = () => {};
  const { caps, dispatch } = createRealmBridge({
    capNames: ["echo"],
    postMessage: (m) => sent.push(m),
    registerMessageHandler: (h) => { _handler = h; },
  });
  // Issue a real call to register a pending entry with id=1.
  const pendingPromise = caps.echo("k");
  // Now drop an alien response with id=999. Should NOT resolve pendingPromise.
  dispatch({ kind: "result", id: 999, value: "WRONG" });
  // Drop malformed garbage. Should be silently ignored.
  dispatch(null);
  dispatch({ kind: "what" });
  dispatch("not even an object");
  // Now legitimately resolve id=1.
  dispatch({ kind: "result", id: 1, value: "ok-1" });
  const out = await pendingPromise;
  eq(out, "ok-1", "alien messages did not corrupt pending entry");
});

test("malformed: host responds with malformed when id is recoverable", async () => {
  /** @type {any[]} */
  const sent = [];
  const host = createHostBridge({
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", () => "ok"]]),
    audit: () => {},
    postMessage: (m) => sent.push(m),
  });
  // Send a half-formed envelope: id present but no cap/args.
  host.dispatch({ id: 42, kind: "call" });
  eq(sent.length, 1);
  eq(sent[0].id, 42);
  eq(sent[0].kind, "error");
  eq(sent[0].error.type, "malformed");
});

test("malformed: host drops envelope with no recoverable id", async () => {
  /** @type {any[]} */
  const sent = [];
  const host = createHostBridge({
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", () => "ok"]]),
    audit: () => {},
    postMessage: (m) => sent.push(m),
  });
  host.dispatch(null);
  host.dispatch({ kind: "call", cap: "echo", args: [] }); // no id
  host.dispatch("garbage");
  eq(sent.length, 0, "nothing to send when id unrecoverable");
});

test("malformed: alien second response for same id is dropped", async () => {
  /** @type {any[]} */
  const sent = [];
  /** @type {(m: any) => void} */
  let _h = () => {};
  const { caps, dispatch } = createRealmBridge({
    capNames: ["echo"],
    postMessage: (m) => sent.push(m),
    registerMessageHandler: (h) => { _h = h; },
  });
  const p = caps.echo("a");
  dispatch({ id: 1, kind: "result", value: "first" });
  // Second response for same id -- should be silently dropped.
  dispatch({ id: 1, kind: "result", value: "second" });
  dispatch({ id: 1, kind: "error", error: { type: "throw", message: "no" } });
  eq(await p, "first");
});

// ---------------------------------------------------------------------
// Non-constructability.
// ---------------------------------------------------------------------

test("non-constructable: `new caps.echo()` throws TypeError", async () => {
  const { realm } = pair({
    capNames: ["echo"],
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", (s) => s]]),
  });
  let threw = false;
  try {
    // @ts-ignore -- intentional misuse
    new realm.caps.echo();
  } catch (e) {
    threw = e instanceof TypeError;
  }
  ok(threw, "new on cap shell must throw TypeError");
});

// ---------------------------------------------------------------------
// No implicit coercion of args.
// ---------------------------------------------------------------------

test("no implicit coercion: host never triggers Symbol.toPrimitive on args", async () => {
  // Build a tripwire object that would record any coercion attempt.
  let coercionCalled = false;
  const tripwire = {
    [Symbol.toPrimitive]() {
      coercionCalled = true;
      return "tripped";
    },
    valueOf() { coercionCalled = true; return "tripped-valueOf"; },
    toString() { coercionCalled = true; return "tripped-toString"; },
  };
  // We inject the tripwire directly through the host dispatch path,
  // bypassing structured-clone (which would strip the symbol keys).
  // The host bridge MUST NOT touch the value before handing it to the
  // impl; the impl below verifies it received the same identity.
  /** @type {any} */
  let received = null;
  /** @type {any[]} */
  const sent = [];
  const host = createHostBridge({
    grantedCaps: new Set(["sink"]),
    capImpls: new Map([["sink", (arg) => { received = arg; return "ok"; }]]),
    audit: () => { /* must not coerce args either */ },
    postMessage: (m) => sent.push(m),
  });
  host.dispatch({ id: 1, kind: "call", cap: "sink", args: [tripwire] });
  // Yield microtasks for the Promise.resolve().then chain to run.
  for (let i = 0; i < 5; i++) await Promise.resolve();
  ok(received === tripwire, "impl received the exact tripwire instance");
  ok(!coercionCalled, "no implicit coercion on args inside the host bridge");
  eq(sent.length, 1);
  eq(sent[0].kind, "result");
});

// ---------------------------------------------------------------------
// Bonus: synchronous postMessage failure on the realm side.
// ---------------------------------------------------------------------

// ---------------------------------------------------------------------
// AbortSignal-based cancellation. See docs/platform_isolation.md §4
// "Cancellation via AbortSignal".
// ---------------------------------------------------------------------

test("cancellation: abort before call settles aborts the impl", async () => {
  /** @type {AbortSignal | null} */
  let observedSignal = null;
  /** @type {(v: unknown) => void} */
  let resolveImpl = () => {};
  const implPromise = new Promise((res) => { resolveImpl = res; });
  const { realm } = pair({
    capNames: ["slow_cap"],
    grantedCaps: new Set(["slow_cap"]),
    capImpls: new Map([["slow_cap", async (_opts, /** @type {AbortSignal} */ signal) => {
      observedSignal = signal;
      return new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => {
          const e = new Error("aborted");
          /** @type {Error & { name?: string }} */ (e).name = "AbortError";
          reject(e);
        }, { once: true });
        // Also resolve if we ever get released externally (we won't in this test).
        implPromise.then((v) => _resolve(v));
      });
    }]]),
  });
  const controller = new AbortController();
  const p = realm.caps.slow_cap({ delayMs: 5000 }, controller.signal);
  // Yield once so the host dispatch runs and the impl receives the signal.
  await Promise.resolve();
  await Promise.resolve();
  ok(observedSignal !== null, "impl received a signal");
  ok(observedSignal !== controller.signal, "host-side signal is a fresh AbortSignal, not the pack-realm signal");
  controller.abort();
  const err = /** @type {any} */ (await rejects(p, "aborted call should reject"));
  eq(err.type, "throw", "abort manifests as a throw-type error");
  eq(err.message, "aborted");
  ok(observedSignal && /** @type {AbortSignal} */ (observedSignal).aborted, "host signal aborted");
  resolveImpl(null); // silence dangling resolver
});

test("cancellation: already-aborted signal aborts immediately", async () => {
  /** @type {AbortSignal | null} */
  let observedSignal = null;
  const { realm } = pair({
    capNames: ["slow_cap"],
    grantedCaps: new Set(["slow_cap"]),
    capImpls: new Map([["slow_cap", async (/** @type {AbortSignal} */ signal) => {
      observedSignal = signal;
      // If already aborted on entry, reject; otherwise wait forever.
      if (signal.aborted) {
        const e = new Error("aborted-on-entry");
        /** @type {Error & { name?: string }} */ (e).name = "AbortError";
        throw e;
      }
      return new Promise((_r, reject) => {
        signal.addEventListener("abort", () => {
          const e = new Error("aborted-after");
          /** @type {Error & { name?: string }} */ (e).name = "AbortError";
          reject(e);
        }, { once: true });
      });
    }]]),
  });
  const controller = new AbortController();
  controller.abort();
  const p = realm.caps.slow_cap(controller.signal);
  const err = /** @type {any} */ (await rejects(p, "already-aborted should reject"));
  eq(err.type, "throw");
  ok(/aborted/.test(err.message), "rejection mentions abort");
  ok(observedSignal && /** @type {AbortSignal} */ (observedSignal).aborted, "host signal aborted");
});

test("cancellation: multiple signals in one call share a host controller", async () => {
  /** @type {AbortSignal[]} */
  const observed = [];
  const { realm } = pair({
    capNames: ["multi"],
    grantedCaps: new Set(["multi"]),
    capImpls: new Map([["multi", async (s1, _other, s2) => {
      observed.push(/** @type {AbortSignal} */ (s1));
      observed.push(/** @type {AbortSignal} */ (s2));
      return new Promise((_r, reject) => {
        const onAbort = () => {
          const e = new Error("aborted-multi");
          /** @type {Error & { name?: string }} */ (e).name = "AbortError";
          reject(e);
        };
        /** @type {AbortSignal} */ (s1).addEventListener("abort", onAbort, { once: true });
        // s2 should be the same signal as s1 because the host bridge
        // collapses multiple markers in a single call into one
        // controller. Assert that here.
      });
    }]]),
  });
  const c1 = new AbortController();
  const c2 = new AbortController();
  const p = realm.caps.multi(c1.signal, "other_arg", c2.signal);
  await Promise.resolve();
  await Promise.resolve();
  eq(observed.length, 2, "impl received both signal slots");
  ok(observed[0] === observed[1], "both markers map to the same host-side signal");
  // Aborting either realm-side signal triggers the same cancel.
  c2.abort();
  const err = /** @type {any} */ (await rejects(p));
  eq(err.message, "aborted-multi");
});

test("cancellation: abort after settle is a no-op", async () => {
  /** @type {any[]} */
  const sent = [];
  // Use a pair but spy on what flows host->realm via a custom postMessage on the host.
  const { realm } = pair({
    capNames: ["fast"],
    grantedCaps: new Set(["fast"]),
    capImpls: new Map([["fast", async (/** @type {AbortSignal} */ _signal) => "done"]]),
    audit: (e) => sent.push(e),
  });
  const controller = new AbortController();
  const out = await realm.caps.fast(controller.signal);
  eq(out, "done", "call settles before abort");
  // Aborting now should be a no-op: no exception, no extra audit.
  const auditCountBefore = sent.length;
  controller.abort();
  // Yield a few microtasks to be sure.
  for (let i = 0; i < 5; i++) await Promise.resolve();
  eq(sent.length, auditCountBefore, "abort after settle produced no further audit events");
});

test("cancellation: host drops cancel for unknown id", async () => {
  /** @type {any[]} */
  const sent = [];
  const host = createHostBridge({
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", () => "ok"]]),
    audit: () => {},
    postMessage: (m) => sent.push(m),
  });
  // Unknown id, no prior call.
  host.dispatch({ id: 999, kind: "cancel" });
  // Still no crash; no response was sent.
  eq(sent.length, 0, "cancel for unknown id produces no message");
});

test("cancellation: non-AbortSignal args still flow normally", async () => {
  /** @type {unknown[]} */
  let received = [];
  const { realm } = pair({
    capNames: ["mix"],
    grantedCaps: new Set(["mix"]),
    capImpls: new Map([["mix", async (...args) => {
      received = args;
      return "ok";
    }]]),
  });
  const c = new AbortController();
  const out = await realm.caps.mix("first", c.signal, 42, { k: "v" });
  eq(out, "ok");
  eq(received[0], "first");
  ok(isAbortSignalLike(received[1]), "second arg is a (host-side) AbortSignal");
  eq(received[2], 42);
  eq(/** @type {any} */ (received[3]).k, "v");
});

test("cancellation: call without any signal sends no markers and works normally", async () => {
  /** @type {any[]} */
  const wireMessages = [];
  /** @type {(m: any) => void} */
  let hostDispatch = () => {};
  const host = createHostBridge({
    grantedCaps: new Set(["echo"]),
    capImpls: new Map([["echo", (s) => s + "!"]]),
    audit: () => {},
    postMessage: () => {},
  });
  hostDispatch = host.dispatch;
  const { caps } = createRealmBridge({
    capNames: ["echo"],
    postMessage: (m) => { wireMessages.push(m); hostDispatch(m); },
    registerMessageHandler: (h) => {
      // Build a host->realm path that funnels host responses back.
      // Override the host postMessage above by rewiring through pair() would be cleaner,
      // but we just need to assert wire shape here.
      void h;
    },
  });
  // We don't actually await the call (no return path wired); we just
  // verify the wire-args don't contain markers when no signal is passed.
  caps.echo("hi");
  eq(wireMessages.length, 1);
  eq(wireMessages[0].kind, "call");
  ok(!hasCapSignalMarker(wireMessages[0].args), "no __cap_signal markers when no signal passed");
});

test("cancellation: duck-typed cross-realm signal is detected", async () => {
  // Build a fake signal-shaped object that masquerades as an AbortSignal
  // via Object.prototype.toString. (Simulates a signal from a different
  // realm whose `instanceof AbortSignal` check would fail.)
  /** @type {Array<() => void>} */
  const listeners = [];
  const fakeSignal = {
    aborted: false,
    addEventListener(/** @type {string} */ ev, /** @type {() => void} */ cb) {
      if (ev === "abort") listeners.push(cb);
    },
    removeEventListener() {},
    get [Symbol.toStringTag]() { return "AbortSignal"; },
  };
  ok(Object.prototype.toString.call(fakeSignal) === "[object AbortSignal]",
    "fakeSignal has the right brand");

  /** @type {AbortSignal | null} */
  let observedSignal = null;
  const { realm } = pair({
    capNames: ["x"],
    grantedCaps: new Set(["x"]),
    capImpls: new Map([["x", async (/** @type {AbortSignal} */ signal) => {
      observedSignal = signal;
      return new Promise((_r, reject) => {
        signal.addEventListener("abort", () => {
          const e = new Error("aborted-duck");
          /** @type {Error & { name?: string }} */ (e).name = "AbortError";
          reject(e);
        }, { once: true });
      });
    }]]),
  });
  const p = realm.caps.x(/** @type {any} */ (fakeSignal));
  await Promise.resolve();
  await Promise.resolve();
  ok(observedSignal !== null, "impl received a real host AbortSignal in place of the duck");
  // Fire the duck's abort listeners to simulate the realm-side signal aborting.
  for (const l of listeners) l();
  const err = /** @type {any} */ (await rejects(p));
  ok(/aborted-duck/.test(err.message), "cancellation propagated via duck-typed detection");
});

/** @param {unknown} v */
function isAbortSignalLike(v) {
  if (v === null || typeof v !== "object") return false;
  if (typeof AbortSignal !== "undefined" && v instanceof AbortSignal) return true;
  return Object.prototype.toString.call(v) === "[object AbortSignal]";
}

/** @param {unknown[]} args */
function hasCapSignalMarker(args) {
  for (let i = 0; i < args.length; i++) {
    const v = args[i];
    if (v !== null && typeof v === "object"
      && /** @type {any} */ (v).__cap_signal === true) return true;
  }
  return false;
}

test("realm: postMessage that throws rejects the returned promise", async () => {
  const { caps } = createRealmBridge({
    capNames: ["echo"],
    postMessage: () => { throw new Error("transport down"); },
  });
  const err = /** @type {any} */ (await rejects(caps.echo("x")));
  ok(/transport down/.test(err.message), "rejection carries underlying error");
});

// ---------------------------------------------------------------------
// Driver.
// ---------------------------------------------------------------------

(async () => {
  let pass = 0;
  let fail = 0;
  const failures = [];
  for (const t of TESTS) {
    try {
      await t.fn();
      pass++;
    } catch (e) {
      fail++;
      failures.push({ name: t.name, error: e });
    }
  }
  // eslint-disable-next-line no-console
  console.log("js_cap_bridge tests: " + pass + " passed, " + fail + " failed");
  for (const f of failures) {
    // eslint-disable-next-line no-console
    console.error("  FAIL " + f.name + ": " + (f.error && f.error.stack || f.error));
  }
  if (fail > 0) process.exit(1);
})();
