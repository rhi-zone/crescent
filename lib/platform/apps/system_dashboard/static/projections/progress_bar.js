// projections/progress_bar.js
//
// Atomic projection for
// `{type: "progress_bar", value, max, label?, indeterminate?}`.
// Renders <div class="prim-progress"> wrapping an optional `progress-label`
// div and an inner gauge skeleton (`prim-gauge` + `gauge-fill`). When
// `indeterminate` is truthy the fill gets `.indeterminate` and no width is
// set; otherwise width is the clamped `(value/max)*100` percentage.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectProgressBar(value, _ctx) {
  const children = [];
  if (value.label != null) {
    children.push(dom.div({ class: "progress-label" }, [String(value.label)]));
  }
  let fill;
  if (value.indeterminate) {
    fill = dom.div({ class: "gauge-fill indeterminate" }, []);
  } else {
    const max = typeof value.max === "number" && value.max > 0 ? value.max : 1;
    const v = typeof value.value === "number" ? value.value : 0;
    let pct = (v / max) * 100;
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    fill = dom.div({ class: "gauge-fill", style: { width: pct + "%" } }, []);
  }
  children.push(dom.div({ class: "prim-gauge" }, [fill]));
  return dom.div({ class: "prim-progress" }, children);
}

register("progress_bar", projectProgressBar);
