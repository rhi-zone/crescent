# Global Type Declarations

## Problem

Currently `stdlib_types.lua` is the only file whose declarations become the global type environment. Specifically, `ctx.prim_index` (used for primitive structural subtyping and method dispatch) and `ctx.prim_meta` (operator metamethods) are populated exclusively from that file's `string`, `number_meta`, `integer_meta`, and `string_meta_ops` declarations.

This means:
- A library that adds string methods (e.g. a Lua 5.1 compat shim) cannot declare those methods in its own `_types.lua` — it must patch `stdlib_types.lua`.
- Any project that wants to override or extend primitive metatables has no mechanism to do so.
- The typechecker has a single blessed source of truth that is invisible to the rest of the system.

## Lua semantics

In Lua, the string metatable is a runtime global: `debug.setmetatable("", { __index = string })`. It can be replaced by any code that runs before your code. The type system should mirror this: primitive metatables are globally declared, and any file can participate in declaring them.

The same applies to `number` and `integer` (via `__add`, `__mul`, etc. in their metatables) and, in principle, `boolean` and `nil`.

## TypeScript analogy

TypeScript solves this with **open interface merging**: any `.d.ts` file can declare `interface String { myMethod(): void }` and it merges with the existing `String` interface. The compiler collects all such declarations from all included files in a pre-pass before checking.

The Crescent equivalent: any `*_types.lua` file included in a check can contribute to the global primitive types.

## Design

### Syntax: `--:: declare primitive <name> = T`

A new form of global declaration targeting primitive types:

```lua
--:: declare primitive string = { sub: (string, integer, integer?) -> string, byte: (string, integer?) -> integer, ... }
--:: declare primitive string_meta = { __concat: (string, string) -> string }
```

`declare primitive string` merges `T` into the global `string` prim_index (the `__index` table for the string primitive). `declare primitive string_meta` merges into `prim_meta[TAG_STRING]`.

**Merge semantics**: fields are unioned. If two files declare the same field with incompatible types, the checker emits an error at the declaration site of the later-loaded file.

### Alternative: open primitive types

Instead of new syntax, treat the existing `--:: declare string = T` as a contribution to the global string prim_index when the name matches a primitive type name (`string`, `number`, `integer`, `boolean`). Any file that redeclares one of these contributes its fields via merge.

This is simpler (no new syntax) and matches how TypeScript works (open interfaces via redeclaration), but risks confusion: a local `--:: declare string = SomeOtherType` would unexpectedly affect the global primitive type.

**Decision**: new `declare primitive` syntax is clearer and avoids the collision risk.

### Collection: pre-pass across included files

The typechecker needs to know which files contribute primitive declarations before checking any file. The mechanism:

1. The checker's entry point (`check.check_string`, `cli.lua`) receives a list of files to check plus a list of **global declaration files** (`*_types.lua` files in the project root or explicitly configured).
2. A pre-pass loads each global declaration file, collects all `declare primitive` entries, and merges them into the root context (`ctx.prim_index`, `ctx.prim_meta`).
3. Normal checking proceeds with the merged context.

For single-file checking (the current mode), the pre-pass only runs over files explicitly listed or auto-discovered (e.g. a `crescent.toml` manifest).

### Discovery

Global declaration files are discovered via:
1. **Explicit**: `--:: require "lib.foo.foo_types"` in any file already loads that file's type declarations into the checking context. `declare primitive` entries in required files are promoted to the global context.
2. **Auto-discovery** (future): a project manifest (`crescent.toml`) lists global declaration files. The checker loads them before any file.

The explicit `--:: require` path is implementable now without a manifest. The auto-discovery path requires the package manager to land first.

## Implementation

### Phase 1: `declare primitive` in `--:: require`d files

1. **`ann.lua`**: parse `--:: declare primitive <name> = T` as a new declaration kind (`DECL_PRIMITIVE`).
2. **`constrain.lua` `load_decl_file`**: after resolving all declarations in a file, scan for `DECL_PRIMITIVE` entries and call a new `merge_primitive_decl(ctx, name, tid)` function.
3. **`prelude.lua` `merge_primitive_decl`**: merge the declared type's fields into the existing `ctx.prim_index[tag]` or `ctx.prim_meta[tag]` entry. Create a new merged TAG_TABLE type that is the union of the existing and new fields. Error on incompatible field types.
4. **`stdlib_types.lua`**: convert existing `declare string = ...` to `declare primitive string = ...` so it uses the same mechanism as any other file.

### Phase 2: auto-discovery (post-manifest)

Once `lib/pkg/` has a manifest format, add a `global_types` list that enumerates files to pre-load. The checker reads this list before any per-file check.

## What changes for users

Before: extending string methods requires editing `stdlib_types.lua`.

After:
```lua
-- lib/mylib/mylib_types.lua
--:: declare primitive string = { trim: (string) -> string, split: (string, string) -> string[] }
```

Any file that `--:: require "lib.mylib.mylib_types"` now gets `string <: { trim: _ }` passing in structural checks, and `s:trim()` resolving in method dispatch.

## Open questions

- **Ordering**: if two required files declare incompatible types for the same primitive field, which wins? Current proposal: error. Alternative: last-write-wins (less safe).
- **Rollback on require failure**: if a `--:: require`d file fails to load, should its primitive declarations be rolled back? Yes — partial merges are worse than no merge.
- **`boolean` and `nil`**: these have no methods in standard Lua, but the mechanism should support them for completeness. `declare primitive nil = T` would be unusual but not wrong.
