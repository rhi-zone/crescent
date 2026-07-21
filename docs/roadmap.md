# Roadmap

Crescent's coverage of "the entire surface area of software" gets built by
dogfooding, not by mapping the space in advance. This document is the seed of
that plan — what the strategy is, what exists, what's missing, and what to
build next.

## Strategy: real apps drive library coverage

Build real, useful example apps in the categories people most commonly need.
"Real" and "useful" are load-bearing — the apps should maximize actual
utility, products people want to use, not throwaway exercises kept alive only
to justify a library underneath. A demo app can be faked; a real one can't,
and it's the can't-fake property that does the work below.

Each app pays off twice:

1. **Forces libraries into existence.** Every gap hit while building the app
   — no HTTP client, no session storage, no whatever — becomes a library,
   because the app can't ship without it. This is how the roadmap for `lib/`
   gets generated: by contact with a real requirement, not by guessing what
   might be needed.
2. **Serves as a template that lowers the cost of building similar things.**
   The finished app isn't just a consumer of the libraries it forced into
   existence — it's a fork point. Someone who needs "that kind of app" forks
   the example and writes the correction terms specific to their case,
   instead of asking an AI to generate the whole thing (substrate, ceremony,
   and all) from scratch.

Both effects compound: better libraries make the next app cheaper to build,
and each app raises the floor for whatever gets forked from it next.

## Three substrates

Three substrates emerge from existing rhi projects. Ideas import into
crescent as libraries; the project names don't follow.

`value-landscape.md` provides grounded research on where marginal value is
highest for a solo developer — which categories have the largest gaps, which
are tractable, and which are structurally out of reach. The value landscape
informs which concrete applications are worth building first, and therefore
which substrate work those applications will pull into existence.

### 1. Capture substrate (prior art: pad)

Universal ingest. Anything in, structured, linked, searchable.
Content-addressed, provenance-preserving, format-agnostic. pad
(`~/git/pad/`) is prior art to mine for design decisions, not a port target.

**What exists:**

- `lib/sqlite/` (stable) — full SQLite FFI bindings, including FTS5 support
  (`lib/sqlite/fts5.lua`) with all three content modes, normalized search
  interface, 71 tests.
- `lib/hash/` (stable) — sha256, sha1, md5, hmac, crc32, xxhash.
- `lib/crypto/` (stable) — AES-256-GCM, ChaCha20-Poly1305, HKDF.
- Format/codec coverage is extensive: JSON (tiered ffi+pure+simd), CBOR,
  MessagePack, TOML, YAML, CSV, XML, Markdown, PDF parsing (via subprocess),
  tar, PNG, iCalendar, and dozens more — all stable.
- Compression: brotli, zlib/gzip (tiered), lz4, zstd, snappy — all stable.
- `lib/search/` (stable) — SQLite FTS5 full-text search + brute-force vector
  cosine similarity + hybrid search.
- `lib/inverted_index/` (stable) — BM25-scored full-text search.
- `lib/merkle/` (stable) — Merkle tree with SHA-256.

**What's missing:**

- **Content-addressed blob store.** The next composition to build from
  existing pieces (`lib/hash`, `lib/sqlite`). Hash + dedup + insert-or-get.
  All the primitives exist; the composition does not.
- **Ingestion pipeline orchestration.** `lib/taskgraph/` exists (stable) but
  no concrete ingestion pipeline has been built on top of it for the capture
  use case.
- **Web archiving.** `lib/http/` (stable) and `lib/html/` (stable) exist but
  no archive-specific composition (readability extraction, link crawling,
  WARC format).

### 2. Display/control substrate (prior art: dusklight)

Universal interface for external data. Format-agnostic rendering + control
plane. Subsumes dedicated viewers (theoretically covers what wireshark, conky,
and similar tools do). Key ideas to import from dusklight
(`~/git/rhizone/dusklight/`): pattern-first rendering, reactive lenses,
capability-based plugin architecture, control plane for arbitrary data.

Display doesn't care about addressing scheme — it renders whatever it's
pointed at, whether content-addressed (capture) or identity-addressed
(creation).

**What exists:**

- `lib/tui/` (stable) — TUI widget layer on top of `lib/ansi`.
- `lib/ansi/` (stable) — ANSI escapes (4/8/24-bit color, cursor, control).
- `lib/layout/` (stable) — flexbox-inspired 2D box layout engine.
- `lib/widget/` (wip) — platform-agnostic reactive widget layer.
- `lib/web/reactive_dom/` (stable) — reactive DOM bindings for browser.
- `lib/reactive/` (stable) — push-based signal/computed/effect/batch.
- `lib/signals/` (stable) — auto-tracking signals (Solid/Preact style).
- `lib/canvas/` (stable) — 2D pixel canvas with PPM/PGM/BMP export.
- `lib/css_parser/` (stable) — CSS tokenizer, selector parser, specificity.
- `lib/color/`, `lib/color_palette/`, `lib/color_space/` (all stable).
- `lib/translucent-css-theme/` (stable) — glassmorphic design system.

**What's in progress:**

- **Terminal multiplexer** (commits eacf0650, 36712c59) — PTY + WebSocket +
  VT state. Early concrete consumer of display/control substrate. Vendored
  xterm.js, configurable shell.
- **Dusklight subsumption** — started in a May session but the exact scope
  of what was completed is unverified. Needs audit before building on top.

**What's missing / blocking:**

- **Async I/O adoption.** `lib/epoll` (Linux), `lib/kqueue` (macOS), and
  `lib/io_poll` (platform dispatch) provide readiness notification.
  `lib/async` provides the promise/coroutine abstraction with a
  poller-driven event loop (133 assertions including poller-driven suite).
  Integration is complete. The gap: no existing server or multiplexed
  connection code uses the integrated loop yet. This is the main blocker for
  live control surfaces.
- **Reactive deduplication.** `lib/reactive/` (explicit dep arrays) and
  `lib/signals/` (auto-tracking) are parallel implementations. Pick one
  before building reactive display surfaces on top. Open question.
- **`lib/reactive_optics`** — signals focused through optics (lenses, prisms,
  traversals). The novel piece: optics as structure of derived state, signals
  as propagation. `lib/fp/optics` exists. Prior art: `~/git/rhizone/rainbow/`
  (TypeScript prototype). Not yet implemented.

### 3. Creation substrate (prior art: scribble)

Universal composition for internal creation. Pluggable, extensible,
composable. Can scale to zero (mspaint-level). Key ideas from scribble
(`~/git/rhizone/scribble/`): append-only event log, content-addressed assets,
layer-based composition, live editor-runtime dissolution.

The minimum creation primitive is a mutable, identity-addressed object (not
content-addressed — creation makes new things, not deduplicates existing
ones). No fixed schema, typed fields, or constraints — convention over spec.
At minimum: identity-addressed mutable objects with edges between them, plus
persistence. The data layer is simpler than expected; the hard part is making
it feel like creation, which is display's job.

**What exists:**

- `lib/ecs/` (stable) — SQLite-backed entity-component store. Integer IDs,
  named typed components (JSON-encoded), `ON DELETE CASCADE`. 30 assertions.
  Intentionally minimal.
- `lib/entity_component/` (stable) — in-memory ECS with query iterator,
  system runner, event bus. 70 assertions. Parallel to `lib/ecs/`.
- `lib/command/` (stable) — command pattern with undo/redo, batch,
  transaction, macro record/play. 66 assertions.
- `lib/crdt/` (stable) — data-type CRDTs (gcounter, pncounter, lww_register,
  tpset, orset, lww_map). 69 assertions.
- `lib/event_sourcing/` (stable) — event store, aggregates, projections,
  sagas, snapshotting. 105 assertions.
- `lib/canvas/` (stable), `lib/svg/` (stable), `lib/image_processing/`
  (stable) — visual creation primitives.

**What's missing:**

- **Text/sequence CRDTs.** `lib/crdt` covers data-type CRDTs but not
  RGA-style collaborative text editing or the collaborative sync protocol
  (state vectors, update encoding, awareness). Goal is y.js protocol
  compatibility so Lua servers can interoperate with y.js browser clients.
  For now, application-specific sync protocols (e.g. terminal state
  replication) are simpler and sufficient.
- **Identity-addressed mutable object graph.** The ECS provides entity +
  components but not the object-with-edges-and-persistence primitive
  described in the substrate definition. Whether ECS is the right shape or
  whether a separate `lib/object_graph` (or similar) is needed is an open
  question — derive from a real consumer.

### Shared infrastructure across substrates

The three substrates share a common object+edges+persistence layer but
differ in addressing: capture is content-addressed (dedup matters), creation
is identity-addressed (mutability matters), display is address-agnostic.

**What exists (shared):**

- `lib/sqlite/` (stable) — persistence layer for all three.
- `lib/platform/` (stable) — app format (gzipped tar + manifest), capability
  sandbox, cap factories, daemon, session management. Multiple entrypoints
  (dom, mcp, tui, headless) in one file.
- `lib/http/` (stable) — HTTP server + client.
- `lib/websocket/` (stable) — WebSocket framing.
- `lib/web/` (stable) — web app framework (middleware, routing, cookies,
  CSRF, static).
- `lib/jsonrpc/` (stable) — JSON-RPC 2.0 dispatcher.
- `lib/lsp/` (wip) — LSP method bindings on top of jsonrpc.
- `lib/mcp/` (wip) — MCP server on top of jsonrpc.
- `lib/cli/` (stable), `lib/cr/` (stable) — CLI infrastructure.
- `lib/test/` (stable) — test runner, property testing, fuzz testing,
  integrated shrinking.
- `lib/js_types/` (stable) — DOM/browser/JS host API type declarations
  (2078 lines).
- Browser-side isolation pipeline: `lib/js_realm_sandbox/`, `lib/js_cap_bridge/`,
  `lib/js_caps/`, `lib/js_pack_host/`, `lib/js_pack_validator/` — all initial
  status. Pack iframe pipeline with capability bridge.

**What's in progress (shared):**
- **`lib/lua2ts/`** (wip) — Lua-to-TypeScript transpiler. Handles core
  constructs (local, operators, method calls, require-to-ESM, for loops,
  ipairs/pairs, pcall try/catch, type annotations). 112 tests. Browser
  targeting strategy depends on this — affects all three substrates if they
  need browser UIs.
- **`lib/pkg/`** (wip) — package manager. Foundation only (semver, manifest,
  lock parsers); install algorithm not yet implemented.
- **`lib/type/analysis/`** (wip) — agnostic static-analysis substrate.
  Propositional + lambda rungs done; cyclic-fixpoint and STLC rungs next.

**What's missing (shared):**

- **`lib/reactive_optics`** — see display/control substrate above.
- **Async I/O adoption** — see display/control substrate above. Blocks all
  substrates for anything network-bound or live.
- **Cap'n Proto** (`lib/protocol/capnp`) — zero-copy binary serialization.
  Genuine capability gap over JSON/CBOR for high-throughput IPC.

## Where the value landscape maps

`value-landscape.md` ranks categories by marginal value x tractability for a
solo developer. The mapping to substrate work:

**Tier 1 #4: Developer tools / infra libraries** — this is crescent itself.
The typechecker, package manager, LSP, MCP, test infrastructure, and the
library ecosystem are all direct contributions here. The most tractable
category with the strongest track record of solo-developer success.

**Tier 1 #5: Data format conversion** — crescent's codec/format coverage is
already extensive (40+ formats, most stable). The remaining gap is the
integration/UX layer: a tool that routes between formats with a discoverable
interface, built on the existing codec libraries.

**Tier 1 #1: Personal finance / micro-business bookkeeping** — maps to
capture substrate (transaction ingest, search, persistence) + creation
substrate (ledger as mutable identity-addressed objects) + display substrate
(rendering financial data). A bookkeeping app would be a high-value concrete
consumer that drives all three substrates. `lib/finance/` (stable, 121
assertions) and `lib/money/` (stable, 85 assertions) provide financial math
primitives. `lib/decimal/` (stable) provides exact arithmetic.

**Tier 2 #8: Local-first structured data tools** — maps directly to the
display + creation substrates. A spreadsheet-database hybrid would exercise
the reactive display layer and the mutable object persistence layer.
`lib/spreadsheet/` (stable, formula eval + dep tracking) and
`lib/reactive_db/` (stable, live queries) are starting points.

**Cross-cutting: offline-first, non-English** — aligns structurally with
crescent's zero-dependency, vendor-first philosophy. The ~12MB total
ecosystem size (vs 433MB for a typical Node.js app) and pure-Lua baseline
make crescent naturally suited to constrained environments. `lib/i18n/`
(stable) and `lib/locale/` (stable, 15+ CLDR plural rules) exist.

Which specific application to build first — and therefore which substrate
work gets pulled forward — is an open question informed by the value
landscape, not a predetermined ordering.

## Concrete sequencing

The concrete thing drives the substrate. What follows is ordered by
dependency (what unblocks what), not by importance.

### Now: in-progress work

1. **Terminal multiplexer** — active (commits eacf0650, 36712c59). PTY +
   WebSocket + VT state. First concrete consumer of display/control
   substrate. Exercises: `lib/async`, `lib/websocket`, `lib/ansi`,
   `lib/platform` (app format).


### Next: unblocking work

4. **Async I/O adoption** — the single highest-leverage gap. Integration is
   complete (`lib/async` wired to `lib/io_poll`, tested). The gap is that no
   production server or network code uses the integrated loop. First
   consumer: the terminal multiplexer's WebSocket server, or `lib/http`
   server with async accept. Unblocks: concurrent HTTP servers, multiplexed
   connections, live control surfaces, everything network-bound.

5. **Reactive deduplication** — pick `lib/reactive/` or `lib/signals/`
   before building reactive UI surfaces. Open question: which one.
   `lib/reactive/` is explicit-dep push-based; `lib/signals/` is
   auto-tracking (Solid/Preact style). Both are stable with similar
   assertion counts. Decision needed before `lib/reactive_optics` can be
   built.

6. **Content-addressed blob store** — compose from `lib/hash/sha256` +
   `lib/sqlite`. Hash + dedup + insert-or-get. All primitives exist; the
   composition is straightforward. Unblocks: capture substrate ingestion.

7. **Dusklight subsumption audit** — verify what was completed in the May
   session. Determine which dusklight ideas (pattern-first rendering,
   reactive lenses, control plane) have been imported and which remain.
   Unblocks: knowing what display/control substrate work remains.

### Then: substrate consumers

8. **`lib/reactive_optics`** — once reactive dedup is resolved. Signals
   focused through optics. `lib/fp/optics` already exists. Prior art:
   rainbow (TypeScript). Unblocks: reactive UI for both browser
   (`lib/web/reactive_dom`) and terminal (`lib/tui`).

9. **First concrete application** — which one depends on the value landscape
   decision. Candidates informed by `value-landscape.md`:
   - A local-first bookkeeping tool (Tier 1 #1) — drives all three
     substrates, has the highest marginal value x tractability.
   - A format conversion tool (Tier 1 #5) — drives the codec integration
     layer, most tractable category.
   - A structured data viewer/editor (Tier 2 #8) — drives display + creation
     substrates.
   Which to build first is an open question.

10. **Package manager install algorithm** — `lib/pkg/` has semver, manifest,
    lock parsers. The install algorithm (dependency resolution, fetch,
    extract) is not implemented. Needed for ecosystem distribution beyond
    git-clone.

### Ongoing: developer tools

- **`lib/doc/`** (wip) — docgen from typed API source.
- **`lib/type/search/`** (wip) — Hoogle-style type search. Useful once the
  library count makes manual discovery hard.

### Parked: typechecker replacement

The legacy typechecker (`lib/type/static/`, v2/v3 lineage, 53K lines) is the
working tool and gates all commits via `.githooks/pre-commit`. Despite
architectural issues (105+ ad-hoc instances documented), it remains in use.

A replacement has been attempted 8 times (v4, v5, v6, v7, framework, v9,
toy_checker, declc) without producing a viable successor. The last viable
candidate (v9) measured ~3% hard-true precision — not acceptable. The
follow-up (toy_checker) hit an unsolved hard problem: dynamic constraint-graph
edge direction in the type inference engine.

**Status:** Parked, not abandoned. Autonomous agent-directed development was
declared dead by owner verdict as of 2026-07-08 (supervision cost exceeded
value). Building applications and libraries can proceed without a new
typechecker; applications simply typecheck against the legacy checker.

**To resume:** Requires either (1) solving the hard problem, or (2) finding a
fundamentally different approach that avoids it entirely.

## Duplicate clusters

The inventory has ~25 duplicate library pairs/triplets (see
`docs/duplicate_clusters.md`). Notable ones relevant to substrate work:

- `lib/reactive/` vs `lib/signals/` — reactive primitives, must pick one.
- `lib/ecs/` vs `lib/entity_component/` — SQLite-backed vs in-memory ECS.
- `lib/json/` vs `lib/format/json/` — standalone vs tiered JSON.
- 5 FSM implementations (`state`, `state_machine`, `statemachine`,
  `state_machine_hsm`, `fsm`).
- `lib/json_schema/` vs `lib/jsonschema/` vs `lib/schema_validator/` vs
  `lib/validate/` vs `lib/validation/`.

Consolidation should happen as substrate consumers exercise these libraries
and reveal which implementation is the right one. Don't consolidate in the
abstract — let real use cases pick the winner.

## Open questions

- **Which substrate gets built first?** Informed by the value landscape but
  not predetermined. The old heuristic ("capture and display first, creation
  most optional") is superseded by whatever the value landscape's
  marginal-value x tractability analysis points to.
- **Which reactive library?** `lib/reactive/` vs `lib/signals/`. Blocks
  `lib/reactive_optics` and everything downstream.
- **Browser targeting strategy.** `lib/lua2ts/` (wip, 112 tests) is the
  mechanism. Current status and completeness not fully verified. Affects all
  three substrates if they need browser UIs.
- **Library names for imported ideas.** The three substrates import ideas
  from pad, dusklight, and scribble. The library names in crescent are not
  decided.
- **Object graph shape.** Whether `lib/ecs/` is the right primitive for the
  creation substrate's identity-addressed mutable objects, or whether a
  separate library is needed. Derive from a real consumer.
- **Dusklight subsumption scope.** What was completed in the May session
  needs verification.

## Relation to the Jevons thesis

This strategy is a direct instance of the substrate lever described in
[Jevons Paradox and Substrates](https://docs.rhi.zone/essays/jevons-paradox-and-substrates):
an agent decomposes a task into subagents when the task "looks big," and what
makes it look big is usually encoding overhead, not the actual novel logic.
Libraries reduce that overhead for anyone building on crescent; the example
apps reduce it further by covering common use cases end-to-end, so the
starting point for a new app is a working one, not an empty one. No abstract
taxonomy of "software's surface area" is needed — the coverage hierarchy
emerges from use.
