// lib/js_caps/set_timeout.js
//
// Day-zero `set_timeout` cap implementation. Returns a Promise that
// resolves to performance.now() after delayMs.
//
// Spec: docs/browser_caps.md §4.9.1 / §5. The day-zero shape returns a
// Promise rather than a host-side handle: the pack realm cannot manage
// handles synchronously, and the streaming subscriber-token convention
// for cancellable timers is an open question (docs §7). Cancellation
// is therefore not supported in this commit; `clear_timeout` is a
// documented no-op until the cancellable-timer design lands.
//
// delayMs is clamped to [0, MAX_DELAY]. MAX_DELAY = 3_600_000 ms = 1 h
// (a host-side DoS guard; longer waits should be expressed as a chain).

const MAX_DELAY = 3_600_000;

export const set_timeout = (delayMs) => {
  if (typeof delayMs !== "number" || !Number.isFinite(delayMs)) {
    throw new TypeError("set_timeout: delayMs must be a finite number");
  }
  const clamped = Math.max(0, Math.min(delayMs, MAX_DELAY));
  return new Promise((resolve) => {
    globalThis.setTimeout(() => resolve(globalThis.performance.now()), clamped);
  });
};
