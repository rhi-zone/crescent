// projections/tree.js
//
// Hierarchical projection for `{type: "tree", root: TreeNode}`.
// TreeNode = `{label, children?: TreeNode[], value?, icon?}` — note tree
// nodes are NOT primitives (no `type` field) so we recurse via the private
// `renderTreeNode` helper, NOT via `ctx.project`.
//
// Leaf nodes (no children) render <div class="tree-leaf">. Branch nodes
// render <details>/<summary>; the root branch is open by default.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function renderTreeNode(node, isRoot) {
  if (!node || typeof node !== "object") {
    return dom.div({ class: "tree-leaf" }, [String(node)]);
  }
  const label = node.label == null ? "" : String(node.label);
  const children = node.children;
  if (!children || !children.length) {
    let leafText = label;
    if (node.value !== undefined && node.value !== null) {
      leafText += ": " + String(node.value);
    }
    const kids = [];
    if (node.icon != null) {
      kids.push(dom.span({ class: "tree-icon" }, [String(node.icon) + " "]));
    }
    kids.push(leafText);
    return dom.div({ class: "tree-leaf" }, kids);
  }
  const sumKids = [];
  if (node.icon != null) {
    sumKids.push(dom.span({ class: "tree-icon" }, [String(node.icon) + " "]));
  }
  sumKids.push(label);
  const detKids = [dom.summary({}, sumKids)];
  for (let i = 0; i < children.length; i++) {
    detKids.push(renderTreeNode(children[i], false));
  }
  const props = isRoot ? { open: true } : {};
  return dom.details(props, detKids);
}

function projectTree(value, _ctx) {
  const kids = value.root ? [renderTreeNode(value.root, true)] : [];
  return dom.div({ class: "prim-tree" }, kids);
}

register("tree", projectTree);
