// Token counter feature. Owns: #token-count-text, #token-count-fill —
// fetches /api/token_count and renders the used/max count + progress bar.
//
// The fill turns yellow above 50% and red above 80% to signal context
// pressure.

import { request as apiRequest } from "./api.js";

/**
 * @typedef {{
 *   context_used?: number,
 *   context_max?: number
 * }} TokenCountData
 */

/**
 * Wire up the token counter.
 *
 * @param {{ showError: (msg: string) => void }} deps
 * @returns {{ refresh: () => Promise<void>, update: (data: TokenCountData | null | undefined) => void }}
 */
export function init(deps) {
  const onError = deps.showError;

  /** @type {HTMLElement} */
  const tokenCountText = /** @type {HTMLElement} */ (document.getElementById("token-count-text"));
  /** @type {HTMLElement} */
  const tokenCountFill = /** @type {HTMLElement} */ (document.getElementById("token-count-fill"));

  /**
   * @param {TokenCountData | null | undefined} data
   */
  function update(data) {
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

  async function refresh() {
    const data = await apiRequest("GET", "/api/token_count", undefined, { onError });
    if (data) update(data);
  }

  return { refresh, update };
}
