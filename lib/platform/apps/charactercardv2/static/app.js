import { renderMarkdown } from "./markdown.js";
import { request as apiRequest } from "./api.js";
import { init as initPersona } from "./persona.js";
import { init as initGroup } from "./group.js";
import { init as initRegex } from "./regex.js";
import { init as initSettings } from "./settings.js";
import { init as initSessions } from "./sessions.js";
import { init as initMyLorebooks } from "./my-lorebooks.js";
import { init as initCardEditor } from "./card-editor.js";

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

// ── Card Lorebook panel ─────────────────────────────────────────────────────

/** @type {HTMLButtonElement} */
const lorebookAdd = /** @type {HTMLButtonElement} */ (document.getElementById("lorebook-add"));
/** @type {HTMLElement} */
const lorebookList = /** @type {HTMLElement} */ (document.getElementById("lorebook-list"));
/** @type {HTMLElement} */
const lorebookNotice = /** @type {HTMLElement} */ (document.getElementById("lorebook-notice"));

const POSITION_LABELS = [
  "Before Char Defs",
  "After Char Defs",
  "Before AN (Top)",
  "Before AN (Bottom)",
  "At Depth",
  "After Example Msgs (Top)",
  "After Example Msgs (Bottom)",
];

/**
 * Show or hide a "read-only" notice element based on cardWritable.
 * @param {HTMLElement} el
 */
function updateReadOnlyNotice(el) {
  if (cardWritable) {
    el.hidden = true;
    el.textContent = "";
  } else {
    el.hidden = false;
    el.textContent = "Read-only (self_write not granted) \u2014 edits persist locally but won't ride with the card PNG.";
  }
}

async function loadLorebook() {
  const data = await request("GET", "/api/lorebook");
  if (!data) return;
  renderLorebookEntries(data.entries);
}

/**
 * @param {LorebookEntry[] | null | undefined} entries
 */
function renderLorebookEntries(entries) {
  lorebookList.innerHTML = "";
  if (!entries || entries.length === 0) {
    lorebookList.innerHTML = '<div class="lorebook-empty">No lorebook entries. Click "+ Add Entry" to create one.</div>';
    return;
  }
  for (const entry of entries) {
    lorebookList.appendChild(createEntryEl(entry, {
      updateUrl: "/api/lorebook/update",
      deleteUrl: "/api/lorebook/delete",
      onChange: loadLorebook,
    }));
  }
}

/**
 * @typedef {{
 *   updateUrl: string,
 *   deleteUrl: string,
 *   extraBody?: Record<string, unknown>,
 *   onChange: () => void,
 * }} EntryHandlers
 */

/**
 * @param {LorebookEntry} entry
 * @param {EntryHandlers} handlers
 * @returns {HTMLElement}
 */
function createEntryEl(entry, handlers) {
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
  arrow.textContent = "\u25B6";

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
    arrow.textContent = body.hidden ? "\u25B6" : "\u25BC";
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
    if (data) handlers.onChange();
  });

  // Delete
  /** @type {HTMLButtonElement} */ (body.querySelector(".lorebook-entry__delete")).addEventListener("click", async function () {
    const label = (entry.keys && entry.keys.length) ? entry.keys.join(", ") : ("entry #" + entry.uid);
    if (!window.confirm(`Delete lorebook entry "${label}"? This cannot be undone.`)) return;
    const data = await request("POST", handlers.deleteUrl, {
      ...(handlers.extraBody || {}),
      uid: entry.uid,
    });
    if (data) handlers.onChange();
  });

  el.appendChild(header);
  el.appendChild(body);
  return el;
}

/**
 * @param {string} s
 * @returns {string}
 */
function escAttr(s) {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

/**
 * @param {string} s
 * @returns {string}
 */
function escHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Add new entry
lorebookAdd.addEventListener("click", async function () {
  const data = await request("POST", "/api/lorebook/add", {
    keys: ["new keyword"],
    content: "",
  });
  if (data) loadLorebook();
});

// ── Linked Lorebooks (card-vendored) ───────────────────────────────────────
//
// Card-embedded lorebook snapshots. View / import / remove from the Lorebook
// tab in the Card Editor. Per-entry edits are out of scope for this pass —
// entries are shown read-only. Source field is informational only.

/**
 * @typedef {{ name: string, source?: string | null, entry_count: number }} LinkedBookSummary
 */

/** @type {HTMLElement} */
const linkedLorebooksList = /** @type {HTMLElement} */ (document.getElementById("linked-lorebooks-list"));
/** @type {HTMLButtonElement} */
const linkedLorebooksAdd = /** @type {HTMLButtonElement} */ (document.getElementById("linked-lorebooks-add"));
/** @type {HTMLInputElement} */
const linkedLorebooksFile = /** @type {HTMLInputElement} */ (document.getElementById("linked-lorebooks-file"));

/** @type {Set<number>} */
const linkedExpanded = new Set();

async function loadLinkedLorebooks() {
  const data = await request("GET", "/api/linked_lorebooks");
  if (!data) return;
  /** @type {LinkedBookSummary[]} */
  const books = data.books || [];
  /** @type {LorebookEntry[][]} */
  const entriesByBook = data.entries || [];
  renderLinkedLorebooks(books, entriesByBook);
}

/**
 * @param {LinkedBookSummary[]} books
 * @param {LorebookEntry[][]} entriesByBook
 */
function renderLinkedLorebooks(books, entriesByBook) {
  linkedLorebooksList.innerHTML = "";
  if (!books || books.length === 0) {
    const empty = document.createElement("div");
    empty.className = "lorebook-empty";
    empty.textContent = "No linked lorebooks. Click \"+ Add Linked Lorebook\" to bundle one with this card.";
    linkedLorebooksList.appendChild(empty);
    return;
  }
  for (let i = 0; i < books.length; i++) {
    linkedLorebooksList.appendChild(
      createLinkedBookEl(i, books[i], entriesByBook[i] || []),
    );
  }
}

/**
 * @param {number} index
 * @param {LinkedBookSummary} book
 * @param {LorebookEntry[]} entries
 * @returns {HTMLElement}
 */
function createLinkedBookEl(index, book, entries) {
  const expanded = linkedExpanded.has(index);
  const section = document.createElement("div");
  section.className = "linked-lorebook" + (expanded ? " linked-lorebook--expanded" : "");

  const header = document.createElement("div");
  header.className = "linked-lorebook__header";
  header.addEventListener("click", () => {
    if (linkedExpanded.has(index)) linkedExpanded.delete(index);
    else linkedExpanded.add(index);
    section.classList.toggle("linked-lorebook--expanded");
    body.hidden = !linkedExpanded.has(index);
  });

  const caret = document.createElement("span");
  caret.className = "linked-lorebook__caret";
  caret.textContent = "▸";
  header.appendChild(caret);

  const title = document.createElement("span");
  title.className = "linked-lorebook__name";
  title.textContent = book.name || "(unnamed)";
  header.appendChild(title);

  const count = document.createElement("span");
  count.className = "linked-lorebook__count";
  count.textContent = String(book.entry_count) + " " + (book.entry_count === 1 ? "entry" : "entries");
  header.appendChild(count);

  if (book.source) {
    const src = document.createElement("span");
    src.className = "linked-lorebook__source";
    src.textContent = book.source;
    src.title = book.source;
    header.appendChild(src);
  }

  const removeBtn = document.createElement("button");
  removeBtn.className = "linked-lorebook__remove";
  removeBtn.type = "button";
  removeBtn.textContent = "Remove";
  removeBtn.addEventListener("click", async (e) => {
    e.stopPropagation();
    if (!confirm("Remove linked lorebook \"" + (book.name || "(unnamed)") + "\"?")) return;
    const data = await request("POST", "/api/linked_lorebooks/delete", { index });
    if (data) {
      linkedExpanded.delete(index);
      loadLinkedLorebooks();
    }
  });
  header.appendChild(removeBtn);

  section.appendChild(header);

  const body = document.createElement("div");
  body.className = "linked-lorebook__body";
  body.hidden = !expanded;
  if (!entries || entries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "linked-lorebook__empty";
    empty.textContent = "(no entries)";
    body.appendChild(empty);
  } else {
    for (const entry of entries) {
      body.appendChild(createLinkedEntryEl(entry));
    }
  }
  section.appendChild(body);

  return section;
}

/**
 * @param {LorebookEntry} entry
 * @returns {HTMLElement}
 */
function createLinkedEntryEl(entry) {
  const el = document.createElement("div");
  el.className = "linked-lorebook__entry";

  const keys = document.createElement("div");
  keys.className = "linked-lorebook__entry-keys";
  keys.textContent = (entry.keys && entry.keys.length > 0) ? entry.keys.join(", ") : "(no keys)";
  el.appendChild(keys);

  const content = document.createElement("div");
  content.className = "linked-lorebook__entry-content";
  content.textContent = entry.content || "";
  el.appendChild(content);

  return el;
}

linkedLorebooksAdd.addEventListener("click", () => {
  linkedLorebooksFile.value = "";
  linkedLorebooksFile.click();
});

linkedLorebooksFile.addEventListener("change", async () => {
  const file = linkedLorebooksFile.files && linkedLorebooksFile.files[0];
  if (!file) return;
  let text;
  try {
    text = await file.text();
  } catch (e) {
    showError(e instanceof Error ? e.message : String(e));
    return;
  }
  /** @type {{ name?: string, source?: string, entries?: unknown } | null} */
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
  const payload = {
    name: parsed.name || file.name.replace(/\.lorebook\.json$|\.json$/i, "") || "Imported",
    source: parsed.source,
    entries: parsed.entries,
  };
  const data = await request("POST", "/api/linked_lorebooks/import", payload);
  if (data) loadLinkedLorebooks();
});

// ── My Lorebooks panel ─────────────────────────────────────────────────────

const myLorebooks = initMyLorebooks({ showError, trapFocus, releaseFocus, createEntryEl });

// ── Card editor panel ──────────────────────────────────────────────────────
//
// Card editor extracted to ./card-editor.js. We expose the Author's Note
// loader and a card-side lorebook reload callback so the card editor can
// trigger them when the respective tab is opened.

async function loadAuthorsNote() {
  const data = await request("GET", "/api/authors_note");
  if (data) {
    /** @type {HTMLTextAreaElement} */ (document.getElementById("an-text")).value = data.text || "";
    /** @type {HTMLInputElement} */ (document.getElementById("an-depth")).value = data.depth != null ? data.depth : 4;
    /** @type {HTMLSelectElement} */ (document.getElementById("an-position")).value = data.position || "after";
  }
}

function loadCardLorebook() {
  updateReadOnlyNotice(lorebookNotice);
  loadLorebook();
  loadLinkedLorebooks();
}

const regex = initRegex({ showError, escAttr });

const cardEditor = initCardEditor({
  showError,
  trapFocus,
  releaseFocus,
  lorebookReload: loadCardLorebook,
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
