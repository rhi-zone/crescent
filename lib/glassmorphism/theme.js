// Glassmorphism theme toggle.
//
// `applyTheme(theme)` sets the `body.theme-dark` / `body.theme-light` class
// pair (forcing a theme regardless of `prefers-color-scheme`) and persists
// the choice to `localStorage` under key `"theme"`. Pass `"system"` to clear
// both classes and follow the OS preference.
//
// The module auto-applies the saved theme on import. Apps that need a
// `<select>` or button just call `applyTheme(selected)` on change.

const STORAGE_KEY = "theme";
const VALID = new Set(["dark", "light", "system"]);

function safeStorage() {
  try {
    if (typeof localStorage !== "undefined") return localStorage;
  } catch (_) {
    // localStorage access can throw (file:// in some browsers, privacy mode).
  }
  return null;
}

export function getTheme() {
  const store = safeStorage();
  if (!store) return "system";
  const v = store.getItem(STORAGE_KEY);
  return VALID.has(v) ? v : "system";
}

export function applyTheme(theme) {
  if (!VALID.has(theme)) theme = "system";
  const store = safeStorage();
  if (store) {
    if (theme === "system") store.removeItem(STORAGE_KEY);
    else store.setItem(STORAGE_KEY, theme);
  }
  if (typeof document === "undefined" || !document.body) return theme;
  const body = document.body;
  body.classList.remove("theme-dark", "theme-light");
  if (theme === "dark") body.classList.add("theme-dark");
  else if (theme === "light") body.classList.add("theme-light");
  return theme;
}

// Auto-apply on import. Defer until body exists if the document is still
// parsing, so that the class actually lands on <body>.
function autoApply() {
  applyTheme(getTheme());
}

if (typeof document !== "undefined") {
  if (document.body) autoApply();
  else if (typeof document.addEventListener === "function") {
    document.addEventListener("DOMContentLoaded", autoApply, { once: true });
  }
}
