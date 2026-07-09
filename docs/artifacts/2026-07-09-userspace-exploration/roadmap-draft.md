# Roadmap draft — crescent as the entire computer

**Status: DRAFT.** Synthesizes `synthesis.md`, `batteries-delta.md`,
`unshape-xref.md`, and the existing `docs/artifacts/2026-07-08-roadmap/roadmap.md`
against the organizing principle below. Nothing here is committed until the
owner signs off. Every item marked **OPEN** is an undecided question, not a
default — do not build against it as if it were resolved.

## Principles

**General substrate first (when it's obvious), then app-pulled substrate.**
If something is clearly general and clearly needed by everything, build it
first — no app has to ask. For everything else: pick the next app, build
only the substrate that app actually needs (properly — real implementation,
not a hack), ship the app, repeat. Each app drags forward substrate every
later app benefits from. App order is settled: (1) AI RP frontend, (2)
taskgraph/agent harness, (3) creative tools.

## Phase 0: Obviously-general substrate

Kept short on purpose — only things clearly needed by everything, not things
that "might be useful."

- **Cross-platform event loop.** `lib/epoll/init.lua` and `lib/async/init.lua`
  both exist today but are unreconciled — two libraries, not one tiered
  implementation. batteries.md's old #1 priority ("async I/O — largest
  single gap") was written without checking the codebase; the real gap is
  narrower: vendor `wepoll.dll` for Windows (per the `dep/`-vendoring
  pattern already used for musl loaders), implement kqueue for macOS, then
  unify `lib/epoll` and `lib/async` into one tiered library per
  `docs/conventions.md`'s system > FFI > pure-Lua rule. This blocks
  concurrent HTTP servers, multiplexed connections, and anything
  network-bound across all three app phases — genuinely universal.
- Nothing else cleared the "genuinely obvious, not merely useful" bar. Two
  strong candidates were considered and rejected for Phase 0 specifically
  *because* they're app-pull, not universal-first: undo/redo (creative.md,
  development.md, information.md all want it, but nobody has wired it into
  a real editing surface yet — build it when RP frontend or a later app
  needs a concrete undo model, not speculatively) and notification routing
  (`lib/notify` already exists per batteries-delta.md §2 — this is a false
  gap, not a Phase 0 task; composing it into a UI is app-pull work).

## Phase 1: AI RP frontend → shippable

**What exists:** `lib/platform/apps/charactercardv2/` (character card v2
app) with a supporting adapter at `lib/platform/apps/sillytavern/`. Per the
prior roadmap, this was paused for typechecker work and "sorely needs
design." A prior session on this is likely findable via `normalize
sessions` (not yet mined for this draft).

**Substrate this app needs, per synthesis.md's application-domain section:**
this is closest to "mostly buildable today" — chat/message rendering,
character data, storage. `lib/smtp`/`lib/imap` are not relevant here; the
closer analogy from synthesis is the PIM/notes composition pattern
(`kv_store`/`sqlite` + `search`/`fuzzy_match` for card/session retrieval).

**Gaps flagged against this app specifically:**
- **OPEN** — is a `lib/chat` (thread/message/reaction model over an
  injected transport cap) in scope, or does it cross the "no framework
  code in lib/" line the way a dispatch/routing layer would? synthesis.md
  §4 flags this as genuinely unclear from the stated rules, not resolved
  anywhere. This blocks deciding whether RP-frontend message-list state
  gets its own library or stays app-local code in
  `lib/platform/apps/charactercardv2/`.
- Local LLM inference (batteries-delta.md §1): `lib/ai/providers/` is
  hosted-only today. `lib/onnx` under `lib/ml` is adjacent but not the same
  thing (ONNX runtime ≠ a `libllama.so` inference tier). **OPEN** whether
  this app needs local inference to ship, or ships hosted-only first.
- Import/migration: synthesis.md §3 notes ai-agents.md is the *only* facet
  doc naming an actual import path (SillyTavern card import) — this
  already has a concrete target in `lib/platform/apps/sillytavern/`, so
  it's not a new gap, just a thing to finish.

**Definition of "shippable" here is not yet drafted** — **OPEN**: what does
done look like (card import + chat UI + one storage backend + one LLM
provider)? Needs the mined prior session before this can be scoped further.

## Phase 2: Taskgraph / agent harness → shippable

**What exists:** `lib/taskgraph/` (core). The agent harness itself would
"probably be a platform app, pending design" per the prior roadmap — not
started.

**Design thesis:** `docs/agent-design.md` argues most existing multi-agent
frameworks are "chronological accumulation with extra steps" and proposes
deleting the concept of an agent as the organizing unit. This session's
exploration (`synthesis.md` §2, "large, mostly-unclaimed") confirms crescent
has no existing multi-agent coordination story beyond single-orchestrator
`lib/taskgraph`.

**Substrate gaps, most load-bearing first:**
- **OPEN (design, not scoped)** — what does a set-based multi-agent
  coordination primitive look like (separate sets per role, explicit
  note-passing)? synthesis.md is explicit no design exists anywhere for
  this; it's the central open question for this whole phase, not a detail.
- **OPEN** — should `lib/agent/`'s preset system let a preset declare its
  own cap manifest independent of its hosting app (cap-minimality enforced
  per-task-type, not per-agent-instance)? Flagged as novel relative to
  every other agent framework if pursued, and undecided.
- RAG chunking pipeline: `lib/embed/` (storage) and `lib/ai/` (generation)
  exist independently; no glue connects a document to a queryable index.
  synthesis.md suggests this wants to be a *preset* (task type), not a new
  library — consistent with "no framework code in lib/."
- Eval/comparison harness for LLM presets (PromptFoo/Arena-shaped): ties
  into existing `lib/test/` fixture/snapshot infra, not new machinery —
  lowest-risk item in this phase.
- Depends on Phase 0's event loop for any concurrent multi-agent execution
  — this is the first phase that actually exercises that substrate, which
  is itself an argument the event loop belongs in Phase 0 and not later.

## Phase 3: Creative tools → shippable

Per the prior roadmap, this subsumes the scribble and dusklight fold-ins —
their design docs are stale (scribble's own design doc is flagged as
"partially wrong, don't cargo-cult primitives from it") and "the editor is
just another platform app," not a reason to mint app-specific libraries.

**What this domain actually requires**, per `unshape-xref.md`'s survey of a
sibling Rust media-generation ecosystem (45 crates) against crescent's
current libraries — this is the sharpest available signal for what's
actually missing, not guessed:
- **Audio synthesis is the single largest hole**, confirmed independently
  by synthesis.md and unshape-xref.md. Crescent has `lib/dsp/` (signal
  processing) and `lib/midi/` (SMF file format, not synthesis) and
  `lib/wave` (WAV codec — the decode half already exists per
  batteries-delta.md, contrary to synthesis.md's framing that decode was
  missing). What's actually missing: oscillator/envelope/filter-graph
  synthesis engine, a live audio sink (WebAudio cap in-browser, WAV-file
  cap pure-Lua), granular synthesis, physical modeling. unshape's
  `unshape-audio` crate is the reference depth to build toward, not to
  port directly.
- **3D mesh is the single biggest structural gap** if this phase's scope
  includes any 3D content (game assets, procedural environments):
  crescent has no vertex/index buffer type, no CSG, no marching cubes, no
  skeletal rig/skinning, no glTF import/export, no NURBS surfaces. unshape
  has all of these (`unshape-mesh`, `unshape-rig`, `unshape-gltf`,
  `unshape-surface`). **OPEN** — is 3D content in scope for this phase at
  all, or is creative tools 2D-first (livecoding, trackers, paint, motion
  graphics)? Not decided anywhere; this materially changes the size of
  Phase 3's substrate work.
- **Musical-time primitive** — a quantized, cycle-based, re-evaluated clock
  distinct from `lib/easing`/`lib/interpolation`'s continuous parametric
  time. Needed for livecoding/tracker tools. **OPEN** — who owns wall-clock
  time (audio callback, animation frame, or a fake deterministic clock for
  tests)? Not decided.
- **Sequence CRDT** (RGA/Peritext-shaped) for collaborative canvas —
  confirmed as a real gap by both synthesis.md and batteries-delta.md
  (existing `lib/crdt` has six generic types, none is a text-sequence
  CRDT). **OPEN** — lives under `lib/crdt` or as a sibling library?
- **2D physics gaps beyond what exists**: `lib/physics_2d/` covers rigid
  body only; unshape has cloth/softbody/fluid with no crescent equivalent.
  Scope call for whether Phase 3 needs these — likely app-pulled if a
  specific tool needs cloth/fluid, not built speculatively.
- **Fantasy console**: both creative.md and games.md independently
  converge that this is a cap *profile* (fixed canvas, fixed palette, no
  network/fs) applied to `lib/platform/`, not a bespoke product — cheap to
  build once the audio/graphics substrate above exists, not its own
  work item.
- **Node-graph editor**: explicitly named out-of-scope as a *library* (it's
  tool-shaped, would become the generic-dispatch framework code
  CLAUDE.md's constraints forbid); if built, it's an app in
  `lib/platform/apps/` composed from libraries. **OPEN** whether Phase 3
  needs one at all.
- **Architectural pattern worth adopting, independent of any single gap**:
  unshape's `ComputeBackend` trait + registry + `ExecutionPolicy` pattern
  (unshape-xref.md §4) cleanly separates "what backends exist" from "how to
  pick," and could replace crescent's copy-pasted per-library tier-selection
  boilerplate (system > FFI > pure Lua) with one shared, mechanically
  checkable mechanism. Not creative-tools-specific, but the audio/mesh
  substrate this phase builds is the first place multiple real backend
  tiers (FFI SIMD vs pure Lua) will show up together, making this the
  natural phase to introduce it. **OPEN** whether this is worth doing as
  its own `lib/backend/` before or during Phase 3, versus deferred further.

## Phase N: The long tail

Not sequenced — the backlog that app-pulled work from Phases 1–3 will
eventually reach into, or that stays parked until a consumer names it.

- Debugger (`lib/debug_adapter/`, DAP-shaped, `debug.sethook` + coroutines)
  and REPL (`bin/cr repl`, nREPL-shaped over `lib/jsonrpc`) — named "the
  most conspicuous gap for a language ecosystem this mature," zero mentions
  in batteries.md.
- Clipboard as a cap — the one inter-app channel that must cross cap
  boundaries by design; no grant semantics designed yet.
- Window management for sandboxed DOM apps — "tmux/i3 control-plane over
  DOM regions" framing, explicitly not answered whether worth building
  before a real consumer needs it.
- Replay/deterministic-input-log + sim-state-snapshot format
  (`lib/replay/`) — for rhythm games, TAS tooling, emulation-style rewind.
- Determinism-as-a-cap audit for generative libraries (`noise_gen`,
  `particle`, `lindenmayer`, WFC) — confirm PRNG is always an injected cap,
  never ambient `math.random()`.
- Search-across-everything as a system-level launcher surface (rofi/
  Spotlight-shaped) — likely the same `search`/`tfidf`/`fuzzy_match` stack
  information.md already uses for PIM, wearing a different UI.
- Sharing/export as a universal action ("take an artifact out of crescent
  and hand it to someone not running crescent") — named independently four
  times across facets with no shared vocabulary yet.
- Cross-cutting concerns with zero current owner: accessibility, privacy
  audit/revocation UI (the audit log substrate exists per system.md; no
  UI/query layer over it), platform discoverability/onboarding, error
  handling as user-facing UX, cross-facet workflow state (how open
  file/chat/note/todo state moves between apps in one session), app
  discovery/composition.
- Unreconciled duplication: `lib/i18n` and `lib/locale` are two overlapping
  full implementations (batteries-delta.md §2) — worth a reconciliation
  pass whenever an app first needs either.
- IMAP: `lib/smtp`/`lib/email` are implemented; no `lib/imap` was found by
  direct grep despite communication.md citing it as existing — needs
  verification, not assumed either way.

## Open questions

Collected verbatim in intent from synthesis.md §6 plus this session's own
findings. None of these are resolved by this draft — they need explicit
decisions before the affected work can be scheduled.

- Is `lib/chat` in scope, or does it violate "no framework code in lib/"?
  (blocks Phase 1 scoping)
- Does local LLM inference need to ship with Phase 1, or is hosted-only
  sufficient for v1?
- What does a set-based multi-agent coordination primitive look like? (no
  design exists — central to Phase 2)
- Should agent presets declare their own cap manifest independent of their
  hosting app?
- Is 3D content in scope for Phase 3 at all, or is creative tools 2D-first?
  (changes Phase 3's substrate size substantially)
- Who owns wall-clock time for the musical-time primitive?
- Does sequence CRDT live under `lib/crdt` or as a sibling library?
- Is a `lib/backend/`-style capability-tiered registry worth building, and
  if so in which phase?
- Storage format for note-shaped data generally: plain files on disk vs.
  `kv_store`/`sqlite` rows — unresolved for any data-holding library, not
  just PIM.
- Does `spreadsheet` become the canonical backing store for kanban/gantt/
  calendar views, or does a dedicated typed `task` record win?
- Is voice/video in scope at all, given WebRTC has no pure-Lua tier?
- Whether a crescent window-manager cap is worth building before any app
  needs multi-pane layout.
- Whether clipboard/notification caps belong in `lib/platform/caps/` now or
  wait for a consuming app (notification routing itself is not open —
  `lib/notify` exists — but the cap-grant wiring into a UI is).
- What does federation/trust between two independently-run crescent
  instances look like — addressed only for chat, nowhere else.
- What does identity mean on top of a caps model that only describes
  access, not "who is the user"?
- No philosophical answer for retention/deletion (GDPR-shaped "delete my
  data") anywhere in CLAUDE.md or the overview.
- Whether "target LuaJIT, don't require it" as a portability stance is
  actually a usable performance floor for timing-critical work (audio
  scheduling, netcode) — unverified, could silently break Phase 3's premise.
- Marinada's relationship to crescent (vendored dep? standalone? ported?) —
  carried over unresolved from the prior roadmap.
