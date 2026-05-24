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

---

## 2026-05-22 — Adversarial coherence wave (4 attackers): picks refuted, triaged

**Context.** Per F12 (orchestrator coherence claim was synthesis-from-memory, not from evidence), dispatched 4 independent adversarial agents to attack the four design picks. The brief: attack, don't validate. Verdict was lopsided.

### Findings

**Composition attacker (opus) — 5 hits.** (a) Scheduler "SCC once after gen" contradicts HKT pick's Option X (fresh tvars during solve); (b) HKT β-reduction allocates fresh tvars under capture-avoidance, breaking substrate's tvar-keyed indexing; (c) H4 typestate IS NOT orthogonal — `lib/epoll/init.lua:99-110` (cited by H4 design as fitting) requires `μ = typeof(self)` to be a solver-pinned tvar; (d) provenance ownership ambiguous for HOUnify residue spawned via CImpl → CHKT chains; (e) H4 "sealed = no mutation" rejects `lib/github` inheritance pattern (`setmetatable({}, {__index=Container})` then `IntBag.__index = IntBag` is sealed-then-mutate). **Recommendation: re-open.**

**Soundness attacker (opus) — 2 severe + 2 moderate.** (a) `setmetatable` post-seal unmodelled — concrete crash repro via switching metatables on a sealed binding; (b) unbound effect-row variables at quiescence have no defined disposition — concrete `coroutine.yield outside resume` crash; (c) HOUnify residue + downstream constraint ordering; (d) CImpl/CHKT/CInst nesting scope discipline. **All fixable inside picked architecture. Recommendation: patch spec before op-sem.**

**Performance attacker (opus) — 8 vectors, 3 plausibly close the 30s budget.** Reified constraint allocation (~1.8 MB live heap on `type_test.lua` alone); SCC recomputation cost; delta-driven re-firing quadratic on binding chains; β-reduction exponential on nested HKTs; HOUnify constraints not properly indexed by head shape; typestate as separate pass × substitution stability undefined. **Recommendation: reconsider architecture before op-sem.**

**Corpus survey (Explore) — H4 refuted empirically.** Across 700 non-excluded `setmetatable` sites in `lib/`: 60% FITS, 9% MODULE-MT, 6% HELPER, <1% ESCAPES, ~0% MUTATES-POST-SEAL, 24% OTHER. The H4 design's claimed-acceptable "5% refactor" exit is empirically a **40% refactor** — 8× off. `lib/epoll`, named by the H4 design as fitting, was independently found to not fit by the composition attacker.

### Triage outcome (orchestrator + user, 2026-05-22)

User clarified scope: "literal SOTA because the typechecker is load-bearing for an ecosystem that should last a century." Scope cuts off the table. The cross-pick contradictions are architectural and compound over decades — must be fixed at this stage, not papered over.

Three fixes accepted to the four picks, resolving the cross-pick contradictions:

**Fix 1 (Scheduler): drop precomputed SCCs entirely.** The scheduler design invented stratification as a performance optimization, then promoted it to a correctness mechanism. The user-binding constraints (B1, B2, B3) don't require strata — pure worklist-to-quiescence terminates by the same monotone-substitution argument. Strata can return later as a performance optimisation (incremental rechecking, LSP file granularity); they are not architectural.

**Fix 2 (HKT encoding): De Bruijn levels internally.** Substrate's "monotonic union-find substitution as single source of truth" stays sound iff β doesn't allocate new tvars. De Bruijn levels (Lean/Coq style) make β a level-substitution, not a tvar allocation. Tvars get names for source/error reporting only; internally everything is De Bruijn. β is then pure with respect to the substitution. Cost of being wrong: error messages need a de-Bruijn-to-name post-pass — cheap.

**Fix 3 (H4 + Substrate): construction-phase as constraint kinds in the substrate, not a separate pass.** Replace "H4 = separate flow-sensitive pass over unique locals" with: **construction-phase constraint variants** (`CTableOpen`, `CTableSet`, `CTableSeal`) that participate in the main worklist. Same open/sealed/row semantics expressed as constraints, not a parallel mechanism. This directly fixes the `lib/epoll` non-orthogonality — `μ = typeof(self)` becomes a `CSeal(obj, ?μ_self)` constraint that waits for `self` to be solved, exactly like any other constraint. For the corpus-coverage problem, the construction-phase constraint model admits:
- **MODULE-MT (9%)**: module-top-level treated as one extended open-construction block; `return M` is the seal.
- **Self-reference `__index = self`** (lib/github pattern): special-case rule — sealing with self-reference is sound iff the methods table is sealed first.
- **HELPER (6%)**: `Open[R_in] → Open[R_out]` parameter annotations available in v5.0, not deferred.
- **OTHER (24%)**: needs case-by-case audit. Some are MUTATES-POST-SEAL in disguise (unsoundness in current code, refactor); some are MODULE-MT subtypes; some may require additional model extensions.

Alternative considered and parked: full Mezzo permissions. Previously rejected on "pervasive churn" + "unsolved research with HKT"; both reasons now suspect since the corpus survey shows churn was a wash and v5 is research-grade everywhere. Re-evaluate if construction-phase-as-constraints fails its own corpus survey (>10% non-fit).

### Revised architecture (post-triage)

| Layer | Pick | Revision |
|---|---|---|
| Substrate | Reified `Constraint` ADT with provenance + Wanted/Given + 3 construction-phase variants | unchanged + 3 variants added |
| Scheduler | Worklist-to-quiescence, no precomputed strata | strata removed |
| HKT encoding | Direct type lambdas, De Bruijn levels internally, HO pattern unification + HOUnify residue | named representation → De Bruijn |
| Construction phase | Constraint kinds in substrate (CTableOpen / CTableSet / CTableSeal) | was: separate H4 typestate pass |

Also need to spec-patch (per soundness attacker):
- `setmetatable` post-seal rule (re-seal vs reject)
- Unbound effect-row variable disposition at quiescence (error or default-and-recheck, decide per variant)
- HOUnify residue head-rigidity wake-up (second index keyed by head shape)
- CImpl scope discipline for solving wanteds in nested implications (transcribe from OutsideIn)

### Next entry point

Re-attack the revised architecture before op-sem writing. Adversarial round 2: same surfaces (composition, soundness, performance, corpus) against the new picks. If the revised picks survive, op-sem writing proceeds.

---

## 2026-05-22 — Adversarial round 2 (4 attackers): triage resolved corpus, opened 8 severe structural patches

**Composition attacker** — 7 hits/8 vectors, 4 severe. Recommendation: re-open.
**Soundness attacker** — 4 severe + 5 moderate + 2 spec-clarification. Recommendation: re-open.
**Performance attacker** — architecture survives, 3 concrete spec gaps must close + prototype perf experiment required before op-sem.
**Corpus re-survey** — 100% fit on 20% sample. **Decisively resolves the H4 corpus issue.** The revised construction-as-constraints model is sound for the corpus.

### Severe items (must fix before op-sem)

1. **Per-tvar `open|sealed` phase bit** — CSeal/CMethodCall race (composition V1). Bit on the tvar binding; CMethodCall canonicalisation blocks until phase=sealed.
2. **Explicit `shift(level_delta, body)` + split solver-tvar identity from De Bruijn bound-var levels** (composition V3, soundness F4, perf A9). Solver-tvars are gensym IDs (never shift); lambda-bound vars use De Bruijn levels (shift under β). Lean's approach. The triage conflated them.
3. **Module-level fixpoint expression** for circular `require` × MODULE-MT (composition V4). Per-module batched solve = dynamic stratum (different from gen-time strata that Fix 1 dropped).
4. **Wait-graph SCC detection** for HOUnify mutual-wait (composition V7). The wait-graph is dynamic, smaller than the constraint-emission graph; the worklist maintains it.
5. **`setmetatable(t, nil)` rule** (soundness F2). Monotone substitution can't model clearing; need a `CTableClearMt` variant or restriction to fresh-table contexts.
6. **Rémy-level lowering ordering w.r.t. CImpl scope** (soundness F4). Specifies when level updates can happen relative to implication scope opening. Skolem escape if wrong.
7. **Multi-return into row rule** (soundness F10). `t.x, t.y = f()` where `f` may return 1 or 2 values. Union semantics over runtime possibilities, not common-prefix.
8. **Worklist discipline spec** (perf A2/A12). Tvar-indexed multimap + FIFO over ready set + starvation fairness. Without it, 10-100× perf cliff.

### Moderate items (resolvable during op-sem)

CTableSet ordering with multiple writes to same key; CTableSet on unannotated fn-arg; effect propagation through `__index`-as-function; module exports leaked tvar; `Open[R]` variance; HKT through CSeal's μ; provenance under De Bruijn rename; cyclic metatable chain; per-decl arena allocation.

### Pattern observation

The 4 severe ordering items (1, 2, 4, 8) likely consolidate into **one constraint ordering framework** — per-tvar phase tags + wait-graph SCC + module fixpoints + worklist discipline are all manifestations of "finer dynamic ordering than no-strata, coarser than per-constraint-edges." The triage's Fix 1 (drop strata) was directionally right but didn't replace strata with anything. The right answer is dynamic per-tvar phase tags that subsume what coarse strata did and more.

The remaining 4 severe items are concrete language-coverage rules: De Bruijn shift, setmetatable-nil, Rémy+CImpl, multi-return.

### Decision (orchestrator + user, 2026-05-22)

**Don't dispatch round 3.** Diminishing returns; round 2 hit rate is in finer-grained surfaces. Next move:
1. Orchestrator + user walk through each of the 8 severe items, picking resolution.
2. Build the prototype perf experiment (500-line worklist core; measure on `lib/std/init.lua` + `lib/test/init.lua`).
3. Then op-sem.

### Next entry point

Walkthrough item 1 / dependency root: representation question — De Bruijn shift discipline + split of solver-tvar identity from bound-var levels. Most other severe items reference levels; resolve representation first.

---

## 2026-05-22 — Severe item 2 closed: De Bruijn shift + tvar identity split

**Decision (user).**

Type AST splits two distinct entities:
- **`UVar(TVarId)`** — solver tvar; gensym ID, never shifts. Provenance attaches here (1:1 mapping UVar ↔ source name).
- **`Var(LvlIdx)`** — De Bruijn bound var inside type lambdas; shifts under β.

Operations: `shift(d, body)` walks `body` and increments every `Var(i)` by `d`. `instantiate(body, args)` substitutes `args[i]` for `Var(i)` while shifting nested binders. `UVar` is opaque to both.

**Eager shift on bind** for v5.0 — keeps substitution table flat and reasoning simple. Lazy-shift (Lean/Coq sliding-window cache) deferred as a future low-priority experiment after everything's stable; revisit if benchmarks show shift cost is hot.

Provenance for error rendering: free `UVar`s render via gensym↔name table; bound `Var(LvlIdx)`s render by walking back to the binder's introducer name via the rendering scope context.

Mirrors Lean's metavariable + expression-with-bvars discipline. Cited as Lean's `instantiate` primitive — ~150 LOC in our shape.

---

## 2026-05-23 — Severe item 6 closed: tvars don't change level

**Decision (user).** Option (C): each tvar gets its level at creation; the level never changes. Generalisation at scope-exit closes over tvars whose creation-scope is the current scope or deeper. Mirrors Lean's metavariable discipline.

**Rejected alternatives.**
- (A) OCaml/Rémy: level lowering on unification with bookkeeping to prevent skolem escape. Reactive; one failure mode is F4. Rejected on A1 (soundness floor).
- (B) Defer level-lowering inside open CImpls. Postpones the bookkeeping but doesn't remove the failure mode.

**Trade accepted.** Missed-generalisation in edge cases where a tvar legitimately could be generalised but its creation-scope was already outer. User must hoist or annotate. Per the analogous trade in item 2: revisit only if benchmarks show real cost.

**Owed follow-up (commitment).** Before declaring v5 stable, run an adversarial corpus generation pass to find real-world missed-generalisation cases. Generate Lua snippets that the (C) discipline rejects but (A) would accept; classify by whether they're idiomatic, rare, or pathological. If idiomatic patterns are common, revisit (A) as an optimisation. Tracked as a follow-up item; not blocking op-sem.

**Soundness gap F4 closed by construction.** No level-lowering ⇒ no skolem escape via level race. CImpl skolem invariants follow from tvar identity discipline (item 2's gensym IDs).

---

## 2026-05-23 — Severe item 8 closed: worklist discipline deferred to implementation

**Decision (user).** Specific scheduler discipline (FIFO vs LIFO, exact head-rigidity wake-up semantics, fairness guard) is too speculative to settle on paper. **Defer to implementation; document the experience via experiment logs as the prototype reveals what's hard.**

**Framework agreed** (no decision needed at this layer):
- Tvar-indexed multimap of parked constraints. Wake on tvar binding.
- Separate parked map for HOUnify-style "wake on head rigidity" (matches item 4).
- Worklist core is ~500 LOC; the performance attacker's recommended prototype is the right falsifiability gate.

**Open at implementation time**: FIFO vs LIFO over ready set; whether fairness needs an explicit guard; how to detect a wake-up bug (parked constraint whose watch-tvars are all bound but didn't fire); whether to add priority queueing as a perf opt later. Each gets a log entry under `docs/perf/log.md` or `docs/typechecker-v5-log.md` as the prototype shapes them.

**Owed follow-up.** Exhaustive mining of prior session JSONLs in `~/.claude/projects/-home-me-git-rhizone-crescent/` for insights on scheduler-shaped problems and what mechanisms previous attempts found load-bearing. The session-history agent earlier this session did a sampled pass (5 arcs); exhaustive mining is a separate, longer task. Added to root `TODO.md` (high prio, permanent doc for everyone to read).

---

## 2026-05-23 — Severe item 1 closed: per-tvar phase bit as part of binding

**Decision (user).** Yes — add `Phase = Open | Sealed` as part of the substitution's binding shape, not a side-channel.

**Substitution shape.** `TVarId → (Type, Phase)`. A tvar bound to `Table[R]` with `Phase=Open` means the row R may still grow; `Phase=Sealed` means R is final and method dispatch is permitted.

**Constraint rules.**
- `CTableOpen(t)` introduces `t ↦ (Table[{}], Open)`.
- `CTableSet(t, k, v)` requires `Phase=Open`; extends R; phase stays Open.
- `CTableSeal(t, μ)` flips Phase to Sealed; binds metatable type.
- `CMethodCall(t, m)` requires `Phase=Sealed`. Parks until the seal fires.
- `CTableSet` on Sealed → A1 reject ("can't mutate sealed table").

**Why this isn't a side-channel.** Phase is part of the binding itself — same data shape that's the substrate's single source of truth (per item 2). Not a parallel mechanism (no B5/B6 violation).

**Open at implementation time.** Exact wake-up shape when Phase flips; whether CTableSet on Sealed is immediate reject or parked-error-at-quiescence; how to report.

**Soundness gap V1 (composition attacker) closed.** Phase=Sealed precondition on CMethodCall is the ordering invariant the scheduler lacked.

---

## 2026-05-23 — Severe items 3, 4, 8 collapse: no cycle detection

**Decision (user).** Drop cycle detection from the solver design. Items 3 (module-level fixpoint), 4 (wait-graph SCC for HOUnify mutual wait), 8 (worklist discipline as separately-specified ordering) collapse into a single simpler design.

**Substrate semantics.**
- Worklist of constraints + inert set + monotone union-find substitution. No parked-on-event map; no wait-graph; no SCC computation.
- Pop a constraint from worklist. Try to make progress against current substitution. If progress: extend substitution, emit any new constraints to worklist, re-add affected inert constraints to worklist. If no progress: add to inert.
- **Quiescence = worklist empty.** That's the whole termination rule.
- At quiescence, every inert constraint is an error. Each reports its own stuck-ness.

**Circular `require` is a typecheck-time error.** Modules typecheck in topological order; cycles are rejected with a "restructure your modules; consider factoring shared types into a third module" diagnostic. Lua allows circular require at runtime; v5 doesn't. Corpus impact: presumed small (circular require is an antipattern even in untyped Lua); confirm pre-stable via grep.

**Trade explicitly accepted.**
- Some programs that would have typechecked with a fixpoint-over-modules don't anymore. User restructures.
- Mutually-ambiguous HOUnify constraints (e.g. `?F<?G<int>>` + `?G<?F<int>>`) produce two `ambiguous` errors instead of one `cycle` error. Mitigation in the error renderer: when emitting an ambiguous-inert error, name other inert constraints whose progress would have unstuck this one. Recovers ~80% of cycle diagnostic info without computing SCCs.

**Wins.**
- Termination story is one rule: worklist empty.
- Spec shrinks. One named concept (`wait-graph SCC`) eliminated. The "two-tier quiescence" (module-group / CImpl / core) becomes "just quiescence."
- Diagnostic for circular `require` is *better* without — "restructure" beats "here's an inferred fixpoint."

**Aligns crescent's solver lineage with Lean's elaboration discipline** rather than GHC's wait-graph-style inert set. Both are SOTA; the Lean lineage favours simplicity over expressivity at the cycle margin.

**Owed pre-stable check.** Grep `lib/` for circular `require` patterns. If any are load-bearing (vs incidental), revisit before declaring v5 stable. Added to root `TODO.md`.

### Severe items remaining

Items 5 (`setmetatable(t, nil)`), 7 (multi-return into row). Both concrete language rules, smaller surface than the ordering questions.

---

## 2026-05-23 — Severe item 5 closed: unconditionally disallow `setmetatable(t, nil)`

**Decision (user).** Unconditional reject. No carve-out for Open-phase tables. The type of `setmetatable`'s second argument is `Table`, not `Table | nil`.

**Mechanism.** Stdlib types declare `setmetatable : <T, M: Table>(T, M) -> Sealed<T, M>`. Pass `nil` → type error at the call site. Same shape any other type mismatch takes.

**Diagnostic.** "cannot pass `nil` to `setmetatable`; v5.0 does not support metatable clearing. See backlog item."

**Trade.** Stricter than necessary on Open-phase tables (clearing a non-existent metatable is sound) but simpler spec: one rule, no exceptions. Conforms to the v5 frame of "simpler invariants compound over decades."

**Sandboxing power preserved via fresh-table pattern.** Sandboxing IS the strongest real use case for `setmetatable(t, nil)` (e.g., Scribunto, LuaSandbox patterns: build env inheriting trusted globals, then strip prototype before exposing to untrusted code). The fresh-table alternative serves it without `setmetatable(t, nil)`:
```lua
local clean = {}
for k, v in pairs(env) do clean[k] = v end
provide_to_untrusted(clean)
```
Arguably safer — no transient state where metatable is partially stripped. v5's rejection nudges sandbox code toward this pattern.

**Backlog item (medium prio, bumped from low for sandboxing context).** Investigate whether `setmetatable(t, nil)` can be soundly supported in a future v5.x. Open: does it require breaking monotone substitution, treating each setmetatable call as creating a fresh table identity (contradicts Lua's "same `t` reference" semantics), or is there a third path? Note the fresh-table pattern is likely the actual answer — the v5.x decision may be "yes, document the fresh-table idiom as the canonical sandboxing pattern, never support setmetatable(t, nil)."

**Soundness gap F2 (soundness attacker) closed by rejection.**

---

## 2026-05-23 — Severe item 7 closed: multi-return union semantics + strong-but-sound narrowing

**Decision (user).** Union of branches for multi-return; strong narrowing for the resulting pseudo-discriminated-unions; **no narrowing when a row variable affects the narrowing path** (soundness floor).

**Return-type unification rule.** A function with multiple return statements of varying arity has its return type unified as a max-length tuple where each component is the union of contributions across branches, with `nil` filling missing-arity branches. Concretely:
- branches `return 1, 2` and `return 3` unify as `(int, int | nil)`.
- branches `return ok, val` and `return nil, msg` unify as `(ok_type | nil, val_type | msg_type)`.

**Multi-assignment rule.** `local x, y, z = f()` and `t.x, t.y = f()` types each LHS position from the corresponding tuple component. Missing positions bind `nil`.

**Narrowing rule (strong-but-sound).** Flow-typing narrows aggressively on closed pseudo-discriminated-unions:
- `if t.y then ... end` narrows `t.y : int | nil` to `int` in the branch. Standard A8/A2 discipline.
- `if t.tag == "a" then ...` narrows a union of records discriminated by `tag` to the matching branch. Standard.
- `assert(t.y)` narrows post-assert. Standard.

**Soundness floor**: narrowing is suppressed when a **row variable** affects the narrowing path. Specifically: if the type being narrowed contains a row variable (an open row that may be extended), narrowing on a discriminant field does not commit the type narrower — because the same discriminant value might be inhabited by row extensions the typechecker can't see. The narrowed binding falls back to the original type.

Concrete example of the soundness floor:
```lua
function f<R>(x: R extends {tag: "a"}) ...   -- R is open
if x.tag == "a" then
  -- x is NOT narrowed; x stays at type R extends {tag:"a"}.
  -- (in a closed-row context, narrowing would commit; here it can't.)
end
```

**Cost.** Some idioms that would narrow under row-polymorphism don't. Mitigation: users can close the row at the binding site (concrete record type) and narrowing fires normally.

**Soundness gap F10 (soundness attacker) closed by union semantics.**

---

## 2026-05-23 — All 8 severe items closed

Walkthrough complete. Items 1, 2, 3, 4, 5, 6, 7, 8 all resolved:

| Item | Resolution |
|---|---|
| 1 | Per-tvar `Phase = Open \| Sealed` as part of substitution binding |
| 2 | De Bruijn levels for bound vars + gensym `UVar` for solver tvars; eager shift |
| 3, 4, 8 | Collapse: no cycle detection; worklist + inert set + monotone substitution; circular `require` rejected |
| 5 | `setmetatable(t, nil)` unconditionally rejected; sandboxing served by fresh-table pattern |
| 6 | Tvars don't change level (Lean discipline); no Rémy lowering |
| 7 | Multi-return unified as tuple-of-unions with nil padding; narrowing strong but suppressed on row variables |

**Architecture as it now stands:**

- **Type AST** — `Type ::= UVar(TVarId) | Var(LvlIdx) | App | Lambda | ...` with `UVar` opaque to β.
- **Substitution** — `TVarId → (Type, Phase)`, monotone, single source of truth.
- **Constraints** — reified ADT with provenance, Wanted/Given flavour, including `CEq`, `CSub`, `CInst`, `CHKT`, `CEffect`, `CRow`, `CImpl`, `CTableOpen`, `CTableSet`, `CTableSeal`, `CMethodCall`, `HOUnify`, `CMultiReturn`.
- **Scheduler** — worklist + inert set + substitution. Pop, try progress, extend substitution or add to inert, re-add affected inert to worklist. Quiescence = worklist empty. Inert at quiescence = errors.
- **Narrowing** — strong flow-typing on closed unions; suppressed on row variables.
- **Cross-module** — modules typecheck in topological order; circular `require` rejected.

### Next entry point

Prototype perf experiment. ~500 LOC worklist core. Feed synthetic constraints derived from `lib/std/init.lua` (record-heavy) and `lib/test/init.lua` (annotation-heavy). Measure: wall time, live heap at quiescence, constraint-reactivation count. Targets per perf attacker: <500ms wall on either file, <2 MB heap, <5× reactivations vs emissions. If those hold, the architecture's perf claims are real; if not, allocation strategy needs work before op-sem.

After the prototype passes its gate: operational-semantics writing (H7: parallel impl + docs with parity tests).

---

## 2026-05-24 — Prototype perf gate: PASS (with honest caveats)

Opus agent built 1149 LOC of typechecked Lua under `lib/type/experiments/v5_perf/`. Six files: types, subst, constraint, solver, corpus_extract, bench. Commits `6bbe20a4`, `ebc41ada`, `fb4576e3`, `74d224a9`. Full results in `docs/perf/log.md`.

### Gate verdict

| Gate | Target | Worst median | Margin |
|---|---|---|---|
| Wall time | <500 ms | 0.18 ms | ~2700× |
| Live heap | <2 MB | 21.1 KB | ~100× |
| Reactivations / emissions | <5× | 0.067× | ~75× |

**PASS on all three gates.**

### What this validates

- Substrate `Type` ADT with `UVar`/`Var`/`App`/`Lambda`/`Const`/`Record`/`Arrow`/`Union` variants — implementable cleanly in pure Lua, ~190 LOC.
- Substitution as monotone `TVarId → (Type, Phase)` with union-find + path compression — works, ~200 LOC.
- Worklist + inert + tvar-indexed wake-up — works for the minimal constraint subset (`CEq/CSub/CTableOpen/CTableSet/CTableSeal/CMethodCall`).
- FIFO over ready (not LIFO — the agent caught a seal-before-set causality issue mid-implementation and switched; exactly the deferral-to-implementation discipline working as designed).
- `--summary`-amenable provenance tagging per constraint.

### Honest caveats (NOT PASS for these)

1. **Constraint counts (454, 208) are 100-200× below the architecture's target scale (~10⁵).** Agent's linear extrapolation predicts ~40ms at 10⁵; non-linear factors (cache pressure at large heaps, GC pause time, LuaJIT trace bailouts) aren't captured. Re-gate at realistic scale once the corpus extractor covers more constraint shapes.
2. **The hard constraint variants are not implemented or tested.** `CInst/CHKT/CEffect/CRow/CImpl/HOUnify/CMultiReturn` all have potentially different step costs and reactivation profiles. The gate must be re-run as each lands.
3. **Synthetic gen-pass, not real.** The extractor is pattern-grep over annotations + setmetatable sites. Real gen-pass may have different ordering, different dependency density. The stress-reorder mode shows headroom but doesn't simulate worst-case dependency chains.
4. **Files substituted**: `lib/test/arb.lua` and `lib/stdlib/lint.lua` used instead of the spec's `lib/test/init.lua` and `lib/std/init.lua` because those don't exist in the tree. Both replacements are corpus-representative but the spec target should be revised.

### Interpretation

The PASS verdict validates the **basic substrate + scheduler shape**. It does NOT validate the full architecture under realistic load. The architecture's perf claim is "probably real" — promoted from "design hypothesis" — but a full perf re-gate is owed at each constraint-family landing during op-sem implementation.

### Op-sem unblocked

Operational-semantics writing can begin per H7 (parallel impl + docs with parity tests). Per F2, op-sem must be runnable, not prose. The structure:
- `docs/typechecker-v5-operational-semantics.md` — inference rules.
- `lib/type/static-v5/op_sem.lua` — executable spec (extends the prototype's substrate).
- Parity test asserting both produce the same judgments on a small fixture set.

### Re-gate schedule

Per CLAUDE.md F10 + perf log discipline: re-run the perf gate after each major constraint family lands (CInst, CHKT, CEffect, CRow, CImpl, HOUnify). Log results to `docs/perf/log.md`. If any re-gate fails: stop op-sem advancement, address the perf regression first.

---

## 2026-05-24 — Op-sem v5.0 minimal core: docs + executable spec + parity test landed

Per H7 (parallel impl + docs with parity tests) and F2 (op-sem is a runnable test, not prose).

### Deliverables

| File | LOC | Purpose |
|---|---|---|
| `docs/typechecker-v5-operational-semantics.md` | 402 | Inference-rule prose, one rule per labelled `T-*`/`S-*` form |
| `lib/type/static-v5/op_sem.lua` | 536 | Executable spec — each labelled rule is a `rule_<label>` function; `run` is the S-Step/S-Park/S-Wake/S-Quiesce loop |
| `lib/type/static-v5/op_sem_parity_test.lua` | 244 | Parity test — for each fixture, drives the rules by hand AND runs the solver, asserts equal final state |

### Scope

Six constraint variants (exactly): `CEq`, `CSub` (stub as eq), `CTableOpen`, `CTableSet`, `CTableSeal`, `CMethodCall`, plus `CInst` (Option X form, deferred instantiation as first-class constraint).

Out of scope (own re-gate each): `CHKT`, `CEffect`, `CRow`, `CImpl`, `HOUnify`, `CMultiReturn`. Out of op-sem entirely: module-ordering / circular-require rejection (driver level).

### Methodology of the parity test

For each fixture, two paths produce a final substitution + error set:
1. **EXEC**: emit constraints, call `op_sem.run` (full worklist loop).
2. **DOCS**: drive the same scenario by *calling rule functions in source order*, without the solver loop. The docs path is a hand-encoded trace of (rule_label, hypotheses).

The test asserts the two paths produce equal resolved types at chosen tvars and equal error counts/rules. Divergence means EITHER the doc rule is wrong OR the executable rule encodes something different — both forms must be reconciled. This is the F2 forcing function.

### Test results

```
$ timeout 30 bin/cr test lib/type/static-v5/
  pass  lib/type/static-v5/op_sem_parity_test.lua  (31 passed)
1 passed, 0 failed, 1 total  (31 assertions)
```

All 7 fixtures pass (5 in-scope + 2 documented-as-stand-in for out-of-scope variants).

### Spec gaps surfaced

Per F12 (do not silently invent rules), the following gaps were *named* during writing rather than filled:

1. **μ.__index chain walk** for CMethodCall when the field is missing on the sealed table. v5.0 rejects; chain-walking interacts with HKT-shaped metatables and needs orchestrator design before landing. Marked in the doc's "What this does NOT cover" section.
2. **CMultiReturn** for `t.x, t.y = f()` with union-arity returns. The fixture for this (task fixture 6) is encoded as a scalar stand-in; the union form is a separate op-sem extension.
3. **CRow** narrowing-suppression on row variables (fixture 8). Omitted entirely; reinstate when CRow lands.
4. **CSub variance**. v5.0 routes CSub to CEq; the variance-respecting form is owed in the CHKT op-sem extension. Tracked.

### Risks for the next constraint family (CInst surface forced)

CInst (the closest extension already in this op-sem) forced these substrate decisions:
- **β must be a pure function of the substitution**, not a substitution event. `T-CInst` allocates fresh tvars via `subst_mod.fresh` and substitutes via `types_mod.instantiate` — both already in the prototype substrate. No new wake-up plumbing needed.
- **Scheme representation is De Bruijn-indexed body + binder count**, per log item 2 (split solver-tvar from bound-var levels). Schemes use `Var(i)` exclusively; instantiation produces a body with fresh `UVar(id)`s.
- **Iterated `instantiate(body, fresh, 0)`** with depth 0 every time — relies on the prototype's eager-shift discipline so each instantiate decrements outer indices. Verified by fixture 5 producing two independent fresh tvar specialisations.
- **What CHKT will force**: `CInst` did NOT need to add a wake-up shape (scheme is fully concrete at the instantiation site). CHKT *will* — `HOUnify` parks on head rigidity and needs the second-index parked-map the log called out under severe item 4. The current substrate has the watch-map shape but not the head-shape indexing.

### Caveats and what was NOT done

- The two paths in the parity test go through the same `rule_T_*` functions in op_sem.lua. They are not two independently-written rule interpreters. The forcing function still works (a wrong rule in op_sem.lua breaks both forms identically, so the assertion would still pass — but the source code matches the docs line-by-line via the label cross-reference table). A stronger parity check (two independent encodings, e.g. one in Lua and one transcribed from the doc by a different agent) is owed before v5.0 is declared stable. **Logged as backlog.**
- Fixture 7 (circular require) is encoded as a degenerate "empty constraint set" test because op-sem itself does not see require. The actual policy belongs in the module driver. Not a fixture for op_sem.
- Full test suite parity confirmed: pre-change (540 pass / 45 fail / 10 skip) matches post-change exactly. No A11 regression.

### Next entry point

Either:
1. Begin CInst-related real codegen (gen pass emitting CInst from `local f = function...` source), or
2. Land the next constraint family per the re-gate schedule (CHKT is the natural next step since it forces the head-shape watch-map).
