# Typechecker v5 — Discovery, Exploration, and Decision Log

Append-only. One entry per session, decision, or experiment.

**Companion files:**
- Constraints catalog (the binding spec): `~/.claude/plans/radiant-gathering-gray.md` (not in repo — relocation TBD, see open thread below).
- Unframed architecture discovery: `docs/typechecker-v5-discovery-unframed.md`.
- Tainted (pre-framed) discovery: `docs/typechecker-v5-discovery-tainted.md` — radioactive; do not cite as design evidence.

**How to use this file:** Each entry is dated. Sections within an entry: *Question*, *Evidence*, *Decisions closed*, *Decisions still open*, *Tainted artifacts*, *Next entry point*. The point of the log is to make tactical-for-strategic substitution (session audit §1 P1) visible across sessions — an entry that resolves nothing should be obvious as such.

---

## 2026-05-22 — Session 1: Frame, not build

### Question entering session
Continue v4 (implement K6f deferred-constraint queue) per the prior handoff `94fb058f`?

### Reframe by user
Architecture has been the issue across v1→v2→v3→v4, not features and not type theory. Each rewrite treated symptoms and inherited the substrate. Soundness is non-negotiable; "it's not just about soundness — features matter too." Design from scratch, from first principles. Never guess; nail down constraints from the historical record.

### Evidence gathered

**Corpus survey (`lib/**/*.lua`)** — measured what real code uses:
- 9343 single-line `--: T` annotations
- 4683 multi-line `--:: T` declarations
- 925 checked casts `--[[: T]]`
- 5432 force casts `--[[:! T]]` (predominantly post-`pcall` narrowing)
- Tables: records ~60%, arrays ~25%, maps ~15%
- `setmetatable`-post-construction common (`lib/epoll`, `lib/github`)
- Module pattern dominant: `local M = {}; M.foo = ...; return M`
- Method dispatch via `:` on metatable `__index` chains

**Historical soundness gaps (`docs/soundness-audit.md`, Gaps 1–11):**
- Gap 1 (TAG_VAR permissiveness in `try_unify`): fixed 2026-03-15
- Gap 8/9/10 (annotated locals without init, parser totality): fixed
- Gap 11 (`unknown` laundering through `any`): fixed
- Gap 2 (unannotated parameters): mitigated via implicit-any warning, not fixed

**Architectural diagnosis (`docs/typechecker-architecture-from-first-principles.md` §2):**
- D6 (4-pass + deferral + waiters) — wrong. Three scheduling mechanisms coexist; "pass<4 retry" branch in `solve.lua:3972` is a confession.
- D11 (gen-time mutable side-channels) — wrong. `_hkt_payloads`, `_last_multi_return*`, `_forall_bounds` mutate ctx during gen-time and are read during solve.
- D14 (implicit constraint provenance) — wrong. No declared-vs-inferred tier tag.

**K6e audit finding (`docs/typechecker-method-dispatch-audit.md`):** legacy has a principled `prim_index`/`prim_meta` registry pattern v4 missed. Same pattern likely applies elsewhere; check before reimplementing.

**Methodology failures (`docs/session-audit-2026-05-20.md`):**
- P1: tactical substitutes for strategic
- P2: confidence overstatement in reports (K6e claimed "ad-hoc rejected" while shipping ad-hoc)
- P3: reactive subagent dispatch as substitute for orchestrator thought
- P4: spec-as-re-narration (operational semantics that wasn't run)
- P5: multi-option hedging menus that punt to user

**Cross-ecosystem architecture survey:** Eight Explore agents fanned out across ~30 sibling repos (`~/git/rhizone/*`, `~/git/exoplace/*`, `~/git/pterror/*`, `~/git/*`). Total LOC surveyed: ~1.4M, mostly Rust with TypeScript/Bun for UI and Lua for moonlet/zone. Full reports in `docs/typechecker-v5-discovery-unframed.md`. Recurring patterns observed (unjudged): operations-as-serializable-data (nanites, sketchpad, wick, reincarnate); worklist-to-quiescence with monotone facts (ascent-interpreter); backend-per-domain or backend-per-protocol (wick, server-less, portals); codegen-from-schema (ooxml, concord); open vs sealed AST kinds (rescribe vs reincarnate); profile/registry dispatch (gels, paraphase).

### Decisions closed

| ID | Decision | Citation |
|----|----------|----------|
| H1 | HKT in scope. Substrate already designed (`typechecker-hkt-broader.md` — H1/H3/H4/H5/H6 landed). Unfinished work: "Option X — deferred instantiation as first-class solver constraint." Directly ties to v5's B5/B7 payload-as-data constraints. | user this session; HKT docs |
| H3 | Parallel build at `lib/type/static-v5/` (working name, user may rename — version numbering is muddled). Swap when 2809 tests green under new tree. Legacy + v4 remain until swap. | user this session |
| H5 | Refinement types, GADT-strength flow typing, impredicativity — **out of scope** for v5. | user this session |
| H6 | LSP port-vs-rewrite question — **struck**. LSP is unreliable, not a v5 design constraint. If v5 breaks it, that is acceptable. | user this session |
| H8 | Scope/timeline question — **struck**. User does not care about budget; design *quality* is the issue, not pacing. | user this session |
| H9 | Initial wide-unframed sibling-repo discovery: done this session. | this entry |
| G7 | `any` ban softened to conditional. Goal: no `any`, predicated on flawless inference (user asserts unconditionally always possible). Community-release ergonomic exception tracked as H10. | user this session |

### Decisions still open

- **H2.** Effect tracking in scope for v5? Roadmap F2 flags as differentiator. Effects propagate through function types — significant constraint payload cost.
- **H4.** Sound model of `setmetatable`-post-construction. Soundness non-negotiable (A1). Candidates: linear/affine "table-under-construction" vs "table-sealed" types, construction-phase typing, declared-metatable-up-front. Existing `lib/epoll`, `lib/github` refactor downstream if model rejects them.
- **H7.** Operational-semantics representation: inference rules in `docs/`, executable Lua spec, or both with parity tests?
- **H10** (new this session). Does community release force an `any` escape hatch? Default v5 posture is no `any`; revisit if community ergonomics force it.

### Methodology constraints added/strengthened this session

- F9 — this log exists.
- F10 — experiments are first-class; commit before discard.
- F11 — H-closures need log entries with evidence, not chat alone.
- F12 — subagent prompts must NOT pre-load the answer. Three reports earlier this session were tainted by D6/D11/D14 framing.
- F13 — tainted output preserved separately.
- F14 — slacking off during design is the named primary failure mode; "as wide as possible" beats "smart cherry-pick."

### Tainted artifacts

Three Explore agents earlier this session were prompted with "patterns relevant to D6/D11/D14 specifically." Their reports (nanites / ascent-interpreter / normalize) are partial — biased toward the orchestrator's pre-held hypothesis. Preserved at `docs/typechecker-v5-discovery-tainted.md` as evidence of the bias mode. **Do not cite these in v5 design work.** The unframed re-run (`discovery-unframed.md`) supersedes them.

### Open thread: where the constraints catalog lives

The constraints catalog is at `~/.claude/plans/radiant-gathering-gray.md` — outside the repo. For durability and reviewability, it likely belongs under `docs/typechecker-v5-constraints.md` or similar. Not relocated this session; flagged for next session.

### Next entry point

1. Close H2, H4, H10 with the user.
2. Relocate constraints catalog into the repo.
3. Write the operational semantics — both inference rules in `docs/` AND executable Lua spec, with parity tests (H7 closed below).
4. Only then begin mechanism implementation under `lib/type/static-v5/`.

---

## 2026-05-22 — Mid-session: H7 closed

**Question.** Operational-semantics representation: inference rules in `docs/`, executable Lua spec, or both with parity tests?

**Decision.** Both, in parallel. Inference rules in `docs/` AND executable Lua spec; parity tested between them. — user this session.

**Implication.** Spec lives in two places by design; parity is the load-bearing check that they agree. If they drift, parity fails — which is the desired forcing function per F2 ("operational semantics is a runnable test, not prose"). The docs form is for humans (reviewable, citable); the executable form is for the test harness.

---

## 2026-05-22 — Autonomous research fan-out dispatched

**Context.** After the constraints catalog and discovery files landed, kicked off a wider research pass before writing the operational semantics. Per F14 (wide-and-thorough beats cherry-pick) and F12 (no pre-loaded subagent prompts), each agent is framed on its source ("characterise X") not on a target hypothesis.

**Eight agents dispatched in parallel:**
1. Prior crescent typechecker work — catalog `docs/typechecker-*` and `docs/legacy-typechecker/`: what was designed, what shipped, what was superseded, what was abandoned.
2. Prior Claude Code sessions — via `normalize sessions` and `~/.claude/projects/-home-me-git-rhizone-crescent/*.jsonl`: decisions made, decisions forgotten, decisions re-made differently.
3. Sound type systems for dynamic languages (literature) — Typed Lua, Pallene, Luau, Sorbet, Hack, TypeScript `--strict`, mypy `--strict`, Pyre, Pyright, Roc, Diamondback Ruby.
4. Constraint-based inference (literature) — HM(X), OutsideIn(X), THIH, simple-sub, MLstruct, Algebraic Subtyping, GHC.
5. HKT (literature) — Yallop & White, OCaml encodings, Haskell, Scala HKT, Constraint kinds.
6. Effect systems (literature) — Koka, Frank, Eff, algebraic effects + handlers, row-effects, polymorphic effect inference.
7. Construction-phase / linear / typestate (literature) — for the H4 setmetatable-post-construction problem: typestate, Rust borrow check, session types, linear Haskell, Mezzo, Idris linear, Pony.
8. Worklist / fixpoint architectures in production compilers — GHC solver, OCaml solver, Chalk (Rust trait solver), MLstruct solver, Datalog (souffle, ascent), abstract-interpretation fixpoints.

Each agent has a hard scope, word cap, and the F12 framing ("characterise on its own terms, no recommendations"). Results will be appended to this log + a research report at `docs/typechecker-v5-research-report.md` (to be written after all agents return).

Status: agents running in background; this entry will be updated when synthesis is complete.
