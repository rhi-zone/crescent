// lib/js_caps/text_encode.js
//
// Day-zero `text_encode` cap implementation. UTF-8 string -> Uint8Array.
//
// Spec: docs/browser_caps.md §4.8 / §5. The cap is a pure wrap of the
// host's TextEncoder. Uint8Array is structured-clone-safe across the
// postMessage boundary, so it flows back to the realm as-is.
//
// Validation: the cap impl validates structurally before invoking the
// host API (per docs/browser_caps.md §2.2 "Entry args type"). A non-
// string argument throws TypeError; the cap bridge surfaces this as an
// error envelope with type "throw".

const encoder = new TextEncoder();

export const text_encode = (text) => {
  if (typeof text !== "string") {
    throw new TypeError("text_encode: arg must be string");
  }
  return encoder.encode(text);
};
