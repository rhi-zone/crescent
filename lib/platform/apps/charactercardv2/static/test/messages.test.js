// Tests for ../messages.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initMessages } from "../messages.js";

let mock, errors, busy, reloadBelowCount, tokenStaleCount;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  busy = false;
  reloadBelowCount = 0;
  tokenStaleCount = 0;
});

function makeDeps(overrides) {
  return {
    showError: (m) => errors.push(m),
    isBusy: () => busy,
    setBusy: (v) => { busy = v; },
    onReloadBelow: () => { reloadBelowCount++; },
    onTokenCountStale: () => { tokenStaleCount++; },
    ...(overrides || {}),
  };
}

describe("messages.init", () => {
  test("returns the expected shape", () => {
    const api = initMessages(makeDeps());
    for (const k of [
      "addMessage", "replaceMessages", "updateMessage", "setMessageContent",
      "updateSwipeUI", "siblingIndex", "siblingCount", "findMessageEl",
      "removeMessagesFrom", "setHasAvatar", "clear", "scrollToBottom",
    ]) {
      expect(typeof api[k]).toBe("function");
    }
  });

  test("addMessage appends a .message--<role> element", () => {
    const api = initMessages(makeDeps());
    const el = api.addMessage({ role: "user", content: "hi" });
    expect(el).toBeDefined();
    expect(el.classList.contains("message--user")).toBe(true);
    const list = document.getElementById("message-list");
    expect(list.children.length).toBe(1);
    expect(list.children[0]).toBe(el);
  });

  test("setMessageContent renders markdown into .message__content", () => {
    const api = initMessages(makeDeps());
    const el = api.addMessage({ role: "user", content: "plain" });
    api.setMessageContent(el, "**bold**");
    const contentEl = el.querySelector(".message__content");
    // renderMarkdown returns <strong>bold</strong> wrapped in a <p> or similar.
    expect(contentEl.innerHTML).toContain("<strong>");
    expect(contentEl.innerHTML).toContain("bold");
    expect(el.dataset.rawContent).toBe("**bold**");
  });

  test("replaceMessages clears the list and rebuilds it", () => {
    const api = initMessages(makeDeps());
    api.addMessage({ role: "user", content: "first" });
    api.replaceMessages([
      { role: "user", content: "a" },
      { role: "assistant", content: "b" },
    ]);
    const list = document.getElementById("message-list");
    expect(list.children.length).toBe(2);
    expect(list.children[0].classList.contains("message--user")).toBe(true);
    expect(list.children[1].classList.contains("message--assistant")).toBe(true);
  });

  test("clicking [data-action=edit] enters edit mode with raw text", async () => {
    const api = initMessages(makeDeps());
    const el = api.addMessage({ id: "m1", role: "assistant", content: "**raw**" });
    const editBtn = el.querySelector('[data-action="edit"]');
    editBtn.click();
    await flush();
    expect(el.classList.contains("message--editing")).toBe(true);
    const textarea = el.querySelector(".message__edit-textarea");
    expect(textarea).toBeDefined();
    expect(textarea.value).toBe("**raw**");
  });

  test("edit save POSTs to /api/message/edit and updates inline", async () => {
    mock.respond("/api/message/edit", () => ({
      status: 200, json: { id: "m1", content: "**new**" },
    }));
    const api = initMessages(makeDeps());
    const el = api.addMessage({ id: "m1", role: "assistant", content: "old" });
    el.querySelector('[data-action="edit"]').click();
    await flush();
    const textarea = el.querySelector(".message__edit-textarea");
    textarea.value = "**new**";
    el.querySelector(".message__edit-button--save").click();
    await flush();
    const call = mock.findCall("POST", "/api/message/edit");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ message_id: "m1", content: "**new**" });
    expect(el.classList.contains("message--editing")).toBe(false);
    expect(el.dataset.rawContent).toBe("**new**");
    expect(tokenStaleCount).toBe(1);
  });

  test("edit cancel restores focus to the edit button", async () => {
    const api = initMessages(makeDeps());
    const el = api.addMessage({ id: "m1", role: "assistant", content: "old" });
    const editBtn = el.querySelector('[data-action="edit"]');
    editBtn.click();
    await flush();
    el.querySelector(".message__edit-button--cancel").click();
    await flush();
    expect(el.classList.contains("message--editing")).toBe(false);
    expect(document.activeElement).toBe(editBtn);
  });

  test("delete confirms before POSTing", async () => {
    mock.respond("/api/message/delete", () => ({ status: 200, json: { ok: true } }));
    const api = initMessages(makeDeps());
    const el = api.addMessage({ id: "m1", role: "user", content: "x" });
    // User cancels — no POST.
    window.confirm = () => false;
    el.querySelector('[data-action="delete"]').click();
    await flush();
    expect(mock.findCall("POST", "/api/message/delete")).toBeUndefined();
    // User confirms — POST fires.
    window.confirm = () => true;
    el.querySelector('[data-action="delete"]').click();
    await flush();
    const call = mock.findCall("POST", "/api/message/delete");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ message_id: "m1" });
    expect(tokenStaleCount).toBe(1);
  });

  test("swipe prev navigates within cached siblings", async () => {
    mock.respond(/^\/api\/swipes/, () => ({
      status: 200,
      json: {
        swipes: [
          { id: "s0", content: "first", index: 0 },
          { id: "s1", content: "second", index: 1 },
        ],
        current: 1,
      },
    }));
    mock.respond("/api/branch/navigate", () => ({ status: 200, json: { ok: true } }));
    mock.respond("/api/messages", () => ({
      status: 200, json: { messages: [{ id: "s0", role: "assistant", content: "first" }] },
    }));
    const api = initMessages(makeDeps());
    const el = api.addMessage({
      id: "s1", role: "assistant", content: "second",
      sibling_index: 1, sibling_count: 2,
    });
    el.querySelector('[data-dir="prev"]').click();
    for (let i = 0; i < 6; i++) await flush();
    expect(mock.findCall("GET", /^\/api\/swipes/)).toBeDefined();
    expect(mock.findCall("POST", "/api/branch/navigate")).toBeDefined();
    // After navigate the message_id should now be s0.
    expect(el.dataset.id).toBe("s0");
  });

  test("swipe next past end POSTs to /api/swipe/new", async () => {
    mock.respond(/^\/api\/swipes/, () => ({
      status: 200,
      json: { swipes: [{ id: "s0", content: "only", index: 0 }], current: 0 },
    }));
    mock.respond("/api/swipe/new", () => ({
      status: 200, json: { id: "s1", content: "new sibling", sibling_index: 1, sibling_count: 2 },
    }));
    const api = initMessages(makeDeps());
    const el = api.addMessage({
      id: "s0", role: "assistant", content: "only",
      sibling_index: 0, sibling_count: 1,
    });
    el.querySelector('[data-dir="next"]').click();
    for (let i = 0; i < 6; i++) await flush();
    expect(mock.findCall("POST", "/api/swipe/new")).toBeDefined();
    expect(el.dataset.id).toBe("s1");
  });

  // FAILING: sibling cache is keyed by the message's current id, which changes
  // after navigation. Second swipe after navigating refetches because the new
  // active id has no cache entry. See TODO.md frontend test regressions.
  test("sibling cache: second swipe in either direction does not refetch /api/swipes", async () => {
    let swipesCalls = 0;
    mock.respond(/^\/api\/swipes/, () => {
      swipesCalls++;
      return {
        status: 200,
        json: {
          swipes: [
            { id: "s0", content: "first", index: 0 },
            { id: "s1", content: "second", index: 1 },
            { id: "s2", content: "third", index: 2 },
          ],
          current: 2,
        },
      };
    });
    mock.respond("/api/branch/navigate", () => ({ status: 200, json: { ok: true } }));
    mock.respond("/api/messages", () => ({ status: 200, json: { messages: [] } }));
    const api = initMessages(makeDeps());
    const el = api.addMessage({
      id: "s2", role: "assistant", content: "third",
      sibling_index: 2, sibling_count: 3,
    });
    el.querySelector('[data-dir="prev"]').click();
    for (let i = 0; i < 6; i++) await flush();
    el.querySelector('[data-dir="prev"]').click();
    for (let i = 0; i < 6; i++) await flush();
    expect(swipesCalls).toBe(1);
  });

  test("group speaker: sets .message__speaker textContent and a background color", () => {
    const api = initMessages(makeDeps());
    const el = api.addMessage({
      role: "assistant", content: "hi", speaker: "Alice",
    });
    const speakerEl = el.querySelector(".message__speaker");
    expect(speakerEl.textContent).toBe("Alice");
    expect(speakerEl.hidden).toBe(false);
    // Background is set from the palette (non-empty).
    expect(el.style.background).toBeDefined();
    expect(String(el.style.background)).not.toBe("");
  });

  test("group avatar alt: setHasAvatar(true) + speaker -> 'Name avatar'", () => {
    const api = initMessages(makeDeps());
    api.setHasAvatar(true);
    const el = api.addMessage({
      role: "assistant", content: "hi", speaker: "Bob",
    });
    const avatar = el.querySelector(".message__avatar");
    expect(avatar.getAttribute("alt")).toBe("Bob avatar");
    expect(avatar.hidden).toBe(false);
  });

  test("updateMessage rewrites content and id", () => {
    const api = initMessages(makeDeps());
    const el = api.addMessage({ id: "old", role: "assistant", content: "x" });
    api.updateMessage(el, { id: "new", content: "y", role: "assistant" });
    expect(el.dataset.id).toBe("new");
    expect(el.dataset.rawContent).toBe("y");
  });

  test("reload_below edit triggers onReloadBelow", async () => {
    mock.respond("/api/message/edit", () => ({
      status: 200, json: { id: "m2", content: "forked", reload_below: true },
    }));
    const api = initMessages(makeDeps());
    const a = api.addMessage({ id: "m1", role: "user", content: "u" });
    const b = api.addMessage({ id: "m2", role: "assistant", content: "before" });
    const c = api.addMessage({ id: "m3", role: "assistant", content: "below" });
    b.querySelector('[data-action="edit"]').click();
    await flush();
    b.querySelector(".message__edit-textarea").value = "forked";
    b.querySelector(".message__edit-button--save").click();
    await flush();
    expect(reloadBelowCount).toBe(1);
    // c should be removed (below the edited message).
    const list = document.getElementById("message-list");
    expect(list.children.length).toBe(2);
  });
});
