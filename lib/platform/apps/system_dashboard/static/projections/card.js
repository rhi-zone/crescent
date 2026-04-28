// projections/card.js
//
// Composite projection for
// `{type: "card", title?, subtitle?, body?: Primitive, footer?: Primitive}`.
// Renders <div class="prim-card"> with optional title/subtitle, a body slot
// recursing through `ctx.project`, and an optional footer slot also recursing.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectCard(value, ctx) {
  const children = [];
  if (value.title != null) {
    children.push(dom.div({ class: "card-title" }, [String(value.title)]));
  }
  if (value.subtitle != null) {
    children.push(dom.div({ class: "card-subtitle" }, [String(value.subtitle)]));
  }
  const bodyChildren = value.body ? [ctx.project(value.body)] : [];
  children.push(dom.div({ class: "card-body" }, bodyChildren));
  if (value.footer) {
    children.push(dom.div({ class: "card-footer" }, [ctx.project(value.footer)]));
  }
  return dom.div({ class: "prim-card" }, children);
}

register("card", projectCard);
