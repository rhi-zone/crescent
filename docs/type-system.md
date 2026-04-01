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
local f = function(a, b) return a + b end  -- f: (number, number) -> number
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

Annotations are constraints, not assertions. The checker verifies the annotation against the implementation. Casts (`--[[as T]]`) exist for when you know better, but they require overlap. Force casts (`--[[as! T]]`) exist for when you *really* know better, and they're grep-able.

### 5. Sound by default, escape hatches by choice

Soundness means: if the checker says "no errors," there are no type errors at runtime (modulo FFI and force casts).

| Mechanism | Soundness | Use case |
|-----------|-----------|----------|
| Normal code | Sound | Application logic |
| `--:` annotation | Sound (checked) | Documentation + constraint |
| `--[[as T]]` | Semi-sound (overlap) | Narrowing, downcasting |
| `--[[as! T]]` | Unsound (explicit) | FFI, serialization |
| `any` | Unsound (bilateral) | Dynamic boundaries |

The unsound mechanisms are *visible*. You can grep for `as!` and `any` to find every place where the type system is bypassed.

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

### Union and intersection

`A | B` means "A or B." `A & B` means "A and B." Unions are for values that could be several types. Intersections are for values that satisfy multiple constraints (overloaded functions, mixin types).

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

## Decisions

Resolved design choices. Sections with dedicated design docs link to them; brief decisions that have no separate doc are kept inline.

### Generics: `<T>` syntax
→ See [generic-params-spec.md](generic-params-spec.md)

### Type narrowing: full flow analysis
→ See [typechecker-v3.md](typechecker-v3.md) and [semantics.md](semantics.md) (narrowing rules)

**Flow typing is not inference.** These are separate concerns that must not be conflated:
- **Inference** resolves type variables from usage constraints. `?A` → `string | nil`.
- **Flow typing** refines known types based on control flow. `string | nil` → `string` after a nil guard.

The architecture is two passes: (1) constraint generation + solving resolves all type variables, (2) a post-solve flow typing pass walks control flow and applies narrowings to the now-concrete types. Narrowing never participates in constraint solving — no subtraction constraints, no fixpoint interaction with the solver. Narrowing stays lexical/scoped: scope exit reverts to the pre-narrowing resolved type; early-return patterns work because there is no join point.

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

### Field modifiers: optional, readonly, private

FieldEntry gains a flags word — stride changes from 2 to 3: `(name_id, type_id, flags)`.

- `FLAG_OPTIONAL = 0x01` — field may be absent; access returns `T|nil`.
- `FLAG_READONLY = 0x02` — assignment to this field is a type error.
- `FLAG_PRIVATE` — superseded by [access-control.md](access-control.md).

Syntax: `field?: T` for optional, `readonly field: T` for readonly. No table-level `readonly` keyword — `Readonly<T>` is a library type (mapped type in the prelude).

### `typeof` in function signatures: mutual equality constraints

`typeof x` in a function signature means "same type as parameter x." Works for backward refs, forward refs, and mutual/circular refs. The mutual case `(a: typeof b, b: typeof a)` resolves via union-find — equivalent to `<T>(a: T, b: T)`. Implementation requires pre-binding all param names as `TAG_VAR` placeholders before resolving annotations.

### Mutual bounded type parameter constraints

Parameters can have mutually dependent bounds: `<T, K: $Keys<T>>(obj: T, key: K)`. For fully mutual bounds, the solver finds a fixed point by iterating until no bound changes.

## Open Questions

Genuinely unresolved — needs dedicated design work:

- **Coroutine effects.** Full effect system design for yield/resume typing. See [effects.md](effects.md).
