# FFI Types — Design State

State of the typing for the LuaJIT `ffi` module in `lib/type/static/stdlib_types.lua`.

## Resolved

### `T` in `Cdata<T>` is a Lua type, not a C type string

The hidden inner type of `$Opaque<T>` should be a meaningful Lua type. Earlier
attempts using the C type string as `T` (`Cdata<"int">`, `Cdata<"int*">`) are
**wrong**: unsealing `Cdata<"int">` would give a Lua string `"int"`, not a C
integer. Also fragile — `"int*"` and `"int *"` are the same C type but
different string literals → incompatible nominal types.

`T` should be:
- `integer` for `int8/16/32_t`, `char`, `short`, `int`, `long`
- `number` for `float`, `double`
- `boolean` for `bool`
- `{ x: number, y: number }` for a Vec2 struct
- A user-declared opaque/newtype for nominal handles

### String paths must exist for ergonomics

`ffi.new("int32_t", 0)`, `ffi.new("uint8_t[256]")`, `ffi.new("struct Vec2", 1, 2)`
are the most common forms. Removing the string overload entirely makes valid
LuaJIT code a type error — too strict.

### The mapping from C name → Lua type must be user-extensible

`match S { "int32_t" => integer, ... }` doesn't work because `match` arms are
fixed at definition time — users can't add their own struct types.

The right mechanism: an **open augmentable table type** plus **type-level
indexed access**. Both built in this session:

```lua
--:: CTypeMap = {
--::   int8_t: integer,  uint8_t: integer,
--::   int32_t: integer, uint32_t: integer,
--::   float: number,    double: number,
--::   bool: boolean,
--::   ...   -- open
--:: }

-- in user code:
--:: augment CTypeMap { Vec2: { x: number, y: number } }
```

`T[K]` indexed access (commit `ca17ca5`) implements TypeScript's `T[K]` syntax
as a first-class type operation. Hard-error on miss. See
`lib/type/static/match.lua::lookup_index`.

### Constraint, not fallback

`<S: Keys<CTypeMap>>(ct: S, ...) -> CTypeMap[S]` is preferred over
`<S: string>(ct: S) -> match CTypeMap { { [S]: %V } => V, _ => unknown }`.
Unregistered C types error at the call site rather than silently returning
`Cdata<unknown>` / `unknown`. Forces users to declare types before use.

### Don't wrap primitives unnecessarily

LuaJIT auto-coerces primitive cdata with Lua values; struct cdata behaves like
its field-table. The Lua-side type IS the type. `ffi.new("int32_t", 0)` should
return `integer`, not `Cdata<integer>` — IF we don't need nominal distinction.

### `Ctype<T>` is a true opaque

You can't treat a ctype value as `T` (it's just a type descriptor). One-arg
`$Opaque<T>` is correct.

## Still open

### Newtype, not branded

`Cdata<T> = T & $Opaque<"Cdata">` (intersection-with-marker brand) was
implemented in commit `ffdb9b3`'s successor — **wrong**. Brands are a TS hack
because TS lacks proper newtype primitives. Crescent has `$Opaque` as a real
newtype mechanism. Use a newtype, not a brand.

Open question: how to express "newtype that exposes T's fields and is usable as
T (subtyping), but T isn't usable as the newtype." `$Opaque<T, T>` is
nominally invariant in both directions — neither `Cdata<integer>` is a subtype
of `integer` nor vice versa. That's wrong for cdata where you want
`Cdata<integer> <: integer` (usable as integer).

This needs a typechecker-level mechanism that's currently absent. Possibilities:
- `$Opaque<T, T>` made covariant in T (subtype-of-T direction only) — semantics
  change for all opaque users, probably wrong
- A new `$Newtype<T>` intrinsic — but CLAUDE.md forbids new `$` intrinsics
- Pattern-match-based recovery: figure out if there's a match expression that
  defines this directional subtyping
- Maybe the right answer is: don't introduce `Cdata<T>` at all, return T
  directly from `ffi.new`, and let users define their own newtypes when they
  want nominal distinction. The "branded for FFI provenance" goal is a non-goal.

### `int64_t` / `uint64_t` mapping

Currently mapped to `integer`. Wrong: in LuaJIT these stay as cdata and don't
coerce to Lua integer. `tonumber()` is lossy for values > 2^53. Need a distinct
representation — possibly self-mapping (`int64_t: int64_t`) once we have a real
newtype primitive, or an opaque alias.

### Too many `unknown` / `any` parameters

`sizeof: (ct: unknown)`, `cast: ..., obj: unknown`, `copy: (dst: unknown, src: unknown)`,
`string: (ptr: unknown)`, `istype: (ct: unknown, obj: unknown)` etc. are too
loose. Want a name for "any cdata" so we can write `dst: AnyCdata` etc.
Possible: introduce a brand-only marker `AnyCdataBrand = $Opaque<"Cdata">` and
use it for `dst`/`src`/`ptr` typing — but this depends on the newtype-vs-brand
question above. For `cast.obj`, the value being cast is genuinely polymorphic
(any cdata + numbers + strings + nil for some target types).

### `ffi.typeof(value)` route

If we don't define `Cdata<T>`, `ffi.typeof(some_cdata) -> Ctype<T>` can't be
typed (no Cdata<T> input pattern to match against). Currently:
`(<T>(ct: Ctype<T>) -> Ctype<T>) & (<S: Keys<CTypeMap>>(ct: S) -> Ctype<CTypeMap[S]>)`.
The "get ctype of a cdata value" use case is missing. May not matter — typeof
is mostly used with strings to cache ctypes.

## Behavioral lesson

This session: ~25 wrong attempts at the FFI types before getting close. Pattern
of failure: each time the user said "wrong" / "garbage", I tried a syntactic
variation instead of asking what semantic property was being violated. The
correct loop is:

1. User says X is wrong
2. State explicitly *why* X is wrong (semantic, not just "looks bad")
3. Ask if my reasoning matches theirs *before* trying a fix
4. Only then change code

Burned a lot of context tokens cycling through:
`<T: string>` → `unknown` → `any` → `Cdata<unknown>` → no string path →
`<T: string>` again → ...

The user explicitly said "why are you trying the WRONG thing" — the correction
was about **what to think about**, not about which type to write. When stuck
in a loop, ask what to think about, not what to write.
