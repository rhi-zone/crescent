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

## Immutable vs write-private

Both are type modifiers; they differ in scope:

- **Immutable** — field is non-writable in *all* contexts, internal and external. A structural property of the field itself. Useful for constants, IDs, and values set at construction that must never change.
- **Write-private** — field is writable in the internal type, non-writable in the exported type. Different callers hold different types of the same underlying table.

From the typechecker's perspective, both are "this field is not writable in this type." The distinction is which types include write access.

## Privacy as absence from the exported type

The common case needs no special mechanism. A "private" field is simply not present in the type the module exports.

```lua
-- lib/http/server.lua (internal type has pool, conn_count, ...)
-- require("lib.http.server") returns a type without those fields
-- accessing them from outside is "field not found" — existing machinery
```

There is no `private` keyword for this case. The module author designs the exported type to omit implementation details. `FLAG_PRIVATE` is not needed for the common case.

## Explicit opt-in for intentional private access

Sometimes code genuinely needs access to internals — test suites, sibling modules in a package, debuggers. The model here is **use-site explicitness**, not definition-site whitelisting.

The analogy is Rust's `unsafe {}`: you don't declare who is allowed to write unsafe code. You require that anyone who does must be explicit about it. Accidental unsafe operations are compile errors; deliberate ones require acknowledgment.

Applied to access control:
- Accessing a field absent from the exported type without acknowledgment → type error
- Accessing it *with* explicit acknowledgment → allowed, typechecked normally

**What this is not:**
- Not a `friend` declaration (C++ `friend` is explicit at the definition site — you list every consumer. This couples the module to its consumers and doesn't scale.)
- Not a capability token (requires explicit passing and bootstrapping)
- Not path-based rules (files are not fundamental units of access control)

The explicitness is at the **use site**. The module author does not need to maintain any list.

## What the typechecker enforces

1. Field read on a type that does not include the field → error ("field not found")
2. Field write on a type that marks the field non-writable → error
3. Accessing a field via explicit opt-in → allowed; the opt-in is visible in the source and can be audited

The type system is strict. The access policy is not enforced by a whitelist — it falls out of type checking.

## Files are not fundamental

The module boundary (where you choose to narrow the type you expose) is often a file because `require()` creates a natural handoff point. But this is a convention, not a constraint. Access control does not depend on file identity or directory structure.

There are no `pub(in path)` style rules. Code in `lib/http/router.lua` has no ambient authority to access `lib/http/server.lua` internals — it receives whatever type `require()` returns, same as any other caller.

## Open questions

**1. Annotation syntax for the exported type**

How does a module author declare the exported type when it differs from the inferred type? Options:
- Explicit `--:: export MyModule = { ... }` declaration in the source or a `.d.lua` file
- Per-field modifiers on the internal type declaration: `--:: { pub field: integer, ... }`
- Inferred from what is included in the returned table (already partially works)

The `.d.lua` companion file model already provides an explicit exported type — the question is whether additional syntax is needed for the internal/external split.

**2. Opt-in syntax at the use site**

What does explicit acknowledgment of private access look like? The design requirement: it must be impossible to do accidentally; it must be visible in code review.

Candidates:
- Block annotation: `--! private-access` scoping a region
- Per-expression: some explicit type assertion or cast
- A function: `internal(x).field` where `internal` strips access restrictions (and is itself typed as requiring acknowledgment)

The scope question is related: does the opt-in cover one expression, a block, or a whole file?

**3. Read/write independence in annotation syntax**

If read and write are truly independent, the annotation syntax must express them independently. `readonly` in existing annotations conflates these. The replacement syntax needs to be unambiguous.

**4. Immutable vs write-private in the type representation**

Currently `FLAG_READONLY` covers both. With the split, FieldEntry needs at minimum:
- `FLAG_IMMUTABLE` — non-writable everywhere
- `FLAG_WRITE_PRIVATE` — non-writable in exported type, writable internally

These may be the same bit with different semantics depending on context (internal vs exported type), or genuinely separate flags.
