# Type System Design

Design philosophy for crescent's static typechecker. Not a spec — a set of principles that guide decisions when the spec is ambiguous.

## The Core Bet

Lua is a dynamically typed language. Most Lua typecheckers respond to this by being lenient: infer what you can, shrug at what you can't, let `any` spread silently. TypeScript chose this path because JavaScript codebases are enormous and untyped, and migration matters more than soundness.

We don't have that constraint. Crescent is a new ecosystem. Every library is written from scratch. There is no legacy code to accommodate. So we make a different bet:

**The type system is static by default. Dynamic typing is an explicit opt-in.**

This means:
- Unannotated code is *inferred*, not assumed `any`.
- If inference fails, it's an error — not a silent widening.
- `any` exists but is a deliberate escape hatch, not a fallback.
- The checker should catch bugs at the cost of occasional annotation burden.

The goal is not to type all possible Lua programs. It's to type *crescent programs* — code written with the type system in mind.

## Principles

### 1. Infer aggressively, widen reluctantly

The checker should infer precise types from code structure:

```lua
local x = 42           -- x: 42 (literal type), not number
local t = { a = 1 }    -- t: { a: number }, not table
local f = function(a, b) return a + b end
-- f: <A: { #__add: (A, B) -> C }, B, C>(A, B) -> C
-- Not `(number, number) -> number` — that would be a predicate-style collapse
-- ("must be numeric") which violates Principle 10. The body's `a + b` requires
-- only that `a` has `__add` taking `(A, B)` and returning some type; `number`,
-- `integer`, and any user type with `__add` defined all satisfy this.
```

Widening happens at well-defined points:
- Assignment to a mutable binding widens literals to their base type.
- Function parameter types widen on export (you don't want `(42) -> ...`).
- Explicit annotation always wins.

The user should be able to look at any binding and know its type without running the program.

### 2. Structural by default, nominal by choice

Lua tables are the only compound data structure. Two tables with the same shape are the same type:

```lua
--:: Point = { x: number, y: number }
local p = { x = 1, y = 2 }  -- p is a Point, no declaration needed
```

This is the natural fit for Lua. Structural typing works *with* the language. But sometimes you need identity — two types with the same shape that are deliberately incompatible. Three mechanisms, each addressing a different need:

```lua
-- opaque: structure hidden outside the defining module
--:: opaque Connection = { fd: number, state: string }

-- newtype: distinct type wrapping another, explicit conversion required
--:: newtype UserId = number
--:: newtype PostId = number

-- private fields: individual fields hidden, rest of structure visible
--:: Session = { id: string, private socket: cdata }
```

**`opaque`** is OCaml's abstract type. **`newtype`** is Haskell's zero-cost wrapper. **`private`** is field-granularity visibility. They're orthogonal and composable.

Row polymorphism keeps tables open when they need to be:

```lua
-- This function works on any table with an `x` field:
local function get_x(t) return t.x end
-- Inferred: <T> ({ x: T, ... }) -> T
```

The `...` (row variable) means "and maybe other fields." Without it, the table is closed.

### 3. `any` is a firewall, not a lubricant

In TypeScript, `any` is contagious — it silently disables checking for everything it touches. In crescent, `any` is a *boundary marker*:

- You can assign anything to `any`.
- You can assign `any` to anything.
- But the checker *notices*. It tracks where `any` enters the system.

The philosophy: `any` is for FFI boundaries, legacy interop, and genuinely dynamic code. It should not appear in normal application code. Every implicit `any` emits a warning.

### 4. Annotations are checked, not trusted

Annotations are constraints, not assertions. The checker verifies the annotation against the implementation. The cast form `--[[: T]] expr` (placed *before* the expression) emits a subtype check — it does not bypass the type system, it just gives you a place to attach a target type. A redundant cast (where `expr` already has type `T`) is warned about.

**Annotations vs. casts.** A `--: T` annotation on `local x --: T = expr` is *not* a cast — it requires `expr` to already typecheck against `T`. The same applies to `--[[: T]]`: it emits `C_SUB(typeof(expr), T)`. There is no force-cast / unsafe-cast variant in the current checker. (Soundness gap: for `unknown` actuals, the local-init path silently accepts assignment to any annotated type — see [soundness-audit.md, Gap 8](soundness-audit.md).)

### 5. Sound by default, escape hatches by choice

Soundness means: if the checker says "no errors," there are no type errors at runtime (modulo `any` and FFI boundaries).

| Mechanism | Soundness | Use case |
|-----------|-----------|----------|
| Normal code | Sound | Application logic |
| `--:` annotation | Sound (checked) | Documentation + constraint |
| `--[[: T]] expr` cast | Sound (checked subtyping) | Annotating an expression in place |
| `any` | Unsound (bilateral) | Dynamic boundaries |

The unsound mechanism is *visible*. You can grep for `any` to find every place where the type system is bypassed.

**Planned, not implemented.** A semi-sound cast (overlap-required, e.g. `--[[as T]]`) and a force cast (e.g. `--[[as! T]]`) have been discussed but neither is implemented. The current `--[[: T]]` is strictly a checked subtype assertion. See TODO.md.

### 6. Follow the language, don't fight it

Lua has specific idioms. The type system must handle them natively:

- **Module pattern**: `local M = {}; function M.foo(x) ... end; return M` — tracked as open table, refined with each assignment.
- **Method calls**: `function Point:move(dx, dy)` — `self` typed from context.
- **Varargs, multiple returns, `pcall` wrapping** — core Lua patterns handled in the core, not via special-case hacks.
- **`setmetatable` and `__index`**: `setmetatable(t, {__index = proto})` merges `proto`'s fields into `t`'s type.

### 7. FFI types come from C, not from annotations

LuaJIT's FFI is typed at the C level. The checker reads `ffi.cdef` blocks directly via cparser — no duplicate type definitions. Single source of truth. The C header *is* the type definition.

### 8. The checker is modular

The typechecker is a small core — structural HM unification, scope management, AST walking — with features as separate modules: annotations, narrowing, nominal types, FFI, builtins, patterns, coroutines, metatypes. Each module is a Lua file that plugs into the core. All modules are always enabled. The benefit is development velocity and testability.

### 9. Errors are precise, not noisy

A type error should tell you exactly what went wrong, where, and why. Not "type mismatch" with no context. Not 47 cascading errors from one root cause. Report the *first* meaningful error in a chain and suppress downstream noise.

### 10. Prefer principled solutions over special cases

When a check needs to accept a new category of type, ask whether the type system can be extended cleanly rather than tagging the predicate. Ad-hoc flags erode correctness over time.

### 11. Every type tag requires a complete behavioral spec

For every type construct, enumerate ALL operations it must support: field access, indexing, call, unification (both directions), try_unify, narrowing, display, serialization, instantiate/generalize, resolve_annotation_type. Write tests for each. A type tag is not done until all operations are specified and tested.

### 12. New type features: derive from full unification first

When designing how a new type construct should work, ask: "what does full unification give us?" before reaching for special cases. The answer is almost always: one persistent type that accumulates information over time, not per-access reconstruction.

### 13. Source locations do not belong in the type system

Types are semantic entities; source positions are syntactic. Do not store line/col in type arena entries — errors are exceptional, so paying a per-entry cost for rare diagnostics is the wrong trade-off. Reparse the source on the error path instead.

## Types

### Primitives

`nil`, `boolean`, `number`, `integer`, `string`. These are the Lua value types. `integer` is a subtype of `number` (`integer <: number`), matching LuaJIT's representation.

### Literal types

`"GET"`, `42`, `true`. A literal type is a singleton — exactly one value. Literal types enable discriminated unions:

```lua
--:: Method = "GET" | "POST" | "PUT" | "DELETE"
```

### Union, intersection, and complement

Crescent's type lattice is **set-theoretic**: union (`|`), intersection (`&`), and complement (`~`) are first-class type constructors. Subtyping, narrowing, match-types, and overload resolution all operate under this algebraic structure.

- `A | B` — "A or B." Unions are for values that could be several types.
- `A & B` — "A and B." Intersections are for values that satisfy multiple constraints (overloaded functions, mixin types).
- `~T` — "any type that is not a subtype of T." Complement is the unary prefix operator.

Complement uses `~` rather than `!` because `!` is reserved by the force-cast syntax `--[[:! T]]`; reusing it for negation would create two meanings of the same token.

```lua
--: ~string                 -- any type that is not a subtype of string
--: ~(string | number)      -- neither a string nor a number
--: T & ~nil                -- narrowing T to exclude nil
--: ~~T                     -- equivalent to T (complement is involutive)
```

The complement operator is what makes the `_` arm in match types well-defined: `_` desugars to `~(P1 | P2 | ...)` over the other arms' patterns (see [typechecker-reference.md](typechecker-reference.md) match types).

### Functions

```lua
(number, string) -> boolean
(x: number, y: number) -> number   -- named params (documentation only)
(string, ...Array<any>) -> string   -- varargs (Array<T> = { [number]: T })
(string) -> (number?, string?)      -- multi-return
```

Parameters are contravariant, returns are covariant.

### Tables

Tables are the universal compound type. A table type has:
- **Named fields**: `{ x: number, y: number }` — known keys with known types.
- **Indexers**: `{ [string]: number }` — dynamic keys. `{ [number]: T }` for arrays, `{ [string]: T }` for dictionaries.
- **Row variable**: open vs. closed. Open tables accept extra fields. Closed tables don't.

Optionality is expressed as `T | nil` — no dedicated postfix syntax.

### Tuples

`{ number, string, boolean }` is a tuple — fixed length, heterogeneous, ordered. Distinct from arrays:

- `t[1]` is `number`, `t[2]` is `string`, `t[3]` is `boolean`.
- `t[4]` is an error — out of bounds.
- A tuple is *not* assignable to an array.
- `ipairs` over a tuple yields the union of element types at each position.

### `any` and `never`

`any` is the top-and-bottom type for gradual typing. `never` is the true bottom — the type of expressions that never produce a value (`error("msg")`, exhausted narrowing). `never` is assignable to everything (vacuously). Nothing is assignable to `never`.

## Non-Goals

- **Typing all Lua programs.** Code not written for the type system may not type-check. That's fine.
- **TypeScript compatibility.** EmmyLua and LuaLS exist. Crescent's annotation syntax is purpose-built.
- **Completeness.** The checker will have gaps. Better to be correct on 90% of code than hand-wavy on 100%.
- **Runtime overhead.** The checker is purely static. Zero runtime cost. The runtime schema validator (`lib/type/check.lua`) is a separate, complementary tool.

### Out of scope: type-system features crescent will not adopt

The set-theoretic foundation (union, intersection, complement) plus crescent's existing constructors (product, function, fixed point, universal quantification, type-level functions / match types, nominal opaqueness) covers the closure of useful operations for crescent's domain. The following are explicitly out of scope. If a feature request lands in this list, the answer is "not in scope" — not silent extension of the type system.

- **Dependent types** (types parameterized by runtime values, not just types). Massive implementation complexity, decidability concerns, low payoff for crescent's use cases. Crescent's literal types provide a weak proxy.
- **Linear / affine types** (track usage of values). Resource-management feature; not part of crescent's design intent.
- **Effect types** (track side effects in the type). Not in crescent's design intent.
- **Refinement types beyond narrowing** (types as `{x : A | P(x)}` for arbitrary predicates P). Requires attaching logical predicates to types and SMT-style checking. Crescent's flow-sensitive narrowing covers the practical cases.
- **Quotient types** (`A / ~`). Rare in mainstream type systems; not in crescent's design intent.
- **Coinductive types** beyond what structural records already express. Structural records handle some forms; full co-recursion as a primary feature is out of scope.
- **Higher-rank kind polymorphism beyond HKT decomposition.** Crescent has HKT; full System Fω-style kind polymorphism is not needed.

## Decisions

Resolved design choices. Sections with dedicated design docs link to them; brief decisions that have no separate doc are kept inline.

### Generics: `<T>` syntax
→ See [generic-params-spec.md](generic-params-spec.md)

### Type narrowing: full flow analysis
→ See [typechecker-v3.md](typechecker-v3.md) and [semantics.md](semantics.md) (narrowing rules)

**Flow typing is not inference.** These are separate concerns that must not be conflated:
- **Inference** resolves type variables from usage constraints. `?A` → `string | nil`.
- **Flow typing** refines known types based on control flow. `string | nil` → `string` after a nil guard.

The principle is two passes: (1) constraint generation + solving resolves all type variables, (2) a post-solve flow typing pass applies narrowings to the now-concrete types. Narrowing stays lexical/scoped: scope exit reverts to the pre-narrowing resolved type; early-return patterns work because there is no join point.

**Open problem:** constraints from narrowed scopes reference the un-narrowed type variable, not the narrowed concrete type. `local x = f(); if x then x:upper() end` generates `?A:upper()` against the un-narrowed `?A = string | nil`, which fails — but should succeed because `x` is `string` in the narrowed scope. A pure post-solve pass avoids fixpoint issues but must somehow re-evaluate constraints that depend on narrowed variables. Design options in TODO.md.

### Metatypes: `__index` drives the model
→ See [semantics.md](semantics.md) (metatype rules)

### Module resolution: overrideable, manifest-aware
→ See [require-intrinsic-spec.md](require-intrinsic-spec.md)

### Error recovery: `any` with warnings

When inference fails partway through a function, the checker assigns `any` to the failed expression and continues. Every implicit `any` emits a warning. One error doesn't cascade into 50 errors.

### Output formats

The checker supports human-readable (default), JSON, and SARIF output. Machine-readable output is a first-class concern.

### No strict mode — strict is the only mode

There is no `--strict` flag. The checker is always strict. Every implicit `any` is a warning. Every type error is an error. We start tight. We stay tight.

### Generic constraints: structural, inline
→ See [generic-params-spec.md](generic-params-spec.md)

### Overload resolution: best match
→ See [semantics.md](semantics.md) (overload resolution rules)

### Variance: unimplemented — inference planned

**Current state:** all generic types are invariant. **Planned:** infer variance from usage (`out T` covariant, `in T` contravariant, `inout T` invariant). Explicit annotations available for documentation and enforcement. Known gap: without variance, HKT subtype relationships between constructors can't be checked.

### Inline privacy annotations
→ See [access-control.md](access-control.md)

### String pattern types

`string.match`, `string.gmatch`, and `string.gsub` return types depend on capture groups in the pattern string. Implemented as a checker module that analyzes string literal patterns and computes return types from capture groups. Non-literal patterns fall back to `string?` returns.

### Coroutine typing
→ See [effects.md](effects.md)

### Tuple subtyping: structural, no magic
→ See [semantics.md](semantics.md) (tuple rules)

### Recursive types: equi-recursive with lazy expansion
→ See [semantics.md](semantics.md) (recursive type rules)

### Type-level computation: declarative, not imperative
→ See [semantics.md](semantics.md), [capture-sigil-spec.md](capture-sigil-spec.md), [each-field-spec.md](each-field-spec.md), [partial-application-spec.md](partial-application-spec.md)

### Higher-kinded types
→ See [generic-params-spec.md](generic-params-spec.md)

### `newtype` conversion: constructor pattern
→ See [access-control.md](access-control.md)

### Performance: LuaJIT-first, Rust escape hatch

The checker is written in LuaJIT because that's the ecosystem. But performance is a hard constraint: if the checker can't stay within ~2x of equivalent Rust performance on realistic codebases, rewrite the hot paths in Rust. We measure, not hope.

### Manifest: `crescent.type.toml`

Separate from the package manager's manifest. Optional; the checker works without one by following `package.path`. Supports module path overrides, external type stubs, and package.path additions.

### Standard prelude
→ See [stdlib-design.md](stdlib-design.md)

### v2 Checker Architecture
→ See [typechecker-v3.md](typechecker-v3.md) (supersedes the v2 architecture notes)

## Decisions — Implementation Details

Concrete decisions made during implementation, kept here because they have no dedicated doc.

### Field modifiers: attributes, not keywords

**Current implementation** (to be replaced): FieldEntry has a packed flags byte (`FLAG_OPTIONAL`, `FLAG_READONLY`, `FLAG_PRIVATE`). Syntax is per-keyword: `readonly name: T`, `name?: T`. Each new modifier requires parser changes and a new flag bit.

**Design direction: field attributes.** Field modifiers are arbitrary named metadata attached to fields via a general attribute syntax, not per-modifier keywords. Prior art: Java `@annotations`, C# `[attributes]`, Rust `#[attributes]`, C++ `[[attributes]]`, Python decorators, Go struct tags — every major language converges on this pattern because the problem (metadata on declarations) is universal.

Proposed syntax (sigil TBD):
```lua
--: { @readonly x: integer, @optional y: string }
--: { @deprecated @readonly z: boolean }
```

The parser collects `@name` attributes on fields without knowing what they mean. The checker defines which attributes it understands (`@readonly`, `@optional`, etc.). New attributes (`@deprecated`, `@lazy`, `@sealed`, whatever) require zero parser changes.

**Why not per-modifier keywords:** each keyword (`readonly`, `writeonly`, `optional`, `final`, `const`, `private`, `protected`, ...) adds parsing complexity and is closed — adding a new modifier means changing the parser. Attributes are open — the parser handles the general mechanism, the checker interprets specific names.

**Why not infer from usage:** inference tells you what IS (descriptive), annotations tell you what SHOULD BE (prescriptive). Type systems are prescriptive — `@readonly` means "writing is a bug," not "happens to not be written currently." Inference loses prescriptive intent and causes spooky action at a distance (one new write silently removes readonly for everyone).

**Why not `+`/`-` variance markers:** `+integer` and `-integer` conflict with numeric literals. Symbols aren't free.

**For `$EachField` / mapped types:** attributes are type-level data on the field descriptor. Match can inspect them, transforms can add/remove/change them. `MakeOptional<T>` = iterate fields of T, add `@optional` to each. `MakeReadonly<T>` = add `@readonly` to each. No special flag-mutation API — just attribute manipulation via the same match/transform mechanism as value types.

**Open questions:**
- Attribute sigil: `@name`, `#name`, or something else? (`#` is already used for meta-fields in the current syntax)
- Should attributes carry arguments? `@deprecated("use foo instead")`, `@range(0, 100)`
- How to represent attributes in the type arena (extend FieldEntry? separate attribute list?)
- Interaction with `$EachField`: does the transform function see attributes as fields on the descriptor, or as a separate attribute list?

Syntax: `field?: T` for optional, `readonly field: T` for readonly. No table-level `readonly` keyword — `Readonly<T>` is a library type (mapped type in the prelude).

### `typeof` in function signatures: mutual equality constraints

`typeof x` in a function signature means "same type as parameter x." Works for backward refs, forward refs, and mutual/circular refs. The mutual case `(a: typeof b, b: typeof a)` resolves via union-find — equivalent to `<T>(a: T, b: T)`. Implementation requires pre-binding all param names as `TAG_VAR` placeholders before resolving annotations.

### Mutual bounded type parameter constraints

Parameters can have mutually dependent bounds: `<T, K: $Keys<T>>(obj: T, key: K)`. For fully mutual bounds, the solver finds a fixed point by iterating until no bound changes.

## Open Questions

Genuinely unresolved — needs dedicated design work:

- **Coroutine effects.** Full effect system design for yield/resume typing. See [effects.md](effects.md).
