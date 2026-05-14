// Tests for ../card-state.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initCardState } from "../card-state.js";

let mock, errors, addedMessages, replaced, hasAvatarSet, loadedCard;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  addedMessages = [];
  replaced = null;
  hasAvatarSet = null;
  loadedCard = undefined;
});

function makeMessagesHandle() {
  return {
    addMessage: (m) => { addedMessages.push(m); return m; },
    replaceMessages: (m) => { replaced = m; },
    setHasAvatar: (b) => { hasAvatarSet = b; },
  };
}

function makeDeps(overrides) {
  return {
    showError: (m) => errors.push(m),
    messages: makeMessagesHandle(),
    onCardLoaded: (c) => { loadedCard = c; },
    ...(overrides || {}),
  };
}

describe("card-state.init", () => {
  test("returns reload/getCardWritable/getHasAvatar", () => {
    const api = initCardState(makeDeps());
    expect(typeof api.reload).toBe("function");
    expect(typeof api.getCardWritable).toBe("function");
    expect(typeof api.getHasAvatar).toBe("function");
  });

  test("initially cardWritable is false and hasAvatar is false", () => {
    const api = initCardState(makeDeps());
    expect(api.getCardWritable()).toBe(false);
    expect(api.getHasAvatar()).toBe(false);
  });

  test("reload() fetches /api/card, /api/messages, and HEAD /api/avatar", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "Alice", writable: true } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(mock.findCall("GET", "/api/card")).toBeDefined();
    expect(mock.findCall("GET", "/api/messages")).toBeDefined();
    expect(mock.findCall("HEAD", "/api/avatar")).toBeDefined();
  });

  test("reload() sets cardWritable from the card payload", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "Alice", writable: true } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(api.getCardWritable()).toBe(true);
  });

  test("reload() sets document.title and #card-header-name from the card name", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "Bob" } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(document.title).toBe("Bob");
    expect(document.getElementById("card-header-name").textContent).toBe("Bob");
  });

  test("reload() sets the Edit/Export buttons visible when a card is loaded", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "Bob" } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(document.getElementById("btn-card-header-edit").hidden).toBe(false);
    expect(document.getElementById("btn-card-header-export").hidden).toBe(false);
  });

  test("reload() with no card shows the 'no card loaded' system message", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: null }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 404, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(addedMessages.length).toBe(1);
    expect(addedMessages[0].content).toContain("No card loaded");
    expect(document.getElementById("btn-card-header-edit").hidden).toBe(true);
  });

  test("reload() appends each history message in order when history is non-empty", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "X", greeting: { id: "g", role: "assistant", content: "hi" } } }));
    mock.respond("/api/messages", () => ({
      status: 200,
      json: { messages: [
        { id: "1", role: "user", content: "a" },
        { id: "2", role: "assistant", content: "b" },
      ] },
    }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(addedMessages.map(m => m.id)).toEqual(["1", "2"]);
  });

  test("reload() appends the card greeting only when history is empty", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "X", greeting: { id: "g", role: "assistant", content: "hi" } } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(addedMessages.length).toBe(1);
    expect(addedMessages[0].id).toBe("g");
  });

  test("reload() sets hasAvatar+messages.setHasAvatar to true when HEAD /api/avatar is OK", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "X" } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(api.getHasAvatar()).toBe(true);
    expect(hasAvatarSet).toBe(true);
    expect(document.getElementById("card-avatar").hidden).toBe(false);
  });

  test("reload() hides the avatar when HEAD /api/avatar is not OK", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "X" } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 404, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(api.getHasAvatar()).toBe(false);
    expect(document.getElementById("card-avatar").hidden).toBe(true);
  });

  test("reload() escapes filesystem-unsafe characters in the export filename", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "A/B:C*?" } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(document.getElementById("btn-card-header-export").download).toBe("A_B_C__.png");
  });

  test("reload() fires onCardLoaded with the card after load", async () => {
    mock.respond("/api/card", () => ({ status: 200, json: { name: "Zed" } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    mock.respond("/api/avatar", () => ({ status: 200, json: {} }));
    const api = initCardState(makeDeps());
    await api.reload();
    await flush();
    expect(loadedCard).toEqual({ name: "Zed" });
  });
});
