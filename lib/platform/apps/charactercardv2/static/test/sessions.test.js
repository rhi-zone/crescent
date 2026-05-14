// Tests for ../sessions.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush, fire } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initSessions } from "../sessions.js";

let mock, errors, busy, switched, trapped, released;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = []; switched = []; trapped = []; released = 0;
  busy = false;
});

function makeDeps() {
  return {
    showError: (m) => errors.push(m),
    setBusy: (v) => { busy = v; },
    isBusy: () => busy,
    onSessionSwitch: (d) => switched.push(d),
    trapFocus: (overlay, trigger) => trapped.push({ overlay, trigger }),
    releaseFocus: () => { released++; },
  };
}

describe("sessions.init", () => {
  test("returns { open, close, isOpen, panel, reload, newSession }", () => {
    const api = initSessions(makeDeps());
    for (const k of ["open", "close", "isOpen", "reload", "newSession"]) {
      expect(typeof api[k]).toBe("function");
    }
    expect(api.panel).toBe(document.getElementById("session-panel"));
  });

  test("reload() fetches /api/sessions and renders the list", async () => {
    mock.respond("/api/sessions", () => ({
      status: 200,
      json: {
        sessions: [
          { id: "s1", preview: "hi", created_at: 1700000000 },
          { id: "s2", preview: "there", created_at: 1700000100 },
        ],
        current: "s1",
      },
    }));
    const api = initSessions(makeDeps());
    await api.reload();
    await flush();
    const items = document.querySelectorAll(".session-item");
    expect(items.length).toBe(2);
    expect(items[0].dataset.id).toBe("s1");
    expect(items[0].classList.contains("session-item--active")).toBe(true);
    expect(items[1].classList.contains("session-item--active")).toBe(false);
  });

  test("clicking a non-active session invokes onSessionSwitch with response", async () => {
    mock.respond("/api/sessions", () => ({
      status: 200,
      json: { sessions: [{ id: "s1" }, { id: "s2" }], current: "s1" },
    }));
    mock.respond("/api/session/switch", () => ({
      status: 200, json: { session: { id: "s2" }, messages: [] },
    }));
    const api = initSessions(makeDeps());
    await api.reload();
    await flush();
    const items = document.querySelectorAll(".session-item");
    items[1].click();
    await flush();
    const call = mock.findCall("POST", "/api/session/switch");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ session_id: "s2" });
    expect(switched.length).toBe(1);
    expect(switched[0].session.id).toBe("s2");
  });

  test("newSession() POSTs /api/session/new and invokes onSessionSwitch", async () => {
    mock.respond("/api/session/new", () => ({
      status: 200, json: { session: { id: "new1" }, messages: [] },
    }));
    mock.respond("/api/sessions", () => ({ status: 200, json: { sessions: [], current: "new1" } }));
    const api = initSessions(makeDeps());
    api.newSession();
    await flush();
    const call = mock.findCall("POST", "/api/session/new");
    expect(call).toBeDefined();
    expect(switched.length).toBe(1);
  });

  test("newSession() bails when isBusy() returns true", async () => {
    busy = true;
    const api = initSessions(makeDeps());
    api.newSession();
    await flush();
    expect(mock.findCall("POST", "/api/session/new")).toBeUndefined();
  });

  test("pressing Escape on the panel closes it", async () => {
    mock.respond("/api/sessions", () => ({
      status: 200, json: { sessions: [], current: null },
    }));
    const api = initSessions(makeDeps());
    api.open();
    await flush();
    fire(api.panel, "keydown", { key: "Escape" });
    expect(api.isOpen()).toBe(false);
  });

  test("delete button inside session-item POSTs delete and skips switch path", async () => {
    mock.respond("/api/sessions", () => ({
      status: 200,
      json: { sessions: [{ id: "s1" }], current: "s1" },
    }));
    mock.respond("/api/session/delete", () => ({
      status: 200, json: { current_session_id: null, session: { id: null }, messages: [] },
    }));
    const api = initSessions(makeDeps());
    await api.reload();
    await flush();
    const del = document.querySelector(".session-item__delete");
    del.click();
    await flush();
    const call = mock.findCall("POST", "/api/session/delete");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ session_id: "s1" });
    // Did not also trigger switch.
    expect(mock.findCall("POST", "/api/session/switch")).toBeUndefined();
  });
});
