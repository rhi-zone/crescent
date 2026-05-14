// Shared helpers for ccv2 frontend tests.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resetDOM } from "./dom.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const INDEX_HTML_PATH = resolve(__dirname, "../index.html");

let _cachedIndex = null;
function readIndexHtml() {
  if (_cachedIndex == null) _cachedIndex = readFileSync(INDEX_HTML_PATH, "utf8");
  return _cachedIndex;
}

/** Parse the real production index.html into the polyfill DOM. */
export function loadIndexHtml() {
  return resetDOM(readIndexHtml());
}

/** Create one DOM element (escape hatch for ad-hoc setup). */
export function el(tag, attrs, children) {
  const e = document.createElement(tag);
  if (attrs) {
    for (const k in attrs) {
      if (k === "value") e.value = attrs[k];
      else if (k === "checked") e.checked = !!attrs[k];
      else e.setAttribute(k, attrs[k]);
    }
  }
  if (children) for (const c of children) {
    e.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return e;
}

/** Trigger an event on an element, with optional init dict. */
export function fire(target, type, init) {
  const ev = new Event(type, { bubbles: true, ...(init || {}) });
  if (init) for (const k in init) ev[k] = init[k];
  target.dispatchEvent(ev);
  return ev;
}

/** Microtask flush — await this to let pending Promises settle. */
export async function flush() {
  // Two-tick flush handles `await fetch` chains (response, then .json()).
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

/** Trivial escAttr stub matching the production helper signature. */
export function escAttr(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
