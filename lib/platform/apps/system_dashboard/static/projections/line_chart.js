// projections/line_chart.js
//
// Time-series projection for
// `{type: "line_chart", series: [{name?, points: [{t, v}]}], unit?, y_min?, y_max?}`.
// Multi-series polyline. X axis from `t` values across all series, Y axis from
// `v` values (with optional y_min/y_max overrides). One color per series
// cycling through the 6-entry palette. Optional unit label top-right.

import { dom } from "../dom.js";
import { register } from "./registry.js";

const CHART_W = 240;
const CHART_H = 80;
const CHART_PAD = 4;

// duplicated from app.js renderXYChart palette; future shared module if duplication grows
const SERIES_COLORS = ["#80a8d0", "#80d080", "#ffd070", "#ff8080", "#c080d0", "#80d0c0"];

function seriesTExtent(series) {
  let min = Infinity;
  let max = -Infinity;
  for (let s = 0; s < series.length; s++) {
    const pts = series[s].points || [];
    for (let i = 0; i < pts.length; i++) {
      const t = pts[i].t;
      if (typeof t !== "number") continue;
      if (t < min) min = t;
      if (t > max) max = t;
    }
  }
  if (!isFinite(min) || !isFinite(max)) { min = 0; max = 1; }
  if (min === max) max = min + 1;
  return { min, max };
}

function seriesYExtent(series) {
  let min = Infinity;
  let max = -Infinity;
  for (let s = 0; s < series.length; s++) {
    const pts = series[s].points || [];
    for (let i = 0; i < pts.length; i++) {
      const v = pts[i].v;
      if (typeof v !== "number") continue;
      if (v < min) min = v;
      if (v > max) max = v;
    }
  }
  if (!isFinite(min) || !isFinite(max)) { min = 0; max = 1; }
  if (min === max) max = min + 1;
  return { min, max };
}

function projectLineChart(value, _ctx) {
  const series = value.series || [];
  const tExt = seriesTExtent(series);
  const yExt = seriesYExtent(series);
  if (typeof value.y_min === "number") yExt.min = value.y_min;
  if (typeof value.y_max === "number") yExt.max = value.y_max;
  if (yExt.min === yExt.max) yExt.max = yExt.min + 1;
  const w = CHART_W - CHART_PAD * 2;
  const h = CHART_H - CHART_PAD * 2;
  const xOf = (t) => CHART_PAD + ((t - tExt.min) / (tExt.max - tExt.min)) * w;
  const yOf = (v) => CHART_PAD + h - ((v - yExt.min) / (yExt.max - yExt.min)) * h;

  const children = [];
  for (let s = 0; s < series.length; s++) {
    const pts = series[s].points || [];
    if (!pts.length) continue;
    const coords = [];
    for (let i = 0; i < pts.length; i++) {
      coords.push(xOf(pts[i].t).toFixed(2) + "," + yOf(pts[i].v).toFixed(2));
    }
    const color = SERIES_COLORS[s % SERIES_COLORS.length];
    children.push(dom.polyline({
      points: coords.join(" "),
      fill: "none",
      stroke: color,
      "stroke-width": "1.2",
    }, []));
  }

  if (value.unit != null) {
    children.push(dom.text({
      x: String(CHART_W - CHART_PAD),
      y: String(CHART_PAD + 9),
      "text-anchor": "end",
      class: "chart-unit",
    }, [String(value.unit)]));
  }

  return dom.svg({
    class: "prim-chart",
    width: String(CHART_W),
    height: String(CHART_H),
    viewBox: "0 0 " + CHART_W + " " + CHART_H,
  }, children);
}

register("line_chart", projectLineChart);
