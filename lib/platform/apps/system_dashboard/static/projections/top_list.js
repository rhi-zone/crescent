// projections/top_list.js
//
// Time-series projection for
// `{type: "top_list", items: [{label, value, unit?}], max?}`.
// Renders <ul class="prim-toplist"> with one <li> per item: a label span, a
// fill-bar track whose width = value / (max || max-of-values) * 100%, and a
// trailing value+unit span.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectTopList(value, _ctx) {
  const items = value.items || [];
  let maxV = typeof value.max === "number" ? value.max : 0;
  if (!maxV) {
    for (let i = 0; i < items.length; i++) {
      const v = typeof items[i].value === "number" ? items[i].value : 0;
      if (v > maxV) maxV = v;
    }
  }
  if (maxV <= 0) maxV = 1;

  const lis = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const label = item.label == null ? "" : String(item.label);
    const vNum = typeof item.value === "number" ? item.value : 0;
    let pct = (vNum / maxV) * 100;
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    const valueText = String(vNum) + (item.unit != null ? String(item.unit) : "");
    lis.push(dom.li({}, [
      dom.span({ class: "toplist-label" }, [label]),
      dom.span({ class: "toplist-track" }, [
        dom.span({ class: "toplist-fill", style: { width: pct + "%" } }, []),
      ]),
      dom.span({ class: "toplist-value" }, [valueText]),
    ]));
  }

  return dom.ul({ class: "prim-toplist" }, lis);
}

register("top_list", projectTopList);
