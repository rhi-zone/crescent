// Settings overlay feature. Owns: #btn-settings, #settings-overlay,
// #settings-close, #settings-save, all #set-* generation inputs + #val-*
// labels, #btn-test-connection + #connection-result. Persona section inside
// the settings panel is owned by persona.js; this module just calls
// `persona.reload()` when the overlay opens. Focus-trap helpers stay in
// app.js and are injected.

import { request } from "./api.js";

/**
 * @typedef {{
 *   temperature?: number,
 *   top_p?: number,
 *   frequency_penalty?: number,
 *   presence_penalty?: number,
 *   max_tokens?: number,
 *   max_context?: number,
 *   [key: string]: number | undefined
 * }} Settings
 */

const SETTINGS_RANGE_KEYS = ["temperature", "top_p", "frequency_penalty", "presence_penalty"];
const SETTINGS_NUMBER_KEYS = ["max_tokens", "max_context"];
const SETTINGS_ALL_KEYS = [...SETTINGS_RANGE_KEYS, ...SETTINGS_NUMBER_KEYS];

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   persona: { reload: () => Promise<void> | void },
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
  const onError = deps.showError;
  const persona = deps.persona;
  const trapFocus = deps.trapFocus;
  const releaseFocus = deps.releaseFocus;

  /** @type {HTMLButtonElement} */
  const btnSettings = /** @type {HTMLButtonElement} */ (document.getElementById("btn-settings"));
  /** @type {HTMLElement} */
  const settingsOverlay = /** @type {HTMLElement} */ (document.getElementById("settings-overlay"));
  /** @type {HTMLButtonElement} */
  const settingsClose = /** @type {HTMLButtonElement} */ (document.getElementById("settings-close"));
  /** @type {HTMLButtonElement} */
  const settingsSave = /** @type {HTMLButtonElement} */ (document.getElementById("settings-save"));

  /**
   * @param {Settings} settings
   */
  function populateSettings(settings) {
    for (const key of SETTINGS_ALL_KEYS) {
      const el = /** @type {HTMLInputElement | null} */ (document.getElementById("set-" + key));
      if (el && settings[key] != null) el.value = String(settings[key]);
      const valEl = document.getElementById("val-" + key);
      if (valEl && settings[key] != null) valEl.textContent = String(settings[key]);
    }
  }

  /**
   * @returns {Settings}
   */
  function readSettings() {
    /** @type {Settings} */
    const s = {};
    for (const key of SETTINGS_ALL_KEYS) {
      const el = /** @type {HTMLInputElement | null} */ (document.getElementById("set-" + key));
      if (el) s[key] = parseFloat(el.value);
    }
    return s;
  }

  // Live value display for range sliders.
  for (const key of SETTINGS_RANGE_KEYS) {
    const el = /** @type {HTMLInputElement | null} */ (document.getElementById("set-" + key));
    const valEl = document.getElementById("val-" + key);
    if (el && valEl) {
      el.addEventListener("input", function () { valEl.textContent = el.value; });
    }
  }

  function openSettings() {
    settingsOverlay.hidden = false;
    persona.reload();
    trapFocus(settingsOverlay, btnSettings);
  }

  function closeSettings() {
    settingsOverlay.hidden = true;
    releaseFocus();
  }

  btnSettings.addEventListener("click", openSettings);
  settingsClose.addEventListener("click", closeSettings);
  settingsOverlay.addEventListener("click", function (e) {
    if (e.target === settingsOverlay) closeSettings();
  });

  settingsSave.addEventListener("click", async function () {
    const data = await request("POST", "/api/settings", readSettings(), { onError });
    if (data) {
      populateSettings(data);
      closeSettings();
    }
  });

  async function loadSettings() {
    const data = await request("GET", "/api/settings", undefined, { onError });
    if (data) populateSettings(data);
  }

  // Connection test.
  /** @type {HTMLButtonElement | null} */
  const btnTestConnection = /** @type {HTMLButtonElement | null} */ (document.getElementById("btn-test-connection"));
  /** @type {HTMLElement | null} */
  const connectionResult = /** @type {HTMLElement | null} */ (document.getElementById("connection-result"));

  if (btnTestConnection && connectionResult) {
    btnTestConnection.addEventListener("click", async function () {
      btnTestConnection.disabled = true;
      btnTestConnection.textContent = "Testing...";
      connectionResult.textContent = "";
      connectionResult.className = "connection-result";
      try {
        const res = await fetch("/api/connection/test", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        });
        const data = await res.json();
        if (data.success) {
          connectionResult.textContent = "Connected! (" + data.latency_ms + " ms) — " + data.response;
          connectionResult.className = "connection-result connection-result--success";
        } else {
          connectionResult.textContent = "Failed: " + data.error;
          connectionResult.className = "connection-result connection-result--error";
        }
      } catch (e) {
        connectionResult.textContent = "Failed: " + (e instanceof Error ? e.message : String(e));
        connectionResult.className = "connection-result connection-result--error";
      }
      btnTestConnection.disabled = false;
      btnTestConnection.textContent = "Test Connection";
      setTimeout(function () {
        connectionResult.textContent = "";
        connectionResult.className = "connection-result";
      }, 5000);
    });
  }

  return {
    open: openSettings,
    close: closeSettings,
    isOpen: function () { return !settingsOverlay.hidden; },
    overlay: settingsOverlay,
    reload: loadSettings,
  };
}
