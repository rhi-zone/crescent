// Group chat panel feature. Owns: #btn-group, #group-overlay, #group-close,
// #group-enabled, #group-turn-order, #group-member-list, #group-add-json,
// #group-add-btn — open/close, load/render members, toggle, turn order, add,
// remove. Focus-trap helpers (`trapFocus`/`releaseFocus`) are injected; they
// stay in app.js because every overlay shares them.

import { request } from "./api.js";

/**
 * @typedef {{
 *   name?: boolean,
 *   is_primary?: boolean
 * }} GroupMember
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
 * }}
 */
export function init(deps) {
  const onError = deps.showError;
  const trapFocus = deps.trapFocus;
  const releaseFocus = deps.releaseFocus;

  /** @type {HTMLButtonElement} */
  const btnGroup = /** @type {HTMLButtonElement} */ (document.getElementById("btn-group"));
  /** @type {HTMLElement} */
  const groupOverlay = /** @type {HTMLElement} */ (document.getElementById("group-overlay"));
  /** @type {HTMLButtonElement} */
  const groupClose = /** @type {HTMLButtonElement} */ (document.getElementById("group-close"));
  /** @type {HTMLInputElement} */
  const groupEnabledCheckbox = /** @type {HTMLInputElement} */ (document.getElementById("group-enabled"));
  /** @type {HTMLSelectElement} */
  const groupTurnOrder = /** @type {HTMLSelectElement} */ (document.getElementById("group-turn-order"));
  /** @type {HTMLElement} */
  const groupMemberList = /** @type {HTMLElement} */ (document.getElementById("group-member-list"));
  /** @type {HTMLTextAreaElement} */
  const groupAddJson = /** @type {HTMLTextAreaElement} */ (document.getElementById("group-add-json"));
  /** @type {HTMLButtonElement} */
  const groupAddBtn = /** @type {HTMLButtonElement} */ (document.getElementById("group-add-btn"));

  /** @type {boolean} */
  let groupEnabled = false;

  function openGroup() {
    groupOverlay.hidden = false;
    loadGroup();
    trapFocus(groupOverlay, btnGroup);
  }

  function closeGroup() {
    groupOverlay.hidden = true;
    releaseFocus();
  }

  btnGroup.addEventListener("click", openGroup);
  groupClose.addEventListener("click", closeGroup);
  groupOverlay.addEventListener("click", function (e) {
    if (e.target === groupOverlay) closeGroup();
  });
  groupOverlay.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && !groupOverlay.hidden) { e.stopPropagation(); closeGroup(); }
  });

  async function loadGroup() {
    const data = await request("GET", "/api/group", undefined, { onError });
    if (!data) return;
    groupEnabled = data.enabled;
    groupEnabledCheckbox.checked = data.enabled;
    groupTurnOrder.value = data.turn_order;
    renderGroupMembers(data.members);
  }

  /**
   * @param {GroupMember[]} members
   */
  function renderGroupMembers(members) {
    groupMemberList.innerHTML = "";
    for (const m of members) {
      const row = document.createElement("div");
      row.className = "group-member";
      const name = document.createElement("span");
      name.className = "group-member__name";
      name.textContent = /** @type {any} */ (m).name;
      if (m.is_primary) {
        const badge = document.createElement("span");
        badge.className = "group-member__badge";
        badge.textContent = "primary";
        name.appendChild(document.createTextNode(" "));
        name.appendChild(badge);
      }
      row.appendChild(name);
      if (!m.is_primary) {
        const removeBtn = document.createElement("button");
        removeBtn.className = "group-member__remove";
        removeBtn.textContent = "×";
        removeBtn.title = "Remove";
        removeBtn.addEventListener("click", async function () {
          const data = await request("POST", "/api/group/remove", { name: /** @type {any} */ (m).name }, { onError });
          if (data) renderGroupMembers(data.members);
        });
        row.appendChild(removeBtn);
      }
      groupMemberList.appendChild(row);
    }
  }

  groupEnabledCheckbox.addEventListener("change", async function () {
    const data = await request("POST", "/api/group/toggle", { enabled: groupEnabledCheckbox.checked }, { onError });
    if (data) {
      groupEnabled = data.enabled;
    }
  });

  groupTurnOrder.addEventListener("change", async function () {
    await request("POST", "/api/group/order", { turn_order: groupTurnOrder.value }, { onError });
  });

  groupAddBtn.addEventListener("click", async function () {
    const jsonStr = groupAddJson.value.trim();
    if (!jsonStr) return;
    const data = await request("POST", "/api/group/add", { card_json: jsonStr }, { onError });
    if (data) {
      groupAddJson.value = "";
      renderGroupMembers(data.members);
    }
  });

  return {
    open: openGroup,
    close: closeGroup,
    isOpen: function () { return !groupOverlay.hidden; },
    overlay: groupOverlay,
  };
}
