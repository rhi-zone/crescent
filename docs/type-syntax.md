# Type Annotation Syntax Reference

Type annotations in crescent are written in Lua comments. There is no
transpiler — code runs directly under LuaJIT. Annotations are stripped at
runtime and exist only for the static typechecker (`lib/type/static/`).

---

## Annotation forms

### `--: type` — value annotation

Placed on the line **before** a declaration, or at the **end** of the same line.

```lua
--: string
local name = "alice"

local count = 0  --: integer
```

Also valid as a block comment:

```lua
--[[:
string | nil
]]
local result = maybe_string()
```

### `--:: ...` — type declaration

Declares a type alias, global variable, or module-level type directive.
Multi-line declarations are supported: continue lines that have unclosed
brackets by starting each continuation line with `--::`.

```lua
--:: Point = { x: number, y: number }

--:: Config = {
--::   host: string,
--::   port: integer,
--::   debug: boolean | nil
--:: }
```

---

## Primitive types

| Type      | Meaning                                               |
|-----------|-------------------------------------------------------|
| `string`  | Lua string                                            |
| `number`  | Lua number (float or integer)                         |
| `integer` | Integer-valued number (subtype of `number`)           |
| `boolean` | `true` or `false`                                     |
| `nil`     | The nil value                                         |
| `any`     | Opt-out of type checking — caller takes responsibility|
| `unknown` | Must be narrowed before use (caller must check)       |
| `never`   | Uninhabited — the bottom type; no value of this type  |
| `cdata`   | LuaJIT FFI cdata                                      |
| `function`| Any function (no param/return info)                   |

`unknown` is analogous to TypeScript's `unknown` — assignments from it
require a narrowing check. `any` is TypeScript's `any` — it bypasses all
checks. Prefer `unknown`; use `any` only with justification.

---

## Literal types

Single values as types:

```lua
--: "hello"           -- the string "hello" only
--: 42                -- the integer 42 only
--: 3.14              -- the number 3.14 only
--: true              -- only true
--: false             -- only false
```

---

## Union and intersection

### Union: `A | B`

A value that is either `A` or `B` (or both).

```lua
--: string | nil
--: number | string | boolean
--: "ok" | "error" | "pending"
```

### Intersection: `A & B`

A value that satisfies both `A` and `B`. Common for overloads and merged
table types.

```lua
--: { x: number } & { y: number }
--: ((string) -> number) & ((integer) -> string)
```

---

## Optional shorthand

`T | nil` is the standard form. There is no `T?` postfix — write `T | nil`
explicitly.

```lua
--: string | nil         -- correct
--: (integer | nil)      -- also correct
```

---

## Table and struct types

### Named fields

```lua
--: { x: number, y: number }
--: { host: string, port: integer }
```

### Optional fields

Use `?` after the field name (before `:`):

```lua
--: { host: string, port: integer, debug?: boolean }
```

### Readonly fields

Fields prefixed with `readonly` cannot be assigned after creation:

```lua
--: { readonly version: string, mutable_count: integer }
```

`readonly` and optional may be combined:

```lua
--: { readonly id?: integer }
```

### Open tables (structural subtyping)

`...` at the end of a field list marks the table as open — it accepts any
table with *at least* these fields. Unknown extra fields return `unknown`.

```lua
--: { name: string, ... }         -- accepts {name="x", extra=1}
```

### Index signatures

Any key of type `K` maps to a value of type `V`:

```lua
--: { [string]: number }          -- string-keyed map to number
--: { [integer]: string }         -- integer-indexed array of strings
--: { [string]: number, ... }     -- open indexed table
```

### Array shorthand

`T[]` is sugar for `{ [number]: T }` (closed):

```lua
--: string[]                      -- { [number]: string }
```

### Meta slots

Fields prefixed with `#` are metamethod slots (not regular fields):

```lua
--: { #__index: { [string]: unknown, ... } }
--: { #__add: (self: unknown, other: unknown) -> unknown }
```

### String-literal indexing

`{ ["foo"]: T }` is equivalent to `{ foo: T }`:

```lua
--: { ["content-type"]: string }  -- field with a hyphen in its name
```

---

## Function types

### Basic form

```lua
--: (A, B) -> C
--: (string, integer) -> boolean
--: () -> string
```

### Named parameters

Parameters may be named for documentation. Names are optional and do not
affect type checking:

```lua
--: (host: string, port: integer) -> boolean
```

### Multi-return

Wrap multiple return types in parentheses:

```lua
--: (string) -> (boolean, string | nil)
--: () -> (integer, integer)
```

### Variadic parameters

Use `...T` as the last parameter for variadic functions:

```lua
--: (...string) -> ()
--: (integer, ...unknown) -> ()
```

### Spread return (multi-return variadic)

Use `-> ...(T)` to return a spread of a type — zero or more values of type
`T`:

```lua
--: () -> ...(string)
--: (string) -> ...(integer)
```

### Bare arrow (curried shorthand)

`A -> B` at the top level is parsed as `(A) -> B`:

```lua
--: string -> number   -- same as (string) -> number
```

---

## Generic functions and types

### Inline generic (forall)

Generic type parameters are declared with `<T>` before the type body in an
inline position:

```lua
--: <T>(T) -> T                           -- identity
--: <T, U>(T, U) -> T                     -- first
--: <T>(t: { [integer]: T, ... }) -> T    -- head
```

### Generic with bounds

```lua
--: <T: string>(T) -> T    -- T must be a subtype of string
```

### Named generic aliases

```lua
--:: Pair<A, B> = { first: A, second: B }
--:: Result<T, E> = { ok: true, value: T } | { ok: false, err: E }
```

### Generic with defaults

```lua
--:: Box<T = string> = { value: T }
```

---

## Type declarations (`--::`)

### Simple alias

```lua
--:: Name = type
--:: UserId = integer
--:: Point = { x: number, y: number }
```

### Generic alias

```lua
--:: Option<T> = T | nil
--:: Pair<A, B> = { first: A, second: B }
```

### Declare a variable's type in scope

```lua
--:: declare x = string
--:: declare config = { host: string, port: integer }
```

### Augment an existing library table

Merges additional fields into an already-declared type binding. Used
primarily for standard library extensions:

```lua
--:: augment string {
--::   trim: (string) -> string,
--::   split: (string, string) -> { [integer]: string, ... }
--:: }
```

### Declare the type of a required module

```lua
--:: module "mylib.util": {
--::   parse: (string) -> integer | nil,
--::   format: (integer) -> string
--:: }
```

### Load type declarations from another file

```lua
--:: require "lib.mylib.types"
```

### Newtype (nominal wrapper)

Creates a new type that is structurally identical to the underlying type but
is not assignable to or from it without an explicit cast:

```lua
--:: newtype UserId = integer
--:: newtype Email = string
```

Two different newtypes over the same underlying type are not interchangeable:

```lua
--:: newtype UserId = integer
--:: newtype PostId = integer
-- UserId and PostId are distinct even though both wrap integer
```

### Typeof: capture the inferred type of a binding

```lua
local config = { host = "localhost", port = 8080 }
--:: Config = typeof config
-- Config is now { host: string, port: integer }
```

---

## Match types

`match T { pat => result, ... }` — conditional type computation based on
structural pattern matching:

```lua
--:: IsString<T> = match T { string => true, _ => false }
--:: Flatten<T> = match T { { [integer]: %E, ... } => E, _ => T }
```

Pattern forms in match arms:

| Pattern                     | Matches                                     |
|-----------------------------|---------------------------------------------|
| `string`, `number`, etc.    | Primitive type                              |
| `{ field: T }`              | Table with named field                      |
| `{ [K]: V }`                | Table with indexer                          |
| `() -> %R`                  | Any function; binds return to `R`           |
| `(A, B) -> %R`              | Function with exact param count             |
| `(...%P) -> T`              | Function; binds all params as tuple to `P`  |
| `{ ...[%K]: %V }`          | Iterates all fields; K/V bound per field    |
| `{ field: _, ...%Rest }`    | Named field + rest capture                  |
| `{ #...%M }`                | All meta slots captured into `M`            |
| `_`                         | Wildcard — always matches, no binding       |
| `%Name`                     | Explicit capture (binds in result expr)     |

Captures are referenced by bare name in the result expression. The `%`
prefix is only used in the pattern side.

```lua
--:: Head<T> = match T { (A, ...%Rest) => A }
--:: PcallReturn<F> = match F {
--::   (...%P) -> %R => (true, ...R)
--::   | (false, string)
--:: }
```

---

## Intrinsics

Intrinsics are built-in type operators that require compiler support.
User-defined `match` types cover most needs; these cover what `match` cannot
express.

### `$Opaque<T>` / `$Opaque<T, U>`

Nominal identity: creates a type that is structurally `T` but is only
assignable to itself. With two arguments, `U` is the exposed view type
(what the holder sees).

```lua
--:: Ctype<T> = $Opaque<T>
```

### `$GlobalScope`

Builds a closed table type mirroring all `--:: declare` globals. Used to
type `_G`:

```lua
--:: declare _G = $GlobalScope
```

### `$FfiC`

Builds a closed table from `ffi.cdef(...)` call sites in the file, so
undeclared C symbols are type errors:

```lua
--:: declare ffi = { C: $FfiC, ... }
```

### `$Require<T>`

Module system intrinsic. Given a string literal module name, resolves to the
declared or inferred type of that module. Used internally for `require()`.

### `$Throw<T>` / `$Catch<T, Default>`

Type-level error/pcall. `$Throw<T>` produces a diagnostic. `$Catch<T, D>`
returns `T` if it typechecks, `D` on failure. Used for error recovery in
type-level computation.

### `$EachField<T, F>`

Per-field flatMap. Iterates the fields of `T`, passes each as a descriptor
`{ key, value, optional, readonly }` to alias `F` (passed unapplied), and
collects results. Used for `Partial<T>`, `Required<T>`, `Readonly<T>` — flag
manipulation that `{ ...[%K]: %V }` cannot do.

### `$PatternReturn<P>` / `$FindReturn<P>`

Given a Lua pattern string literal `P`, computes the return type of
`string.match`/`string.gmatch` and `string.find` respectively, counting
captures in the pattern at type-check time.

---

## Type guards and assertion functions

### Type predicates: `param is T`

A function returning `param is T` narrows the type of `param` to `T` in
branches where the function returns true:

```lua
--: (x: unknown) -> x is string
local function is_string(x) return type(x) == "string" end

local v --: string | integer
if is_string(v) then
    -- v is string here
end
```

### Assertion predicates: `asserts param is T`

A function annotated `asserts param is T` returns `nil`/void but narrows
`param` to `T` in all code following the call (as if the check always
passes):

```lua
--: (x: unknown) -> asserts x is string
local function assert_string(x)
    assert(type(x) == "string", "expected string")
end

local v --: unknown
assert_string(v)
-- v is string here
```

---

## Indexed type access

Access a specific field type from a table type:

```lua
--:: Config = { host: string, port: integer }
--:: HostType = Config["host"]   -- string
```

---

## Block annotation form

Multi-line annotations can use block comment syntax. Inline `--` comments
inside the block are stripped:

```lua
--[[::
Point = {
  x: number,  -- horizontal
  y: number,  -- vertical
}
]]
```

---

## Cast syntax: `--[[: T]] expr`

A cast is written as a `--[[: T]]` block annotation placed **immediately
before** the expression it applies to. The parser sees the pending cast and
wraps the next expression in a `NODE_CAST_EXPR` whose target type is `T`.

```lua
local x = --[[: integer | nil]] maybe_value()
local greeting = --[[: string]] tostring(42)
```

The cast binds to the next *simple expression* (atom or
prefix-with-suffixes — variable, call, table constructor, literal, function
expression), not to a surrounding unary or binary operator. To cast the
result of a unary or binary expression, parenthesise:

```lua
local len = --[[: integer]] (#s)
```

### Semantics

A cast emits a `C_SUB(typeof(expr), T)` constraint
(`lib/type/static/constrain.lua:2138-2147`, with `is_cast=true`). This is the
same subtype check the checker uses for any annotated assignment — the cast
does **not** bypass the type system, it just attaches a target type to a
position that has no binding to annotate. A cast that fails subtyping is a
type error. A cast that asserts a type the expression already has is a
warning ("redundant type assertion").

### `unknown` cannot be cast away

Because the cast is a checked subtype assertion, it cannot rescue a value of
type `unknown`. `unknown <: T` is rejected by `unify` (`unify.lua:287-294`)
and by `try_unify` (`unify.lua:862`) for any concrete `T`. The only way to
use an `unknown` is to narrow it via a runtime test (`type(x) == "string"`,
`x is T` predicate, etc.).

```lua
local v --: unknown = receive()
local s = --[[: string]] v       -- ERROR: unknown is not assignable to string
if type(v) == "string" then
    -- v: string here, no cast needed
end
```

### Force cast: `--[[:! T]]`

`--[[:! T]] expr` is an overlap-checked force cast. It succeeds when `actual`
and `T` have any value in common (the intersection is inhabitable), and
fails for disjoint pairs (e.g. `string → integer`). This is the documented
escape hatch from `unknown` and from one-sided union narrowing where the
checker cannot narrow automatically.

```lua
local v --: unknown = receive()
local s = --[[:! string]] v      -- accepted (overlap: unknown & string nonempty)
                                 -- runtime: still your responsibility
```

Casting `unknown` to `any` via the regular `--[[: any]]` form is **rejected**
— `any` is an opt-out the user must declare on the *binding* (e.g.
`local x --: any`), not a back-channel that silently launders an `unknown`
source. The force-cast form `--[[:! any]]` is **also rejected**: a force
cast to `any` is indistinguishable from "I gave up" and there is no
narrowing it could perform. If you genuinely need an `any` escape hatch,
declare it on the binding (`local x --: any = ...`) or use a checked
`--[[: any]]` cast at a site where the source type is already `any` (so
the cast is a no-op). To force-cast `unknown` to a *concrete* type, use
`--[[:! T]]` with a real `T` (e.g. `--[[:! string]]`).

### Annotations vs. casts

`--: T` on a `local` declaration is **not** a cast. The intent is that the
annotation declares the variable's permanent type and the initializer is
checked against it. **In the current implementation, the local-init
subtype check is unsound** — see the "Known limitations" entry below and
[soundness-audit.md, Gap 8](soundness-audit.md). To force a real subtype
check today, prefer the cast form or a function-return annotation:

```lua
local x = --[[: integer]] "hello"           -- ERROR: string </: integer (correct)
local function f() --: () -> integer
    return "hello"                          -- ERROR: string </: integer (correct)
end
```

---

## Examples

### Annotated function

```lua
--: (path: string, mode: string | nil) -> (boolean, string | nil)
local function try_open(path, mode)
    local f, err = io.open(path, mode or "r")
    if not f then return false, err end
    f:close()
    return true, nil
end
```

### Type alias for a record

```lua
--:: HttpRequest = {
--::   method:  string,
--::   path:    string,
--::   headers: { [string]: string, ... },
--::   body:    string | nil
--:: }

--: (HttpRequest) -> string
local function format_request(req)
    return req.method .. " " .. req.path
end
```

### Generic container

```lua
--:: Stack<T> = {
--::   push: (Stack<T>, T) -> (),
--::   pop:  (Stack<T>) -> T | nil,
--::   peek: (Stack<T>) -> T | nil,
--::   len:  (Stack<T>) -> integer
--:: }
```

### Overloaded function

```lua
--: ((string) -> string) & ((integer) -> string)
local function to_str(x)
    return tostring(x)
end
```

### Nominal type for safety

```lua
--:: newtype UserId = integer
--:: newtype PostId = integer

--: (UserId) -> string
local function get_username(uid) return "user_" .. uid end

--:: declare user_id = UserId
get_username(user_id)      -- ok
-- get_username(42)        -- error: integer is not UserId
```

### match type for conditional types

```lua
--:: Stringify<T> = match T {
--::   string  => string,
--::   number  => string,
--::   boolean => string,
--::   _       => never
--:: }
```

---

## Known limitations

- **`T?` postfix is not valid.** Write `T | nil`. The parser records a hint
  error if it sees `T?` and continues, but the intent is rejected — always
  write the full form.

- **Annotations on `local x = expr` narrow but do not enforce structural
  field-level compatibility.** To test that type `T` satisfies `U`, use a
  function return annotation: `local function f() --: U ... end` where the
  body returns a `T` value.

- **Unannotated parameters in `--::` function declarations warn** about
  unnamed parameters. Name them: `(x: integer, y: string) -> boolean`.
  Inline `--:` annotations do not warn because param names come from the AST.

- **`match` arm patterns with bare capture keys `{ [%K]: %V }` are
  rejected.** Use `{ ...[%K]: %V }` for per-field iteration. Bare `[%K]`
  capture is non-deterministic over named fields.

- **Generic defaults must follow non-default parameters** in the declaration:
  `Foo<T, U = string>` is valid; `Foo<T = string, U>` produces an error.

- **`typeof` only works on bindings visible in the current scope** at the
  point of the `--::` declaration. Forward references to not-yet-declared
  variables produce an error.

- **`match` result expressions cannot nest table literals in brace-tuple
  position.** Use a flat descriptor `{ key: K, value: V, ...Rest }` instead
  of `{ { ...Rest } }` in result expressions.

- **Type depth is capped at 64 levels.** Deeply-nested types beyond this
  produce a diagnostic instead of a stack overflow.
