// projections/heatmap.js
//
// Time-series projection for
// `{type: "heatmap", x_bins, y_bins, values: number[y][x]}`.
// Grid of <rect>s coloured by intensity. Each cell is 12x12. Values are
// normalized against the per-grid max → fill-opacity on the accent color.

import { dom } from "../dom.js";
import { register } from "./registry.js";

// duplicated from app.js renderHeatmap palette; future shared module if duplication grows
const SERIES_COLORS = ["#80a8d0", "#80d080", "#ffd070", "#ff8080", "#c080d0", "#80d0c0"];
const CELL = 12;

function projectHeatmap(value, _ctx) {
  const xb = typeof value.x_bins === "number" && value.x_bins > 0 ? value.x_bins : 1;
  const yb = typeof value.y_bins === "number" && value.y_bins > 0 ? value.y_bins : 1;
  const W = xb * CELL;
  const H = yb * CELL;
  const values = value.values || [];

  let maxV = 0;
  for (let y = 0; y < yb; y++) {
    const row = values[y] || [];
    for (let x = 0; x < xb; x++) {
      const v = typeof row[x] === "number" ? row[x] : 0;
      if (v > maxV) maxV = v;
    }
  }
  if (maxV <= 0) maxV = 1;

  const children = [];
  for (let y = 0; y < yb; y++) {
    const row = values[y] || [];
    for (let x = 0; x < xb; x++) {
      const v = typeof row[x] === "number" ? row[x] : 0;
      let op = v / maxV;
      if (op < 0) op = 0;
      if (op > 1) op = 1;
      children.push(dom.rect({
        x: String(x * CELL),
        y: String(y * CELL),
        width: String(CELL),
        height: String(CELL),
        fill: SERIES_COLORS[0],
        "fill-opacity": op.toFixed(3),
      }, []));
    }
  }

  return dom.svg({
    class: "prim-heatmap",
    width: String(W),
    height: String(H),
    viewBox: "0 0 " + W + " " + H,
  }, children);
}

register("heatmap", projectHeatmap);
