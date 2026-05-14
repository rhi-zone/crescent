// Tests for ../chat-export.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initChatExport } from "../chat-export.js";

let mock, errors;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  // Override real Bun URL with a benign stub: tests inspect fetch calls,
  // not the URL.createObjectURL output.
  globalThis.URL = {
    createObjectURL: () => "blob:mock",
    revokeObjectURL: () => {},
  };
});

function makeDeps() {
  return { showError: (m) => errors.push(m) };
}

describe("chat-export.init", () => {
  test("returns exportChat()", () => {
    const api = initChatExport(makeDeps());
    expect(typeof api.exportChat).toBe("function");
  });

  test("exportChat('text') GETs /api/export/chat?format=text", async () => {
    mock.respond(/\/api\/export\/chat/, () => ({ status: 200, json: {} }));
    const api = initChatExport(makeDeps());
    await api.exportChat("text");
    await flush();
    const call = mock.findCall("GET", /\/api\/export\/chat\?format=text/);
    expect(call).toBeDefined();
  });

  test("exportChat('json') GETs /api/export/chat?format=json", async () => {
    mock.respond(/\/api\/export\/chat/, () => ({ status: 200, json: {} }));
    const api = initChatExport(makeDeps());
    await api.exportChat("json");
    await flush();
    const call = mock.findCall("GET", /\/api\/export\/chat\?format=json/);
    expect(call).toBeDefined();
  });

  test("clicking #btn-card-header-export-chat triggers exportChat using prompt() result", async () => {
    mock.respond(/\/api\/export\/chat/, () => ({ status: 200, json: {} }));
    window.prompt = () => "json";
    initChatExport(makeDeps());
    document.getElementById("btn-card-header-export-chat").click();
    await flush();
    expect(mock.findCall("GET", /\/api\/export\/chat\?format=json/)).toBeDefined();
  });

  test("clicking the button when prompt returns null cancels the export", async () => {
    mock.respond(/\/api\/export\/chat/, () => ({ status: 200, json: {} }));
    window.prompt = () => null;
    initChatExport(makeDeps());
    document.getElementById("btn-card-header-export-chat").click();
    await flush();
    expect(mock.findCall("GET", /\/api\/export\/chat/)).toBeUndefined();
  });

  test("prompt returning anything other than 'json' is treated as 'text'", async () => {
    mock.respond(/\/api\/export\/chat/, () => ({ status: 200, json: {} }));
    window.prompt = () => "yaml";
    initChatExport(makeDeps());
    document.getElementById("btn-card-header-export-chat").click();
    await flush();
    expect(mock.findCall("GET", /\/api\/export\/chat\?format=text/)).toBeDefined();
  });

  test("non-OK response calls showError", async () => {
    mock.respond(/\/api\/export\/chat/, () => ({ status: 500, json: {} }));
    const api = initChatExport(makeDeps());
    await api.exportChat("text");
    await flush();
    expect(errors.length).toBeGreaterThan(0);
  });
});
