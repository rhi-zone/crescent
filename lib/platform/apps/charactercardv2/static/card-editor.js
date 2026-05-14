// Card editor overlay — tab framework + identity/greetings content. Owns:
// #card-edit-overlay, #card-edit-panel, #card-edit-close, all tab buttons
// (#tab-btn-identity/greetings/lorebook/regex) and their tabpanels, the
// identity input/textarea fields (#card-name/creator/character_version/
// description/personality/scenario/first_mes/mes_example/system_prompt/
// post_history_instructions/creator_notes/tags), the Alternate Greetings list
// (#card-alt-greetings-list, #card-alt-add), the Save/Reset footer
// (#card-edit-save, #card-edit-reset, #card-edit-footer), the read-only
// notice (#card-edit-notice), and the Author's Note save (#an-save) since
// Author's Note lives inside the Identity tab.
//
// Does NOT own:
//   * Regex tab content (regex.js owns it; this module just calls
//     `regexReload()` when the Regex tab opens).
//   * Lorebook tab content (still inline in app.js; this module calls
//     `lorebookReload()` when the Lorebook tab opens).
//
// `cardWritable` is mutable in app.js (toggled when the card is reloaded),
// so it's passed as a getter (`getCardWritable`) rather than a value.

import { request } from "./api.js";

/**
 * @typedef {{ [key: string]: any, tags?: string[], alternate_greetings?: string[] }} CardData
 */

const CARD_INPUT_KEYS = ["name", "creator", "character_version"];
const CARD_TEXTAREA_KEYS = [
  "description", "personality", "scenario", "first_mes", "mes_example",
  "system_prompt", "post_history_instructions", "creator_notes",
];

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   showInfo?: (msg: string) => void,
 *   trapFocus: (overlay: HTMLElement, triggerEl?: Element | null) => void,
 *   releaseFocus: () => void,
 *   lorebookReload: () => void,
 *   regexReload: () => void,
 *   authorsNoteLoad: () => void,
 *   getCardWritable: () => boolean,
 * }} deps
 * @returns {{
 *   open: (tab?: string) => void,
 *   close: () => void,
 *   isOpen: () => boolean,
 *   overlay: HTMLElement,
 * }}
 */
export function init(deps) {
  const showError = deps.showError;
  const showInfo = deps.showInfo || function () {};
  const trapFocus = deps.trapFocus;
  const releaseFocus = deps.releaseFocus;
  const lorebookReload = deps.lorebookReload;
  const regexReload = deps.regexReload;
  const authorsNoteLoad = deps.authorsNoteLoad;
  const getCardWritable = deps.getCardWritable;

  /** @type {HTMLElement} */
  const overlay = /** @type {HTMLElement} */ (document.getElementById("card-edit-overlay"));
  /** @type {HTMLButtonElement} */
  const closeBtn = /** @type {HTMLButtonElement} */ (document.getElementById("card-edit-close"));
  /** @type {HTMLButtonElement} */
  const saveBtn = /** @type {HTMLButtonElement} */ (document.getElementById("card-edit-save"));
  /** @type {HTMLButtonElement} */
  const resetBtn = /** @type {HTMLButtonElement} */ (document.getElementById("card-edit-reset"));
  /** @type {HTMLElement} */
  const notice = /** @type {HTMLElement} */ (document.getElementById("card-edit-notice"));
  /** @type {HTMLElement} */
  const panelTitle = /** @type {HTMLElement} */ (document.getElementById("card-edit-panel-title"));
  /** @type {HTMLElement} */
  const footer = /** @type {HTMLElement} */ (document.getElementById("card-edit-footer"));
  /** @type {HTMLElement} */
  const altList = /** @type {HTMLElement} */ (document.getElementById("card-alt-greetings-list"));
  /** @type {HTMLButtonElement} */
  const altAdd = /** @type {HTMLButtonElement} */ (document.getElementById("card-alt-add"));

  /** @type {{ [key: string]: HTMLElement }} */
  const tabPanes = {
    identity: /** @type {HTMLElement} */ (document.getElementById("tab-identity")),
    greetings: /** @type {HTMLElement} */ (document.getElementById("tab-greetings")),
    lorebook: /** @type {HTMLElement} */ (document.getElementById("tab-lorebook")),
    regex: /** @type {HTMLElement} */ (document.getElementById("tab-regex")),
  };

  /** @type {{ [key: string]: HTMLButtonElement }} */
  const tabBtns = {
    identity: /** @type {HTMLButtonElement} */ (document.getElementById("tab-btn-identity")),
    greetings: /** @type {HTMLButtonElement} */ (document.getElementById("tab-btn-greetings")),
    lorebook: /** @type {HTMLButtonElement} */ (document.getElementById("tab-btn-lorebook")),
    regex: /** @type {HTMLButtonElement} */ (document.getElementById("tab-btn-regex")),
  };

  /** @type {HTMLTextAreaElement} */
  const anText = /** @type {HTMLTextAreaElement} */ (document.getElementById("an-text"));
  /** @type {HTMLInputElement} */
  const anDepth = /** @type {HTMLInputElement} */ (document.getElementById("an-depth"));
  /** @type {HTMLSelectElement} */
  const anPosition = /** @type {HTMLSelectElement} */ (document.getElementById("an-position"));
  /** @type {HTMLButtonElement} */
  const anSave = /** @type {HTMLButtonElement} */ (document.getElementById("an-save"));

  /** @type {string} */
  let activeTab = "identity";

  /**
   * @param {string} tab
   */
  function switchTab(tab) {
    activeTab = tab;
    for (const [key, pane] of Object.entries(tabPanes)) {
      pane.hidden = key !== tab;
    }
    for (const [key, btn] of Object.entries(tabBtns)) {
      btn.classList.toggle("card-edit-tab--active", key === tab);
      btn.setAttribute("aria-selected", key === tab ? "true" : "false");
    }
    // Footer (Save/Reset) only shown for Identity and Greetings tabs.
    footer.hidden = tab === "lorebook" || tab === "regex";
  }

  for (const [key, btn] of Object.entries(tabBtns)) {
    btn.addEventListener("click", function () {
      switchTab(key);
      if (key === "lorebook") lorebookReload();
      else if (key === "regex") regexReload();
    });
  }

  function updateReadOnlyNotice() {
    if (getCardWritable()) {
      notice.hidden = true;
      notice.textContent = "";
    } else {
      notice.hidden = false;
      notice.textContent = "Read-only (self_write not granted) — edits persist locally but won't ride with the card PNG.";
    }
  }

  /**
   * @param {CardData} data
   */
  function populateCardEditor(data) {
    for (const key of CARD_INPUT_KEYS) {
      const el = /** @type {HTMLInputElement | null} */ (document.getElementById("card-" + key));
      if (el) el.value = data[key] || "";
    }
    for (const key of CARD_TEXTAREA_KEYS) {
      const el = /** @type {HTMLTextAreaElement | null} */ (document.getElementById("card-" + key));
      if (el) el.value = data[key] || "";
    }
    /** @type {HTMLInputElement} */ (document.getElementById("card-tags")).value = (data.tags || []).join(", ");
    renderAltGreetings(data.alternate_greetings || []);
  }

  /**
   * @param {string[]} greetings
   */
  function renderAltGreetings(greetings) {
    altList.innerHTML = "";
    for (let i = 0; i < greetings.length; i++) {
      const row = document.createElement("div");
      row.className = "card-edit-alt-row";
      const textarea = document.createElement("textarea");
      textarea.className = "card-edit-alt-row__textarea";
      textarea.value = greetings[i] || "";
      textarea.rows = 2;
      textarea.dataset.index = String(i);
      const removeBtn = document.createElement("button");
      removeBtn.className = "card-edit-alt-row__remove";
      removeBtn.textContent = "×";
      removeBtn.title = "Remove";
      removeBtn.addEventListener("click", function () { row.remove(); });
      row.appendChild(textarea);
      row.appendChild(removeBtn);
      altList.appendChild(row);
    }
  }

  /**
   * @returns {CardData}
   */
  function readCardEditor() {
    /** @type {CardData} */
    const data = {};
    for (const key of CARD_INPUT_KEYS) {
      const el = /** @type {HTMLInputElement | null} */ (document.getElementById("card-" + key));
      if (el) data[key] = el.value;
    }
    for (const key of CARD_TEXTAREA_KEYS) {
      const el = /** @type {HTMLTextAreaElement | null} */ (document.getElementById("card-" + key));
      if (el) data[key] = el.value;
    }
    const tagsStr = /** @type {HTMLInputElement} */ (document.getElementById("card-tags")).value;
    data.tags = tagsStr.split(",").map(function (s) { return s.trim(); }).filter(Boolean);
    const altTextareas = altList.querySelectorAll(".card-edit-alt-row__textarea");
    data.alternate_greetings = [];
    for (const ta of altTextareas) {
      data.alternate_greetings.push(/** @type {HTMLTextAreaElement} */ (ta).value);
    }
    return data;
  }

  async function loadCardEditor() {
    const data = await request("GET", "/api/card/edit", undefined, { onError: showError });
    if (data) {
      populateCardEditor(data);
      panelTitle.textContent = data.name || "";
    }
  }

  /**
   * @param {string} [tab]
   */
  function open(tab) {
    overlay.hidden = false;
    const chosen = tab || "identity";
    switchTab(chosen);
    updateReadOnlyNotice();
    loadCardEditor();
    if (chosen === "identity") {
      authorsNoteLoad();
    } else if (chosen === "lorebook") {
      lorebookReload();
    } else if (chosen === "regex") {
      regexReload();
    }
    trapFocus(overlay, null);
  }

  function close() {
    overlay.hidden = true;
    releaseFocus();
  }

  function isOpen() {
    return !overlay.hidden;
  }

  closeBtn.addEventListener("click", close);
  overlay.addEventListener("click", function (e) {
    if (e.target === overlay) close();
  });

  saveBtn.addEventListener("click", async function () {
    const data = await request("POST", "/api/card/edit", readCardEditor(), { onError: showError });
    if (data) {
      populateCardEditor(data);
      // Aspirational: surface which storage path the edit took (kv vs PNG).
      if (data.storage) {
        showInfo("Saved to " + data.storage);
      }
      close();
    }
  });

  resetBtn.addEventListener("click", async function () {
    const confirmed = window.confirm(
      "Reset to original? This will discard your edits to this card and cannot be undone."
    );
    if (!confirmed) return;
    const data = await request("POST", "/api/card/reset", undefined, { onError: showError });
    if (data) populateCardEditor(data);
  });

  altAdd.addEventListener("click", function () {
    const greetings = [];
    for (const ta of altList.querySelectorAll(".card-edit-alt-row__textarea")) {
      greetings.push(/** @type {HTMLTextAreaElement} */ (ta).value);
    }
    greetings.push("");
    renderAltGreetings(greetings);
  });

  anSave.addEventListener("click", async function () {
    await request("POST", "/api/authors_note", {
      text: anText.value,
      depth: parseInt(anDepth.value, 10) || 4,
      position: anPosition.value,
    }, { onError: showError });
  });

  return { open, close, isOpen, overlay };
}
