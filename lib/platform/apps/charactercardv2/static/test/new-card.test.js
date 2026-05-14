// Tests for ../new-card.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initNewCard } from "../new-card.js";

let mock, errors, fallbacks, locationHref;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  fallbacks = 0;
  locationHref = null;
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
  // Capture window.location.href assignments without navigating the test runner.
  try {
    Object.defineProperty(window.location, "href", {
      configurable: true,
      get() { return locationHref || ""; },
      set(v) { locationHref = v; },
    });
  } catch (_) { /* already installed */ }
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
    mock.respond("/api/new-card", () => ({
      status: 200,
      headers: { "content-type": "application/json" },
      json: { launch_url: "/launch/42" },
    }));
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

  test("JSON response with launch_url redirects (create_instance cap path)", async () => {
    mock.respond("/api/new-card", () => ({
      status: 200,
      headers: { "content-type": "application/json" },
      json: { launch_url: "/launch/123" },
    }));
    initNewCard(makeDeps());
    document.getElementById("btn-new-card").click();
    await flush();
    expect(locationHref).toBe("/launch/123");
    expect(fallbacks).toBe(0);
  });

  test("PNG response triggers download and calls onFallbackDownload", async () => {
    mock.respond("/api/new-card", () => ({
      status: 200,
      headers: { "content-type": "image/png" },
      arrayBuffer: new ArrayBuffer(8),
    }));
    initNewCard(makeDeps());
    document.getElementById("btn-new-card").click();
    await flush();
    expect(fallbacks).toBe(1);
    expect(locationHref).toBe(null);
  });
});
