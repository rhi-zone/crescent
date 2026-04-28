// projections/list.js
//
// Atomic projection for
// `{type: "list", items: [{title, subtitle?, icon?, trailing?, action?}]}`.
// Renders <ul class="prim-list"> with one <li> per item. Each <li> contains
// a `list-title` div and optional `list-subtitle` div + `list-trailing` span.
// TODO render `icon` and wire `action` aliases once action dispatch is plumbed
// (mirrors the legacy renderPrimitive TODO).

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectList(value, _ctx) {
  const items = value.items || [];
  const lis = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    const children = [];
    const title = item.title == null ? "" : String(item.title);
    children.push(dom.div({ class: "list-title" }, [title]));
    if (item.subtitle != null) {
      children.push(dom.div({ class: "list-subtitle" }, [String(item.subtitle)]));
    }
    if (item.trailing != null) {
      children.push(dom.span({ class: "list-trailing" }, [String(item.trailing)]));
    }
    lis.push(dom.li({}, children));
  }
  return dom.ul({ class: "prim-list" }, lis);
}

register("list", projectList);
