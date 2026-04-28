// projections/key_value.js
//
// Atomic projection for `{type: "key_value", pairs: [{key, value: Primitive}]}`.
// Renders <dl class="prim-kv"> with one <dt>/<dd> pair per entry. The <dd>
// recurses through the registry via `ctx.project(value)` so any primitive
// shape can appear as a value.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectKeyValue(value, ctx) {
  const pairs = value.pairs || [];
  const children = [];
  for (let i = 0; i < pairs.length; i++) {
    const k = pairs[i].key == null ? "" : String(pairs[i].key);
    children.push(dom.dt({}, [k]));
    children.push(dom.dd({}, [ctx.project(pairs[i].value)]));
  }
  return dom.dl({ class: "prim-kv" }, children);
}

register("key_value", projectKeyValue);
