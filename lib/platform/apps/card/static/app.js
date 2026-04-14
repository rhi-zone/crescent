import { renderMarkdown } from "./markdown.js";

const messageList = document.getElementById("message-list");
const input = document.getElementById("input");
const btnSend = document.getElementById("btn-send");
const btnContinue = document.getElementById("btn-continue");
const btnImpersonate = document.getElementById("btn-impersonate");
const btnSettings = document.getElementById("btn-settings");
const loading = document.getElementById("loading");
const template = document.getElementById("message-template");

const tokenCountText = document.getElementById("token-count-text");
const tokenCountFill = document.getElementById("token-count-fill");

const cardHeader = document.getElementById("card-header");
const cardAvatar = document.getElementById("card-avatar");
const cardHeaderName = document.getElementById("card-header-name");

const settingsOverlay = document.getElementById("settings-overlay");
const settingsClose = document.getElementById("settings-close");
const settingsSave = document.getElementById("settings-save");

let busy = false;
let hasAvatar = false;

// Sibling cache: message_id -> {siblings: [{id, content, index}], current: index}
const siblingCache = new Map();

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
function siblingIndex(msg) {
  return msg.sibling_index != null ? msg.sibling_index : (msg.swipe_index || 0);
}
function siblingCount(msg) {
  return msg.sibling_count != null ? msg.sibling_count : (msg.swipe_total || 1);
}

// Set rendered markdown content on a message element.
// Stores raw text in dataset for edit mode.
function setMessageContent(el, content) {
  const contentEl = el.querySelector(".message__content");
  el.dataset.rawContent = content || "";
  contentEl.innerHTML = renderMarkdown(content || "");
}

// Add a message to the list. Returns the DOM element.
function addMessage(msg) {
  const el = template.content.cloneNode(true).firstElementChild;
  el.classList.add("message--" + msg.role);
  el.dataset.id = msg.id || "";
  if (hasAvatar && msg.role === "assistant") {
    el.querySelector(".message__avatar").hidden = false;
  }
  setMessageContent(el, msg.content);
  updateSwipeUI(el, siblingIndex(msg), siblingCount(msg));
  messageList.appendChild(el);
  scrollToBottom();
  return el;
}

function updateSwipeUI(el, index, total) {
  const swipe = el.querySelector(".message__swipe");
  if (total == null || total <= 1) {
    swipe.hidden = true;
    return;
  }
  swipe.hidden = false;
  el.querySelector(".message__swipe-label").textContent =
    (index + 1) + "/" + total;
}

function updateMessage(el, msg) {
  setMessageContent(el, msg.content);
  if (msg.id) el.dataset.id = msg.id;
  updateSwipeUI(el, siblingIndex(msg), siblingCount(msg));
}

function showError(text) {
  addMessage({ id: "", role: "system", content: "Error: " + text });
}

async function request(method, path, body) {
  try {
    const opts = { method, headers: {} };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(path, opts);
    const data = await res.json();
    if (data.error) {
      showError(data.error);
      return null;
    }
    return data;
  } catch (e) {
    showError(e.message);
    return null;
  }
}

// ── Token counter ──────────────────────────────────────────────────────────

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
async function ensureSiblings(messageId) {
  if (siblingCache.has(messageId)) return siblingCache.get(messageId);
  const data = await request("GET", "/api/swipes?message_id=" + messageId);
  if (!data) return null;
  const entry = { siblings: data.swipes, current: data.current };
  siblingCache.set(messageId, entry);
  return entry;
}

// Navigate to a sibling by index (from cache). Returns the sibling or null.
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
  };
}

// Add a newly generated sibling to the cache
function addSiblingToCache(messageId, sibling) {
  const entry = siblingCache.get(messageId);
  if (!entry) return;
  entry.siblings.push(sibling);
  entry.current = entry.siblings.length - 1;
}

function findMessageEl(id) {
  return messageList.querySelector('.message[data-id="' + id + '"]');
}

// Remove all message elements after (and optionally including) a given element
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

// Auto-resize textarea
input.addEventListener("input", function () {
  this.style.height = "auto";
  this.style.height = this.scrollHeight + "px";
});

// Enter to send, Shift+Enter for newline
input.addEventListener("keydown", function (e) {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    btnSend.click();
  }
});

// Streaming send via SSE over fetch
async function sendStreaming(text) {
  setBusy(true);
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
      buffer = parts.pop();
      for (const part of parts) {
        for (const line of part.split("\n")) {
          if (!line.startsWith("data: ")) continue;
          let event;
          try { event = JSON.parse(line.slice(6)); } catch { continue; }
          if (event.type === "user") {
            addMessage({ id: event.id, role: "user", content: event.content });
          } else if (event.type === "token") {
            if (!assistantEl) {
              assistantEl = addMessage({ id: "", role: "assistant", content: "" });
              assistantEl.querySelector(".message__content").classList.add("message__content--streaming");
            }
            contentSoFar += event.token;
            // Plain text during streaming (too expensive to re-parse every token)
            assistantEl.querySelector(".message__content").textContent = contentSoFar;
            scrollToBottom();
          } else if (event.type === "done") {
            if (assistantEl) {
              assistantEl.querySelector(".message__content").classList.remove("message__content--streaming");
              assistantEl.dataset.id = event.id;
              // Render final content as markdown
              setMessageContent(assistantEl, event.content);
              updateSwipeUI(assistantEl, siblingIndex(event), siblingCount(event));
            } else {
              addMessage(event);
            }
          } else if (event.type === "error") {
            showError(event.error);
          }
        }
      }
    }
  } catch (e) {
    showError(e.message);
  }
  setBusy(false);
  fetchTokenCount();
}

// Send
btnSend.addEventListener("click", async function () {
  const text = input.value.trim();
  if (!text || busy) return;
  input.value = "";
  input.style.height = "auto";
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
    input.style.height = "auto";
    input.style.height = input.scrollHeight + "px";
    input.focus();
  }
});

// Show/hide actions on hover
messageList.addEventListener("mouseover", function (e) {
  const msgEl = e.target.closest(".message");
  if (!msgEl) return;
  const actions = msgEl.querySelector(".message__actions");
  if (actions && !msgEl.classList.contains("message--editing")) actions.hidden = false;
});

messageList.addEventListener("mouseout", function (e) {
  const msgEl = e.target.closest(".message");
  if (!msgEl) return;
  if (msgEl.contains(e.relatedTarget)) return;
  const actions = msgEl.querySelector(".message__actions");
  if (actions && !msgEl.classList.contains("message--editing")) actions.hidden = true;
});

// Edit and Delete actions — delegated
messageList.addEventListener("click", async function (e) {
  const btn = e.target.closest(".message__action-button");
  if (!btn || busy) return;
  const msgEl = btn.closest(".message");
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
    const contentEl = msgEl.querySelector(".message__content");
    const actionsEl = msgEl.querySelector(".message__actions");
    const original = msgEl.dataset.rawContent || contentEl.textContent;

    msgEl.classList.add("message--editing");
    actionsEl.hidden = true;

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
  const btn = e.target.closest(".message__swipe-button");
  if (!btn || busy) return;
  const msgEl = btn.closest(".message");
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

function populateSettings(settings) {
  for (const key of SETTINGS_ALL_KEYS) {
    const el = document.getElementById("set-" + key);
    if (el && settings[key] != null) el.value = settings[key];
    const valEl = document.getElementById("val-" + key);
    if (valEl && settings[key] != null) valEl.textContent = settings[key];
  }
}

function readSettings() {
  const s = {};
  for (const key of SETTINGS_ALL_KEYS) {
    const el = document.getElementById("set-" + key);
    if (el) s[key] = parseFloat(el.value);
  }
  return s;
}

// Live value display for range sliders
for (const key of SETTINGS_RANGE_KEYS) {
  const el = document.getElementById("set-" + key);
  const valEl = document.getElementById("val-" + key);
  if (el && valEl) {
    el.addEventListener("input", function () { valEl.textContent = el.value; });
  }
}

btnSettings.addEventListener("click", function () {
  settingsOverlay.hidden = false;
  loadPersonas();
});

settingsClose.addEventListener("click", function () {
  settingsOverlay.hidden = true;
});

settingsOverlay.addEventListener("click", function (e) {
  if (e.target === settingsOverlay) settingsOverlay.hidden = true;
});

settingsSave.addEventListener("click", async function () {
  const data = await request("POST", "/api/settings", readSettings());
  if (data) {
    populateSettings(data);
    settingsOverlay.hidden = true;
  }
});

async function loadSettings() {
  const data = await request("GET", "/api/settings");
  if (data) populateSettings(data);
}

// ── Session panel ──────────────────────────────────────────────────────────

const btnSessions = document.getElementById("btn-sessions");
const sessionPanel = document.getElementById("session-panel");
const sessionOverlay = document.getElementById("session-overlay");
const sessionList = document.getElementById("session-list");
const btnNewSession = document.getElementById("btn-new-session");
const btnCloseSessions = document.getElementById("btn-close-sessions");

let currentSessionId = null;

function openSessionPanel() {
  sessionPanel.hidden = false;
  sessionOverlay.hidden = false;
  loadSessions();
}

function closeSessionPanel() {
  sessionPanel.hidden = true;
  sessionOverlay.hidden = true;
}

function formatTime(ts) {
  if (!ts) return "";
  const d = new Date(ts * 1000);
  const now = new Date();
  const diff = now - d;
  if (diff < 86400000) {
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
  if (diff < 604800000) {
    return d.toLocaleDateString([], { weekday: "short" });
  }
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}

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
  const del = e.target.closest(".session-item__delete");
  const item = e.target.closest(".session-item");
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
    request("GET", "/api/card"),
    request("GET", "/api/messages"),
    loadSettings(),
    checkAvatar(),
  ]);
  setBusy(false);

  if (card) {
    document.title = card.name || "Card";
    cardHeaderName.textContent = card.name || "";
    if (card.name) cardHeader.hidden = false;
  }

  if (history && history.messages && history.messages.length > 0) {
    for (const msg of history.messages) addMessage(msg);
  } else if (card && card.greeting) {
    addMessage(card.greeting);
  }

  fetchTokenCount();
})();

// ── Lorebook panel ──────────────────────────────────────────────────────────

const btnLorebook = document.getElementById("btn-lorebook");
const lorebookOverlay = document.getElementById("lorebook-overlay");
const lorebookClose = document.getElementById("lorebook-close");
const lorebookAdd = document.getElementById("lorebook-add");
const lorebookList = document.getElementById("lorebook-list");

const POSITION_LABELS = [
  "Before Char Defs",
  "After Char Defs",
  "Before AN (Top)",
  "Before AN (Bottom)",
  "At Depth",
  "After Example Msgs (Top)",
  "After Example Msgs (Bottom)",
];

function openLorebook() {
  lorebookOverlay.hidden = false;
  loadLorebook();
}

function closeLorebook() {
  lorebookOverlay.hidden = true;
}

btnLorebook.addEventListener("click", openLorebook);
lorebookClose.addEventListener("click", closeLorebook);
lorebookOverlay.addEventListener("click", function (e) {
  if (e.target === lorebookOverlay) closeLorebook();
});

async function loadLorebook() {
  const data = await request("GET", "/api/lorebook");
  if (!data) return;
  renderLorebookEntries(data.entries);
}

function renderLorebookEntries(entries) {
  lorebookList.innerHTML = "";
  if (!entries || entries.length === 0) {
    lorebookList.innerHTML = '<div class="lorebook-empty">No lorebook entries. Click "+ Add Entry" to create one.</div>';
    return;
  }
  for (const entry of entries) {
    lorebookList.appendChild(createEntryEl(entry));
  }
}

function createEntryEl(entry) {
  const el = document.createElement("div");
  el.className = "lorebook-entry" + (entry.enabled ? "" : " lorebook-entry--disabled");
  el.dataset.uid = entry.uid;

  // Header row
  const header = document.createElement("div");
  header.className = "lorebook-entry__header";

  const toggle = document.createElement("button");
  toggle.className = "lorebook-entry__toggle" + (entry.enabled ? " lorebook-entry__toggle--on" : "");
  toggle.title = entry.enabled ? "Enabled" : "Disabled";
  toggle.addEventListener("click", async function (e) {
    e.stopPropagation();
    const newEnabled = !entry.enabled;
    const data = await request("POST", "/api/lorebook/update", {
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
  body.querySelector(".lorebook-entry__save").addEventListener("click", async function () {
    const keysStr = body.querySelector('[data-field="keys"]').value;
    const newKeys = keysStr.split(",").map(s => s.trim()).filter(Boolean);
    const content = body.querySelector('[data-field="content"]').value;
    const position = parseInt(body.querySelector('[data-field="position"]').value, 10);
    const order = parseInt(body.querySelector('[data-field="order"]').value, 10) || 0;
    const constant = body.querySelector('[data-field="constant"]').checked;
    const data = await request("POST", "/api/lorebook/update", {
      uid: entry.uid, keys: newKeys, content, position, order, constant,
    });
    if (data) loadLorebook();
  });

  // Delete
  body.querySelector(".lorebook-entry__delete").addEventListener("click", async function () {
    const data = await request("POST", "/api/lorebook/delete", { uid: entry.uid });
    if (data) loadLorebook();
  });

  el.appendChild(header);
  el.appendChild(body);
  return el;
}

function escAttr(s) {
  return s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

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

// ── Card editor panel ──────────────────────────────────────────────────────

const btnCardEdit = document.getElementById("btn-card-edit");
const cardEditOverlay = document.getElementById("card-edit-overlay");
const cardEditClose = document.getElementById("card-edit-close");
const cardEditSave = document.getElementById("card-edit-save");
const cardEditReset = document.getElementById("card-edit-reset");
const cardAltList = document.getElementById("card-alt-greetings-list");
const cardAltAdd = document.getElementById("card-alt-add");

const CARD_INPUT_KEYS = ["name", "creator", "character_version"];
const CARD_TEXTAREA_KEYS = [
  "description", "personality", "scenario", "first_mes", "mes_example",
  "system_prompt", "post_history_instructions", "creator_notes",
];

function populateCardEditor(data) {
  for (const key of CARD_INPUT_KEYS) {
    const el = document.getElementById("card-" + key);
    if (el) el.value = data[key] || "";
  }
  for (const key of CARD_TEXTAREA_KEYS) {
    const el = document.getElementById("card-" + key);
    if (el) el.value = data[key] || "";
  }
  document.getElementById("card-tags").value = (data.tags || []).join(", ");
  renderAltGreetings(data.alternate_greetings || []);
}

function renderAltGreetings(greetings) {
  cardAltList.innerHTML = "";
  for (let i = 0; i < greetings.length; i++) {
    const row = document.createElement("div");
    row.className = "card-edit-alt-row";
    const textarea = document.createElement("textarea");
    textarea.className = "card-edit-alt-row__textarea";
    textarea.value = greetings[i] || "";
    textarea.rows = 2;
    textarea.dataset.index = i;
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

function readCardEditor() {
  const data = {};
  for (const key of CARD_INPUT_KEYS) {
    const el = document.getElementById("card-" + key);
    if (el) data[key] = el.value;
  }
  for (const key of CARD_TEXTAREA_KEYS) {
    const el = document.getElementById("card-" + key);
    if (el) data[key] = el.value;
  }
  const tagsStr = document.getElementById("card-tags").value;
  data.tags = tagsStr.split(",").map(function (s) { return s.trim(); }).filter(Boolean);
  const altTextareas = cardAltList.querySelectorAll(".card-edit-alt-row__textarea");
  data.alternate_greetings = [];
  for (const ta of altTextareas) {
    data.alternate_greetings.push(ta.value);
  }
  return data;
}

function openCardEditor() {
  cardEditOverlay.hidden = false;
  loadCardEditor();
}

function closeCardEditor() {
  cardEditOverlay.hidden = true;
}

async function loadCardEditor() {
  const data = await request("GET", "/api/card/edit");
  if (data) populateCardEditor(data);
}

btnCardEdit.addEventListener("click", openCardEditor);
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
  const data = await request("POST", "/api/card/reset");
  if (data) populateCardEditor(data);
});

cardAltAdd.addEventListener("click", function () {
  const greetings = [];
  for (const ta of cardAltList.querySelectorAll(".card-edit-alt-row__textarea")) {
    greetings.push(ta.value);
  }
  greetings.push("");
  renderAltGreetings(greetings);
});

// ── Persona panel ──────────────────────────────────────────────────────────

const personaSelect = document.getElementById("persona-select");
const personaName = document.getElementById("persona-name");
const personaDescription = document.getElementById("persona-description");
const personaNew = document.getElementById("persona-new");
const personaDelete = document.getElementById("persona-delete");
const personaSave = document.getElementById("persona-save");

let personaList = [];

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
  personaDescription.value = p ? p.description : "";
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
