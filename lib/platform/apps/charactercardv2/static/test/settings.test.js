// Tests for ../settings.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush, fire } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initSettings } from "../settings.js";

let mock, errors, personaReloadCalls, trapped, released;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  personaReloadCalls = 0;
  trapped = []; released = 0;
});

function makeDeps() {
  return {
    showError: (m) => errors.push(m),
    persona: { reload: () => { personaReloadCalls++; } },
    trapFocus: (overlay, trigger) => trapped.push({ overlay, trigger }),
    releaseFocus: () => { released++; },
  };
}

describe("settings.init", () => {
  test("returns { open, close, isOpen, overlay, reload }", () => {
    const api = initSettings(makeDeps());
    for (const k of ["open", "close", "isOpen", "reload"]) {
      expect(typeof api[k]).toBe("function");
    }
    expect(api.overlay).toBe(document.getElementById("settings-overlay"));
  });

  test("slider input updates the live value label", () => {
    initSettings(makeDeps());
    const slider = document.getElementById("set-temperature");
    const label = document.getElementById("val-temperature");
    slider.value = "0.7";
    fire(slider, "input");
    expect(label.textContent).toBe("0.7");
  });

  test("Save POSTs all setting values to /api/settings", async () => {
    mock.respond("/api/settings", () => ({ status: 200, json: { temperature: 0.5 } }));
    initSettings(makeDeps());
    document.getElementById("set-temperature").value = "0.5";
    document.getElementById("set-top_p").value = "0.9";
    document.getElementById("set-max_tokens").value = "1024";
    document.getElementById("settings-save").click();
    await flush();
    const call = mock.findCall("POST", "/api/settings");
    expect(call).toBeDefined();
    expect(call.body.temperature).toBe(0.5);
    expect(call.body.top_p).toBe(0.9);
    expect(call.body.max_tokens).toBe(1024);
  });

  test("Test Connection POSTs to /api/connection/test and shows success", async () => {
    mock.respond("/api/connection/test", () => ({
      status: 200,
      json: { success: true, latency_ms: 42, response: "pong" },
    }));
    initSettings(makeDeps());
    document.getElementById("btn-test-connection").click();
    await flush();
    const call = mock.findCall("POST", "/api/connection/test");
    expect(call).toBeDefined();
    const result = document.getElementById("connection-result");
    expect(result.textContent).toContain("Connected");
    expect(result.textContent).toContain("42");
  });

  test("Test Connection shows error on failure payload", async () => {
    mock.respond("/api/connection/test", () => ({
      status: 200,
      json: { success: false, error: "auth failed" },
    }));
    initSettings(makeDeps());
    document.getElementById("btn-test-connection").click();
    await flush();
    const result = document.getElementById("connection-result");
    expect(result.textContent).toContain("Failed");
    expect(result.textContent).toContain("auth failed");
  });

  test("open() invokes persona.reload()", () => {
    const api = initSettings(makeDeps());
    api.open();
    expect(personaReloadCalls).toBe(1);
    expect(trapped.length).toBe(1);
  });

  test("close() releases focus", () => {
    const api = initSettings(makeDeps());
    api.close();
    expect(released).toBe(1);
    expect(api.overlay.hidden).toBe(true);
  });
});
