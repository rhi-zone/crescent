// Chats sidebar feature. Owns: #btn-sessions, #session-panel, #session-overlay,
// #session-list, #btn-new-session, #btn-close-sessions — open/close, list
// chats, new chat, switch chat, delete chat. Stays pure of message-rendering
// logic: `onSessionSwitch(data)` is invoked with the API response and the
// caller (app.js) reloads the message list. Focus-trap helpers, setBusy, and
// showError are injected.

import { request } from "./api.js";

/**
 * @typedef {{ id: string, preview?: string, created_at?: number }} SessionInfo
 */

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
 * @param {{
 *   showError: (msg: string) => void,
 *   setBusy: (v: boolean) => void,
 *   isBusy: () => boolean,
 *   onSessionSwitch: (data: any) => void,
 *   trapFocus: (overlay: HTMLElement, triggerEl?: Element | null) => void,
 *   releaseFocus: () => void,
 * }} deps
 * @returns {{
 *   open: () => void,
 *   close: () => void,
 *   isOpen: () => boolean,
 *   panel: HTMLElement,
 *   reload: () => Promise<void>,
 *   newSession: () => void,
 * }}
 */
export function init(deps) {
  const onError = deps.showError;
  const setBusy = deps.setBusy;
  const isBusy = deps.isBusy;
  const onSessionSwitch = deps.onSessionSwitch;
  const trapFocus = deps.trapFocus;
  const releaseFocus = deps.releaseFocus;

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
      del.textContent = "×";
      del.title = "Delete";

      item.appendChild(preview);
      item.appendChild(time);
      item.appendChild(del);
      sessionList.appendChild(item);
    }
  }

  async function loadSessions() {
    const data = await request("GET", "/api/sessions", undefined, { onError });
    if (!data) return;
    currentSessionId = data.current;
    renderSessions(data.sessions, data.current);
  }

  btnSessions.addEventListener("click", openSessionPanel);
  btnCloseSessions.addEventListener("click", closeSessionPanel);
  sessionOverlay.addEventListener("click", closeSessionPanel);

  async function newSession() {
    if (isBusy()) return;
    setBusy(true);
    const data = await request("POST", "/api/session/new", undefined, { onError });
    setBusy(false);
    if (data) {
      currentSessionId = data.session.id;
      onSessionSwitch(data);
      loadSessions();
    }
  }

  btnNewSession.addEventListener("click", newSession);

  sessionList.addEventListener("click", async function (e) {
    if (isBusy()) return;
    const del = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".session-item__delete"));
    const item = /** @type {HTMLElement | null} */ (/** @type {HTMLElement} */ (e.target).closest(".session-item"));
    if (!item) return;
    const id = item.dataset.id;

    if (del) {
      // Delete session.
      setBusy(true);
      const data = await request("POST", "/api/session/delete", { session_id: id }, { onError });
      setBusy(false);
      if (data) {
        currentSessionId = data.current_session_id;
        onSessionSwitch(data);
        loadSessions();
      }
      return;
    }

    // Switch session.
    if (id === currentSessionId) return;
    setBusy(true);
    const data = await request("POST", "/api/session/switch", { session_id: id }, { onError });
    setBusy(false);
    if (data) {
      currentSessionId = data.session.id;
      onSessionSwitch(data);
      loadSessions();
    }
  });

  return {
    open: openSessionPanel,
    close: closeSessionPanel,
    isOpen: function () { return !sessionPanel.hidden; },
    panel: sessionPanel,
    reload: loadSessions,
    newSession: newSession,
  };
}
