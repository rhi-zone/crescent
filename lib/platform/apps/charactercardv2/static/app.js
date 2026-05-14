import { renderMarkdown } from "./markdown.js";

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
/** @type {HTMLButtonElement} */
const btnSettings = /** @type {HTMLButtonElement} */ (document.getElementById("btn-settings"));
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

/** @type {HTMLElement} */
const settingsOverlay = /** @type {HTMLElement} */ (document.getElementById("settings-overlay"));
/** @type {HTMLButtonElement} */
const settingsClose = /** @type {HTMLButtonElement} */ (document.getElementById("settings-close"));
/** @type {HTMLButtonElement} */
const settingsSave = /** @type {HTMLButtonElement} */ (document.getElementById("settings-save"));

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
 * @typedef {{
 *   name: string,
 *   find: string,
 *   replace: string,
 *   enabled: boolean,
 *   scope: string,
 *   order?: number
 * }} RegexScript
 */

/**
 * @typedef {{
 *   name: string,
 *   description?: string
 * }} Persona
 */

/**
 * @typedef {{
 *   name?: boolean,
 *   is_primary?: boolean
 * }} GroupMember
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

/** @type {boolean} */
let groupEnabled = false;

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
    /** @type {HTMLElement} */ (el.querySelector(".message__avatar")).hidden = false;
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
 * @param {string} method
 * @param {string} path
 * @param {unknown} [body]
 * @param {{ silent?: boolean }} [opts_]
 * @returns {Promise<any>}
 */
async function request(method, path, body, opts_) {
  try {
    /** @type {{ method: string, headers: Record<string, string>, body?: string }} */
    const opts = { method, headers: {} };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(path, opts);
    const data = await res.json();
    if (data.error) {
      if (!opts_?.silent) showError(data.error);
      return null;
    }
    return data;
  } catch (e) {
    if (!opts_?.silent) showError(e instanceof Error ? e.message : String(e));
    return null;
  }
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
    }

    cancelBtn.addEventListener("click", exitEdit);

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

// ── Settings panel ──────────────────────────────────────────────────────────

const SETTINGS_RANGE_KEYS = ["temperature", "top_p", "frequency_penalty", "presence_penalty"];
const SETTINGS_NUMBER_KEYS = ["max_tokens", "max_context"];
const SETTINGS_ALL_KEYS = [...SETTINGS_RANGE_KEYS, ...SETTINGS_NUMBER_KEYS];

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

// Live value display for range sliders
for (const key of SETTINGS_RANGE_KEYS) {
  const el = /** @type {HTMLInputElement | null} */ (document.getElementById("set-" + key));
  const valEl = document.getElementById("val-" + key);
  if (el && valEl) {
    el.addEventListener("input", function () { valEl.textContent = el.value; });
  }
}

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

function openSettings() {
  settingsOverlay.hidden = false;
  loadPersonas();
  trapFocus(settingsOverlay, btnSettings);
}

btnSettings.addEventListener("click", openSettings);

function closeSettings() {
  settingsOverlay.hidden = true;
  releaseFocus();
}

settingsClose.addEventListener("click", closeSettings);

settingsOverlay.addEventListener("click", function (e) {
  if (e.target === settingsOverlay) closeSettings();
});

settingsSave.addEventListener("click", async function () {
  const data = await request("POST", "/api/settings", readSettings());
  if (data) {
    populateSettings(data);
    closeSettings();
  }
});

async function loadSettings() {
  const data = await request("GET", "/api/settings");
  if (data) populateSettings(data);
}

// ── Connection test ───────────────────────────────────────────────────────

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

// ── Session panel ──────────────────────────────────────────────────────────

/** @type {HTMLButtonElement} */
const btnSessions = /** @type {HTMLButtonElement} */ (document.getElementById("btn-sessions"));
/** @type {HTMLElement} */
const sessionPanel = /** @type {HTMLElement} */ (document.getElementById("session-panel"));
/** @type {HTMLElement} */
const sessionOverlay = /** @type {HTMLElement} */ (document.getElementById("session-overlay"));
/** @type {HTMLElement} */
const sessionList = /** @type {HTMLElement} */ (document.getElementById("session-list"));
/** @type {HTMLButtonElement} */
const btnNewSession = /** @type {HTMLButtonElement} */ (document.getElementById("btn-new-session"));
/** @type {HTMLButtonElement} */
const btnCloseSessions = /** @type {HTMLButtonElement} */ (document.getElementById("btn-close-sessions"));

/** @type {string | null} */
let currentSessionId = null;

function openSessionPanel() {
  sessionPanel.hidden = false;
  sessionOverlay.hidden = false;
  loadSessions();
  trapFocus(sessionPanel, btnSessions);
}

function closeSessionPanel() {
  sessionPanel.hidden = true;
  sessionOverlay.hidden = true;
  releaseFocus();
}

/**
 * @param {number | null | undefined} ts
 * @returns {string}
 */
function formatTime(ts) {
  if (!ts) return "";
  const d = new Date(ts * 1000);
  const now = new Date();
  const diff = now.getTime() - d.getTime();
  if (diff < 86400000) {
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
  if (diff < 604800000) {
    return d.toLocaleDateString([], { weekday: "short" });
  }
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}

/**
 * @typedef {{ id: string, preview?: string, created_at?: number }} SessionInfo
 */

/**
 * @param {SessionInfo[]} sessions
 * @param {string} current
 */
function renderSessions(sessions, current) {
  sessionList.innerHTML = "";
  for (const s of sessions) {
    const item = document.createElement("div");
    item.className = "session-item" + (s.id === current ? " session-item--active" : "");
    item.dataset.id = s.id;

    const preview = document.createElement("div");
    preview.className = "session-item__preview";
    preview.textContent = s.preview || "New chat";

    const time = document.createElement("div");
    time.className = "session-item__time";
    time.textContent = formatTime(s.created_at);

    const del = document.createElement("button");
    del.className = "session-item__delete";
    del.textContent = "\u00d7";
    del.title = "Delete";

    item.appendChild(preview);
    item.appendChild(time);
    item.appendChild(del);
    sessionList.appendChild(item);
  }
}

async function loadSessions() {
  const data = await request("GET", "/api/sessions");
  if (!data) return;
  currentSessionId = data.current;
  renderSessions(data.sessions, data.current);
}

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

btnSessions.addEventListener("click", openSessionPanel);
btnCloseSessions.addEventListener("click", closeSessionPanel);
sessionOverlay.addEventListener("click", closeSessionPanel);

btnNewSession.addEventListener("click", async function () {
  if (busy) return;
  setBusy(true);
  const data = await request("POST", "/api/session/new");
  setBusy(false);
  if (data) {
    currentSessionId = data.session.id;
    replaceMessages(data.messages);
    loadSessions();
    fetchTokenCount();
  }
});

sessionList.addEventListener("click", async function (e) {
  if (busy) return;
  const del = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".session-item__delete"));
  const item = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".session-item"));
  if (!item) return;
  const id = item.dataset.id;

  if (del) {
    // Delete session.
    setBusy(true);
    const data = await request("POST", "/api/session/delete", { session_id: id });
    setBusy(false);
    if (data) {
      currentSessionId = data.current_session_id;
      replaceMessages(data.messages);
      loadSessions();
      fetchTokenCount();
    }
    return;
  }

  // Switch session.
  if (id === currentSessionId) return;
  setBusy(true);
  const data = await request("POST", "/api/session/switch", { session_id: id });
  setBusy(false);
  if (data) {
    currentSessionId = data.session.id;
    replaceMessages(data.messages);
    loadSessions();
    fetchTokenCount();
  }
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
    loadSettings(),
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

/**
 * @typedef {{ id: string, name: string, active: boolean, entry_count: number }} BookSummary
 */

/** @type {HTMLButtonElement} */
const btnMyLorebooks = /** @type {HTMLButtonElement} */ (document.getElementById("btn-my-lorebooks"));
/** @type {HTMLElement} */
const myLorebooksOverlay = /** @type {HTMLElement} */ (document.getElementById("my-lorebooks-overlay"));
/** @type {HTMLButtonElement} */
const myLorebooksClose = /** @type {HTMLButtonElement} */ (document.getElementById("my-lorebooks-close"));
/** @type {HTMLButtonElement} */
const myLorebooksNew = /** @type {HTMLButtonElement} */ (document.getElementById("my-lorebooks-new"));
/** @type {HTMLButtonElement} */
const myLorebooksImport = /** @type {HTMLButtonElement} */ (document.getElementById("my-lorebooks-import"));
/** @type {HTMLInputElement} */
const myLorebooksImportFile = /** @type {HTMLInputElement} */ (document.getElementById("my-lorebooks-import-file"));
/** @type {HTMLElement} */
const bookListEl = /** @type {HTMLElement} */ (document.getElementById("book-list"));
/** @type {HTMLElement} */
const bookDetailPlaceholder = /** @type {HTMLElement} */ (document.getElementById("book-detail-placeholder"));
/** @type {HTMLElement} */
const bookDetailHeader = /** @type {HTMLElement} */ (document.getElementById("book-detail-header"));
/** @type {HTMLInputElement} */
const bookDetailName = /** @type {HTMLInputElement} */ (document.getElementById("book-detail-name"));
/** @type {HTMLButtonElement} */
const bookDetailRename = /** @type {HTMLButtonElement} */ (document.getElementById("book-detail-rename"));
/** @type {HTMLButtonElement} */
const bookDetailAdd = /** @type {HTMLButtonElement} */ (document.getElementById("book-detail-add"));
/** @type {HTMLElement} */
const bookDetailBody = /** @type {HTMLElement} */ (document.getElementById("book-detail-body"));

/** @type {BookSummary[]} */
let myBooks = [];
/** @type {string | null} */
let selectedBookId = null;

function openMyLorebooks() {
  myLorebooksOverlay.hidden = false;
  loadMyLorebooks();
  trapFocus(myLorebooksOverlay, btnMyLorebooks);
}

function closeMyLorebooks() {
  myLorebooksOverlay.hidden = true;
  releaseFocus();
}

btnMyLorebooks.addEventListener("click", openMyLorebooks);
myLorebooksClose.addEventListener("click", closeMyLorebooks);
myLorebooksOverlay.addEventListener("click", function (e) {
  if (e.target === myLorebooksOverlay) closeMyLorebooks();
});

async function loadMyLorebooks() {
  const data = await request("GET", "/api/user_lorebooks");
  if (!data) return;
  myBooks = /** @type {BookSummary[]} */ (data.books || []);
  renderBookList();
  if (selectedBookId && myBooks.find(b => b.id === selectedBookId)) {
    loadBookEntries(selectedBookId);
  } else {
    selectedBookId = null;
    hideBookDetail();
  }
}

function renderBookList() {
  bookListEl.innerHTML = "";
  if (myBooks.length === 0) {
    const empty = document.createElement("div");
    empty.className = "lorebook-empty";
    empty.textContent = 'No lorebooks yet. Click "+ New Lorebook" to create one.';
    bookListEl.appendChild(empty);
    return;
  }
  for (const book of myBooks) {
    bookListEl.appendChild(createBookRow(book));
  }
}

/**
 * @param {BookSummary} book
 * @returns {HTMLElement}
 */
function createBookRow(book) {
  const row = document.createElement("div");
  row.className = "book-row" + (selectedBookId === book.id ? " book-row--selected" : "");
  row.dataset.id = book.id;

  const toggle = document.createElement("button");
  toggle.className = "lorebook-entry__toggle" + (book.active ? " lorebook-entry__toggle--on" : "");
  toggle.title = book.active ? "Active" : "Inactive";
  toggle.addEventListener("click", async function (e) {
    e.stopPropagation();
    const newActive = !book.active;
    const data = await request("POST", "/api/user_lorebooks/toggle", { id: book.id, active: newActive });
    if (data) {
      book.active = newActive;
      toggle.className = "lorebook-entry__toggle" + (newActive ? " lorebook-entry__toggle--on" : "");
      toggle.title = newActive ? "Active" : "Inactive";
    }
  });

  const name = document.createElement("span");
  name.className = "book-row__name";
  name.textContent = book.name;

  const count = document.createElement("span");
  count.className = "book-row__count";
  count.textContent = String(book.entry_count) + (book.entry_count === 1 ? " entry" : " entries");

  const exportBtn = document.createElement("button");
  exportBtn.className = "book-row__export";
  exportBtn.textContent = "\u2b07";
  exportBtn.title = "Export lorebook to JSON";
  exportBtn.addEventListener("click", function (e) {
    e.stopPropagation();
    exportLorebook(book.id, book.name);
  });

  const del = document.createElement("button");
  del.className = "book-row__delete";
  del.textContent = "\u00d7";
  del.title = "Delete lorebook";
  del.addEventListener("click", async function (e) {
    e.stopPropagation();
    if (!confirm(`Delete lorebook "${book.name}"? This cannot be undone.`)) return;
    const data = await request("POST", "/api/user_lorebooks/delete", { id: book.id });
    if (data) {
      if (selectedBookId === book.id) selectedBookId = null;
      loadMyLorebooks();
    }
  });

  row.appendChild(toggle);
  row.appendChild(name);
  row.appendChild(count);
  row.appendChild(exportBtn);
  row.appendChild(del);

  row.addEventListener("click", function () {
    selectedBookId = book.id;
    renderBookList();
    loadBookEntries(book.id);
  });

  return row;
}

function hideBookDetail() {
  bookDetailPlaceholder.hidden = false;
  bookDetailHeader.hidden = true;
  bookDetailBody.hidden = true;
  bookDetailBody.innerHTML = "";
}

/**
 * @param {string} bookId
 */
async function loadBookEntries(bookId) {
  const data = await request("GET", "/api/user_lorebooks/entries?book_id=" + encodeURIComponent(bookId));
  if (!data) return;
  bookDetailPlaceholder.hidden = true;
  bookDetailHeader.hidden = false;
  bookDetailBody.hidden = false;
  bookDetailName.value = data.name || "";
  renderBookEntries(bookId, data.entries);
}

/**
 * @param {string} bookId
 * @param {LorebookEntry[] | null | undefined} entries
 */
function renderBookEntries(bookId, entries) {
  bookDetailBody.innerHTML = "";
  if (!entries || entries.length === 0) {
    bookDetailBody.innerHTML = '<div class="lorebook-empty">No entries. Click "+ Add Entry" to create one.</div>';
    return;
  }
  for (const entry of entries) {
    bookDetailBody.appendChild(createEntryEl(entry, {
      updateUrl: "/api/user_lorebooks/entry/update",
      deleteUrl: "/api/user_lorebooks/entry/delete",
      extraBody: { book_id: bookId },
      onChange: function () {
        loadBookEntries(bookId);
        // Refresh book list for entry_count.
        request("GET", "/api/user_lorebooks").then(function (d) {
          if (d) { myBooks = d.books || []; renderBookList(); }
        });
      },
    }));
  }
}

myLorebooksNew.addEventListener("click", async function () {
  const name = prompt("Lorebook name:", "Untitled");
  if (!name) return;
  const data = await request("POST", "/api/user_lorebooks", { name });
  if (data && data.id) {
    selectedBookId = data.id;
    await loadMyLorebooks();
  }
});

/**
 * Trigger a file download for a single lorebook.
 * @param {string} bookId
 * @param {string} bookName
 */
async function exportLorebook(bookId, bookName) {
  try {
    const res = await fetch("/api/user_lorebooks/export?book_id=" + encodeURIComponent(bookId));
    if (!res.ok) {
      const data = await res.json().catch(() => ({ error: "export failed" }));
      showError(data.error || "export failed");
      return;
    }
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    const disp = res.headers.get("content-disposition");
    if (disp) {
      const match = disp.match(/filename="?([^"]+)"?/);
      if (match) a.download = match[1];
    }
    if (!a.download) a.download = (bookName || "lorebook") + ".lorebook.json";
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  } catch (e) {
    showError(e instanceof Error ? e.message : String(e));
  }
}

myLorebooksImport.addEventListener("click", function () {
  myLorebooksImportFile.value = "";
  myLorebooksImportFile.click();
});

myLorebooksImportFile.addEventListener("change", async function () {
  const file = myLorebooksImportFile.files && myLorebooksImportFile.files[0];
  if (!file) return;
  let text;
  try {
    text = await file.text();
  } catch (e) {
    showError(e instanceof Error ? e.message : String(e));
    return;
  }
  /** @type {{ name?: string, entries?: unknown } | null} */
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
  // Derive a default name from the filename if none supplied.
  const payload = {
    name: parsed.name || file.name.replace(/\.lorebook\.json$|\.json$/i, "") || "Imported",
    entries: parsed.entries,
  };
  const data = await request("POST", "/api/user_lorebooks/import", payload);
  if (data && data.id) {
    selectedBookId = data.id;
    await loadMyLorebooks();
  }
});

bookDetailRename.addEventListener("click", async function () {
  if (!selectedBookId) return;
  const newName = bookDetailName.value.trim();
  if (!newName) return;
  const data = await request("POST", "/api/user_lorebooks/rename", { id: selectedBookId, name: newName });
  if (data) loadMyLorebooks();
});

bookDetailAdd.addEventListener("click", async function () {
  if (!selectedBookId) return;
  const data = await request("POST", "/api/user_lorebooks/entry/add", {
    book_id: selectedBookId,
    keys: ["new keyword"],
    content: "",
  });
  if (data) {
    loadBookEntries(selectedBookId);
    // Refresh entry_count.
    const list = await request("GET", "/api/user_lorebooks");
    if (list) { myBooks = list.books || []; renderBookList(); }
  }
});

// ── Card editor panel ──────────────────────────────────────────────────────

/** @type {HTMLElement} */
const cardEditOverlay = /** @type {HTMLElement} */ (document.getElementById("card-edit-overlay"));
/** @type {HTMLButtonElement} */
const cardEditClose = /** @type {HTMLButtonElement} */ (document.getElementById("card-edit-close"));
/** @type {HTMLButtonElement} */
const cardEditSave = /** @type {HTMLButtonElement} */ (document.getElementById("card-edit-save"));
/** @type {HTMLButtonElement} */
const cardEditReset = /** @type {HTMLButtonElement} */ (document.getElementById("card-edit-reset"));
/** @type {HTMLElement} */
const cardEditNotice = /** @type {HTMLElement} */ (document.getElementById("card-edit-notice"));
/** @type {HTMLElement} */
const cardEditPanelTitle = /** @type {HTMLElement} */ (document.getElementById("card-edit-panel-title"));
/** @type {HTMLElement} */
const cardEditFooter = /** @type {HTMLElement} */ (document.getElementById("card-edit-footer"));
/** @type {HTMLElement} */
const cardAltList = /** @type {HTMLElement} */ (document.getElementById("card-alt-greetings-list"));
/** @type {HTMLButtonElement} */
const cardAltAdd = /** @type {HTMLButtonElement} */ (document.getElementById("card-alt-add"));

/** @type {string} */
let activeTab = "identity";

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

/**
 * Switch the active tab.
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
  // Footer (Save/Reset) only shown for Identity and Greetings tabs
  cardEditFooter.hidden = tab === "lorebook" || tab === "regex";
}

// Wire tab buttons
for (const [key, btn] of Object.entries(tabBtns)) {
  btn.addEventListener("click", function () { switchTab(key); });
}

const CARD_INPUT_KEYS = ["name", "creator", "character_version"];
const CARD_TEXTAREA_KEYS = [
  "description", "personality", "scenario", "first_mes", "mes_example",
  "system_prompt", "post_history_instructions", "creator_notes",
];

/**
 * @typedef {{ [key: string]: any, tags?: string[], alternate_greetings?: string[] }} CardData
 */

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
  cardAltList.innerHTML = "";
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
    removeBtn.textContent = "\u00d7";
    removeBtn.title = "Remove";
    removeBtn.addEventListener("click", function () {
      row.remove();
    });
    row.appendChild(textarea);
    row.appendChild(removeBtn);
    cardAltList.appendChild(row);
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
  const altTextareas = cardAltList.querySelectorAll(".card-edit-alt-row__textarea");
  data.alternate_greetings = [];
  for (const ta of altTextareas) {
    data.alternate_greetings.push(/** @type {HTMLTextAreaElement} */ (ta).value);
  }
  return data;
}

/**
 * @param {string} [tab]
 */
function openCardEditor(tab) {
  cardEditOverlay.hidden = false;
  switchTab(tab || "identity");
  updateReadOnlyNotice(cardEditNotice);
  loadCardEditor();
  if (!tab || tab === "identity") {
    loadAuthorsNote();
  } else if (tab === "lorebook") {
    updateReadOnlyNotice(lorebookNotice);
    loadLorebook();
    loadLinkedLorebooks();
  } else if (tab === "regex") {
    loadRegex();
  }
  trapFocus(cardEditOverlay, btnCardHeaderEdit);
}

function closeCardEditor() {
  cardEditOverlay.hidden = true;
  releaseFocus();
}

async function loadCardEditor() {
  const data = await request("GET", "/api/card/edit");
  if (data) {
    populateCardEditor(data);
    // Update panel title to card name
    cardEditPanelTitle.textContent = data.name || "";
  }
}

// Card header — open card editor.
btnCardHeaderEdit.addEventListener("click", function () { openCardEditor("identity"); });
cardEditClose.addEventListener("click", closeCardEditor);
cardEditOverlay.addEventListener("click", function (e) {
  if (e.target === cardEditOverlay) closeCardEditor();
});

cardEditSave.addEventListener("click", async function () {
  const data = await request("POST", "/api/card/edit", readCardEditor());
  if (data) {
    populateCardEditor(data);
    closeCardEditor();
  }
});

cardEditReset.addEventListener("click", async function () {
  const confirmed = window.confirm(
    "Reset to original? This will discard all your edits to this card and cannot be undone."
  );
  if (!confirmed) return;
  const data = await request("POST", "/api/card/reset");
  if (data) populateCardEditor(data);
});

cardAltAdd.addEventListener("click", function () {
  const greetings = [];
  for (const ta of cardAltList.querySelectorAll(".card-edit-alt-row__textarea")) {
    greetings.push(/** @type {HTMLTextAreaElement} */ (ta).value);
  }
  greetings.push("");
  renderAltGreetings(greetings);
});

// ── Persona panel ──────────────────────────────────────────────────────────

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
  const data = await request("GET", "/api/personas");
  if (data) populatePersonaSelect(data.personas, data.active);
}

personaSelect.addEventListener("change", async function () {
  showSelectedPersona();
  await request("POST", "/api/personas/activate", { name: personaSelect.value });
});

personaNew.addEventListener("click", function () {
  personaName.value = "";
  personaDescription.value = "";
  personaName.focus();
});

personaDelete.addEventListener("click", async function () {
  const name = personaSelect.value;
  if (!name) return;
  const data = await request("POST", "/api/personas/delete", { name: name });
  if (data) loadPersonas();
});

personaSave.addEventListener("click", async function () {
  const name = personaName.value.trim();
  if (!name) return;
  const data = await request("POST", "/api/personas/save", {
    name: name,
    description: personaDescription.value,
  });
  if (data) {
    await request("POST", "/api/personas/activate", { name: name });
    loadPersonas();
  }
});

// ── Regex scripts panel ────────────────────────────────────────────────────

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

/** @type {{ [key: string]: string }} */
const SCOPE_LABELS = { ai_output: "AI Output", user_input: "User Input", display: "Display" };

async function loadRegex() {
  const data = await request("GET", "/api/regex");
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
    });
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
  arrow.textContent = "\u25B6";

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
    arrow.textContent = body.hidden ? "\u25B6" : "\u25BC";
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
    });
    if (data) loadRegex();
  });

  /** @type {HTMLButtonElement} */ (body.querySelector(".regex-entry__delete")).addEventListener("click", async function () {
    const data = await request("POST", "/api/regex/delete", { name: script.name });
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
  });
  if (data) loadRegex();
});

regexTestBtn.addEventListener("click", async function () {
  const find = regexTestFind.value;
  const replace = regexTestReplace.value;
  const inputVal = regexTestInput.value;
  if (!find || !inputVal) return;
  const data = await request("POST", "/api/regex/test", { find: find, replace: replace, input: inputVal });
  if (data) {
    regexTestOutput.textContent = data.output;
  }
});

// ── Author's Note ──────────────────────────────────────────────────────────

/** @type {HTMLTextAreaElement} */
const anText = /** @type {HTMLTextAreaElement} */ (document.getElementById("an-text"));
/** @type {HTMLInputElement} */
const anDepth = /** @type {HTMLInputElement} */ (document.getElementById("an-depth"));
/** @type {HTMLSelectElement} */
const anPosition = /** @type {HTMLSelectElement} */ (document.getElementById("an-position"));
/** @type {HTMLButtonElement} */
const anSave = /** @type {HTMLButtonElement} */ (document.getElementById("an-save"));

async function loadAuthorsNote() {
  const data = await request("GET", "/api/authors_note");
  if (data) {
    anText.value = data.text || "";
    anDepth.value = data.depth != null ? data.depth : 4;
    anPosition.value = data.position || "after";
  }
}

anSave.addEventListener("click", async function () {
  await request("POST", "/api/authors_note", {
    text: anText.value,
    depth: parseInt(anDepth.value, 10) || 4,
    position: anPosition.value,
  });
});

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
  if (!settingsOverlay.hidden) { closeSettings(); return true; }
  if (!myLorebooksOverlay.hidden) { closeMyLorebooks(); return true; }
  if (!cardEditOverlay.hidden) { closeCardEditor(); return true; }
  if (!groupOverlay.hidden) { closeGroup(); return true; }
  if (!sessionPanel.hidden) { closeSessionPanel(); return true; }
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
      case "S": openSettings(); e.preventDefault(); break;
      case "L": openCardEditor("lorebook"); e.preventDefault(); break;
      case "W": openMyLorebooks(); e.preventDefault(); break;
      case "E": exportChat("text"); e.preventDefault(); break;
      case "N": btnNewSession.click(); e.preventDefault(); break;
    }
  }
});

// ── Group chat panel ──────────────────────────────────────────────────────

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

async function loadGroup() {
  const data = await request("GET", "/api/group");
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
      removeBtn.textContent = "\u00d7";
      removeBtn.title = "Remove";
      removeBtn.addEventListener("click", async function () {
        const data = await request("POST", "/api/group/remove", { name: /** @type {any} */ (m).name });
        if (data) renderGroupMembers(data.members);
      });
      row.appendChild(removeBtn);
    }
    groupMemberList.appendChild(row);
  }
}

groupEnabledCheckbox.addEventListener("change", async function () {
  const data = await request("POST", "/api/group/toggle", { enabled: groupEnabledCheckbox.checked });
  if (data) {
    groupEnabled = data.enabled;
  }
});

groupTurnOrder.addEventListener("change", async function () {
  await request("POST", "/api/group/order", { turn_order: groupTurnOrder.value });
});

groupAddBtn.addEventListener("click", async function () {
  const jsonStr = groupAddJson.value.trim();
  if (!jsonStr) return;
  const data = await request("POST", "/api/group/add", { card_json: jsonStr });
  if (data) {
    groupAddJson.value = "";
    renderGroupMembers(data.members);
  }
});

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
