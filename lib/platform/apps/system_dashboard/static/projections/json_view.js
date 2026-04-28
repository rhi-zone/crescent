// projections/json_view.js
//
// Hierarchical projection for `{type: "json_view", value, expand_depth?}`.
// Renders <div class="prim-jsonview"> wrapping a recursive node tree built by
// `renderJsonNode`. `expand_depth` controls how many levels are open by
// default (default 1). Object/array nodes are <details>/<summary>; scalars
// are <span> with type-specific classes (json-null, json-string, json-number,
// json-boolean, json-unknown).
//
// Recursion stays internal — JSON values are not primitives, so we do NOT
// route them through `ctx.project`.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function renderJsonNode(value, depth, expandDepth) {
  if (value === null) {
    return dom.span({ class: "json-null" }, ["null"]);
  }
  const tt = typeof value;
  if (tt === "string") {
    return dom.span({ class: "json-string" }, [JSON.stringify(value)]);
  }
  if (tt === "number") {
    return dom.span({ class: "json-number" }, [String(value)]);
  }
  if (tt === "boolean") {
    return dom.span({ class: "json-boolean" }, [value ? "true" : "false"]);
  }
  if (tt === "object") {
    const isArr = Array.isArray(value);
    const count = isArr ? value.length : Object.keys(value).length;
    const summaryText = (isArr ? "[" : "{") + " " + count + " "
      + (isArr ? "items" : "keys") + " " + (isArr ? "]" : "}");
    const detKids = [dom.summary({ class: "json-summary" }, [summaryText])];
    if (isArr) {
      for (let ai = 0; ai < value.length; ai++) {
        detKids.push(dom.div({ class: "json-row" }, [
          dom.span({ class: "json-key" }, [String(ai) + ": "]),
          renderJsonNode(value[ai], depth + 1, expandDepth),
        ]));
      }
    } else {
      const keys = Object.keys(value);
      for (let ki = 0; ki < keys.length; ki++) {
        detKids.push(dom.div({ class: "json-row" }, [
          dom.span({ class: "json-key" }, [keys[ki] + ": "]),
          renderJsonNode(value[keys[ki]], depth + 1, expandDepth),
        ]));
      }
    }
    const props = depth < expandDepth ? { open: true } : {};
    return dom.details(props, detKids);
  }
  return dom.span({ class: "json-unknown" }, [String(value)]);
}

function projectJsonView(value, _ctx) {
  const depth = typeof value.expand_depth === "number" ? value.expand_depth : 1;
  return dom.div({ class: "prim-jsonview" }, [
    renderJsonNode(value.value, 0, depth),
  ]);
}

register("json_view", projectJsonView);
