// projections/area_chart.js
//
// Time-series projection for
// `{type: "area_chart", series: [{name?, points: [{t, v}]}], stacked?, unit?, y_min?, y_max?}`.
// Like line_chart but each series is filled to baseline. When `stacked=true`,
// series stack on top of one another using the union of all distinct t values.

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

function seriesYExtent(series, stacked) {
  let min = Infinity;
  let max = -Infinity;
  if (stacked) {
    const sums = {};
    for (let s = 0; s < series.length; s++) {
      const pts = series[s].points || [];
      for (let i = 0; i < pts.length; i++) {
        const key = String(pts[i].t);
        sums[key] = (sums[key] || 0) + (pts[i].v || 0);
      }
    }
    for (const k in sums) {
      if (Object.prototype.hasOwnProperty.call(sums, k)) {
        if (sums[k] < min) min = sums[k];
        if (sums[k] > max) max = sums[k];
      }
    }
  } else {
    for (let s = 0; s < series.length; s++) {
      const pts = series[s].points || [];
      for (let i = 0; i < pts.length; i++) {
        const v = pts[i].v;
        if (typeof v !== "number") continue;
        if (v < min) min = v;
        if (v > max) max = v;
      }
    }
  }
  if (!isFinite(min) || !isFinite(max)) { min = 0; max = 1; }
  if (min === max) max = min + 1;
  return { min, max };
}

function projectAreaChart(value, _ctx) {
  const series = value.series || [];
  const stacked = !!value.stacked;
  const tExt = seriesTExtent(series);
  const yExt = seriesYExtent(series, stacked);
  if (typeof value.y_min === "number") yExt.min = value.y_min;
  if (typeof value.y_max === "number") yExt.max = value.y_max;
  if (yExt.min === yExt.max) yExt.max = yExt.min + 1;
  const w = CHART_W - CHART_PAD * 2;
  const h = CHART_H - CHART_PAD * 2;
  const xOf = (t) => CHART_PAD + ((t - tExt.min) / (tExt.max - tExt.min)) * w;
  const yOf = (v) => CHART_PAD + h - ((v - yExt.min) / (yExt.max - yExt.min)) * h;

  const children = [];

  if (stacked) {
    const xKeys = {};
    for (let s = 0; s < series.length; s++) {
      const pts = series[s].points || [];
      for (let i = 0; i < pts.length; i++) xKeys[pts[i].t] = true;
    }
    const xs = [];
    for (const k in xKeys) {
      if (Object.prototype.hasOwnProperty.call(xKeys, k)) xs.push(parseFloat(k));
    }
    xs.sort((a, b) => a - b);
    let bottom = new Array(xs.length);
    for (let i = 0; i < xs.length; i++) bottom[i] = 0;
    for (let s = 0; s < series.length; s++) {
      const ptsBy = {};
      const pts = series[s].points || [];
      for (let i = 0; i < pts.length; i++) ptsBy[pts[i].t] = pts[i].v;
      const top = new Array(xs.length);
      for (let i = 0; i < xs.length; i++) {
        const v = ptsBy[xs[i]];
        top[i] = bottom[i] + (typeof v === "number" ? v : 0);
      }
      const polyPts = [];
      for (let i = 0; i < xs.length; i++) {
        polyPts.push(xOf(xs[i]).toFixed(2) + "," + yOf(top[i]).toFixed(2));
      }
      for (let i = xs.length - 1; i >= 0; i--) {
        polyPts.push(xOf(xs[i]).toFixed(2) + "," + yOf(bottom[i]).toFixed(2));
      }
      const color = SERIES_COLORS[s % SERIES_COLORS.length];
      children.push(dom.polygon({
        points: polyPts.join(" "),
        fill: color,
        "fill-opacity": "0.5",
        stroke: color,
        "stroke-width": "1",
      }, []));
      bottom = top;
    }
  } else {
    for (let s = 0; s < series.length; s++) {
      const pts = series[s].points || [];
      if (!pts.length) continue;
      const coords = [];
      for (let i = 0; i < pts.length; i++) {
        coords.push(xOf(pts[i].t).toFixed(2) + "," + yOf(pts[i].v).toFixed(2));
      }
      const color = SERIES_COLORS[s % SERIES_COLORS.length];
      const areaPts = coords.slice();
      areaPts.push(xOf(pts[pts.length - 1].t).toFixed(2) + "," + (CHART_PAD + h));
      areaPts.push(xOf(pts[0].t).toFixed(2) + "," + (CHART_PAD + h));
      children.push(dom.polygon({
        points: areaPts.join(" "),
        fill: color,
        "fill-opacity": "0.3",
        stroke: "none",
      }, []));
      children.push(dom.polyline({
        points: coords.join(" "),
        fill: "none",
        stroke: color,
        "stroke-width": "1.2",
      }, []));
    }
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

register("area_chart", projectAreaChart);
