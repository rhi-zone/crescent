# Access Control Design

## Core insight

Access control is a type problem, not an enforcement problem.

The question is never "who is this caller?" — it's "what type does this caller hold?" The typechecker already answers the second question. No new enforcement mechanism is needed.

## Read and write are independent axes

A field has two independent access dimensions:

- **read** — can external code read this field?
- **write** — can external code write this field?

These are type modifiers, not access control keywords. Both are enforced by the same mechanism: the typechecker checks what operations the type at a given use site permits.

`FLAG_READONLY` as currently implemented conflates "read is public" with "write is private." This must be split into independent flags.

## `const` vs `readonly` — placement, not separate keywords

Both mean "not writable in this type," but they differ by *where* `readonly` appears:

- `readonly` in the **internal type** → non-writable for all holders, including internal code. Equivalent to what `const` would mean. Useful for IDs, values set at construction, true constants.
- `readonly` in the **exported (`$Opaque`) type only** → non-writable externally, writable internally. The internal type omits the restriction.

No separate `const` keyword needed. The distinction is expressed by placement.

## Privacy as absence from the exported type

The common case needs no special mechanism. A "private" field is simply not present in the type the module exports.

```lua
-- lib/http/server.lua (internal type has pool, conn_count, ...)
-- require("lib.http.server") returns a type without those fields
-- accessing them from outside is "field not found" — existing machinery
```

There is no `private` keyword for this case. The module author designs the exported type to omit implementation details. `FLAG_PRIVATE` is not needed.

## `$Opaque<T>` — hiding internals with a named type

For the case where external callers need a named type (to pass values around, store in tables, etc.) but should not see its structure, use the `$Opaque<T>` intrinsic:

```lua
--:: declare server = $Opaque<InternalHttpServer>
```

Callers know the type exists and can pass it to functions that accept it, but cannot access any fields.

To expose a subset of fields:

```lua
--:: declare server = $Opaque<InternalHttpServer, { start: () -> (), stop: () -> () }>
```

External callers see only `start` and `stop`. Internal code works with the full `InternalHttpServer` type.

`$Opaque<T>` with no second argument produces a **nominal opaque newtype** — not an empty table type. The distinction matters: `{}` is structurally compatible with any other empty table, but `$Opaque<HttpServer>` is nominally distinct from `$Opaque<ConnectionPool>` even though both expose nothing. Nominal identity comes from the **declaration site** — each `--::` declaration anchors a fresh nominal ID. `T` is the wrapped shape: it determines what `unseal` recovers and what fields are valid to expose in `U`, but it is not the source of identity. Two `$Opaque<HttpServer>` at different declaration sites are different types. Callers can only thread the value through functions that accept it — they cannot inspect or construct it. This is how OCaml abstract types work.

`U` in `$Opaque<T, U>` is not a standalone structural type — it is an **open view of `T`**. The external type is `U + sealed row variable` containing the hidden portion of `T`. This has several consequences:

- `$Opaque<HttpServer, { start: () -> () }>` ≠ `$Opaque<ConnectionPool, { start: () -> () }>` even with identical `U` — nominal identity comes from the declaration site, and the two declarations are at different sites
- `$Opaque<T, U>` is assignable to `$Opaque<T>` (drop exposed fields, go fully opaque) — identity preserved
- `--:: unseal T` unseals the row variable, recovering the full `T`; the typechecker knows the sealed portion IS `T`
- The fields declared in `U` are checked against `T` — you cannot expose a field that does not exist in `T`

This maps onto `TAG_ROWVAR` in the existing type system: the row is present but sealed; `unseal` unseals it.

`$Opaque<T>` fits the existing intrinsic system (`$GlobalScope`, `$Keys<T>`, etc.) and is usable anywhere in a type expression — function signatures, field types, not just module declarations.

Each occurrence of `$Opaque<T>` creates a fresh nominal type anchored to its declaration site. Two textually identical `$Opaque<T>` at different source locations are different types. When the same opaque type is needed in multiple positions, three trivial options exist:

```lua
--:: type HttpHandle = $Opaque<HttpServer>       -- named alias
--:: (x: HttpHandle) -> HttpHandle

--:: <H: $Opaque<HttpServer>> (x: H) -> H        -- type variable

--:: (x: $Opaque<HttpServer>) -> typeof x        -- typeof
```

## Why not absolute enforcement

Absolute enforcement — where accessing a sealed type from outside its defining module is a hard error with no escape — has one fatal flaw: **it's binary**. Inside the module gets full access; outside gets nothing.

This destroys all the granularity the rest of this design provides. `$Opaque<T, U>` with partial exposure, read/write as independent axes, different callers seeing different views — all of that is about fine-grained control. Absolute enforcement collapses it to a single bit: are you in the right file, yes or no.

It also reintroduces identity-based reasoning ("who is the caller?") into a design that's entirely type-based ("what type do you hold?"). A module that absolutely enforces opacity must check call-site file identity, not just types — contradicting the core model.

Vendorability is an additional concern: path/identity-based enforcement breaks when code is copied to a new location.

## Explicit opt-in for intentional private access

The model is **use-site explicitness**, not definition-site whitelisting. The motivation is maximum explicitness: intentional access to internals must be impossible to do accidentally and impossible to miss in code review. This is the same principle as Rust's `unsafe {}` — anyone can write it, but it screams "something deliberate is happening here."

The analogy is Rust's `#[allow(clippy::lint_name)]`: you don't declare who is allowed to bypass the lint. You require anyone who does to be explicit at the point of use. The scope of the bypass follows the AST node the attribute is attached to.

### Syntax

```lua
--:: unseal InternalHttpServer
do
    local s = require("lib.http.server")  -- full type accessible here
    ...
end
-- scope ends, restriction restored
```

`--:: unseal T` applies to the **next AST node** — a block, a declaration, a statement, or a single expression. Whatever the next syntactic unit is. No line counting. The region is delimited by code structure, not comment markers.

When a tighter scope is needed than a function body, Lua's `do...end` is the explicit delimiter.

**What this is not:**
- Not a `friend` declaration — C++ `friend` lists every consumer at the definition site, coupling the module to its consumers. This has no such list.
- Not a capability token — no explicit passing, no bootstrapping problem.
- Not path-based — no `pub(in path)` rules. Files are not fundamental units of access control.

The explicitness is at the **use site**. The module author maintains no list.

## What the typechecker enforces

1. Field read on a type that does not include the field → error ("field not found")
2. Field write on a type that marks the field `readonly` → error
3. Accessing a field via `--:: unseal` → allowed; the opt-in is visible in source and greppable

The type system is strict. The access policy falls out of type checking, not from a whitelist.

## Files are not fundamental

The module boundary is often a file because `require()` creates a natural handoff point. But access control does not depend on file identity or directory structure. There are no `pub(in path)` style rules.

Code in `lib/http/router.lua` has no ambient authority over `lib/http/server.lua` internals — it receives whatever type `require()` returns, same as any other caller.

## Open questions

**1. `$Opaque<T, U>` vs `opaque T U` syntax**

`$Opaque<T>` is consistent with the intrinsics system. `opaque T U` is a lighter two-token form. Either could work. Deferred until implementation. Note: `U` has no default (it is either absent — fully opaque newtype — or explicit).

**2. `unseal` scope granularity**

The annotation applies to the next AST node. Does this interact correctly with the prescan? The prescan needs to see `unseal` declarations to know which private types are in scope where. Implementation question, not a design question.

**3. `FLAG_READONLY` split in FieldEntry**

Currently one bit. With independent read/write axes, needs at minimum two flags. The `const`-vs-`readonly` distinction collapses into internal-type vs exported-type placement, so no third flag is needed. Implementation: rename/split `FLAG_READONLY` when `$Opaque` is implemented.
