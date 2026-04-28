// projections/grid.js
//
// Composite projection for `{type: "grid", columns?: number, cells: Primitive[]}`.
// Renders <div class="prim-grid"> with CSS grid; column count defaults to 2.
// Each cell is wrapped in <div class="grid-cell"> and recurses through
// `ctx.project`.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectGrid(value, ctx) {
  const cols = typeof value.columns === "number" && value.columns > 0
    ? value.columns
    : 2;
  const cells = value.cells || [];
  const cellEls = [];
  for (let i = 0; i < cells.length; i++) {
    cellEls.push(dom.div({ class: "grid-cell" }, [ctx.project(cells[i])]));
  }
  return dom.div(
    {
      class: "prim-grid",
      style: { gridTemplateColumns: "repeat(" + cols + ", 1fr)" },
    },
    cellEls,
  );
}

register("grid", projectGrid);
