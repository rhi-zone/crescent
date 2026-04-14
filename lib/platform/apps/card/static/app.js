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

// Send
btnSend.addEventListener("click", async function () {
  const text = input.value.trim();
  if (!text || busy) return;
  input.value = "";
  input.style.height = "auto";
  setBusy(true);
  const data = await request("POST", "/api/message", { content: text });
  setBusy(false);
  if (data) {
    if (data.user) addMessage(data.user);
    if (data.assistant) addMessage(data.assistant);
  }
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
