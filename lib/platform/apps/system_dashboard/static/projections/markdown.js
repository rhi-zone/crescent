// projections/markdown.js
//
// Atomic projection for `{type: "markdown", text}`.
// Placeholder rendering — emits the raw text inside a <pre>.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectMarkdown(value, _ctx) {
  // TODO render via lib/markdown once it exists
  const text = value.text == null ? "" : String(value.text);
  return dom.pre({ class: "prim-markdown" }, [text]);
}

register("markdown", projectMarkdown);
