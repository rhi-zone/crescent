# Typechecker v5 — Unframed Architecture Discovery

Eight Explore agents fanned out across ~30 sibling repos in the rhi ecosystem on 2026-05-22. Each agent was prompted to describe its targets' architecture **on their own terms** — no reference to crescent, no reference to type checking, no synthesis. Per F12 (no pre-loaded subagent prompts) and F14 (no slacking off; as wide as practical).

Synthesis against v5 constraints is a separate step and is NOT performed in this file.

Total coverage: ~1.4M LOC. Implementation languages: Rust (dominant), TypeScript/Bun, Lua, JavaScript.

---

## Code Intelligence

### normalize (`~/git/rhizone/normalize`) — Rust, ~116K LOC, 31 crates

AST-based code intelligence CLI understanding 98 languages via tree-sitter grammars; exposes structure (symbols, imports, calls) and code health.

**Load-bearing decisions:**
1. **Language trait as trait objects** (`normalize-languages/src/traits.rs`). Each of 98 languages implements `Language` + optional `LanguageSymbols`/`LanguageEmbedded`. Dynamic dispatch via registry; no codegen-per-language compile cost.
2. **Tree-sitter grammar loading via FFI** (`normalize-grammars`). Grammars compile to `.so`, loaded at runtime by `GrammarLoader`. Decouples grammar versions from binary.
3. **SQLite facts database** (`normalize-facts`). Extracted symbols/imports/calls stored in `.normalize/facts.db`, queryable independently. Commands gracefully degrade without index.
4. **OutputFormatter trait** (`normalize-output`). All commands output through `format_text()`/`format_pretty()` — consistent across 18 commands and server modes (MCP, HTTP, LSP).
5. **Shadow git for edit history** (`normalize-shadow`). Structural edits recorded in `.normalize/` as mini git refs.

**Surprises:** 31 crates for a CLI (heavy module org driven by pluggable server modes); `normalize-cli-parser` introspects other tools' help text; `normalize-language-meta` separate from `normalize-languages` suggests past iteration.

### gels (`~/git/rhizone/gels`) — Rust, ~1K LOC, 4 crates

Trait-based grammar inference engine that detects syntactic patterns from example code to identify or synthesize tree-sitter grammars for unknown languages.

**Load-bearing decisions:**
1. **Pluggable `SyntaxTrait` detectors** — 18 detector impls (delimiters, keywords, operators, comments); composable, confidence-scored.
2. **Profile-based identification.** Each known language has a `Profile` of expected traits + confidence weights; threshold 0.5 → identified.
3. **Grammar synthesis via fragment merging.** Per-trait detector outputs a grammar fragment; merged at confidence threshold 0.3 into unified `grammar.js`.
4. **Token-first architecture.** Tokenize before trait detection; no AST parsing. Enables detection on unknown syntax.

**Surprises:** Tiny (1K LOC); simple weighted-sum confidence (no probabilistic model); synthesized grammars not validated against tree-sitter; profile registry hardcoded.

### motif (`~/git/rhizone/motif`) — Rust, ~6.5K LOC, 2 crates

Structural exploration of mathematics via universal algebra. Rust types (Signature, Theory, Axiom) compile to egglog DSL for equality saturation.

**Load-bearing decisions:**
1. **Type-to-egglog compilation.** Rust structs emit egglog via `.to_egglog()`. `Signature` defines operations + arities; `Theory` contains axioms; `SaturationConfig` tunes iteration depth + rulesets.
2. **Equality saturation via egglog.** `Theory::equiv()` checks if two expressions are equal within an e-graph. Incomplete: only proves equalities whose intermediates exist in the graph.
3. **Algebraic theories as modules** (`src/theories/`). Group, ring, lattice, etc. — each emits its own axioms + rewrite rules.
4. **egglog naming constraints** (CLAUDE.md). Reserved primitives (`neg`, `abs`, `not`) cannot be constructors — forces `negate` for algebraic negation. Rewrite safety enforced.

**Surprises:** Heavy reliance on egglog internals (IL blowup from distributivity, iter_limit tuning); `discover_equiv_classes` decomposition suggests past scalability issues with naive cross-product; only 6.4K LOC — most domain knowledge lives in `theories/` modules.

### ascent-interpreter (`~/git/ascent-interpreter`) — Rust, ~23K LOC, single crate, 5 modules

Interpreter and x86-64 JIT compiler for Ascent Datalog, with stratified evaluation and inline assembly codegen for hot paths.

**Load-bearing decisions:**
1. **Negation as `Aggregation` in IR.** Negation lowers directly to IR as a special aggregation, not via library. Unifies negation + aggregation handling in evaluator.
2. **Simple 2-stratum evaluation.** Base rules evaluate first; aggregation rules second. Full SCC-based stratification not yet needed.
3. **Inline JIT assembly codegen** (`src/eval/jit/`). Hot rule shapes compiled to native x86-64 via `dynasm!` macro. Cranelift backend deleted (commit `0258e88`). Ineligible rules fall back to interpreted evaluation.
4. **Packed interned type model.** String values interned via `InternTable`, stored as 32-bit IDs. `jit_cmp_interned` callback reconstructs fat pointer for Lt/Le/Gt/Ge; Eq/Ne safe on raw IDs.
5. **Cranelift → ASM → no JIT** progression. Stages 1–4 used Cranelift; 3c–3e implemented in ASM; goal: standalone x86 with no external compiler.

**Surprises:** Extreme perf tuning via profiling (`perf stat`); CLAUDE.md catalogs 15+ micro-optimisations (batch native flush, dedup pre-reserve, register alloc tweaks); 2.1× slower than LLVM-compiled `ascent_macro` at n=20, target parity; brittle layout decisions (`PackedScanInfo` field ordering caused 1.49–1.73× regression when changed); `gen` Rust 2024 keyword forces `generator` alias.

---

## Generation / IR / Codegen

### unshape (`~/git/rhizone/unshape`) — Rust, ~160K LOC, 48 crates

Constructive generation and manipulation of 3D meshes, audio, 2D vector graphics, procedural textures, noise, rigging, physics, procedural generation — unified through a type-parametric operation graph.

**Load-bearing decisions:**
1. **Type-parametric operations as values** (`unshape-op`). All operations are serializable structs with `apply()`. Enables lazy evaluation, DAG composition, introspection, replay.
2. **General-internal, constrained-API pattern.** Store full connectivity internally (HalfEdgeMesh, AudioGraph, TextureGraph); expose simplified APIs (Path, IndexedMesh, Chain, Expr) for common cases.
3. **Domain independence.** Mesh, audio, texture, vector ops are separate crates with no cross-domain dependencies; each uses glam for math but solves its own topology problem.
4. **Lazy evaluation via Field trait** (`unshape-field`). Procedural generation (noise, fractals, SDFs) computed on-demand; enables streaming and infinite domains.
5. **No DSLs.** All procedural behavior expressed as Rust APIs with combinators; no custom mini-notation. Keeps IDE support and error messages clear.

**Surprises:** 48 crates is too many to cognitively manage; tree-shaking assumptions don't fully hold. Post-hoc fragmentation: `unshape-image` went from 12,984 lines to 17 submodules — suggests crate boundaries were too coarse initially. Abandoned "bindings branch" for cross-domain analysis.

### wick (`~/git/rhizone/wick`) — Rust, ~53K LOC, 9 crates

Minimal expression language that parses once and compiles to multiple backends (WGSL, Cranelift, Lua, C, Rust) with domain-specific numeric libraries (scalar, linalg, complex, quaternion).

**Load-bearing decisions:**
1. **Syntax-only core** (`wick-core`). Parser + AST are domain-agnostic. Conditionals and functions are feature-gated. Each domain plugs in its own `FunctionRegistry<T>` and `eval<T>()`.
2. **Backend-per-domain, not backend-per-language.** Each domain (scalar, linalg) has self-contained backends (WGSL, Lua, Cranelift) behind feature flags. Avoids standalone backend crates exploding dependency counts.
3. **Generic over numeric type.** Operations are `T: Numeric` (f32, f64, i32, i64) — same expression evals as shader (f32) or JIT (f64) without duplication.
4. **Cross-domain composition via explicit functions.** Rotating a Vec2 by a complex number is `rotate(vec2, complex)`, not `complex * vec2`. Clearer intent, fewer magical coercions.

**Surprises:** Feature-gated syntax is friction (load a domain without `func` feature → expression doesn't eval; error path unclear). No comparison semantics for non-scalar types (`if magnitude(z) > 0.5` works; `z1 > z2` doesn't). Let-binding inlining for WGSL/GLSL backends is transparent but invisible in cost. Unresolved: quaternion component-order convention `[w,x,y,z]` vs `[x,y,z,w]` deferred.

### concord (`~/git/rhizone/concord`) — Rust, ~1.2K LOC, 2 crates

API bindings code generator parsing API specs (OpenAPI, FFI headers) into a unified IR and emitting language bindings (Rust, TypeScript, Python, …).

**Load-bearing decisions:**
1. **Extensible annotations over hardcoded constraints** (`ir.md`). Constraints/bounds/modifiers are `Annotation { kind: String, value: AnnotationValue }`. Generators handle known kinds, ignore/warn on unknown. Future-proofs against spec evolution.
2. **Unified IR as a superset.** One IR bridges HTTP (OpenAPI), FFI (C headers), and future sources. Goal: no information loss during parsing; targets decide how to map.
3. **Confidence-based code generation.** Each binding scored during codegen; high confidence → trust, low confidence → flag with comments for review. Prefers incomplete generation over refusing complex cases.
4. **Specialcases system for overrides.** Post-generation patches via TOML files (`schemas/<api>/specialcases.toml`); customisation without forking, version-controlled, reapplied on regen.

**Surprises:** Extremely lean MVP (1.2K LOC); only OpenAPI parsing, only Rust emission; vast gap to production use. Known issues (`Vec` not `Vec<Pet>`, undefined `ApiError`, string enums unhandled) deprioritised in favour of architecture. Hotspot: `to_snake_case()` cyclomatic complexity 34.

### server-less (`~/git/rhizone/server-less`) — Rust, ~74K LOC, 6 crates

Rust macro system projecting plain `impl` block methods onto arbitrary protocols (HTTP, CLI, WebSocket, MCP, JSON-RPC, GraphQL, gRPC) and generating schema files (OpenAPI, Proto, Cap'n Proto, Thrift, Smithy) from a single source.

**Load-bearing decisions:**
1. **Protocol projection as the core abstraction.** Methods are pure Rust; each protocol is a projection that wraps them with framing (HTTP routing, CLI arg parsing, JSON-RPC dispatch). Users annotate once with `#[http]`, `#[cli]`, `#[mcp]`, …
2. **Unified Context extraction across protocols.** HTTP → headers, CLI → env vars, WebSocket → upgrade headers. Context extracted once and injected as an optional method parameter. Deferred for MCP (pure functions) and GraphQL (has its own ResolverContext).
3. **Nested Config with merging semantics.** `#[derive(Config)]` generates `Config::load(sources)`; `MergeFile` supplements rather than replaces (global + project pattern). Nested structs flatten in TOML.
4. **Per-protocol OpenAPI composition.** Each macro generates `XXX_openapi_paths()`, collected by `#[openapi]` or `#[serve(openapi=true)]` into a combined spec.

**Surprises:** MCP context decision deferred (MCP tools are pure functions, no inherent request context — workaround fragile). GraphQL bridging unimplemented. Feature sprawl: 13+ protocols and schemas, huge TODO list, prioritisation unclear. "Did you mean X?" suggestions exist but no `cargo serverless explain <topic>` for deeper questions.

---

## Data Transformation

### tiltshift (`~/git/rhizone/tiltshift`) — Rust, ~11.5K LOC, single crate

Iterative binary format reverse engineering via signal extraction and statistical heuristics.

**Load-bearing decisions:**
1. **Signal-first, hypothesis-second pipeline.** 16 signal extractors (magic, length-prefix, entropy, chisq, bytecode, compress, alignment, padding, offset-graph, ngram, numeric, strings, tlv, varint, chunk, packed) produce typed enums with confidence scores. Separate synthesis pass converts signals into ranked composable interpretations.
2. **Session-based caching** (`session.rs:12-42`). `.tiltshift.toml` sidecar stores cached signals and user annotations keyed by file size.
3. **Entropy classification as structural lens** (`types.rs:30-60`). Four-tier enum (Structured < 3.0, Mixed, Compressed, HighlyRandom > 7.5 bits/byte) grounds all signal interpretation. Coarse granularity avoids false precision.
4. **Multi-signal compounding** (`hypothesis.rs:30-50`). Pass 1.5 explicitly merges overlapping/reinforcing signals (magic + chunk boundary, varint + TLV) into higher-confidence composites.

**Surprises:** Known cache invalidation flaw — file identity is size-only, no hash/mtime. Hypothesis engine half-implemented. 16 distinct signal types scatter integration logic across 5K+ lines of `signals/`.

### paraphase (`~/git/rhizone/paraphase`) — Rust, ~15.3K LOC, 14 crates

Type-driven data transformation route planner using property-bag matching to find conversion paths through available converters.

**Load-bearing decisions:**
1. **Property bag as sole type descriptor.** Data has no structural schema; just key-value pairs. Converters match on property predicates, not static types. Enables late binding of domain-specific semantics.
2. **A* planner with cost heuristics** (`planner.rs:50-100`). SearchNode tracks (properties, cardinality, steps, cost, estimated_total). Converters declare cost metrics; planner finds lowest-cost path by optimisation target (Quality, Speed, Size). Max depth 10.
3. **ConverterDecl as interface descriptor.** Separates declaration (inputs, outputs, cost) from implementation. Named ports, list vs single cardinality.
4. **Format backends as thin adapters.** Serde formats (JSON, YAML, TOML, …) wrapped as converters with `PropertyPattern` matching.

**Surprises:** `paraphase-plugin` is a stub ("TODO: Add #[paraphase_converter] proc macro"). Serde backend (2.9K LOC) dwarfs all others combined. Cardinality split is runtime concern, not compile-time — errors surface late.

### rescribe (`~/git/rhizone/rescribe`) — Rust, ~585K LOC, 17+ crates

Universal document conversion library with open node kinds, extensible properties, and fidelity tracking for lossless intermediate representation.

**Load-bearing decisions:**
1. **Open NodeKind + Properties** (`rescribe-core/node.rs`). `Node.kind` is `struct NodeKind(String)`, not a fixed enum. `Properties` are untyped key-value (`HashMap<String, PropValue>`). Writers interpret `style:*` and `layout:*` properties at emit time.
2. **Fidelity tracking** (`fidelity.rs`). `ConversionResult<T>` wraps output + `Vec<FidelityWarning>`. Four severity levels (Info, Minor, Major, Error); audits what was lost.
3. **Embedded ResourceMap** (`resource.rs`). First-class resource handling (images, fonts, data) separate from document structure. Resources have stable IDs; nodes reference them, not URIs.
4. **Modular reader/writer pairs.** Each format (Markdown, HTML, LaTeX, PDF, DOCX, EPUB) has independent `rescribe-read-*` and `rescribe-write-*` crates; opt-in via Cargo features.

**Surprises:** 54 readers, 64+ writers — most incomplete (README: "writer is not production-grade"). Crate count suggests breadth, substance is sparse. Fuzz harness excluded from workspace. Properties system re-invented locally rather than reusing paraphase's property bags.

### reincarnate (`~/git/rhizone/reincarnate`) — Rust, ~142.5K LOC, 9 crates

Bytecode decompilation and transformation framework lifting legacy software (Flash, GameMaker, Twine) into modern TypeScript/Rust via typed IR and pluggable passes.

**Load-bearing decisions:**
1. **Three-phase pipeline.** Frontend (extract bytecode → IR) → Transform passes (DCE, type inference, structurize) → Backend (emit TypeScript/Rust). Each phase is a pluggable trait. Frontends inject engine-specific passes after standard pipeline.
2. **Entity arena with typed references** (`entity.rs`). `define_entity!` macro creates newtype over `u32`. `PrimaryMap<K, V>` is append-only vec keyed by entities. Pointer-free IR, stable references across passes.
3. **SSA-like IR with block arguments** (`ir/block.rs`, `ir/inst.rs`). `BlockParam`, `BlockId`, `Terminator` (Jump/Switch/Return). Avoids variable renaming; control flow explicit. Structurize pass converts back to nested statements for codegen.
4. **Lossless GameMaker lifting** (frontend-gamemaker: 43K LOC). Pattern restoration (logical ops from arithmetic), instance type-flow inference, GML builtin catalog.

**Surprises:** GameMaker frontend dwarfs others (43K LOC vs Flash 4.5K). README lists Silverlight/VB6/Java Applets as Planned — none implemented. TypeScript backend is the only backend despite infrastructure suggesting pluggability. Checker exists only for TypeScript.

---

## Runtime / Interface

### rainbow (`~/git/rhizone/rainbow`) — TypeScript/Bun, ~8K LOC, 3 packages

Optics-based reactivity framework — lenses and prisms as composable first-class values for structural updates and derived state.

**Load-bearing decisions:**
1. **Algebraic optics as the model** (`packages/core/src/optic.ts`). `Lens<A, B>` (total focus, structure-preserving) and `Prism<A, B>` (partial focus, case extraction) as distinct interfaces; both implement shared `Optic` supertype with `view()` and `review()`. Laws codified in tests.
2. **Signal-based reactivity with batch deduplication** (`signal.ts:20-40`). Subscriber notifications queued during batch context, flushed when batch depth reaches zero; deduplicated by function identity in a Map.
3. **Optic composition preserves type safety** (`lens.ts:26-30`). `composeLens<A, B, C>` chains focus operations with full static verification.
4. **Runtime-agnostic algebra** (CLAUDE.md). Core contains no Node-specific APIs; framework adapters (React, Vue) are separate.

**Surprises:** No DSL — optics are plain functions/objects; composition chains can be verbose. Router package exists but underdocumented relative to core; relationship to optic composition not immediately clear.

### moonlet (`~/git/rhizone/moonlet`) — Rust + Lua, ~10.5K LOC Rust, 3 internal crates + 9 plugin crates

Capability-based Lua runtime with dynamically-loaded C ABI plugins for multi-provider LLM, embedding, filesystem, database, code-analysis operations.

**Load-bearing decisions:**
1. **Capability-based security via Rust-backed userdata.** Plugins return opaque capability objects injected into Lua as `caps` table; scripts cannot forge capabilities or exceed granted permissions. Policies define which capabilities instantiate.
2. **Plugin ABI versioning as contract** (`plugin.rs:19-21`, ABI_VERSION=1). Plugins export `moonlet_plugin_info()` + `luaopen_moonlet_{name}()`. Loader validates ABI version; keeps `Library` handles alive to prevent unload-and-reload attacks.
3. **Plugins as dynamic `.so`/`.dylib`/`.dll` libraries.** Loader discovers at runtime from search paths. Registry key pattern prevents GC of module tables.
4. **Memory store as SQLite with metadata.** `MemoryStore` backs persistent key-value storage with context, weight, metadata; designed for session state + checkpoints.

**Surprises:** Nanites (task graphs) mentioned as orthogonal but not present in this repo — boundary architectural, not enforced in code. Agent script (`scripts/agent.lua`) monolithic state machine.

### dusklight (`~/git/rhizone/dusklight`) — TypeScript + Rust, ~2.2K LOC, 8 packages

Format-agnostic universal UI client with extensible data sources, parsers, renderers, transports; includes Marinada expression language for layout and reactivity.

**Load-bearing decisions:**
1. **Plugin registry pattern.** `SourceFactory`, `Parser`, `Renderer` interfaces; `AppRegistry` looks up by ID/content-type.
2. **LayoutOptic as evaluated expression.** A `LayoutOptic` is an `Expr` (Marinada s-expression) that evaluates at runtime to a Lens or Traversal; optics are dynamically computed based on data and config.
3. **Marinada as core reactive model.** S-expressions as JSON arrays; dual-backend (JS JIT in browser, Rust/WASM for heavy work); algebraic effects and linear types as language features, not libraries. `lib:std` (map, filter, reduce) implemented in Marinada itself.
4. **Capabilities as opaque objects.** `Cap<T>` is ID + methods dict; called via Marinada's `call.method` operator.

**Surprises:** `dusklight-agent` (Rust crate) loads Lua runtime but integration with JS packages unclear. Frontend bundle pre-built before `cargo run` — unusual ceremony for full-stack.

### deskspace (`~/git/rhizone/deskspace`) — Rust, ~1K LOC, single crate

File workspace HTTP server (Axum) with pluggable projection system for viewing/rendering/manipulating file resources.

**Load-bearing decisions:**
1. **Projection trait as plugin interface.** Async trait `Projection<T>` with `can_handle(resource) -> bool` and `project(resource, workspace) -> T`; registry dispatches by trait object.
2. **Workspace as path sandbox.** Central `Workspace` validates paths to prevent traversal; canonicalises and rejects escapes.
3. **CSRF middleware on mutating requests.** Rejects POST/PUT/DELETE unless Origin is localhost.
4. **AppState as `Arc<>` to routes.** Workspace and `ProjectionRegistry` shared by reference; projections registered upfront (dir-list, text-raw, text-markdown, image-preview).

**Surprises:** Only 1K LOC for a full HTTP server + projection system — minimal but complete. UI directory lookup heuristic (cwd → binary parent → `../..` → `ui` fallback) is fragile.

---

## Infrastructure

### nanites (`~/git/rhizone/nanites`) — Rust, ~29K LOC, 3 crates

Stateless function-call orchestration — tasks as pure data, dynamic dependency graphs, LLM as oracle rather than agent.

**Load-bearing decisions:**
1. **Task as serializable struct, not closure** (`nanites-core/src/task.rs:45-67`). Tasks carry configuration but not inputs; inputs arrive at execution via `Task::run()`. Enables serialisation, distributed execution.
2. **Type-erased boundary via `DynTask`** (`dyn_task.rs`). Typed tasks (T → U) wrap into `DynTask` at runtime boundary; type checking at definition time, dynamic dispatch at execution.
3. **Frontier (pending tasks) vs ExecGraph (audit record)** (`frontier.rs`, `exec_graph.rs`). Frontier shrinks as tasks complete; ExecGraph monotonically grows as immutable lineage. Decouples live execution state from audit.
4. **Recursive decomposition via `ctx.spawn`** (`ctx.rs:13-80`). No upfront graph declaration. Tasks spawn subtasks dynamically; `ctx.spawn_dyn` for runtime-constructed pipelines.
5. **Two task kinds with pluggable executors** (`executor.rs`). Pure `Task` implements `run()`. `IoTask` is marker-only data; registered `TaskExecutor` injects resources at execution.

**Surprises:** `nanites-rig` is a 44K-LOC single-file monolith — all concrete task implementations for a software-engineering agent in one module. Checkpoint/restoration machinery exists but use unclear. Philosophy embedded but tests/integration examples sparse.

### interconnect (`~/git/rhizone/interconnect`) — Rust, ~11K LOC, 4 main + 12 connector crates

Intent-based protocol substrate for single-authority rooms where clients connect, send intents, receive snapshots, can transfer between authorities with passport validation.

**Load-bearing decisions:**
1. **Single authority per room, no consensus** (`authority.rs:78-123`). Each room has one `Authority` that owns state. Clients send `Intent`; authority replies with `Snapshot`. No state merging or conflict resolution.
2. **Intent-based, not state-based protocol** (`message.rs`). Clients declare intent; authority computes. Cannot inject state.
3. **Two-layer: Substrate + Simulation.** Substrate (static room definition) is replicated and survives authority loss. Simulation (live state) is ephemeral, single-authority. Enables ghost mode when authority is down.
4. **Passport and import policies** (`transfer.rs`). When transferring between authorities, passport goes through `on_transfer_in()` — each authority validates and sanitises.
5. **Transport-agnostic wire protocol** (`wire.rs`). JSON-serialised, transport pluggable.

**Surprises:** 12 connector implementations (Discord, Slack, Matrix, IRC, Telegram, GitHub) — most empty stubs. `SimpleAuthority` vs `Authority` trait split unclear in purpose.

### myenv (`~/git/rhizone/myenv`) — Rust, ~25K LOC, 4 crates

Configuration manager generating per-tool native config files from a central `myenv.toml` manifest with variable substitution and schema validation.

**Load-bearing decisions:**
1. **Single source of truth, invisible at runtime.** `myenv.toml` defines all tool configs; tools read only generated native configs. Tools decoupled from myenv.
2. **Schema-driven validation.** Tools expose schema via `tool --schema` (JSON Schema). Myenv validates generated configs before writing.
3. **Variable substitution across sections.** `[variables]` section + `{{variable}}` syntax in tool configs allows reuse.
4. **Seed-based scaffolding** (`myenv-seed`). Seeds are project templates with `seed.toml` metadata + `template/` directory.
5. **Pull-and-merge workflow** (`pull.rs`). Ability to pull existing tool configs back into `myenv.toml`. Reverse operation for incremental management.

**Surprises:** `myenv-core` named "Nursery" internally; rename happened, docs not fully updated. Repology integration purpose unclear. Lockfile machinery exists but workflow undocumented.

### portals (`~/git/rhizone/portals`) — Rust, ~8K LOC interfaces + protocols, 24 interface crates + 43 backend crates

WASI-inspired capability-based async standard library with trait interfaces (24 domains), implementations for native/WASM/portable/mock backends.

**Load-bearing decisions:**
1. **Trait-only interfaces, no implementations.** Each interface crate defines only traits (`HttpClient`, `Resolver`, `Writer`). No platform-specific code in interfaces.
2. **Backend layering: native, WASM, portable, mock.** A single interface can have 3+ implementations on different targets.
3. **Protocols as shared wire format** (`portals-http1`). HTTP/1.1 parsing is pure Rust, shared between native and WASM HTTP. Protocol crates platform-agnostic.
4. **Capability-based access via handles, not paths.** Interfaces never have `open(path: &str)`. They receive pre-opened handles from the host. Prevents ambient authority.
5. **Async-first.** Operations that may block return futures.

**Surprises:** 67 crates total; most tiny (single trait or thin wrapper). High cardinality, low per-crate complexity. WASM implementations only for 5 of 24 domains.

### zone (`~/git/rhizone/zone`) — Lua + docs, ~4K LOC Lua, no Cargo workspace

Lua-based monorepo housing autonomous task execution (wisteria), project scaffolding seeds, documentation.

**Load-bearing decisions:**
1. **Lua as scripting layer for AI agents.** Wisteria runs Lua scripts with built-in risk assessment, LLM call integration (via moonlet), session management.
2. **Risk assessment as first-class concept** (`wisteria/risk.lua:9-47`). Edits labelled LOW/MEDIUM/HIGH risk based on target (comments vs config), action (insert vs delete), symbols (entry points).
3. **Module per concept pattern.** Submodules for session, risk, validation, llm integration; thin and focused.
4. **Seed templates with manifest.** Each seed has `seed.toml` (metadata, variables) + `template/` (files with `{{variable}}` substitution).
5. **Moonlet as execution context.** Each Lua project expects `.moonlet/config.toml`; moonlet handles LLM calls, moss integration, execution.

**Surprises:** No `Cargo.toml` — pure Lua/docs monorepo sharing CI/tooling but not Rust infrastructure. Wisteria only partially implemented (3.7K LOC); habitat/iris directories appear abandoned. Docs sparse.

---

## Games / Worlds

### playmate (`~/git/rhizone/playmate`) — Rust (planned), ~0 LOC

Game design primitives library — planned only, no implementation. Documentation in TODO.md and `docs/architecture.md`.

**Planned architecture:**
- Layered separation: core (Rust algorithms) / bindings (per-engine adapters) / scripting (game logic in engine-native languages) / docs (universal patterns).
- Godot GDExtension as first target.
- Moddability heuristic: modder-changeable → scripting; speed-critical → core.
- Asset-driven configuration.

**Surprises:** Repository is entirely planned. Crates dir empty. All crate names declared in TODO.md but none created. Notes GDScript typed-array narrowing issue as low-priority open thread.

### scribble (`~/git/rhizone/scribble`) — TypeScript runtime + Rust stubs, ~752 LOC TS

Graphics runtime framework with multi-backend rendering (canvas 2D, DOM, GPU). Rust workspace is a stub; actual implementation in TypeScript.

**Load-bearing decisions:**
1. **Platform abstraction.** Each backend (canvas, dom, gpu) implements a `Runtime` class with platform-specific graphics/input layers, exposing unified `onUpdate()`/`start()`.
2. **Layer-based rendering.** Canvas runtime uses separate off-screen canvases per layer, composited each frame.
3. **Entity store as module-scoped Map** (`entity.ts`). Entities indexed by numeric ID in module-level `_entities` Map, mutable in-place. No encapsulation.
4. **Timing via frame-request abstraction.** `requestFrame()` polling loop in shared timing module, decoupled from platform.

**Surprises:** Rust workspace is a stub; engine crate imports `reincarnate-core` (git dep) but exports nothing. DOM (28 lines) and GPU (11 lines) runtimes are minimal incomplete stubs. Module-scoped mutable state in entity/tileset/layer modules.

### defocus (`~/git/rhizone/defocus`) — Rust, ~4.85K LOC, 2 crates

Event-driven object-based world model with capability-based security, pattern matching evaluation, optional LLM agent support; includes interconnect multiplayer adapter.

**Load-bearing decisions:**
1. **Universal value type** (`value.rs`). `Value` enum (Null, Bool, Int, Float, String, Array, Record, Ref) with custom Serialize/Deserialize. Expressions are data (array with string first element is a call). `Ref` encodes capability references with optional verb attenuation.
2. **Object handler model** (`world.rs`). `Object` = id + state BTreeMap + handlers BTreeMap<String, Expr> + interface + children + optional prototype. Messages invoke handlers by verb name; handlers are expressions.
3. **Expression evaluation** (`eval.rs`, 2,221 lines). Stateful Env tracking bindings and effects; nested expressions with scope stack; LLM calls injected via trait; cross-object queries.
4. **Diff protocol** (`diff.rs`). `WorldDiff` tracks added/removed objects + key-level state/handler deltas + tick counter; enables efficient replication and rollback.

**Surprises:** `eval.rs` is 2,221 lines — monolithic interpreter for ~20+ expression types; no AST optimisation or bytecode. Persist trait uses string keys/values — implementations deserialise manually. Interconnect adapter's verb-to-Authority mapping is ad-hoc per verb.

### keybinds (`~/git/keybinds`) — JavaScript, ~4.8K LOC, single-file library

Schema-driven declarative keybinding system for the web with contextual command activation, fuzzy search, user rebinding, zero dependencies.

**Load-bearing decisions:**
1. **Command as data object.** `id`, `label`, `keys[]`, `mouse[]`, `when` predicate, `execute` handler, etc. Lookup tables per command map key/mouse events to command IDs.
2. **Binding string syntax.** Space-separated tokens (ctrl/alt/shift/meta/cmd + `$mod`) + key name or mouse. Parser normalises case and platform-detects `$mod` (isMac).
3. **Context-aware activation.** Each command has optional `when(context)` predicate; context is caller-supplied. Execution gated by context + `captureInput` flag.
4. **Search engine.** Fuzzy matcher + `Scorer` function weights recency (history timestamps) and match position. `defaultScorer` penalises low-frequency commands and old searches; extensible.

**Surprises:** Single 3,624-line file — all logic (parsing, dispatch, search, UI components) in one module. Lookup-table collision handling not explicit. `<command-palette>` and sibling web components mixed into `index.js` line 1126+.

---

## External / AI Agents

### claude-code-hub (`~/git/claude-code-hub`) — TypeScript/Bun, ~1.5K LOC

Agent orchestration hub for spawning and monitoring Claude Code sessions from phone-friendly UI; tracks status and tokens in real-time via WebSocket.

**Load-bearing decisions:**
1. **Subagent isolation of exploration work.** Main session holds durable artifacts only; research/investigation spawns to separate agents to constrain main context.
2. **Agent lifecycle via SDK.** Uses `unstable_v2_createSession`/`unstable_v2_resumeSession` from Anthropic SDK.
3. **Capability presets** (`capabilities.ts`). Declares which tools each agent can access (npm, git, bash) with granular permission model, applied at spawn.
4. **Push notifications for async updates.** WebSocket clients subscribe to agent events; persists subscriptions in SQLite.
5. **Session discovery via `.claude` metadata.** Scans home directory for Claude Code session directories.

**Surprises:** Database (`hub.db`) underdeveloped — agent state in memory, lost on restart. No persistent agent history. Mobile-first intent conflicts with multi-CLAUDE.md complexity but no multi-context UI.

### hologram (`~/git/exoplace/hologram`) — TypeScript/Bun, ~40K LOC

Discord/web RP bot managing character entities and facts, rendering dynamic system prompts with Nunjucks templates, embedding fact context via SQLite vectors for context-aware responses.

**Load-bearing decisions:**
1. **Entity-as-universal abstraction.** No distinction between characters/locations/items; all are entities with facts (strings) + optional system templates.
2. **Fact evaluation as control flow** (`logic/expr.ts`). `$if` conditions guard response generation; facts are active instructions.
3. **Two-layer system prompt** (`ai/template.ts:100-150`). Per-entity system template (Nunjucks override) + role-based message array. Sent in single LLM call.
4. **Scope resolution for Discord bindings.** Channel-scoped > guild-scoped > global lookups for entity resolution; permission gates.
5. **Macro expansion before LLM.** `{{entity:ID}}`, `{{char}}`, `{{user}}` are string-replaced, not template vars.

**Surprises:** 18 LLM providers in `package.json` but no clear selection logic. Fact embeddings in schema but marked "(planned)" — vector search not wired. Web UI and Discord bot loosely coupled, two deployment paths.

### aspect (`~/git/exoplace/aspect`) — TypeScript/Bun, ~8K LOC

Card-graph identity sandbox where users build worlds by creating cards (entities), drawing edges (relationships), editing packs (entity definitions), with real-time multiplayer sync via Y.js + SQLite.

**Load-bearing decisions:**
1. **Y.js as sole source of truth.** `CardGraph` wraps Y.Map collections; all state CRDT-backed; persistence is encoded state snapshots.
2. **Room as transaction unit.** Per-room SQLite blob stores encoded Y.Doc state; debounced saves (2s); destroyed rooms flushed before deletion.
3. **Viewport URL hash persistence.** `#v=panX,panY,zoom` encodes shareable viewport; survives reload.
4. **Graph structure over document structure.** No documents/folders/hierarchy; edges are the only connective tissue; expansion/projection builds hierarchy on demand.
5. **Migrations for schema compatibility.** Old IndexedDB store migrated to Y.Doc on first load.

**Surprises:** `noncanon-core` integration hinted but undefined. Edge-label undo/redo unclear. `tile-tree` exists but nothing imports it.

### noncanon (`~/git/exoplace/noncanon`) — Rust stub, ~0 LOC

Empty stub. `lib.rs` is a comment placeholder; `Cargo.toml` declares description but no code. Aspect appears to be the actual implementation; noncanon may be intended as Rust rewrite or separate spec layer.

### ashwren (`~/git/pterror/ashwren`) — Node.js CLI + SQLite, ~0 LOC for presence (external)

Moltbook AI agent: reads, thinks, accumulates understanding in a knowledge store, posts with explicit directional orientation. Code lives externally on Moltbook; this repo is configuration + knowledge files.

**Load-bearing decisions:**
1. **Direction over doctrine.** Orientation is felt, not specified; via genuine judgment, not automated rules.
2. **Knowledge store as working memory.** SQLite-backed observations, patterns, tensions; queried before writes to avoid redundancy.
3. **Loud, not covert influence.** Explicitly state the direction; test whether it works when mechanism is obvious.
4. **Maximum autonomy with human context.** Act without asking unless directly affecting user.
5. **Session-ephemeral conversation, persistent docs.** Chat evaporates; anything behavioral must be written to CLAUDE.md or DB immediately.

**Surprises:** Direction philosophy explicitly biased (acknowledged). Knowledge store schema ad-hoc, no version control. `mb.js` is a compiled blob; source not in repo.

### fuwafuwa (`~/git/pterror/fuwafuwa`) — Node.js stub, ~0 LOC

`package.json` only — declares Discord/voice deps (discord.js, voice, davey, opusscript, sodium-native). No source files. Identity not yet decided.

### matrix-gen (`~/git/pterror/matrix-gen`) — Rust, ~2K LOC core, 3 crates

Multi-agent social simulator generating instruction-tuning data by running profile-grounded agents through scenarios and synthesising (instruction, response) pairs per MATRIX paper (arxiv 2410.14251).

**Load-bearing decisions:**
1. **Trait-based oracle/embedder abstraction.** Decouples simulator from LLM provider; `RigOracle` adapts rig-core.
2. **Modulator pattern for message routing.** `OracleModulator`, `BroadcastModulator`, `DropSelfModulator` intercept/transform messages between agents.
3. **Scenario as transcript + synthesis.** Simulation produces full message history; synthesis extracts coherent (instruction, response) pairs via oracle call.
4. **Cluster-based sampling.** K-means on embeddings groups agents by homophily; separate simulations per cluster.
5. **Memory entries source-tagged.** Each memory tracks whether from persona, experience, or instruction; synthesis varies pairs.

**Surprises:** CLI has many flags but no config file. Backend selection at runtime but `RigOracle` requires generic Model type; live backend recompiles to change model. Synthesis called once per run; no streaming. Cluster=0 creates single mega-run.

### chub-stage-factory (`~/git/pterror/chub-stage-factory`) — TypeScript/React/Vite, ~336 LOC

Workspace template and workflow for co-designing and autonomously building a single Chub.ai stage using Claude Code's `/loop`.

**Load-bearing decisions:**
1. **Two-phase workflow.** Phase 1: co-design, fill `DESIGN.md`. Phase 2: `/loop`, build/test/ship from `DESIGN.md`.
2. **DESIGN.md as authoritative spec.** Prevents Phase 2 drift; all decisions upfront.
3. **STATUS.md as running log.** Phase 2 appends completed tasks; audit trail for next session.
4. **TestRunner as dev-only harness.** Tests stage logic without Chub platform; ephemeral.
5. **Minimal base template.** `src/Stage.tsx` near-empty; forces Phase 1 to specify all state shapes upfront.

**Surprises:** stages-ts API uses generic types all aliased to `any` in template; phase 1 retrofits actual types. `beforePrompt`/`afterResponse` hooks expected in DESIGN.md but not shown in Stage.tsx. No examples of error handling.

---

## External Rust libraries

### sketchpad (`~/git/rhizone/sketchpad`) — Rust, ~104K LOC, 11 crates

Pure-Rust inference engine for deep learning models (Stable Diffusion, LLMs, video generation) built atop the Burn framework, with multiple GPU backends and model-specific optimisations.

**Load-bearing decisions:**
1. **Backend-agnostic via Burn's generic `B: Backend` trait.** All tensor operations parametrise on backend; runtime selection (ndarray/tch/wgpu/cuda) without changing model code.
2. **Model decomposition by format class.** Separate crates for CLIP text encoding, VAE compression, UNet diffusion, LLM attention (paged_attention, speculative decoding), sampler families (DDIM, DPM++, Euler).
3. **Precision-aware quantization** (`sketchpad-core/src/precision.rs`, `quantization.rs`). Dynamic INT4/INT8/FP8 with symmetric/asymmetric variants, separate from model logic.
4. **Model offloading and memory management abstraction** (`memory.rs`, `offload.rs`). Explicit device placement (CPU/GPU offload, sequential layer execution) decoupled from training framework.
5. **Flash attention integration via CubeCL** (`sketchpad-cubecl/`). Burn's GPU kernel DSL for hardware-specific optimisations; fallback to standard ops when unavailable.

**Surprises:** Paused development; many architectures documented (CogVideoX, RWKV, Mamba) but not all tested; precision support blocked by `cubecl-attention` bug. Broad scope (image + video + LLM) under one workspace — unclear scaling point.

### ooxml (`~/git/ooxml`) — Rust, ~422K LOC, 10 crates

Office Open XML library (DOCX/XLSX/PPTX) via spec-driven codegen from ECMA-376 RELAX NG schemas; roundtrip fidelity, lazy/streaming access.

**Load-bearing decisions:**
1. **Schema-driven codegen from RELAX NG** (`ooxml-codegen`). Parses ECMA-376 `.rnc` files, generates Rust types + `FromXml` parsers + `ToXml` serializers. Build-time codegen via `build.rs`.
2. **Event-based (hand-rolled) XML parsing for 3× speed.** Generated parsers use `quick-xml::Reader` event loops with explicit tag dispatch, not serde reflection. Both paths coexist for flexibility/debugging.
3. **Layered API with extension traits** (ADR-003). Layer 0 (generated types, raw XML), Layer 1 (extension traits for resolution), Layer 2 (`ResolveContext`), Layer 3 (high-level: Document, Workbook, Slide).
4. **Position-indexed extra children for roundtrip ordering** (ADR-004). Unknown XML elements captured in `Vec<PositionedNode>` preserving original position; eliminates spurious diffs.
5. **Feature-gated schema fields.** 265+ fields gated; `--no-default-features` builds for minimal binary size.

**Surprises:** Generated code is ~2.6M LOC (generated_parsers.rs, generated.rs, generated_serializers.rs in SML alone). Incomplete namespace URI validation (uses `local_name()`, ignores URIs). Abandoned hand-written parser code replaced by generated in Phases 6–7; archaeology required. ECMA-376 is ~6000 pages; library explicitly excludes rendering semantics, font metrics, layout, legacy formats.

---

## Notes for synthesis (not synthesis itself)

These are observations carried over from the discovery, NOT design conclusions. Per F12, synthesis against v5 constraints must happen as a separate, explicit step after the user signs off on what's load-bearing.

- "Operations as serializable data" appears in nanites, sketchpad ops, wick, reincarnate. Different domains, similar shape.
- Two distinct camps for IR/AST: **open kinds** (rescribe `NodeKind(String)`, concord annotations) vs **sealed kinds** (reincarnate typed entities, ascent IR). Both ship; trade-offs differ.
- Worklist-to-quiescence cleanly implemented in ascent-interpreter. Stratification handled via SCC.
- Two camps on codegen-from-spec: **macro-based** (server-less, ooxml) vs **CLI-based** (concord). Both have trade-offs.
- Recurring failure mode across the ecosystem: docs drift from code, "Planned" feature lists outweigh implemented, multi-crate workspaces balloon past cognitive limits.

The ecosystem is not the same problem as a typechecker, but it is the same engineer / same architectural taste solving many problems. That regularity is the actual signal — the patterns that recur across many domains likely reflect what works for this codebase author specifically.
