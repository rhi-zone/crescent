# Stdlib Design

## Goal

Domain-agnostic. The stdlib provides primitives that any application picks up
regardless of runtime, async model, or domain. No privileged use case.

## Ownership rule

**`lib/` contains only code written by us.** Not forks. Not vendored libraries
with patches on top. Not "mostly rewritten." A package in `lib/` must have been
written from scratch to crescent conventions.

Third-party libraries are installed via the registry (`cr add lunajson`) and live
in a per-project cache — never committed to the repo. There is no `dep/` directory.
If you need a library that doesn't exist in the stdlib yet, either write it or
install it from the registry.

**Why this matters:** vendored code has its own conventions. If a vendored package
accidentally passes our lint, that means the lint is only checking surface syntax,
not the deeper architectural patterns that make crescent stdlib code what it is.
The surface lint is necessary but not sufficient. The real bar is:

1. Written by us from scratch
2. Tiered implementations where the domain warrants (pure Lua / FFI / system) —
   each tier a real independent implementation, fastest selected at load time
3. Parity tests if multiple tiers exist — byte-for-byte identical output
4. Sans-I/O layering for anything that touches the outside world
5. Mechanical conventions (see below) — what the lint checks

A vendored library that passes (5) but fails (1)–(4) does not belong in `lib/`.

**Current exceptions** — packages in `lib/` that originated as vendored code and
need to be rewritten or removed once the registry exists:
- `lib/format/json/` — lunajson; rewrite planned
- `lib/format/cbor/` — vendored; rewrite planned
- `lib/encode/base64/` — lbase64; rewrite planned
- `lib/hash/sha1/` — mpeterv/sha1; heavily patched, rewrite planned
- `lib/ljsocket/` — CapsAdmin/luajitsocket; rewrite planned (blocked on registry)

## Layering rule

Every module that touches I/O must have a pure-data layer underneath — parse
and serialize without knowing about sockets or coroutines. `http/format` (pure)
vs `http/server` (network + concurrency) is the canonical example. This split
is the rule everywhere, not an accident.

## Iterator protocol

The primitive is the triple: `fn, state, control`. The VM calls
`fn(state, control)` each iteration, returning the next control value (and any
additional values). Iteration stops when the first return value is nil.

```lua
-- zero-alloc table iteration — next is the iterator fn, table is state
for i, x in next, t do ... end
```

A stateful closure works as a degenerate triple (state and control are ignored),
but it allocates. **Hot paths in the stdlib use the triple directly.** Combinator
utilities (map, filter, zip, chain) exist as conveniences but are not on the
critical path — callers that care about allocation use the triple.

## Error convention

`nil, err` at all public boundaries. The rule is mechanical:

- **`error()`** — legal only when the condition cannot occur in a correct program:
  wrong argument type, violated internal invariant that represents a bug in the
  caller. Example: `error("expected string, got " .. type(x))`. These are
  crash-worthy; the caller has no way to recover from them.
- **`nil, err`** — everything else. Missing files, parse failures, syscall errors,
  network errors, malformed input. Any condition a correct program might encounter.
- **`assert()`** — forbidden in library code (tests only). It produces unhelpful
  error messages, is not recoverable, and conflates programmer errors with runtime
  failures. Use explicit `if not x then return nil, "..." end` instead.

The test: *could a correct, well-written caller encounter this condition?* If yes,
`nil, err`. If only a buggy caller could trigger it, `error()`.

## Concurrency

The stdlib does not assume an async model. Modules that need scheduling accept
the scheduler as a parameter or return iterators/callbacks that the caller drives.
Blocking is a valid usage. Sans-I/O at the core.

## Tiers

**1 — Data and algorithms**
- `iter` — combinator utilities (map, filter, zip, chain, take); protocol is
  Lua's built-in triple, not a wrapper type
- `table` — deep copy, merge, freeze, sorted iteration
- `string` — split, trim, pad, template formatting (beyond LuaJIT builtins)

**2 — System**
- `fs` — stat, read, write, walk, watch
- `process` — subprocess spawn, pipes, wait
- `path` — manipulation, resolution, safe_resolve
- `env` — environment variables
- `time` — clocks, monotonic, formatting
- `signal` — POSIX signal handling

**3 — Network**
- `socket`, `http`, `websocket`, `dns`, `tls` — all exist, varying quality

**4 — Encoding**
- JSON (lunajson), CBOR, base64, UTF-8 — all exist
- `toml` — missing (needed for config files)
- `csv` — missing
- `msgpack` — missing

**5 — Crypto**
- `sha1`, `sha256` exist as orphans; need unification under `lib/hash/`
- `hmac` — missing
- `rand` — CSPRNG missing

## Namespacing

Group related modules under a namespace (`lib/hash/`, `lib/encode/`) when two
or more of these apply:

- **Top-level noise** — `lib/` has 80+ entries already; adding sha1, sha256,
  blake3, xxhash flat makes the directory unnavigable. This is the primary reason
  to namespace.
- **Shared interface** — siblings implement the same contract; parity tests and
  the interface definition live at the namespace level (`lib/hash/init.lua`
  defines what a hasher looks like).
- **Parent value** — `init.lua` does real work: registry of all algorithms,
  dispatch by MIME type, etc.

Protocols (`http`, `websocket`, `dns`, `tls`) stay flat — each is large enough
to be its own world, and the noise argument doesn't apply when there are only a
handful.

## Mechanical conventions

These rules are precise enough to lint mechanically. A package that follows all
of them is consistent with every other compliant package — no judgment calls.

### Module variable

Always `local M = {}` … `return M`. No other forms (`mod`, `lib`, `self`, etc.).
One name, everywhere, no exceptions.

### Path guard

Exactly:
```lua
if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end
```
The `find` check uses `?/init.lua` (no `./`); the prepended path uses `./?/init.lua`
(with `./`). Do not use `./` in the find string — Lua 5.2+ adds `?/init.lua` to
the default path, not `./?/init.lua`, so the guard must match the right form.

### Type annotations

Always crescent-style `--:` on the line immediately before the declaration.
`---@param`, `---@return`, `--[[@type]]` and all other LuaLS/EmmyLua forms are
forbidden in stdlib packages. Every public function on `M` must have a `--:`
annotation. Local helpers do not require annotation.

### Naming

| Thing | Convention | Example |
|-------|-----------|---------|
| Module variable | `M` | `local M = {}` |
| Constructor returning object | `M.new(...)` | `M.new(host, port)` |
| Resource cleanup | `:close()` | `conn:close()` |
| Predicate | `is_*` or `has_*` | `is_valid`, `has_key` |
| Converter | `to_*` / `from_*` | `to_hex`, `from_base64` |
| Success return | `true` | not `1`, not the object itself |

### Options tables

- ≤3 required parameters: positional args
- Optional/named behaviour: final `opts` table, always last, always optional
- Never use `nil` as a placeholder to skip a positional arg — redesign as opts

### `bit.*` library

Always `local bit = require("bit")` at the top of the file. Never bare `bit.*`
globals. LuaJIT exposes `bit` globally but PUC-Rio does not; explicit require
makes the dependency visible and works everywhere.

### FFI cdefs

FFI modules are the canonical case where the typechecker infers types from cdefs
directly — no `--:` annotation is needed on FFI wrapper functions since the type
is already captured at the cdef site. Adding redundant annotations that could
drift from the cdef is worse than omitting them.

### Tiered implementations

When a function has multiple implementation tiers (pure Lua / FFI / system library):
- Each tier is a real, independent implementation — no wrapping
- Load order: fastest first, each in a `pcall`; fall through on failure
- Parity tests assert byte-for-byte identical output across all tiers
- The module variable (`M.fn`) always points to the fastest available tier

### Resource objects

Objects returned by `M.new()` that hold OS resources must implement `:close()`.
`:close()` returns `true` on success or `nil, err` on failure. Calling `:close()`
twice is safe (idempotent). No finalizer/`__gc` is required but is welcome.

## Open questions

- `iter` module shape: pure functions `iter.map(fn, iter)` vs method chaining?
- `result` as a library on top of `nil, err`? Or just document the convention?
- Unified `lib/hash/` namespace design (see TODO.md — crypto/hashing stdlib design)
