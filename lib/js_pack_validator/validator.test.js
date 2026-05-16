// lib/js_pack_validator/validator.test.js
//
// Self-tests for validator.js. To run:
//
//   bun lib/js_pack_validator/validator.test.js
//
// Each test case is either an `accept` (source must validate clean) or
// a `reject` (source must produce at least one error containing the
// given needle). The corpus mirrors docs/platform_isolation.md §3
// "Pack JS subset (draft)" rule-for-rule; parity_test.lua asserts that
// each documented rule has a corresponding test entry by hand-curated
// needle.

import { validate } from "./validator.js";

/**
 * @typedef {{ kind: "accept", name: string, src: string }
 *          | { kind: "reject", name: string, src: string, needle: string, rule: string }} Case
 */

/** @type {Case[]} */
const CASES = [
  // --------------------------------------------------------------- accept
  {
    kind: "accept",
    name: "function declaration with return",
    src: "function f(x) { return x + 1; }",
  },
  {
    kind: "accept",
    name: "async function declaration",
    src: "async function g(x) { return await x; }",
  },
  {
    kind: "accept",
    name: "arrow function",
    src: "const f = (x) => x * 2;",
  },
  {
    kind: "accept",
    name: "control flow",
    src: "function f(xs) {\n" +
      "  let s = 0;\n" +
      "  for (const x of xs) {\n" +
      "    if (x > 0) { s += x; } else { continue; }\n" +
      "  }\n" +
      "  try { return s; } catch (e) { throw e; }\n" +
      "}",
  },
  {
    kind: "accept",
    name: "object and array literals",
    src: "const o = { a: 1, b: [2, 3], c: { d: 'x' } };",
  },
  {
    kind: "accept",
    name: "destructuring",
    src: "function f({ a, b: [c, d] }) { return a + c + d; }",
  },
  {
    kind: "accept",
    name: "template literal (untagged)",
    src: "const s = `hello ${name}!`;",
  },
  {
    kind: "accept",
    name: "safe regex literal",
    src: "const r = /a+b/;",
  },
  {
    kind: "accept",
    name: "switch / break",
    src: "function f(x) {\n" +
      "  switch (x) { case 1: return 'a'; default: break; }\n" +
      "  return 'b';\n" +
      "}",
  },
  {
    kind: "accept",
    name: "static import / export",
    src: "import { x } from './m.js';\nexport const y = x;",
  },
  {
    kind: "accept",
    name: "allowed constructors via new",
    src: "const a = new Array(3);\n" +
      "const m = new Map();\n" +
      "const s = new Set();\n" +
      "const d = new Date();\n" +
      "const p = new Promise((r) => r(1));\n" +
      "const re = new RegExp('a+');\n" +
      "const e = new Error('x');\n" +
      "const u = new Uint8Array(8);\n",
  },
  {
    kind: "accept",
    name: "new on pack-local function",
    src: "function Vec(x, y) { this.x = x; this.y = y; }\n" +
      "const v = new Vec(1, 2);",
  },
  {
    kind: "accept",
    name: "literal bracket access",
    src: "const v = obj['name'];\nconst w = arr[0];",
  },
  {
    kind: "accept",
    name: "optional chaining and nullish",
    src: "const v = obj?.foo ?? 'default';",
  },
  {
    kind: "accept",
    name: "spread in call and literal",
    src: "function f(...xs) { return [0, ...xs]; }",
  },
  {
    kind: "accept",
    name: "identifier whose name is benign (no globals to reject)",
    src: "function f() { const x = 1; return x; }",
  },

  // --------------------------------------------------------------- reject
  {
    kind: "reject",
    rule: "ClassDeclaration",
    name: "class declaration",
    src: "class Foo { m() { return 1; } }",
    needle: "class",
  },
  {
    kind: "reject",
    rule: "ClassExpression",
    name: "class expression with extends",
    src: "const X = class extends Y { };",
    needle: "class",
  },
  {
    kind: "reject",
    rule: "WithStatement",
    name: "with statement",
    // `with` is a syntax error in strict / module mode. Acorn parses
    // it under sourceType:"script" only. To trigger the WithStatement
    // walker rule we hand-write Script-mode? validator.js uses
    // sourceType:"module" which forces strict, so `with` will fail at
    // parse. Accept the parse error as the rejection signal — the
    // needle "with" matches the parser's "with in strict mode" error
    // text. This satisfies the spec: `with` is rejected.
    src: "with (o) { x = 1; }",
    needle: "with",
  },
  {
    kind: "reject",
    rule: "generator function",
    name: "generator function declaration",
    src: "function* gen() { yield 1; }",
    needle: "generator",
  },
  {
    kind: "reject",
    rule: "async generator function",
    name: "async generator function",
    src: "async function* ag() { yield 1; }",
    needle: "generator",
  },
  {
    kind: "reject",
    rule: "TaggedTemplateExpression",
    name: "tagged template literal",
    src: "const v = tag`hello ${x}`;",
    needle: "tagged template",
  },
  {
    kind: "reject",
    rule: "ImportExpression",
    name: "dynamic import",
    src: "const m = import('./mod.js');",
    needle: "dynamic `import()`",
  },
  {
    kind: "reject",
    rule: "MetaProperty import.meta",
    name: "import.meta",
    src: "const u = import.meta.url;",
    needle: "import.meta",
  },
  {
    kind: "reject",
    rule: "computed MemberExpression non-literal",
    name: "dynamic bracket access",
    src: "function f(o, k) { return o[k]; }",
    needle: "dynamic bracket",
  },
  {
    kind: "reject",
    rule: "banned identifier: eval",
    name: "eval call",
    src: "function f(s) { return eval(s); }",
    needle: "eval",
  },
  {
    kind: "reject",
    rule: "banned identifier: Function",
    name: "Function constructor via new",
    src: "const f = new Function('return 1');",
    needle: "Function",
  },
  {
    kind: "reject",
    rule: "banned identifier: Reflect",
    name: "Reflect reference",
    src: "function f(o) { return Reflect.get(o, 'x'); }",
    needle: "Reflect",
  },
  {
    kind: "reject",
    rule: "banned identifier: Proxy",
    name: "Proxy reference",
    src: "function f(t, h) { return new Proxy(t, h); }",
    needle: "Proxy",
  },
  {
    kind: "reject",
    rule: "banned identifier: WeakRef",
    name: "WeakRef reference",
    src: "function f(o) { return new WeakRef(o); }",
    needle: "WeakRef",
  },
  {
    kind: "reject",
    rule: "banned identifier: FinalizationRegistry",
    name: "FinalizationRegistry",
    src: "const fr = new FinalizationRegistry(() => {});",
    needle: "FinalizationRegistry",
  },
  {
    kind: "reject",
    rule: "banned identifier: SharedArrayBuffer",
    name: "SharedArrayBuffer",
    src: "const b = new SharedArrayBuffer(16);",
    needle: "SharedArrayBuffer",
  },
  {
    kind: "reject",
    rule: "banned identifier: shadowing (function eval)",
    name: "redeclared eval is still rejected (cleanest policy)",
    src: "function eval() { return 1; }",
    needle: "eval",
  },
  {
    kind: "reject",
    rule: "non-whitelisted constructor in new",
    name: "new against unknown constructor",
    src: "const x = new SomeRandomThing(1);",
    needle: "SomeRandomThing",
  },
  {
    kind: "reject",
    rule: "new on expression callee",
    name: "new on member expression",
    src: "const x = new lib.Thing();",
    needle: "must be a plain identifier",
  },
  {
    kind: "reject",
    rule: "regex literal catastrophic",
    name: "regex literal with nested quantifier",
    src: "const r = /(a+)+b/;",
    needle: "nested quantifier",
  },

  // --------------------------------------------------------------- errors include location
  {
    kind: "reject",
    rule: "error location reporting",
    name: "error has line/column/nodeType",
    src: "\nclass X {}",
    needle: "class",
  },
];

export const cases = CASES;

/**
 * @returns {{ passed: number, total: number }}
 */
export function run() {
  let passed = 0;
  let failed = 0;
  for (const c of CASES) {
    const r = validate(c.src, { filename: c.name + ".js" });
    if (c.kind === "accept") {
      if (!r.ok) {
        failed += 1;
        console.error("FAIL accept: " + c.name);
        for (const e of r.errors) {
          console.error("  " + e.nodeType + " @ " + e.line + ":" + e.column +
            " — " + e.message);
        }
        continue;
      }
    } else {
      if (r.ok) {
        failed += 1;
        console.error("FAIL reject: " + c.name + " — expected error containing " +
          JSON.stringify(c.needle));
        continue;
      }
      const hit = r.errors.find((e) =>
        e.message.indexOf(c.needle) !== -1);
      if (!hit) {
        failed += 1;
        console.error("FAIL reject: " + c.name + " — none of the errors contain " +
          JSON.stringify(c.needle));
        for (const e of r.errors) {
          console.error("  " + e.nodeType + " @ " + e.line + ":" + e.column +
            " — " + e.message);
        }
        continue;
      }
      // For the "error location reporting" rule, also check shape.
      if (c.name === "error has line/column/nodeType") {
        if (typeof hit.line !== "number" || typeof hit.column !== "number" ||
            typeof hit.nodeType !== "string") {
          failed += 1;
          console.error("FAIL: error shape missing line/column/nodeType");
          continue;
        }
      }
    }
    passed += 1;
  }
  if (failed > 0) {
    throw new Error(failed + " test failures out of " + CASES.length);
  }
  return { passed: passed, total: CASES.length };
}

if (typeof process !== "undefined" && process.argv && process.argv[1]) {
  const arg = process.argv[1];
  if (arg.endsWith("validator.test.js")) {
    const r = run();
    // eslint-disable-next-line no-undef
    console.log("validator.test.js: " + r.passed + "/" + r.total + " passed");
  }
}
