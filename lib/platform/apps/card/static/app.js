const messageList = document.getElementById("message-list");
const input = document.getElementById("input");
const btnSend = document.getElementById("btn-send");
const btnRegen = document.getElementById("btn-regen");
const btnContinue = document.getElementById("btn-continue");
const loading = document.getElementById("loading");
const greetingBar = document.querySelector(".greeting-bar");
const greetingLabel = document.querySelector(".greeting-bar__label");
const template = document.getElementById("message-template");

let busy = false;

function setBusy(v) {
  busy = v;
  btnSend.disabled = v;
  btnRegen.disabled = v;
  btnContinue.disabled = v;
  loading.classList.toggle("loading-indicator--visible", v);
}

function scrollToBottom() {
  messageList.scrollTop = messageList.scrollHeight;
}

function addMessage(role, content) {
  const el = template.content.cloneNode(true).firstElementChild;
  el.classList.add("message--" + role);
  el.querySelector(".message__content").textContent = content;
  messageList.appendChild(el);
  scrollToBottom();
  return el;
}

function showError(msg) {
  addMessage("system", "Error: " + msg);
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

function updateGreetingBar(index, total) {
  if (total <= 1) {
    greetingBar.hidden = true;
    return;
  }
  greetingBar.hidden = false;
  greetingLabel.textContent = (index + 1) + "/" + total;
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
  addMessage("user", text);
  setBusy(true);
  const data = await request("POST", "/api/message", { content: text });
  setBusy(false);
  if (data) addMessage(data.role, data.content);
});

// Regenerate — replaces the last assistant message
btnRegen.addEventListener("click", async function () {
  if (busy) return;
  setBusy(true);
  const data = await request("POST", "/api/regenerate");
  setBusy(false);
  if (data) {
    const messages = messageList.querySelectorAll(".message--assistant");
    const last = messages[messages.length - 1];
    if (last) {
      last.querySelector(".message__content").textContent = data.content;
    } else {
      addMessage(data.role, data.content);
    }
  }
});

// Continue
btnContinue.addEventListener("click", async function () {
  if (busy) return;
  setBusy(true);
  const data = await request("POST", "/api/continue");
  setBusy(false);
  if (data) {
    // Replace last assistant message content with continued version
    const messages = messageList.querySelectorAll(".message--assistant");
    const last = messages[messages.length - 1];
    if (last) {
      last.querySelector(".message__content").textContent = data.content;
    } else {
      addMessage(data.role, data.content);
    }
    scrollToBottom();
  }
});

// Greeting navigation
greetingBar.addEventListener("click", async function (e) {
  const action = e.target.dataset.action;
  if (!action || busy) return;
  const endpoint =
    action === "greeting-prev" ? "/api/greeting/prev" : "/api/greeting/next";
  setBusy(true);
  const data = await request("POST", endpoint);
  setBusy(false);
  if (data) {
    // Update the first assistant message (the greeting)
    const first = messageList.querySelector(".message--assistant");
    if (first) {
      first.querySelector(".message__content").textContent = data.content;
    }
    updateGreetingBar(data.index, data.total);
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
    for (const msg of history.messages) {
      addMessage(msg.role, msg.content);
    }
  } else if (card && card.greeting) {
    addMessage("assistant", card.greeting);
    if (card.greeting_total > 1) {
      updateGreetingBar(card.greeting_index || 0, card.greeting_total);
    }
  }
})();
