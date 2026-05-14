// Card state feature. Owns: card-header visibility, card-header-name,
// card-avatar visibility, btn-card-header-edit/export visibility, the
// loaded card's `writable` flag, and the "no card / greeting / history"
// boot population of the message list.
//
// Exposes `getCardWritable()` and `getHasAvatar()` for other modules
// (card editor, card lorebook, messages) to query without owning the
// fetch.

import { request as apiRequest } from "./api.js";

/**
 * @typedef {{
 *   name?: string,
 *   writable?: boolean,
 *   greeting?: any
 * }} Card
 */

/**
 * @typedef {{
 *   addMessage: (msg: any) => any,
 *   replaceMessages: (msgs: any[]) => any,
 *   setHasAvatar: (b: boolean) => any
 * }} MessagesHandle
 */

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   messages: MessagesHandle,
 *   onCardLoaded?: (card: Card | null) => void,
 * }} deps
 * @returns {{
 *   reload: () => Promise<void>,
 *   getCardWritable: () => boolean,
 *   getHasAvatar: () => boolean,
 * }}
 */
export function init(deps) {
  const onError = deps.showError;
  const messages = deps.messages;
  const onCardLoaded = deps.onCardLoaded || function () {};

  /** @type {HTMLElement} */
  const cardHeader = /** @type {HTMLElement} */ (document.getElementById("card-header"));
  /** @type {HTMLImageElement} */
  const cardAvatar = /** @type {HTMLImageElement} */ (document.getElementById("card-avatar"));
  /** @type {HTMLElement} */
  const cardHeaderName = /** @type {HTMLElement} */ (document.getElementById("card-header-name"));
  /** @type {HTMLButtonElement} */
  const btnCardHeaderEdit = /** @type {HTMLButtonElement} */ (
    document.getElementById("btn-card-header-edit")
  );
  /** @type {HTMLAnchorElement} */
  const btnCardHeaderExport = /** @type {HTMLAnchorElement} */ (
    document.getElementById("btn-card-header-export")
  );

  let cardWritable = false;
  let hasAvatar = false;

  async function checkAvatar() {
    try {
      const res = await fetch("/api/avatar", { method: "HEAD" });
      if (res.ok) {
        hasAvatar = true;
        messages.setHasAvatar(true);
        cardAvatar.hidden = false;
      } else {
        hasAvatar = false;
        cardAvatar.hidden = true;
      }
    } catch {
      hasAvatar = false;
      cardAvatar.hidden = true;
    }
  }

  async function reload() {
    const [card, history] = await Promise.all([
      apiRequest("GET", "/api/card", undefined, { silent: true, onError }),
      apiRequest("GET", "/api/messages", undefined, { silent: true, onError }),
      checkAvatar(),
    ]);

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
      cardWritable = false;
      btnCardHeaderEdit.hidden = true;
      btnCardHeaderExport.hidden = true;
      messages.addMessage({
        id: "",
        role: "system",
        content: "No card loaded. Go to the library to import or create a card.",
      });
    }

    if (history && history.messages && history.messages.length > 0) {
      for (const msg of history.messages) messages.addMessage(msg);
    } else if (card && card.greeting) {
      messages.addMessage(card.greeting);
    }

    onCardLoaded(card || null);
  }

  return {
    reload,
    getCardWritable: function () { return cardWritable; },
    getHasAvatar: function () { return hasAvatar; },
  };
}
