// New Card feature. Owns: #btn-new-card — POSTs /api/new-card.
//
// The backend has two response shapes:
//   - JSON { launch_url } — the `create_instance` cap was granted and the new
//     blank card was installed in-process via the daemon. We redirect.
//   - image/png — the cap wasn't available (or failed). The card PNG is
//     returned for the user to import manually. We trigger a download.
//
// The previous cross-origin attempt against the daemon's /api/apps is gone:
// it never worked from the app subdomain (SameSite cookie blocks it), and the
// `create_instance` cap subsumes it cleanly when granted.

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
      const contentType = res.headers.get("Content-Type") || "";
      if (contentType.indexOf("application/json") !== -1) {
        // create_instance cap path: backend installed the new card and gave
        // us a launch URL to redirect into.
        const data = await res.json();
        if (data && data.launch_url) {
          window.location.href = data.launch_url;
          return;
        }
        onError("new-card: server returned JSON without launch_url");
        return;
      }
      // Binary PNG fallback: trigger a download.
      const buf = await res.arrayBuffer();
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
