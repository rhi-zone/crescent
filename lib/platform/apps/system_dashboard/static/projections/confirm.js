// projections/confirm.js
//
// Action projection for `{type: "confirm", prompt, alias, args?, danger?}`.
// Renders <div class="prim-confirm"> (with `.danger` class when `value.danger`)
// containing the prompt text, a Confirm button that dispatches `value.alias`
// via `ctx.action`, and a Cancel button that clears the inline result slot.
// The dispatch result is re-projected into the slot using ctx.project, or
// rendered as an error on failure.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectConfirm(value, ctx) {
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
  const onConfirmClick = ctx.action
    ? ctx.action(value.alias, value.args, onResult)
    : (() => {});
  const onCancelClick = () => { slot.replaceChildren(); };

  const prompt = value.prompt == null ? "" : String(value.prompt);
  const confirmStyle = value.danger ? "danger" : "primary";
  const wrapClass = "prim-confirm" + (value.danger ? " danger" : "");
  return dom.div({ class: wrapClass }, [
    dom.div({ class: "confirm-prompt" }, [prompt]),
    dom.div({ class: "confirm-buttons" }, [
      dom.button(
        { class: "prim-btn style-" + confirmStyle, onClick: onConfirmClick },
        ["Confirm"],
      ),
      dom.button(
        { class: "prim-btn style-default", onClick: onCancelClick },
        ["Cancel"],
      ),
    ]),
    slot,
  ]);
}

register("confirm", projectConfirm);
