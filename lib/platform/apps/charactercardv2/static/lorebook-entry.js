// Shared lorebook-entry row UI. Owns: `createEntryEl(entry, handlers)` —
// builds the editable DOM element for a single lorebook entry (toggle, keys
// preview, expandable body with keys/content/position/order/constant fields,
// Save and Delete buttons). Used by both the card-side lorebook tab
// (`card-lorebook.js`) and the user-side lorebook library
// (`my-lorebooks.js`). The handlers parameter selects update/delete URLs and
// supplies an `onChange` reload callback, plus any `extraBody` fields that
// must accompany each request (e.g. `book_id` for user lorebooks).
//
// HTML escaping for the inline-rendered fields lives here too (escAttr /
// escHtml) since they're entry-shape-specific and not used elsewhere.

import { request } from "./api.js";

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
 * @typedef {{
 *   updateUrl: string,
 *   deleteUrl: string,
 *   extraBody?: Record<string, unknown>,
 *   onChange?: () => void,
 * }} EntryHandlers
 */

export const POSITION_LABELS = [
  "Before Char Defs",
  "After Char Defs",
  "Before AN (Top)",
  "Before AN (Bottom)",
  "At Depth",
  "After Example Msgs (Top)",
  "After Example Msgs (Bottom)",
];

/**
 * @param {string} s
 * @returns {string}
 */
export function escAttr(s) {
  return String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

/**
 * @param {string} s
 * @returns {string}
 */
export function escHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/**
 * Build a single editable lorebook-entry row.
 *
 * @param {LorebookEntry} entry
 * @param {EntryHandlers} handlers
 * @returns {HTMLElement}
 */
export function createEntryEl(entry, handlers) {
  const onChange = handlers.onChange || function () {};
  const el = document.createElement("div");
  el.className = "lorebook-entry" + (entry.enabled ? "" : " lorebook-entry--disabled");
  el.dataset.uid = String(entry.uid);

  // Header row
  const header = document.createElement("div");
  header.className = "lorebook-entry__header";

  const toggle = document.createElement("button");
  toggle.className = "lorebook-entry__toggle" + (entry.enabled ? " lorebook-entry__toggle--on" : "");
  toggle.title = entry.enabled ? "Enabled" : "Disabled";
  toggle.addEventListener("click", async function (e) {
    e.stopPropagation();
    const newEnabled = !entry.enabled;
    const data = await request("POST", handlers.updateUrl, {
      ...(handlers.extraBody || {}),
      uid: entry.uid, enabled: newEnabled,
    });
    if (data) {
      entry.enabled = newEnabled;
      toggle.className = "lorebook-entry__toggle" + (newEnabled ? " lorebook-entry__toggle--on" : "");
      toggle.title = newEnabled ? "Enabled" : "Disabled";
      el.className = "lorebook-entry" + (newEnabled ? "" : " lorebook-entry--disabled");
    }
  });

  const keys = document.createElement("div");
  keys.className = "lorebook-entry__keys";
  for (const k of (entry.keys || [])) {
    const tag = document.createElement("span");
    tag.className = "lorebook-entry__key";
    tag.textContent = k;
    keys.appendChild(tag);
  }

  const preview = document.createElement("span");
  preview.className = "lorebook-entry__preview";
  preview.textContent = (entry.content || "").slice(0, 60);

  const arrow = document.createElement("span");
  arrow.className = "lorebook-entry__expand";
  arrow.textContent = "▶";

  header.appendChild(toggle);
  header.appendChild(keys);
  header.appendChild(preview);
  header.appendChild(arrow);

  // Body (collapsed by default)
  const body = document.createElement("div");
  body.className = "lorebook-entry__body";
  body.hidden = true;

  body.innerHTML = `
    <div class="lorebook-entry__field">
      <label class="lorebook-entry__label">Keywords (comma-separated)</label>
      <input class="lorebook-entry__input" data-field="keys" value="${escAttr((entry.keys || []).join(", "))}">
    </div>
    <div class="lorebook-entry__field">
      <label class="lorebook-entry__label">Content</label>
      <textarea class="lorebook-entry__textarea" data-field="content">${escHtml(entry.content || "")}</textarea>
    </div>
    <div class="lorebook-entry__row">
      <div class="lorebook-entry__field">
        <label class="lorebook-entry__label">Position</label>
        <select class="lorebook-entry__input" data-field="position">
          ${POSITION_LABELS.map((l, i) => `<option value="${i}"${entry.position === i ? " selected" : ""}>${l}</option>`).join("")}
        </select>
      </div>
      <div class="lorebook-entry__field">
        <label class="lorebook-entry__label">Order</label>
        <input type="number" class="lorebook-entry__input" data-field="order" value="${entry.order || 0}">
      </div>
      <div class="lorebook-entry__constant">
        <input type="checkbox" data-field="constant" ${entry.constant ? "checked" : ""}>
        <span>Constant</span>
      </div>
    </div>
    <div class="lorebook-entry__actions">
      <button class="lorebook-entry__delete">Delete</button>
      <button class="lorebook-entry__save">Save</button>
    </div>
  `;

  // Toggle expand/collapse
  header.addEventListener("click", function () {
    body.hidden = !body.hidden;
    arrow.textContent = body.hidden ? "▶" : "▼";
  });

  // Save
  /** @type {HTMLButtonElement} */ (body.querySelector(".lorebook-entry__save")).addEventListener("click", async function () {
    const keysStr = /** @type {HTMLInputElement} */ (body.querySelector('[data-field="keys"]')).value;
    const newKeys = keysStr.split(",").map(s => s.trim()).filter(Boolean);
    const content = /** @type {HTMLTextAreaElement} */ (body.querySelector('[data-field="content"]')).value;
    const position = parseInt(/** @type {HTMLSelectElement} */ (body.querySelector('[data-field="position"]')).value, 10);
    const order = parseInt(/** @type {HTMLInputElement} */ (body.querySelector('[data-field="order"]')).value, 10) || 0;
    const constant = /** @type {HTMLInputElement} */ (body.querySelector('[data-field="constant"]')).checked;
    const data = await request("POST", handlers.updateUrl, {
      ...(handlers.extraBody || {}),
      uid: entry.uid, keys: newKeys, content, position, order, constant,
    });
    if (data) onChange();
  });

  // Delete
  /** @type {HTMLButtonElement} */ (body.querySelector(".lorebook-entry__delete")).addEventListener("click", async function () {
    const label = (entry.keys && entry.keys.length) ? entry.keys.join(", ") : ("entry #" + entry.uid);
    if (!window.confirm(`Delete lorebook entry "${label}"? This cannot be undone.`)) return;
    const data = await request("POST", handlers.deleteUrl, {
      ...(handlers.extraBody || {}),
      uid: entry.uid,
    });
    if (data) onChange();
  });

  el.appendChild(header);
  el.appendChild(body);
  return el;
}
