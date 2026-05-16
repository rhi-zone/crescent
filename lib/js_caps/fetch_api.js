// lib/js_caps/fetch_api.js
//
// Day-zero `fetch_api` cap implementation. Attenuated browser-side HTTP
// fetch with origin allowlist.
//
// Spec: docs/browser_caps.md §4.1.1 / §5. Unlike the other day-zero caps,
// fetch_api is **factory-shaped**: the manifest carries per-pack config
// (`allowed_origins`) which must be bound at host-side instantiation time,
// not passed by the pack as an arg (a pack-supplied allowlist would
// defeat the manifest grant). `makeFetchApi({ allowed_origins })`
// returns the cap function; the host page constructs it per manifest
// entry and inserts the result into the cap-impls Map alongside
// `dayZeroCaps`.
//
// Per-call args are validated structurally before any network call:
//   - url: required string, absolute URL (parsed via `new URL`).
//     Origin must exactly match an entry in `allowed_origins`.
//   - method: optional; one of GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS.
//   - headers: optional Record<string, string>.
//   - body: optional; passed through to fetch as-is.
//   - responseFormat: optional "arraybuffer" (default) | "json" | "text".
//   - signal: optional AbortSignal. The pack-side AbortSignal does not
//     cross the wire directly -- the cap bridge replaces it with a
//     host-realm AbortSignal (see lib/js_cap_bridge/bridge.js commit
//     9899a8f0 and lib/js_caps/set_timeout.js).
//
// Response is shaped into a structured-clone-safe plain object:
//   { status, statusText, headers, body }
// where `headers` is a plain `{ [name: string]: string }` (no Headers
// object crosses the bridge per §2.5) and `body` is either an
// ArrayBuffer (default), a decoded JSON value, or a string.

const ALLOWED_METHODS = new Set([
  "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS",
]);

const ALLOWED_RESPONSE_FORMATS = new Set(["arraybuffer", "json", "text"]);

/**
 * Duck-typed cross-realm AbortSignal check. Mirrors set_timeout.js: the
 * cap-bridge synthesises a host-realm AbortSignal in place of the pack
 * realm's signal marker, so `instanceof AbortSignal` is reliable here in
 * practice -- but the structural check is cheap and matches the rest of
 * the module.
 *
 * @param {unknown} v
 * @returns {boolean}
 */
function looksLikeAbortSignal(v) {
  if (v === null || typeof v !== "object") return false;
  const c = /** @type {Record<string, unknown>} */ (v);
  return typeof c.aborted === "boolean"
    && typeof c.addEventListener === "function"
    && typeof c.removeEventListener === "function";
}

/**
 * Construct a `fetch_api` cap impl bound to a per-pack origin allowlist.
 *
 * @param {{ allowed_origins: string[] }} config
 * @returns {(args: {
 *   url: string,
 *   method?: string,
 *   headers?: Record<string, string>,
 *   body?: unknown,
 *   responseFormat?: "arraybuffer" | "json" | "text",
 *   signal?: AbortSignal,
 * }) => Promise<{
 *   status: number,
 *   statusText: string,
 *   headers: Record<string, string>,
 *   body: ArrayBuffer | string | unknown,
 * }>}
 */
export function makeFetchApi(config) {
  if (config === null || typeof config !== "object") {
    throw new TypeError(
      "makeFetchApi: config must be an object with allowed_origins",
    );
  }
  const rawAllowed = /** @type {Record<string, unknown>} */ (config).allowed_origins;
  if (!Array.isArray(rawAllowed)) {
    throw new TypeError(
      "makeFetchApi: config.allowed_origins must be an array",
    );
  }
  for (let i = 0; i < rawAllowed.length; i++) {
    if (typeof rawAllowed[i] !== "string") {
      throw new TypeError(
        "makeFetchApi: config.allowed_origins entries must be strings",
      );
    }
  }
  const allowedOrigins = new Set(/** @type {string[]} */ (rawAllowed));

  // Concise-method syntax drops [[Construct]]; `new fetch_api(...)` throws.
  return { async fetch_api(/** @type {unknown} */ args) {
    if (args === null || typeof args !== "object") {
      throw new TypeError("fetch_api: args must be an object");
    }
    const a = /** @type {Record<string, unknown>} */ (args);

    // url
    if (typeof a.url !== "string") {
      throw new TypeError("fetch_api: args.url must be a string");
    }
    /** @type {URL} */
    let parsed;
    try {
      parsed = new URL(a.url);
    } catch (_e) {
      throw new TypeError("fetch_api: args.url must be an absolute URL");
    }
    if (!allowedOrigins.has(parsed.origin)) {
      throw new TypeError(
        "fetch_api: origin not allowed: " + parsed.origin,
      );
    }

    // method
    let method = "GET";
    if (a.method !== undefined && a.method !== null) {
      if (typeof a.method !== "string") {
        throw new TypeError("fetch_api: args.method must be a string");
      }
      if (!ALLOWED_METHODS.has(a.method)) {
        throw new TypeError("fetch_api: method not allowed: " + a.method);
      }
      method = a.method;
    }

    // headers
    /** @type {Record<string, string> | undefined} */
    let headers;
    if (a.headers !== undefined && a.headers !== null) {
      if (typeof a.headers !== "object" || Array.isArray(a.headers)) {
        throw new TypeError("fetch_api: args.headers must be an object");
      }
      const h = /** @type {Record<string, unknown>} */ (a.headers);
      const out = { __proto__: null };
      for (const k of Object.keys(h)) {
        if (typeof k !== "string") {
          throw new TypeError("fetch_api: args.headers keys must be strings");
        }
        const v = h[k];
        if (typeof v !== "string") {
          throw new TypeError(
            "fetch_api: args.headers[" + k + "] must be a string",
          );
        }
        out[k] = v;
      }
      headers = /** @type {Record<string, string>} */ (out);
    }

    // signal
    /** @type {AbortSignal | undefined} */
    let signal;
    if (a.signal !== undefined && a.signal !== null) {
      if (!looksLikeAbortSignal(a.signal)) {
        throw new TypeError("fetch_api: args.signal must be an AbortSignal");
      }
      signal = /** @type {AbortSignal} */ (a.signal);
    }

    // responseFormat
    let responseFormat = "arraybuffer";
    if (a.responseFormat !== undefined && a.responseFormat !== null) {
      if (typeof a.responseFormat !== "string") {
        throw new TypeError("fetch_api: args.responseFormat must be a string");
      }
      if (!ALLOWED_RESPONSE_FORMATS.has(a.responseFormat)) {
        throw new TypeError(
          "fetch_api: args.responseFormat must be one of " +
          "'arraybuffer', 'json', 'text' (got " + a.responseFormat + ")",
        );
      }
      responseFormat = a.responseFormat;
    }

    if (typeof globalThis.fetch !== "function") {
      throw new Error("fetch_api: globalThis.fetch is not available in this realm");
    }

    /** @type {RequestInit} */
    const init = { method };
    if (headers !== undefined) init.headers = headers;
    if (a.body !== undefined) init.body = /** @type {BodyInit} */ (a.body);
    if (signal !== undefined) init.signal = signal;

    const response = await globalThis.fetch(parsed.href, init);

    // Marshal headers to a plain object -- no Headers instance crosses
    // the cap-bridge boundary (per §2.5 lockdown).
    /** @type {Record<string, string>} */
    const respHeaders = { __proto__: null };
    if (response.headers && typeof response.headers.forEach === "function") {
      response.headers.forEach((value, name) => { respHeaders[name] = value; });
    }

    /** @type {ArrayBuffer | string | unknown} */
    let body;
    if (responseFormat === "json") {
      body = await response.json();
    } else if (responseFormat === "text") {
      body = await response.text();
    } else {
      body = await response.arrayBuffer();
    }

    return {
      status: response.status,
      statusText: response.statusText,
      headers: respHeaders,
      body,
    };
  } }.fetch_api;
}
