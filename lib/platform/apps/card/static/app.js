const messageList = document.getElementById("message-list");
const input = document.getElementById("input");
const btnSend = document.getElementById("btn-send");
const btnContinue = document.getElementById("btn-continue");
const loading = document.getElementById("loading");
const template = document.getElementById("message-template");

let busy = false;

// Swipe cache: message_id -> {swipes: [{id, content, index}], current: index}
const swipeCache = new Map();

function setBusy(v) {
  busy = v;
  btnSend.disabled = v;
  btnContinue.disabled = v;
  loading.classList.toggle("loading-indicator--visible", v);
}

function scrollToBottom() {
  messageList.scrollTop = messageList.scrollHeight;
}

// Add a message to the list. Returns the DOM element.
// msg: {id, role, content, swipe_index?, swipe_total?}
function addMessage(msg) {
  const el = template.content.cloneNode(true).firstElementChild;
  el.classList.add("message--" + msg.role);
  el.dataset.id = msg.id || "";
  el.querySelector(".message__content").textContent = msg.content;
  updateSwipeUI(el, msg.swipe_index, msg.swipe_total);
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
  el.querySelector(".message__content").textContent = msg.content;
  if (msg.id) el.dataset.id = msg.id;
  updateSwipeUI(el, msg.swipe_index, msg.swipe_total);
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

// Fetch and cache all swipes for a message. Returns the cached entry.
async function ensureSwipes(messageId) {
  if (swipeCache.has(messageId)) return swipeCache.get(messageId);
  const data = await request("GET", "/api/swipes?message_id=" + messageId);
  if (!data) return null;
  const entry = { swipes: data.swipes, current: data.current };
  swipeCache.set(messageId, entry);
  return entry;
}

// Navigate to a swipe by index (from cache). Returns the swipe or null.
function navigateSwipe(messageId, index) {
  const entry = swipeCache.get(messageId);
  if (!entry || index < 0 || index >= entry.swipes.length) return null;
  entry.current = index;
  const s = entry.swipes[index];
  return {
    id: s.id,
    content: s.content,
    swipe_index: index,
    swipe_total: entry.swipes.length,
  };
}

// Add a newly generated swipe to the cache
function addSwipeToCache(messageId, swipe) {
  const entry = swipeCache.get(messageId);
  if (!entry) return;
  entry.swipes.push(swipe);
  entry.current = entry.swipes.length - 1;
}

function findMessageEl(id) {
  return messageList.querySelector('.message[data-id="' + id + '"]');
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
      // Fall back to non-streaming
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
      // Parse SSE events from buffer
      const parts = buffer.split("\n\n");
      buffer = parts.pop(); // last part is incomplete
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
            }
            contentSoFar += event.token;
            assistantEl.querySelector(".message__content").textContent = contentSoFar;
            scrollToBottom();
          } else if (event.type === "done") {
            if (assistantEl) {
              assistantEl.dataset.id = event.id;
              assistantEl.querySelector(".message__content").textContent = event.content;
              updateSwipeUI(assistantEl, event.swipe_index, event.swipe_total);
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
  // Check if we're leaving to a child — relatedTarget still inside message
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
      // Remove deleted messages from DOM — the target message and all after it
      const messages = Array.from(messageList.querySelectorAll(".message"));
      let found = false;
      for (const el of messages) {
        if (el.dataset.id === id) found = true;
        if (found) el.remove();
      }
    }
  } else if (action === "edit") {
    const contentEl = msgEl.querySelector(".message__content");
    const actionsEl = msgEl.querySelector(".message__actions");
    const original = contentEl.textContent;

    // Enter edit mode
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
        contentEl.textContent = data.content;
        if (data.id) msgEl.dataset.id = data.id;
        updateSwipeUI(msgEl, data.swipe_index, data.swipe_total);
      }
      exitEdit();
    });
  }
});

// Swipe navigation — delegated from message list
messageList.addEventListener("click", async function (e) {
  const btn = e.target.closest(".message__swipe-button");
  if (!btn || busy) return;
  const msgEl = btn.closest(".message");
  const id = msgEl.dataset.id;
  if (!id) return;

  const dir = btn.dataset.dir;

  // Fetch all swipes on first interaction
  setBusy(true);
  const entry = await ensureSwipes(id);
  setBusy(false);
  if (!entry) return;

  const current = entry.current;

  if (dir === "next" && current >= entry.swipes.length - 1) {
    // Next past end — generate a new swipe
    setBusy(true);
    const data = await request("POST", "/api/swipe/new", { message_id: id });
    setBusy(false);
    if (data) {
      addSwipeToCache(id, { id: data.id, content: data.content, index: entry.swipes.length - 1 });
      updateMessage(msgEl, {
        id: data.id,
        content: data.content,
        swipe_index: entry.current,
        swipe_total: entry.swipes.length,
      });
    }
  } else {
    const nextIndex = dir === "next" ? current + 1 : Math.max(0, current - 1);
    const swipe = navigateSwipe(id, nextIndex);
    if (swipe) updateMessage(msgEl, swipe);
  }
});

// Init
(async function () {
  setBusy(true);
  const [card, history] = await Promise.all([
    request("GET", "/api/card"),
    request("GET", "/api/messages"),
  ]);
  setBusy(false);

  if (card) document.title = card.name || "Card";

  if (history && history.messages && history.messages.length > 0) {
    for (const msg of history.messages) addMessage(msg);
  } else if (card && card.greeting) {
    addMessage(card.greeting);
  }
})();
