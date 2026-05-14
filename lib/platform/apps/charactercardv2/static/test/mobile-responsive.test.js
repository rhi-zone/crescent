// Aspirational tests for the mobile-responsive burger menu in the card
// header. The polyfill DOM has no real viewport / media query support, so we
// can't assert CSS visibility directly — instead we assert the *class /
// aria-expanded contract* that the CSS hooks into:
//
//   - burger present, aria-expanded="false" at load
//   - tap → aria-expanded="true", `.card-header--menu-open` on header
//   - second tap → closes
//   - first focusable action receives focus when opened
//   - clicking an action closes the menu
//
// Note: app.js wires the burger handler at module-eval time. bun caches the
// module across tests in the same file, so handlers bind to the DOM that
// existed during the *first* import. The single combined test below
// exercises everything against that initial DOM.

import { describe, test, expect, beforeAll } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";

describe("card-header burger menu", () => {
  test("DOM has burger button with correct aria attributes", () => {
    loadIndexHtml();
    const btn = document.getElementById("btn-card-header-burger");
    expect(btn).not.toBeNull();
    expect(btn.getAttribute("aria-label")).toBe("Open card actions");
    expect(btn.getAttribute("aria-expanded")).toBe("false");
    expect(btn.getAttribute("aria-controls")).toBe("card-header-actions");
    const actions = document.getElementById("card-header-actions");
    expect(actions).not.toBeNull();
    expect(actions.classList.contains("card-header__actions")).toBe(true);
  });

  test("burger toggle contract — open, focus, close, action-click closes", async () => {
    // Fresh DOM, then load app.js so its handlers attach to it. Subsequent
    // imports of app.js will be cached; this test owns the live wiring.
    loadIndexHtml();
    try { await import("../app.js"); } catch { /* fetch missing in tests */ }
    await flush();

    const btn = document.getElementById("btn-card-header-burger");
    const header = document.getElementById("card-header");
    const edit = document.getElementById("btn-card-header-edit");
    expect(btn).not.toBeNull();
    expect(header).not.toBeNull();

    // Initial: closed.
    expect(btn.getAttribute("aria-expanded")).toBe("false");
    expect(header.classList.contains("card-header--menu-open")).toBe(false);

    // First tap → open + focus moves to first action.
    btn.click();
    expect(btn.getAttribute("aria-expanded")).toBe("true");
    expect(header.classList.contains("card-header--menu-open")).toBe(true);
    expect(document.activeElement).toBe(edit);

    // Second tap → closed.
    btn.click();
    expect(btn.getAttribute("aria-expanded")).toBe("false");
    expect(header.classList.contains("card-header--menu-open")).toBe(false);

    // Open again, then click the Edit action — actions container handler
    // closes the menu (better mobile UX than tapping the burger again).
    btn.click();
    expect(header.classList.contains("card-header--menu-open")).toBe(true);
    edit.click();
    expect(header.classList.contains("card-header--menu-open")).toBe(false);
    expect(btn.getAttribute("aria-expanded")).toBe("false");
  });
});
