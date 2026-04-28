// projections/diff.js
//
// Hierarchical projection for `{type: "diff", before?: string, after?: string}`.
// Naive line-by-line zip: equal lines render as `diff-eq`, mismatches render as
// a `diff-del` line followed by a `diff-add` line. Output is a single
// <pre class="prim-diff"> with one <span> per line.
//
// TODO: a real LCS would produce minimal diffs. v1 is a deliberate stand-in
// — the legacy renderPrimitive carried the same TODO and the renderer's
// behavior is preserved exactly here.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectDiff(value, _ctx) {
  const beforeS = value.before == null ? "" : String(value.before);
  const afterS  = value.after  == null ? "" : String(value.after);
  const bl = beforeS.split("\n");
  const al = afterS.split("\n");
  const n = Math.max(bl.length, al.length);
  const lines = [];
  for (let i = 0; i < n; i++) {
    const b = i < bl.length ? bl[i] : null;
    const a = i < al.length ? al[i] : null;
    if (b !== null && a !== null && b === a) {
      lines.push(dom.span({ class: "diff-eq" }, ["  " + b + "\n"]));
    } else {
      if (b !== null) {
        lines.push(dom.span({ class: "diff-del" }, ["- " + b + "\n"]));
      }
      if (a !== null) {
        lines.push(dom.span({ class: "diff-add" }, ["+ " + a + "\n"]));
      }
    }
  }
  return dom.pre({ class: "prim-diff" }, lines);
}

register("diff", projectDiff);
