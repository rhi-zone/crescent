# Typechecker reference

Per-feature syntax and semantics of crescent's type annotation system. Not a
tutorial — this is the index you grep when you suspect a feature exists and
need to know how to spell it.

Every feature listed below is implemented, tested, and in active use. Before
claiming a feature is missing: write a 5-line repro and run
`timeout 30 bin/cr check <file>`. The default hypothesis on a surprising
result is "my repro is wrong" or "this is a typechecker bug" — not
"crescent doesn't support this." See the type-system rule in `CLAUDE.md`.

For design rationale (why the system is shaped this way) see
`docs/type-system.md`. For the soundness audit see `docs/soundness-audit.md`.

## Annotation syntax

```lua
local x --: integer                   -- inline: annotates the local declaration
--: (string, integer) -> boolean      -- function type (preceding line → applies to next expr/function)
-- To annotate params: use preceding-line function type (only supported form).
-- WARNING: `function(x --: string)` is INVALID — `--` starts a line comment, eating `)` and beyond.
-- WARNING: `function(x --[[: string]])` is also INVALID — block comment form is parsed as a cast, not a param annotation; silently ignored in param position.
--:: Foo = { name: string, age: integer }  -- type alias declaration
--:: declare x = integer              -- global variable declaration
--:: newtype UserId = integer         -- nominal newtype (not assignable to/from integer)
-- --:: module "mylib": { foo: string }  -- DO NOT USE in crescent source; require() return types are inferred from return M
--:: augment string { upper: () -> string }  -- merges fields into an existing type binding
--:: template                         -- marks next function as a generic template (advanced)
```

## Primitive types

```lua
--: integer   -- LuaJIT integer (32-bit range for literals; promotes to number ops)
--: number    -- any number (integer or float)
--: string
--: boolean
--: nil
--: never     -- bottom type; no value inhabits it; union member is dropped
--: unknown   -- top type; caller must narrow before use (like TS unknown)
--: any       -- opt-out of checking (like TS any); use only when explicitly documented why
--: cdata     -- LuaJIT FFI cdata value
```

## Literal types

```lua
--: "heading"    -- string literal type
--: 42           -- integer literal type (integer-valued floats auto-promoted)
--: 3.14         -- float literal type
--: true         -- boolean literal type
```

Literal types are subtypes of their base type: `42 <: integer <: number`.

## Table types

```lua
-- Closed record: exactly these fields
--: { name: string, age: integer }

-- Optional field (field may be absent or nil)
--: { name: string, age?: integer }

-- Readonly field
--: { readonly id: integer, name: string }

-- Open record: at least these fields; additional fields permitted
--: { name: string, ... }
-- Reading an unlisted field on { ..., ... } returns unknown (NOT the indexer type)

-- Index signature: any key of that type maps to the value type
--: { [string]: integer }
--: { [integer]: string }

-- Mixed: named fields + indexer
--: { [integer]: string, n: integer }

-- Array sugar (postfix [])
--: string[]            -- equivalent to { [number]: string }
--: Arr<string>         -- equivalent to { [integer]: string, ... } (stdlib alias)

-- Meta slots (metamethods)
--: { name: string, #__add: (self: unknown, other: unknown) -> unknown }

-- Meta-spread (inherit all meta slots from another type)
--: { name: string, #...MT }
```

`...` and `{ [K]: V }` are distinct. `{ name: string, ... }` does NOT mean any string key maps to any type — that is `{ [string]: unknown }`.

## Function types

```lua
--: () -> nil                        -- no params, no return
--: (string) -> integer              -- one param, one return
--: (string, integer) -> boolean     -- two params
--: (name: string, age: integer) -> boolean  -- named params (for predicate syntax)
--: (string, ...integer) -> nil      -- varadic: last param ...T means zero or more T
--: () -> (string, integer)          -- multiple returns
--: () -> ...(T)                     -- multi-return spread (T may be a tuple type alias)
--: string -> integer                -- right-associative bare arrow (curried sugar)
--: function                         -- any function (untyped)
```

Multi-return union: `(A) -> B | (C) -> D` parses as `(A) -> (B | (C) -> D)`. Wrap: `((A) -> B) | ((C) -> D)`.

## Union and intersection

```lua
--: string | nil          -- union (|)
--: A & B                 -- intersection (&): must satisfy both
--: (A -> nil) & (B -> nil)  -- overloaded function (intersection of functions)
```

Field access on union: only fields present in ALL members are accessible without narrowing.
Field access on intersection: a field present in ANY member is accessible.

## Generics

```lua
-- Basic generic function
--: <T>(T) -> T

-- Constrained generic (T must structurally satisfy the bound)
--: <T: { name: string, ... }>(T) -> T

-- Multiple type params
--: <T, U>(T, U) -> T

-- Generic alias with params
--:: Pair<A, B> = { first: A, second: B }

-- Generic alias with bounds and defaults
--:: MyAlias<T: Bound, U = string> = { key: T, val: U }
```

Type params are instantiated independently per call site. No explicit instantiation syntax — the checker infers from arguments.

## Casts

```lua
local x = expr --[[: T]]    -- checked cast: T must be a supertype of expr's type
local x = expr --[[:! T]]   -- force cast: overlap-checked; almost never correct.
                             -- If unknown: fix the upstream producer's type annotation.
                             -- If A|B → A: use a discriminant check; if that fails, fix the typechecker.
                             -- A force cast that substitutes for either is wrong.
-- --[[:! any]] is REJECTED. Use --[[: any]] if you genuinely need an any cast.
```

## Narrowing forms

All forms the checker recognizes in `if`/`while`/`repeat` test position:

```lua
if x then end                    -- nil_check: x is non-nil in truthy branch
if x ~= nil then end             -- nil_check (explicit)
if x == nil then end             -- nil_check (negative)
if type(x) == "string" then end  -- type_check: narrows to string
if type(x) == "number" then end  -- type_check: narrows to number
if type(x) == "table" then end   -- type_check: narrows to table type
if x == "literal" then end       -- lit_eq: narrows to literal type
if x == 42 then end              -- lit_eq: narrows to integer literal
if x == true then end            -- lit_eq: narrows to boolean literal
if x.field then end              -- field_presence: x.field is non-nil in truthy branch
if x.field == "val" then end     -- field_disc: discriminated union narrowing (literal only!)
if x.field == 42 then end        -- field_disc: numeric discriminant
if x == Enum.Member then end     -- enum_eq: narrows to enum member type
if is_str(x) then end            -- guard_check: user-defined type predicate (see below)
if not x then end                -- negation: inverts any narrowing above
if a and b then end              -- and: both narrowings apply in truthy branch
if a or b then end               -- or: either narrowing
```

Discriminant-field narrowing requires a **literal** discriminant field type. `type: string` cannot be narrowed; `type: "heading"` can. **Aliasing to a local does NOT narrow the object:** `local t = x.field; if t == "v" then` narrows `t`, not `x`.

## Type predicates and assertion functions

```lua
-- Type predicate: narrows the argument in the caller's scope
--: (x: unknown) -> x is string
local function is_str(x) return type(x) == "string" end

-- Assertion function: asserts x is T or throws (narrows after the call)
--: (x: unknown) -> asserts x is string
local function assert_str(x)
  if type(x) ~= "string" then error("expected string") end
end
```

## Match types

```lua
--:: ReturnOf<F>    = match F { () -> %R => R }               -- extract return type
--:: ParamOf<F>     = match F { (%P, ..._) -> _ => P }    -- extract first param type
--:: ParamsOf<F>    = match F { (...%P) -> _ => P }        -- all params as tuple
--:: Tail<F>        = match F { (_, ...%P) -> _ => P }     -- params after first

-- Table field distribution (result is a union of the expression per field)
--:: Keys<T>        = match T { { ...[%K]: %V } => K }
--:: Values<T>      = match T { { ...[%K]: %V } => V }
--:: PairsReturn<T> = match T { { ...[%K]: %V } => (K, V) }

-- Conditional type
--:: IsString<T>    = match T { string => true, _ => false }

-- Pattern captures use %Name in pattern position, bare Name in result position
-- _ is a wildcard (always matches, no binding)
-- Bare names in pattern position are concrete type lookups (error if not in scope)
```

`match` arm patterns: primitives, unions, intersections, function types `() -> %R`, `(...%P) -> T`, `(A, ...%P) -> T`, table types `{ field: T }`, `{ [K]: %V }`, `{ ...[%K]: %V }`, `{ field: T, ...%Rest }`, `{ #...%M }`.

## Tuple and spread types

```lua
--:: PcallReturn<F> = match F { (...%P) -> %R => (true, ...R) | (false, string) }
-- (true, ...R): spreads R's elements into the tuple position.
-- R = integer        → (true, integer)
-- R = (A, B)         → (true, A, B)
-- R = never (void)   → (true)
```

## Stdlib built-in aliases (no import needed)

```lua
Arr<T>           -- { [integer]: T, ... }
Ptr<T>           -- T & { [0]: T }
Ctype<T>         -- $Opaque<T> (FFI ctype wrapper)
PairsReturn<T>   -- match T { { ...[%K]: %V } => (K, V) }
IpairsReturn<T>  -- match T { { ...[%K]: %V } => match K { number => (integer, V), _ => never } }
Keys<T>          -- match T { { ...[%K]: %V } => K }
Values<T>        -- match T { { ...[%K]: %V } => V }
Open<T>          -- match T { { ...%Rest } => { ...Rest, ... } }   (open version of T)
Closed<T>        -- match T { { ...%Rest } => { ...Rest } }        (closed version of T)
MetaOf<T>        -- match T { { #...%M } => M, _ => nil }         (metatable type)
```

## Permanent intrinsics ($-prefixed)

```lua
$Require<T>          -- module system; needs literal type propagation through generics
$Opaque<T>           -- nominal identity; $Opaque<T, U> with optional exposed view U
$Opaque<T, U>        -- opaque with view: external sees U, internal treats as T
$FfiC                -- closed table built from ffi.cdef(...) call sites in the file
-- ffi.C is typed as $FfiC: symbols declared via ffi.cdef ARE typed; undeclared symbols
-- are errors. FFI-heavy files are fully typecheckable — ensure all used C symbols have
-- cdef declarations and the typechecker infers their types. Do NOT claim FFI code is
-- "untyped" or "untypeable" — that is wrong. Missing types = missing cdef declarations.
$GlobalScope         -- closed table mirroring all --:: declare globals; used for _G
$Throw<T>            -- type-level error (diagnostic side effect)
$Catch<T, Default>   -- type-level pcall; returns Default if T throws
$EachField<T, F>     -- per-field flatMap with flag access; F is a named alias
$PatternReturn<P>    -- return type of string.match/gmatch given literal pattern P
$FindReturn<P>       -- return type of string.find given literal pattern P
```

Do not add new `$` intrinsics — extend `match` patterns instead.

## Indexed access types

```lua
--:: T = { name: string, age: integer }
--:: Name = T["name"]   -- string (indexed access into a table type by string literal key)
--:: Val  = Arr<integer>["n"]  -- integer (index into named field)
```

## Newtype (nominal types)

```lua
--:: newtype UserId = integer
-- UserId is NOT assignable to integer and vice versa.
-- Use --:: unseal UserId to rebind to inner type in a scope.
```

## typeof

```lua
local point = { x = 0.0, y = 0.0 }
--:: PointType = typeof point   -- captures inferred type of `point` binding
```

## ANN_TYPE_ARGS (explicit type instantiation at call site)

```lua
local x = f() --:<integer>   -- force-instantiate generic f with T=integer
```
