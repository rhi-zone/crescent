// Regex scripts tab content. Owns: #regex-add, #regex-list, #regex-test-find,
// #regex-test-replace, #regex-test-input, #regex-test-btn, #regex-test-output —
// list/add/save/delete regex scripts plus a Lua-pattern test area. The tab
// itself is owned by the card editor (open/close/switch); this module renders
// the contents and wires the handlers. `escAttr` is injected because it's a
// shared HTML-escaping helper used by other panels (lorebook etc.).

import { request } from "./api.js";

/**
 * @typedef {{
 *   name: string,
 *   find: string,
 *   replace: string,
 *   enabled: boolean,
 *   scope: string,
 *   order?: number
 * }} RegexScript
 */

/** @type {{ [key: string]: string }} */
const SCOPE_LABELS = { ai_output: "AI Output", user_input: "User Input", display: "Display" };

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   escAttr: (s: string) => string,
 * }} deps
 * @returns {{ reload: () => Promise<void> }}
 */
export function init(deps) {
  const onError = deps.showError;
  const escAttr = deps.escAttr;

  /** @type {HTMLButtonElement} */
  const regexAdd = /** @type {HTMLButtonElement} */ (document.getElementById("regex-add"));
  /** @type {HTMLElement} */
  const regexList = /** @type {HTMLElement} */ (document.getElementById("regex-list"));
  /** @type {HTMLInputElement} */
  const regexTestFind = /** @type {HTMLInputElement} */ (document.getElementById("regex-test-find"));
  /** @type {HTMLInputElement} */
  const regexTestReplace = /** @type {HTMLInputElement} */ (document.getElementById("regex-test-replace"));
  /** @type {HTMLInputElement} */
  const regexTestInput = /** @type {HTMLInputElement} */ (document.getElementById("regex-test-input"));
  /** @type {HTMLButtonElement} */
  const regexTestBtn = /** @type {HTMLButtonElement} */ (document.getElementById("regex-test-btn"));
  /** @type {HTMLElement} */
  const regexTestOutput = /** @type {HTMLElement} */ (document.getElementById("regex-test-output"));

  async function loadRegex() {
    const data = await request("GET", "/api/regex", undefined, { onError });
    if (!data) return;
    renderRegexScripts(data.scripts);
  }

  /**
   * @param {RegexScript[] | null | undefined} scripts
   */
  function renderRegexScripts(scripts) {
    regexList.innerHTML = "";
    if (!scripts || scripts.length === 0) {
      regexList.innerHTML = '<div class="regex-empty">No regex scripts. Click "+ Add Script" to create one.</div>';
      return;
    }
    for (const script of scripts) {
      regexList.appendChild(createRegexEntryEl(script));
    }
  }

  /**
   * @param {RegexScript} script
   * @returns {HTMLElement}
   */
  function createRegexEntryEl(script) {
    const el = document.createElement("div");
    el.className = "regex-entry" + (script.enabled ? "" : " regex-entry--disabled");

    const header = document.createElement("div");
    header.className = "regex-entry__header";

    const toggle = document.createElement("button");
    toggle.className = "regex-entry__toggle" + (script.enabled ? " regex-entry__toggle--on" : "");
    toggle.title = script.enabled ? "Enabled" : "Disabled";
    toggle.addEventListener("click", async function (e) {
      e.stopPropagation();
      const newEnabled = !script.enabled;
      const data = await request("POST", "/api/regex/save", {
        name: script.name, find: script.find, replace: script.replace,
        enabled: newEnabled, scope: script.scope, order: script.order,
      }, { onError });
      if (data) {
        script.enabled = newEnabled;
        toggle.className = "regex-entry__toggle" + (newEnabled ? " regex-entry__toggle--on" : "");
        toggle.title = newEnabled ? "Enabled" : "Disabled";
        el.className = "regex-entry" + (newEnabled ? "" : " regex-entry--disabled");
      }
    });

    const name = document.createElement("span");
    name.className = "regex-entry__name";
    name.textContent = script.name;

    const scope = document.createElement("span");
    scope.className = "regex-entry__scope";
    scope.textContent = SCOPE_LABELS[script.scope] || script.scope;

    const arrow = document.createElement("span");
    arrow.className = "regex-entry__expand";
    arrow.textContent = "▶";

    header.appendChild(toggle);
    header.appendChild(name);
    header.appendChild(scope);
    header.appendChild(arrow);

    const body = document.createElement("div");
    body.className = "regex-entry__body";
    body.hidden = true;

    body.innerHTML = `
      <div class="regex-entry__field">
        <label class="regex-entry__label">Name</label>
        <input class="regex-entry__input" data-field="name" value="${escAttr(script.name)}">
      </div>
      <div class="regex-entry__field">
        <label class="regex-entry__label">Find (Lua pattern)</label>
        <input class="regex-entry__input regex-entry__input--mono" data-field="find" value="${escAttr(script.find)}">
      </div>
      <div class="regex-entry__field">
        <label class="regex-entry__label">Replace</label>
        <input class="regex-entry__input regex-entry__input--mono" data-field="replace" value="${escAttr(script.replace)}">
      </div>
      <div class="regex-entry__row">
        <div class="regex-entry__field">
          <label class="regex-entry__label">Scope</label>
          <select class="regex-entry__input" data-field="scope">
            <option value="ai_output"${script.scope === "ai_output" ? " selected" : ""}>AI Output</option>
            <option value="user_input"${script.scope === "user_input" ? " selected" : ""}>User Input</option>
            <option value="display"${script.scope === "display" ? " selected" : ""}>Display</option>
          </select>
        </div>
        <div class="regex-entry__field">
          <label class="regex-entry__label">Order</label>
          <input type="number" class="regex-entry__input" data-field="order" value="${script.order || 0}">
        </div>
      </div>
      <div class="regex-entry__actions">
        <button class="regex-entry__delete">Delete</button>
        <button class="regex-entry__save">Save</button>
      </div>
    `;

    header.addEventListener("click", function () {
      body.hidden = !body.hidden;
      arrow.textContent = body.hidden ? "▶" : "▼";
    });

    /** @type {HTMLButtonElement} */ (body.querySelector(".regex-entry__save")).addEventListener("click", async function () {
      const newName = /** @type {HTMLInputElement} */ (body.querySelector('[data-field="name"]')).value.trim();
      if (!newName) return;
      const data = await request("POST", "/api/regex/save", {
        name: newName,
        find: /** @type {HTMLInputElement} */ (body.querySelector('[data-field="find"]')).value,
        replace: /** @type {HTMLInputElement} */ (body.querySelector('[data-field="replace"]')).value,
        scope: /** @type {HTMLSelectElement} */ (body.querySelector('[data-field="scope"]')).value,
        order: parseInt(/** @type {HTMLInputElement} */ (body.querySelector('[data-field="order"]')).value, 10) || 0,
        enabled: script.enabled,
      }, { onError });
      if (data) loadRegex();
    });

    /** @type {HTMLButtonElement} */ (body.querySelector(".regex-entry__delete")).addEventListener("click", async function () {
      if (!window.confirm(`Delete regex script "${script.name}"? This cannot be undone.`)) return;
      const data = await request("POST", "/api/regex/delete", { name: script.name }, { onError });
      if (data) loadRegex();
    });

    el.appendChild(header);
    el.appendChild(body);
    return el;
  }

  regexAdd.addEventListener("click", async function () {
    const data = await request("POST", "/api/regex/save", {
      name: "New Script",
      find: "",
      replace: "",
      scope: "ai_output",
      order: 0,
    }, { onError });
    if (data) loadRegex();
  });

  regexTestBtn.addEventListener("click", async function () {
    const find = regexTestFind.value;
    const replace = regexTestReplace.value;
    const inputVal = regexTestInput.value;
    if (!find || !inputVal) return;
    const data = await request("POST", "/api/regex/test", { find: find, replace: replace, input: inputVal }, { onError });
    if (data) {
      regexTestOutput.textContent = data.output;
    }
  });

  return { reload: loadRegex };
}
