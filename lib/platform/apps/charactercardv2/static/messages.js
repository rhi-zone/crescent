// messages.js — message list rendering, sibling cache, edit/delete/swipe.
//
// Owns:
//   - #message-list (the container)
//   - <template id="message-template">
//   - Speaker color palette (group chat assistant background tinting)
//   - Sibling cache (message_id → {siblings[], current})
//   - Event delegation on the list: edit / delete / swipe prev/next
//   - Inline edit mode (textarea + Save/Cancel) with focus restore
//
// Exports a single `init(deps)` returning a handle for app.js / send.js
// to drive. `send.js` uses `addMessage` and `setMessageContent` to render
// streaming responses; it does NOT import this module directly — app.js
// passes the messages handle to send.init().

import { request as apiRequest } from "./api.js";
import { renderMarkdown } from "./markdown.js";

/**
 * @typedef {{ id: string, content: string, index: number }} SiblingEntry
 * @typedef {{ siblings: SiblingEntry[], current: number }} SiblingCacheEntry
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

const SPEAKER_COLORS = [
  "var(--bg-message)", "#1a3a2e", "#2e1a3a", "#1a2e3a", "#3a2e1a",
  "#2a1a2e", "#1a3a3a", "#3a1a2a",
];

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   isBusy?: () => boolean,
 *   setBusy?: (v: boolean) => void,
 *   onReloadBelow?: () => void,
 *   onTokenCountStale?: () => void,
 * }} deps
 */
export function init(deps) {
  const showError = deps.showError;
  const isBusy = deps.isBusy || (() => false);
  const setBusy = deps.setBusy || ((_v) => {});
  const onReloadBelow = deps.onReloadBelow || (() => {});
  const onTokenCountStale = deps.onTokenCountStale || (() => {});

  function request(method, path, body, opts_) {
    return apiRequest(method, path, body, { silent: opts_?.silent, onError: showError });
  }

  /** @type {HTMLElement} */
  const messageList = /** @type {HTMLElement} */ (document.getElementById("message-list"));
  /** @type {HTMLTemplateElement} */
  const template = /** @type {HTMLTemplateElement} */ (document.getElementById("message-template"));

  let hasAvatar = false;

  /** @type {Map<string, SiblingCacheEntry>} */
  const siblingCache = new Map();

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

  // Normalize response: backend uses sibling_index/sibling_count
  /** @param {Message} msg */
  function siblingIndex(msg) {
    return msg.sibling_index != null ? msg.sibling_index : (msg.swipe_index || 0);
  }
  /** @param {Message} msg */
  function siblingCount(msg) {
    return msg.sibling_count != null ? msg.sibling_count : (msg.swipe_total || 1);
  }

  function scrollToBottom() {
    messageList.scrollTop = messageList.scrollHeight;
  }

  /**
   * @param {HTMLElement} el
   * @param {string} content
   */
  function setMessageContent(el, content) {
    const contentEl = el.querySelector(".message__content");
    el.dataset.rawContent = content || "";
    /** @type {HTMLElement} */ (contentEl).innerHTML = renderMarkdown(content || "");
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
   * @param {Message} msg
   */
  function updateMessage(el, msg) {
    setMessageContent(el, msg.content);
    if (msg.id) el.dataset.id = msg.id;
    updateSwipeUI(el, siblingIndex(msg), siblingCount(msg));
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

  function clear() {
    messageList.innerHTML = "";
    siblingCache.clear();
  }

  /**
   * @param {string} id
   * @returns {HTMLElement | null}
   */
  function findMessageEl(id) {
    return /** @type {HTMLElement | null} */ (messageList.querySelector('.message[data-id="' + id + '"]'));
  }

  /**
   * Remove all message elements after (and optionally including) a given element.
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

  // ── Event delegation: edit / delete ────────────────────────────────────
  messageList.addEventListener("click", async function (e) {
    const btn = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".message__action-button"));
    if (!btn || isBusy()) return;
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
        onTokenCountStale();
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
            // Edit forked — new branch. Remove messages below, update this one.
            setMessageContent(msgEl, data.content);
            if (data.id) msgEl.dataset.id = data.id;
            updateSwipeUI(msgEl, siblingIndex(data), siblingCount(data));
            removeMessagesFrom(msgEl, false);
            siblingCache.delete(id);
            onReloadBelow();
          } else {
            setMessageContent(msgEl, data.content);
            if (data.id) msgEl.dataset.id = data.id;
            updateSwipeUI(msgEl, siblingIndex(data), siblingCount(data));
          }
          onTokenCountStale();
        } else {
          exitEdit();
        }
      });
    }
  });

  // ── Event delegation: swipe prev/next ──────────────────────────────────
  messageList.addEventListener("click", async function (e) {
    const btn = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".message__swipe-button"));
    if (!btn || isBusy()) return;
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
        onTokenCountStale();
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
          let found = false;
          for (const msg of history.messages) {
            if (found) addMessage(msg);
            if (msg.id === sibling.id) found = true;
          }
        }
        onTokenCountStale();
      }
    }
  });

  return {
    addMessage,
    replaceMessages,
    updateMessage,
    setMessageContent,
    updateSwipeUI,
    siblingIndex,
    siblingCount,
    findMessageEl,
    removeMessagesFrom,
    setHasAvatar(b) { hasAvatar = !!b; },
    clear,
    // exposed for app.js scrollToBottom needs after send/continue
    scrollToBottom,
  };
}
