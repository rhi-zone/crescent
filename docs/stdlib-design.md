# Stdlib Design

## Goal

Domain-agnostic. The stdlib provides primitives that any application picks up
regardless of runtime, async model, or domain. No privileged use case.

---

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
- `lib/hash/sha1/` — mpeterv/sha1; heavily patched, rewrite planned
- `lib/ljsocket/` — CapsAdmin/luajitsocket; rewrite planned (blocked on registry)

---

## Layering rule

Every module that touches I/O must have a pure-data layer underneath — parse
and serialize without knowing about sockets or coroutines. `http/format` (pure)
vs `http/server` (network + concurrency) is the canonical example. This split
is the rule everywhere, not an accident.

**Why:** a pure-data layer is independently testable (no network fixtures), can be
reused by other transports (HTTP/2, QUIC, Unix sockets), and keeps complexity
budget separate. Sans-I/O is the [correct pattern](https://sans-io.readthedocs.io/)
for protocol implementations.

---

## Iterator protocol

The primitive is the triple: `fn, state, control`. The VM calls
`fn(state, control)` each iteration, returning the next control value (and any
additional values). Iteration stops when the first return value is nil.

```lua
-- zero-alloc table iteration — next is the iterator fn, table is state
for i, x in next, t do ... end
```

Two iterator shapes both use the triple protocol:

- **Stateless**: `f` has no upvalues; all iteration state lives in `s` and `var`.
  Zero allocation. `next, t, nil` is the canonical example — `next` is a single
  function reused across every table iteration.
- **Stateful**: `f` is a closure that captures mutable upvalues. Allocates one
  closure at iterator creation time. `s` and `var` are often nil/unused.

**Hot paths in the stdlib use stateless iterators.** Combinator utilities (map,
filter, zip, chain) exist as conveniences but are not on the critical path —
callers that care about allocation use stateless iterators directly.

**Why stateless:** the allocation is in the closure, not the triple. Using a
closure as `f` still uses the triple protocol; it just pays allocation cost.
Stateless iterators are zero-cost after the `for` setup. The JIT can also
specialise better when `f` is a known non-closure function.

---

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

**Why `nil, err` not exceptions:** LuaJIT exceptions (pcall/error) are expensive
— they allocate and unwind. `nil, err` is zero-cost on the success path and
keeps control flow explicit and local. Go, Rust, and Zig all converged on explicit
error returns for the same reason.

**Why not a Result type:** a Result wrapper adds allocation and forces callers to
unwrap. `nil, err` is Lua's native two-return idiom; it composes with `or` and
`and`, and every Lua programmer already knows how to use it.

**Why `err` is a string not a table:** tables allocate and require caller code to
pattern-match structure. Plain strings print directly. If structured error context
is needed (error code + message), a module-level error table keyed by code is the
right shape — but the public return is still `nil, string`.

---

## Concurrency

The stdlib does not assume an async model. Modules that need scheduling accept
the scheduler as a parameter or return iterators/callbacks that the caller drives.
Blocking is a valid usage. Sans-I/O at the core.

**Why:** crescent doesn't pick a scheduler. A library that hard-codes coroutine
yields or callbacks locks the caller into one concurrency model and breaks
composability. By being synchronous and sans-I/O at the core, the same library
works with coroutines, OS threads, or no concurrency at all.

---

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
- `sha1`, `sha256` exist under `lib/hash/`
- `hmac` — exists under `lib/hash/`
- `rand` — CSPRNG missing

---

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

---

## Mechanical conventions

These rules are precise enough to lint mechanically. A package that follows all
of them is consistent with every other compliant package — no judgment calls.

---

### Module variable

Always `local M = {}` … `return M`. No other forms (`mod`, `lib`, `self`, the
filename, etc.). One name, everywhere, no exceptions.

**Why `M`:** `M` is the shortest unambiguous name that doesn't shadow anything.
It is instantly recognisable as "the module being built." Longer names (`mod`,
`module`) collide with each other mentally when reading code across files;
the filename shadows the module name on refactors; `self` implies OOP. `M` is
a convention, not an abbreviation — its meaning is fixed by the ecosystem, not
the reader's vocabulary.

**Why not the filename:** `require("lib.fs")` returns the table you called `fs`
inside the file — but now renaming the file requires updating every local name
inside it. `M` is stable across renames.

---

### Path guard

Exactly:
```lua
if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end
```

The `find` check uses `?/init.lua` (no `./`); the prepended path uses
`./?/init.lua` (with `./`). Do not use `./` in the find string — Lua 5.2+ adds
`?/init.lua` to the default path, not `./?/init.lua`, so the guard must match
the right form. Prepend, do not append — a prepended entry wins over any existing
path entry, preventing stale or wrong copies from being found first.

**Why the guard at all:** LuaJIT does not include `?/init.lua` in its default
`package.path`. Every `init.lua` that needs to be the entry point for `require`
calls (either its own requires or by being directly required) must add it.

**Why check before adding:** multiple `init.lua` files may be composed in one
process. Without the check, each require of any crescent package appends another
copy, growing `package.path` unboundedly.

---

### Type annotations

Always crescent-style `--:` on the line immediately before the declaration.
`---@param`, `---@return`, `--[[@type]]`, `--[[@class]]` and all other
LuaLS/EmmyLua forms are forbidden in stdlib packages.

Every public function on `M` must have a `--:` annotation. Local helpers do not
require annotation.

**Why `--:` not EmmyLua:** EmmyLua annotations are parsed by external tools (the
LuaLS language server) and are structurally separate from crescent's type system.
They cannot be consumed by `lib/type/static/`, cannot be verified by the
typechecker, and represent a second source of type truth that can drift from
the actual implementation. Crescent has one type annotation syntax — `--:`.

**Why every public function:** unannotated public API is a documentation and
typechecker gap. The typechecker can infer local types, but exported API must be
declared so callers get accurate diagnostics. An unannotated `M.foo` is invisible
to type search and the LSP.

---

### Naming

| Thing | Convention | Why |
|-------|-----------|-----|
| Module variable | `M` | See "Module variable" above |
| Constructor returning object | `M.new(...)` | Universal constructor name across languages; unambiguous about intent |
| Resource cleanup | `:close()` | POSIX/Go/Python convention for I/O resources; telegraphs "this is I/O" |
| Predicate | `is_*` or `has_*` | Unambiguous: reader knows the return type is boolean |
| Converter | `to_*` / `from_*` | Symmetric pair; self-documenting direction; generalizes cleanly (`to_hex`, `from_json`) |
| Success return (side-effectful op) | `true` | Not the object (that implies chaining, which we don't use); not `1`; `true` is unambiguous |

**Why `M.new` not `M.create`/`M.make`/`M.open`:** `create` is ambiguous
("create a file? a connection? an object?"). `make` is a Go idiom that allocates
without construction semantics. `open` is correct for file resources but misleading
for anything else. `new` consistently means "allocate and initialise an object"
— it is what you reach for first.

**Why `:close()` not `:destroy()`/`:free()`/`:release()`:** `close` is what the
OS uses (file descriptors, sockets), what Go uses, what Python uses. `destroy`
implies destructors / RAII. `free` implies manual memory. `release` is COM/ref-counting.

**Why `is_*`/`has_*`:** a function named `valid()` could return anything.
`is_valid()` has a type signature in its name. This also lets the typechecker's
lint rule (`lib/type/static/rules/predicate_return.lua`) verify that `is_*`
functions actually return boolean.

**Why `to_*`/`from_*` not `encode`/`decode`:** `encode`/`decode` are
specific to serialisation. `to_hex`/`from_hex` are self-documenting in both
direction and target. The pattern generalises: `to_string`, `to_bytes`,
`to_base64`, `from_json` — they all form natural symmetric pairs.

---

### Options tables

- ≤3 required parameters: positional args
- Optional / named behaviour: final `opts` table, always last, always optional
- Never use `nil` as a placeholder to skip a positional arg — redesign as opts

**Why ≤3 positional:** three positional args fit in most people's mental buffer
and are unambiguous by position. Four or more require looking at the signature
to know which is which. Python's similar "use keyword args for defaults"
convention reflects the same intuition.

**Why opts always last and always optional:** putting opts first would make every
call require an explicit `nil` for the common case. Making opts required would
remove the ability to call `M.encode(str)` for the default case.

**Why no nil placeholder:** `M.foo(nil, nil, opts)` is unreadable and fragile.
If you need to skip positional args, the function has too many required positional
args — collapse them into opts.

---

### `bit.*` library

Always `local bit = require("bit")` at the top of the file. Never bare `bit.*`
globals. Reference only via the local.

**Why:** LuaJIT exposes `bit` as a global, but PUC-Rio does not. Pure Lua code
that accesses `bit` as a global silently breaks on standard Lua. Explicit require
makes the dependency visible, works everywhere, and allows the typechecker to
resolve the type.

---

### Module load side effects

Module load must be side-effect free. No file I/O, no network access, no process
spawning, no global mutation during `require`. Expensive initialisation is deferred
until first use or an explicit `M.init()` / `M.new()`.

**Why:** `require` is cached — it runs once per process. Side effects during load
make load order matter, prevent test isolation (one test's load contaminates
another's), and make the module impossible to load safely in a context where the
resource isn't available. Lazy initialisation keeps the load fast and safe.

---

### Locals

All module-level names that are not on `M` must be `local`. Do not write to `_G`.
Do not rely on globals except for builtins (`string`, `table`, `math`, `io`,
`os`, `pcall`, `ipairs`, etc.).

**Why:** global writes are process-wide and invisible to the caller. A module that
writes `foo = 123` at load time has a hidden side effect that can corrupt other
modules or tests. Explicit `local` also lets LuaJIT optimise variable access more
aggressively.

---

### FFI cdefs

FFI modules are the canonical case where the typechecker infers types from cdefs
directly — no `--:` annotation is needed on FFI wrapper functions since the type
is already captured at the cdef site. Adding redundant annotations that could
drift from the cdef is worse than omitting them.

**Why no annotation on FFI wrappers:** the cdef is the single source of truth.
A `--:` annotation on a wrapper function that shadows the cdef creates two
representations of the same type, and they will diverge. When they disagree,
the cdef wins (it's what the C ABI enforces) — the annotation becomes misleading.

---

### Tiered implementations

When a function has multiple implementation tiers (pure Lua / FFI / system library):
- Each tier is a real, independent implementation — no wrapping one in another
- Load order: fastest first, each in a `pcall`; fall through on failure
- Parity tests assert byte-for-byte identical output across all tiers
- Parity fuzzing generates random inputs and runs all tiers, catching edge cases
- Benchmarks for each tier committed to `docs/perf/log.md`
- The module variable (`M.fn`) always points to the fastest available tier

**Why no wrapping:** wrapping the fast tier around the slow tier (or vice versa)
destroys hackability. The reader can't understand the fast path without understanding
the wrapper. Each tier must be readable and modifiable independently.

**Why pure Lua must exist before any FFI tier:** pure Lua is the correctness
reference. It works on PUC-Rio. It is readable by anyone. The FFI tier is an
optimisation, not a replacement — without the pure Lua tier, there is no baseline
to test parity against.

**Why fastest first with pcall fallback:** the caller never specifies a tier.
The module picks the best available. Failing hard when a faster tier is missing
(e.g., no OpenSSL on this system) breaks correct programs unnecessarily. Silently
using a slow tier without trying faster ones first violates the performance contract.

---

### Resource objects

Objects returned by `M.new()` that hold OS resources must implement `:close()`.
`:close()` returns `true` on success or `nil, err` on failure. Calling `:close()`
twice is safe (idempotent). No finalizer/`__gc` is required but is welcome.

**Why idempotent:** resource cleanup often happens in both the success path and
the error path (Go's `defer`, Lua's `pcall` cleanup). Double-close must not crash.
The pattern is: track whether the resource is already closed in a local flag;
if already closed, return `true` silently.

**Why `true` not `nil` on success:** callers that write `assert(conn:close())`
should not be surprised. `true` is the unambiguous "it worked" signal. Returning
the object itself would suggest the object is still usable post-close, which is
wrong.

---

### Testing files

- Named `<module>_test.lua`, in the same directory as the module
- Use `local T = require("lib.test.assert")` — never shadow the builtin `assert`
- Assertions at the top level of the file (not wrapped in functions unless using
  `T.describe`/`T.it`)
- Test the public API only; do not reach into `M._private` unless testing a
  named internal tier
- Error paths: test that `M.foo(bad_input)` returns `nil` as first value and a
  string as second — do not test the exact error message text (it changes)

**Why `T` not `assert`:** shadowing the builtin `assert` makes bugs harder to
find (a miscalled assertion silently panics instead of counting as a test failure).
`T` is short, unambiguous, and doesn't collide with anything.

**Why same directory:** the test is part of the package. It lives next to the
code it tests and is discovered automatically by the test runner.

---

### Comments

- `--` for regular line comments
- `--:` for type annotations (crescent-native, see above)
- `--::` for type declarations
- `--[[ ]]` for multi-line block comments (file-level docstrings, long explanations)
- No `---` (triple dash) — that is EmmyLua/LuaLS doc-comment syntax
- No `--[[@param]]`, `--[[@return]]`, `--[[@class]]` etc. — forbidden (see "Type annotations")
- Comments explain *why*, not *what*. `-- add 1 to i` is noise. `-- skip the BOM` is useful.

**Why no `---`:** triple-dash is EmmyLua convention. Crescent uses `--:` for
annotating types. Mixing the two creates ambiguity about which tool reads which
comment.

---

## Open questions

- `iter` module shape: pure functions `iter.map(fn, iter)` vs method chaining?
- `result` as a library on top of `nil, err`? Or just document the convention?
- Unified `lib/hash/` namespace design (see TODO.md — crypto/hashing stdlib design)
- Constants naming: uppercase (`MAX_SIZE`) or lowercase with underscores (`max_size`)?
  Current files are inconsistent.
