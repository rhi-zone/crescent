// projections/tabs.js
//
// Composite projection for
// `{type: "tabs", tabs: [{label, body: Primitive}]}`.
// Renders <div class="prim-tabs"> with a header strip of buttons and a body
// slot. Clicking a tab swaps the body element's children to the projection
// of that tab's body and toggles the `.active` class on the buttons.
//
// Internal mutability after initial render is intentional and accepted:
// projections own the DOM they create, so mutating elements this projection
// itself constructed (the body slot and the button list) is allowed.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectTabs(value, ctx) {
  const tabs = value.tabs || [];
  const headerChildren = [];
  const bodyEl = dom.div({ class: "tabs-body" }, []);
  const tabBtns = [];

  function showTab(idx) {
    const tab = tabs[idx];
    const node = tab && tab.body ? ctx.project(tab.body) : null;
    if (node) bodyEl.replaceChildren(node);
    else bodyEl.replaceChildren();
    for (let bi = 0; bi < tabBtns.length; bi++) {
      tabBtns[bi].classList.toggle("active", bi === idx);
    }
  }

  for (let i = 0; i < tabs.length; i++) {
    const idx = i;
    const label = tabs[i].label == null ? "" : String(tabs[i].label);
    const btn = dom.button(
      { class: "tab-btn", onClick: function () { showTab(idx); } },
      [label],
    );
    tabBtns.push(btn);
    headerChildren.push(btn);
  }

  const root = dom.div({ class: "prim-tabs" }, [
    dom.div({ class: "tabs-header" }, headerChildren),
    bodyEl,
  ]);
  if (tabs.length) showTab(0);
  return root;
}

register("tabs", projectTabs);
