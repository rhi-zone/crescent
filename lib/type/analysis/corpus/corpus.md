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

The **crescent.slice.v1 Verdict** column is filled from the actual Pass-4 corpus
run (`lib/type/analysis/corpus_test.lua`, the end-to-end runner that routes each
fixture's checked behavior through the hosted `crescent.slice.v1` checker). All
eleven reach the Expected Verdict (Accepts / 0 errors); none required a
fixture-keyed carve-out in the checker (hard constraint). See
`docs/agnostic-static-analysis-crescent-slice.md` §7.1 (mapping) and §9.6
(Pass-4 findings).

| Fixture | Source Fire | Feature Families | Expected Verdict (correct checker) | Legacy Verdict (current checker) | crescent.slice.v1 Verdict |
|---------|-------------|-----------------|-------------------------------------|----------------------------------|---------------------------|
| `fixture_boolean_narrowing.lua` | `lib/type/v7_mr0/canonical.lua` TODO + commit `fcfdd612` | Boolean type, comparison operators returning boolean, `and` operator narrowing, function return type | Accepts; `n == 0 and 1 / n < 0` has type `boolean` | **REMAINS** — errors: `return type mismatch: cannot return nil | boolean` | **Accepts** — `synth_and_or_not` positive `and`-of-booleans ⇒ `boolean` (not `nil|boolean`) |
| `fixture_closure_param_typing.lua` | `lib/web/reactive_dom/init.lua` beside(); commit `40f3da91` | Higher-order functions, closure type inference, multi-return destructuring, call-site return-slot inference | Accepts; second return of `with_scope` is `() -> ()` regardless of closure param typing | **REMAINS** — errors: `cannot call value of type nil` (c1 inferred as nil) | **Accepts** — slot 2 drawn from the *declared* `Ret.fixed[2] = () -> ()`, never re-inferred from the typed closure (annotated form, §7.1) |
| `fixture_table_construction_widening.lua` | `lib/asm/ir.lua` lines 219, 251, 261, 342; TODO.md "unknown→any→T two-step" | Table type inference, literal type inference at assignment sites, flow-sensitive type merging, checked cast as structural assertion | Accepts; sequential assignments to different-literal-typed values widen to the declared alias type | **REMAINS** — errors: `cannot assign {dst:nil, op:"ret", pos:2} to {dst:0, op:"add", pos:1}` (literal lock) | **Accepts** — each write checks `<: Insn` (declared element type); both literal records widen; force cast admitted |
| `fixture_cast_not_inference_source.lua` | `lib/type/static/solve.lua:579`; TODO-typecheck.md "force casts act as inference sources"; `docs/typechecker-param-semantics.md` | Checked cast directional scope, parameter binding (unidirectional: arg→param), REDUNDANT_CAST diagnostic | Accepts redundant cast as documented intent (no error); or raises warning-only, never hard error | **REMAINS** — errors: `redundant force cast` (hard error) | **Accepts** — force cast = `trusted_signature` (visible boundary, never inference source); no REDUNDANT_CAST; `y` checked by its own type |
| `fixture_hamt_recursion.lua` | `lib/hamt/init.lua`; commit `56810b60` (stack-overflow fix) | Union types, recursive type aliases, integer-tag discriminated narrowing, termination under self-referential unions | Accepts; narrows union member via integer-tag check without force cast; no stack overflow | **PARTIALLY FIXED** — no crash/overflow; errors: 2× `force cast — fix upstream annotation` (lint rule; narrowing requires explicit cast) | **Accepts** — integer-tag `narrow_guard` refines the μ-unfolded union to exactly `Leaf` (no force cast); cycle-guarded `subtype`, no overflow |
| `fixture_local_return_narrowing.lua` | `lib/taskgraph/exec.lua:27-30`, `lib/taskgraph/context.lua:54-57` | Local variable type inference from call return annotation, nil-narrowing post-guard, union types `T | nil`, flow-sensitive narrowing | Accepts; `task` is narrowed to `TaskNode` in the if-branch without explicit annotation | **FIXED** — 0 errors (unannotated form accepted correctly) | **Accepts** — unannotated-local synth + nil-guard `narrow_guard` ⇒ `task : TaskNode`; `task.done : boolean` |
| `fixture_union_alias_over_named_types.lua` | `lib/imap/format_types.lua:53`; "v3 gap" comment | Type aliases, union of named aliases (`A | B` where A, B are `--::` declared), field access on union | Accepts; `AnyCmd = LoginCmd | LogoutCmd`; common-field access works; function returns either constituent | **FIXED** — 0 errors | **Accepts** — `synth_index` distributes over the union (`tag` present in ALL members ⇒ `string`; `user` inaccessible) |
| `fixture_tonumber_return_type.lua` | `lib/safe_regex/init.lua:148-151`; commit `02812180` workaround | Standard library typing (`tonumber`, `string.sub`), `number | nil` from fallible stdlib calls, nil-narrowing post-guard | Accepts; `tonumber(string.sub(...))` inferred as `number | nil`; narrowed to `number` after nil check | **FIXED** — 0 errors (no intermediate `--: string` annotation needed) | **Accepts** — trusted `tonumber` signature ⇒ `number|nil`; nil-guard ⇒ `number`; `math.floor : integer <: integer|nil` |
| `fixture_pairs_return_leak.lua` | `lib/type/static/constrain.lua:~4182`; `$PairsReturn` workaround comment | `pairs()` for-in loop typing, table construction via loop, no internal iterator types in user-visible positions | Accepts; table built by `pairs()` loops has clean element type; no `$PairsReturn` in call-site type | **FIXED** — 0 errors | **Accepts** — `for-in pairs` (`synth_loop_var`) binds `k`/`v` from the indexer type directly; slice has no match-type intrinsic to leak (§9.1) |
| `fixture_coinductive_recursive_types.lua` | `docs/agnostic-static-analysis-design.md` §5; `lib/fp/maybe`, `lib/fp/either` (stack-overflow triggers) | Self-referential recursive type aliases, union with recursive members (`T | nil`), termination, discriminated narrowing on recursive unions | Accepts; recursive type traversal (tree_sum) and Maybe-like dispatch check without divergence | **FIXED** — 0 errors | **Accepts** — contractive `mu` + cycle-guarded `subtype` (no divergence); nil-guard discriminates `integer|nil` |
| `fixture_cross_module_type_alias.lua` | `lib/dns/tcp_client.lua:11-15`; "cross-module named type alias not visible" comment | Cross-module type alias visibility, `require` return type propagation, `Foo | nil` parameter typing, nil-narrowing post-guard | Accepts; in-file alias form works; cross-module form (epoll alias from epoll/init.lua in dns/tcp_client.lua) requires alias propagation across require boundary | **PARTIAL** — 0 errors for in-file form; cross-module form still requires `unknown | nil` workaround (verify with actual files) | **Accepts** (in-file form) — alias resolves to `Ty`; nil-guard ⇒ `Epoll`; `ep.wait()` accessible. Cross-module form is a trusted boundary in v1 (an accept, not a checked relation — §9.2) |

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
11. `fixture_cross_module_type_alias.lua` — in-file alias form works; the TRUE
    cross-module form is now the two-file `xmod/` fixture (see "Multi-file fixtures"
    below), checkable end-to-end as of slice v2 increment 2.

## crescent.slice.v1 Result Summary (Pass 4, 2026-06-12)

**11 / 11 fixtures Accept (0 errors), matching every Expected Verdict.** The five
REMAINS gaps the legacy checker still carries (boolean `and`, closure return-slot,
table-widening, redundant-cast, hamt tag-narrow) are all closed by the slice; the
six FIXED regression guards stay accepted. No fixture required a fixture-keyed or
name-keyed carve-out in the hosted checker — each derivation runs through the same
registered evidence methods (`synth_*`, `check_*`, `narrow_guard`, `subtype_witness`,
`instantiate_witness`, `trusted_signature`, and the Pass-4 `synth_loop_var` /
`synth_numeric_for_var`). The one Pass-4 mechanism change forced by the corpus was
*principled, not fixture-keyed*: `slice_narrow.lua`'s `members_of` now unfolds a μ
target once before the positive decomposition, so a discriminated union written as
a recursive alias (`HamtNode = Leaf | Interior`) splits into its arms for tag
narrowing — the same equirecursive `unfold` already applied to members elsewhere.
See `docs/agnostic-static-analysis-crescent-slice.md` §9.6.

The runner is `lib/type/analysis/corpus_test.lua` (40 assertions, the §7.1 verdicts
plus the named mechanism assertions — hamt tag-narrowed branch type = `Leaf`,
boolean `and` ⇒ `boolean`, pairs loop-var = indexer value type, recursive-μ
subtype reflexive without overflow). It models each fixture's *checked behavior* as
the typing derivation a correct checker concludes (the claim graph for the
fixture's load-bearing expressions), not by re-parsing the `.lua` source.

## How to validate a new checker

Run `bin/cr check lib/type/analysis/corpus/<fixture>` (or the equivalent new
checker invocation). For REMAINS fixtures: the new checker must produce 0 errors.
For FIXED fixtures: the new checker must also produce 0 errors (regression guard).
For `fixture_cross_module_type_alias.lua`: also run the checker on
`lib/dns/tcp_client.lua` + `lib/epoll/init.lua` together and verify that
`epoll` can be typed as `Epoll | nil` without a workaround.

## Multi-file fixtures

A fixture may span multiple files in a subdirectory when the gap it encodes is a
genuinely cross-artifact relation (one file declaring something another file
consumes). The corpus directory supports this: a subdirectory under
`lib/type/analysis/corpus/` holds the co-operating files, and the runner drives the
ENTRY file with a file-reading capability so the other files resolve.

### `xmod/` — the TRUE cross-module type-alias form (slice v2 increment 2)

The two-file realization of `fixture_cross_module_type_alias.lua`'s cross-module
half (the tcp_client+epoll pattern its source-fire comment names):

- `xmod/epoll.lua` — the EXPORTING module. Declares `--:: Epoll = { ... }` (the
  `lib/epoll/init.lua` shape).
- `xmod/tcp_client.lua` — the ENTRY module. References `Epoll` by **bare name** in a
  parameter annotation (`epoll: Epoll | nil`), where `Epoll` is declared in
  `xmod/epoll.lua`, NOT in this file — the `require` of the exporting module brings
  its `--::` aliases into the entry's annotation scope (`docs/agnostic-static-analysis-crescent-slice.md`
  §6.6).

**Expected behavior (correct checker):** with the file-reading cap injected, `Epoll`
resolves across the `require` boundary (it is NOT `unknown-type-name`), and the
cross-module resolution is recorded as a visible `cross_module_alias` trust boundary
with a Dependency per consuming claim. The entry's *statements* (a value-`require`, a
`mod.new()` method call) are out-of-§5-subset, so the lowered file is OUT-OF-SUBSET —
that is the orthogonal statement-lowering boundary (§9.8), not an alias-resolution
failure. End-to-end assertions: `lib/type/analysis/crescent_slice_xmodule_test.lua`.

These files are intentionally NOT held to the zero-error `bin/cr check` bar (they
are corpus fixtures, exempt via the `.githooks/pre-commit` corpus exemption).
