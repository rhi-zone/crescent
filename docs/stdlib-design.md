# Stdlib Design

## Goal

Domain-agnostic. The stdlib provides primitives that any application picks up
regardless of runtime, async model, or domain. No privileged use case.

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

`nil, err` at all public boundaries. `error()` only for invariant violations
(programmer errors, not recoverable conditions). No exceptions from this rule at
module edges.

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

## Open questions

- `iter` module shape: pure functions `iter.map(fn, iter)` vs method chaining?
- `result` as a library on top of `nil, err`? Or just document the convention?
- Unified `lib/hash/` namespace design (see TODO.md — crypto/hashing stdlib design)
