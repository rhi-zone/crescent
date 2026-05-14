// Tests for ../card-lorebook.js init() — card-side lorebook tab.

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initCardLore } from "../card-lorebook.js";

let mock, errors, writable;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
  writable = true;
});

function makeDeps() {
  return {
    showError: (m) => errors.push(m),
    getCardWritable: () => writable,
  };
}

describe("card-lorebook.init", () => {
  test("returns { reload }", () => {
    const api = initCardLore(makeDeps());
    expect(typeof api.reload).toBe("function");
  });

  test("reload() fetches /api/lorebook AND /api/linked_lorebooks and populates both sections", async () => {
    mock.respond("/api/lorebook", () => ({
      status: 200,
      json: { entries: [
        { uid: 1, enabled: true, keys: ["k"], content: "c1" },
        { uid: 2, enabled: false, keys: ["k2"], content: "c2" },
      ] },
    }));
    mock.respond("/api/linked_lorebooks", () => ({
      status: 200,
      json: {
        books: [{ name: "Linked One", entry_count: 1 }],
        entries: [[{ uid: 99, enabled: true, keys: ["lk"], content: "lcontent" }]],
      },
    }));
    const api = initCardLore(makeDeps());
    await api.reload();
    await flush();
    expect(mock.findCall("GET", "/api/lorebook")).toBeDefined();
    expect(mock.findCall("GET", "/api/linked_lorebooks")).toBeDefined();
    const entries = document.querySelectorAll("#lorebook-list .lorebook-entry");
    expect(entries.length).toBe(2);
    const linked = document.querySelectorAll("#linked-lorebooks-list .linked-lorebook");
    expect(linked.length).toBe(1);
    expect(linked[0].querySelector(".linked-lorebook__name").textContent).toBe("Linked One");
  });

  test("#lorebook-add POSTs a new entry, then reloads", async () => {
    let addCount = 0;
    mock.respond("/api/lorebook", () => ({
      status: 200, json: { entries: [] },
    }));
    mock.respond("/api/lorebook/add", () => {
      addCount++;
      return { status: 200, json: { ok: true } };
    });
    mock.respond("/api/linked_lorebooks", () => ({
      status: 200, json: { books: [], entries: [] },
    }));
    initCardLore(makeDeps());
    document.getElementById("lorebook-add").click();
    await flush();
    expect(addCount).toBe(1);
    const call = mock.findCall("POST", "/api/lorebook/add");
    expect(call.body).toEqual({ keys: ["new keyword"], content: "" });
    // Reload triggered.
    expect(mock.findCall("GET", "/api/lorebook")).toBeDefined();
  });

  test("when getCardWritable() returns false, #lorebook-notice is visible with explanation", async () => {
    writable = false;
    mock.respond("/api/lorebook", () => ({ status: 200, json: { entries: [] } }));
    mock.respond("/api/linked_lorebooks", () => ({ status: 200, json: { books: [], entries: [] } }));
    const api = initCardLore(makeDeps());
    await api.reload();
    await flush();
    const notice = document.getElementById("lorebook-notice");
    expect(notice.hidden).toBe(false);
    expect(notice.textContent).toContain("Read-only");
    expect(notice.textContent).toContain("self_write");
  });

  test("when getCardWritable() returns true, #lorebook-notice is hidden", async () => {
    writable = true;
    mock.respond("/api/lorebook", () => ({ status: 200, json: { entries: [] } }));
    mock.respond("/api/linked_lorebooks", () => ({ status: 200, json: { books: [], entries: [] } }));
    const api = initCardLore(makeDeps());
    await api.reload();
    await flush();
    const notice = document.getElementById("lorebook-notice");
    expect(notice.hidden).toBe(true);
  });

  test("adding a linked lorebook via file upload POSTs to /api/linked_lorebooks/import with the file contents", async () => {
    mock.respond("/api/linked_lorebooks", () => ({ status: 200, json: { books: [], entries: [] } }));
    mock.respond("/api/linked_lorebooks/import", () => ({ status: 200, json: { ok: true } }));
    initCardLore(makeDeps());
    const fileInput = document.getElementById("linked-lorebooks-file");
    const payload = { name: "From File", source: "https://example.test/lb.json", entries: [{ uid: 1, enabled: true, keys: ["k"], content: "c" }] };
    const text = JSON.stringify(payload);
    fileInput.files = [{ name: "from-file.lorebook.json", text: async () => text }];
    fileInput.dispatchEvent(new Event("change", { bubbles: true }));
    await flush();
    const call = mock.findCall("POST", "/api/linked_lorebooks/import");
    expect(call).toBeDefined();
    expect(call.body.name).toBe("From File");
    expect(call.body.source).toBe("https://example.test/lb.json");
    expect(call.body.entries).toEqual(payload.entries);
  });

  test("removing a linked lorebook confirms then POSTs to /api/linked_lorebooks/delete", async () => {
    mock.respond("/api/lorebook", () => ({ status: 200, json: { entries: [] } }));
    mock.respond("/api/linked_lorebooks", () => ({
      status: 200,
      json: { books: [{ name: "Linked", entry_count: 0 }], entries: [[]] },
    }));
    mock.respond("/api/linked_lorebooks/delete", () => ({ status: 200, json: { ok: true } }));
    const api = initCardLore(makeDeps());
    await api.reload();
    await flush();
    const removeBtn = document.querySelector(".linked-lorebook__remove");
    expect(removeBtn).not.toBeNull();

    window.confirm = () => false;
    removeBtn.click();
    await flush();
    expect(mock.findCall("POST", "/api/linked_lorebooks/delete")).toBeUndefined();

    window.confirm = () => true;
    removeBtn.click();
    await flush();
    const call = mock.findCall("POST", "/api/linked_lorebooks/delete");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ index: 0 });
  });
});
