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
| Ingest pipeline | `lib/taskgraph`, `lib/fs`, `lib/process` |
| PDF/image/audio parsing | `lib/format/*`, `lib/process` (subprocess) |
| Web archiving | `lib/http`, `lib/html` |
| Full-text search | `lib/sqlite` (FTS5) |
| Tag inference | `lib/taskgraph/executor/ai` |
| E2E encrypted sync | `lib/http`, `lib/crypto` (AES-GCM, HKDF) |
| CLI | `lib/cli` (arg parsing) |

Lumen is the proof that crescent's stdlib is broad enough for real applications.

### Distribution thesis

The complete crescent ecosystem — every library in this document implemented — is
approximately **~8MB of pure Lua** plus ~4MB of runtime (LuaJIT binary, SQLite,
vendored stb binaries). **~12MB total.**

SillyTavern, for comparison, is 433MB installed (334MB `node_modules` alone). A
typical Node.js app's dependency tree exceeds the entire crescent ecosystem before
the first line of application code runs.

This isn't just "lean" — it's small enough to travel inside other things. An RP
frontend, a game, a dev tool, a CLI utility: anything users will download without
asking questions. The download is honest about what it is; users just have a small
mental model of what "RP frontend" implies. What they actually install is a complete,
hackable, vendorable computing substrate.

The propagation mechanism is inspection. Every file is readable Lua with no build step.
Someone opens the install directory, reads `lib/reactive/init.lua`, understands it,
copies it into their own project. That's how the ecosystem spreads — not through a
registry, through curiosity.

**The goal:** get LuaJIT + crescent onto every machine by being the best version of
whatever people actually want to download. The OS layer arrives as a footnote.

### Portable application substrate

Self-contained, portable applications: logic + state + UI bundled into a single
distributable artifact that runs anywhere LuaJIT runs. Zero setup, zero dependencies
beyond the vendored runtime. The entire app is the artifact.

Motivating targets: an LLM interaction platform (replacing SillyTavern, Talemate,
Claude Code), a file manager, a markdown viewer, a unified workspace (Deskspace-in-Lua)
— each dissolving an artificial app boundary. The long-term direction: every user-facing
layer of the OS-as-Lua goal.

**LLM interaction platform** — generic enough to replace SillyTavern, Talemate, and
Claude Code, not by being all three, but by being the substrate they're programs on
top of.

**Core thesis (from `lib/taskgraph`):** the LLM is a stateless oracle. Conversation
is context poisoning. The right unit is a function call. The orchestrator is a program,
not an agent. ST/Talemate/Claude Code are different programs that call LLMs — the
platform gives primitives and requires you to write the loop.

**Distribution format:** programs embedded in PNG metadata. A "character" or scenario
is a Lua script in a PNG tEXt chunk — the image is the distributable. Visual
representation and executable loop in one file, zero extra dependencies (LuaJIT is
already vendored). The card carries:
- The interaction loop (turn script)
- The world state schema
- The editor UI (via `lib/reactive_optics`)
- Its own import/export logic for CCv2/charx/etc — the card is self-describing,
  the platform has no hardcoded knowledge of any card format

**What this fixes about SillyTavern:**
- No database → SQLite, search is instant, tags are joins
- Conversation-as-foundation → loop is user code; accumulation is a choice
- LLM-derived worldstate → state is written by the program, read by the LLM, never held by it
- Entity isolation → each character is a function call with explicit inputs; cross-contamination impossible by construction
- Lorebook triggers = fields pretending to be a language → predicates are code
- 23k characters, no index, full CCv2 JSON blob → indexed, virtualized, thumbnails on import

**Security:** capability-based. The turn script gets exactly the capabilities it's
handed — LLM oracle, worldstate read/write, render surface. No ambient authority. The
threat surface is "what capabilities did the platform hand this card?" — auditable and
small. UI code (Rainbow/reactive_optics) is lower-risk; sanitization at the render
boundary is sufficient.

**Architecture:** Lua HTTP server + SQLite + `lib/reactive_optics` frontend. Cap'n Proto
for the control plane if latency becomes a problem (promise pipelining eliminates
roundtrip chains). Thumbnail generation via stb_image_resize compiled into the binary
(zero runtime dep).

**Other frontends follow the same pattern:**
- File manager — browse, preview, edit as one surface (Deskspace-in-Lua)
- Markdown viewer / editor
- Archive tool
- Eventually: the entire user-facing OS layer

**CCv2/lorebook compatibility** is best-in-class but a footnote: CCv2 is lossless
import, lossy export. The card embeds its own import/export logic — the platform has
no hardcoded knowledge of CCv2, charx, or any other format. Lorebooks dissolve into
worldstate queries; the lorebook editor is only needed for the compatibility surface.

| Component | Crescent primitive |
|---|---|
| World state | `lib/sqlite` + entity model |
| LLM task dispatch | `lib/taskgraph` + `lib/taskgraph/executor/ai` |
| Prose assembly | Lua string ops (no dedicated library needed) |
| Reactive UI | `lib/reactive_optics` |
| HTTP server/API | `lib/http` |
| Card format (PNG + metadata) | `lib/png` (chunk r/w, tEXt helpers) |
| Capability sandbox | `lib/sandbox` |
| Platform runner + cap factories | `lib/platform` (card loader, `caps.png`, `caps.llm`, `caps.render`, `caps.fs`) |
| Thumbnail generation | stb_image_resize via FFI (compiled in) |

### Full-stack dashboard

A production admin dashboard/control plane: web backend, auth, database with
migrations, realtime updates, structured logging, frontend via `lib/reactive_optics`
+ `lib/lua2ts`. Not a new library — an application pattern that exercises the entire
stack end-to-end. If this works without reaching outside crescent, the ecosystem is
real for the web/ops crowd.

The key insight: the model is not the container of state. State lives in a real data
structure; the model is a function over it. The context window is a view, not the truth.

## What "batteries included" means

### Already exists (lib/)

- **Test infrastructure** — runner, property testing, fuzz testing, fixture/snapshot,
  integrated shrinking, parallel execution
- **Typechecker** — static checker, LSP daemon, SARIF/JSON output; constraint-based
  inference (v2 flat-array AST + arena allocation, v3 constraint solver); fuzz suite
  (algebra invariants, eval-tier computation contracts, grammar-tier end-to-end);
  lint rule passes (unannotated exports, assert-in-lib, naming, bare-bit, dead-locals,
  predicate return type); type search by signature; generic parameter defaults;
  interface declarations (`--:: Name: Base`) with oracle; partial application of generic
  aliases; `$EachField` flatMap; `$Throw`/`$Catch` type-level error pair;
  spread-in-tuple-position for multi-return; `%Name` capture sigil and `{ ...[%K]: %V }`
  all-fields pattern; function-type and indexer arm patterns in match types
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
  LLM executor at `lib/taskgraph/executor/ai`
- **Package manager** — semver, manifest, lockfile (install not yet implemented)
- **Markdown** — `lib/mdast`: CommonMark parser (Phase 1) producing mdast-compatible AST
  nodes; block structure (headings, paragraphs, fenced/indented code, thematic breaks,
  blockquotes, lists, HTML, link definitions) + inline parsing (emphasis, strong,
  inline code, links, images, hard breaks); `mdast.stringify` for basic round-trip

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

**Template formats** — standard specs (`lib/mustache`, `lib/handlebars`, etc.) are
worth adding as libraries. A bespoke `lib/template/` for prose assembly is not — Lua
string concatenation and `string.format` are sufficient for that use case.

**More crypto** — AES-GCM (needed for sync encryption), HKDF (key derivation),
ChaCha20-Poly1305. Design: system library tier (libcrypto via FFI), pure Lua for
reference. Note: pure Lua AES is slow; system tier is the real implementation.

**TOML** — config file format. Needed by the package manager and any application
with a config file. The format is small and well-specified; a pure Lua parser is
reasonable.

### Missing — binary serialization

**`lib/protocol/capnp`** — Cap'n Proto zero-copy binary serialization. LuaJIT FFI can
read Cap'n Proto messages with near-zero allocation by casting directly into the wire
buffer (fixed-width fields + typed pointers, no varint parsing). Wire format reader +
writer first; `.capnp` schema parser deferred (hand-write schemas as Lua tables
initially). RPC layer (`lib/capnprpc`) separate. Genuine capability gap over JSON/CBOR
for high-throughput IPC and inter-process data sharing.

### Missing — protocol bindings

Protocol libraries that expose a typed API, not just a raw wire format:

**`lib/jsonrpc`** — request/response dispatch layer over stdio or TCP. The substrate
for LSP, MCP, and any other JSON-RPC protocol. Design: transport abstraction (stdio,
TCP, HTTP), method registry, typed handler registration.

**`lib/lsp`** — LSP method bindings on top of `lib/jsonrpc`. Ships with every method
pre-typed from the LSP spec. You register handlers; the types are already there. The
protocol definition is the library.

**`lib/mcp`** — same pattern for the Model Context Protocol. (Note: `lib/mud_cp/` is the existing MUD Client Protocol implementation — unrelated.)

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
`lib/taskgraph` for execution semantics.

**`lib/search`** — search vertical. Full-text search via SQLite FTS5 (near-term) +
semantic search via embeddings (`lib/ai`) for vector similarity. Needed by Lumen and
any content-heavy application.

**`lib/realtime`** — pub/sub, presence, event sourcing patterns. Builds on
`lib/websocket`. Needed by collaborative applications, live UIs, multiplayer.

**`lib/tui`** — terminal UI. Layouts, widgets, keyboard input, color/style. Needed
for `cr` (the package manager CLI) and any interactive CLI tool. Builds on
`lib/cli` (arg parsing) and raw terminal FFI.

**`lib/ansi`** — low-level terminal: escape codes, colors, cursor movement, terminal
queries (size, capabilities). Pure Lua, no deps. The primitive everything TUI builds on.

**`lib/tui`** — widget layer: layouts, boxes, text, input, scrolling, borders. Builds
on `lib/ansi`. Imperative API — draw what you want, when you want.

**`lib/tui/reactive`** *(opt-in)* — reactive binding for `lib/tui`. Wire
`lib/reactive_optics` signals to widget state; only affected widgets redraw on change.
Same model as the browser frontend (`lib/reactive_optics` + `lib/lua2ts`), different
render target. The terminal is just another output surface.

**`lib/notify`** — push notifications, webhooks, alerting. Outbound HTTP webhooks,
email notifications (via `lib/email`), SMS gateway integrations.

**`lib/ml`** *(data/ML vertical)* — classical ML and inference, not training. Tiered
as everywhere else: pure Lua reference implementations (hackable, readable, the thing
you study to understand the algorithm) + FFI bindings to real libraries as the fast tier.

- `lib/vec` — dense vector math: dot product, cosine similarity, norms. The primitive
  everything else builds on.
- `lib/tfidf` — TF-IDF text scoring, document similarity. Pure Lua. Useful for Lumen
  search and any content-heavy application.
- `lib/knn` — k-nearest neighbors. Pure Lua reference + optional FFI fast path.
- `lib/xgboost` — gradient boosted trees. Pure Lua implementation (a few hundred lines
  — decision trees are simple, boosting is just iteration) as the hackable reference;
  FFI binding to the real xgboost library as the fast tier. Parity tests between them.
- `lib/onnx` — ONNX runtime FFI bindings. Run any exported model from PyTorch, sklearn,
  etc. FFI-only (no pure Lua equivalent — the model format is the spec).
- `lib/embed` — embedding utilities on top of `lib/ai`: batch embedding, vector
  similarity search, nearest-neighbor retrieval. Builds on `lib/vec`.

**`lib/logic`** *(logic programming)* — relational/logic programming substrate.

- `lib/ukanren` — microKanren port. The original is ~40 lines of Scheme; a Lua port
  is a beautiful demonstration of hackability. Goals, unification, streams.
- `lib/datalog` — Datalog engine. Rule-based queries over structured data. Practically
  useful: dependency analysis, reachability queries, rule-based inference. Pure Lua.
  Builds on `lib/ukanren` or standalone depending on design.

These serve both the language tooling crowd (type inference helpers, program analysis)
and anyone who wants declarative query semantics without a full SQL engine.

**`lib/parse`** *(lower priority, niche)* — general-purpose parsing substrate. Lexer
utilities, parser combinators, AST construction. Extracted from the typechecker's own
parser (`lib/type/static/lex.lua`, `parse.lua`) into reusable primitives. For anyone
building a language, DSL, config format, query language, or linter. Crescent already
does this for itself — the question is whether those primitives become first-class
`lib/` libraries. Also: `lib/asm` (assembler utilities) and `lib/ir` (intermediate
representation) as stretch goals for the language tooling niche.

### Missing — typechecker features (load-bearing for the ecosystem)

**Record spread union distribution** — `{ ...(A | B), k: V }` where the spread inner
type is a union. The basic `{ ...T, k: V }` spread is implemented; what remains is
distribution over union members in `env.lua:substitute_inner`. Needed for builder
patterns and mapped-type aliases instantiated with union types.

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

## The logical conclusion

The verticals compound. Web backend + CLI tooling + system primitives + package manager
+ typechecker + shell utilities + TUI = a complete userspace. Not a goal, but a natural
endpoint: if crescent is genuinely batteries-included, you could build everything above
the kernel line in it. coreutils, a shell, a service manager, a text editor. All
vendorable, all typed, all cross-platform.

The package manager already exists. The typechecker already exists. The rest is just
a long TODO list.

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
- **Protocol bindings** — a pre-typed protocol library (`lib/lsp`, `lib/mcp` (Model Context Protocol)) means
  you implement handlers and the typechecker validates them against the spec. You never
  write a schema; the types are the schema.
- **Typed holes** — `_: unknown` in a stdlib definition is a typed hole. `unknown`
  forces narrowing at every use site, propagating "not designed yet" through the type
  graph automatically. Incomplete APIs are loud, not silent.

The flywheel: more typed libraries → better discovery → easier composition → more
libraries built → repeat.
