// projections/action_menu.js
//
// Action projection for `{type: "action_menu", items: [{label, alias, args?}, ...]}`.
// Renders <div class="prim-action-menu"> with one button per item plus a shared
// inline result slot. Clicking an item dispatches its alias via `ctx.action`;
// the response is re-projected into the shared slot (replacing any previous
// result), or rendered as an error on failure.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectActionMenu(value, ctx) {
  const slot = dom.div({ class: "btn-result" });
  const onResult = (env) => {
    slot.replaceChildren();
    if (!env || !env.ok) {
      const msg = (env && env.error != null) ? String(env.error) : "error";
      slot.appendChild(
        dom.div({ class: "prim-text style-error" }, [dom.pre({}, [msg])]),
      );
      return;
    }
    if (env.body != null) slot.appendChild(ctx.project(env.body));
  };

  const items = Array.isArray(value.items) ? value.items : [];
  const children = [];
  for (const item of items) {
    // ctx.action is provided by the host; if missing (legacy app.js path),
    // fall back to a no-op handler so the projection still mounts cleanly.
    const onClick = ctx.action
      ? ctx.action(item.alias, item.args, onResult)
      : (() => {});
    const label = item.label == null ? "" : String(item.label);
    children.push(
      dom.button({ class: "prim-btn style-default", onClick: onClick }, [label]),
    );
  }
  children.push(slot);
  return dom.div({ class: "prim-action-menu" }, children);
}

register("action_menu", projectActionMenu);
