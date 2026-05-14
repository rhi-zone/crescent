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
import { escAttr } from "./lorebook-entry.js";

/** @type {HTMLElement} */
const tokenCountText = /** @type {HTMLElement} */ (document.getElementById("token-count-text"));
/** @type {HTMLElement} */
const tokenCountFill = /** @type {HTMLElement} */ (document.getElementById("token-count-fill"));

/** @type {HTMLElement} */
const cardHeader = /** @type {HTMLElement} */ (document.getElementById("card-header"));
/** @type {HTMLImageElement} */
const cardAvatar = /** @type {HTMLImageElement} */ (document.getElementById("card-avatar"));
/** @type {HTMLElement} */
const cardHeaderName = /** @type {HTMLElement} */ (document.getElementById("card-header-name"));
/** @type {HTMLButtonElement} */
const btnNewCard = /** @type {HTMLButtonElement} */ (document.getElementById("btn-new-card"));
/** @type {HTMLButtonElement} */
const btnCardHeaderEdit = /** @type {HTMLButtonElement} */ (document.getElementById("btn-card-header-edit"));
/** @type {HTMLAnchorElement} */
const btnCardHeaderExport = /** @type {HTMLAnchorElement} */ (document.getElementById("btn-card-header-export"));

/** Whether the loaded card can write back to its PNG (caps.self_write granted). */
let cardWritable = false;

/**
 * @typedef {{
 *   context_used?: number,
 *   context_max?: number
 * }} TokenCountData
 */

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

/**
 * @param {TokenCountData | null | undefined} data
 */
function updateTokenCounter(data) {
  if (!data) return;
  const used = data.context_used || 0;
  const max = data.context_max || 4096;
  tokenCountText.textContent = used + " / " + max;
  const pct = max > 0 ? Math.min(100, (used / max) * 100) : 0;
  tokenCountFill.style.width = pct + "%";
  tokenCountFill.className = "token-counter__fill" +
    (pct > 80 ? " token-counter__fill--danger" :
     pct > 50 ? " token-counter__fill--warn" : "");
}

async function fetchTokenCount() {
  const data = await request("GET", "/api/token_count");
  if (data) updateTokenCounter(data);
}

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

// Check avatar availability (HEAD request avoids downloading the full image)
async function checkAvatar() {
  try {
    const res = await fetch("/api/avatar", { method: "HEAD" });
    if (res.ok) {
      messages.setHasAvatar(true);
      cardAvatar.hidden = false;
    } else {
      cardAvatar.hidden = true;
    }
  } catch {
    cardAvatar.hidden = true;
  }
}

// Init
(async function () {
  setBusy(true);
  const [card, history] = await Promise.all([
    request("GET", "/api/card", undefined, { silent: true }),
    request("GET", "/api/messages", undefined, { silent: true }),
    settings.reload(),
    checkAvatar(),
  ]);
  setBusy(false);

  cardHeader.hidden = false;
  if (card) {
    document.title = card.name || "Character Card v2";
    cardHeaderName.textContent = card.name || "";
    cardWritable = card.writable === true;
    if (card.name) {
      const safeName = card.name.replace(/[/\\:*?"<>|]/g, "_");
      btnCardHeaderExport.download = safeName + ".png";
    }
    btnCardHeaderEdit.hidden = false;
    btnCardHeaderExport.hidden = false;
  } else {
    btnCardHeaderEdit.hidden = true;
    btnCardHeaderExport.hidden = true;
    addMessage({ id: "", role: "system", content: "No card loaded. Go to the library to import or create a card." });
  }

  if (history && history.messages && history.messages.length > 0) {
    for (const msg of history.messages) addMessage(msg);
  } else if (card && card.greeting) {
    addMessage(card.greeting);
  }

  fetchTokenCount();
})();

// ── Card Lorebook panel (extracted to card-lorebook.js) ─────────────────────

const cardLorebook = initCardLorebook({
  showError,
  getCardWritable: function () { return cardWritable; },
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
  getCardWritable: function () { return cardWritable; },
});

btnCardHeaderEdit.addEventListener("click", function () { cardEditor.open("identity"); });

// ── Chat export ────────────────────────────────────────────────────────────

/** @type {HTMLButtonElement} */
const btnCardHeaderExportChat = /** @type {HTMLButtonElement} */ (document.getElementById("btn-card-header-export-chat"));

btnCardHeaderExportChat.addEventListener("click", function () {
  const format = prompt("Export format: type 'json' for JSON, or press OK for plain text", "text");
  if (format === null) return; // cancelled
  exportChat(format === "json" ? "json" : "text");
});

/**
 * @param {string} format
 */
async function exportChat(format) {
  const res = await fetch("/api/export/chat?format=" + format);
  if (!res.ok) return;
  const blob = await res.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  const disp = res.headers.get("content-disposition");
  if (disp) {
    const match = disp.match(/filename="?([^"]+)"?/);
    if (match) a.download = match[1];
  }
  if (!a.download) a.download = "chat." + (format === "json" ? "json" : "txt");
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

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

btnNewCard.addEventListener("click", async function () {
  try {
    const res = await fetch("/api/new-card", { method: "POST" });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      showError((data && data.error) ? data.error : "Failed to create new card");
      return;
    }
    const buf = await res.arrayBuffer();
    // Try to install directly via the daemon's import endpoint.
    try {
      const importRes = await fetch("/api/apps", {
        method: "POST",
        headers: { "Content-Type": "image/png" },
        body: buf,
      });
      if (importRes.ok) {
        const data = await importRes.json();
        window.location.href = data.launch_url;
        return;
      }
    } catch (_) { /* fall through to download */ }
    // Fallback: download the PNG and inform the user.
    const blob = new Blob([buf], { type: "image/png" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "new-character.png";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    addMessage({ id: "", role: "system", content: "Card downloaded — import it to get started" });
  } catch (e) {
    showError(e instanceof Error ? e.message : String(e));
  }
});

// Register focus traps for all overlays so Tab cycles within the dialog.
setupFocusTrap(settings.overlay);
setupFocusTrap(myLorebooks.overlay);
setupFocusTrap(cardEditor.overlay);
setupFocusTrap(group.overlay);
setupFocusTrap(sessions.panel);
