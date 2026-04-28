// projections/bar_chart.js
//
// Time-series projection for
// `{type: "bar_chart", series: [{name?, points: [{t, v}]}], stacked?, unit?}`.
// Vertical bars. When `stacked=true`, series stack per category; otherwise
// they sit side-by-side per category. Categories = union of distinct `t`
// values across all series, sorted numerically when parseable, else lexically.

import { dom } from "../dom.js";
import { register } from "./registry.js";

const CHART_W = 240;
const CHART_H = 80;
const CHART_PAD = 4;

// duplicated from app.js renderBarChart palette; future shared module if duplication grows
const SERIES_COLORS = ["#80a8d0", "#80d080", "#ffd070", "#ff8080", "#c080d0", "#80d0c0"];

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

function projectBarChart(value, _ctx) {
  const series = value.series || [];
  const stacked = !!value.stacked;

  const tSet = {};
  for (let s = 0; s < series.length; s++) {
    const pts = series[s].points || [];
    for (let i = 0; i < pts.length; i++) tSet[pts[i].t] = true;
  }
  const tKeys = [];
  for (const k in tSet) {
    if (Object.prototype.hasOwnProperty.call(tSet, k)) tKeys.push(k);
  }
  tKeys.sort((a, b) => {
    const na = parseFloat(a);
    const nb = parseFloat(b);
    if (!isNaN(na) && !isNaN(nb)) return na - nb;
    return a < b ? -1 : a > b ? 1 : 0;
  });

  const yExt = seriesYExtent(series, stacked);
  if (yExt.min > 0) yExt.min = 0;
  const w = CHART_W - CHART_PAD * 2;
  const h = CHART_H - CHART_PAD * 2;
  const nCats = tKeys.length || 1;
  const slot = w / nCats;
  const yOf = (v) => CHART_PAD + h - ((v - yExt.min) / (yExt.max - yExt.min)) * h;

  const children = [];

  if (stacked) {
    for (let ci = 0; ci < tKeys.length; ci++) {
      const x0 = CHART_PAD + slot * ci + slot * 0.1;
      const bw = slot * 0.8;
      let stack = 0;
      for (let s = 0; s < series.length; s++) {
        const pts = series[s].points || [];
        let v = 0;
        for (let i = 0; i < pts.length; i++) {
          if (String(pts[i].t) === tKeys[ci]) { v = pts[i].v || 0; break; }
        }
        const yTop = yOf(stack + v);
        const yBot = yOf(stack);
        children.push(dom.rect({
          x: x0.toFixed(2),
          y: yTop.toFixed(2),
          width: bw.toFixed(2),
          height: Math.max(0, yBot - yTop).toFixed(2),
          fill: SERIES_COLORS[s % SERIES_COLORS.length],
        }, []));
        stack += v;
      }
    }
  } else {
    const nSer = series.length || 1;
    for (let ci = 0; ci < tKeys.length; ci++) {
      const groupX = CHART_PAD + slot * ci + slot * 0.1;
      const groupW = slot * 0.8;
      const bw = groupW / nSer;
      for (let s = 0; s < series.length; s++) {
        const pts = series[s].points || [];
        let v = 0;
        for (let i = 0; i < pts.length; i++) {
          if (String(pts[i].t) === tKeys[ci]) { v = pts[i].v || 0; break; }
        }
        const yT = yOf(v);
        const yB = yOf(0);
        children.push(dom.rect({
          x: (groupX + bw * s).toFixed(2),
          y: Math.min(yT, yB).toFixed(2),
          width: bw.toFixed(2),
          height: Math.abs(yB - yT).toFixed(2),
          fill: SERIES_COLORS[s % SERIES_COLORS.length],
        }, []));
      }
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

register("bar_chart", projectBarChart);
