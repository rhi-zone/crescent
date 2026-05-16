// lib/js_safe_regex/safe_regex.test.js
//
// Test corpus for safe_regex.js. Mirrors lib/safe_regex/safe_regex_test.lua
// case-for-case. To run:
//
//   bun lib/js_safe_regex/safe_regex.test.js
//
// or in a browser console:
//
//   import("./safe_regex.test.js").then(m => m.run())
//
// The module exports `cases` (the test corpus, also consumed by
// parity_test.lua) and `run()` (the runner).

import { validatePattern } from "./safe_regex.js";

/**
 * @typedef {{ kind: "safe", pat: string, name: string }
 *          | { kind: "unsafe", pat: string, needle: string | null, name: string }} Case
 */

/** @type {Case[]} */
const CASES = [
  // positive (safe)
  { kind: "safe", pat: "a+b", name: "single quantifier on a literal" },
  { kind: "safe", pat: "(ab)+c", name: "quantifier on a non-quantified group" },
  { kind: "safe", pat: "a{3}", name: "bounded fixed count" },
  { kind: "safe", pat: "a{3}b{2}", name: "bounded sequence" },
  { kind: "safe", pat: "[a-z]+", name: "quantifier on a character class" },
  { kind: "safe", pat: "\\d+", name: "shorthand class with quantifier" },
  { kind: "safe", pat: "(?:abc)+", name: "non-capturing group with quantifier" },
  { kind: "safe", pat: "(a)(b)(c)", name: "sibling capturing groups" },
  { kind: "safe", pat: "^a+$", name: "anchors don't compose with quantifiers" },
  { kind: "safe", pat: "", name: "empty pattern is safe" },
  { kind: "safe", pat: "a", name: "single literal" },
  { kind: "safe", pat: "foo|bar|baz", name: "alternation of simple atoms" },
  { kind: "safe", pat: "a+|b+", name: "alternation with one quantified branch" },
  { kind: "safe", pat: ".+", name: "dot with quantifier" },
  { kind: "safe", pat: "a?b+", name: "optional then quantified literal" },
  { kind: "safe", pat: "\\.\\+\\*", name: "escaped specials" },
  { kind: "safe", pat: "(?<name>abc)+", name: "named group without quantifier on quantified child" },
  { kind: "safe", pat: "\\x41+", name: "hex escape" },
  { kind: "safe", pat: "\\u0041+", name: "unicode escape" },
  { kind: "safe", pat: "\\u{1F600}+", name: "unicode brace escape" },
  { kind: "safe", pat: "\\bword\\b", name: "word boundary" },
  { kind: "safe", pat: "(a)\\1", name: "backref alone" },
  { kind: "safe", pat: "(?<x>a)\\k<x>", name: "named backref" },
  { kind: "safe", pat: "(?=abc)x", name: "lookahead containing only non-quantified content" },
  { kind: "safe", pat: "a{0,1}", name: "bounded {0,1} acts like ?" },
  { kind: "safe", pat: "a{3,3}", name: "bounded {3,3}" },
  { kind: "safe", pat: "(ab){3}", name: "bounded count on quantified-free group" },
  { kind: "safe", pat: "(?:a|b)+", name: "alternation in non-capturing group" },

  // negative (catastrophic)
  { kind: "unsafe", pat: "(a+)+",       needle: "nested quantifier", name: "(a+)+" },
  { kind: "unsafe", pat: "(a*)*",       needle: "nested quantifier", name: "(a*)*" },
  { kind: "unsafe", pat: "(a+)*b",      needle: "nested quantifier", name: "(a+)*b" },
  { kind: "unsafe", pat: "(\\d+)+",     needle: "nested quantifier", name: "(\\d+)+" },
  { kind: "unsafe", pat: "(a*)+",       needle: "nested quantifier", name: "(a*)+" },
  { kind: "unsafe", pat: "(?:a+)+",     needle: "nested quantifier", name: "non-capturing wrapping nested" },
  { kind: "unsafe", pat: "(?<x>a+)+",   needle: "nested quantifier", name: "named group nesting" },
  { kind: "unsafe", pat: "(?=(.+)+)x",  needle: "nested quantifier", name: "lookahead containing (.+)+" },
  { kind: "unsafe", pat: "((a+)+)+",    needle: "nested quantifier", name: "deeply nested groups stacking quantifiers" },
  { kind: "unsafe", pat: "(a|b+)+",     needle: "nested quantifier", name: "alternation branch contributes unbounded" },
  { kind: "unsafe", pat: "(a+){3}",     needle: "nested quantifier", name: "bounded outer on unbounded inner -- (a+){3}" },
  { kind: "unsafe", pat: "(a+){2,5}",   needle: "nested quantifier", name: "range that's effectively unbounded -- (a+){2,5}" },

  // edge cases
  { kind: "unsafe", pat: "^*",          needle: "anchor", name: "anchor with star is rejected" },
  { kind: "unsafe", pat: "\\b+",        needle: "anchor", name: "anchor with plus is rejected" },
  { kind: "safe",   pat: "(abc)?", name: "'?' after group is bounded so safe" },
  { kind: "safe",   pat: "a?", name: "'?' on a quantified-free child is bounded" },
  { kind: "safe",   pat: "a{0,0}", name: "'{0,0}' is bounded" },
  { kind: "safe",   pat: "a{xyz}b", name: "literal '{' (not a quantifier)" },
  { kind: "safe",   pat: "a{", name: "non-quantifier brace doesn't cascade" },

  // malformed
  { kind: "unsafe", pat: "(abc",   needle: "malformed", name: "unbalanced '('" },
  { kind: "unsafe", pat: "abc)",   needle: "malformed", name: "unbalanced ')'" },
  { kind: "unsafe", pat: "[abc",   needle: "malformed", name: "unbalanced '['" },
  { kind: "unsafe", pat: "abc\\",  needle: "malformed", name: "trailing backslash" },
  { kind: "unsafe", pat: "+abc",   needle: "malformed", name: "quantifier with no atom" },
  { kind: "unsafe", pat: "*",      needle: "malformed", name: "star with no atom" },
  { kind: "unsafe", pat: "(?Zabc)", needle: "malformed", name: "unknown group prefix" },
  { kind: "unsafe", pat: "(?<name", needle: "malformed", name: "unterminated named group" },
  { kind: "unsafe", pat: "(?=",    needle: "malformed", name: "unterminated lookahead" },

  // known limitations (v1): these pin current behavior
  { kind: "safe", pat: "(a|aa)+", name: "(a|aa)+ is currently accepted (KNOWN LIMITATION)" },
  { kind: "safe", pat: "(a|a)+",  name: "(a|a)+ is currently accepted (KNOWN LIMITATION)" },
  { kind: "safe", pat: "(.|.)+",  name: "(.|.)+ is currently accepted (KNOWN LIMITATION)" },
];

export const cases = CASES;

/**
 * Run the test corpus. Throws on first failure.
 * @returns {{ passed: number, total: number }}
 */
export function run() {
  let passed = 0;
  for (const c of CASES) {
    const r = validatePattern(c.pat);
    if (c.kind === "safe") {
      if (!r.ok) {
        throw new Error("expected SAFE for " + JSON.stringify(c.pat) +
          " (" + c.name + ") but got error: " + r.error);
      }
    } else {
      if (r.ok) {
        throw new Error("expected UNSAFE for " + JSON.stringify(c.pat) +
          " (" + c.name + ") but got ok");
      }
      if (typeof r.error !== "string") {
        throw new Error("expected error string for " + JSON.stringify(c.pat));
      }
      if (c.needle !== null && c.needle !== undefined &&
          r.error.indexOf(c.needle) === -1) {
        throw new Error("error " + JSON.stringify(r.error) +
          " did not contain " + JSON.stringify(c.needle) +
          " (case: " + c.name + ")");
      }
    }
    passed += 1;
  }
  return { passed: passed, total: CASES.length };
}

// When invoked directly (bun/node), run the suite.
// Detect "main module" without relying on Node-specific globals.
if (typeof process !== "undefined" && process.argv && process.argv[1]) {
  const arg = process.argv[1];
  if (arg.endsWith("safe_regex.test.js")) {
    const r = run();
    // eslint-disable-next-line no-undef
    console.log("safe_regex.test.js: " + r.passed + "/" + r.total + " passed");
  }
}
