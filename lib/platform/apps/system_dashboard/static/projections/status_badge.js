// projections/status_badge.js
//
// Atomic projection for `{type: "status_badge", state?, label?}`.
// Renders as <span class="prim-badge state-${state}">${label}</span>.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectStatusBadge(value, _ctx) {
  const state = value.state == null ? "unknown" : String(value.state);
  const label = value.label == null ? "" : String(value.label);
  return dom.span({ class: "prim-badge state-" + state }, [label]);
}

register("status_badge", projectStatusBadge);
