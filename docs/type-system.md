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

Future work: a strict mode that forbids implicit `any` entirely.

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

## Open Questions

These are unresolved and will be decided through implementation experience:

- **Generics syntax.** `[T]` for type parameters reads naturally (`Result[number, string]`) but conflicts with array type syntax. May need revisiting.
- **Type narrowing in branches.** `if type(x) == "string" then ... end` should narrow `x` to `string` in the branch. How deep does this go? Just `type()` checks? `== nil`? Truthiness?
- **Metatype support.** How precisely to model `__add`, `__index`, `__call` etc. Full metatable typing is complex — may start with `__index` only and expand.
- **Module resolution.** Following `require()` across files means building a module graph. How to handle circular requires? Missing modules?
- **Error recovery.** When inference fails partway through a function, how much of the rest should be checked? Currently: assign `any` and continue. May want better.
- **Strict mode.** A mode where implicit `any` is forbidden — every binding must be inferable or annotated. Useful for library code.
