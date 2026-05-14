// Persona panel feature. Owns: #persona-select, #persona-name,
// #persona-description, #persona-new, #persona-delete, #persona-save —
// list/load/save/delete/activate flows for user personas.

import { request } from "./api.js";

/**
 * @typedef {{ name: string, description?: string }} Persona
 */

/**
 * Wire up the persona panel. Captures DOM refs and event handlers internally.
 *
 * @param {{ showError: (msg: string) => void }} deps
 * @returns {{ reload: () => Promise<void> }}
 */
export function init(deps) {
  const onError = deps.showError;

  /** @type {HTMLSelectElement} */
  const personaSelect = /** @type {HTMLSelectElement} */ (document.getElementById("persona-select"));
  /** @type {HTMLInputElement} */
  const personaName = /** @type {HTMLInputElement} */ (document.getElementById("persona-name"));
  /** @type {HTMLTextAreaElement} */
  const personaDescription = /** @type {HTMLTextAreaElement} */ (document.getElementById("persona-description"));
  /** @type {HTMLButtonElement} */
  const personaNew = /** @type {HTMLButtonElement} */ (document.getElementById("persona-new"));
  /** @type {HTMLButtonElement} */
  const personaDelete = /** @type {HTMLButtonElement} */ (document.getElementById("persona-delete"));
  /** @type {HTMLButtonElement} */
  const personaSave = /** @type {HTMLButtonElement} */ (document.getElementById("persona-save"));

  /** @type {Persona[]} */
  let personaList = [];

  /**
   * @param {Persona[] | null | undefined} personas
   * @param {string} active
   */
  function populatePersonaSelect(personas, active) {
    personaSelect.innerHTML = "";
    personaList = personas || [];
    for (const p of personaList) {
      const opt = document.createElement("option");
      opt.value = p.name;
      opt.textContent = p.name;
      if (p.name === active) opt.selected = true;
      personaSelect.appendChild(opt);
    }
    showSelectedPersona();
  }

  function showSelectedPersona() {
    const name = personaSelect.value;
    const p = personaList.find(function (x) { return x.name === name; });
    personaName.value = p ? p.name : "";
    personaDescription.value = p ? (p.description || "") : "";
  }

  async function loadPersonas() {
    const data = await request("GET", "/api/personas", undefined, { onError });
    if (data) populatePersonaSelect(data.personas, data.active);
  }

  personaSelect.addEventListener("change", async function () {
    showSelectedPersona();
    await request("POST", "/api/personas/activate", { name: personaSelect.value }, { onError });
  });

  personaNew.addEventListener("click", function () {
    personaName.value = "";
    personaDescription.value = "";
    personaName.focus();
  });

  personaDelete.addEventListener("click", async function () {
    const name = personaSelect.value;
    if (!name) return;
    if (!window.confirm(`Delete persona "${name}"? This cannot be undone.`)) return;
    const data = await request("POST", "/api/personas/delete", { name: name }, { onError });
    if (data) loadPersonas();
  });

  personaSave.addEventListener("click", async function () {
    const name = personaName.value.trim();
    if (!name) return;
    const data = await request("POST", "/api/personas/save", {
      name: name,
      description: personaDescription.value,
    }, { onError });
    if (data) {
      await request("POST", "/api/personas/activate", { name: name }, { onError });
      loadPersonas();
    }
  });

  return { reload: loadPersonas };
}
