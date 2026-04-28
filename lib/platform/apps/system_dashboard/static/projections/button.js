// projections/button.js
//
// Action projection for `{type: "button", label, alias, args?, style?, confirm?}`.
// Renders <div class="prim-button-wrap"> containing a <button class="prim-btn
// style-${style||'default'}"> and an inline result slot. Clicking dispatches
// `value.alias` via `ctx.action`; the response envelope is re-projected into
// the slot, or rendered as an error message on failure.
//
// `value.confirm` is metadata the projection does NOT act on. The host
// (`ctx.action`) decides whether a confirmation modal interposes the
// dispatch by inspecting cap declarations or the alias's `confirm` hint.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectButton(value, ctx) {
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
  // ctx.action is provided by the host; if missing (legacy app.js path),
  // fall back to a no-op handler so the projection still mounts cleanly.
  const onClick = ctx.action
    ? ctx.action(value.alias, value.args, onResult)
    : (() => {});
  const label = value.label == null ? "" : String(value.label);
  const style = value.style == null ? "default" : String(value.style);
  return dom.div({ class: "prim-button-wrap" }, [
    dom.button({ class: "prim-btn style-" + style, onClick: onClick }, [label]),
    slot,
  ]);
}

register("button", projectButton);
