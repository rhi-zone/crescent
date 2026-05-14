// Chat export feature. Owns: #btn-card-header-export-chat — prompts the
// user for "json" or plain text, GETs /api/export/chat?format=…, and
// downloads the response as a blob using the server-supplied filename.

/**
 * Wire up the chat export button.
 *
 * @param {{ showError: (msg: string) => void }} deps
 * @returns {{ exportChat: (format: string) => Promise<void> }}
 */
export function init(deps) {
  const onError = deps.showError;

  /** @type {HTMLButtonElement} */
  const btnExportChat = /** @type {HTMLButtonElement} */ (
    document.getElementById("btn-card-header-export-chat")
  );

  /**
   * @param {string} format
   */
  async function exportChat(format) {
    let res;
    try {
      res = await fetch("/api/export/chat?format=" + format);
    } catch (e) {
      onError(e instanceof Error ? e.message : String(e));
      return;
    }
    if (!res.ok) {
      onError("Failed to export chat (HTTP " + res.status + ")");
      return;
    }
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    const disp = res.headers.get("content-disposition");
    if (disp) {
      const match = disp.match(/filename="?([^"]+)"?/);
      if (match) a.download = match[1];
    }
    if (!a.download) a.download = "chat." + (format === "json" ? "json" : "txt");
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  btnExportChat.addEventListener("click", function () {
    const format = window.prompt(
      "Export format: type 'json' for JSON, or press OK for plain text",
      "text",
    );
    if (format === null) return; // cancelled
    exportChat(format === "json" ? "json" : "text");
  });

  return { exportChat };
}
