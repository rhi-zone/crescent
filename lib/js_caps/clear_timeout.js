// lib/js_caps/clear_timeout.js
//
// Day-zero `clear_timeout` cap implementation. NO-OP.
//
// Spec: docs/browser_caps.md §4.9.1 / §5. The day-zero `set_timeout`
// returns a Promise rather than a host-side handle; there is nothing
// for clear_timeout to cancel. The cap is listed in the day-zero set
// because the cancellable-timer pattern is a documented open question
// (docs/browser_caps.md §7 "Streaming subscriber convention") and the
// name is reserved for the future cancellable-timer shape.
//
// For now this logs a deprecation note (once per process, to avoid
// spamming hosts whose pack repeatedly calls into the cap) and returns
// undefined. The cap bridge still audit-logs each call so operators
// can see when packs are reaching for cancellation that does not exist.

let warned = false;

export const clear_timeout = (_handle) => {
  if (!warned) {
    warned = true;
    globalThis.console.warn(
      "[pack] clear_timeout: day-zero no-op; set_timeout returns a Promise, " +
        "not a handle. The cap reservation will land a real impl when the " +
        "cancellable-timer pattern is designed (docs/browser_caps.md §7).",
    );
  }
  return undefined;
};
