// projections/panel.js
//
// Composite projection for
// `{type: "panel", title?, body?: Primitive, actions?: alias_id[]}`.
// Renders <div class="prim-panel"> with title, body (recurses via
// `ctx.project`), and optional action button row. Each action is an alias id;
// clicking should dispatch via `ctx.action(alias_id)`.
//
// TODO ctx.action wiring: `ctx` does not yet expose `action`. The button below
// uses `ctx.action(alias_id)` when present and falls back to a no-op handler
// otherwise — the future app.js refactor that owns dispatch will plumb
// `ctx.action` through and the buttons will activate without further changes
// here. Do NOT replicate `executeAlias` inline; dispatch belongs in the host.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function renderActionButton(aliasId, ctx) {
  const handler = ctx.action ? ctx.action(aliasId) : function () {};
  return dom.button(
    { class: "prim-btn style-default", onClick: handler },
    [String(aliasId)],
  );
}

function projectPanel(value, ctx) {
  const children = [];
  const titleText = value.title == null ? "" : String(value.title);
  children.push(dom.div({ class: "panel-title" }, [titleText]));
  const bodyChildren = value.body ? [ctx.project(value.body)] : [];
  children.push(dom.div({ class: "panel-body" }, bodyChildren));
  if (value.actions && value.actions.length) {
    const actEls = [];
    for (let i = 0; i < value.actions.length; i++) {
      actEls.push(renderActionButton(value.actions[i], ctx));
    }
    children.push(dom.div({ class: "panel-actions" }, actEls));
  }
  return dom.div({ class: "prim-panel" }, children);
}

register("panel", projectPanel);
