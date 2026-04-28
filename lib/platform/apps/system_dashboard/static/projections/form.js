// projections/form.js
//
// Stub projection for `{type: "form", fields?, submit_label?, submit_alias?, ...}`.
//
// TODO: real form rendering needs field-type widgets, validation, and submit
// semantics tied through ctx.action. The renderer stub keeps this primitive
// out of the unknown-type fallback while the design is sorted. Mirrors the
// legacy app.js placeholder, plus a field-summary <ul> so authors can see
// the declared schema in the meantime.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectForm(value, _ctx) {
  const lbl = value.submit_label != null
    ? String(value.submit_label)
    : (value.submit_alias != null ? String(value.submit_alias) : "");
  const children = [
    dom.div({}, ["Form: " + lbl + " (renderer TODO)"]),
  ];
  const fields = Array.isArray(value.fields) ? value.fields : [];
  if (fields.length > 0) {
    const items = [];
    for (const f of fields) {
      const name = f && f.name != null ? String(f.name) : "";
      const flabel = f && f.label != null ? String(f.label) : name;
      const ftype = f && f.type != null ? String(f.type) : "string";
      items.push(dom.li({}, [flabel + " (" + name + ": " + ftype + ")"]));
    }
    children.push(dom.ul({}, items));
  }
  return dom.div({ class: "prim-form-placeholder" }, children);
}

register("form", projectForm);
