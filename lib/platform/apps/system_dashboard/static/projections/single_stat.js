// projections/single_stat.js
//
// Atomic projection for `{type: "single_stat", value, unit?, label?, delta?, state?}`.
// Renders <div class="prim-stat"> with required `stat-value` and optional
// `stat-label`/`stat-delta` children. `state` (when set together with `delta`)
// adds a `state-${state}` class to the delta div.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectSingleStat(value, _ctx) {
  const valText =
    (value.value == null ? "" : String(value.value)) +
    (value.unit == null ? "" : String(value.unit));
  const children = [dom.div({ class: "stat-value" }, [valText])];
  if (value.label != null) {
    children.push(dom.div({ class: "stat-label" }, [String(value.label)]));
  }
  if (value.delta != null) {
    const cls = "stat-delta" + (value.state ? " state-" + String(value.state) : "");
    children.push(dom.div({ class: cls }, [String(value.delta)]));
  }
  return dom.div({ class: "prim-stat" }, children);
}

register("single_stat", projectSingleStat);
