// projections/sparkline.js
//
// Atomic projection for `{type: "sparkline", points: number[], unit?}`.
// Renders an inline 120x24 SVG. Empty points → empty <svg>. Single point →
// centered dot. Two or more points → polyline normalized into the viewBox.
// `unit` is currently unused (mirrors the legacy renderPrimitive behavior).

import { dom } from "../dom.js";
import { register } from "./registry.js";

const W = 120;
const H = 24;

function projectSparkline(value, _ctx) {
  const pts = value.points || [];
  const children = [];
  if (pts.length === 1) {
    children.push(dom.circle({
      cx: String(W / 2),
      cy: String(H / 2),
      r: "2",
      fill: "currentColor",
    }, []));
  } else if (pts.length > 1) {
    let sMin = pts[0];
    let sMax = pts[0];
    for (let i = 1; i < pts.length; i++) {
      if (pts[i] < sMin) sMin = pts[i];
      if (pts[i] > sMax) sMax = pts[i];
    }
    const span = sMax - sMin;
    const coords = [];
    for (let j = 0; j < pts.length; j++) {
      const x = (j / (pts.length - 1)) * W;
      const y = span > 0 ? H - ((pts[j] - sMin) / span) * H : H / 2;
      coords.push(x.toFixed(2) + "," + y.toFixed(2));
    }
    children.push(dom.polyline({
      points: coords.join(" "),
      fill: "none",
      stroke: "currentColor",
      "stroke-width": "1",
    }, []));
  }
  return dom.svg({
    class: "prim-sparkline",
    width: String(W),
    height: String(H),
    viewBox: "0 0 " + W + " " + H,
  }, children);
}

register("sparkline", projectSparkline);
