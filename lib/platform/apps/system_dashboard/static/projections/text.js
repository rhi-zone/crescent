// projections/text.js
//
// Atomic projection for `{type: "text", text, style?}`.
// Renders as <div class="prim-text"><pre>...</pre></div>. When `style` is one
// of {muted, strong, error, success}, the inner <pre> gains `style-${style}`.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectText(value, _ctx) {
  const cls = value.style ? "style-" + String(value.style) : null;
  const preProps = cls ? { class: cls } : {};
  const text = value.text == null ? "" : String(value.text);
  return dom.div({ class: "prim-text" }, [
    dom.pre(preProps, [text]),
  ]);
}

register("text", projectText);
