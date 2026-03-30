# Fuzz Suite Gaps

Current state after 2026-03-30 redesign: 22 algebra invariants, 11 eval invariants,
24 grammar invariants. The three-tier architecture is in place but coverage is thin.
This file tracks what's missing, ordered by priority.

## Tier 1 (Algebra) gaps

These extend fuzz_alg.lua. All use direct type construction (fast, 2000 trials).

### A1: never propagation — DONE (invariants 25–27, fuzz_alg.lua)
- [x] `never | T <: T` — invariant 25
- [x] `T <: never | T` — invariant 26
- [x] `never & T <: never` — invariant 27

### A2: readonly field semantics — PARTIALLY DONE
- [x] `{ readonly x: T } <: { readonly x: T }` — reflexivity: invariant 24
- [x] `{ x: T } <: { readonly x: T }` — mutable satisfies readonly: invariant 28
- [ ] `{ readonly x: T } </: { x: T }` — NOT testable at algebra level (unify.lua).
  FLAG_READONLY is a write-site constraint enforced in constrain.lua, not unify.lua.
  try_unify checks structural shape only; readonly does not affect structural subtyping.
  Needs a grammar-level test (fuzz_test.lua) that exercises a write to a readonly field.

### A3: function arity — DONE (invariants 30–31, fuzz_alg.lua)
- [x] `(A, B) -> C </: (A) -> C` — extra required param fails: invariant 30
- [x] `(A) -> C <: (A) -> C` — reflexivity sanity check: invariant 31
Note: uses `arb_base_type` for B so `nil </: B` always holds — contravariant padding at
position 2 inserts T_NIL for the target, so try_unify checks `nil <: B`, which fails for
all of integer/number/string/boolean.

### A4: meta slot subtyping — SKIPPED (try_unify does not check meta fields)
`try_unify` only iterates regular fields (data[0]/data[1]) in the TAG_TABLE branch (unify.lua
lines 981–997). Meta field checking lives only in `M.unify`, used by constrain.lua. All
try_unify calls on meta-only tables return true trivially regardless of meta slot presence or
type mismatch, making algebra-level invariants vacuously true and non-informative.
Grammar-level alternative (P3): build programs using `setmetatable` and typed meta slots,
verifying metamethod access typechecks correctly via the full constrain.lua pipeline.

---

## Tier 2 (Eval) generator gaps

fuzz_eval_arb.lua only generates simple table types. Everything below requires generator
extension before the invariants can be tested.

### G1: function type generation
Add `arb_function_type(rng)` to fuzz_eval_arb.lua:
```
func_type ::= "(" param_list ") -> " base_type
param_list ::= base_type ("," " " base_type)*  -- 0–3 params
```
Needed for: param capture invariants, ReturnType invariants.

### G2: union type subjects for match
Extend `arb_union_table` to also generate `A | B` where A and B are base types (not just tables). Needed for: match capture on union, distributivity.

---

## Tier 2 (Eval) invariant gaps

These go in fuzz_eval.lua. Grouped by feature.

### E1: never propagation through EachField
- `$EachField<never, KeepAll>` — should produce `never` (no fields to iterate)
- `$EachField<T | never, KeepAll>` == `$EachField<T, KeepAll>` == T

### E2: EachField filter correctness
- `DropOptional<{ x?: integer, y: string }>` == `{ y: string }` — filter removes optional field
- `NonOptional<T>` where T has mixed required/optional — only required fields survive

### E3: partial application round-trip
`F<A><B>` == `F<A, B>` for any 2-param alias. Test with PickKey:
- `PickKey<"x", D>` == `PickKey<"x"><D>` for a fixed descriptor D
Requires: apply the alias both ways, assert results are structurally equal.

### E4: all-fields pattern correctness — DONE (fuzz_eval.lua E4a–E4c)
- [x] `Keys<{ x: integer, y: string }>` == `"x" | "y"` — E4a
- [x] `Values<{ x: integer, y: string }>` == `integer | string` — E4b
- [x] `Keys<{ [integer]: boolean }>` == `integer` (indexer table) — E4c
These test the `{ ...[%K]: %V }` all-fields pattern properties.

### E5: param captures (requires G1 generator)
- `Parameters<(integer, string) -> boolean>` == `(integer, string)`
- `Tail<(integer, string, boolean) -> nil>` == `(string, boolean)`
- `Last<(integer, string) -> nil>` == `string`
- `Init<(integer, string) -> nil>` == `(integer,)` (1-tuple)
Requires `arb_function_type` generator.

### E6: $Throw/$Catch interaction
- `$Catch<$Throw<"msg">, integer>` == `integer` (catch swallows throw, returns default)
- `$Catch<string, integer>` == `string` (no throw, value passes through)
Fixed test (not randomly generated — $Throw/Catch take literal message strings).

### E7: generic defaults
- `WithDefault<integer>` where `WithDefault<T, U = string> = { a: T, b: U }` → `{ a: integer, b: string }`
- Missing second arg uses default
Fixed test with hardcoded alias.

### E8: oracle non-population on failed declaration — DONE (fuzz_eval.lua E8)
- [x] Failed `--:: BadImpl: HasX = { y: string }` emits CONSTRAINT_MISMATCH
- [x] Subsequent `needs_x(bad)` call also errors (structural mismatch — body `{ y: string }` lacks field `x`)
Note: implementation always registers the oracle pair even on failure (constrain.lua line 3134),
but variable bindings carry the resolved body type (not the name), so the call-site structural
check fails independently of the oracle. Both errors fire correctly — exactly 2 total.

### E9: match exhaustiveness on union
`match (A | B) { A => X, B => X }` == X for base type combinations.
Test: declare match alias, apply to union, check result is X with 0 errors.

### E10: capture in function return position
`match (integer -> string) { () -> %R => R }` == `string`
Requires `arb_function_type`.

### E11: MakeOptional idempotent
`$EachField<$EachField<T, MakeOptional>, MakeOptional>` == `$EachField<T, MakeOptional>`
Applying MakeOptional twice == applying once.

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

### P3: meta slot programs
Program: `setmetatable(t, mt)` return type carries meta slots.
Field access on result uses `__index`. Verify it typechecks correctly.

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
