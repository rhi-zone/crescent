# Acceptance/Falsification Corpus

**Location:** `lib/type/analysis/corpus/`
**Purpose:** Minimal self-contained fixtures encoding documented legacy-checker
failures with their expected-correct verdicts. Kernel-agnostic: does not assume
any specific checker architecture. Any future checker is validated against this
corpus — it must match or beat the "legacy verdict" column.

**Note:** These fixtures are NOT `*_test.lua` files; the test runner globs
`*_test.lua` only and will not pick them up. The corpus directory is also
exempt from the pre-commit hook's new-file zero-error requirement (see
`.githooks/pre-commit` exemption block for `lib/type/analysis/corpus/`).

The "verdict" column uses kernel-agnostic language (not checker-implementation
vocabulary). "Accepts" = 0 errors (warnings allowed). "Errors with: ..." = the
specific error produced by the legacy checker.

## Methodology

- Legacy verdict obtained by running `timeout 30 bin/cr check <fixture>` on
  each fixture file and recording the actual output (not anticipated behavior).
- "FIXED" in the legacy verdict column means the gap was documented in source
  comments but the current checker already handles it correctly.
- "REMAINS" means the gap is active in the current checker.
- Future checkers must: accept all FIXED fixtures (0 errors), and accept all
  REMAINS fixtures (0 errors — that is the "beat it" bar).

## Fixture Table

| Fixture | Source Fire | Feature Families | Expected Verdict (correct checker) | Legacy Verdict (current checker) |
|---------|-------------|-----------------|-------------------------------------|----------------------------------|
| `fixture_boolean_narrowing.lua` | `lib/type/v7_mr0/canonical.lua` TODO + commit `fcfdd612` | Boolean type, comparison operators returning boolean, `and` operator narrowing, function return type | Accepts; `n == 0 and 1 / n < 0` has type `boolean` | **REMAINS** — errors: `return type mismatch: cannot return nil | boolean` |
| `fixture_closure_param_typing.lua` | `lib/web/reactive_dom/init.lua` beside(); commit `40f3da91` | Higher-order functions, closure type inference, multi-return destructuring, call-site return-slot inference | Accepts; second return of `with_scope` is `() -> ()` regardless of closure param typing | **REMAINS** — errors: `cannot call value of type nil` (c1 inferred as nil) |
| `fixture_table_construction_widening.lua` | `lib/asm/ir.lua` lines 219, 251, 261, 342; TODO.md "unknown→any→T two-step" | Table type inference, literal type inference at assignment sites, flow-sensitive type merging, checked cast as structural assertion | Accepts; sequential assignments to different-literal-typed values widen to the declared alias type | **REMAINS** — errors: `cannot assign {dst:nil, op:"ret", pos:2} to {dst:0, op:"add", pos:1}` (literal lock) |
| `fixture_cast_not_inference_source.lua` | `lib/type/static/solve.lua:579`; TODO-typecheck.md "force casts act as inference sources"; `docs/typechecker-param-semantics.md` | Checked cast directional scope, parameter binding (unidirectional: arg→param), REDUNDANT_CAST diagnostic | Accepts redundant cast as documented intent (no error); or raises warning-only, never hard error | **REMAINS** — errors: `redundant force cast` (hard error) |
| `fixture_hamt_recursion.lua` | `lib/hamt/init.lua`; commit `56810b60` (stack-overflow fix) | Union types, recursive type aliases, integer-tag discriminated narrowing, termination under self-referential unions | Accepts; narrows union member via integer-tag check without force cast; no stack overflow | **PARTIALLY FIXED** — no crash/overflow; errors: 2× `force cast — fix upstream annotation` (lint rule; narrowing requires explicit cast) |
| `fixture_local_return_narrowing.lua` | `lib/taskgraph/exec.lua:27-30`, `lib/taskgraph/context.lua:54-57` | Local variable type inference from call return annotation, nil-narrowing post-guard, union types `T | nil`, flow-sensitive narrowing | Accepts; `task` is narrowed to `TaskNode` in the if-branch without explicit annotation | **FIXED** — 0 errors (unannotated form accepted correctly) |
| `fixture_union_alias_over_named_types.lua` | `lib/imap/format_types.lua:53`; "v3 gap" comment | Type aliases, union of named aliases (`A | B` where A, B are `--::` declared), field access on union | Accepts; `AnyCmd = LoginCmd | LogoutCmd`; common-field access works; function returns either constituent | **FIXED** — 0 errors |
| `fixture_tonumber_return_type.lua` | `lib/safe_regex/init.lua:148-151`; commit `02812180` workaround | Standard library typing (`tonumber`, `string.sub`), `number | nil` from fallible stdlib calls, nil-narrowing post-guard | Accepts; `tonumber(string.sub(...))` inferred as `number | nil`; narrowed to `number` after nil check | **FIXED** — 0 errors (no intermediate `--: string` annotation needed) |
| `fixture_pairs_return_leak.lua` | `lib/type/static/constrain.lua:~4182`; `$PairsReturn` workaround comment | `pairs()` for-in loop typing, table construction via loop, no internal iterator types in user-visible positions | Accepts; table built by `pairs()` loops has clean element type; no `$PairsReturn` in call-site type | **FIXED** — 0 errors |
| `fixture_coinductive_recursive_types.lua` | `docs/agnostic-static-analysis-design.md` §5; `lib/fp/maybe`, `lib/fp/either` (stack-overflow triggers) | Self-referential recursive type aliases, union with recursive members (`T | nil`), termination, discriminated narrowing on recursive unions | Accepts; recursive type traversal (tree_sum) and Maybe-like dispatch check without divergence | **FIXED** — 0 errors |
| `fixture_cross_module_type_alias.lua` | `lib/dns/tcp_client.lua:11-15`; "cross-module named type alias not visible" comment | Cross-module type alias visibility, `require` return type propagation, `Foo | nil` parameter typing, nil-narrowing post-guard | Accepts; in-file alias form works; cross-module form (epoll alias from epoll/init.lua in dns/tcp_client.lua) requires alias propagation across require boundary | **PARTIAL** — 0 errors for in-file form; cross-module form still requires `unknown | nil` workaround (verify with actual files) |

## REMAINS Summary (gaps active in current checker)

These are the fixtures a future checker MUST improve on:

1. **`fixture_boolean_narrowing.lua`** — `and` of two booleans must be `boolean`, not `nil | boolean`.
2. **`fixture_closure_param_typing.lua`** — Typed closure passed to higher-order function must not corrupt multi-return inference for second return slot.
3. **`fixture_table_construction_widening.lua`** — Sequential integer-keyed table construction must widen to declared element type, not lock at first literal.
4. **`fixture_cast_not_inference_source.lua`** — REDUNDANT_CAST must be a warning, not a hard error, when the cast is explicit annotation intent.
5. **`fixture_hamt_recursion.lua`** — Integer-tag discriminated narrowing on a union (`if node.kind == NODE_LEAF`) should narrow without a force cast.

## FIXED Summary (regression guards)

These were documented gaps that are now correctly handled; future checkers must continue to accept them:

6. `fixture_local_return_narrowing.lua` — function return inference + nil-narrowing (fixed in current).
7. `fixture_union_alias_over_named_types.lua` — union alias over named table aliases (v3 gap, fixed).
8. `fixture_tonumber_return_type.lua` — `tonumber()` returns `number | nil` (fixed, no workaround needed).
9. `fixture_pairs_return_leak.lua` — `$PairsReturn` does not leak into user-visible types (fixed).
10. `fixture_coinductive_recursive_types.lua` — recursive types terminate (fixed in 56810b60 cycle guard).
11. `fixture_cross_module_type_alias.lua` — in-file alias form works; cross-module form is the remaining gap.

## How to validate a new checker

Run `bin/cr check lib/type/analysis/corpus/<fixture>` (or the equivalent new
checker invocation). For REMAINS fixtures: the new checker must produce 0 errors.
For FIXED fixtures: the new checker must also produce 0 errors (regression guard).
For `fixture_cross_module_type_alias.lua`: also run the checker on
`lib/dns/tcp_client.lua` + `lib/epoll/init.lua` together and verify that
`epoll` can be typed as `Epoll | nil` without a workaround.
