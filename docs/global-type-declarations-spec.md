# Global Type Declarations

## Problem

The typechecker has no ambient type environment — no declarations are implicit.
The type algebra (TAG_STRING, TAG_NUMBER, etc.) is hardcoded into the checker
itself; everything else must be declared. Currently `stdlib_types.lua` is a
monolith loaded unconditionally before every file, giving it special status no
other file has. This is wrong: nothing is always present in every Lua VM, so
nothing should be unconditionally loaded.

The goal: a single, uniform mechanism for contributing declarations to the
type-checking context, usable from any file, with project-level config
controlling what gets pre-loaded for the whole project.

## Unified mechanism: declaration files + augmentation

A **declaration file** is any `*_types.lua` file containing `--::` annotations.
Declaration files may contain a new form:

```lua
--:: augment string { sub: (string, integer, integer?) -> string, byte: (string, integer?) -> integer }
--:: augment math { floor: (number) -> integer, ceil: (number) -> integer }
```

`--:: augment T { ... }` merges the listed fields into the existing binding `T`
in the current context. If `T` is not yet bound, it is created. If a field
already exists with an incompatible type, the checker emits an error at the
augmentation site.

This is the only mechanism for contributing to the ambient type environment.
There is no special prelude file, no hardcoded stdlib, no blessed source.

## Two entry points, one mechanism

**Per-file**: `--:: require "lua.string"` in a source file loads that
declaration file into the file's checking context. Its `--:: augment`
declarations are merged into the file's type environment.

**Project-wide**: `pkg.lua` lists declaration files to pre-load before checking
any file in the project:

```lua
return {
  name = "myproject",
  typecheck = { globals = { "lua.string", "lua.math", "lua.table", "luajit.ffi" } }
}
```

The CLI reads `pkg.lua` from the project root, loads each listed file in order,
and passes the resulting scope as the `parent_scope` for all files in the
project. Every file inherits those augmentations without any per-file boilerplate.

The files listed in `pkg.lua` are ordinary declaration files — identical in
content and processed by the same code as files loaded via `--:: require`.
The only difference is the call site.

## What replaces stdlib_types.lua

`stdlib_types.lua` is split into a set of declaration files:

```
lib/type/static/stdlib/
  lua.string.lua       -- --:: augment string { sub, byte, find, gmatch, ... }
  lua.table.lua        -- --:: augment table { insert, remove, sort, ... }
  lua.math.lua         -- --:: augment math { floor, ceil, sqrt, ... }
  lua.io.lua           -- --:: augment io { open, read, write, ... }
  lua.os.lua           -- --:: augment os { time, clock, date, ... }
  lua.coroutine.lua    -- --:: augment coroutine { create, resume, yield, ... }
  lua.base.lua         -- --:: augment for print, pcall, type, pairs, ipairs, ...
  luajit.ffi.lua       -- --:: augment ffi { cdef, new, cast, ... }
  luajit.bit.lua       -- --:: augment bit { band, bor, bxor, ... }
  lua51.stdlib.lua     -- convenience: requires all lua.* above
  luajit.stdlib.lua    -- convenience: requires lua51.stdlib + luajit.*
```

A crescent project targeting standard LuaJIT sets:
```lua
typecheck = { globals = { "luajit.stdlib" } }
```

A sandboxed script project that only has `string` and `math`:
```lua
typecheck = { globals = { "lua.string", "lua.math" } }
```

## Primitive metatable augmentation

`--:: augment string { sub: ... }` also updates `ctx.prim_index[TAG_STRING]`,
which drives both method dispatch (`s:sub()`) and structural subtyping
(`string <: { sub: _ }`). The mechanism is the same for `number` and `integer`
(operator metamethods via `ctx.prim_meta`).

When a declaration file is loaded (via `--:: require` or project pre-load), its
`--:: augment` entries for primitive type names (`string`, `number`, `integer`,
`boolean`) are also merged into the context's `prim_index`/`prim_meta` tables
so the structural subtyping and method dispatch machinery stays consistent.

## Implementation order

1. **`--:: augment` syntax** — `ann.lua`: parse `--:: augment Name { fields }`.
   New declaration kind `DECL_AUGMENT`. Field list uses existing field parsing.

2. **Merge in `load_decl_file`** — `constrain.lua`: after resolving a
   declaration file's types, apply each `DECL_AUGMENT` by looking up the name
   in the current scope and merging fields into its type. If the name is a
   primitive (`string`, `number`, `integer`, `boolean`), also update
   `ctx.prim_index`/`ctx.prim_meta`.

3. **Split `stdlib_types.lua`** — move declarations into `lib/type/static/stdlib/`.
   Update the existing `prelude.populate(ctx)` call to load `luajit.stdlib`
   (or nothing, deferring to `pkg.lua`) instead of the monolith.

4. **`pkg.lua` integration** — CLI reads `pkg.lua` from the project root if
   present, loads listed files before checking, passes resulting scope as
   `parent_scope` to all checked files.

## Open questions

- **Merge conflict resolution**: two files augment the same field with
  incompatible types — error at second augmentation site (conservative).
- **Order dependence**: augmentations apply in load order. `pkg.lua` lists are
  ordered; `--:: require` order follows the file's declaration order.
- **Rollback on error**: if a declaration file fails mid-load, augmentations
  already applied are NOT rolled back (partial load = partial context). Files
  that fail to load should emit an error and leave the context unchanged —
  requires two-pass loading (parse all, then apply).
