// HTTP helper for the BFF API. Owns: `request()` — fetch + JSON parse +
// uniform error surfacing via an injected `onError` callback. No UI state
// (busy flags, DOM); the caller decides what to do with errors.

/**
 * Make a JSON request against the app's BFF.
 *
 * Returns the parsed JSON body on success, or `null` on transport error or
 * when the response carries a top-level `error` field. On either error path,
 * `opts.onError(message)` is invoked unless `opts.silent` is set.
 *
 * @param {string} method
 * @param {string} path
 * @param {unknown} [body]
 * @param {{ silent?: boolean, onError?: (msg: string) => void }} [opts_]
 * @returns {Promise<any>}
 */
export async function request(method, path, body, opts_) {
  try {
    /** @type {{ method: string, headers: Record<string, string>, body?: string }} */
    const opts = { method, headers: {} };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(path, opts);
    let data = null;
    try { data = await res.json(); } catch (_) { /* non-JSON body */ }
    if (!res.ok) {
      const msg = (data && data.error) || ("HTTP " + res.status);
      if (!opts_?.silent && opts_?.onError) opts_.onError(msg);
      return null;
    }
    if (data && data.error) {
      if (!opts_?.silent && opts_?.onError) opts_.onError(data.error);
      return null;
    }
    return data;
  } catch (e) {
    if (!opts_?.silent && opts_?.onError) {
      opts_.onError(e instanceof Error ? e.message : String(e));
    }
    return null;
  }
}
