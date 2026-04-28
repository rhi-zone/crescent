// projections/code.js
//
// Atomic projection for `{type: "code", text, lang?}`.
// Renders as <pre class="prim-code" data-lang="${lang||''}">...</pre>.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectCode(value, _ctx) {
  const text = value.text == null ? "" : String(value.text);
  const lang = value.lang == null ? "" : String(value.lang);
  return dom.pre({ class: "prim-code", "data-lang": lang }, [text]);
}

register("code", projectCode);
