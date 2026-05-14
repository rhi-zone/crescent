// New Card feature. Owns: #btn-new-card — POSTs /api/new-card to get a
// blank CCv2 PNG, tries to install it via the daemon's `/api/apps`
// endpoint (cross-origin: may fail), and falls back to downloading the
// PNG when install isn't possible.
//
// The cross-origin install path is tracked under "Frictionless new card
// — cross-origin problem" in TODO.md; this module just keeps the
// current behavior.

/**
 * @param {{
 *   showError: (msg: string) => void,
 *   onFallbackDownload?: () => void,
 * }} deps
 * @returns {{}}
 */
export function init(deps) {
  const onError = deps.showError;
  const onFallbackDownload = deps.onFallbackDownload || function () {};

  /** @type {HTMLButtonElement} */
  const btnNewCard = /** @type {HTMLButtonElement} */ (
    document.getElementById("btn-new-card")
  );

  btnNewCard.addEventListener("click", async function () {
    try {
      const res = await fetch("/api/new-card", { method: "POST" });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        onError((data && data.error) ? data.error : "Failed to create new card");
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
      onFallbackDownload();
    } catch (e) {
      onError(e instanceof Error ? e.message : String(e));
    }
  });

  return {};
}
