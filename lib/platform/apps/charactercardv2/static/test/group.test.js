// Tests for ../group.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initGroup } from "../group.js";

let mock, errors, trapped, released;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  trapped = []; released = 0;
});

function makeDeps() {
  return {
    showError: (m) => errors.push(m),
    trapFocus: (overlay, trigger) => trapped.push({ overlay, trigger }),
    releaseFocus: () => { released++; },
  };
}

describe("group.init", () => {
  test("returns { open, close, isOpen, overlay }", () => {
    const api = initGroup(makeDeps());
    expect(typeof api.open).toBe("function");
    expect(typeof api.close).toBe("function");
    expect(typeof api.isOpen).toBe("function");
    expect(api.overlay).toBe(document.getElementById("group-overlay"));
  });

  test("open() unhides overlay, calls trapFocus", async () => {
    mock.respond("/api/group", () => ({
      status: 200,
      json: { enabled: false, turn_order: "round_robin", members: [] },
    }));
    const api = initGroup(makeDeps());
    api.overlay.hidden = true;
    api.open();
    expect(api.overlay.hidden).toBe(false);
    expect(trapped.length).toBe(1);
    expect(trapped[0].overlay).toBe(api.overlay);
    await flush();
  });

  test("close() hides overlay and calls releaseFocus", () => {
    const api = initGroup(makeDeps());
    api.overlay.hidden = false;
    api.close();
    expect(api.overlay.hidden).toBe(true);
    expect(released).toBe(1);
  });

  test("isOpen() reflects overlay.hidden", () => {
    const api = initGroup(makeDeps());
    api.overlay.hidden = true;
    expect(api.isOpen()).toBe(false);
    api.overlay.hidden = false;
    expect(api.isOpen()).toBe(true);
  });

  test("clicking add button POSTs to /api/group/add with card_json", async () => {
    mock.respond("/api/group/add", () => ({ status: 200, json: { members: [] } }));
    initGroup(makeDeps());
    document.getElementById("group-add-json").value = '{"name":"foo"}';
    document.getElementById("group-add-btn").click();
    await flush();
    const call = mock.findCall("POST", "/api/group/add");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ card_json: '{"name":"foo"}' });
  });
});
