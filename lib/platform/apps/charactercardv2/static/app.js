import { request as apiRequest } from "./api.js";
import { init as initPersona } from "./persona.js";
import { init as initGroup } from "./group.js";
import { init as initRegex } from "./regex.js";
import { init as initSettings } from "./settings.js";
import { init as initSessions } from "./sessions.js";
import { init as initMyLorebooks } from "./my-lorebooks.js";
import { init as initCardEditor } from "./card-editor.js";
import { init as initCardLorebook } from "./card-lorebook.js";
import { init as initMessages } from "./messages.js";
import { init as initSend } from "./send.js";
import { init as initTokenCounter } from "./token-counter.js";
import { init as initChatExport } from "./chat-export.js";
import { init as initNewCard } from "./new-card.js";
import { init as initCardState } from "./card-state.js";
import { escAttr } from "./lorebook-entry.js";

/** @type {HTMLButtonElement} */
const btnCardHeaderEdit = /** @type {HTMLButtonElement} */ (document.getElementById("btn-card-header-edit"));

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
 * `showError` indirection: bootstrapped before `messages` exists (apiRequest
 * closures reference it). When messages is initialized below `_showError` is
 * re-pointed so errors append into the message list. Pre-messages calls hit
 * the console fallback.
 * @type {(text: string) => void}
 */
let _showError = (text) => { console.error("[ccv2]", text); };
/** @param {string} text */
function showError(text) { _showError(text); }

/**
 * Local wrapper that injects the app's `showError` as the api.js error sink,
 * so call sites can use `request(...)` exactly as before.
 *
 * @param {string} method
 * @param {string} path
 * @param {unknown} [body]
 * @param {{ silent?: boolean }} [opts_]
 * @returns {Promise<any>}
 */
function request(method, path, body, opts_) {
  return apiRequest(method, path, body, { silent: opts_?.silent, onError: showError });
}

// ── Token counter ──────────────────────────────────────────────────────────

const tokenCounter = initTokenCounter({ showError });
const fetchTokenCount = tokenCounter.refresh;
const updateTokenCounter = tokenCounter.update;

// ── Messaging core ────────────────────────────────────────────────────────
//
// Two coordinated modules:
//   - messages.js owns the list (#message-list), edit/delete/swipe state,
//     speaker color palette, sibling cache.
//   - send.js owns the send row (#input, #btn-send/#btn-continue/#btn-impersonate,
//     #loading) and SSE streaming. It uses the messages handle to render.
//
// Keyboard: the textarea-local Enter / Ctrl+Enter handler lives in send.js.
// The document-level Ctrl+Enter shortcut below still goes through btn-send.click().

const messages = initMessages({
  showError: function (m) { showError(m); },
  isBusy: function () { return send.isBusy(); },
  setBusy: function (v) { send.setBusy(v); },
  onReloadBelow: function () { /* edit-fork already removes children inline */ },
  onTokenCountStale: function () { fetchTokenCount(); },
});

// Re-point the showError indirection so errors append through messages.
_showError = function (text) {
  messages.addMessage({ id: "", role: "system", content: "Error: " + text });
};

const send = initSend({
  showError: function (m) { showError(m); },
  messages: messages,
  onSent: function () { fetchTokenCount(); },
  onTokenCount: function (data) { updateTokenCounter(data); },
});

// Re-export key helpers under their old names for the rest of app.js.
const addMessage = messages.addMessage;
const replaceMessages = messages.replaceMessages;
const setBusy = send.setBusy;
const btnSend = send.btnSend;

// ── Focus trap helpers ─────────────────────────────────────────────────────

/**
 * @type {Element | null}
 */
let lastFocusedBeforeOverlay = null;

/**
 * Move focus into overlay on open. Records the trigger so focus can be restored on close.
 * @param {HTMLElement} overlay
 * @param {Element | null} [triggerEl]
 */
function trapFocus(overlay, triggerEl) {
  lastFocusedBeforeOverlay = triggerEl || document.activeElement;
  const focusable = /** @type {HTMLElement | null} */ (overlay.querySelector(
    "button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])"
  ));
  if (focusable) focusable.focus();
}

/** Restore focus to the element that was active before the overlay opened. */
function releaseFocus() {
  if (lastFocusedBeforeOverlay && typeof /** @type {any} */ (lastFocusedBeforeOverlay).focus === "function") {
    /** @type {any} */ (lastFocusedBeforeOverlay).focus();
  }
  lastFocusedBeforeOverlay = null;
}

/**
 * Cycle Tab focus within the overlay so users can't tab out into background content.
 * Listener is permanent (overlays only receive keydown while visible).
 * @param {HTMLElement} overlay
 */
function setupFocusTrap(overlay) {
  overlay.addEventListener("keydown", function (e) {
    if (e.key !== "Tab") return;
    const focusable = overlay.querySelectorAll(
      "button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"
    );
    if (!focusable.length) return;
    const visible = Array.from(focusable).filter(function (el) {
      return /** @type {HTMLElement} */ (el).offsetParent !== null;
    });
    if (!visible.length) return;
    const first = /** @type {HTMLElement} */ (visible[0]);
    const last = /** @type {HTMLElement} */ (visible[visible.length - 1]);
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  });
}

// ── Persona / Settings / Sessions ─────────────────────────────────────────
// Initialized early because settings.reload() runs in the boot IIFE and
// the keyboard shortcut + closeAnyPanel handlers reference both.

const persona = initPersona({ showError });
const settings = initSettings({ showError, persona, trapFocus, releaseFocus });
const sessions = initSessions({
  showError: showError,
  setBusy: setBusy,
  isBusy: function () { return send.isBusy(); },
  onSessionSwitch: function (data) {
    if (data.session && data.session.id != null) {
      // switch / new
      replaceMessages(data.messages);
    } else if (data.messages !== undefined) {
      // delete
      replaceMessages(data.messages);
    }
    fetchTokenCount();
  },
  trapFocus: trapFocus,
  releaseFocus: releaseFocus,
});

// ── Card state (header, avatar, writable flag, history load) ──────────────

const cardState = initCardState({
  showError,
  messages,
  onCardLoaded: function () { fetchTokenCount(); },
});

// Init: load settings + card in parallel.
(async function () {
  setBusy(true);
  await Promise.all([
    settings.reload(),
    cardState.reload(),
  ]);
  setBusy(false);
})();

// ── Card Lorebook panel (extracted to card-lorebook.js) ─────────────────────

const cardLorebook = initCardLorebook({
  showError,
  getCardWritable: cardState.getCardWritable,
});

// ── My Lorebooks panel ─────────────────────────────────────────────────────

const myLorebooks = initMyLorebooks({ showError, trapFocus, releaseFocus });

// ── Card editor panel ──────────────────────────────────────────────────────
//
// Card editor extracted to ./card-editor.js. We expose the Author's Note
// loader and the card-side lorebook reload (cardLorebook.reload) so the
// card editor can trigger them when the respective tab is opened.

async function loadAuthorsNote() {
  const data = await request("GET", "/api/authors_note");
  if (data) {
    /** @type {HTMLTextAreaElement} */ (document.getElementById("an-text")).value = data.text || "";
    /** @type {HTMLInputElement} */ (document.getElementById("an-depth")).value = data.depth != null ? data.depth : 4;
    /** @type {HTMLSelectElement} */ (document.getElementById("an-position")).value = data.position || "after";
  }
}

const regex = initRegex({ showError, escAttr });

const cardEditor = initCardEditor({
  showError,
  trapFocus,
  releaseFocus,
  lorebookReload: cardLorebook.reload,
  regexReload: regex.reload,
  authorsNoteLoad: loadAuthorsNote,
  getCardWritable: cardState.getCardWritable,
});

btnCardHeaderEdit.addEventListener("click", function () { cardEditor.open("identity"); });

// ── Card-header burger menu (mobile <768px) ───────────────────────────────
//
// Toggles `.card-header--menu-open` on the header which reveals the action
// row as a dropdown. The button itself is hidden at desktop widths via CSS,
// so the handler is inert there. Escape closes it (via closeAnyPanel below);
// clicking an action also closes it.

/** @type {HTMLButtonElement | null} */
const btnCardHeaderBurger = /** @type {HTMLButtonElement | null} */ (document.getElementById("btn-card-header-burger"));
/** @type {HTMLElement | null} */
const cardHeaderEl = /** @type {HTMLElement | null} */ (document.getElementById("card-header"));

/** @param {boolean} open */
function setCardHeaderMenu(open) {
  if (!btnCardHeaderBurger || !cardHeaderEl) return;
  cardHeaderEl.classList.toggle("card-header--menu-open", open);
  btnCardHeaderBurger.setAttribute("aria-expanded", open ? "true" : "false");
}

/** @returns {boolean} */
function isCardHeaderMenuOpen() {
  return !!cardHeaderEl && cardHeaderEl.classList.contains("card-header--menu-open");
}

if (btnCardHeaderBurger) {
  btnCardHeaderBurger.addEventListener("click", function () {
    const open = !isCardHeaderMenuOpen();
    setCardHeaderMenu(open);
    if (open && cardHeaderEl) {
      const first = /** @type {HTMLElement | null} */ (cardHeaderEl.querySelector(".card-header__actions button, .card-header__actions a"));
      if (first) first.focus();
    }
  });

  const actionsEl = document.getElementById("card-header-actions");
  if (actionsEl) {
    actionsEl.addEventListener("click", function () {
      setCardHeaderMenu(false);
    });
  }
}

// ── Chat export ────────────────────────────────────────────────────────────

const chatExport = initChatExport({ showError });
const exportChat = chatExport.exportChat;

// ── Keyboard shortcuts ────────────────────────────────────────────────────

/**
 * @returns {boolean}
 */
function closeAnyPanel() {
  if (settings.isOpen()) { settings.close(); return true; }
  if (myLorebooks.isOpen()) { myLorebooks.close(); return true; }
  if (cardEditor.isOpen()) { cardEditor.close(); return true; }
  if (group.isOpen()) { group.close(); return true; }
  if (sessions.isOpen()) { sessions.close(); return true; }
  if (isCardHeaderMenuOpen()) { setCardHeaderMenu(false); return true; }
  return false;
}

document.addEventListener("keydown", function (e) {
  const mod = e.ctrlKey || e.metaKey;

  // Escape — close any open panel
  if (e.key === "Escape") {
    if (closeAnyPanel()) { e.preventDefault(); return; }
  }

  // Ctrl+Enter / Cmd+Enter — send message
  if (mod && e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    btnSend.click();
    return;
  }

  // Ctrl+Shift shortcuts
  if (mod && e.shiftKey) {
    switch (e.key) {
      case "S": settings.open(); e.preventDefault(); break;
      case "L": cardEditor.open("lorebook"); e.preventDefault(); break;
      case "W": myLorebooks.open(); e.preventDefault(); break;
      case "E": exportChat("text"); e.preventDefault(); break;
      case "N": sessions.newSession(); e.preventDefault(); break;
    }
  }
});

// ── Group chat panel ──────────────────────────────────────────────────────

const group = initGroup({ showError, trapFocus, releaseFocus });

// ── New Card ───────────────────────────────────────────────────────────────

initNewCard({
  showError,
  onFallbackDownload: function () {
    addMessage({
      id: "",
      role: "system",
      content: "Card downloaded — import it to get started",
    });
  },
});

// Register focus traps for all overlays so Tab cycles within the dialog.
setupFocusTrap(settings.overlay);
setupFocusTrap(myLorebooks.overlay);
setupFocusTrap(cardEditor.overlay);
setupFocusTrap(group.overlay);
setupFocusTrap(sessions.panel);
