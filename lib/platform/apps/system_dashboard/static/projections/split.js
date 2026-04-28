// projections/split.js
//
// Composite projection for
// `{type: "split", direction?: "row"|"col", parts: Primitive[]}`.
// Renders <div class="prim-split split-{row|col}"> with each part wrapped in
// <div class="split-part"> and recursing through `ctx.project`. Direction
// defaults to "row"; any value other than "col" normalizes to "row".

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectSplit(value, ctx) {
  const dir = value.direction === "col" ? "col" : "row";
  const parts = value.parts || [];
  const partEls = [];
  for (let i = 0; i < parts.length; i++) {
    partEls.push(dom.div({ class: "split-part" }, [ctx.project(parts[i])]));
  }
  return dom.div({ class: "prim-split split-" + dir }, partEls);
}

register("split", projectSplit);
