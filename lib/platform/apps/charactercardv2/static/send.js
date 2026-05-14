// send.js — send / continue / impersonate, including SSE streaming.
//
// Owns: #btn-send, #btn-continue, #btn-impersonate, #input, #loading.
//
// Streaming reads chunks off /api/message/stream and calls messages.addMessage
// for new messages, then mutates `.message__content` directly during token
// ticks (textContent — not markdown — too expensive to re-parse per token).
// On `done`, the final content is re-rendered through messages.setMessageContent
// so markdown formatting takes effect.
//
// Keyboard: Enter / Shift+Enter / Ctrl+Enter on the textarea live here; the
// global Ctrl+Enter shortcut in app.js still goes through btn-send.click().

import { request as apiRequest } from "./api.js";

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   messages: {
 *     addMessage: (msg: any) => HTMLElement,
 *     setMessageContent: (el: HTMLElement, content: string) => void,
 *     updateSwipeUI: (el: HTMLElement, index: number, total: number) => void,
 *     siblingIndex: (msg: any) => number,
 *     siblingCount: (msg: any) => number,
 *     findMessageEl: (id: string) => HTMLElement | null,
 *     updateMessage: (el: HTMLElement, msg: any) => void,
 *     scrollToBottom: () => void,
 *   },
 *   onSent?: () => void,
 *   onTokenCount?: (data: any) => void,
 * }} deps
 */
export function init(deps) {
  const showError = deps.showError;
  const messages = deps.messages;
  const onSent = deps.onSent || (() => {});
  const onTokenCount = deps.onTokenCount || (() => {});

  function request(method, path, body, opts_) {
    return apiRequest(method, path, body, { silent: opts_?.silent, onError: showError });
  }

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

  let busy = false;

  /** @param {boolean} v */
  function setBusy(v) {
    busy = v;
    btnSend.disabled = v;
    btnContinue.disabled = v;
    btnImpersonate.disabled = v;
    loading.classList.toggle("loading-indicator--visible", v);
  }

  function isBusy() { return busy; }

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

  /** @param {string} text */
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
          if (data.user) messages.addMessage(data.user);
          if (data.assistant) messages.addMessage(data.assistant);
          if (data.assistants) {
            for (const a of data.assistants) messages.addMessage(a);
          }
        }
        onSent();
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
            let event;
            try { event = JSON.parse(line.slice(6)); } catch { continue; }
            if (event.type === "user") {
              messages.addMessage({ id: event.id, role: "user", content: event.content });
            } else if (event.type === "token") {
              if (!assistantEl) {
                assistantEl = messages.addMessage({ id: "", role: "assistant", content: "" });
                /** @type {HTMLElement} */ (assistantEl.querySelector(".message__content")).classList.add("message__content--streaming");
              }
              contentSoFar += event.token;
              // Plain text during streaming (too expensive to re-parse every token)
              /** @type {HTMLElement} */ (assistantEl.querySelector(".message__content")).textContent = contentSoFar;
              messages.scrollToBottom();
            } else if (event.type === "done") {
              if (assistantEl) {
                /** @type {HTMLElement} */ (assistantEl.querySelector(".message__content")).classList.remove("message__content--streaming");
                assistantEl.dataset.id = event.id ?? "";
                // Render final content as markdown
                messages.setMessageContent(assistantEl, event.content);
                messages.updateSwipeUI(assistantEl, messages.siblingIndex(event), messages.siblingCount(event));
              } else {
                messages.addMessage(event);
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
    onSent();
  }

  async function send() {
    const text = input.value.trim();
    if (!text || busy) return;
    input.value = "";
    await sendStreaming(text);
  }

  async function continueLast() {
    if (busy) return;
    setBusy(true);
    const data = await request("POST", "/api/continue");
    setBusy(false);
    if (data) {
      const el = messages.findMessageEl(data.id);
      if (el) {
        messages.updateMessage(el, data);
      } else {
        messages.addMessage(data);
      }
      messages.scrollToBottom();
      if (data.token_count) onTokenCount(data.token_count);
    }
    onSent();
  }

  async function impersonate() {
    if (busy) return;
    setBusy(true);
    const data = await request("POST", "/api/impersonate");
    setBusy(false);
    if (data && data.content) {
      input.value = data.content;
      input.focus();
    }
  }

  // Button wiring.
  btnSend.addEventListener("click", function () { send(); });
  btnContinue.addEventListener("click", function () { continueLast(); });
  btnImpersonate.addEventListener("click", function () { impersonate(); });

  return {
    send,
    continueLast,
    impersonate,
    setBusy,
    isBusy,
    // app.js global Ctrl+Enter shortcut clicks btnSend directly via the
    // button reference, but exposing it here keeps the integration cleaner
    // if the shortcut migrates in.
    btnSend,
  };
}
