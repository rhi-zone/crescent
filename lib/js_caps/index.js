// lib/js_caps/index.js
//
// Day-zero cap implementations for the pack-realm host bridge. ESM
// aggregator. Each cap is a pure wrap of a host API; per-cap files in
// this directory hold the impl, this file gathers them into the
// `dayZeroCaps` Map that lib/js_pack_host/host.js#mountPack consumes as
// `opts.capImpls`.
//
// Spec: docs/browser_caps.md §5 enumerates the 18 day-zero caps. This
// commit ships the 6 trivial ones (pure wraps with no design questions):
//
//   text_encode, text_decode, compress, decompress, console_log,
//   web_crypto_random.
//
// `set_timeout` is day-zero but is deferred behind the cap-bridge
// AbortSignal cancellation extension (docs/platform_isolation.md §4
// "Cancellation via AbortSignal") — it re-lands once the bridge speaks
// AbortSignal. The remaining 11 (fetch_api, web_crypto_subtle, kv_*,
// navigate, dialog, toast, clipboard_write, set_timeout) involve design
// decisions and land in subsequent commits. Their names are NOT in
// dayZeroCaps yet -- callers wiring those caps must add them as
// additional Map entries alongside the ones this module exports.
//
// Each cap is also exported individually so callers that want a
// narrower set (e.g. an audit-restricted pack) can build their own Map.

import { text_encode } from "./text_encode.js";
import { text_decode } from "./text_decode.js";
import { compress } from "./compress.js";
import { decompress } from "./decompress.js";
import { console_log } from "./console_log.js";
import { web_crypto_random } from "./web_crypto_random.js";

export {
  text_encode,
  text_decode,
  compress,
  decompress,
  console_log,
  web_crypto_random,
};

export const dayZeroCaps = new Map([
  ["text_encode", text_encode],
  ["text_decode", text_decode],
  ["compress", compress],
  ["decompress", decompress],
  ["console_log", console_log],
  ["web_crypto_random", web_crypto_random],
]);
