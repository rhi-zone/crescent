// User-side lorebook library overlay. Owns: #btn-my-lorebooks,
// #my-lorebooks-overlay / #my-lorebooks-panel / #my-lorebooks-close,
// the book list (left pane) and book detail (right pane) UI, and all CRUD
// against /api/user_lorebooks. Distinct from the card-side lorebook tab
// (`card-lorebook.js`). The shared entry-row UI lives in
// `lorebook-entry.js` and is imported directly.

import { request } from "./api.js";
import { createEntryEl } from "./lorebook-entry.js";

/**
 * @typedef {{ id: string, name: string, active: boolean, entry_count: number }} BookSummary
 */

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
 * @param {{
 *   showError: (msg: string) => void,
 *   trapFocus: (overlay: HTMLElement, triggerEl?: Element | null) => void,
 *   releaseFocus: () => void,
 * }} deps
 * @returns {{
 *   open: () => void,
 *   close: () => void,
 *   isOpen: () => boolean,
 *   overlay: HTMLElement,
 *   reload: () => Promise<void>,
 * }}
 */
export function init(deps) {
  const showError = deps.showError;
  const trapFocus = deps.trapFocus;
  const releaseFocus = deps.releaseFocus;

  /** @type {HTMLButtonElement} */
  const btnMyLorebooks = /** @type {HTMLButtonElement} */ (document.getElementById("btn-my-lorebooks"));
  /** @type {HTMLElement} */
  const myLorebooksOverlay = /** @type {HTMLElement} */ (document.getElementById("my-lorebooks-overlay"));
  /** @type {HTMLButtonElement} */
  const myLorebooksClose = /** @type {HTMLButtonElement} */ (document.getElementById("my-lorebooks-close"));
  /** @type {HTMLButtonElement} */
  const myLorebooksNew = /** @type {HTMLButtonElement} */ (document.getElementById("my-lorebooks-new"));
  /** @type {HTMLButtonElement} */
  const myLorebooksImport = /** @type {HTMLButtonElement} */ (document.getElementById("my-lorebooks-import"));
  /** @type {HTMLInputElement} */
  const myLorebooksImportFile = /** @type {HTMLInputElement} */ (document.getElementById("my-lorebooks-import-file"));
  /** @type {HTMLElement} */
  const bookListEl = /** @type {HTMLElement} */ (document.getElementById("book-list"));
  /** @type {HTMLElement} */
  const bookDetailPlaceholder = /** @type {HTMLElement} */ (document.getElementById("book-detail-placeholder"));
  /** @type {HTMLElement} */
  const bookDetailHeader = /** @type {HTMLElement} */ (document.getElementById("book-detail-header"));
  /** @type {HTMLInputElement} */
  const bookDetailName = /** @type {HTMLInputElement} */ (document.getElementById("book-detail-name"));
  /** @type {HTMLButtonElement} */
  const bookDetailRename = /** @type {HTMLButtonElement} */ (document.getElementById("book-detail-rename"));
  /** @type {HTMLButtonElement} */
  const bookDetailAdd = /** @type {HTMLButtonElement} */ (document.getElementById("book-detail-add"));
  /** @type {HTMLElement} */
  const bookDetailBody = /** @type {HTMLElement} */ (document.getElementById("book-detail-body"));

  /** @type {BookSummary[]} */
  let myBooks = [];
  /** @type {string | null} */
  let selectedBookId = null;

  function openMyLorebooks() {
    myLorebooksOverlay.hidden = false;
    loadMyLorebooks();
    trapFocus(myLorebooksOverlay, btnMyLorebooks);
  }

  function closeMyLorebooks() {
    myLorebooksOverlay.hidden = true;
    releaseFocus();
  }

  btnMyLorebooks.addEventListener("click", openMyLorebooks);
  myLorebooksClose.addEventListener("click", closeMyLorebooks);
  myLorebooksOverlay.addEventListener("click", function (e) {
    if (e.target === myLorebooksOverlay) closeMyLorebooks();
  });
  myLorebooksOverlay.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && !myLorebooksOverlay.hidden) { e.stopPropagation(); closeMyLorebooks(); }
  });

  async function loadMyLorebooks() {
    const data = await request("GET", "/api/user_lorebooks", undefined, { onError: showError });
    if (!data) return;
    myBooks = /** @type {BookSummary[]} */ (data.books || []);
    renderBookList();
    if (selectedBookId && myBooks.find(b => b.id === selectedBookId)) {
      loadBookEntries(selectedBookId);
    } else {
      selectedBookId = null;
      hideBookDetail();
    }
  }

  function renderBookList() {
    bookListEl.innerHTML = "";
    if (myBooks.length === 0) {
      const empty = document.createElement("div");
      empty.className = "lorebook-empty";
      empty.textContent = 'No lorebooks yet. Click "+ New Lorebook" to create one.';
      bookListEl.appendChild(empty);
      return;
    }
    for (const book of myBooks) {
      bookListEl.appendChild(createBookRow(book));
    }
  }

  /**
   * @param {BookSummary} book
   * @returns {HTMLElement}
   */
  function createBookRow(book) {
    const row = document.createElement("div");
    row.className = "book-row" + (selectedBookId === book.id ? " book-row--selected" : "");
    row.dataset.id = book.id;

    const toggle = document.createElement("button");
    toggle.className = "lorebook-entry__toggle" + (book.active ? " lorebook-entry__toggle--on" : "");
    toggle.title = book.active ? "Active" : "Inactive";
    toggle.addEventListener("click", async function (e) {
      e.stopPropagation();
      const newActive = !book.active;
      const data = await request("POST", "/api/user_lorebooks/toggle", { id: book.id, active: newActive }, { onError: showError });
      if (data) {
        book.active = newActive;
        toggle.className = "lorebook-entry__toggle" + (newActive ? " lorebook-entry__toggle--on" : "");
        toggle.title = newActive ? "Active" : "Inactive";
      }
    });

    const name = document.createElement("span");
    name.className = "book-row__name";
    name.textContent = book.name;

    const count = document.createElement("span");
    count.className = "book-row__count";
    count.textContent = String(book.entry_count) + (book.entry_count === 1 ? " entry" : " entries");

    const exportBtn = document.createElement("button");
    exportBtn.className = "book-row__export";
    exportBtn.textContent = "⬇";
    exportBtn.title = "Export lorebook to JSON";
    exportBtn.addEventListener("click", function (e) {
      e.stopPropagation();
      exportLorebook(book.id, book.name);
    });

    const del = document.createElement("button");
    del.className = "book-row__delete";
    del.textContent = "×";
    del.title = "Delete lorebook";
    del.addEventListener("click", async function (e) {
      e.stopPropagation();
      if (!confirm(`Delete lorebook "${book.name}"? This cannot be undone.`)) return;
      const data = await request("POST", "/api/user_lorebooks/delete", { id: book.id }, { onError: showError });
      if (data) {
        if (selectedBookId === book.id) selectedBookId = null;
        loadMyLorebooks();
      }
    });

    row.appendChild(toggle);
    row.appendChild(name);
    row.appendChild(count);
    row.appendChild(exportBtn);
    row.appendChild(del);

    row.addEventListener("click", function () {
      selectedBookId = book.id;
      renderBookList();
      loadBookEntries(book.id);
    });

    return row;
  }

  function hideBookDetail() {
    bookDetailPlaceholder.hidden = false;
    bookDetailHeader.hidden = true;
    bookDetailBody.hidden = true;
    bookDetailBody.innerHTML = "";
  }

  /**
   * @param {string} bookId
   */
  async function loadBookEntries(bookId) {
    const data = await request("GET", "/api/user_lorebooks/entries?book_id=" + encodeURIComponent(bookId), undefined, { onError: showError });
    if (!data) return;
    bookDetailPlaceholder.hidden = true;
    bookDetailHeader.hidden = false;
    bookDetailBody.hidden = false;
    bookDetailName.value = data.name || "";
    renderBookEntries(bookId, data.entries);
  }

  /**
   * @param {string} bookId
   * @param {LorebookEntry[] | null | undefined} entries
   */
  function renderBookEntries(bookId, entries) {
    bookDetailBody.innerHTML = "";
    if (!entries || entries.length === 0) {
      bookDetailBody.innerHTML = '<div class="lorebook-empty">No entries. Click "+ Add Entry" to create one.</div>';
      return;
    }
    for (const entry of entries) {
      bookDetailBody.appendChild(createEntryEl(entry, {
        updateUrl: "/api/user_lorebooks/entry/update",
        deleteUrl: "/api/user_lorebooks/entry/delete",
        extraBody: { book_id: bookId },
        onChange: function () {
          loadBookEntries(bookId);
          // Refresh book list for entry_count.
          request("GET", "/api/user_lorebooks", undefined, { onError: showError }).then(function (d) {
            if (d) { myBooks = d.books || []; renderBookList(); }
          });
        },
      }));
    }
  }

  myLorebooksNew.addEventListener("click", async function () {
    const name = prompt("Lorebook name:", "Untitled");
    if (!name) return;
    const data = await request("POST", "/api/user_lorebooks", { name }, { onError: showError });
    if (data && data.id) {
      selectedBookId = data.id;
      await loadMyLorebooks();
    }
  });

  /**
   * Trigger a file download for a single lorebook.
   * @param {string} bookId
   * @param {string} bookName
   */
  async function exportLorebook(bookId, bookName) {
    try {
      const res = await fetch("/api/user_lorebooks/export?book_id=" + encodeURIComponent(bookId));
      if (!res.ok) {
        const data = await res.json().catch(() => ({ error: "export failed" }));
        showError(data.error || "export failed");
        return;
      }
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      const disp = res.headers.get("content-disposition");
      if (disp) {
        const match = disp.match(/filename="?([^"]+)"?/);
        if (match) a.download = match[1];
      }
      if (!a.download) a.download = (bookName || "lorebook") + ".lorebook.json";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (e) {
      showError(e instanceof Error ? e.message : String(e));
    }
  }

  myLorebooksImport.addEventListener("click", function () {
    myLorebooksImportFile.value = "";
    myLorebooksImportFile.click();
  });

  myLorebooksImportFile.addEventListener("change", async function () {
    const file = myLorebooksImportFile.files && myLorebooksImportFile.files[0];
    if (!file) return;
    let text;
    try {
      text = await file.text();
    } catch (e) {
      showError(e instanceof Error ? e.message : String(e));
      return;
    }
    /** @type {{ name?: string, entries?: unknown } | null} */
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
    // Derive a default name from the filename if none supplied.
    const payload = {
      name: parsed.name || file.name.replace(/\.lorebook\.json$|\.json$/i, "") || "Imported",
      entries: parsed.entries,
    };
    const data = await request("POST", "/api/user_lorebooks/import", payload, { onError: showError });
    if (data && data.id) {
      selectedBookId = data.id;
      await loadMyLorebooks();
    }
  });

  bookDetailRename.addEventListener("click", async function () {
    if (!selectedBookId) return;
    const newName = bookDetailName.value.trim();
    if (!newName) return;
    const data = await request("POST", "/api/user_lorebooks/rename", { id: selectedBookId, name: newName }, { onError: showError });
    if (data) loadMyLorebooks();
  });

  bookDetailAdd.addEventListener("click", async function () {
    if (!selectedBookId) return;
    const data = await request("POST", "/api/user_lorebooks/entry/add", {
      book_id: selectedBookId,
      keys: ["new keyword"],
      content: "",
    }, { onError: showError });
    if (data) {
      loadBookEntries(selectedBookId);
      // Refresh entry_count.
      const list = await request("GET", "/api/user_lorebooks", undefined, { onError: showError });
      if (list) { myBooks = list.books || []; renderBookList(); }
    }
  });

  return {
    open: openMyLorebooks,
    close: closeMyLorebooks,
    isOpen: function () { return !myLorebooksOverlay.hidden; },
    overlay: myLorebooksOverlay,
    reload: loadMyLorebooks,
  };
}
