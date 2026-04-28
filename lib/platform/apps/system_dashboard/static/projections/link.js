// projections/link.js
//
// Atomic projection for `{type: "link", href, label?}`.
// Renders as <a class="prim-link" href="..." target="_blank">label||href</a>.
// dom.a auto-emits rel="noopener noreferrer" for target="_blank".

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectLink(value, _ctx) {
  const href = value.href == null ? "" : String(value.href);
  const label = value.label == null ? href : String(value.label);
  return dom.a({ class: "prim-link", href: href, target: "_blank" }, [label]);
}

register("link", projectLink);
