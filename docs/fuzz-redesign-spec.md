# Type Fuzzer Redesign

## Problem

The existing fuzz suite (fuzz_alg.lua, fuzz_test.lua, fuzz_arb.lua) tests **algebraic
laws of subtyping** — reflexivity, union intro/elim, transitivity. These are correct and
valuable. But they test a much simpler type system than what now exists.

Everything added in the 2026-03-30 session — match evaluation, captures, EachField, partial
application, interface oracle — is **type-level computation**. That has completely different
invariants, and the current generator cannot produce those types at all.

## Three-tier architecture

| Tier | File | What it tests | No parse | Context |
|------|------|---------------|----------|---------|
| Algebra | fuzz_alg.lua | Subtyping lattice laws | ✓ | types_mod directly |
| Eval | fuzz_eval.lua (NEW) | Type-level computation contracts | — | Mini scope, annotation strings |
| Grammar | fuzz_test.lua | Full pipeline end-to-end | — | Full check_string |

---

## Tier 1: Algebra (extend fuzz_alg.lua)

Existing invariants stay. Add:

- **Optional field subtyping**: `{ x?: T } <: { x?: T }` (reflexivity with optional field)
- **Required ≤ optional**: `{ x: T } <: { x?: T }` (required field satisfies optional slot)
- **Intersection-of-records field access**: `{ x: A } & { y: B } <: { x: A }` (existing elim, but with records specifically)

Generator extension: add record types with optional fields (`FLAG_OPTIONAL`) and readonly
fields (`FLAG_READONLY`) to `arb_type`. These are structural nodes, no scope needed.

Not added to algebra tier: match types, EachField, oracle — all require scope.

---

## Tier 2: Eval (new fuzz_eval.lua)

Tests **type-level computation contracts**. Uses a fixed pre-declared scope, generates
type expressions as strings, evaluates via `check.check_string`.

### Fixed scope (always declared at top of each eval test)

```lua
--:: KeepAll<D>      = match D { _ => { D } }
--:: DropAll<D>      = match D { _ => {} }
--:: MakeOptional<D> = match D { { optional: _, ...%Rest } => { { optional: true,  ...Rest } } }
--:: MakeRequired<D> = match D { { optional: _, ...%Rest } => { { optional: false, ...Rest } } }
--:: MakeReadonly<D> = match D { { readonly: _, ...%Rest } => { { readonly: true,  ...Rest } } }
--:: MakeWritable<D> = match D { { readonly: _, ...%Rest } => { { readonly: false, ...Rest } } }
```

### Table type generator (arb_simple_table)

Generates annotation strings for simple closed table types:

```
table_type  ::= "{ " field ("," " " field)* " }"
field       ::= modifiers name ": " base_type
modifiers   ::= ("readonly ")? ("?")?    -- optional/readonly flags
name        ::= one of {x, y, z, n, s}
base_type   ::= "integer" | "string" | "boolean" | "number"
```

Constraints:
- 1–3 fields (prevents blowup)
- No duplicate field names within one table
- Generates both plain and union tables: `T` and `T1 | T2`

### Type equivalence assertion

To assert `A == B` (structural equivalence): generate a program that checks both
`A <: B` and `B <: A` via assignment. If no errors, types are equivalent.

```lua
<scope declarations>
--:: T = <generated table type>
--:: Result = <computed expression, e.g. $EachField<T, KeepAll>>
local x --: T
local _a --: Result = x   -- T <: Result
local _b --: T     = x    -- (x is T, assign to T, trivially ok — but we need Result <: T)
```

Actually simpler: use a two-way assignment check:

```lua
local function check_eq(x --: A, y --: B)
  local _: B = x  -- A <: B
  local _: A = y  -- B <: A
end
```

Or even simpler: check only `A <: B` for asymmetric properties (subtype, not equality).

### Invariants

**EachField:**

1. **KeepAll identity**: `$EachField<T, KeepAll> <: T` and `T <: $EachField<T, KeepAll>` for any generated T
2. **DropAll empty**: `$EachField<T, DropAll> <: {}` — DropAll gives empty table (subtype of empty closed table)
3. **MakeOptional→MakeRequired round-trip**: `$EachField<$EachField<T, MakeOptional>, MakeRequired>` structurally == T (bidirectional — all fields present, types unchanged)
4. **MakeReadonly→MakeWritable round-trip**: same pattern
5. **Distributivity**: `$EachField<T1 | T2, KeepAll>` == `$EachField<T1, KeepAll> | $EachField<T2, KeepAll>` == `T1 | T2`

**Match:**

6. **Capture identity**: `match T { %R => R }` == T for any base type T (integer, string, boolean)
7. **Wildcard constant**: `match T { _ => integer }` == `integer` for any non-never T
8. **Never propagation**: `match never { _ => integer }` == `never`
9. **Union distribution**: `match (A | B) { %R => R }` == `A | B` — capture on union round-trips

**Oracle:**

10. **Oracle soundness (algebraic)**: construct a test ctx; generate two types A_tid, B_tid where
    `try_unify(A_tid, B_tid) == true`; intern names "FuzzA"/"FuzzB"; manually inject
    `(FuzzA_id, FuzzB_id)` into `ctx.declared_subtypes`; add aliases to scope; create
    TAG_NAMED nodes; call `try_unify(FuzzA_named, FuzzB_named)` — assert returns true.
    This tests the oracle lookup path directly, independent of the declaration mechanism.

11. **Oracle non-interference**: for types A, B where A </: B structurally; oracle has NO
    entry for (A, B); call `try_unify(A_named, B_named)` — assert returns false (oracle miss
    falls through to structural, which correctly rejects).

**Partial application:**

12. **Completion consistency**: `PickKey<"x", D>` applied to descriptor with key="x" == `{ D }`;
    applied to descriptor with key="y" == `{}`. Test with concrete fixed descriptors.

### Trial counts

- EachField/Match/PartialApp invariants: 500 trials each (involve string parsing)
- Oracle invariants (algebraic): 2000 trials each (direct type construction, fast)

---

## Tier 3: Grammar (extend fuzz_test.lua)

Extend the Lua program generator to include:

### New program patterns

```lua
-- Pattern A: match alias application
--:: ReturnType<F> = match F { () -> %R => R }
local function f() return 42 end
local x --: ReturnType<typeof f>   -- not yet expressible; skip until typeof
```

```lua
-- Pattern B: interface declaration + oracle use
--:: Addable = { __add: (integer, integer) -> integer }
--:: Vec2: Addable = { __add: function(a, b) return a + b end }
local function add_things(a --: Addable, b --: Addable) end
local v --: Vec2
add_things(v, v)  -- should pass via oracle
```

```lua
-- Pattern C: Pick/Omit
--:: PickKey<Keys, D> = match D { { key: %K, ...%Rest } => match K { Keys => { D }, _ => {} }, _ => {} }
--:: Pick<T, Keys> = $EachField<T, PickKey<Keys>>
local x --: { name: string, age: integer }
local y --: Pick<{ name: string, age: integer }, "name"> = x  -- should fail (has extra field)
```

New invariants (grammar level):

- **Interface oracle (E2E)**: declare `--:: A: B`; a function expecting B accepts A values (no error)
- **Partial application type accuracy**: `Pick<T, "x">` contains only the "x" field
- **Match capture correctness**: `ReturnType` of a known function gives the declared return type

---

## Generator file structure

```
lib/type/static/
  fuzz_arb.lua         — algebra generators (extend with optional/readonly)
  fuzz_eval_arb.lua    — NEW: eval-tier generators (arb_simple_table, table_to_string)
  fuzz_alg.lua         — algebra invariants (minor extensions)
  fuzz_eval.lua        — NEW: eval tier invariants
  fuzz_test.lua        — grammar tier (extend program generator)
```

## Implementation order

1. `fuzz_arb.lua`: add optional/readonly field generation
2. `fuzz_alg.lua`: add 3 new algebra invariants
3. `fuzz_eval_arb.lua`: create simple table generator
4. `fuzz_eval.lua`: create eval tier with EachField + match + oracle invariants
5. `fuzz_test.lua`: add interface declaration + oracle program patterns

Each step independently testable. Start with (1–3) as they extend existing infrastructure.
