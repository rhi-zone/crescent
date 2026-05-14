// Tests for ../send.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush, fire } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initSend } from "../send.js";
import { init as initMessages } from "../messages.js";

let mock, errors, sentCount, tokenCount;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = []; sentCount = 0; tokenCount = null;
});

function makeMessages() {
  // Use the real messages module; tests want end-to-end behavior.
  return initMessages({ showError: (m) => errors.push(m) });
}

function makeDeps(messagesHandle) {
  return {
    showError: (m) => errors.push(m),
    messages: messagesHandle,
    onSent: () => { sentCount++; },
    onTokenCount: (d) => { tokenCount = d; },
  };
}

// Build a fake streaming Response — body.getReader yields the given chunks
// in order, then signals done.
function fakeStream(chunks) {
  let i = 0;
  return {
    ok: true,
    status: 200,
    body: {
      getReader() {
        return {
          async read() {
            if (i >= chunks.length) return { done: true, value: undefined };
            return { done: false, value: new TextEncoder().encode(chunks[i++]) };
          },
        };
      },
    },
    async json() { return {}; },
  };
}

describe("send.init", () => {
  test("returns expected shape", () => {
    const messages = makeMessages();
    const api = initSend(makeDeps(messages));
    for (const k of ["send", "continueLast", "impersonate", "setBusy", "isBusy"]) {
      expect(typeof api[k]).toBe("function");
    }
  });

  test("send() reads input, clears it, and toggles busy", async () => {
    // Non-streaming path: server replies with JSON containing user + assistant.
    globalThis.fetch = async (path, opts) => {
      if (path === "/api/message/stream") {
        return {
          ok: false, status: 200,
          async json() { return {
            user: { id: "u1", role: "user", content: "hi" },
            assistant: { id: "a1", role: "assistant", content: "hello" },
          }; },
        };
      }
      throw new Error("unexpected " + path);
    };
    const messages = makeMessages();
    const api = initSend(makeDeps(messages));
    document.getElementById("input").value = "hi";
    await api.send();
    expect(document.getElementById("input").value).toBe("");
    expect(api.isBusy()).toBe(false);
    const list = document.getElementById("message-list");
    expect(list.children.length).toBe(2);
    expect(sentCount).toBe(1);
  });

  test("send() toggles setBusy(true) then (false) during the call", async () => {
    let busyDuring = null;
    globalThis.fetch = async () => {
      // Snapshot busy state at the moment fetch is called.
      busyDuring = api.isBusy();
      return {
        ok: false, status: 200,
        async json() { return { user: null, assistant: null }; },
      };
    };
    const messages = makeMessages();
    const api = initSend(makeDeps(messages));
    document.getElementById("input").value = "hi";
    await api.send();
    expect(busyDuring).toBe(true);
    expect(api.isBusy()).toBe(false);
  });

  test("continueLast() POSTs /api/continue and updates the last message", async () => {
    mock.respond("/api/continue", () => ({
      status: 200, json: { id: "a1", role: "assistant", content: "more" },
    }));
    const messages = makeMessages();
    messages.addMessage({ id: "a1", role: "assistant", content: "before" });
    const api = initSend(makeDeps(messages));
    await api.continueLast();
    await flush();
    expect(mock.findCall("POST", "/api/continue")).toBeDefined();
    const el = messages.findMessageEl("a1");
    expect(el.dataset.rawContent).toBe("more");
    expect(sentCount).toBe(1);
  });

  test("impersonate() POSTs /api/impersonate and fills the input", async () => {
    mock.respond("/api/impersonate", () => ({
      status: 200, json: { content: "as you" },
    }));
    const messages = makeMessages();
    const api = initSend(makeDeps(messages));
    await api.impersonate();
    await flush();
    expect(mock.findCall("POST", "/api/impersonate")).toBeDefined();
    expect(document.getElementById("input").value).toBe("as you");
  });

  test("Enter on the input fires send", async () => {
    let sent = false;
    globalThis.fetch = async () => {
      sent = true;
      return { ok: false, status: 200, async json() { return {}; } };
    };
    const messages = makeMessages();
    initSend(makeDeps(messages));
    document.getElementById("input").value = "hello";
    fire(document.getElementById("input"), "keydown", { key: "Enter" });
    await flush();
    await flush();
    expect(sent).toBe(true);
  });

  test("Shift+Enter does NOT send (newline pass-through)", async () => {
    let sent = false;
    globalThis.fetch = async () => { sent = true; return { ok: true, status: 200, async json() { return {}; } }; };
    const messages = makeMessages();
    initSend(makeDeps(messages));
    document.getElementById("input").value = "hi";
    fire(document.getElementById("input"), "keydown", { key: "Enter", shiftKey: true });
    await flush();
    expect(sent).toBe(false);
  });

  test("streaming: token events append, done event finalizes content", async () => {
    globalThis.fetch = async (path) => {
      if (path !== "/api/message/stream") throw new Error("unexpected " + path);
      const events = [
        'data: {"type":"user","id":"u1","content":"hi"}\n\n',
        'data: {"type":"token","token":"he"}\n\n',
        'data: {"type":"token","token":"llo"}\n\n',
        'data: {"type":"done","id":"a1","content":"hello"}\n\n',
      ];
      return fakeStream(events);
    };
    const messages = makeMessages();
    const api = initSend(makeDeps(messages));
    document.getElementById("input").value = "hi";
    await api.send();
    const list = document.getElementById("message-list");
    expect(list.children.length).toBe(2);
    const assistant = list.children[1];
    expect(assistant.dataset.id).toBe("a1");
    expect(assistant.dataset.rawContent).toBe("hello");
  });

  test("setBusy disables the buttons and toggles the loading indicator", () => {
    const messages = makeMessages();
    const api = initSend(makeDeps(messages));
    api.setBusy(true);
    expect(document.getElementById("btn-send").disabled).toBe(true);
    expect(document.getElementById("btn-continue").disabled).toBe(true);
    expect(document.getElementById("btn-impersonate").disabled).toBe(true);
    expect(document.getElementById("loading").classList.contains("loading-indicator--visible")).toBe(true);
    api.setBusy(false);
    expect(document.getElementById("btn-send").disabled).toBe(false);
    expect(document.getElementById("loading").classList.contains("loading-indicator--visible")).toBe(false);
  });
});
