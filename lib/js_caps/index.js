// lib/js_caps/index.js
//
// Day-zero cap implementations for the pack-realm host bridge. ESM
// aggregator. Each cap is a pure wrap of a host API; per-cap files in
// this directory hold the impl, this file gathers them into the
// `dayZeroCaps` Map that lib/js_pack_host/host.js#mountPack consumes as
// `opts.capImpls`.
//
// Spec: docs/browser_caps.md §5 enumerates the day-zero caps. This
// module ships the 6 trivial pure-wrap caps plus set_timeout
// (cancellable via the cap-bridge AbortSignal extension; see
// docs/platform_isolation.md §4) plus web_crypto_subtle (op-
// discriminated wrap of SubtleCrypto) plus clipboard_write plus the
// fetch_api factory and the makeKvCaps factory (the four kv_* caps;
// IndexedDB-backed, per-pack partitioned -- both config-bound at
// host-side instantiation; see below):
//
//   text_encode, text_decode, compress, decompress, console_log,
//   web_crypto_random, set_timeout, web_crypto_subtle, clipboard_write,
//   makeFetchApi (factory), makeKvCaps (factory).
//
// The remaining caps (navigate, dialog, toast) involve design
// decisions and land in subsequent commits. Their names are NOT in
// dayZeroCaps yet -- callers wiring those caps must add them as
// additional Map entries alongside the ones this module exports.
// kv_* is shipped via the `makeKvCaps` factory (see below) and is
// likewise NOT in dayZeroCaps because it is config-bound per pack.
//
// Each cap is also exported individually so callers that want a
// narrower set (e.g. an audit-restricted pack) can build their own Map.
//
// ## Factory caps vs bare-function caps
//
// Most caps in this module are pure functions: the same impl is safe
// for every pack. They live in `dayZeroCaps` directly.
//
// Some caps -- `fetch_api` and the `kv_*` family today, and future
// per-pack-configured caps like `navigate` (allowed_navigations) --
// carry manifest-supplied config that must be bound at host-side
// instantiation, not passed by the pack as a per-call arg (a pack-
// supplied allowlist or pack-id would defeat the manifest grant; see
// docs/browser_caps.md §4.1.1, §4.2.1). These are exported as
// factories (`makeFetchApi`, `makeKvCaps`, etc.) the host page calls
// per manifest entry. The host page is expected to construct the
// cap-impls Map at mount time:
//
//   const capImpls = new Map(dayZeroCaps);
//   for (const [name, entry] of Object.entries(manifest.browser_caps ?? {})) {
//     if (entry.kind === "fetch_api") {
//       capImpls.set(name, makeFetchApi(entry.config));
//     } else if (entry.kind === "kv_read" /* or kv_write/kv_delete/kv_keys */) {
//       // The four kv_* caps share a backend; construct once per pack
//       // and merge the resulting record into the Map:
//       const kv = makeKvCaps({ pack_id: manifest.id });
//       capImpls.set("kv_read", kv.kv_read);
//       capImpls.set("kv_write", kv.kv_write);
//       capImpls.set("kv_delete", kv.kv_delete);
//       capImpls.set("kv_keys", kv.kv_keys);
//     }
//     // ... other factory kinds
//   }
//
// `dayZeroCaps` therefore aggregates only the pack-config-free caps;
// factory caps must be explicitly constructed by the host page.

import { text_encode } from "./text_encode.js";
import { text_decode } from "./text_decode.js";
import { compress } from "./compress.js";
import { decompress } from "./decompress.js";
import { console_log } from "./console_log.js";
import { web_crypto_random } from "./web_crypto_random.js";
import { web_crypto_subtle } from "./web_crypto_subtle.js";
import { set_timeout } from "./set_timeout.js";
import { clipboard_write } from "./clipboard_write.js";
import { makeFetchApi } from "./fetch_api.js";
import { makeKvCaps } from "./kv.js";

export {
  text_encode,
  text_decode,
  compress,
  decompress,
  console_log,
  web_crypto_random,
  web_crypto_subtle,
  set_timeout,
  clipboard_write,
  makeFetchApi,
  makeKvCaps,
};

export const dayZeroCaps = new Map([
  ["text_encode", text_encode],
  ["text_decode", text_decode],
  ["compress", compress],
  ["decompress", decompress],
  ["console_log", console_log],
  ["web_crypto_random", web_crypto_random],
  ["web_crypto_subtle", web_crypto_subtle],
  ["set_timeout", set_timeout],
  ["clipboard_write", clipboard_write],
]);
