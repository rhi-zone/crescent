// Tests for ../my-lorebooks.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initMyLore } from "../my-lorebooks.js";

let mock, errors, trapped, released;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = []; trapped = []; released = 0;
});

function makeDeps() {
  return {
    showError: (m) => errors.push(m),
    trapFocus: (overlay, trigger) => trapped.push({ overlay, trigger }),
    releaseFocus: () => { released++; },
  };
}

describe("my-lorebooks.init", () => {
  test("returns { open, close, isOpen, overlay, reload }", () => {
    const api = initMyLore(makeDeps());
    for (const k of ["open", "close", "isOpen", "reload"]) {
      expect(typeof api[k]).toBe("function");
    }
    expect(api.overlay).toBe(document.getElementById("my-lorebooks-overlay"));
  });

  test("reload() GETs /api/user_lorebooks and renders the book list", async () => {
    mock.respond("/api/user_lorebooks", () => ({
      status: 200,
      json: { books: [
        { id: "b1", name: "Book One", active: true, entry_count: 3 },
        { id: "b2", name: "Book Two", active: false, entry_count: 0 },
      ] },
    }));
    const api = initMyLore(makeDeps());
    await api.reload();
    await flush();
    const rows = document.querySelectorAll(".book-row");
    expect(rows.length).toBe(2);
    expect(rows[0].dataset.id).toBe("b1");
    expect(rows[0].querySelector(".book-row__name").textContent).toBe("Book One");
  });

  test("creating a new book POSTs to /api/user_lorebooks", async () => {
    mock.respond("/api/user_lorebooks", (call) => {
      if (call.method === "POST") return { status: 200, json: { id: "newb", name: call.body.name } };
      return { status: 200, json: { books: [] } };
    });
    window.prompt = () => "Fresh";
    initMyLore(makeDeps());
    document.getElementById("my-lorebooks-new").click();
    await flush();
    const call = mock.calls.find(c => c.method === "POST" && c.path === "/api/user_lorebooks");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ name: "Fresh" });
  });

  test("selecting a book triggers GET entries and renders one row per entry", async () => {
    mock.respond("/api/user_lorebooks", () => ({
      status: 200,
      json: { books: [{ id: "b1", name: "B1", active: true, entry_count: 2 }] },
    }));
    mock.respond(/^\/api\/user_lorebooks\/entries/, () => ({
      status: 200,
      json: { name: "B1", entries: [
        { uid: 1, enabled: true, keys: ["k"], content: "c1" },
        { uid: 2, enabled: false, keys: ["k2"], content: "c2" },
      ] },
    }));
    const api = initMyLore(makeDeps());
    await api.reload();
    await flush();
    const row = document.querySelector(".book-row");
    row.click();
    await flush();
    const bookBody = document.getElementById("book-detail-body");
    const entryEls = bookBody.querySelectorAll(".lorebook-entry");
    expect(entryEls.length).toBe(2);
    expect(entryEls[0].dataset.uid).toBe("1");
    expect(entryEls[1].dataset.uid).toBe("2");
  });

  test("toggling a book's active POSTs to /api/user_lorebooks/toggle", async () => {
    mock.respond("/api/user_lorebooks", () => ({
      status: 200,
      json: { books: [{ id: "b1", name: "B1", active: false, entry_count: 0 }] },
    }));
    mock.respond("/api/user_lorebooks/toggle", () => ({ status: 200, json: { ok: true } }));
    const api = initMyLore(makeDeps());
    await api.reload();
    await flush();
    const toggle = document.querySelector(".book-row .lorebook-entry__toggle");
    toggle.click();
    await flush();
    const call = mock.findCall("POST", "/api/user_lorebooks/toggle");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ id: "b1", active: true });
  });

  test("adding an entry POSTs /api/user_lorebooks/entry/add with selected book_id", async () => {
    mock.respond("/api/user_lorebooks", () => ({
      status: 200,
      json: { books: [{ id: "b1", name: "B1", active: true, entry_count: 0 }] },
    }));
    mock.respond(/^\/api\/user_lorebooks\/entries/, () => ({
      status: 200, json: { name: "B1", entries: [] },
    }));
    mock.respond("/api/user_lorebooks/entry/add", () => ({ status: 200, json: { ok: true } }));
    const api = initMyLore(makeDeps());
    await api.reload();
    await flush();
    document.querySelector(".book-row").click();
    await flush();
    document.getElementById("book-detail-add").click();
    await flush();
    const call = mock.findCall("POST", "/api/user_lorebooks/entry/add");
    expect(call).toBeDefined();
    expect(call.body.book_id).toBe("b1");
    expect(call.body.keys).toEqual(["new keyword"]);
  });

  test("deleting a book confirms before POSTing", async () => {
    mock.respond("/api/user_lorebooks", () => ({
      status: 200,
      json: { books: [{ id: "b1", name: "B1", active: true, entry_count: 0 }] },
    }));
    mock.respond("/api/user_lorebooks/delete", () => ({ status: 200, json: { ok: true } }));
    const api = initMyLore(makeDeps());
    await api.reload();
    await flush();
    window.confirm = () => false;
    document.querySelector(".book-row__delete").click();
    await flush();
    expect(mock.findCall("POST", "/api/user_lorebooks/delete")).toBeUndefined();

    window.confirm = () => true;
    document.querySelector(".book-row__delete").click();
    await flush();
    const call = mock.findCall("POST", "/api/user_lorebooks/delete");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ id: "b1" });
  });
});
