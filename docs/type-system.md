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

### 2. Tables are structural, not nominal

Lua tables are the only compound data structure. Two tables with the same shape are the same type:

```lua
--:: Point = { x: number, y: number }
local p = { x = 1, y = 2 }  -- p is a Point, no declaration needed
```

This is the natural fit for Lua. Nominal typing (requiring `Point.new()`) would fight the language. Structural typing works *with* it.

Row polymorphism keeps tables open when they need to be:

```lua
-- This function works on any table with an `x` field:
local function get_x(t) return t.x end
-- Inferred: [T] ({ x: T, ... }) -> T
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

### 8. Errors are precise, not noisy

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
(string, ...any) -> string          -- varargs
(string) -> (number?, string?)      -- multi-return
```

Parameters are contravariant, returns are covariant. This is standard.

### Tables

Tables are the universal compound type. A table type has:
- **Named fields**: `{ x: number, y: number }` — known keys with known types.
- **Indexers**: `{ [string]: number }` — dynamic keys. `[number]` for arrays, `[string]` for dictionaries.
- **Row variable**: open vs. closed. Open tables accept extra fields. Closed tables don't.

`[T]` is sugar for `{ [number]: T }`. `T?` is sugar for `T | nil`.

### `any` and `never`

`any` is the top-and-bottom type for gradual typing. `never` is the true bottom — the type of `error()` and unreachable code.

## Non-Goals

- **Typing all Lua programs.** Code not written for the type system may not type-check. That's fine.
- **TypeScript compatibility.** EmmyLua and LuaLS exist. Crescent's annotation syntax is purpose-built.
- **Completeness.** The checker will have gaps. Better to be correct on 90% of code than hand-wavy on 100%.
- **Runtime overhead.** The checker is purely static. Zero runtime cost. The runtime schema validator (`lib/type/check.lua`) is a separate, complementary tool.

## Decisions

Resolved design choices.

### Generics: `<T>` syntax, not `[T]`

`[T]` for type parameters conflicts with `[T]` for array types. `[number]` is "array of number" — it can't also mean "generic parameterized by number." Use angle brackets for generics:

```lua
--:: Result<T, E> = { ok: T } | { err: E }
Result<number, string>

-- Array types remain bracket syntax:
[number]      -- array of number
number[]      -- also array of number (suffix form)
```

This is unambiguous. `<T>` is generics, `[T]` is arrays. No parsing conflict.

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

## Open Questions

Genuinely unresolved — will be decided through implementation experience:

- **Generics type parameter constraints.** `<T: number | string>` for bounded generics — what's the constraint syntax? How do constraints interact with structural typing?
- **Tuple types vs. array types.** Is `{ number, string, boolean }` a tuple (fixed length, heterogeneous) or sugar for something else? How do tuples interact with `ipairs` and `#`?
- **Overload resolution.** When a function has multiple signatures (`((number) -> string) | ((string) -> number)`), how are calls resolved? First match? Best match? Error on ambiguity?
- **Variance annotations.** Should the user be able to declare a generic parameter as covariant or contravariant? Or is inference sufficient?
- **String pattern types.** `string.match` and `string.gmatch` return types depend on capture groups in the pattern. Is this worth modeling?
- **Coroutine typing.** `coroutine.wrap` returns a function whose return type depends on the coroutine's yields. How to model `yield`/`resume` types?
