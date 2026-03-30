# Fuzz Suite Gaps

Current state after 2026-03-31 update: 39 algebra invariants, 57 eval invariants (22 arb.it
+ 21 T.it, 500 trials each for arb), 15 grammar programs. The three-tier architecture
is in place. This file tracks remaining gaps.

## Tier 1 (Algebra) gaps

These extend fuzz_alg.lua. All use direct type construction (fast, 2000 trials).

### A1: never propagation — DONE (invariants 25–27, fuzz_alg.lua)
- [x] `never | T <: T` — invariant 25
- [x] `T <: never | T` — invariant 26
- [x] `never & T <: never` — invariant 27

### A2: readonly field semantics — DONE
- [x] `{ readonly x: T } <: { readonly x: T }` — reflexivity: invariant 24
- [x] `{ x: T } <: { readonly x: T }` — mutable satisfies readonly: invariant 28
- [x] writing to a readonly field is rejected — grammar-level A2c (fuzz_test.lua)
- [x] reading a readonly field is allowed — grammar-level A2d (fuzz_test.lua)
Note: `{ readonly x: T } </: { x: T }` is NOT testable at algebra level (unify.lua).
  FLAG_READONLY is a write-site constraint enforced in constrain.lua, not unify.lua.
  try_unify checks structural shape only; readonly does not affect structural subtyping.
  Grammar-level write-rejection tests (A2c/A2d) provide the coverage instead.

### A3: function arity — DONE (invariants 30–31, fuzz_alg.lua)
- [x] `(A, B) -> C </: (A) -> C` — extra required param fails: invariant 30
- [x] `(A) -> C <: (A) -> C` — reflexivity sanity check: invariant 31
Note: uses `arb_base_type` for B so `nil </: B` always holds — contravariant padding at
position 2 inserts T_NIL for the target, so try_unify checks `nil <: B`, which fails for
all of integer/number/string/boolean.

### A5: lattice boundaries — DONE (invariants 25–33, fuzz_alg.lua)
- [x] `never <: T` for all T — bottom type is subtype of everything
- [x] `T <: unknown` for all T — everything is subtype of top
- [x] `base_type </: never` — base types are not subtypes of bottom (negative)
- [x] `unknown </: base_type` — top is not assignable without narrowing (negative)
- [x] `unknown | T <: unknown` — union with top stays top
- [x] `unknown & T <: T` — intersection with top gives the other
- [x] `T <: unknown & T` — T is in any intersection with top
- [x] `(unknown)->T <: (base_type)->T` — contravariance with top: wider param OK
- [x] `(base_type)->T </: (unknown)->T` — contravariance: narrower param fails (negative)

### A4: meta slot subtyping — DONE (invariants 32–34, fuzz_alg.lua)
- [x] `{ #__add: T } <: { #__add: T }` — meta reflexivity: invariant 32
- [x] `{ #__add: T, #__sub: U } <: { #__add: T }` — meta elimination (source has more): invariant 33
- [x] `{} </: { #__add: T }` — missing required meta field fails: invariant 34
Fixed by adding meta field iteration to `try_unify`'s TAG_TABLE branch (unify.lua), mirroring
the logic already in `M.unify`. `table_meta_field` is used for lookup; the check mirrors regular
field checking: missing required meta field → false; optional mismatch → false; recursive try_unify
on types. Grammar-level coverage (P3) now done — see fuzz_test.lua P3a/P3b.

---

## Tier 2 (Eval) generator gaps

fuzz_eval_arb.lua only generates simple table types. Everything below requires generator
extension before the invariants can be tested.

### G1: function type generation — DONE
- [x] `arb_function_type(rng, size)` — returns annotation string "(A, B) -> C"
- [x] `arb_function_parts(rng, size)` — returns `{ params, ret, type_str }` for invariant building
Both added to fuzz_eval_arb.lua. 0–3 params, base types only, never `any`.

### G2: union type subjects for match — DONE
- [x] `arb_union_base(rng, size)` — returns `{ lhs, rhs, type_str }` for two distinct base types (fuzz_eval_arb.lua)
- [x] G2a: `CaptureId<A | B> == A | B` — capture on union round-trips (500 trials, fuzz_eval.lua)
- [x] G2b: `$EachField<T1|T2, KeepAll> == $EachField<T1,KeepAll> | $EachField<T2,KeepAll>` — EachField distributivity over union of tables (500 trials, fuzz_eval.lua)

### G3: match identity for non-base types — DONE (fuzz_eval.lua 6b–8b)
- [x] `CaptureId<T> == T` for random table types (500 trials) — 6b
- [x] `CaptureId<F> == F` for random function types (500 trials) — 6c
- [x] `WildConst<T> <: integer` for random table types (500 trials) — 7b
- [x] `WildConst<F> <: integer` for random function types (500 trials) — 7c
- [x] `CaptureId<T1 | T2> == T1 | T2` for random table union (500 trials) — 8b
Previously, match identity was only tested for 4 base types.

---

## Tier 2 (Eval) invariant gaps

These go in fuzz_eval.lua. Grouped by feature.

### E1: never propagation through EachField — DONE (fuzz_eval.lua E1a–E1b)
- [x] `$EachField<never, KeepAll> | integer == integer` — EachField over never is never (E1a)
- [x] `$EachField<never, KeepAll>` usable as `never` — no crash, 0 errors (E1b)

### E2: EachField filter correctness — DONE (fuzz_eval.lua E2a–E2b)
- [x] `DropOptional<{ x?: integer, y: string }>` keeps `.y` accessible, drops `.x` (E2a)
- [x] `DropOptional<{ x: integer, y: string }>` == identity on all-required table (E2b)
DropOptional declared inline: `match D { { optional: true, ...%Rest } => {}, _ => { D } }`

### E3: partial application round-trip — DONE (fuzz_eval.lua E3a–E3d)
- [x] `Pick<{ x: integer, y: string }, "x">.x` accessible — 0 errors (E3a)
- [x] `Pick<{ x: integer, y: string }, "x">.y` not accessible — 1 error (E3b)
- [x] `Omit<{ x: integer, y: string }, "x">.y` accessible — 0 errors (E3c)
- [x] `$EachField<T, PickKey<"x">> == Pick<T, "x">` bidirectional round-trip (E3d)
PickKey/OmitKey/Pick/Omit declared via nested match. Partial-application path
(`PickKey<"x">` as unapplied alias passed to `$EachField`) and direct-application path
(`Pick<T, "x">`) produce the same structural type.

### E4: all-fields pattern correctness — DONE (fuzz_eval.lua E4a–E4c)
- [x] `Keys<{ x: integer, y: string }>` == `"x" | "y"` — E4a
- [x] `Values<{ x: integer, y: string }>` == `integer | string` — E4b
- [x] `Keys<{ [integer]: boolean }>` == `integer` (indexer table) — E4c
These test the `{ ...[%K]: %V }` all-fields pattern properties.

### E5: param captures — DONE (fuzz_eval.lua E5a–E5c)
- [x] E5a: `Parameters<(integer, string) -> boolean>` == `(integer, string)` (fixed)
- [x] E5b: `Tail<(integer, string, boolean) -> nil>` == `(string, boolean)` (fixed)
- [x] E5c: `Parameters<F>` == param tuple for random function types (500 trials, random)
Note: `Last` and `Init` not tested here (deferred — require 1-element tuple literals, not yet stabilized).

### E6: $Throw/$Catch interaction — DONE (fuzz_eval.lua E6a–E6c)
- [x] `$Catch<$Throw<"msg">, integer>` == `integer` — catch returns default (E6a)
- [x] `$Catch<string, integer>` == `string` — no throw, value passes through (E6b)
- [x] `$Throw<"msg">` without $Catch produces exactly 1 diagnostic with the message (E6c)

### E7: generic defaults — DONE (fuzz_eval.lua E7a–E7c)
- [x] `WithDefault<integer>` uses default `U = string` → `{ a: integer, b: string }` (E7a)
- [x] `WithDefault<integer, boolean>` overrides default → `{ a: integer, b: boolean }` (E7b)
- [x] `WithDefault<integer>` b is `string` not `boolean` → 1 error (E7c, negative test)

### E8: oracle non-population on failed declaration — DONE (fuzz_eval.lua E8)
- [x] Failed `--:: BadImpl: HasX = { y: string }` emits CONSTRAINT_MISMATCH
- [x] Subsequent `needs_x(bad)` call also errors (structural mismatch — body `{ y: string }` lacks field `x`)
Note: implementation always registers the oracle pair even on failure (constrain.lua line 3134),
but variable bindings carry the resolved body type (not the name), so the call-site structural
check fails independently of the oracle. Both errors fire correctly — exactly 2 total.

### E9: match exhaustiveness on union — DONE (fuzz_eval.lua E9a–E9c)
- [x] `Normalize<integer | string>` == `string` (both arms → string, E9a)
- [x] `MapTypes<integer | string>` <: `boolean | integer` (both arm results present, E9b)
- [x] `Ignores<integer>` == `string` (never arm never fires, E9c)

### E10: capture in function return position — DONE (fuzz_eval.lua E10a–E10d)
- [x] E10a: `ReturnType<() -> integer>` == `integer` (fixed)
- [x] E10b: `ReturnType<() -> string>` == `string` (fixed)
- [x] E10c: `ReturnType<() -> (integer, string)>` is a tuple `(integer, string)` (fixed)
- [x] E10d: `ReturnType<() -> C>` == `C` for random 0-param function types (500 trials)

### E11: MakeOptional idempotent — DONE (fuzz_eval.lua E11)
- [x] `$EachField<$EachField<T, MakeOptional>, MakeOptional>` == `$EachField<T, MakeOptional>` (500 trials, bidirectional)

---

## Tier 3 (Grammar) gaps

These extend fuzz_test.lua program patterns.

### P1: Pick/Omit correctness — DONE (fuzz_test.lua P1a/P1b)
- [x] `Pick<{name,age}, "name">.name` accessible — 0 errors (P1a)
- [x] `Pick<{name,age}, "name">.age` not accessible — 1 error (P1b)

### P2: param capture programs — DONE (fuzz_test.lua P2a–P2c)
- [x] `Parameters<typeof f>` == `(integer, string)` bidirectionally (P2a)
- [x] Wrong param order `(string, integer)` rejected — 1 error (P2b)
- [x] `ReturnType<typeof h>` == `boolean` (P2c)
Notes: `typeof` was already implemented. Use `-> %R` (not `-> _` or `-> unknown`) in the
pattern return position — `_` doesn't match void `-> ()`, `unknown` doesn't match non-unknown
returns; `%R` captures and ignores any return type. Inline params with `--:` on same line
as other params silently swallow the rest of the line (Lua comment); annotate via
`--: (A, B) -> C` on the preceding line instead.

### P3: meta slot programs — DONE
- [x] P3a: `setmetatable({}, { __index = fn })` typechecks — 0 errors (fuzz_test.lua)
- [x] P3b: `setmetatable(v, mt)` with typed Vec/VecMeta typechecks — 0 errors (fuzz_test.lua)

### P4: $Throw inside match — only fires for selected arms — DONE (fuzz_test.lua P4a/P4b)
- [x] `CheckedId<integer>` — integer arm taken, no throw — 0 errors (P4a)
- [x] `CheckedId<string>` — wildcard arm taken, throw fires — 1 error (P4b)
Note: `$Throw<"literal">` fires eagerly at alias declaration time. Defer by using a type arg:
`$Throw<T, " suffix">` — only fires when the arm is selected and T is concrete.

### P5: generic defaults in programs — DONE (fuzz_test.lua P5a/P5b/P5c)
- [x] `Wrap<integer>` defaults `U` to `string` — 0 errors (P5a)
- [x] `Wrap<integer, boolean>` overrides default — 0 errors (P5b)
- [x] `Wrap<integer>` label is `string` not `integer` — 1 error via function return check (P5c)
Note: `local x --: T` only narrows the variable; use function return annotation to assert
structural field-level mismatch (see CLAUDE.md "Annotation enforcement gotcha").

### MA8: EachField flag-alias distributivity over union — DONE (fuzz_eval.lua MA8a–MA8d)
- [x] MA8a: `$EachField<T1|T2, MakeOptional>` == `$EachField<T1, MakeOptional> | $EachField<T2, MakeOptional>` (500 trials, bidirectional)
- [x] MA8b: `$EachField<T1|T2, MakeRequired>` == `$EachField<T1, MakeRequired> | $EachField<T2, MakeRequired>` (500 trials, bidirectional)
- [x] MA8c: `$EachField<T1|T2, MakeReadonly>` == `$EachField<T1, MakeReadonly> | $EachField<T2, MakeReadonly>` (500 trials, bidirectional)
- [x] MA8d: `$EachField<T1|T2, MakeWritable>` == `$EachField<T1, MakeWritable> | $EachField<T2, MakeWritable>` (500 trials, bidirectional)
Uses `{ arb_table_type, arb_table_type }` generators with `check_sub` (FIXED_SCOPE already declares all four aliases).

### MA: multi-arm match expression — DONE (fuzz_eval.lua MA1–MA6)
- [x] MA1: arm selectivity — `match T { A => C, B => D }` with `T = A` gives `C`, `T = B` gives `D` (bidirectional, 500 trials)
- [x] MA2: distributivity over union — `match (A|B) { A => C, B => D } == C | D` (bidirectional, 500 trials)
- [x] MA3: non-matching input gives `never` — `match D { A => C, B => C }` with `D ∉ {A, B}` gives `never` (500 trials)
- [x] MA4a: `FieldX<{ x: integer, y: string }>` == `integer` — structural arm extracts x field (bidirectional, fn-return)
- [x] MA4b: `FieldX<{ x: string }>` == `string` — single-field table extraction (bidirectional, fn-return)
- [x] MA4r: `FieldX<T>` == x-field-type when T has x, else `never` — random table types (500 trials, fn-return bidirectional)
- [x] MA5: `FieldX<{ y: integer }>` == `never` — no x field gives never (bidirectional, fn-return)
- [x] MA5b: `FieldX<{ y: string, z: boolean }>` == `never` — multi-field, no x (bidirectional, fn-return)
- [x] MA6a: `IsX<{ x: integer }>` == `boolean` — exact type in pattern selects first arm (bidirectional, fn-return)
- [x] MA6b: `IsX<{ x: string }>` == `never` — wrong field type falls to wildcard (bidirectional, fn-return)
Uses `arb_base_type_quad` (all 4 distinct base types in random order) for MA1–MA3 so arm keys are always unambiguous.
`check_sub_ext(a, b, extra_scope)` and `check_sub_fn`/`check_eq_fn` helpers in fuzz_eval.lua.
Note: `check_sub` (local assignment) does NOT enforce primitive type mismatches (CLAUDE.md "annotation enforcement gotcha").
MA4–MA6 use `check_sub_fn` (function-return annotation) which enforces `A </: B` correctly.
`FieldX<T> = match T { { x: %V } => V }` — open structural pattern matches any table with x field,
captures its type; tables without x give `never`.

---

## Implementation order

1. **A1 (never propagation)** — trivial, 3 new algebra invariants
2. **A2 (readonly)** — small, 2–3 new algebra invariants
3. **E1 (EachField never)** — small, uses existing eval infrastructure
4. **E6 ($Throw/$Catch)** — fixed tests, no generator needed
5. **E7 (generic defaults)** — fixed tests, no generator needed
6. **E8 (oracle non-population)** — medium, needs program + assertion
7. **G1 + E5 (function type generator + param captures)** — medium, new generator
8. **E4 (all-fields pattern)** — medium, uses existing eval infrastructure
9. **E3 (partial application round-trip)** — medium, needs alias + descriptor generation
10. **E9–E11 (match exhaustiveness, function return capture, MakeOptional idempotent)** — medium
11. **P1, P3, P4, P5 (grammar programs)** — medium
12. **A3–A4 (function arity, meta slots algebra)** — medium
13. **P2 (param capture programs)** — deferred until `typeof` exists
