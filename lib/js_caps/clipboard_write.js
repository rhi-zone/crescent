// lib/js_caps/clipboard_write.js
//
// Day-zero `clipboard_write` cap implementation. Writes a string to the
// system clipboard via `navigator.clipboard.writeText`.
//
// Spec: docs/browser_caps.md §4.10.5 / §5. The cap is a pure wrap of
// the host's clipboard API. Browser-permission-gated: the first call in
// a realm may surface a permission prompt; if the user denies, the
// underlying API rejects with a DOMException(name: "NotAllowedError"),
// which the cap propagates so the cap-bridge surfaces it to the pack
// realm as a `throw` envelope.
//
// Validation: arg must be a string (structural check, per the §2.2
// "Entry args type" rule). Size is capped at 1 MiB -- the clipboard is
// a user-facing UI primitive for paste-back flows (links, snippets,
// short text), not a bulk-data channel. Multi-megabyte payloads are
// almost certainly a bug (e.g. accidentally serialising a whole table)
// and rejecting them early surfaces the bug at the cap call rather
// than producing a clipboard the user can't reasonably paste anywhere.

const MAX_BYTES = 1024 * 1024; // 1 MiB

export const clipboard_write = async (text) => {
  if (typeof text !== "string") {
    throw new TypeError("clipboard_write: text must be string");
  }
  if (text.length > MAX_BYTES) {
    throw new RangeError(
      "clipboard_write: text exceeds 1 MiB cap (got " + text.length + ")",
    );
  }
  const nav = globalThis.navigator;
  if (nav === undefined || nav === null ||
      nav.clipboard === undefined || nav.clipboard === null ||
      typeof nav.clipboard.writeText !== "function") {
    throw new Error("clipboard_write: clipboard API not available in this realm");
  }
  await nav.clipboard.writeText(text);
};
