// projections/kbd.js
//
// Atomic projection for `{type: "kbd", keys}`.
// Renders as <span class="prim-kbd"><kbd>K1</kbd>+<kbd>K2</kbd>+...</span>
// with literal "+" text nodes between keys.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectKbd(value, _ctx) {
  const keys = Array.isArray(value.keys) ? value.keys : [];
  const children = [];
  for (let i = 0; i < keys.length; i++) {
    if (i > 0) children.push("+");
    children.push(dom.kbd({}, [String(keys[i])]));
  }
  return dom.span({ class: "prim-kbd" }, children);
}

register("kbd", projectKbd);
