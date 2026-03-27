# Crescent: Batteries Included

The goal is an ecosystem so complete that you reach for crescent regardless of what
you're building — a PIM, a web service, a game, a language server, an RP engine, an
LLM pipeline. The motivating examples are not the point; the foundation is the point.
The examples just prove the foundation is real.

## Motivating targets

### Lumen

A local-first personal information manager: ingest (text, markdown, PDF, images, audio,
links), full-text search, tagging, self-hosted E2E-encrypted sync, voice transcription,
web archiving. Every piece maps to a crescent primitive:

| Lumen feature | Crescent primitive |
|---|---|
| Ingest pipeline | `lib/orchestration`, `lib/fs`, `lib/process` |
| PDF/image/audio parsing | `lib/format/*`, `lib/process` (subprocess) |
| Web archiving | `lib/http`, `lib/html` |
| Full-text search | `lib/sqlite` (FTS5) |
| Tag inference | `lib/orchestration/executor/ai` |
| E2E encrypted sync | `lib/http`, `lib/crypto` (AES-GCM, HKDF) |
| CLI | `lib/cli` (arg parsing) |

Lumen is the proof that crescent's stdlib is broad enough for real applications.

### RP substrate

Stateful, LLM-driven narrative: world state that the model reads and writes, prose
generated from state rather than inferred from conversation, proper lineage tracking
for every LLM call and tool invocation.

| RP component | Crescent primitive |
|---|---|
| World state | `lib/ecs` or equivalent mutable entity store |
| LLM task dispatch | `lib/orchestration` + `lib/orchestration/executor/ai` |
| Prose assembly | `lib/template` (string interpolation over state) |
| Persistence | `lib/sqlite` |
| Protocol / API | `lib/http`, `lib/jsonrpc` |

The key insight: the model is not the container of state. State lives in a real data
structure; the model is a function over it. The context window is a view, not the truth.

## What "batteries included" means

### Already exists (lib/)

- **Test infrastructure** — runner, property testing, fuzz testing, fixture/snapshot,
  integrated shrinking, parallel execution
- **Typechecker** — static checker, LSP daemon, SARIF output
- **Network** — HTTP (client + server), WebSockets, DNS, TLS (partial)
- **Storage** — SQLite
- **Encoding** — JSON, CBOR, base64, UTF-8, URL encoding, MessagePack
- **Hashing** — SHA-1, SHA-256, HMAC
- **System** — fs, process, path, env, time, signal, epoll, inotify, timerfd
- **Concurrency** — epoll event loop (partial), fork-based parallelism in test runner
- **Random** — CSPRNG (getrandom / /dev/urandom)
- **Functional** — fp/ typeclasses (Maybe, Either, lens, prism), iter combinators
- **AI** — provider dispatch (Anthropic, OpenAI, Google), streaming, embeddings, tools
- **Orchestration** — task graph, execution engine, combinators (map/retry/refine),
  LLM executor at `lib/orchestration/executor/ai`
- **Package manager** — semver, manifest, lockfile (install not yet implemented)

### Missing — stdlib tier

These belong in `lib/` and block real applications:

**Async I/O / event loop** — the largest gap. Without a proper event loop (io_uring on
Linux, kqueue on macOS), crescent can't do high-concurrency servers or multiplex
connections. Everything currently blocks. This is the single change that unlocks the
most use cases. Design: sans-I/O core, injectable scheduler, `lib/reactor` or
`lib/loop`.

**Datetime** — no date/time library at all. Needed by Lumen (timeline), logging,
anything timestamped. Design: POSIX time via FFI, timezone support via tzdata,
formatting per RFC 3339 / ISO 8601.

**Regex** — no pattern matching beyond Lua's built-in `string.find` / `string.gmatch`.
Needed for search syntax, text processing, URL routing. Design: PCRE2 via FFI (system
library tier) + a pure Lua fallback for basic patterns.

**CLI arg parsing** — `lib/cli` exists but its scope is unclear. Need a clap-equivalent:
subcommands, typed flags, auto-generated help, completions. Every CLI tool needs this.

**Structured logging / tracing** — no observability layer. `print` is not production
logging. Need: log levels, structured fields, pluggable sinks (stderr, file, journald),
optional OpenTelemetry-compatible trace IDs.

**UUID** — trivial but missing. Needed for entity IDs, request IDs, sync records.
Design: v4 (random) via `lib/rand`, v7 (time-ordered) for database keys.

**Compression** — no zlib/gzip, no zstd. Needed for HTTP content encoding, storage,
sync. Design: system library tier (zlib, zstd via FFI) + pure Lua tier for zlib deflate.

**Template engine** — string interpolation over a data table. Needed for prose
assembly (RP), HTML generation, config rendering. Design: minimal — `{{var}}` and
`{{#block}}` are sufficient; avoid logic-heavy templates.

**More crypto** — AES-GCM (needed for sync encryption), HKDF (key derivation),
ChaCha20-Poly1305. Design: system library tier (libcrypto via FFI), pure Lua for
reference. Note: pure Lua AES is slow; system tier is the real implementation.

**TOML** — config file format. Needed by the package manager and any application
with a config file. The format is small and well-specified; a pure Lua parser is
reasonable.

### Missing — protocol bindings

Protocol libraries that expose a typed API, not just a raw wire format:

**`lib/jsonrpc`** — request/response dispatch layer over stdio or TCP. The substrate
for LSP, MCP, and any other JSON-RPC protocol. Design: transport abstraction (stdio,
TCP, HTTP), method registry, typed handler registration.

**`lib/lsp`** — LSP method bindings on top of `lib/jsonrpc`. Ships with every method
pre-typed from the LSP spec. You register handlers; the types are already there. The
protocol definition is the library.

**`lib/mcp`** — same pattern for the Model Context Protocol.

**`lib/openapi`** — OpenAPI 3.x client/server from a spec file. Request validation,
response serialization, typed route handlers.

### Missing — frontend vertical

**`lib/reactive_optics`** — reactive optics. Signals focused through optics (lenses, prisms,
traversals) as the reactivity primitive. `signal:focus(lens)` produces a derived signal
that reads and writes structurally through the lens; reactivity flows through optic
composition rather than imperative synchronization functions. Lawful by construction —
lens laws (get-set, set-get, set-set) guarantee derived state is always consistent.

Built on `lib/fp/` (lenses, prisms, traversals already exist there). The novel piece is
the marriage: optics as the *structure* of derived state, signals as the *propagation*
mechanism. Prior art: `~/git/rhizone/rainbow/` (TypeScript prototype).

Paired with `lib/lua2ts`: write reactive UI logic in Lua, emit typed TypeScript, run in
the browser. Same optic algebra server-side and client-side, no impedance mismatch.

### Missing — world state

**`lib/ecs` or equivalent** — durable, queryable, mutable entity store. Named entities,
typed components, spatial containment. User-defined schemas — no hardcoded concepts.
Useful for games, simulations, workflow state, the RP substrate. The shape of this
library is still open; ECS is one design, a graph database is another, a document
store is a third. The right answer is derived from real consumers (Lumen, RP) first.

### Missing — application verticals

Higher-level libraries that assemble primitives into complete vertical solutions.
A new user building in a given domain shouldn't need to compose primitives themselves.
The vertical is complete — not 90%, 100%. Partial verticals create the same pressure
to abandon as partial stdlib implementations.

**`lib/web`** — full web backend vertical. Builds on `lib/http`, adds: middleware
pipeline, session management, cookie handling, CSRF protection, static file serving,
route groups. The "Rails without opinions" answer for crescent web apps.

**`lib/db`** — database vertical. Builds on `lib/sqlite`, adds: migrations, query
builder, schema management, connection pooling. Raw SQLite is not enough for real apps.

**`lib/auth`** — authentication and authorization. JWT, OAuth 2.0 / OIDC, session
tokens, password hashing (Argon2, bcrypt). Every web app needs this; nobody wants to
write it.

**`lib/email`** — SMTP client, email composition (MIME, attachments), template
rendering. Boring but load-bearing for any application with user accounts.

**`lib/queue`** — task queues and scheduling. Cron-style job scheduling, deferred
execution, retry with backoff. Backed by SQLite for persistence. Builds on
`lib/orchestration` for execution semantics.

**`lib/search`** — search vertical. Full-text search via SQLite FTS5 (near-term) +
semantic search via embeddings (`lib/ai`) for vector similarity. Needed by Lumen and
any content-heavy application.

**`lib/realtime`** — pub/sub, presence, event sourcing patterns. Builds on
`lib/websocket`. Needed by collaborative applications, live UIs, multiplayer.

**`lib/tui`** — terminal UI. Layouts, widgets, keyboard input, color/style. Needed
for `cr` (the package manager CLI) and any interactive CLI tool. Builds on
`lib/cli` (arg parsing) and raw terminal FFI.

**`lib/notify`** — push notifications, webhooks, alerting. Outbound HTTP webhooks,
email notifications (via `lib/email`), SMS gateway integrations.

### Missing — transpiler (future)

**`lib/lua2ts`** — Lua → TypeScript transpiler. The typechecker already builds an AST;
emitting TS syntax is largely mechanical. Prior art: `dep/lua2js.lua` in the legacy
repo. Metatables are the awkward mapping; FFI doesn't cross. Crescent type annotations
map directly to TS types.

## Priority order

Ordered by how many other things unblock:

1. **Async I/O / event loop** — unlocks: concurrent HTTP servers, multiplexed
   connections, everything network-bound. Largest single gap.
2. **Datetime** — unlocks: Lumen timeline, logging, any timestamped data.
3. **CLI arg parsing** — unlocks: every CLI tool (Lumen CLI, `cr` package manager CLI).
4. **Structured logging** — unlocks: production-grade observability in any service.
5. **`lib/jsonrpc`** — unlocks: LSP, MCP, any JSON-RPC protocol.
6. **`lib/lsp`** — unlocks: building language servers with crescent (including
   crescent's own LSP daemon, which currently lives in `lib/type/static/lsp.lua`
   and would benefit from a proper protocol layer).
7. **UUID** — small, unblocks entity IDs everywhere.
8. **TOML** — unblocks package manager config, application config.
9. **Regex** — unblocks search syntax, text processing.
10. **Compression** — unblocks HTTP content encoding, sync.
11. **More crypto** — unblocks E2E sync (AES-GCM, HKDF).
12. **Template engine** — unblocks prose assembly, HTML generation.
13. **World state lib** — unblocks RP substrate, Lumen entity model.

## Why vendor-first doesn't mean bloat

The npm cautionary tale is not about vendoring — it's about **fragmentation**. Thousands
of packages with no shared conventions, no coherent design, no single source of truth.
Each package is its own island. Modularity without coherence produces a dependency graph
that no one can audit or reason about.

Crescent's modularity is within a bounded, coherent system. `lib/` has one error
convention, one iterator protocol, one type annotation syntax, one naming convention.
Any two libraries compose because they were designed together. The dependency direction
is always *toward* `lib/`, never outward into an unbounded third-party graph.

Vendoring `lib/http` means vendoring `lib/http` — not `lib/http` plus its transitive
dependencies, because those dependencies are also in `lib/`, which is already there.
The graph is shallow by design, not by accident.

The LuaJIT binary is ~500KB. A typical application's `dep/` is a handful of `.lua`
files. The whole thing fits in a git repo. That's not bloat — that's a complete,
auditable, self-contained artifact.

## Vendored runtime

LuaJIT binaries are vendored directly in the repo — one per platform
(linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64, windows-x86_64).
A bootstrap script selects the right one.

LuaJIT's release cadence is effectively frozen (2.1 beta has been stable for years),
so the binary doesn't change without a deliberate commit. Vendoring it means:

- No "install LuaJIT" step in the getting-started story
- No version variance across users (distro packages, 2.0 vs 2.1, patched forks)
- The repo is the complete runtime — clone and run, nothing else required
- Full vertical ownership: libraries, tooling, and runtime are all in one place,
  all auditable, all yours

The only external dependency left is a C compiler for any FFI work that needs
it — which is as close to a universal assumption as exists.

## The typed ecosystem flywheel

Every library in `lib/` is fully annotated with crescent-style `--:` types. The
typechecker reads these directly. The result:

- **Discovery** — type search (`lib/type/static/`) finds functions by signature, not
  name. New library → immediately searchable.
- **Composition** — libraries snap together without glue code because their interfaces
  are explicit contracts, not conventions.
- **Protocol bindings** — a pre-typed protocol library (`lib/lsp`, `lib/mcp`) means
  you implement handlers and the typechecker validates them against the spec. You never
  write a schema; the types are the schema.
- **Typed holes** — `_: unknown` in a stdlib definition is a typed hole. `unknown`
  forces narrowing at every use site, propagating "not designed yet" through the type
  graph automatically. Incomplete APIs are loud, not silent.

The flywheel: more typed libraries → better discovery → easier composition → more
libraries built → repeat.
