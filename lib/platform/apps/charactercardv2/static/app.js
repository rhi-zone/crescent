import { renderMarkdown } from "./markdown.js";
import { request as apiRequest } from "./api.js";
import { init as initPersona } from "./persona.js";
import { init as initGroup } from "./group.js";
import { init as initRegex } from "./regex.js";
import { init as initSettings } from "./settings.js";
import { init as initSessions } from "./sessions.js";
import { init as initMyLorebooks } from "./my-lorebooks.js";
import { init as initCardEditor } from "./card-editor.js";
import { init as initCardLorebook } from "./card-lorebook.js";
import { escAttr } from "./lorebook-entry.js";

/** @type {HTMLElement} */
const messageList = /** @type {HTMLElement} */ (document.getElementById("message-list"));
/** @type {HTMLTextAreaElement} */
const input = /** @type {HTMLTextAreaElement} */ (document.getElementById("input"));
/** @type {HTMLButtonElement} */
const btnSend = /** @type {HTMLButtonElement} */ (document.getElementById("btn-send"));
/** @type {HTMLButtonElement} */
const btnContinue = /** @type {HTMLButtonElement} */ (document.getElementById("btn-continue"));
/** @type {HTMLButtonElement} */
const btnImpersonate = /** @type {HTMLButtonElement} */ (document.getElementById("btn-impersonate"));
/** @type {HTMLElement} */
const loading = /** @type {HTMLElement} */ (document.getElementById("loading"));
/** @type {HTMLTemplateElement} */
const template = /** @type {HTMLTemplateElement} */ (document.getElementById("message-template"));

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

/** @type {boolean} */
let busy = false;
/** Whether the loaded card can write back to its PNG (caps.self_write granted). */
let cardWritable = false;
/** @type {boolean} */
let hasAvatar = false;

/**
 * @typedef {{ id: string, content: string, index: number }} SiblingEntry
 * @typedef {{ siblings: SiblingEntry[], current: number }} SiblingCacheEntry
 */

// Sibling cache: message_id -> {siblings: [{id, content, index}], current: index}
/** @type {Map<string, SiblingCacheEntry>} */
const siblingCache = new Map();

/**
 * @typedef {{
 *   id?: string,
 *   role: string,
 *   content: string,
 *   speaker?: string,
 *   sibling_index?: number,
 *   sibling_count?: number,
 *   swipe_index?: number,
 *   swipe_total?: number,
 *   token?: string,
 *   type?: string,
 *   error?: string,
 *   reload_below?: boolean
 * }} Message
 */

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
 * @param {boolean} v
 */
function setBusy(v) {
  busy = v;
  btnSend.disabled = v;
  btnContinue.disabled = v;
  btnImpersonate.disabled = v;
  loading.classList.toggle("loading-indicator--visible", v);
}

function scrollToBottom() {
  messageList.scrollTop = messageList.scrollHeight;
}

// Normalize response: backend uses sibling_index/sibling_count
/**
 * @param {Message} msg
 * @returns {number}
 */
function siblingIndex(msg) {
  return msg.sibling_index != null ? msg.sibling_index : (msg.swipe_index || 0);
}
/**
 * @param {Message} msg
 * @returns {number}
 */
function siblingCount(msg) {
  return msg.sibling_count != null ? msg.sibling_count : (msg.swipe_total || 1);
}

// Set rendered markdown content on a message element.
// Stores raw text in dataset for edit mode.
/**
 * @param {HTMLElement} el
 * @param {string} content
 */
function setMessageContent(el, content) {
  const contentEl = el.querySelector(".message__content");
  el.dataset.rawContent = content || "";
  /** @type {HTMLElement} */ (contentEl).innerHTML = renderMarkdown(content || "");
}

// Group chat speaker color palette
const SPEAKER_COLORS = [
  "var(--bg-message)", "#1a3a2e", "#2e1a3a", "#1a2e3a", "#3a2e1a",
  "#2a1a2e", "#1a3a3a", "#3a1a2a",
];
/** @type {Map<string, string>} */
const speakerColorMap = new Map();
let nextColorIndex = 0;

/**
 * @param {string | undefined} name
 * @returns {string | null}
 */
function getSpeakerColor(name) {
  if (!name) return null;
  if (speakerColorMap.has(name)) return speakerColorMap.get(name) ?? null;
  const color = SPEAKER_COLORS[nextColorIndex % SPEAKER_COLORS.length];
  nextColorIndex++;
  speakerColorMap.set(name, color);
  return color;
}

// Add a message to the list. Returns the DOM element.
/**
 * @param {Message} msg
 * @returns {HTMLElement}
 */
function addMessage(msg) {
  const el = /** @type {HTMLElement} */ (/** @type {DocumentFragment} */ (template.content.cloneNode(true)).firstElementChild);
  el.classList.add("message--" + msg.role);
  el.dataset.id = msg.id || "";
  if (hasAvatar && msg.role === "assistant") {
    const avatarEl = /** @type {HTMLImageElement} */ (el.querySelector(".message__avatar"));
    avatarEl.hidden = false;
    // In group chat the avatar represents a specific speaker — name it.
    // In single-character chat alt stays empty (decorative; speaker is implicit).
    if (msg.speaker) avatarEl.alt = msg.speaker + " avatar";
  }
  // Show speaker name for group chat messages
  if (msg.speaker && msg.role === "assistant") {
    const speakerEl = /** @type {HTMLElement} */ (el.querySelector(".message__speaker"));
    speakerEl.textContent = msg.speaker;
    speakerEl.hidden = false;
    el.style.background = getSpeakerColor(msg.speaker) || "";
  }
  setMessageContent(el, msg.content);
  updateSwipeUI(el, siblingIndex(msg), siblingCount(msg));
  messageList.appendChild(el);
  scrollToBottom();
  return el;
}

/**
 * @param {HTMLElement} el
 * @param {number} index
 * @param {number | null | undefined} total
 */
function updateSwipeUI(el, index, total) {
  const swipe = /** @type {HTMLElement} */ (el.querySelector(".message__swipe"));
  if (total == null || total <= 1) {
    swipe.hidden = true;
    return;
  }
  swipe.hidden = false;
  /** @type {HTMLElement} */ (el.querySelector(".message__swipe-label")).textContent =
    (index + 1) + "/" + total;
}

/**
 * @param {HTMLElement} el
 * @param {Message} msg
 */
function updateMessage(el, msg) {
  setMessageContent(el, msg.content);
  if (msg.id) el.dataset.id = msg.id;
  updateSwipeUI(el, siblingIndex(msg), siblingCount(msg));
}

/**
 * @param {string} text
 */
function showError(text) {
  addMessage({ id: "", role: "system", content: "Error: " + text });
}

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

// Fetch and cache all siblings for a message.
/**
 * @param {string} messageId
 * @returns {Promise<SiblingCacheEntry | null>}
 */
async function ensureSiblings(messageId) {
  if (siblingCache.has(messageId)) return siblingCache.get(messageId) ?? null;
  const data = await request("GET", "/api/swipes?message_id=" + messageId);
  if (!data) return null;
  const entry = { siblings: data.swipes, current: data.current };
  siblingCache.set(messageId, entry);
  return entry;
}

// Navigate to a sibling by index (from cache). Returns the sibling or null.
/**
 * @param {string} messageId
 * @param {number} index
 * @returns {Message | null}
 */
function navigateSibling(messageId, index) {
  const entry = siblingCache.get(messageId);
  if (!entry || index < 0 || index >= entry.siblings.length) return null;
  entry.current = index;
  const s = entry.siblings[index];
  return {
    id: s.id,
    content: s.content,
    sibling_index: index,
    sibling_count: entry.siblings.length,
    role: "assistant",
  };
}

// Add a newly generated sibling to the cache
/**
 * @param {string} messageId
 * @param {SiblingEntry} sibling
 */
function addSiblingToCache(messageId, sibling) {
  const entry = siblingCache.get(messageId);
  if (!entry) return;
  entry.siblings.push(sibling);
  entry.current = entry.siblings.length - 1;
}

/**
 * @param {string} id
 * @returns {HTMLElement | null}
 */
function findMessageEl(id) {
  return /** @type {HTMLElement | null} */ (messageList.querySelector('.message[data-id="' + id + '"]'));
}

// Remove all message elements after (and optionally including) a given element
/**
 * @param {HTMLElement} el
 * @param {boolean} inclusive
 */
function removeMessagesFrom(el, inclusive) {
  const messages = Array.from(messageList.querySelectorAll(".message"));
  let found = false;
  for (const m of messages) {
    if (m === el) found = true;
    if (found && (inclusive || m !== el)) m.remove();
  }
}

// Reload full message list from server
async function reloadMessages() {
  const data = await request("GET", "/api/messages");
  if (!data || !data.messages) return;
  messageList.innerHTML = "";
  siblingCache.clear();
  for (const msg of data.messages) addMessage(msg);
}

// Enter to send, Shift+Enter for newline, Ctrl+Enter also sends
input.addEventListener("keydown", function (e) {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    btnSend.click();
  } else if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    btnSend.click();
  }
});

// Streaming send via SSE over fetch
/**
 * @param {string} text
 */
async function sendStreaming(text) {
  setBusy(true);
  /** @type {HTMLElement | null} */
  let assistantEl = null;
  let contentSoFar = "";
  try {
    const res = await fetch("/api/message/stream", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content: text }),
    });
    if (!res.ok || !res.body) {
      const data = await res.json();
      setBusy(false);
      if (data && data.error) { showError(data.error); return; }
      if (data) {
        if (data.user) addMessage(data.user);
        if (data.assistant) addMessage(data.assistant);
        if (data.assistants) {
          for (const a of data.assistants) addMessage(a);
        }
      }
      return;
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const parts = buffer.split("\n\n");
      // parts.pop() returns the incomplete trailing chunk (may be "")
      buffer = parts.pop() ?? "";
      for (const part of parts) {
        for (const line of part.split("\n")) {
          if (!line.startsWith("data: ")) continue;
          /** @type {Message} */
          let event;
          try { event = JSON.parse(line.slice(6)); } catch { continue; }
          if (event.type === "user") {
            addMessage({ id: event.id, role: "user", content: event.content });
          } else if (event.type === "token") {
            if (!assistantEl) {
              assistantEl = addMessage({ id: "", role: "assistant", content: "" });
              /** @type {HTMLElement} */ (assistantEl.querySelector(".message__content")).classList.add("message__content--streaming");
            }
            contentSoFar += event.token;
            // Plain text during streaming (too expensive to re-parse every token)
            /** @type {HTMLElement} */ (assistantEl.querySelector(".message__content")).textContent = contentSoFar;
            scrollToBottom();
          } else if (event.type === "done") {
            if (assistantEl) {
              /** @type {HTMLElement} */ (assistantEl.querySelector(".message__content")).classList.remove("message__content--streaming");
              assistantEl.dataset.id = event.id ?? "";
              // Render final content as markdown
              setMessageContent(assistantEl, event.content);
              updateSwipeUI(assistantEl, siblingIndex(event), siblingCount(event));
            } else {
              addMessage(event);
            }
          } else if (event.type === "error") {
            showError(event.error ?? "");
          }
        }
      }
    }
  } catch (e) {
    showError(e instanceof Error ? e.message : String(e));
  }
  setBusy(false);
  fetchTokenCount();
}

// Send
btnSend.addEventListener("click", async function () {
  const text = input.value.trim();
  if (!text || busy) return;
  input.value = "";
  sendStreaming(text);
});

// Continue
btnContinue.addEventListener("click", async function () {
  if (busy) return;
  setBusy(true);
  const data = await request("POST", "/api/continue");
  setBusy(false);
  if (data) {
    const el = findMessageEl(data.id);
    if (el) {
      updateMessage(el, data);
    } else {
      addMessage(data);
    }
    scrollToBottom();
    if (data.token_count) updateTokenCounter(data.token_count);
  }
});

// Impersonate
btnImpersonate.addEventListener("click", async function () {
  if (busy) return;
  setBusy(true);
  const data = await request("POST", "/api/impersonate");
  setBusy(false);
  if (data && data.content) {
    input.value = data.content;
    input.focus();
  }
});

// Edit and Delete actions — delegated
messageList.addEventListener("click", async function (e) {
  const btn = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".message__action-button"));
  if (!btn || busy) return;
  const msgEl = /** @type {HTMLElement} */ (btn.closest(".message"));
  const id = msgEl.dataset.id;
  if (!id) return;
  const action = btn.dataset.action;

  if (action === "delete") {
    if (!window.confirm("Delete this message and everything after it? This cannot be undone.")) return;
    setBusy(true);
    const data = await request("POST", "/api/message/delete", { message_id: id });
    setBusy(false);
    if (data) {
      removeMessagesFrom(msgEl, true);
      fetchTokenCount();
    }
  } else if (action === "edit") {
    const contentEl = /** @type {HTMLElement} */ (msgEl.querySelector(".message__content"));
    const original = msgEl.dataset.rawContent || contentEl.textContent || "";
    const editTrigger = btn;

    msgEl.classList.add("message--editing");

    const textarea = document.createElement("textarea");
    textarea.className = "message__edit-textarea";
    textarea.value = original;
    textarea.rows = Math.max(3, original.split("\n").length);

    const editActions = document.createElement("div");
    editActions.className = "message__edit-actions";
    const saveBtn = document.createElement("button");
    saveBtn.className = "message__edit-button message__edit-button--save";
    saveBtn.textContent = "Save";
    const cancelBtn = document.createElement("button");
    cancelBtn.className = "message__edit-button message__edit-button--cancel";
    cancelBtn.textContent = "Cancel";
    editActions.appendChild(saveBtn);
    editActions.appendChild(cancelBtn);

    contentEl.hidden = true;
    contentEl.after(textarea, editActions);
    textarea.focus();

    function exitEdit() {
      msgEl.classList.remove("message--editing");
      textarea.remove();
      editActions.remove();
      contentEl.hidden = false;
      // Restore focus to the Edit button that opened this editor.
      if (editTrigger && editTrigger.isConnected) editTrigger.focus();
    }

    cancelBtn.addEventListener("click", exitEdit);
    textarea.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape") { ev.preventDefault(); exitEdit(); }
    });

    saveBtn.addEventListener("click", async function () {
      const newContent = textarea.value;
      if (newContent === original) { exitEdit(); return; }
      setBusy(true);
      const data = await request("POST", "/api/message/edit", {
        message_id: id, content: newContent,
      });
      setBusy(false);
      if (data) {
        exitEdit();
        if (data.reload_below) {
          // Edit forked — new branch. Remove messages below, update this one, reload.
          setMessageContent(msgEl, data.content);
          if (data.id) msgEl.dataset.id = data.id;
          updateSwipeUI(msgEl, siblingIndex(data), siblingCount(data));
          removeMessagesFrom(msgEl, false);
          siblingCache.delete(id);
        } else {
          setMessageContent(msgEl, data.content);
          if (data.id) msgEl.dataset.id = data.id;
          updateSwipeUI(msgEl, siblingIndex(data), siblingCount(data));
        }
        fetchTokenCount();
      } else {
        exitEdit();
      }
    });
  }
});

// Sibling navigation — delegated from message list
messageList.addEventListener("click", async function (e) {
  const btn = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".message__swipe-button"));
  if (!btn || busy) return;
  const msgEl = /** @type {HTMLElement} */ (btn.closest(".message"));
  const id = msgEl.dataset.id;
  if (!id) return;

  const dir = btn.dataset.dir;

  // Fetch all siblings on first interaction
  setBusy(true);
  const entry = await ensureSiblings(id);
  setBusy(false);
  if (!entry) return;

  const current = entry.current;

  if (dir === "next" && current >= entry.siblings.length - 1) {
    // Next past end — generate a new sibling
    setBusy(true);
    const data = await request("POST", "/api/swipe/new", { message_id: id });
    setBusy(false);
    if (data) {
      addSiblingToCache(id, { id: data.id, content: data.content, index: entry.siblings.length - 1 });
      updateMessage(msgEl, data);
      // New sibling may have different subtree — reload below
      removeMessagesFrom(msgEl, false);
      fetchTokenCount();
    }
  } else {
    const nextIndex = dir === "next" ? current + 1 : Math.max(0, current - 1);
    if (nextIndex === current) return;
    const sibling = navigateSibling(id, nextIndex);
    if (!sibling) return;

    // Tell the server to update canonical path
    setBusy(true);
    const data = await request("POST", "/api/branch/navigate", { message_id: sibling.id });
    setBusy(false);

    if (data) {
      updateMessage(msgEl, sibling);
      // Different sibling = different subtree below — reload
      removeMessagesFrom(msgEl, false);
      // Fetch and append the new subtree
      const history = await request("GET", "/api/messages");
      if (history && history.messages) {
        // Find where this message is in the path and add everything after it
        let found = false;
        for (const msg of history.messages) {
          if (found) addMessage(msg);
          if (msg.id === sibling.id) found = true;
        }
      }
      fetchTokenCount();
    }
  }
});

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

// ── Message list replace helper ───────────────────────────────────────────

/**
 * @param {Message[] | null | undefined} messages
 */
function replaceMessages(messages) {
  messageList.innerHTML = "";
  siblingCache.clear();
  if (messages) {
    for (const msg of messages) addMessage(msg);
  }
}


// ── Persona / Settings / Sessions ─────────────────────────────────────────
// Initialized early because settings.reload() runs in the boot IIFE and
// the keyboard shortcut + closeAnyPanel handlers reference both.

const persona = initPersona({ showError });
const settings = initSettings({ showError, persona, trapFocus, releaseFocus });
const sessions = initSessions({
  showError: showError,
  setBusy: setBusy,
  isBusy: function () { return busy; },
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
      hasAvatar = true;
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
