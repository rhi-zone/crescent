# exec-api-design.md

Spec for `lib/exec/make_api` — generating a fluent typed API from a HelpSchema.

Status: not implemented.

## Problem

`lib/exec/help.lua` produces a `HelpSchema` from a binary's `--help` output. The schema
describes flags, positionals, and subcommands. Currently callers must hand-construct arg
lists for every invocation. `make_api` turns a `HelpSchema` into a Lua table where each
subcommand is a callable function and each flag is a named parameter — so call sites read
as typed Lua rather than raw arg-list assembly.

## Node shape bitflags

Each node in the schema tree is one of three kinds, detected from the parsed `HelpSchema`:

```
CALLABLE        = 0x1   -- node has flags or positionals (can be invoked directly)
HAS_SUBCOMMANDS = 0x2   -- node has subcommands (is a namespace)
```

Detection rules (applied to a `HelpSubcommand` or the root `HelpSchema`):

- `CALLABLE` is set when `#node.flags > 0` or `#node.positional > 0`.
- `HAS_SUBCOMMANDS` is set when `next(node.subcommands) ~= nil`.
- A node with neither flag is still treated as callable (leaf with no declared inputs).
  Shape `CALLABLE` only. Invocation produces a bare `exec.run(cmd, path)`.

Effective shapes:

| bits | shape | example |
|------|-------|---------|
| `0x1` | leaf | `normalize view <path>` |
| `0x2` | namespace | `git remote` (has `add`, `remove`, etc.) |
| `0x3` | both | `git` (callable AND has subcommands) |

## API shape per node kind

### Leaf (CALLABLE only)

A plain function:

```lua
api.subcmd(positional1, positional2, flags_table?)
```

Positional arguments appear in declaration order from `node.positional`. All are positional
Lua arguments. The optional trailing `flags_table` is a plain table with keys matching
`HelpFlag.ident` values.

Return: `string | nil, string | nil` — stdout on success, or `nil, errmsg` on failure.

Example generated call for `normalize view <path> [--format <fmt>] [--json]`:

```lua
local out, err = api.normalize.view("/some/path", { format = "json" })
```

### Namespace (HAS_SUBCOMMANDS only)

A plain table. Keys are subcommand idents (from `schema.subcommand_idents`). Each value is
recursively the child node's API.

```lua
api.git.remote.add(name, url)
api.git.remote.remove(name)
```

No callable at this level; calling the table is an error (no `__call` metamethod).

### Both (CALLABLE + HAS_SUBCOMMANDS)

A table with a `__call` metamethod:

```lua
setmetatable({ subcmd1 = ..., subcmd2 = ... }, { __call = function(self, ...) ... end })
```

The `__call` signature is identical to the leaf case (positionals then optional flags table).
Subcommand ident keys are also present as plain fields.

Example: `git` itself takes flags (`--version`, `--help`) AND has subcommands:

```lua
api.git({ version = true })     -- calls git --version
api.git.log("--oneline")        -- NOT this style — see below on how args pass through
```

## Public API

File: `lib/exec/make_api.lua`.

```lua
--:: MakeApiOpts = { popen: POpenFn, stderr: string | nil }
--: (HelpSchema, string, MakeApiOpts) -> table, string
M.make(schema, cmd, opts) -> api_table, decls_string
```

- `schema` — a `HelpSchema` from `lib.exec.help.parse` or `lib.exec.help.fetch`.
- `cmd` — the binary name used to invoke the command (e.g. `"normalize"`, `"git"`).
- `opts` — caps table; `opts.popen` is the injected popen function; `opts.stderr` is
  forwarded to `exec.run` verbatim.
- Returns `api_table` — the callable table described above.
- Returns `decls_string` — a string of `--::` declarations (see below).

`make_api` does NOT itself call `--help` or do any I/O. The caller passes a pre-fetched
`HelpSchema`. Use `lib.exec.help.fetch` to get one.

## Invocation internals

Each leaf callable internally builds an arg list and calls `exec.run`:

1. Subcommand path: each ancestor subcommand name (not ident) joined as positional args.
2. Positionals: Lua positional args passed by the caller, in order.
3. Flags: the flags table (if provided) expanded to CLI arg strings (see below).

```lua
exec.run(cmd, { "subpath1", "subpath2", pos1, pos2, "--flag", "value" }, {
    popen = opts.popen,
    stderr = opts.stderr,
})
```

The raw subcommand names (from `schema.subcommand_idents[ident]`) are used in the arg list,
not the idents. Idents are only Lua-side identifiers.

## Flag expansion rules

Given a flags table `{ json = true, limit = 5, output = "text" }`:

**Boolean flags** (`flag.arg == "boolean"` after --no-X collapsing in help.parse, or
`flag.arg == nil` and the Lua value is `true`/`false`):

- `true` → `"--flag"` (long form) or `"-f"` (short-only).
- `false` → `"--no-flag"` for boolean-pair flags; omit for simple boolean flags with no
  negative form.
- `nil` in the table → omit entirely.

**String flags** (`flag.arg ~= nil`, Lua value is a string):

- Long form: `"--flag"`, `"value"` (two separate entries in arg list).
- Short-only form: `"-f"`, `"value"`.

**Integer flags** (Lua value is a number):

- Converted to string via `tostring(v)`, then treated like string flags.

**Short-only flags** (flag has `.short` but no `.long`):

- `-f value` (two args) for string/integer.
- `-f` for boolean true; omit for false/nil.

**Unknown keys in the flags table** (no corresponding ident in `schema.flag_idents`):

- Return `nil, "unknown flag: " .. key` from the leaf callable.
  Do not silently ignore: silent pass-through defeats the typed-API goal.

## `--::` type declaration codegen

`make_api` returns a `decls_string` — a string of `--::` declarations that can be written
to a `.d.lua` file and loaded by the typechecker via `--:: require`.

Format produced:

**Flags type** (one per node with flags):

```
--:: NormalizeViewFlags = { format: string | nil, json: boolean | nil }
```

Optional fields use `T | nil`. Boolean flags become `boolean | nil`. String/integer flags
become `string | nil` or `integer | nil`.

**Function type** (one per leaf or "both" callable):

```
--:: NormalizeView = (path: string, flags: NormalizeViewFlags | nil) -> string | nil, string | nil
```

Positional arg names come from `HelpPositional.ident`. Return type is always
`string | nil, string | nil` (stdout or nil, errmsg or nil).

**"Both" node type** (namespace with callable):

```
--:: NormalizeFlags = { version: boolean | nil, help: boolean | nil }
--:: Normalize      = { view: NormalizeView, grep: NormalizeGrep, #__call: NormalizeFlags }
```

The `#__call` meta-slot holds the callable signature for the "both" shape, matching the
`--:: { name: T, ... }` + `#__call` pattern used elsewhere in the typechecker.

Type names are generated from the subcommand path, PascalCased. Top-level node uses the
`cmd` arg. Collision avoidance: append `_2`, `_3` as needed (same strategy as `lib.exec.ident`).

The implementer writes `decls_string` to e.g. `normalize.d.lua` and can then annotate
call sites with `--:: require "normalize.d"`.

## What `make_api` does NOT do

- Does not call `--help`. Schema is pre-fetched by the caller.
- Does not validate positional arg types at runtime (no schema for their types beyond
  name and required/optional). That's for a future tier.
- Does not handle subcommand aliases (two idents for one raw name). The schema may have
  them; `make_api` exposes each ident as a separate key pointing to the same node function.
- Does not produce streaming output. Each call captures all stdout and returns it.

## Example end-to-end

```lua
local help = require("lib.exec.help")
local make_api = require("lib.exec.make_api")

local schema, err = help.fetch("normalize", { popen = io.popen })
if not schema then error(err) end

local api, decls = make_api.make(schema, "normalize", { popen = io.popen })

-- Direct call:
local out, err = api.normalize.view("/path/to/file")

-- With flags:
local out, err = api.normalize.grep("/path/to/dir", { pattern = "foo" })

-- Write decls to disk for typechecker:
local f = io.open("normalize.d.lua", "w")
f:write(decls)
f:close()
```

## Tests

Test file: `lib/exec/make_api_test.lua`.

Required test coverage:

1. **Leaf node**: schema with one subcommand (flags + positionals) → callable function,
   correct arg list passed to a mock `popen`.
2. **Namespace node**: schema with nested subcommands, no flags on parent → plain table,
   child is callable.
3. **Both node**: schema with flags on parent AND subcommands → table with `__call` and
   child keys.
4. **Flag expansion**: all four flag types (bool true, bool false, string, integer) → correct
   CLI arg strings.
5. **Unknown flag key**: returns `nil, "unknown flag: ..."`.
6. **Decls string**: snapshot test — known schema → expected `--::` declarations string.
7. **Parity**: two calls with identical inputs produce identical arg lists (determinism).
