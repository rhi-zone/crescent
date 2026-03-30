# Fuzz Suite Gaps

Current state after 2026-03-31 update: 22 algebra invariants, 28 eval invariants,
24 grammar invariants. The three-tier architecture is in place but coverage is thin.
This file tracks what's missing, ordered by priority.

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

### G2: union type subjects for match
Extend `arb_union_table` to also generate `A | B` where A and B are base types (not just tables). Needed for: match capture on union, distributivity.

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

### P1: Pick/Omit correctness
Program: `Pick<{ x: integer, y: string }, "x">` contains only `x` field.
Assert: accessing `.x` on result: no error. Accessing `.y`: error (field not found).

### P2: param capture programs
Program using `Parameters<F>` — result type used in an annotation.
```lua
--:: Parameters<F> = match F { (...%P) -> unknown => P }
local function f(a --: integer, b --: string) end
local p --: Parameters<typeof f>  -- can't yet express typeof, skip?
```
May require `typeof` operator — not yet implemented. Defer until then.

### P3: meta slot programs — DONE
- [x] P3a: `setmetatable({}, { __index = fn })` typechecks — 0 errors (fuzz_test.lua)
- [x] P3b: `setmetatable(v, mt)` with typed Vec/VecMeta typechecks — 0 errors (fuzz_test.lua)

### P4: $Throw inside match — only fires for selected arms
```lua
--:: CheckedId<T> = match T {
--::   integer => integer,
--::   _ => $Throw<"expected integer">
--:: }
```
`CheckedId<integer>` → no diagnostic. `CheckedId<string>` → diagnostic.
Assert: error count is 0 for integer, 1 for string.

### P5: generic defaults in programs
A function with defaulted type params called with/without explicit type arg.

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
