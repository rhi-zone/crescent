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
-- inside this module: full field access
-- outside: it's just "Connection", no field access

-- newtype: distinct type wrapping another, explicit conversion required
--:: newtype UserId = number
--:: newtype PostId = number
-- UserId and PostId are incompatible despite both being number

-- private fields: individual fields hidden, rest of structure visible
--:: Session = { id: string, private socket: cdata }
-- outside: { id: string } — socket is invisible
```

**`opaque`** is OCaml's abstract type — the module controls what the outside world sees. **`newtype`** is Haskell's — zero-cost wrapper that creates type-level identity. **`private`** is field-granularity visibility. They're orthogonal and composable.

Row polymorphism keeps tables open when they need to be:

```lua
-- This function works on any table with an `x` field:
local function get_x(t) return t.x end
-- Inferred: <T> ({ x: T, ... }) -> T
```

The `...` (row variable) means "and maybe other fields." Without it, the table is closed — extra fields are an error. This distinction matters: APIs that accept input should be open. Data definitions should be closed.

### 3. `any` is a firewall, not a lubricant

In TypeScript, `any` is contagious — it silently disables checking for everything it touches. In crescent, `any` is a *boundary marker*:

- You can assign anything to `any`.
- You can assign `any` to anything.
- But the checker *notices*. It tracks where `any` enters the system.

The philosophy: `any` is for FFI boundaries, legacy interop, and genuinely dynamic code (serialization, plugin systems). It should not appear in normal application code. If you find yourself writing `any` to make the checker happy, the checker has a bug.

Every implicit `any` emits a warning. There is no "loose mode" — strict is the only mode. A gradual adoption path may exist for external code, but crescent libraries are held to the full standard. We are not here to let the ecosystem slip into looseness for the sake of backwards compatibility.

### 4. Annotations are checked, not trusted

Annotations are constraints, not assertions. When you write:

```lua
--: (number) -> string
local function f(x) return x end  -- ERROR: number is not string
```

The checker verifies the annotation against the implementation. This is different from TypeScript's `as`, which trusts the programmer. Crescent's `--:` is a contract — the checker enforces both sides.

Casts (`--[[as T]]`) exist for when you know better, but they require overlap. Force casts (`--[[as! T]]`) exist for when you *really* know better, and they're grep-able.

### 5. Sound by default, escape hatches by choice

Soundness means: if the checker says "no errors," there are no type errors at runtime (modulo FFI and force casts). We aim for this as the default, with well-marked exits:

| Mechanism | Soundness | Use case |
|-----------|-----------|----------|
| Normal code | Sound | Application logic |
| `--:` annotation | Sound (checked) | Documentation + constraint |
| `--[[as T]]` | Semi-sound (overlap) | Narrowing, downcasting |
| `--[[as! T]]` | Unsound (explicit) | FFI, serialization |
| `any` | Unsound (bilateral) | Dynamic boundaries |

The unsound mechanisms are *visible*. You can grep for `as!` and `any` to find every place where the type system is bypassed. This is a feature.

### 6. Follow the language, don't fight it

Lua has specific idioms. The type system must handle them natively, not as special cases the user has to annotate around:

**Module pattern:**
```lua
local M = {}
function M.foo(x) return x + 1 end
return M
-- M: { foo: (number) -> number }
```
The checker tracks `M` as an open table, refining it with each assignment, then exports the final type.

**Method calls:**
```lua
function Point:move(dx, dy)
  self.x = self.x + dx
  self.y = self.y + dy
end
-- self is the receiver, typed from context
```

**Varargs, multiple returns, `pcall` wrapping** — these are core Lua patterns, not edge cases. The type system handles them in the core, not via special-case hacks.

**`setmetatable` and `__index`:**
```lua
local Point = {}
Point.__index = Point
function Point.new(x, y)
  return setmetatable({ x = x, y = y }, Point)
end
```
The checker understands that `setmetatable(t, {__index = proto})` merges `proto`'s fields into `t`'s type. This is how Lua OOP works — the checker respects it.

### 7. FFI types come from C, not from annotations

LuaJIT's FFI is typed at the C level. The checker reads `ffi.cdef` blocks directly via cparser — no duplicate type definitions needed:

```lua
ffi.cdef [[
  typedef struct { double x, y; } vec2_t;
  vec2_t vec2_add(vec2_t a, vec2_t b);
]]
local a = ffi.new("vec2_t", 1, 2)  -- a: cdata<vec2_t>
local b = ffi.C.vec2_add(a, a)     -- b: cdata<vec2_t>
```

Single source of truth. The C header *is* the type definition. This extends to `ffi.cast`, `ffi.sizeof`, and `ffi.typeof`.

### 8. The checker is modular

The typechecker is not a monolith. It's a small core — structural HM unification, scope management, AST walking — with features implemented as separate modules that register into the core's dispatch tables:

- **Core**: types, environments, unification, basic inference
- **Annotations**: parse `--:` / `--::` syntax into types
- **Narrowing**: flow-sensitive type refinement in branches
- **Nominal**: `opaque`, `newtype`, `private` — identity and visibility
- **FFI**: cparser bridge, `ffi.cdef` extraction, cdata types
- **Builtins**: stdlib type signatures
- **Patterns**: string pattern return type analysis
- **Coroutines**: yield/resume typing
- **Metatypes**: `__index`, `__call`, operator metamethods

Each module is a Lua file that plugs into the core. No plugin API — just good file boundaries. This is internal architecture, not user-facing configuration. All modules are always enabled. The benefit is development velocity and testability: each subsystem can be built, tested, and reasoned about independently.

This is how rustc works (separate crates for borrowck, typeck, resolve) and how the checker should work too. Don't over-engineer the module boundary upfront — split out when the seams become obvious through implementation.

### 9. Errors are precise, not noisy

A type error should tell you exactly what went wrong, where, and why:

```
lib/foo/init.lua:42: error: cannot pass 'string' where 'number' expected
  42 | local x = math.sqrt("hello")
```

Not "type mismatch" with no context. Not 47 cascading errors from one root cause. The checker should report the *first* meaningful error in a chain and suppress downstream noise.

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

Parameters are contravariant, returns are covariant. This is standard.

### Tables

Tables are the universal compound type. A table type has:
- **Named fields**: `{ x: number, y: number }` — known keys with known types.
- **Indexers**: `{ [string]: number }` — dynamic keys. `{ [number]: T }` for arrays, `{ [string]: T }` for dictionaries.
- **Row variable**: open vs. closed. Open tables accept extra fields. Closed tables don't.

`T?` is sugar for `T | nil`.

### Tuples

`{ number, string, boolean }` is a tuple — fixed length, heterogeneous, ordered. Distinct from arrays:

- `t[1]` is `number`, `t[2]` is `string`, `t[3]` is `boolean`.
- `t[4]` is an error — out of bounds.
- `#t` is `integer` (statically known to be 3).
- A tuple is *not* assignable to an array. `{ number, string }` is not `[number | string]`.
- `ipairs` over a tuple yields the union of element types at each position.

Tuples model Lua's multiple-return and fixed-structure patterns. They're tables with known integer keys.

### `any` and `never`

`any` is the top-and-bottom type for gradual typing. `never` is the true bottom — the type of expressions that never produce a value:

- `error("msg")` returns `never` — the call never completes normally.
- `assert(x)` narrows `x` by eliminating nil/false; if `x` is `nil`, the `assert` branch is `never`.
- A function that always throws has return type `never`.
- `never` is assignable to everything (vacuously). Nothing is assignable to `never`.

## Non-Goals

- **Typing all Lua programs.** Code not written for the type system may not type-check. That's fine.
- **TypeScript compatibility.** EmmyLua and LuaLS exist. Crescent's annotation syntax is purpose-built.
- **Completeness.** The checker will have gaps. Better to be correct on 90% of code than hand-wavy on 100%.
- **Runtime overhead.** The checker is purely static. Zero runtime cost. The runtime schema validator (`lib/type/check.lua`) is a separate, complementary tool.

## Decisions

Resolved design choices.

### Generics: `<T>` syntax

Angle brackets for generic type parameters. Arrays use indexer syntax `{ [number]: T }`, not bracket sugar — no parsing conflict:

```lua
--:: Result<T, E> = { ok: T } | { err: E }
Result<number, string>

-- Arrays are table types with number indexers:
{ [number]: string }    -- array of string
```

### Type narrowing: full flow analysis

The checker models how the code actually works, not just what the types say. Narrowing applies everywhere a branch constrains a type:

```lua
local x = get_value() --: string | number | nil

if type(x) == "string" then
  -- x: string
  print(x:upper())
elseif x ~= nil then
  -- x: number
  print(x + 1)
else
  -- x: nil
end

-- Truthiness narrows too:
if x then
  -- x: string | number (nil eliminated)
end

-- Pattern matching on tags:
if t.kind == "literal" then
  -- t.value exists, t is narrowed to the literal branch
end
```

This is *more* power than TypeScript, not less. The goal is to model how the code works — if a branch eliminates a possibility, the checker knows. This extends to:

- `type()` checks → narrow to matching primitive
- `== nil` / `~= nil` → eliminate or narrow to nil
- Truthiness (`if x then`) → eliminate nil and false
- Tag/discriminant checks (`if x.kind == "foo"`) → narrow discriminated unions
- `assert(x)` → narrow away nil/false in subsequent code
- Negation: `if not x then return end` → `x` is truthy after the guard

### Metatypes: UX-first, `__index` drives the model

Metatables are Lua's extension mechanism. The type system must model them, and the UX question is: how does the user express "this table has metamethods"?

The core insight: `__index` is the only metamethod that affects *type structure* (it adds fields). The arithmetic metamethods (`__add`, `__mul`, etc.) affect *operator resolution*. `__call` makes a table callable. These are separate concerns:

```lua
-- __index: modeled via setmetatable pattern recognition
local Point = {}
Point.__index = Point
function Point.new(x, y)
  return setmetatable({ x = x, y = y }, Point)
end
-- Point.new returns: { x: number, y: number } & Point (merged via __index)

-- Arithmetic metamethods: declared via annotation
--:: Vector = { x: number, y: number, __add: (Vector, Vector) -> Vector }

-- __call: makes a table callable
--:: Callable = { __call: (self, number) -> string }
```

Start with `__index` (most common, highest value), then `__call`, then arithmetic. The checker recognizes `setmetatable` calls and merges types accordingly. Metamethods declared in type annotations are checked against the implementation.

### Module resolution: overrideable, manifest-aware

Following `require()` across files is essential — a typechecker that can't cross module boundaries is useless. The resolution strategy:

1. **Default**: follow `package.path` rules. `require("lib.foo")` → `lib/foo/init.lua` or `lib/foo.lua`.
2. **Manifest override**: a `crescent.toml` or similar can declare module mappings, external type stubs, and path overrides. This is how you type third-party code you don't control.
3. **Adjacent `.d.lua` files**: `lib/foo/init.d.lua` provides type declarations for `lib/foo/init.lua`. The checker loads these automatically. This is the escape hatch for code that's too dynamic to infer.
4. **External type packages**: type definitions can be distributed as vendorable `.d.lua` files, just like the libraries themselves.

```
lib/foo/init.lua        -- implementation
lib/foo/init.d.lua      -- type declarations (optional, supplements inference)
```

Circular requires: the checker detects cycles and assigns `any` to the cycle-breaking edge, with a warning. This is a real Lua pattern (two modules that require each other) and must not crash the checker.

Missing modules: error, not silent `any`. If you `require` something that doesn't exist, that's a bug.

### Error recovery: `any` with warnings

When inference fails partway through a function, the checker assigns `any` to the failed expression and continues. Every implicit `any` emits a warning. This means:

- One error doesn't cascade into 50 errors.
- The user sees where inference gave up.
- `any` warnings are a signal that code needs annotation or the checker needs improvement.

### Output formats

The checker supports multiple output formats:

- **Human-readable** (default): file:line: severity: message, with source context.
- **JSON**: structured output for editor integration and CI pipelines.
- **SARIF**: for GitHub code scanning and other static analysis tooling.

Machine-readable output is a first-class concern, not an afterthought. The checker is a tool that other tools consume.

### No strict mode — strict is the only mode

There is no `--strict` flag. The checker is always strict. Every implicit `any` is a warning. Every type error is an error.

If you're adopting crescent for an existing codebase, the path is:
1. Add annotations incrementally.
2. Fix errors as they appear.
3. Use `--[[as! T]]` for code that's genuinely too dynamic.

There is no "turn off the checker for this file" escape. The closest equivalent is annotating with `any`, which is visible and grep-able. The ecosystem does not have a loose mode because loose modes become the default — TypeScript proved this with `any`, `noImplicitAny`, `strict`, `strictNullChecks`, and the dozen other flags that exist because the default was too loose and tightening it broke the world.

We start tight. We stay tight.

### Generic constraints: structural, inline

Constraints on type parameters use the same structural types as everything else. No trait system, no interface declarations — a constraint is just a type:

```lua
--:: <T: number | string> Comparable = (T, T) -> boolean
--:: <T: { name: string }> Named = (T) -> string
```

`<T: C>` means "T must be assignable to C." Since crescent is structural, this works naturally — `<T: { x: number }>` means "any table with at least an `x: number` field." No need for Rust-style trait bounds or Haskell-style typeclasses. The constraint *is* the structure.

Multiple constraints compose with `&`: `<T: Readable & Closeable>` means T must satisfy both.

Prior art: Haskell's `HasField` typeclass is the closest analog — structural field constraints resolved automatically. But crescent doesn't need the typeclass machinery because structural typing is the default, not an opt-in extension.

### Overload resolution: best match

When a function has multiple signatures (union of function types), calls are resolved by **best match** — the most specific signature whose parameters are all satisfied:

```lua
--: ((number) -> string) | ((string) -> number)
local function convert(x) ... end

convert(42)      -- resolves to (number) -> string
convert("hello") -- resolves to (string) -> number
convert(true)    -- ERROR: no matching overload
```

Best-match avoids order-sensitivity bugs. If multiple overloads match equally, it's an error — the user must narrow the argument types. This is more predictable than first-match and gives the user more control.

### Variance: inferred, with invariance explicit

Variance is inferred from usage, not declared. The checker determines whether a generic parameter is used covariantly, contravariantly, or invariantly based on its positions in the type:

- Return position → covariant
- Parameter position → contravariant
- Both → invariant
- Mutable field → invariant

Explicit variance annotations are not needed for most code. If the inferred variance is wrong, the user sees it as a type error at the use site — which is the right place to catch it.

**Invariant choice types** are a distinct concept: a value that is *one of* several types but you don't know which. This is what unions (`A | B`) express. The key property is that a `[A | B]` array can *contain* both A and B values, but you can't assume any particular element is A without narrowing. This is sound — unlike TypeScript's unsound covariant arrays.

### Inline privacy annotations

Private fields can be annotated inline at the binding site using `--: private`:

```lua
local Session = {
  id = generate_id(),            --: string
  socket = connect(host, port),  --: private cdata
}
```

This is sugar — equivalent to declaring `--:: Session = { id: string, private socket: cdata }` separately. It's there for convenience when the type declaration would be redundant with the implementation. The `--::` form in a type declaration is the canonical form; `--: private T` on a field is the inline shorthand.

### String pattern types

`string.match`, `string.gmatch`, and `string.gsub` return types depend on capture groups in the pattern string. This is worth modeling — it's a common source of bugs (wrong number of captures, nil from non-matching optional groups).

This is implemented as a checker module, not core functionality. The module analyzes string literal patterns passed to string functions and computes return types from capture groups. Non-literal patterns fall back to `string?` returns.

### Coroutine typing: effects as future work

Coroutine typing is fundamentally about effects — `yield` is an effect that suspends computation and produces a value. The full design (effect types, effect handlers) is a significant extension that deserves its own design document.

For now: `coroutine.wrap(f)` returns `(...) -> any`, and `coroutine.resume` returns `(boolean, any)`. This is the `any` boundary — correct but imprecise. Effect typing is future work.

### Tuple subtyping: structural, no magic

Tuples and arrays are distinct types. A tuple `{ number, string }` is *not* a subtype of `{ [number]: number | string }`. If a function expects an array, it expects homogeneous, variable-length data. A tuple is heterogeneous, fixed-length data. They don't mix.

Library authors who want to accept both should make their functions generic over indexable tables. The checker doesn't insert implicit coercions — if the types don't line up, annotate or restructure.

### Recursive types: equi-recursive with lazy expansion

Equi-recursive: a recursive type `mu X. T` *is* its unfolding. No explicit fold/unfold coercions. The checker compares recursive types coinductively — walk both sides in lockstep, track "currently comparing" pairs, and if you revisit a pair already in the set, they're equal.

This is the right choice for structural HM:
- Iso-recursive requires explicit fold/unfold, which is undecidable to infer in HM. Not an option.
- Equi-recursive is what OCaml (`-rectypes`), TypeScript, and Flow use. Proven at scale.
- Lazy expansion (expand on demand, memoize) avoids infinite expansion while keeping the equi-recursive semantics.

Implementation: store recursive types as thunks. Physical equality on unification variable representatives short-circuits most comparisons before the seen-set is even consulted. Maintain a separate blame trail for error messages — don't rely on the cycle-breaking point for error context.

```lua
--:: List<T> = { head: T, tail: List<T>? }
-- This Just Works. No special syntax for recursion.
```

### Type-level computation: declarative, not imperative

TypeScript's mapped types, conditional types, and template literal types are powerful but create an imperative type language that the checker can't reason about bidirectionally. Zig's comptime is the extreme end — the type system *is* a programming language, and type errors become runtime debugging.

Crescent rejects imperative type-level computation. Not because of Turing-completeness (that's a theoretical concern) — but because imperative type constructs are **opaque to the checker**. It can evaluate them forward but can't unify backwards through them. A type expression should be something the checker can reason about in both directions — and something a human can read without mentally executing a program.

#### The design space

Type-level operations fall into distinct categories. TypeScript unifies most of these under "mapped types" — one flexible syntax that can do everything. Crescent separates them because they're conceptually different and compose differently:

**Intrinsics** — compiler-supported, `$` prefix, declared as `= intrinsic` in prelude. `$` means "compiler magic, not user-definable." If it has `$`, the compiler implements it. If it doesn't, you can read the definition:
- `$EachField<T, F>` — apply F to each field of T (F receives a field descriptor)
- `$EachUnion<T, F>` — apply F to each member of union T, re-union results
- `$Keys<T>` — string literal union of a record's keys
- `T[K]` — indexed access, look up a field's type by key (syntax, not `$`-prefixed)
- `F(Args...)` — call a function type, resolve overloads, return the return type (syntax, not `$`-prefixed)

`$EachField` is the key primitive — it iterates over fields, passing each as a `{ key: K, value: V, optional: boolean, readonly: boolean }` descriptor to the user-defined transform F. The transform is a regular type-level function (match or simple generic). `$EachField` collects the transformed field descriptors back into a table type.

**Everything else is user-definable** in the prelude using match + intrinsics:

```lua
-- Modifier toggles:
--:: MakeOptional<F> = match F {
--::   { key: K, value: V } => { key: K, value: V, optional: true },
--:: }
--:: Partial<T> = $EachField<T, MakeOptional>
--:: Required<T> = $EachField<T, MakeRequired>
--:: Readonly<T> = $EachField<T, MakeReadonly>
--:: Mutable<T> = $EachField<T, MakeMutable>

-- Value transforms:
--:: UnwrapSchema<F> = match F {
--::   { key: K, value: Schema<V> } => { key: K, value: V },
--::   F => F,
--:: }
--:: Infer<T> = $EachField<T, UnwrapSchema>

-- Key filters:
--:: KeepKey<Allowed><F> = match F {
--::   { key: K } => match K {
--::     Allowed => F,       -- keep if key is in Allowed
--::   },
--:: }
--:: Pick<T, K> = $EachField<T, KeepKey<K>>
--:: Omit<T, K> = $EachField<T, DropKey<K>>

-- Union filters:
--:: Extract<T, U> = $EachUnion<T, KeepIfAssignable<U>>
--:: Exclude<T, U> = $EachUnion<T, DropIfAssignable<U>>

-- Function type queries (match destructures functions — no intrinsic needed):
--:: Params<F> = match F { (...P) -> any => P }
--:: Return<F> = match F { (...Array<any>) -> R => R }

-- Convenience (sugar over $EachField):
--:: EachValue<T, F> = $EachField<T, ApplyToValue<F>>
--:: EachKey<T, F> = $EachField<T, ApplyToKey<F>>
```

**Composition is just function composition.** "Make fields `a` and `b` optional, keep the rest required" is:
```lua
--:: PatchUser = { ...Partial<Pick<User, "name" | "email">>, ...Omit<User, "name" | "email"> }
```
No special composition mechanism — spread (`...`) and the existing transforms.

#### Motivating use cases

**PATCH endpoint — some fields optional, rest required:**

```lua
--:: User = { id: string, name: string, email: string, role: string }

-- PATCH only allows updating name and email:
--:: PatchUser = { ...Partial<Pick<User, "name" | "email">>, ...Omit<User, "name" | "email"> }
-- = { id: string, name?: string, email?: string, role: string }

--: (string, PatchUser) -> User
local function update_user(id, patch) ... end
```

**Runtime schema → static type (Zod-style):**

```lua
--:: UnwrapSchema<F> = match F {
--::   { key: K, value: Schema<V> } => { key: K, value: V },
--::   F => F,
--:: }
--:: Infer<T> = $EachField<T, UnwrapSchema>

local user_schema = schema.object({
  name = schema.string(),
  age = schema.optional(schema.number()),
})
-- user_schema: Schema<{ name: string, age?: number }>
-- Infer<typeof user_schema> = { name: string, age?: number }

-- Validate at API boundary, get typed result:
local user = user_schema:check(request.body)
-- user: { name: string, age?: number }
```

**API response projection — strip internal fields before serialization:**

```lua
--:: InternalUser = { id: string, name: string, email: string, password_hash: string, role: string }

--:: PublicUser = Omit<InternalUser, "password_hash">
-- = { id: string, name: string, email: string, role: string }

--: (InternalUser) -> PublicUser
local function to_public(user)
  return { id = user.id, name = user.name, email = user.email, role = user.role }
end
```

**Readonly config — freeze after initialization:**

```lua
--:: Config = { host: string, port: number, debug: boolean }
--:: FrozenConfig = Readonly<Config>

--: (Config) -> FrozenConfig
local function freeze_config(c) return c --[[as FrozenConfig]] end

local cfg = freeze_config({ host = "localhost", port = 8080, debug = false })
cfg.port = 9090  -- ERROR: cannot assign to readonly field
```

**Deep transform — recursive via match:**

```lua
--:: DeepReadonly<T> = match T {
--::   { key: K, value: V } => { key: K, value: DeepReadonly<V>, readonly: true },
--::   T => T,
--:: }
-- Applied via $EachField for table types, identity for primitives
```

**Middleware wrapper — transform function signatures:**

```lua
--:: AddContext<F> = match F {
--::   (ctx: Context, ...P) -> R => (...P) -> R,
--:: }
-- Strips the first Context param, curried by middleware:

--: (handler: (Context, Request) -> Response) -> (Request) -> Response
local function with_context(handler)
  return function(req) return handler(create_context(), req) end
end
```

#### Function type calls and distribution

`F(Args...)` calls a function type — resolves overloads (picks the best-matching branch) and returns the return type. This is syntax, not a `$`-prefixed intrinsic, because it mirrors Lua's call syntax:

```lua
--:: F = (number) -> string
F(number)                    -- string

--:: G = ((number) -> string) | ((string) -> number)
G(number)                    -- string (picks matching overload)
G(string)                    -- number
```

**`$EachUnion` makes transforms safe on union types.** When a transform needs to process each union member independently (preserving pairings), use `$EachUnion` explicitly:

```lua
--:: Promisify<F> = (...Params<F>) -> Promise<Return<F>>

--:: G = ((number) -> string) | ((string) -> number)
--:: H = $EachUnion<G, Promisify>
-- Applies Promisify to each branch independently:
--   Promisify<(number) -> string> | Promisify<(string) -> number>
--   = ((number) -> Promise<string>) | ((string) -> Promise<number>)
-- Pairing preserved.
```

Distribution is explicit via `$EachUnion`, not automatic. `Params` and `Return` are match-defined in the prelude — they destructure a single function type. For union function types, wrap with `$EachUnion` so each branch is processed independently.

#### Parameter names

Function parameter names are **preserved for tooling but not structural**. Two function types with different parameter names but same positional types are the same type. The checker remembers names for error messages, hover types, and autocomplete — but they don't affect assignability.

#### Static types from runtime schemas

`--::` annotations are comments — they don't exist at runtime. Runtime validation needs actual runtime values that describe types. Rather than trying to share syntax between static and runtime systems, the approach is **runtime-first**: define schemas as runtime values, and the static checker infers types from them.

```lua
local t = schema.object({
  name = schema.string(),
  age = schema.optional(schema.number()),
})
-- Runtime: t:check(data) validates at boundaries
-- Static: checker infers t's validated type as { name: string, age?: number }
```

This is the Zod/ArkType model: write the schema once as real code, get both runtime validation and static types. The "shared language" isn't shared syntax — it's the checker understanding the runtime schema library's type signatures deeply enough to compute the corresponding static type from schema constructor calls. Zod does this in TypeScript via `z.infer<typeof schema>`. Crescent's version would be the checker recognizing `schema.object({ ... })` patterns and computing the static type directly — no `$Infer` needed if the checker is smart enough.

This is the primary consumer of type transformations. API boundaries need `Partial` (PATCH endpoints), `Pick` (projections), `Omit` (stripping internal fields before serialization). The transformations should be driven by what real validation and serialization code needs, not by what TypeScript happens to offer.

#### Type-level match

A generic type declaration is a type-level function. Match arms define how it dispatches on input types:

```lua
--:: ToString<T> = match T {
--::   number => string,
--::   boolean => "true" | "false",
--::   [U] => [ToString<U>],
--:: }

ToString<number>   -- string
ToString<boolean>  -- "true" | "false"
ToString<[number]> -- [string]
```

This is the same concept as overload resolution — pattern match on inputs, produce an output. The difference is scope: overloads match on function argument types (value-level dispatch), match matches on type parameters (type-level dispatch). The checker machinery is the same: structural pattern matching, captured type variables, best-match selection.

**Properties:**
- **Invertible**: each arm is a pattern → result pair. The checker can work backwards.
- **Exhaustiveness-checkable**: missing cases are errors.
- **Best-match**: no ordering dependency. Ambiguous matches are errors.
- **Structural destructuring**: patterns bind type variables from structure (`[U]` captures the element type, `(A) -> B` captures params and return).

**Application is just syntax.** Generic instantiation is `F<Args>`. Function type calls are `F(Args)`. Every generic type is a type-level function — simple generics have a direct substitution body, match generics dispatch on structure:

```lua
-- Direct body (no dispatch)
--:: Pair<A, B> = { first: A, second: B }
Pair<number, string>    -- { first: number, second: string }

-- Match body (structural dispatch)
--:: Unwrap<T> = match T {
--::   Promise<U> => U,
--::   T => T,
--:: }
Unwrap<Promise<string>> -- string

-- Function type call (overload resolution)
--:: Format = ((number) -> string) | ((boolean) -> "true" | "false")
Format(number)          -- string
```

**Builtins as match.** The `$`-prefixed type queries are instances of match, some builtin for performance and error quality:

```lua
-- $Return is match on function structure
--:: $Return<F> = match F {
--::   (...Array<any>) -> R => R,
--:: }

-- $Keys is match on table structure
--:: $Keys<T> = match T {
--::   { ...fields } => keyof fields,
--:: }
```

They're not conceptually special — they're common patterns that deserve dedicated error messages and optimized paths. User-defined matches use the same mechanism.

**Distribution still applies.** When a match receives a union, it distributes: each union member is matched independently, results are re-unioned. This keeps match arms simple — they never see unions.

**Prior art.** The individual pieces are proven — what's new is the combination targeting a dynamically-typed language:

- **Scala 3 match types** (2020): the closest direct analog. Structural pattern matching at the type level, with reduction semantics. Main pain point: interaction with Scala's subtyping and path-dependent types creates edge cases. Crescent's simpler type system (no path-dependence, no higher-kinded types, no implicits) has less surface area for those issues.
- **Haskell closed type families** (GHC 7.8, 2014): type-level functions with pattern matching, proven at scale for 10+ years. First-match semantics (crescent uses best-match). Non-injective by default; injectivity annotations are opt-in. Demonstrates that type-level match is tractable in practice.
- **C++ SFINAE / concepts** (SFINAE: C++98, concepts: C++20): "Substitution Failure Is Not An Error" — try each candidate, silently skip failures. The semantic model crescent's overload resolution uses. C++ arrived here accidentally through template metaprogramming; concepts cleaned up the syntax 22 years later.
- **OCaml GADTs** (OCaml 4.00, 2012): pattern matching that refines types in branches. Value-level, but the same bidirectional inference — matching a GADT constructor tells the checker what the type parameter must be. The reasoning model crescent's match should support.
- **TypeScript conditional types** (TS 2.8, 2018): the cautionary tale. `T extends U ? A : B` is expedient but imperative — opaque to inference, composes into unreadable nested chains, Turing-complete when recursive. Got there first for "type a dynamic language," and now it's load-bearing infrastructure that can't be changed. Crescent has the luxury of starting fresh.

Nobody has combined structural types + match-as-primitive + distribution + SFINAE-style overloads + bidirectional inference into one coherent system for a dynamically-typed language. Each piece is well-understood; the bet is that the combination works.

#### Constraint inference and deferred checking

Three modes for generic constraints, chosen by how you write the generic:

**Explicit constraint** — checked standalone against the body. Errors at definition site. Guarantees the body works for all valid inputs:

```lua
--:: <T: { name: string }> GetName = (T) -> string
-- Body checked once against the constraint. Call sites only verify T satisfies it.
```

**No constraint** — inferred from the body. Same standalone guarantees, less boilerplate. Structural inference extracts what the body actually uses:

```lua
-- No constraint written:
local function get_x(t) return t.x end
-- Inferred: <T> ({ x: T, ... }) -> T
-- The constraint IS the usage, extracted automatically.
```

**Match arms** — SFINAE-style deferred dispatch. Each arm is standalone-checked, but which arm applies is deferred to the call site. Failed arms are silently skipped:

```lua
--:: Stringify<T> = match T {
--::   { name: string } => T["name"],
--::   number => string,
--:: }
-- Each arm is checked independently. At the call site,
-- the checker picks the matching arm. No match = error.
```

This covers the spectrum without flags or modes:
- Want documentation + guarantees? Write explicit constraints.
- Want less boilerplate? Omit constraints, let inference handle it.
- Want "try and see" dispatch? Use match — each arm is tried, failures are skipped.
- Want silent fallback at call sites? Overloaded function signatures — if one overload doesn't match, try the next.

The match arms and overload branches are each standalone-checked, so you never get the C++ problem of inscrutable errors deep inside a template body at a distant call site. Errors are either at the definition (constraint violation) or at the call site (no matching arm/overload) — never inside the generic's internals.

**Prior art: C++20 concepts.** Concepts are SFINAE made declarative — instead of relying on substitution failure as a side effect, you state what operations a type must support:

```cpp
template<typename T>
concept Addable = requires(T a, T b) {
    { a + b } -> std::convertible_to<T>;
};
```

The `requires` clause is "try this expression, check it's valid." Crescent's structural inference does the same thing automatically — `function add(a, b) return a + b end` infers "a and b must support `+`" without a separate declaration. The explicit constraint form `<T: { ... }>` is the analog of a named concept, but structural rather than nominal. C++ needs concepts declared separately because templates aren't checked standalone without them; crescent infers constraints from the body because structural typing makes usage self-documenting. Named constraints (`--:: Addable = ...` used as `<T: Addable>`) are available for documentation and reuse, but they're type aliases, not a separate concept system.

#### Why not conditional types?

TypeScript's `T extends U ? A : B` is imperative control flow at the type level. The problem isn't power or Turing-completeness — it's that conditional types are **opaque to unification**. The checker can evaluate them forward (given T, compute A or B) but cannot work backwards (given the result type, constrain T). They're black boxes that block inference, narrowing, and bidirectional type refinement.

This matters in practice. When a function's return type is a conditional type, the checker can't infer the argument type from a usage site. Error messages degrade to "conditional type didn't match" with no structural explanation. Composition of conditional types produces nested `extends` chains that are Turing-complete in theory and unreadable in practice.

**SFINAE** (C++ "Substitution Failure Is Not An Error") is closer to the right model: try each candidate, silently skip failures, pick the match. This is what crescent's overload resolution already does — best-match across union branches. `$EachUnion` processes each branch independently, and `F(Args)` resolves by trying substitution. The checker *can* reason backwards through this: if you know the return type, it constrains which overload branch was taken, which constrains the argument types.

If crescent needs conditional type logic beyond what distribution + overloads provide, the path is bounded pattern matching on type structure (Scala 3 match types, Haskell closed type families) — declarative dispatch that the checker can invert. Not an imperative if/else that turns the type system into a second runtime.

#### What we don't have
- **Template literal types** (`\`hello ${T}\``). Clever but niche. String pattern types (for `string.match` etc.) are handled by the pattern module, not by a general string computation mechanism.
- **Recursive type transforms.** Type transforms iterate over a finite key set. They do not recurse. This keeps type-level computation terminating and error messages comprehensible.
- **General mapped type syntax.** The `{ [K in U]: T }` iteration form is deferred. The builtin transformations (`Partial`, `Pick`, `Omit`, etc.) cover most use cases. A general-purpose iteration syntax will be designed when concrete use cases demand it, informed by real usage patterns rather than TypeScript precedent.

### Higher-kinded types: match + generic-type-as-bound

HKTs — abstracting over type constructors — fall out of existing machinery. Every generic type is a type-level function (via match). `F<Args>` applies them. A generic type used as a bound constrains the kind:

```lua
--:: T1<T> = any              -- kind: * -> * (most permissive bound at arity 1)
--:: T2<A, B> = any           -- kind: * -> * -> *

--:: Lift<F: T1, A> = F<A>
-- F must be a single-param type constructor

--:: MakeOptional<T> = T?
Lift<MakeOptional, number>    -- number? (MakeOptional is * -> *)

-- Tighter bound: F must produce something with a value field
--:: Wrapper<T> = { value: T }
--:: LiftW<F: Wrapper, A> = F<A>
```

No new syntax. Arity is structural — the bound's parameter count IS the kind. `T1<T> = any` is the most permissive bound because `any` is the top type (everything is a subtype).

**Type constructor variance** is non-trivial (contravariant inputs interact with constrained constructors), but the pragmatic resolution for v1: HKT bounds are **arity-matching + constraint propagation**, not full subtype checks between constructors. The bound's arity determines the kind, and at instantiation sites the actual type constructor's own constraints are checked against the concrete arguments. This sidesteps constructor variance entirely and defers the real checking to where it matters.

Not in v1, but no design changes needed to add it later — the machinery is already there.

### `newtype` conversion: constructor pattern, not syntax

`newtype` is purely static — no runtime wrapping/unwrapping. A `UserId` IS a `number` at runtime. The recommended pattern is a constructor function that contains the single force cast:

```lua
--:: newtype UserId = number

--: (number) -> UserId
local function UserId(n) return n --[[as! UserId]] end

local id = UserId(42)    -- clean call site
local n = id --[[as number]]  -- explicit unwrap when needed
```

The `as!` blast radius is contained to one line in the constructor. No special conversion syntax needed — it's a regular function.

### Performance: LuaJIT-first, Rust escape hatch

The checker is written in LuaJIT because that's the ecosystem. But performance is a hard constraint: if the checker can't stay within ~2x of equivalent Rust performance on realistic codebases, rewrite the hot paths (or the whole thing) in Rust.

LuaJIT's JIT gives us a real shot — tight loops over tables with predictable shapes are exactly what the trace compiler optimizes. But we measure, not hope. Benchmarks are part of the test infrastructure.

### Manifest: `crescent.type.toml`

The type checker's manifest is separate from the (future) package manager's manifest. It lives in `crescent.type.toml` at the project root:

```toml
# Module path overrides
[paths]
"lib.foo" = "vendor/foo/init.lua"

# External type stubs
[stubs]
"lpeg" = "types/lpeg.d.lua"

# Package.path additions (beyond defaults)
[search]
paths = ["vendor/?.lua", "vendor/?/init.lua"]
```

Exact format TBD — this is the shape, not the spec. The manifest is optional; the checker works without one by following `package.path`.

### Standard prelude

The checker loads a prelude before checking user code — type aliases and stdlib signatures that are always in scope. The prelude is not magic; it's a `.d.lua` file (or set of files) written in the same annotation syntax as everything else. The checker just loads it first.

**Common type aliases:**

```lua
--:: Array<T> = { [number]: T }
--:: Dict<K, V> = { [K]: V }
--:: Map<K, V> = { [K]: V }          -- alias if preferred
--:: Set<T> = { [T]: boolean }
--:: Optional<T> = T?                 -- explicit form of T | nil
```

**Intrinsics** (`$` prefix = compiler magic, declared as `= intrinsic`):

```lua
--:: $EachField<T, F> = intrinsic     -- apply F to each field of T
--:: $EachUnion<T, F> = intrinsic     -- apply F to each union member
--:: $Keys<T> = intrinsic             -- string literal union of record keys
-- T[K] (indexed access) and F(Args) (function type call) are intrinsic syntax
```

**Type transforms** (user-defined via match + intrinsics, no `$`):

```lua
--:: Partial<T> = $EachField<T, MakeOptional>
--:: Required<T> = $EachField<T, MakeRequired>
--:: Readonly<T> = $EachField<T, MakeReadonly>
--:: Mutable<T> = $EachField<T, MakeMutable>
--:: Pick<T, K> = $EachField<T, KeepKey<K>>
--:: Omit<T, K> = $EachField<T, DropKey<K>>
--:: Extract<T, U> = $EachUnion<T, KeepIfAssignable<U>>
--:: Exclude<T, U> = $EachUnion<T, DropIfAssignable<U>>
--:: Params<F> = match F { (...P) -> any => P }
--:: Return<F> = match F { (...Array<any>) -> R => R }
```

**Stdlib signatures are prelude files, not hardcoded.** The checker ships with prelude files for each target:

```
lib/type/static/prelude/
  core.d.lua          -- common aliases (Array, Dict, etc.)
  transforms.d.lua    -- Partial, Pick, Omit, etc.
  lua51.d.lua         -- Lua 5.1 stdlib (string, table, math, io, os, ...)
  lua54.d.lua         -- Lua 5.4 stdlib (integer semantics, utf8, ...)
  luajit.d.lua        -- LuaJIT extensions (ffi, bit, jit, ...)
```

The manifest selects which preludes to load:

```toml
[prelude]
target = "luajit"                     # loads core + transforms + lua51 + luajit
extra = ["types/my_globals.d.lua"]    # project-specific globals
```

Multiple targets are composable — `target = ["lua51", "luajit"]` loads both. Projects can add arbitrary `.d.lua` files to the prelude for project-wide type declarations. The prelude is just "files loaded before everything else" — no special mechanism.

This means:
- Stdlib types are auditable and overrideable — they're files, not hardcoded tables.
- Supporting a new Lua version is adding a `.d.lua` file, not modifying the checker.
- Projects can declare global types without scattering `--::` across files.
- `$`-prefixed types are intrinsics — compiler-supported, declared as `= intrinsic` in prelude files. The `$` prefix is the rule: if it has `$`, the compiler implements it and users can't redefine it. If it doesn't have `$`, it's user-defined and you can read the source. Same pattern as TypeScript's `intrinsic` keyword, but with a visible naming convention.

## v2 Checker Architecture

Design insights for the v2 checker implementation. The v2 front-end (lexer,
parser, annotation parser) is complete. These notes inform the back-end:
constraint generation, solving, and error reporting.

### It's a constraint solver, not a type checker

The traditional framing — "infer types, then check them" — is misleading.
Types ARE constraints. `number` is a constraint ("must be a number").
`{ x: number }` is a constraint ("must have field x satisfying the number
constraint"). `$EachField<T, P>` is a constraint ("every field must satisfy
P"). There is no ontological difference between "a type" and "a predicate on
types." They're all constraint expressions of varying complexity.

The checker is a constraint solver:
1. Walk the AST, generate constraints
2. Propagate constraints (unification, pattern matching, quantifier expansion
   — all the same engine)
3. Unsatisfied constraints are errors

No separate "type evaluation" mode. No special path for match types. One
engine, one loop.

### Unification (equality) is the base, subtyping is a relaxation

TypeScript's fundamental operation is `T extends U` — subtyping, one direction.
This makes exact equality nearly inexpressible (see: the `IsEqual` hacks, the
`oneof` requests, the validator pattern). People build Rube Goldberg machines
to recover what unification gives for free: `T = U`.

Our system is built on unification. Equality is the primitive. Subtyping is a
relaxation we add on top (structural compatibility for tables, union
membership). The programmer can reach both.

### Two constraint operators

Instead of debating "exact vs structural by default," give users both:

- `T: U` — T satisfies U (subtyping, structural compatibility)
- `T = U` — T equals U (unification, exact match)

`<T: X>` is sugar for `<T where T: X>`. The `where` clause is where the
constraint language lives:

```
-- Subtyping (default for most parameters):
<T: Serializable>(data: T) -> string

-- Equality (when you need exact match):
<T where T = boolean | null>(done: T) -> void

-- Relationships between parameters:
<T, U where T: U>(sub: T, sup: U) -> void

-- Compound constraints:
<T where T: Readable, T: Closeable>(resource: T) -> void
```

This dissolves several TypeScript pain points:
- **`$Exact`**: not needed. Use `=` constraint instead of `:` constraint.
- **Validator pattern**: not needed. Write the constraint directly.
- **`oneof`**: not needed. `foreach` over union members with `=` constraints.

### Bidirectional flow

TypeScript's inference is fundamentally bottom-up: infer the argument's type,
then check it against the expected type. Information flows one way. The
`unknown extends T` validator pattern is a hack to force information downward.

Our system uses bidirectional unification. Constraints flow in whatever
direction has information. When a function expects `T where T = A | B | C`,
the expected type flows DOWN into the argument — the checker asks "which of
A, B, C does this match?" rather than inferring the argument independently and
checking afterward.

This means:
- The validator pattern is free — expected types naturally constrain arguments.
- Partial inference works — known type params constrain unknown ones.
- Match types participate in inference — they're constraints, not evaluation
  steps.

### Match types are the intentionally Turing-complete core

TypeScript is Turing-complete by accident (conditional + mapped + recursive
types interacting). We do it on purpose with a minimal core:

- **Pattern matching** on type structure (match types)
- **Recursion** (recursive type aliases)
- **Binding** (type variables captured during pattern matching)

One mechanism, not ten. Everything TypeScript does with conditional types,
mapped types, template literal types — those are patterns expressible in
match/recurse/bind.

The key property of match over conditional types: **match types are
bidirectional.** Pattern matching works through unification, which propagates
constraints both ways. Conditional types are imperative (evaluate forward,
opaque backwards). This is why we have match types and not conditional types —
not because match is "more general," but because it participates in the
constraint solver naturally instead of requiring a separate evaluation engine.

### `foreach` as overload generation

The TypeScript community's `oneof A | B | C` concept — "the value must be
exactly one of these, not a subtype" — is expressible as overload generation:

```
--[=[:<foreach T where T = A | B | C>(arg: T) -> [T]]=]
```

Expands to three overloads:
```
(arg: A) -> [A]
(arg: B) -> [B]
(arg: C) -> [C]
```

Each overload uses equality constraints (via `=`), so subtypes are rejected.
`foreach` iterates explicitly — no surprise distribution like TypeScript's
naked type parameter behavior. If `A` is itself a union `X | Y`, T binds to
`X | Y` as written — no flattening.

This is sugar over overloads, not a new primitive. The core doesn't grow.

### Open tables by default

Lua is duck-typed. Tables are bags of fields. The `M = {}; M.foo = ...`
pattern means tables are built incrementally — inherently open. Closed-by-default
would fight the language.

Existing design (from above): `...` row variable means open, absence means
closed. APIs that accept input should be open. Data definitions can be closed.

Exactness at usage sites is handled by `=` constraints in `where` clauses,
not by `$Exact<T>` type modifiers. `$Exact` conflates definition with usage —
the same type should be open in some contexts and exact in others.

### Existential quantification

TypeScript only has universal quantification (`<T>` = "for all T"). It has no
way to say "there exists some type T such that this holds." The validator
pattern partly hacks around this — it captures T to manipulate it
imperatively, which is reaching for existential binding.

Our `opaque` types are module-level existentials: the implementing module knows
the concrete type, consumers see an abstract type. The open question is whether
to generalize existentials below module level — e.g., type-erased callbacks,
heterogeneous containers.

### What this means for the v2 checker implementation

The v2 checker is a constraint solver operating on flat TypeSlot arenas:

1. **Constraint generation**: walk ASTNode arena, emit constraints into a
   constraint pool (equality constraints from unification, subtyping
   constraints from assignments, pattern constraints from match types)
2. **Constraint solving**: propagate until fixpoint. Union-find for equality.
   Structural matching for subtyping. Pattern matching for match types.
   Intrinsic expansion for quantified constraints ($EachField, $EachUnion).
3. **Error reporting**: unsatisfied constraints become diagnostics.

The solver doesn't distinguish "type evaluation" from "type checking" — it's
all constraint propagation. Match types, generics, structural typing — all
just constraints fed to the same engine.

**Open design questions for implementation:**
- Constraint representation in the flat-slot model (new arena? inline in TypeSlots?)
- Solving order / worklist algorithm
- How `where` clauses lower to constraints
- Interaction between equality and subtyping constraints on the same variable
- Error blame tracking through constraint propagation

## Open Questions

Genuinely unresolved — needs dedicated design work:

- ~~**Tuples vs records syntax.**~~ Resolved: three distinct constructs with no ambiguity:

  Tuples, arrays, and records are all table types — one bracket syntax (`{}`):
  ```lua
  { number, string }                     -- tuple (fixed, heterogeneous)
  { [number]: string }                   -- array (variable, homogeneous)
  { x: number, y: number }              -- record (named fields)
  { number, string, name: boolean }      -- hybrid (positional + named)
  { number, string, [number]: boolean }  -- tuple prefix + array tail
  ```

  Function types use `()` because that's Lua call syntax — parens are function syntax, not a separate type constructor. Parameter names live in function signatures only:
  ```lua
  (host: string, port: number) -> Connection
  ```

  `$Params<F>` returns a tuple with names as internal metadata. When spread back into a function signature, names are restored:
  ```lua
  --:: F = (host: string, port: number) -> Connection
  --:: P = $Params<F>         -- { string, number } (names preserved internally)
  (...P) -> void              -- (host: string, port: number) -> void
  ```

  **Spread (`...`) is one unified operation** — "splice this type's contents here." The type being spread determines semantics:
  ```lua
  -- Positional spread (tuples):
  --:: P = { string, number }
  { boolean, ...P, integer }          -- { boolean, string, number, integer }

  -- Vararg spread (arrays):
  (string, ...Array<any>) -> string   -- like Lua's (string, ...)

  -- Field spread (records, last wins on conflicts):
  --:: Base = { x: number, y: number }
  { ...Base, y: string, z: boolean }  -- { x: number, y: string, z: boolean }

  -- Param list spread:
  (...$Params<F>, timeout: number) -> void
  ```

  Spread is distinct from intersection (`&`). Spread merges with override (last wins). Intersection constrains (conflicts are errors):
  ```lua
  { ...Base, y: string }              -- y becomes string (override)
  Base & { y: string }                -- ERROR: number & string (conflict)
  ```

  Mirrors how `...` works in Lua value-level table constructors — positional entries go by position, named entries go by name.
- **Coroutine effects.** Full effect system design for yield/resume typing. See [effects.md](./effects.md) for the design exploration. Three levels: simple `Coroutine<Y, S, R>` (covers iterators), per-yield-point typing (needed for async/CPS), and full algebraic effects (most general). The async/CPS pattern is the primary motivator — it's crescent's concurrency model.
- ~~**Type transformation composition.**~~ Resolved: `$EachField<T, F>` and `$EachUnion<T, F>` are the two iteration intrinsics. The transform F is a regular type-level function (match or simple generic) that receives a field descriptor `{ key, value, optional, readonly }`. All transforms (`Partial`, `Pick`, `Omit`, etc.) are user-definable in the prelude. Composition is spread + existing transforms, no special mechanism.
- ~~**Match recursion bounds.**~~ Resolved: no arbitrary depth limit. The primary mechanism is **cycle detection** — the checker tracks `(match-type, input-type)` pairs during expansion. If it revisits the same pair, it's a cycle. Structural recursion (input shrinks each step) terminates naturally. Growing or unchanged inputs are flagged as divergence. A configurable depth limit (default high, ~1000) exists as a safety net, not the primary mechanism. Prior art: Haskell's fixed 201 limit is arbitrary and frustrating; smart detection is better.
- ~~**User-defined type transforms.**~~ Resolved: fields are types (descriptors with key, value, metadata). Match destructures them. `$EachField` iterates. Users define transforms as regular type-level functions — no privileged intrinsics for `Partial`, `Readonly`, etc.
