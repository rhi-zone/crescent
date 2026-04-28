// projections/icon.js
//
// Atomic projection for `{type: "icon", name, tone?}`.
// Renders as <span class="prim-icon" data-icon="..." data-tone="...">name</span>.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectIcon(value, _ctx) {
  // TODO swap text fallback for a vendored icon set
  const name = value.name == null ? "" : String(value.name);
  const tone = value.tone == null ? "" : String(value.tone);
  return dom.span(
    { class: "prim-icon", "data-icon": name, "data-tone": tone },
    [name],
  );
}

register("icon", projectIcon);
