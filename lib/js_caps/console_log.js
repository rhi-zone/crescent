// lib/js_caps/console_log.js
//
// Day-zero `console_log` cap implementation. Pack-side console bridged
// to the host's console.
//
// Spec: docs/browser_caps.md §4.14 / §5. Args are coerced to strings
// before forwarding so the host console never invokes a pack-controlled
// toString / Symbol.toPrimitive hook (the foreign-thenable / coercion
// hazard described in docs/browser_caps.md §2.2). Non-strings are
// JSON.stringify'd; cycles and unrepresentable values are caught and
// rendered as "[unrepresentable]" rather than thrown.
//
// Returns undefined; the cap is fire-and-forget from the realm's view
// but still goes through the bridge's promise so audit-logging applies.

const safeStringify = (value) => {
  if (typeof value === "string") return value;
  try {
    const s = JSON.stringify(value);
    return s === undefined ? String(value) : s;
  } catch (_err) {
    return "[unrepresentable]";
  }
};

export const console_log = (...args) => {
  const rendered = args.map(safeStringify);
  globalThis.console.log("[pack]", ...rendered);
  return undefined;
};
