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

---

## 2026-05-22 — H2 closed: effects in scope for v5

**Question.** Should effect tracking be in scope for v5?

**Decision.** Yes. Effects in scope. — user this session.

**Justification recorded.**
1. Lua's `coroutine.yield`/`resume` *are* algebraic effects in disguise (Plotkin/Pretnar). Without effect tracking, calling a yielding function outside a coroutine context is a runtime error — a soundness gap A1 forbids.
2. Two coexisting error conventions (`error()`+`pcall` and `(nil, errmsg)` returns) only compose as types via effect tracking.
3. User's stated bar: "literally state of the art typechecker," "more powerful than Haskell." Haskell's effects are library-level (mtl/freer); first-class effects > library is exactly where Koka/Frank sit.
4. Row polymorphism for records is already shipped (D15); the same row machinery powers Koka-style effect rows. Cost is payload extension, not new mechanism.

**Acknowledged research risk (user accepts).** No published system combines first-class HKT + first-class effects + HM-style inference + full soundness. Koka has effects+rows but limited HKT; Haskell has HKT but library-level effects; Frank uses bidirectional checking instead of full inference. v5 is research-level work on this dimension. Closest published recipe: "Deciding not to Decide" (arXiv:2510.20532) — sound-and-complete effect inference for higher-rank polymorphic functions via deferred resolution. Worth a deep read before substrate-design lands.

**Implication for adversarial design wave.** Each design candidate must demonstrate effect-integration story, not assume effects are a follow-on. Substrate and scheduler candidates in particular must accommodate `<eff>` row machinery alongside HKT.

---

## 2026-05-22 — Adversarial design wave dispatched (4 agents, opus)

**Context.** Layer-3 of the next-steps plan: closed open questions where multiple candidate designs exist. Each agent generates 2–3 candidates for its question, evaluates each against v5 constraints, independently critiques the others, and recommends one (per F5).

**Agents:**

1. **H4 — sound model for `setmetatable`-post-construction.** Candidates: (a) Strom-Yemini typestate restricted to unique local tables; (b) Mezzo-style permission flow; (c) Linear-Haskell-style multiplicity on the table handle.

2. **Substrate — reified vs mutable bounds vs hybrid.** Candidates: (a) OutsideIn(X)-style reified constraints with implication nesting; (b) simple-sub/MLstruct mutable bounds + cache; (c) hybrid (reified for HKT/effects/implications, mutable for simple unification). Must address effect-row integration explicitly.

3. **Scheduler — worklist vs levels vs tabling.** Candidates: (a) Souffle-style stratified worklist-to-quiescence; (b) OCaml Rémy-levels; (c) Chalk-SLG tabling with delayed answers. Must address how the chosen scheduler interacts with deferred HKT instantiation (Option X from `typechecker-hkt-broader.md`).

4. **HKT encoding — direct vs defunctionalised.** Candidates: (a) direct type lambdas (Scala 3 style) with higher-order pattern unification; (b) Yallop/White brands; (c) singletons-style empty data tags + Apply family. Must address interaction with effect rows.

**No pre-loading per F12.** Each prompt frames the question + relevant research + v5 constraints; does NOT name a preferred candidate.

Status: agents running in background; results appended below when complete.

---

## 2026-05-22 — Adversarial design wave returned (4/4)

Full agent reports preserved in this session's task transcripts (transient /tmp paths); architectural picks consolidated here for durability.

### H4 (setmetatable sound model): Candidate A — Strom-Yemini typestate over unique locals

**Picked design.** `Table[φ, R, μ]` where φ ∈ {open, sealed}, R = field row, μ = metatable type. Flow-sensitive over local bindings; escape (assignment to non-fresh binding, capture by closure outliving block, store into another table, pass to function not annotated to accept `open`) forbidden in open state. Joins: two open tables → `Table[open, R₁ ∩ R₂, ⊥]`; open joined with sealed = error.

**Trade explicitly accepted.** Helpers cannot participate in construction (e.g., `function build_client(t) t.x = ...; t.y = ... end`) without an `Open[R_in] → Open[R_out]` annotation. v5.0 will NOT provide such annotations. Per A1 framing — "if a library doesn't fit the model, refactor the library" — corpus refactors to inline construction at the call site. `lib/epoll/init.lua` and `lib/github/init.lua` already fit. Survey of rest of `lib/` is a pre-commit task; if >5% need helpers, revisit with `Open[R]` parameter types as v5.1 additive extension.

**Rejected.** Mezzo permissions (no published combination with HKT; would force corpus-wide permission signatures, violating A11). Linear Haskell multiplicity (CPS-shaped construction; bad error messages; arrow space duplicates with effect rows).

### Substrate: Candidate A — Reified constraints (OutsideIn-style)

**Picked design.** `Constraint` ADT with 7 variants: `CEq`, `CSub`, `CInst` (= Option X), `CHKT`, `CEffect`, `CRow`, `CImpl` (implications for local givens). Every constraint carries `Provenance { range, kind: Declared|Inferred|Synthesized, origin, parent }`. `Flavour = Wanted | Given` flavour bit. Monotonic union-find substitution as single source of truth for tvar resolution. No bounds field on tvars — tvars are inert until a constraint mentions them.

**Gen phase** is a pure fold `AST → ([Constraint], Type)`. No store, no ctx mutation. Local lets emit `CImpl { skolems, givens=[], wanted=[...] }` so binding-group generalisation is honest. B5/B7 enforced by data shape, not convention.

**Solve phase** is canonicalize → interact → react worklist pump with kick-out on substitution extension. CInst (Option X) is just another constraint variant.

**Trade explicitly accepted.** OutsideIn's principal-types limitation — the solver rejects some programs the spec admits. Where rejection bites in practice, require an annotation. Allocation overhead from reified constraints; mitigation: per-decl arena.

**Rejected.** Mutable bounds (simple-sub/MLstruct): HKT decomposition and Option X have no natural home; would force ctx side-tables (B6 violation). Hybrid: "two stores, defined interface" reads cleanly in design but accretes into D6-shape coexistence under feature pressure.

### Scheduler: Candidate A — Stratified worklist-to-quiescence (Souffle-style semi-naïve)

**Picked design.** `ConstraintDB` = indexed multimap keyed by tvar (and by effect-var, type-fn). `Strata` = topological order over SCCs of constraint dependency graph, computed once after gen. Solver per stratum: `Δ = tvars bound by prior strata; repeat: sweep stratum, apply σ to each constraint, reduce, update Δ' with new bindings; until Δ' = ∅`. Quiescence is `Δ' = ∅` after a sweep — no retry heuristic, no depth counter.

**Termination** by monotone semi-naïve over a finite lattice (tvars × {unbound, bound-to-τ}, τ finite trees mod canonicalisation). Non-monotone constructs (handler subsumption, GADT refinement) live in separate strata.

**Option X** is unremarkable: `CHKT(F, A, R)` is indexed under both `F` and `A`; wakes on either binding. The solver doesn't know HKT is "special."

**Trade explicitly accepted.** Implementation complexity (constraint DB, indexing, SCC computation, delta tracking) traded for uniformity. Throughput target: within constant factor of tsgo via indexed delta — each constraint fires `O(arity × tvars_bound)` times, not `O(passes × all_constraints)`.

**Rejected.** Levels (OCaml Rémy): pure levels can't express HKT delay without bolting on a worklist (B1 violation). Tabling (Chalk-SLG): depth-overflow safety net is exactly the budgeted termination B3 forbids; canonicalisation cost; cycle-delay is retry-shaped.

### HKT encoding: Candidate A — Direct type lambdas + Option X as principled HO escape

**Picked design.** Extend type AST with `TLambda(Var, Kind, Type)` and generalise `TApp` to polykinded. `Kind ::= * | (Kind, Variance) → Kind | KVar`. Kinds inferred by first-order unification with kind variables. Declaration-site variance composes through type lambdas.

**Unification strategy.** (1) Decompose when head is rigid on both sides. (2) Miller pattern fragment: equations `?F<a₁..aₙ> = T` with distinct rigid `aᵢ` and `T`'s freevars ⊆ {aᵢ} have unique most-general solution `?F := [a₁..aₙ] =>> T`. (3) Outside the pattern fragment: register `HOUnify` constraint and continue — this is Option X. Constraints surviving to generalisation with no progress become "ambiguous constructor variable" errors. We never commit a guessed solution; soundness is preserved by refusal-to-commit.

**Migration from H1/H3–H6.** H1 syntax kept verbatim. H3 (kind checking) extends from fixed arity to inferred kind, mechanical. H4 (variance) adds lambda composition case. H5/H6 (instance resolution) β-normalises heads before matching. **H2 (record-of-generics, reverted) is subsumed** — type lambdas make the dispatched field's type itself a constructor variable, dispatched via Option X. No record-level cleverness needed.

**Trade explicitly accepted.** Undecidability in the general case. Mitigated by: pattern fragment covers ≥95% of real code (Miller's empirical claim, borne out by Agda/Idris/Lean). Soundness preserved by refusing to commit unguessed HO solutions.

**Rejected.** Yallop/White brands: inj/prj ceremony at every site contradicts SOTA bar; variance lost; alias problem unsolvable. Singletons + Apply family: symbol explosion (every n-ary constructor generates n+1 Sym tags and Apply rules); the hard part (HO unification on `Apply(?F, _)`) is *still there*, just behind a defunctionalisation layer.

### Architecture coherence (orchestrator synthesis, marked as such)

The four picks compose into one architecture without seams:

1. Substrate ADT has `CHKT` and `CInst` as first-class variants — directly cited by HKT-encoding pick as the home for `HOUnify` / Option X obligations.
2. Scheduler indexes by tvar/effect-var/type-fn — directly accepts the substrate's reified constraint shape and Option X "wait on head binding" semantics.
3. HKT pick says "never commit guessed HO solutions" — substrate's monotone substitution + provenance and scheduler's quiescence-on-empty-delta enforce this mechanically.
4. setmetatable typestate is a SEPARATE flow-sensitive pass over local bindings; it does not interact with the constraint solver. Composition: zero — and that's the right answer.

There is no D6-shape "multiple coexisting mechanisms" trap because each of the four picks deliberately rejected its mechanism-multiplying alternatives.

### Decisions still open

- **H10**: `any` escape hatch for community release. Not addressed by SOTA bar.
- **Constraints catalog relocation**: `~/.claude/plans/radiant-gathering-gray.md` → `docs/typechecker-v5-constraints.md`.
- **Corpus survey for setmetatable typestate**: need to confirm <5% of construction sites need helpers across all of `lib/`.

### Next entry point

Operational-semantics writing (H7 closed: parallel impl + docs with parity tests). This is the gateway to mechanism implementation. The picks above define what op-sem must capture.
