// projections/gauge.js
//
// Atomic projection for
// `{type: "gauge", value, min, max, unit?, thresholds?: [{at, state}]}`.
// Renders <div class="prim-gauge"> with a `gauge-fill` div whose width is the
// clamped `(value-min)/(max-min)*100` percentage, and a `gauge-overlay` span
// showing the numeric value with optional unit suffix. When thresholds are
// supplied, the highest threshold whose `at <= value` contributes a
// `state-${state}` class to the fill.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectGauge(value, _ctx) {
  const min = typeof value.min === "number" ? value.min : 0;
  const max = typeof value.max === "number" ? value.max : 100;
  const v = typeof value.value === "number" ? value.value : 0;
  const span = max - min;
  let pct = span > 0 ? ((v - min) / span) * 100 : 0;
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;

  let stateClass = "";
  if (value.thresholds && value.thresholds.length) {
    let bestAt = -Infinity;
    let bestState = null;
    for (let i = 0; i < value.thresholds.length; i++) {
      const th = value.thresholds[i];
      if (typeof th.at === "number" && th.at <= v && th.at >= bestAt) {
        bestAt = th.at;
        bestState = th.state;
      }
    }
    if (bestState) stateClass = " state-" + String(bestState);
  }

  const fill = dom.div(
    { class: "gauge-fill" + stateClass, style: { width: pct + "%" } },
    [],
  );
  const overlayText = String(v) + (value.unit == null ? "" : String(value.unit));
  const overlay = dom.span({ class: "gauge-overlay" }, [overlayText]);
  return dom.div({ class: "prim-gauge" }, [fill, overlay]);
}

register("gauge", projectGauge);
