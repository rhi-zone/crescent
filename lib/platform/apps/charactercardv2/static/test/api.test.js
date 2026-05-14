// Tests for ../api.js — request() helper.
//
// Aspirational behavior is documented per-case. Failing tests should NOT be
// adjusted to match bugs; fix the bug or leave a FAILING comment + TODO entry.

import { describe, test, expect, beforeEach } from "bun:test";
import { resetDOM } from "./dom.js";
import { installFetchMock } from "./mock-fetch.js";
import { request } from "../api.js";

let mock;
beforeEach(() => {
  resetDOM("<html><body></body></html>");
  mock = installFetchMock();
});

describe("api.request", () => {
  test("returns parsed JSON on 200", async () => {
    mock.respond("/api/x", () => ({ status: 200, json: { hello: "world" } }));
    const data = await request("GET", "/api/x");
    expect(data).toEqual({ hello: "world" });
  });

  test("returns null and calls onError on top-level {error}", async () => {
    mock.respond("/api/x", () => ({ status: 200, json: { error: "boom" } }));
    const errs = [];
    const data = await request("GET", "/api/x", undefined, { onError: (m) => errs.push(m) });
    expect(data).toBeNull();
    expect(errs).toEqual(["boom"]);
  });

  test("silent: true suppresses the onError callback on error payload", async () => {
    mock.respond("/api/x", () => ({ status: 200, json: { error: "boom" } }));
    const errs = [];
    const data = await request("GET", "/api/x", undefined, { onError: (m) => errs.push(m), silent: true });
    expect(data).toBeNull();
    expect(errs).toEqual([]);
  });

  test("network failure (fetch throws) returns null and calls onError", async () => {
    mock.respond("/api/x", () => { throw new Error("network down"); });
    const errs = [];
    const data = await request("GET", "/api/x", undefined, { onError: (m) => errs.push(m) });
    expect(data).toBeNull();
    expect(errs).toEqual(["network down"]);
  });

  // FAILING: api.request does not currently treat non-2xx HTTP status as an
  // error — it tries to parse the body and returns whatever JSON it gets,
  // regardless of status. Aspirational behavior: a 500 with no `error` field
  // should still surface as an error. See TODO.md entry.
  test("non-2xx HTTP status surfaces as error", async () => {
    mock.respond("/api/x", () => ({ status: 500, json: { message: "server failed" } }));
    const errs = [];
    const data = await request("GET", "/api/x", undefined, { onError: (m) => errs.push(m) });
    expect(data).toBeNull();
    expect(errs.length).toBe(1);
  });

  test("POST with body sets Content-Type and serializes JSON", async () => {
    mock.respond("/api/x", () => ({ status: 200, json: { ok: 1 } }));
    await request("POST", "/api/x", { a: 1 });
    const call = mock.calls[0];
    expect(call.method).toBe("POST");
    expect(call.body).toEqual({ a: 1 });
    expect(call.opts.headers["Content-Type"]).toBe("application/json");
  });

  test("GET with no body sends no body or content-type", async () => {
    mock.respond("/api/x", () => ({ status: 200, json: {} }));
    await request("GET", "/api/x");
    const call = mock.calls[0];
    expect(call.opts.body).toBeUndefined();
  });
});
