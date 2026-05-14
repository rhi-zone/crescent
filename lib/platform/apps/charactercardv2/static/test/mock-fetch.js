// Mock fetch installer for ccv2 frontend tests.
//
// Usage:
//   import { installFetchMock } from "./mock-fetch.js";
//   const mock = installFetchMock();
//   mock.respond("/api/personas", () => ({ status: 200, json: { personas: [], active: "" } }));
//   ... run module code ...
//   expect(mock.calls).toMatchObject([{ method: "GET", path: "/api/personas" }]);
//
// `respond(pattern, fn)` — pattern is a string (exact match) or RegExp; fn
// receives `{ method, path, body }` and returns `{ status, json }` or `{ status,
// text }` or throws to simulate network failure.

export function installFetchMock() {
  const handlers = [];
  const calls = [];
  let defaultResponder = null;

  function findHandler(method, path) {
    for (let i = handlers.length - 1; i >= 0; i--) {
      const h = handlers[i];
      if (h.method && h.method !== method) continue;
      if (h.pattern instanceof RegExp) {
        if (h.pattern.test(path)) return h;
      } else if (typeof h.pattern === "string") {
        if (h.pattern === path) return h;
        if (h.pattern.endsWith("*") && path.startsWith(h.pattern.slice(0, -1))) return h;
      }
    }
    return null;
  }

  globalThis.fetch = async function (path, opts) {
    const method = (opts && opts.method) || "GET";
    let body = null;
    if (opts && opts.body !== undefined) {
      try { body = JSON.parse(opts.body); } catch { body = opts.body; }
    }
    const call = { method, path, body, opts: opts || null };
    calls.push(call);
    const h = findHandler(method, path) || defaultResponder;
    if (!h) {
      throw new Error(`mock-fetch: no handler for ${method} ${path}`);
    }
    let result;
    try {
      result = await h.fn(call);
    } catch (e) {
      throw e;
    }
    if (!result) result = { status: 200, json: {} };
    const status = result.status == null ? 200 : result.status;
    const headers = result.headers || {};
    return {
      ok: status >= 200 && status < 300,
      status,
      statusText: result.statusText || "",
      headers: {
        get(name) { return headers[name.toLowerCase()] || null; },
      },
      async json() {
        if (result.json !== undefined) return result.json;
        if (result.text !== undefined) return JSON.parse(result.text);
        return {};
      },
      async text() {
        if (result.text !== undefined) return result.text;
        if (result.json !== undefined) return JSON.stringify(result.json);
        return "";
      },
      async blob() {
        return { type: "application/octet-stream", size: 0 };
      },
    };
  };

  return {
    calls,
    respond(pattern, fn, method) {
      handlers.push({ pattern, fn, method: method || null });
    },
    respondDefault(fn) { defaultResponder = { fn, pattern: null }; },
    reset() {
      handlers.length = 0;
      calls.length = 0;
      defaultResponder = null;
    },
    findCall(method, pathPredicate) {
      return calls.find(c =>
        c.method === method &&
        (typeof pathPredicate === "string"
          ? c.path === pathPredicate
          : pathPredicate.test(c.path)));
    },
  };
}
