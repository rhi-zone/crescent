// Tests for ../card-editor.js init().
//
// Aspirational: encodes the intended behavior of the card editor overlay
// (tab framework + identity/greetings save/reset + Author's Note loading).
// Some tests target behaviors not yet present in the current implementation;
// those are tracked in TODO.md's "frontend test regressions" section.

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush, fire } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initCardEditor } from "../card-editor.js";

let mock, errors, trapped, released, lorebookReloads, regexReloads, authorsNoteLoads, writable;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = []; trapped = []; released = 0;
  lorebookReloads = 0; regexReloads = 0; authorsNoteLoads = 0;
  writable = true;
});

function makeDeps(overrides) {
  return {
    showError: (m) => errors.push(m),
    trapFocus: (overlay, trigger) => trapped.push({ overlay, trigger }),
    releaseFocus: () => { released++; },
    lorebookReload: () => { lorebookReloads++; },
    regexReload: () => { regexReloads++; },
    authorsNoteLoad: () => { authorsNoteLoads++; },
    getCardWritable: () => writable,
    ...(overrides || {}),
  };
}

function respondCard(name) {
  mock.respond("/api/card/edit", () => ({
    status: 200,
    json: { name: name || "Test Card", description: "a desc", tags: ["t1", "t2"], alternate_greetings: ["g1"] },
  }));
}

describe("card-editor.init", () => {
  test("returns { open, close, isOpen, overlay }", () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    expect(typeof api.open).toBe("function");
    expect(typeof api.close).toBe("function");
    expect(typeof api.isOpen).toBe("function");
    expect(api.overlay).toBe(document.getElementById("card-edit-overlay"));
  });

  test("open('identity') reveals overlay, marks identity tab active, calls trapFocus", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();
    expect(api.isOpen()).toBe(true);
    expect(api.overlay.hidden).toBe(false);
    const identityBtn = document.getElementById("tab-btn-identity");
    expect(identityBtn.getAttribute("aria-selected")).toBe("true");
    expect(document.getElementById("tab-identity").hidden).toBe(false);
    expect(trapped.length).toBe(1);
    expect(trapped[0].overlay).toBe(api.overlay);
  });

  test("open('lorebook') calls lorebookReload callback", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("lorebook");
    await flush();
    expect(lorebookReloads).toBe(1);
    const lbBtn = document.getElementById("tab-btn-lorebook");
    expect(lbBtn.getAttribute("aria-selected")).toBe("true");
  });

  test("open('regex') calls regexReload callback", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("regex");
    await flush();
    expect(regexReloads).toBe(1);
    const regexBtn = document.getElementById("tab-btn-regex");
    expect(regexBtn.getAttribute("aria-selected")).toBe("true");
  });

  test("authorsNoteLoad fires only for the identity tab, not lorebook/regex", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();
    expect(authorsNoteLoads).toBe(1);

    api.open("lorebook");
    await flush();
    expect(authorsNoteLoads).toBe(1);

    api.open("regex");
    await flush();
    expect(authorsNoteLoads).toBe(1);
  });

  test("close() hides the overlay and calls releaseFocus", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();
    api.close();
    expect(api.isOpen()).toBe(false);
    expect(api.overlay.hidden).toBe(true);
    expect(released).toBe(1);
  });

  test("switching tabs updates aria-selected and shows the correct tabpanel", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();

    document.getElementById("tab-btn-greetings").click();
    await flush();
    expect(document.getElementById("tab-btn-greetings").getAttribute("aria-selected")).toBe("true");
    expect(document.getElementById("tab-btn-identity").getAttribute("aria-selected")).toBe("false");
    expect(document.getElementById("tab-greetings").hidden).toBe(false);
    expect(document.getElementById("tab-identity").hidden).toBe(true);

    document.getElementById("tab-btn-regex").click();
    await flush();
    expect(document.getElementById("tab-btn-regex").getAttribute("aria-selected")).toBe("true");
    expect(document.getElementById("tab-btn-greetings").getAttribute("aria-selected")).toBe("false");
    expect(document.getElementById("tab-regex").hidden).toBe(false);
    expect(regexReloads).toBeGreaterThanOrEqual(1);
  });

  test("tab buttons keep aria-selected synced with active state at all times", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();
    const btns = ["identity", "greetings", "lorebook", "regex"].map(
      (k) => document.getElementById("tab-btn-" + k),
    );
    function selectedKey() {
      for (const b of btns) {
        if (b.getAttribute("aria-selected") === "true") return b.id;
      }
      return null;
    }
    expect(selectedKey()).toBe("tab-btn-identity");
    document.getElementById("tab-btn-lorebook").click();
    await flush();
    expect(selectedKey()).toBe("tab-btn-lorebook");
    // Exactly one tab should be aria-selected="true" at any given time.
    let count = 0;
    for (const b of btns) if (b.getAttribute("aria-selected") === "true") count++;
    expect(count).toBe(1);
  });

  test("Save POSTs identity fields to /api/card/edit", async () => {
    respondCard("Original");
    mock.respond("/api/card/edit", (call) => {
      if (call.method === "POST") return { status: 200, json: { ...call.body } };
      return { status: 200, json: { name: "Original", description: "a desc", tags: [], alternate_greetings: [] } };
    });
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();
    document.getElementById("card-name").value = "Renamed";
    document.getElementById("card-description").value = "new desc";
    document.getElementById("card-tags").value = "a, b, c";
    document.getElementById("card-edit-save").click();
    await flush();
    const post = mock.findCall("POST", "/api/card/edit");
    expect(post).toBeDefined();
    expect(post.body.name).toBe("Renamed");
    expect(post.body.description).toBe("new desc");
    expect(post.body.tags).toEqual(["a", "b", "c"]);
  });

  test("Reset to Original confirms first; on confirm POSTs /api/card/reset", async () => {
    respondCard();
    mock.respond("/api/card/reset", () => ({ status: 200, json: { name: "Reset", tags: [], alternate_greetings: [] } }));
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();

    window.confirm = () => false;
    document.getElementById("card-edit-reset").click();
    await flush();
    expect(mock.findCall("POST", "/api/card/reset")).toBeUndefined();

    window.confirm = () => true;
    document.getElementById("card-edit-reset").click();
    await flush();
    expect(mock.findCall("POST", "/api/card/reset")).toBeDefined();
  });

  test("Reset confirm dialog explains what's lost", async () => {
    respondCard();
    mock.respond("/api/card/reset", () => ({ status: 200, json: {} }));
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();

    let promptText = "";
    window.confirm = (m) => { promptText = m; return false; };
    document.getElementById("card-edit-reset").click();
    await flush();
    expect(promptText.toLowerCase()).toContain("discard");
    expect(promptText.toLowerCase()).toContain("cannot be undone");
  });

  test("Save still works when card is non-writable (writes to kv fallback) and surfaces the storage path", async () => {
    respondCard();
    writable = false;
    /** @type {string[]} */
    const systemMessages = [];
    mock.respond("/api/card/edit", (call) => {
      if (call.method === "POST") return { status: 200, json: { ok: true, storage: "kv", ...call.body } };
      return { status: 200, json: { name: "X", tags: [], alternate_greetings: [] } };
    });
    const deps = makeDeps({
      showInfo: (m) => systemMessages.push(m),
    });
    const api = initCardEditor(deps);
    api.open("identity");
    await flush();
    document.getElementById("card-edit-save").click();
    await flush();
    expect(mock.findCall("POST", "/api/card/edit")).toBeDefined();
    // Aspirational: when the backend reports kv-vs-png, the user should
    // see a notice indicating which path their edit took.
    const joined = systemMessages.join(" ").toLowerCase();
    expect(joined).toContain("kv");
  });

  test("pressing Escape on the overlay closes it", async () => {
    respondCard();
    const api = initCardEditor(makeDeps());
    api.open("identity");
    await flush();
    fire(api.overlay, "keydown", { key: "Escape" });
    expect(api.isOpen()).toBe(false);
    expect(released).toBeGreaterThanOrEqual(1);
  });
});
