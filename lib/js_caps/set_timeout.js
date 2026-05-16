// lib/js_caps/set_timeout.js
//
// Day-zero `set_timeout` cap implementation. Delay-resolved Promise with
// AbortSignal-based cancellation.
//
// Spec: docs/browser_caps.md §4.9.1 / §5. The cap is a pure wrap of the
// host's setTimeout. The pack-side AbortSignal does not cross the wire
// directly -- the cap bridge (lib/js_cap_bridge/bridge.js) intercepts
// top-level AbortSignal args on the realm side, emits a cancel envelope
// keyed to the call's correlation id, and the host bridge allocates a
// fresh host-realm AbortController whose signal is substituted into the
// args delivered here. So `opts.signal` as this impl receives it is a
// host-realm AbortSignal, not a pack-realm one.
//
// No platform-side clamp on delayMs. The browser's native setTimeout
// limit (INT32_MAX ms, ~24.8 days) applies; values exceeding that are
// silently clamped by the host runtime per the HTML spec. Validation
// here only rejects non-finite / negative / non-numeric delays.

/**
 * @param {number} delayMs non-negative finite number; browser enforces upper bound (~24.8 days INT32_MAX)
 * @param {{ signal?: AbortSignal }} [opts]
 * @returns {Promise<void>} resolves when timer fires; rejects with AbortError if signal aborts first
 */
export const set_timeout = (delayMs, opts) => {
  if (typeof delayMs !== "number" || !Number.isFinite(delayMs) || delayMs < 0) {
    throw new TypeError(
      "set_timeout: delayMs must be a non-negative finite number",
    );
  }
  let signal;
  if (opts !== undefined && opts !== null) {
    if (typeof opts !== "object") {
      throw new TypeError("set_timeout: opts must be an object");
    }
    const candidate = /** @type {{ signal?: unknown }} */ (opts).signal;
    if (candidate !== undefined && candidate !== null) {
      // Duck-typed AbortSignal check: must have `aborted` boolean and
      // addEventListener / removeEventListener methods. Cross-realm
      // instanceof is unreliable, so accept structural matches too.
      const c = /** @type {Record<string, unknown>} */ (candidate);
      const looksLikeSignal = typeof c === "object"
        && typeof c.aborted === "boolean"
        && typeof c.addEventListener === "function"
        && typeof c.removeEventListener === "function";
      if (!looksLikeSignal) {
        throw new TypeError("set_timeout: opts.signal must be an AbortSignal");
      }
      signal = /** @type {AbortSignal} */ (candidate);
    }
  }
  return new Promise((resolve, reject) => {
    if (signal && signal.aborted) {
      const err = new Error("aborted");
      err.name = "AbortError";
      reject(err);
      return;
    }
    /** @type {() => void} */
    let onAbort;
    const handle = globalThis.setTimeout(() => {
      if (signal) signal.removeEventListener("abort", onAbort);
      resolve();
    }, delayMs);
    onAbort = () => {
      globalThis.clearTimeout(handle);
      const err = new Error("aborted");
      err.name = "AbortError";
      reject(err);
    };
    if (signal) signal.addEventListener("abort", onAbort, { once: true });
  });
};
