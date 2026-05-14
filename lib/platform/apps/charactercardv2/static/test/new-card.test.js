// Tests for ../new-card.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initNewCard } from "../new-card.js";

let mock, errors, fallbacks;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  fallbacks = 0;
  // Polyfill: Blob isn't on the mock DOM; provide a minimal stub.
  if (typeof globalThis.Blob === "undefined") {
    globalThis.Blob = class { constructor(parts, opts) { this.parts = parts; this.type = opts?.type || ""; } };
  }
  // Override real Bun URL — the fallback path calls createObjectURL on a
  // mock Blob shape that the runtime rejects.
  globalThis.URL = {
    createObjectURL: () => "blob:mock",
    revokeObjectURL: () => {},
  };
});

function makeDeps() {
  return {
    showError: (m) => errors.push(m),
    onFallbackDownload: () => { fallbacks++; },
  };
}

describe("new-card.init", () => {
  test("returns an empty object", () => {
    const api = initNewCard(makeDeps());
    expect(typeof api).toBe("object");
  });

  test("clicking #btn-new-card POSTs /api/new-card", async () => {
    mock.respond("/api/new-card", () => ({ status: 200, json: {} }));
    mock.respond("/api/apps", () => ({ status: 200, json: { launch_url: "http://x/" } }));
    initNewCard(makeDeps());
    document.getElementById("btn-new-card").click();
    await flush();
    expect(mock.findCall("POST", "/api/new-card")).toBeDefined();
  });

  test("non-OK /api/new-card surfaces the server error message", async () => {
    mock.respond("/api/new-card", () => ({
      status: 500,
      json: { error: "boom" },
    }));
    initNewCard(makeDeps());
    document.getElementById("btn-new-card").click();
    await flush();
    expect(errors).toContain("boom");
  });

  test("on success, attempts cross-origin install to /api/apps", async () => {
    mock.respond("/api/new-card", () => ({ status: 200, json: {} }));
    mock.respond("/api/apps", () => ({ status: 200, json: { launch_url: "http://x/launch" } }));
    initNewCard(makeDeps());
    document.getElementById("btn-new-card").click();
    await flush();
    expect(mock.findCall("POST", "/api/apps")).toBeDefined();
  });

  test("when /api/apps fails, falls back to download and calls onFallbackDownload", async () => {
    mock.respond("/api/new-card", () => ({ status: 200, json: {} }));
    mock.respond("/api/apps", () => { throw new Error("cross-origin blocked"); });
    initNewCard(makeDeps());
    document.getElementById("btn-new-card").click();
    await flush();
    expect(fallbacks).toBe(1);
  });
});
