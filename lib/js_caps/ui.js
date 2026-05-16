// lib/js_caps/ui.js
//
// Day-zero `toast` / `dialog` / `navigate` cap implementations. These
// three caps are pure routing layers: the cap impl validates the pack-
// supplied args and forwards them to a host-app-provided UI primitive.
// The host app owns the actual rendering (toast surface, modal dialog
// chrome, in-shell router). The caps own the validated-input boundary.
//
// Spec: docs/browser_caps.md §4.4.10 (navigate), §4.10.3 (dialog),
// §4.10.4 (toast), §5 day-zero exposed cap surface.
//
// Why factory-shaped: the rendering primitives are part of the host
// app's chrome -- they are not globally available the way `fetch` or
// `indexedDB` are. The host page injects them at mount time via
// `makeUiCaps({ renderToast, renderDialog, requestNavigate })`. The
// produced caps close over those primitives; they are NOT in
// `dayZeroCaps` because they are app-bound, not global pure functions.
//
// Why one factory for three caps: they share a single injection point
// (the host app's UI layer). Splitting into three factories would mean
// the caller wires the same `uiPrimitives` object three times. One
// factory returning the three-cap record matches `makeKvCaps`'s
// precedent (one factory, four caps that share an IndexedDB backend).
//
// Lockdown / chrome integrity: the cap impls never touch the DOM
// directly. All UI work happens in the host realm via the injected
// primitive. The pack realm sees only the awaited result of the
// `postMessage` round-trip. This means the host app -- not the pack --
// chooses how a toast looks, what buttons a dialog renders, where a
// navigation lands. The caps are deliberately small: structural arg
// validation, call into the host primitive, return the result.

const MAX_TOAST_MESSAGE = 512;
const MAX_TOAST_DURATION = 30_000;
const DEFAULT_TOAST_DURATION = 3000;
const ALLOWED_TOAST_LEVELS = new Set(["info", "warning", "error"]);

const MAX_DIALOG_MESSAGE = 1024;
const MAX_DIALOG_BUTTONS = 8;

const MAX_NAVIGATE_PATH = 2048;

/**
 * Construct the three UI cap impls bound to a host-app-supplied set of
 * rendering primitives.
 *
 * @param {{
 *   renderToast: (args: { message: string, level: "info"|"warning"|"error", duration: number }) => void | Promise<void>,
 *   renderDialog: (args: { message: string, buttons: string[] }) => Promise<string>,
 *   requestNavigate: (args: { path: string }) => void | Promise<void>,
 * }} uiPrimitives
 * @returns {{
 *   toast: (args: { message: string, level?: "info"|"warning"|"error", duration?: number }) => Promise<void>,
 *   dialog: (args: { message: string, buttons: string[] }) => Promise<string>,
 *   navigate: (args: { path: string }) => Promise<void>,
 * }}
 */
export function makeUiCaps(uiPrimitives) {
  if (uiPrimitives === null || typeof uiPrimitives !== "object") {
    throw new TypeError(
      "makeUiCaps: uiPrimitives must be an object with renderToast/renderDialog/requestNavigate",
    );
  }
  const p = /** @type {Record<string, unknown>} */ (uiPrimitives);
  if (typeof p.renderToast !== "function") {
    throw new TypeError("makeUiCaps: uiPrimitives.renderToast must be a function");
  }
  if (typeof p.renderDialog !== "function") {
    throw new TypeError("makeUiCaps: uiPrimitives.renderDialog must be a function");
  }
  if (typeof p.requestNavigate !== "function") {
    throw new TypeError("makeUiCaps: uiPrimitives.requestNavigate must be a function");
  }
  const renderToast = /** @type {(args: { message: string, level: string, duration: number }) => void | Promise<void>} */ (p.renderToast);
  const renderDialog = /** @type {(args: { message: string, buttons: string[] }) => Promise<string>} */ (p.renderDialog);
  const requestNavigate = /** @type {(args: { path: string }) => void | Promise<void>} */ (p.requestNavigate);

  // Concise-method syntax drops [[Construct]]; `new toast(...)` throws.
  // Matches fetch_api.js / kv.js precedent.
  return {
    async toast(/** @type {unknown} */ args) {
      if (args === null || typeof args !== "object") {
        throw new TypeError("toast: args must be an object");
      }
      const a = /** @type {Record<string, unknown>} */ (args);

      if (typeof a.message !== "string") {
        throw new TypeError("toast: args.message must be a string");
      }
      if (a.message.length === 0) {
        throw new TypeError("toast: args.message must be non-empty");
      }
      if (a.message.length > MAX_TOAST_MESSAGE) {
        throw new RangeError(
          "toast: args.message exceeds " + MAX_TOAST_MESSAGE +
          " chars (got " + a.message.length + ")",
        );
      }

      let level = "info";
      if (a.level !== undefined && a.level !== null) {
        if (typeof a.level !== "string") {
          throw new TypeError("toast: args.level must be a string");
        }
        if (!ALLOWED_TOAST_LEVELS.has(a.level)) {
          throw new TypeError(
            "toast: args.level must be one of 'info', 'warning', 'error' " +
            "(got " + a.level + ")",
          );
        }
        level = a.level;
      }

      let duration = DEFAULT_TOAST_DURATION;
      if (a.duration !== undefined && a.duration !== null) {
        if (typeof a.duration !== "number" || !isFinite(a.duration)) {
          throw new TypeError("toast: args.duration must be a finite number");
        }
        if (a.duration < 0) {
          throw new RangeError("toast: args.duration must be non-negative");
        }
        if (a.duration > MAX_TOAST_DURATION) {
          throw new RangeError(
            "toast: args.duration exceeds " + MAX_TOAST_DURATION +
            " ms (got " + a.duration + ")",
          );
        }
        duration = a.duration;
      }

      await renderToast({ message: a.message, level, duration });
    },

    async dialog(/** @type {unknown} */ args) {
      if (args === null || typeof args !== "object") {
        throw new TypeError("dialog: args must be an object");
      }
      const a = /** @type {Record<string, unknown>} */ (args);

      if (typeof a.message !== "string") {
        throw new TypeError("dialog: args.message must be a string");
      }
      if (a.message.length === 0) {
        throw new TypeError("dialog: args.message must be non-empty");
      }
      if (a.message.length > MAX_DIALOG_MESSAGE) {
        throw new RangeError(
          "dialog: args.message exceeds " + MAX_DIALOG_MESSAGE +
          " chars (got " + a.message.length + ")",
        );
      }

      if (!Array.isArray(a.buttons)) {
        throw new TypeError("dialog: args.buttons must be an array");
      }
      if (a.buttons.length === 0) {
        throw new TypeError("dialog: args.buttons must be non-empty");
      }
      if (a.buttons.length > MAX_DIALOG_BUTTONS) {
        throw new RangeError(
          "dialog: args.buttons exceeds " + MAX_DIALOG_BUTTONS +
          " entries (got " + a.buttons.length + ")",
        );
      }
      /** @type {string[]} */
      const buttons = [];
      for (let i = 0; i < a.buttons.length; i++) {
        const b = a.buttons[i];
        if (typeof b !== "string") {
          throw new TypeError(
            "dialog: args.buttons[" + i + "] must be a string",
          );
        }
        if (b.length === 0) {
          throw new TypeError(
            "dialog: args.buttons[" + i + "] must be non-empty",
          );
        }
        buttons.push(b);
      }

      const result = await renderDialog({ message: a.message, buttons });
      // The host primitive must return one of the button names. A
      // mismatch is a host-side contract violation and surfaces as an
      // error to the pack -- the pack should not have to handle a
      // "stranger" string here.
      if (typeof result !== "string") {
        throw new Error("dialog: host returned non-string from renderDialog");
      }
      let matched = false;
      for (let i = 0; i < buttons.length; i++) {
        if (buttons[i] === result) { matched = true; break; }
      }
      if (!matched) {
        throw new Error("dialog: host returned unknown button");
      }
      return result;
    },

    async navigate(/** @type {unknown} */ args) {
      if (args === null || typeof args !== "object") {
        throw new TypeError("navigate: args must be an object");
      }
      const a = /** @type {Record<string, unknown>} */ (args);

      // `path` is host-app-defined: could be a URL fragment, a route
      // name, an external URL, etc. The cap does not validate the
      // shape -- that's the host's `requestNavigate` responsibility,
      // which knows what its router accepts. The cap only enforces
      // the structural contract: non-empty string, bounded length.
      if (typeof a.path !== "string") {
        throw new TypeError("navigate: args.path must be a string");
      }
      if (a.path.length === 0) {
        throw new TypeError("navigate: args.path must be non-empty");
      }
      if (a.path.length > MAX_NAVIGATE_PATH) {
        throw new RangeError(
          "navigate: args.path exceeds " + MAX_NAVIGATE_PATH +
          " chars (got " + a.path.length + ")",
        );
      }

      await requestNavigate({ path: a.path });
    },
  };
}
