// Tests for the glass-ui theme module symlinked into static/theme.js.
//
// theme.js auto-applies on import. The module is loaded once per bun
// process; subsequent re-imports return the cached module. Tests therefore
// focus on the exported applyTheme/getTheme behavior after explicit calls.

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml } from "./helpers.js";

beforeEach(() => {
  loadIndexHtml();
});

describe("theme.js", () => {
  test('applyTheme("dark") adds theme-dark to body and persists', async () => {
    const { applyTheme, getTheme } = await import("../theme.js");
    applyTheme("dark");
    expect(document.body.classList.contains("theme-dark")).toBe(true);
    expect(document.body.classList.contains("theme-light")).toBe(false);
    expect(localStorage.getItem("theme")).toBe("dark");
    expect(getTheme()).toBe("dark");
  });

  test('applyTheme("light") adds theme-light and removes theme-dark', async () => {
    const { applyTheme } = await import("../theme.js");
    applyTheme("dark");
    applyTheme("light");
    expect(document.body.classList.contains("theme-light")).toBe(true);
    expect(document.body.classList.contains("theme-dark")).toBe(false);
    expect(localStorage.getItem("theme")).toBe("light");
  });

  test('applyTheme("system") clears both classes and storage', async () => {
    const { applyTheme, getTheme } = await import("../theme.js");
    applyTheme("dark");
    applyTheme("system");
    expect(document.body.classList.contains("theme-dark")).toBe(false);
    expect(document.body.classList.contains("theme-light")).toBe(false);
    expect(localStorage.getItem("theme")).toBeNull();
    expect(getTheme()).toBe("system");
  });

  test("getTheme defaults to system when localStorage is empty", async () => {
    localStorage.clear();
    const { getTheme } = await import("../theme.js");
    expect(getTheme()).toBe("system");
  });

  test("getTheme reads the persisted value", async () => {
    localStorage.setItem("theme", "light");
    const { getTheme } = await import("../theme.js");
    expect(getTheme()).toBe("light");
  });

  test("invalid theme value falls back to system semantics", async () => {
    const { applyTheme } = await import("../theme.js");
    applyTheme("dark");
    applyTheme("nonsense");
    // Invalid input is normalized to "system" → both classes cleared.
    expect(document.body.classList.contains("theme-dark")).toBe(false);
    expect(document.body.classList.contains("theme-light")).toBe(false);
  });
});
