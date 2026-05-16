// lib/js_caps/index.js
//
// Day-zero cap implementations for the pack-realm host bridge. ESM
// aggregator. Each cap is a pure wrap of a host API; per-cap files in
// this directory hold the impl, this file gathers them.
//
// Spec: docs/browser_caps.md §5 enumerates the day-zero caps. The full
// day-zero surface is 17 caps and is now complete:
//
//   text_encode, text_decode, compress, decompress, console_log,
//   web_crypto_random, web_crypto_subtle, set_timeout, clipboard_write
//     -- pure-function caps, members of `dayZeroCaps`.
//   makeFetchApi (factory)
//     -- one cap (`fetch_api`), config-bound (`allowed_origins`).
//   makeKvCaps (factory)
//     -- four caps (`kv_read`, `kv_write`, `kv_delete`, `kv_keys`),
//        config-bound (`pack_id`), share an IndexedDB backend.
//   makeUiCaps (factory)
//     -- three caps (`toast`, `dialog`, `navigate`), host-app-bound
//        (`renderToast`, `renderDialog`, `requestNavigate`); pure
//        routing over host-supplied UI primitives.
//
// `dayZeroCaps` holds the FUNCTIONS-WITHOUT-CONFIG subset (9 caps).
// The factory-shaped caps (8 caps across three factories) are exported
// separately because they require host-side construction with the
// per-pack or per-host-app config. `buildDayZeroCapImpls` composes
// everything into a single Map ready to hand to mountPack.
//
// ## Factory caps vs bare-function caps
//
// Most caps in this module are pure functions: the same impl is safe
// for every pack. They live in `dayZeroCaps` directly.
//
// Factory caps carry config that must be bound at host-side
// instantiation, not passed by the pack as a per-call arg (a pack-
// supplied allowlist or pack-id would defeat the manifest grant; see
// docs/browser_caps.md §4.1.1, §4.2.1, §4.4.10, §4.10.3, §4.10.4):
//
//   - makeFetchApi({ allowed_origins })       -> fetch_api
//   - makeKvCaps({ pack_id })                 -> { kv_read, kv_write,
//                                                  kv_delete, kv_keys }
//   - makeUiCaps({ renderToast, renderDialog,
//                  requestNavigate })         -> { toast, dialog,
//                                                  navigate }
//
// The host page calls each factory per manifest entry / per host-app
// config and merges the result into the cap-impls Map. The
// `buildDayZeroCapImpls` helper below performs that composition for
// the common case where the host page wants the full day-zero surface.
// Callers that want a narrower set (e.g. an audit-restricted pack)
// import individual factories / cap functions and build their own Map.

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
import { makeUiCaps } from "./ui.js";

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
  makeUiCaps,
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

/**
 * Compose the full day-zero cap-impls Map for a single pack. Pure
 * convenience over the individual factories: callers that need
 * narrower wiring should import the factories directly.
 *
 * Any of `fetchConfig`, `kvConfig`, `uiPrimitives` may be omitted; the
 * caps from the missing factory are then absent from the returned Map.
 * This means a manifest that does not grant `fetch_api` does not force
 * the host page to invent an `allowed_origins` list; the cap simply is
 * not in the Map and mountPack's `capNames`-subset check ensures the
 * pack manifest cannot grant a cap whose impl is missing.
 *
 * @param {{
 *   fetchConfig?: { allowed_origins: string[] },
 *   kvConfig?: { pack_id: string },
 *   uiPrimitives?: {
 *     renderToast: (args: { message: string, level: "info"|"warning"|"error", duration: number }) => void | Promise<void>,
 *     renderDialog: (args: { message: string, buttons: string[] }) => Promise<string>,
 *     requestNavigate: (args: { path: string }) => void | Promise<void>,
 *   },
 * }} opts
 * @returns {Map<string, (...args: unknown[]) => unknown>}
 */
export const buildDayZeroCapImpls = (opts) => {
  if (opts === null || typeof opts !== "object") {
    throw new TypeError("buildDayZeroCapImpls: opts must be an object");
  }
  /** @type {Map<string, (...args: unknown[]) => unknown>} */
  const out = new Map(dayZeroCaps);
  if (opts.fetchConfig !== undefined) {
    out.set("fetch_api", /** @type {(...args: unknown[]) => unknown} */ (
      /** @type {unknown} */ (makeFetchApi(opts.fetchConfig))
    ));
  }
  if (opts.kvConfig !== undefined) {
    const kv = makeKvCaps(opts.kvConfig);
    out.set("kv_read", /** @type {(...args: unknown[]) => unknown} */ (/** @type {unknown} */ (kv.kv_read)));
    out.set("kv_write", /** @type {(...args: unknown[]) => unknown} */ (/** @type {unknown} */ (kv.kv_write)));
    out.set("kv_delete", /** @type {(...args: unknown[]) => unknown} */ (/** @type {unknown} */ (kv.kv_delete)));
    out.set("kv_keys", /** @type {(...args: unknown[]) => unknown} */ (/** @type {unknown} */ (kv.kv_keys)));
  }
  if (opts.uiPrimitives !== undefined) {
    const ui = makeUiCaps(opts.uiPrimitives);
    out.set("toast", /** @type {(...args: unknown[]) => unknown} */ (/** @type {unknown} */ (ui.toast)));
    out.set("dialog", /** @type {(...args: unknown[]) => unknown} */ (/** @type {unknown} */ (ui.dialog)));
    out.set("navigate", /** @type {(...args: unknown[]) => unknown} */ (/** @type {unknown} */ (ui.navigate)));
  }
  return out;
};
