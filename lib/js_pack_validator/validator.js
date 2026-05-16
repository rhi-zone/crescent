// lib/js_pack_validator/validator.js
//
// Author-side hygiene validator for pack JS. Parses input with acorn,
// walks the AST, and rejects forms outside the pack-JS subset documented
// in docs/platform_isolation.md §3 "Pack JS subset (draft)".
//
// This is an AUTHOR-SIDE TOOL. It runs in a pack author's dev/CI
// environment via bun. It is NOT a daemon-side dependency: the runtime
// boundary is lib/js_realm_sandbox/ (see §3 "Pack-source validation").
//
// Usage:
//
//   import { validate } from "./validator.js";
//   const r = validate(packSource, { filename: "pack.js" });
//   if (!r.ok) for (const e of r.errors) console.error(e);
//
// API: see the JSDoc on `validate` below.
//
// Acorn is vendored at dep/acorn/acorn.mjs (single-file ESM build,
// pinned via dep/acorn/VERSION).

import * as acorn from "../../dep/acorn/acorn.mjs";
import { validatePattern } from "../js_safe_regex/safe_regex.js";

// =====================================================================
// Banned identifier references.
//
// docs/platform_isolation.md §3 "Pack JS subset (draft)" — "Identifier
// nodes resolving to banned globals (eval, Function, AsyncFunction,
// etc.) in *any* context — the validator walks identifier references
// and rejects."
//
// Policy decision: any identifier matching the banned-names list is
// rejected REGARDLESS of binding. `function eval() {}` is rejected
// even though the local would shadow the global, because (a) it is
// universally a code smell, (b) tracking bindings precisely requires
// scope analysis far heavier than the validator's other rules, and
// (c) the runtime sandbox already removes the globals — rejecting the
// identifier here is purely author hygiene against confusing names.
// =====================================================================

const BANNED_GLOBALS = new Set([
  "eval",
  "Function",
  "AsyncFunction",
  "GeneratorFunction",
  "AsyncGeneratorFunction",
  "Reflect",
  "Proxy",
  "WeakRef",
  "FinalizationRegistry",
  "SharedArrayBuffer",
  // `import` as an identifier (e.g. used as a free reference) — the
  // ImportDeclaration / ImportExpression nodes are checked separately;
  // a bare Identifier named "import" should not occur in valid source
  // but reject it for completeness.
  "import",
]);

// =====================================================================
// Whitelisted constructor identifiers for `new` expressions.
//
// docs/platform_isolation.md §3 "Restricted forms" — `new SomeName(...)`
// where SomeName is not in this set is rejected. Pack-side function
// names declared in the same module are added dynamically (see
// walk_collect_local_constructables).
// =====================================================================

const ALLOWED_NEW_CONSTRUCTORS = new Set([
  "Array",
  "Object",
  "String",
  "Number",
  "Boolean",
  "Map",
  "Set",
  "WeakMap",
  "WeakSet",
  "Date",
  "Promise",
  "RegExp",
  "Error",
  "TypeError",
  "RangeError",
  "SyntaxError",
  "ReferenceError",
  "URIError",
  "EvalError",
  "AggregateError",
  "ArrayBuffer",
  "DataView",
  "Uint8Array",
  "Int8Array",
  "Uint16Array",
  "Int16Array",
  "Uint32Array",
  "Int32Array",
  "Float32Array",
  "Float64Array",
  "BigInt64Array",
  "BigUint64Array",
  "Uint8ClampedArray",
]);

// =====================================================================
// AST node-type rejection rules.
//
// Each entry: predicate (node) -> string|null; non-null means reject
// with that message.
// =====================================================================

/**
 * @typedef {{ message: string, line: number, column: number, nodeType: string }} ValidationError
 * @typedef {{ ok: true } | { ok: false, errors: ValidationError[] }} ValidationResult
 */

/**
 * Collect locally-declared function names from the top-level module
 * scope. These names are treated as additional allowed `new` targets:
 * the spec permits `new <pack-side function>(...)` because such a
 * function was authored in the same module and is the pack author's
 * own responsibility.
 *
 * We do NOT track nested scopes: a function declared inside another
 * function will still be allowed as a `new` target because we walk all
 * function declarations regardless of nesting. This over-approximates
 * the spec slightly in the author's favour; full scope analysis is
 * heavier than the rule warrants for hygiene.
 *
 * @param {object} ast
 * @returns {Set<string>}
 */
function collect_local_constructables(ast) {
  const names = new Set();
  walk(ast, (node) => {
    if (!node || typeof node.type !== "string") return;
    if (node.type === "FunctionDeclaration" && node.id && node.id.name) {
      names.add(node.id.name);
    }
    // `const X = function() {}` / `const X = (...) => ...` — treat
    // top-level VariableDeclarators initialised with a function as
    // constructable names. This intentionally matches both arrow and
    // function-expression forms; arrows are not actually constructable
    // at runtime, but the author's intent is "I have a name X in my
    // module, treat it as my responsibility."
    if (node.type === "VariableDeclarator" &&
        node.id && node.id.type === "Identifier" &&
        node.init && (
          node.init.type === "FunctionExpression" ||
          node.init.type === "ArrowFunctionExpression"
        )) {
      names.add(node.id.name);
    }
  });
  return names;
}

/**
 * Generic AST walker. Visits every node reachable from `root` and
 * invokes `visit(node, parent, key)` for each. Does not depend on
 * acorn-walk so we keep the surface to vendored acorn only.
 *
 * @param {*} root
 * @param {(node: object, parent: object|null, key: string|null) => void} visit
 */
function walk(root, visit) {
  function rec(node, parent, key) {
    if (!node || typeof node !== "object") return;
    if (typeof node.type === "string") {
      visit(node, parent, key);
    }
    for (const k of Object.keys(node)) {
      if (k === "loc" || k === "start" || k === "end" || k === "range") continue;
      const v = node[k];
      if (Array.isArray(v)) {
        for (let i = 0; i < v.length; i++) rec(v[i], node, k);
      } else if (v && typeof v === "object" && typeof v.type === "string") {
        rec(v, node, k);
      }
    }
  }
  rec(root, null, null);
}

/**
 * Build a ValidationError from a node and message.
 * @param {object} node
 * @param {string} message
 * @returns {ValidationError}
 */
function mkErr(node, message) {
  const loc = node && node.loc && node.loc.start;
  return {
    message: message,
    line: loc ? loc.line : 0,
    column: loc ? loc.column : 0,
    nodeType: (node && node.type) || "<unknown>",
  };
}

/**
 * Walk the AST and accumulate errors against the pack-JS subset.
 *
 * @param {object} ast
 * @param {Set<string>} localConstructables
 * @param {Set<string>} allowedConstructors
 * @param {ValidationError[]} errors
 */
function check(ast, localConstructables, allowedConstructors, errors) {
  // Track the parent chain for context-dependent checks (e.g. an
  // Identifier nested in MemberExpression as `.property` is not a
  // banned-global reference even if its name matches).
  const stack = [];

  function isPropertyName(node, parent) {
    if (!parent) return false;
    if (parent.type === "MemberExpression" && parent.property === node && !parent.computed) {
      return true;
    }
    if (parent.type === "Property" && parent.key === node && !parent.computed) {
      return true;
    }
    if (parent.type === "MethodDefinition" && parent.key === node && !parent.computed) {
      return true;
    }
    // Identifiers used as labels, imported/exported names: skip.
    if (parent.type === "LabeledStatement" && parent.label === node) return true;
    if (parent.type === "BreakStatement" && parent.label === node) return true;
    if (parent.type === "ContinueStatement" && parent.label === node) return true;
    if (parent.type === "ImportSpecifier" && parent.imported === node) return true;
    if (parent.type === "ExportSpecifier" &&
        (parent.exported === node || parent.local === node)) {
      return true;
    }
    return false;
  }

  function rec(node, parent, key) {
    if (!node || typeof node !== "object" || typeof node.type !== "string") return;
    stack.push(node);

    switch (node.type) {
      case "ClassDeclaration":
      case "ClassExpression":
        errors.push(mkErr(node, "class syntax is banned in pack JS (use plain functions)"));
        break;
      case "WithStatement":
        errors.push(mkErr(node, "`with` statement is banned in pack JS"));
        break;
      case "TaggedTemplateExpression":
        errors.push(mkErr(node, "tagged template literals are banned in pack JS"));
        break;
      case "ImportExpression":
        errors.push(mkErr(node, "dynamic `import()` is banned in pack JS (use static import)"));
        break;
      case "MetaProperty":
        // import.meta and new.target. import.meta is explicitly banned;
        // new.target inside a banned class doesn't matter, but reject
        // generically as "meta-property X.Y not allowed" — pack subset
        // calls out import.meta specifically.
        {
          const ma = node.meta && node.meta.name;
          const mp = node.property && node.property.name;
          errors.push(mkErr(node,
            "meta-property `" + (ma || "?") + "." + (mp || "?") + "` is banned in pack JS"));
        }
        break;
      case "FunctionDeclaration":
      case "FunctionExpression":
        if (node.generator) {
          errors.push(mkErr(node, "generator functions (`function*`) are banned in pack JS"));
        }
        break;
      case "ArrowFunctionExpression":
        // Arrow functions cannot be generators per the spec; nothing to
        // check beyond standard walking.
        break;
      case "YieldExpression":
        errors.push(mkErr(node, "`yield` (generator syntax) is banned in pack JS"));
        break;
      case "MemberExpression":
        if (node.computed) {
          const p = node.property;
          // Allow only Literal whose value is a string or number.
          const isStringLit = p && p.type === "Literal" &&
            (typeof p.value === "string" || typeof p.value === "number");
          if (!isStringLit) {
            errors.push(mkErr(node,
              "dynamic bracket member access (`obj[expr]` where `expr` is " +
              "not a literal string/number) is banned in pack JS"));
          }
        }
        break;
      case "NewExpression": {
        const callee = node.callee;
        if (!callee || callee.type !== "Identifier") {
          errors.push(mkErr(node,
            "`new` target must be a plain identifier; `new <expression>` " +
            "is banned in pack JS"));
        } else {
          const name = callee.name;
          if (!ALLOWED_NEW_CONSTRUCTORS.has(name) &&
              !localConstructables.has(name) &&
              !allowedConstructors.has(name)) {
            errors.push(mkErr(node,
              "`new " + name + "(...)` is banned: `" + name +
              "` is not on the constructor allow-list and is not a " +
              "pack-local function"));
          }
        }
        break;
      }
      case "Literal":
        if (node.regex && typeof node.regex.pattern === "string") {
          const v = validatePattern(node.regex.pattern);
          if (!v.ok) {
            errors.push(mkErr(node,
              "regex literal /" + node.regex.pattern + "/ rejected: " + v.error));
          }
        }
        break;
      case "Identifier":
        if (!isPropertyName(node, parent) && BANNED_GLOBALS.has(node.name)) {
          errors.push(mkErr(node,
            "reference to banned identifier `" + node.name +
            "` (any identifier of this name is rejected, regardless of binding)"));
        }
        break;
      default:
        break;
    }

    // Recurse.
    for (const k of Object.keys(node)) {
      if (k === "loc" || k === "start" || k === "end" || k === "range") continue;
      const v = node[k];
      if (Array.isArray(v)) {
        for (let i = 0; i < v.length; i++) rec(v[i], node, k);
      } else if (v && typeof v === "object" && typeof v.type === "string") {
        rec(v, node, k);
      }
    }

    stack.pop();
  }

  rec(ast, null, null);
}

/**
 * Validate pack JS against the pack-JS subset.
 *
 * @param {string} source - pack JS source
 * @param {{ filename?: string, allowedConstructors?: string[] }} [opts]
 * @returns {ValidationResult}
 */
export function validate(source, opts) {
  const o = opts || {};
  const extraCtors = new Set(Array.isArray(o.allowedConstructors)
    ? o.allowedConstructors : []);

  /** @type {ValidationError[]} */
  const errors = [];

  let ast;
  try {
    ast = acorn.parse(source, {
      ecmaVersion: 2022,
      sourceType: "module",
      locations: true,
      allowAwaitOutsideFunction: true,
    });
  } catch (e) {
    const line = (e && typeof e.loc === "object" && e.loc) ? e.loc.line : 0;
    const column = (e && typeof e.loc === "object" && e.loc) ? e.loc.column : 0;
    return {
      ok: false,
      errors: [{
        message: "parse error: " + ((e && e.message) || String(e)),
        line: line,
        column: column,
        nodeType: "<parse>",
      }],
    };
  }

  const localCtors = collect_local_constructables(ast);
  check(ast, localCtors, extraCtors, errors);

  if (errors.length === 0) return { ok: true };
  return { ok: false, errors: errors };
}
