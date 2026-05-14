// Tests for ../lorebook-entry.js — the shared entry-row UI helper.

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { createEntryEl } from "../lorebook-entry.js";

let mock;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
});

const HANDLERS = {
  updateUrl: "/api/lorebook/update",
  deleteUrl: "/api/lorebook/delete",
};

describe("lorebook-entry.createEntryEl", () => {
  test("returns a DOM element with the right shape (toggle, keys, preview, body)", () => {
    const entry = { uid: 7, enabled: true, keys: ["alpha", "beta"], content: "hello world" };
    const el = createEntryEl(entry, HANDLERS);
    expect(el.className).toContain("lorebook-entry");
    expect(el.className).not.toContain("lorebook-entry--disabled");
    expect(el.dataset.uid).toBe("7");
    expect(el.querySelector(".lorebook-entry__toggle")).not.toBeNull();
    const keyTags = el.querySelectorAll(".lorebook-entry__key");
    expect(keyTags.length).toBe(2);
    expect(keyTags[0].textContent).toBe("alpha");
    expect(keyTags[1].textContent).toBe("beta");
    expect(el.querySelector(".lorebook-entry__preview").textContent).toBe("hello world");
    expect(el.querySelector(".lorebook-entry__body")).not.toBeNull();
  });

  test("disabled entry gets the --disabled class and inactive toggle", () => {
    const entry = { uid: 1, enabled: false, keys: ["k"], content: "" };
    const el = createEntryEl(entry, HANDLERS);
    expect(el.className).toContain("lorebook-entry--disabled");
    const toggle = el.querySelector(".lorebook-entry__toggle");
    expect(toggle.className).not.toContain("lorebook-entry__toggle--on");
    expect(toggle.title).toBe("Disabled");
  });

  test("body has editable inputs for keys, content, position, order, constant", () => {
    const entry = { uid: 1, enabled: true, keys: ["k1", "k2"], content: "body", position: 2, order: 5, constant: true };
    const el = createEntryEl(entry, HANDLERS);
    const body = el.querySelector(".lorebook-entry__body");
    expect(body.querySelector('[data-field="keys"]').value).toBe("k1, k2");
    expect(body.querySelector('[data-field="content"]').textContent).toBe("body");
    expect(body.querySelector('[data-field="position"]')).not.toBeNull();
    expect(body.querySelector('[data-field="order"]').value).toBe("5");
    expect(body.querySelector('[data-field="constant"]').checked).toBe(true);
    expect(body.querySelector(".lorebook-entry__save")).not.toBeNull();
    expect(body.querySelector(".lorebook-entry__delete")).not.toBeNull();
  });

  test("clicking toggle POSTs updateUrl with enabled flipped", async () => {
    const entry = { uid: 42, enabled: false, keys: ["k"], content: "" };
    mock.respond("/api/lorebook/update", () => ({ status: 200, json: { ok: true } }));
    const el = createEntryEl(entry, HANDLERS);
    const toggle = el.querySelector(".lorebook-entry__toggle");
    toggle.click();
    await flush();
    const call = mock.findCall("POST", "/api/lorebook/update");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ uid: 42, enabled: true });
  });

  test("delete confirms before POSTing and calls onChange on success", async () => {
    const entry = { uid: 3, enabled: true, keys: ["alpha"], content: "" };
    mock.respond("/api/lorebook/delete", () => ({ status: 200, json: { ok: true } }));
    let changed = 0;
    const el = createEntryEl(entry, { ...HANDLERS, onChange: () => { changed++; } });
    const deleteBtn = el.querySelector(".lorebook-entry__delete");

    window.confirm = () => false;
    deleteBtn.click();
    await flush();
    expect(mock.findCall("POST", "/api/lorebook/delete")).toBeUndefined();
    expect(changed).toBe(0);

    window.confirm = () => true;
    deleteBtn.click();
    await flush();
    const call = mock.findCall("POST", "/api/lorebook/delete");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ uid: 3 });
    expect(changed).toBe(1);
  });

  test("save reads form fields and POSTs updateUrl", async () => {
    const entry = { uid: 11, enabled: true, keys: ["k"], content: "old" };
    mock.respond("/api/lorebook/update", () => ({ status: 200, json: { ok: true } }));
    let changed = 0;
    const el = createEntryEl(entry, { ...HANDLERS, onChange: () => { changed++; } });
    const body = el.querySelector(".lorebook-entry__body");
    body.querySelector('[data-field="keys"]').value = "a, b, c";
    body.querySelector('[data-field="content"]').value = "new content";
    body.querySelector('[data-field="position"]').value = "3";
    body.querySelector('[data-field="order"]').value = "7";
    body.querySelector('[data-field="constant"]').checked = true;
    el.querySelector(".lorebook-entry__save").click();
    await flush();
    const call = mock.findCall("POST", "/api/lorebook/update");
    expect(call).toBeDefined();
    expect(call.body).toEqual({
      uid: 11, keys: ["a", "b", "c"], content: "new content",
      position: 3, order: 7, constant: true,
    });
    expect(changed).toBe(1);
  });

  test("extraBody fields are merged into update + delete payloads", async () => {
    const entry = { uid: 5, enabled: true, keys: ["k"], content: "" };
    mock.respond("/api/lorebook/update", () => ({ status: 200, json: { ok: true } }));
    mock.respond("/api/lorebook/delete", () => ({ status: 200, json: { ok: true } }));
    const el = createEntryEl(entry, { ...HANDLERS, extraBody: { book_id: "b9" } });
    el.querySelector(".lorebook-entry__toggle").click();
    await flush();
    const updateCall = mock.findCall("POST", "/api/lorebook/update");
    expect(updateCall.body).toEqual({ book_id: "b9", uid: 5, enabled: false });

    window.confirm = () => true;
    el.querySelector(".lorebook-entry__delete").click();
    await flush();
    const deleteCall = mock.findCall("POST", "/api/lorebook/delete");
    expect(deleteCall.body).toEqual({ book_id: "b9", uid: 5 });
  });

  test("handles empty entry with missing fields gracefully", () => {
    const entry = { uid: 0, enabled: true };
    const el = createEntryEl(entry, HANDLERS);
    const body = el.querySelector(".lorebook-entry__body");
    expect(body.querySelector('[data-field="keys"]').value).toBe("");
    expect(body.querySelector('[data-field="content"]').textContent).toBe("");
    expect(body.querySelector('[data-field="order"]').value).toBe("0");
    expect(body.querySelector('[data-field="constant"]').checked).toBe(false);
    expect(el.querySelectorAll(".lorebook-entry__key").length).toBe(0);
    expect(el.querySelector(".lorebook-entry__preview").textContent).toBe("");
  });

  test("HTML-escapes special characters in keys and content (no script injection)", () => {
    const entry = {
      uid: 1, enabled: true,
      keys: ['<script>alert("x")</script>', 'k&v'],
      content: '<script>alert("xss")</script> & "quotes"',
    };
    const el = createEntryEl(entry, HANDLERS);
    // The header preview/key tags use textContent — already safe — but verify
    // they render literal text, not parsed HTML.
    const keyTags = el.querySelectorAll(".lorebook-entry__key");
    expect(keyTags[0].textContent).toBe('<script>alert("x")</script>');
    // No <script> element was created anywhere in the row.
    expect(el.querySelector("script")).toBeNull();
    // The body input/textarea round-trips through escAttr/escHtml — the
    // textarea's textContent (decoded entities) should contain the literal
    // <script> string, proving the HTML was escaped at injection time.
    const body = el.querySelector(".lorebook-entry__body");
    const contentArea = body.querySelector('[data-field="content"]');
    expect(contentArea.textContent).toContain("<script>");
    expect(contentArea.textContent).toContain('"xss"');
  });
});
