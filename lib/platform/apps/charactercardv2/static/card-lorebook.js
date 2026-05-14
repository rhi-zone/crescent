// Card-side lorebook tab content: character_book entries + linked lorebooks
// vendored in the card. Owns: #lorebook-list, #lorebook-add, #lorebook-notice
// (read-only when card not writable), and the linked-lorebooks UI
// (#linked-lorebooks-list, #linked-lorebooks-add, #linked-lorebooks-file).
//
// `reload()` (returned from `init`) is called by card-editor.js when the
// Lorebook tab is opened. It refreshes the read-only notice, fetches
// /api/lorebook and /api/linked_lorebooks, and populates both sections.

import { request as apiRequest } from "./api.js";
import { createEntryEl } from "./lorebook-entry.js";

/**
 * @typedef {{
 *   uid: string | number,
 *   enabled: boolean,
 *   keys?: string[],
 *   content?: string,
 *   position?: number,
 *   order?: number,
 *   constant?: boolean
 * }} LorebookEntry
 */

/**
 * @typedef {{ name: string, source?: string | null, entry_count: number }} LinkedBookSummary
 */

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   getCardWritable: () => boolean,
 * }} deps
 * @returns {{ reload: () => Promise<void> }}
 */
export function init(deps) {
  const showError = deps.showError;
  const getCardWritable = deps.getCardWritable;

  function request(method, path, body, opts_) {
    return apiRequest(method, path, body, { silent: opts_?.silent, onError: showError });
  }

  /** @type {HTMLButtonElement} */
  const lorebookAdd = /** @type {HTMLButtonElement} */ (document.getElementById("lorebook-add"));
  /** @type {HTMLElement} */
  const lorebookList = /** @type {HTMLElement} */ (document.getElementById("lorebook-list"));
  /** @type {HTMLElement} */
  const lorebookNotice = /** @type {HTMLElement} */ (document.getElementById("lorebook-notice"));
  /** @type {HTMLElement} */
  const linkedLorebooksList = /** @type {HTMLElement} */ (document.getElementById("linked-lorebooks-list"));
  /** @type {HTMLButtonElement} */
  const linkedLorebooksAdd = /** @type {HTMLButtonElement} */ (document.getElementById("linked-lorebooks-add"));
  /** @type {HTMLInputElement} */
  const linkedLorebooksFile = /** @type {HTMLInputElement} */ (document.getElementById("linked-lorebooks-file"));

  /** @type {Set<number>} */
  const linkedExpanded = new Set();

  function updateReadOnlyNotice() {
    if (getCardWritable()) {
      lorebookNotice.hidden = true;
      lorebookNotice.textContent = "";
    } else {
      lorebookNotice.hidden = false;
      lorebookNotice.textContent = "Read-only (self_write not granted) — edits persist locally but won't ride with the card PNG.";
    }
  }

  async function loadLorebook() {
    const data = await request("GET", "/api/lorebook");
    if (!data) return;
    renderLorebookEntries(data.entries);
  }

  /**
   * @param {LorebookEntry[] | null | undefined} entries
   */
  function renderLorebookEntries(entries) {
    lorebookList.innerHTML = "";
    if (!entries || entries.length === 0) {
      lorebookList.innerHTML = '<div class="lorebook-empty">No lorebook entries. Click "+ Add Entry" to create one.</div>';
      return;
    }
    for (const entry of entries) {
      lorebookList.appendChild(createEntryEl(entry, {
        updateUrl: "/api/lorebook/update",
        deleteUrl: "/api/lorebook/delete",
        onChange: loadLorebook,
      }));
    }
  }

  lorebookAdd.addEventListener("click", async function () {
    const data = await request("POST", "/api/lorebook/add", {
      keys: ["new keyword"],
      content: "",
    });
    if (data) loadLorebook();
  });

  // ── Linked Lorebooks (card-vendored) ─────────────────────────────────────

  async function loadLinkedLorebooks() {
    const data = await request("GET", "/api/linked_lorebooks");
    if (!data) return;
    /** @type {LinkedBookSummary[]} */
    const books = data.books || [];
    /** @type {LorebookEntry[][]} */
    const entriesByBook = data.entries || [];
    renderLinkedLorebooks(books, entriesByBook);
  }

  /**
   * @param {LinkedBookSummary[]} books
   * @param {LorebookEntry[][]} entriesByBook
   */
  function renderLinkedLorebooks(books, entriesByBook) {
    linkedLorebooksList.innerHTML = "";
    if (!books || books.length === 0) {
      const empty = document.createElement("div");
      empty.className = "lorebook-empty";
      empty.textContent = "No linked lorebooks. Click \"+ Add Linked Lorebook\" to bundle one with this card.";
      linkedLorebooksList.appendChild(empty);
      return;
    }
    for (let i = 0; i < books.length; i++) {
      linkedLorebooksList.appendChild(
        createLinkedBookEl(i, books[i], entriesByBook[i] || []),
      );
    }
  }

  /**
   * @param {number} index
   * @param {LinkedBookSummary} book
   * @param {LorebookEntry[]} entries
   * @returns {HTMLElement}
   */
  function createLinkedBookEl(index, book, entries) {
    const expanded = linkedExpanded.has(index);
    const section = document.createElement("div");
    section.className = "linked-lorebook" + (expanded ? " linked-lorebook--expanded" : "");

    const header = document.createElement("div");
    header.className = "linked-lorebook__header";
    header.addEventListener("click", () => {
      if (linkedExpanded.has(index)) linkedExpanded.delete(index);
      else linkedExpanded.add(index);
      section.classList.toggle("linked-lorebook--expanded");
      body.hidden = !linkedExpanded.has(index);
    });

    const caret = document.createElement("span");
    caret.className = "linked-lorebook__caret";
    caret.textContent = "▸";
    header.appendChild(caret);

    const title = document.createElement("span");
    title.className = "linked-lorebook__name";
    title.textContent = book.name || "(unnamed)";
    header.appendChild(title);

    const count = document.createElement("span");
    count.className = "linked-lorebook__count";
    count.textContent = String(book.entry_count) + " " + (book.entry_count === 1 ? "entry" : "entries");
    header.appendChild(count);

    if (book.source) {
      const src = document.createElement("span");
      src.className = "linked-lorebook__source";
      src.textContent = book.source;
      src.title = book.source;
      header.appendChild(src);
    }

    const removeBtn = document.createElement("button");
    removeBtn.className = "linked-lorebook__remove";
    removeBtn.type = "button";
    removeBtn.textContent = "Remove";
    removeBtn.addEventListener("click", async (e) => {
      e.stopPropagation();
      if (!confirm("Remove linked lorebook \"" + (book.name || "(unnamed)") + "\"?")) return;
      const data = await request("POST", "/api/linked_lorebooks/delete", { index });
      if (data) {
        linkedExpanded.delete(index);
        loadLinkedLorebooks();
      }
    });
    header.appendChild(removeBtn);

    section.appendChild(header);

    const body = document.createElement("div");
    body.className = "linked-lorebook__body";
    body.hidden = !expanded;
    if (!entries || entries.length === 0) {
      const empty = document.createElement("div");
      empty.className = "linked-lorebook__empty";
      empty.textContent = "(no entries)";
      body.appendChild(empty);
    } else {
      for (const entry of entries) {
        body.appendChild(createLinkedEntryEl(entry));
      }
    }
    section.appendChild(body);

    return section;
  }

  /**
   * @param {LorebookEntry} entry
   * @returns {HTMLElement}
   */
  function createLinkedEntryEl(entry) {
    const el = document.createElement("div");
    el.className = "linked-lorebook__entry";

    const keys = document.createElement("div");
    keys.className = "linked-lorebook__entry-keys";
    keys.textContent = (entry.keys && entry.keys.length > 0) ? entry.keys.join(", ") : "(no keys)";
    el.appendChild(keys);

    const content = document.createElement("div");
    content.className = "linked-lorebook__entry-content";
    content.textContent = entry.content || "";
    el.appendChild(content);

    return el;
  }

  linkedLorebooksAdd.addEventListener("click", () => {
    linkedLorebooksFile.value = "";
    linkedLorebooksFile.click();
  });

  linkedLorebooksFile.addEventListener("change", async () => {
    const file = linkedLorebooksFile.files && linkedLorebooksFile.files[0];
    if (!file) return;
    let text;
    try {
      text = await file.text();
    } catch (e) {
      showError(e instanceof Error ? e.message : String(e));
      return;
    }
    /** @type {{ name?: string, source?: string, entries?: unknown } | null} */
    let parsed = null;
    try {
      parsed = JSON.parse(text);
    } catch (e) {
      showError("Invalid JSON: " + (e instanceof Error ? e.message : String(e)));
      return;
    }
    if (!parsed || typeof parsed !== "object") {
      showError("Invalid lorebook file: expected an object");
      return;
    }
    const payload = {
      name: parsed.name || file.name.replace(/\.lorebook\.json$|\.json$/i, "") || "Imported",
      source: parsed.source,
      entries: parsed.entries,
    };
    const data = await request("POST", "/api/linked_lorebooks/import", payload);
    if (data) loadLinkedLorebooks();
  });

  async function reload() {
    updateReadOnlyNotice();
    await Promise.all([loadLorebook(), loadLinkedLorebooks()]);
  }

  return { reload };
}
