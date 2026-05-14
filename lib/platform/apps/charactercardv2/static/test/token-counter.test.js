// Tests for ../token-counter.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initTokenCounter } from "../token-counter.js";

let mock, errors;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
});

function makeDeps() {
  return { showError: (m) => errors.push(m) };
}

describe("token-counter.init", () => {
  test("returns refresh() and update() functions", () => {
    const api = initTokenCounter(makeDeps());
    expect(typeof api.refresh).toBe("function");
    expect(typeof api.update).toBe("function");
  });

  test("update() writes 'used / max' into #token-count-text and sets fill width", () => {
    const api = initTokenCounter(makeDeps());
    api.update({ context_used: 1024, context_max: 4096 });
    const text = document.getElementById("token-count-text");
    const fill = document.getElementById("token-count-fill");
    expect(text.textContent).toBe("1024 / 4096");
    expect(fill.style.width).toBe("25%");
  });

  test("update() adds --warn class above 50%", () => {
    const api = initTokenCounter(makeDeps());
    api.update({ context_used: 3000, context_max: 4096 });
    const fill = document.getElementById("token-count-fill");
    expect(fill.className).toContain("token-counter__fill--warn");
    expect(fill.className).not.toContain("token-counter__fill--danger");
  });

  test("update() adds --danger class above 80%", () => {
    const api = initTokenCounter(makeDeps());
    api.update({ context_used: 3500, context_max: 4096 });
    const fill = document.getElementById("token-count-fill");
    expect(fill.className).toContain("token-counter__fill--danger");
  });

  test("update() with null data does nothing", () => {
    const api = initTokenCounter(makeDeps());
    api.update(null);
    const text = document.getElementById("token-count-text");
    // index.html default is "0 / 4096" — should be untouched.
    expect(text.textContent).toBe("0 / 4096");
  });

  test("update() defaults context_max to 4096 when missing", () => {
    const api = initTokenCounter(makeDeps());
    api.update({ context_used: 100 });
    expect(document.getElementById("token-count-text").textContent).toBe("100 / 4096");
  });

  test("refresh() GETs /api/token_count and applies the result", async () => {
    mock.respond("/api/token_count", () => ({
      status: 200,
      json: { context_used: 512, context_max: 2048 },
    }));
    const api = initTokenCounter(makeDeps());
    await api.refresh();
    await flush();
    expect(document.getElementById("token-count-text").textContent).toBe("512 / 2048");
    expect(mock.findCall("GET", "/api/token_count")).toBeDefined();
  });
});
