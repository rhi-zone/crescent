# Typechecker v5 — Discovery, Exploration, and Decision Log

Append-only. One entry per session, decision, or experiment.

**Companion files:**
- Constraints catalog (the binding spec): `docs/typechecker-v5-constraints.md` (relocated into repo 2026-05-25; originally lived at `~/.claude/plans/radiant-gathering-gray.md`).
- Unframed architecture discovery: `docs/typechecker-v5-discovery-unframed.md`.
- Tainted (pre-framed) discovery: `docs/typechecker-v5-discovery-tainted.md` — radioactive; do not cite as design evidence.

**How to use this file:** Each entry is dated. Sections within an entry: *Question*, *Evidence*, *Decisions closed*, *Decisions still open*, *Tainted artifacts*, *Next entry point*. The point of the log is to make tactical-for-strategic substitution (session audit §1 P1) visible across sessions — an entry that resolves nothing should be obvious as such.

---

## 2026-05-26 — Phase 5 (source pipeline): ann.lua, constrain.lua, cli.lua, --v5 flag

### Question entering session

Can the v5 op-sem be connected to real Lua source — parse → annotate → generate
constraints → solve — so that `bin/cr check --v5 <file>` produces output?

### Evidence

**Four commits landed (parity 275/275 preserved throughout):**

| Phase | Commit | Description | Assertions |
|---|---|---|---|
| 5.A ann.lua | `52fcae6f` | Annotation parser ported to v5 substrate: `--:` / `--::` / cast forms; effect-type syntax (`!Name<Args>`); intersection syntax (`&`); `$Require<T>` intrinsic; `declare` form. ann_test.lua added: 156 assertions. | 275 → 431 |
| 5.B constrain.lua | `0ff434aa` | Gen-pass walker: traverses Lua AST, emits v5 constraints. Handles local decls, function bodies, call sites, return statements, record construction. constrain_test.lua added: 27 assertions across 12 fixtures. | 431 → 458 |
| 5.C effect propagation | `6da6db59` | Effect propagation through call chains: callee effects propagate to caller via CIntersectionMember constraints. pcall/coroutine stubs in stdlib_types.lua. constrain_test extended: 28 new assertions. | 458 → 486 |
| 5.D CLI + e2e | `317acc9b` | `bin/cr check --v5` flag wired end-to-end: parse.lua → ann.lua → constrain.lua → op_sem.lua. Solver fixes: T-CSub-Top/Never, T-CSub-LitWiden, T-CSub-TVar (uvar parking), S-Quiesce CEq drain. demo_effects.lua fixture. cli_e2e_test.lua: 18 assertions. | 486 → 504 |

**Hand-run confirmation:** `timeout 30 bin/cr check --v5 lib/type/static-v5/fixtures/demo_effects.lua`
exits 0. (v4 on same file: 5 warnings, exits 0, 32–43ms wall. v5 on same file: 9–10ms wall.)

### Six honest gaps (open work, not landed work)

These are gaps that exist in the Phase 5 source pipeline. They are NOT closed.
A fresh reader should understand they represent material work remaining.

**Gap P1 — Effect propagation from field-access callees is broken.**
`io.write(...)` has a uvar callee at gen-pass time, so `!io` is never extracted
into the propagation chain. Only direct-bound names (`print`, `error`) propagate
effects. F2 enforcement does NOT actually fire for the common case of dotted stdlib
calls (e.g., `io.write`, `os.execute`), even though the e2e test suite passes.
The e2e tests only exercise direct-bound callees.

**Gap P2 — pcall return type is flat `boolean | unknown`.**
The correct type is a discriminated tuple-union `(true, R...) | (false, E)`.
Implementing the discriminated form requires variadic generics (G17). Current
stdlib_types.lua returns a flat `boolean | unknown` pair, which loses the
success/failure type distinction entirely.

**Gap P3 — `coroutine.create` returns `thread`, not `Coroutine<Y,S,R>`.**
Full parameterisation of coroutine types (yield type, send type, return type) is
deferred. Current stub returns the unparameterised `thread` constant.

**Gap P4 — Arrow subtyping converts `sub(uvar, concrete)` to CEq at S-Quiesce.**
Proper upper/lower bounds tracking ("bounded tvars", spec gap G9) is deferred to
v5.x. At S-Quiesce, a still-unbound uvar under an Arrow CSub defaults via CEq, which
is overly restrictive and may reject valid programs.

**Gap P5 — Ann surface: surface syntax features not yet wired to gen-pass.**
The 5.A ann.lua parser handles `&` intersection and `!Name<Args>` effect syntax in
type positions. However, gen-pass (constrain.lua) does not yet request or emit
constraints for: type predicates (`x is T`), match types, newtype declarations,
augment declarations, pattern types. These syntactic forms are parsed but ignored
at gen-pass time.

**Gap P6 — Constrain surface: closure-as-value intricacies not handled.**
Complex narrowing paths (e.g., closures as values, method dispatch edge cases,
upvalue capture across scopes) are not modelled in constrain.lua. The gen-pass
walker handles straight-line and basic function bodies; it does not handle
closures stored in tables, `self`-style method dispatch via `:`, or upvalue
capture narrowing.

### Decisions closed

- **v5-source-pipeline-integration**: parser + gen-pass + CLI wired. `bin/cr check --v5`
  is runnable end-to-end. Closed with the six gaps above documented as open work.

### Decisions still open

- **G17** (variadic generics): low-medium prio, blocks accurate pcall/coroutine typing.
- **Gap P1** (dotted callee effect propagation): broken; not a v5.0 blocker but visible.
- **Gap P2** (pcall discriminated return): flat return is wrong but safe (not unsound).
- **Gaps P3–P6**: deferred surface and constrain coverage.
- **G9** (bounded tvars), **G10, G11**: unchanged.
- **H10** (`any` escape hatch): still open, not blocking.

### Tainted artifacts

None.

### Next entry point

1. Fix Gap P1 (dotted callee effect propagation) — enables F2 enforcement for the
   real `io.*`/`os.*` call patterns that dominate real code.
2. G17 design (variadic generics) — prerequisite for Gap P2 fix.
3. Pre-stable follow-ups (mining, missed-gen eval, circular require corpus check).

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

The constraints catalog is at `~/.claude/plans/radiant-gathering-gray.md` — outside the repo. For durability and reviewability, it likely belongs under `docs/typechecker-v5-constraints.md` or similar. Not relocated this session; flagged for next session. **Resolved 2026-05-25** — see entry below; catalog now at `docs/typechecker-v5-constraints.md`.

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
- ~~**Constraints catalog relocation**: `~/.claude/plans/radiant-gathering-gray.md` → `docs/typechecker-v5-constraints.md`.~~ Done 2026-05-25.
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

---

## 2026-05-24 — Op-sem v5.0 CHKT + HOUnify extension: docs + executable + parity + perf re-gate

Per the re-gate schedule, the next constraint family. Picks recorded in
the H8/H9 walkthrough land here unchanged: direct type lambdas, Miller
pattern fragment, **never commit guessed HO solutions** (soundness floor),
park-on-head-rigidity for the non-pattern case.

### Deliverables

| File | Change | Commit |
|---|---|---|
| `lib/type/experiments/v5_perf/subst.lua` | +65 LOC: `head_watchers` map + `watch_head` / `drain_head_watchers` / `head_is_rigid`; union() migrates the new map | `e9a06c3e` |
| `docs/typechecker-v5-operational-semantics.md` | +163 LOC: 6 new rules (T-CHKT-Miller / Reduce / Rigid-Mismatch / Park, T-HOUnify-Wake / Stuck) + S-Wake-Head + cross-reference + 5 named spec gaps | `b3259fd0` |
| `lib/type/static-v5/op_sem.lua` | +314 LOC: CHKT/HOUnify constructors, 6 rule functions, head-watch park dispatch, miller_check, abstract_body | `0550959f` |
| `lib/type/static-v5/op_sem_parity_test.lua` | +277 LOC: 5 new fixtures (9, 10, 11, 12, 12b, 13) — Functor<Maybe> reduce, Miller identity, compose-style ambiguity, head-rigidification wake, orphan ambiguity | `0d8434e2` |
| `lib/type/experiments/v5_perf/bench_chkt.lua` | new (~165 LOC): perf re-gate harness layering synthetic CHKT/HOUnify on base corpus, running op_sem dispatcher | `04e73324` |
| `docs/perf/log.md` | +83 LOC: re-gate verdict — PASS on all three gates | `04e73324` |

### Test results

```
$ timeout 30 bin/cr test lib/type/static-v5/
  pass  lib/type/static-v5/op_sem_parity_test.lua  (49 passed)
1 passed, 0 failed, 1 total  (49 assertions)
```

49 assertions (was 31; +18 across 5 new fixtures). All pass.

### Perf re-gate verdict

| File | wall median | heap median | react/emit | Verdict |
|---|---|---|---|---|
| `lib/test/arb.lua` (498 constraints, 44 CHKT) | 0.81 ms | 159.9 KB | 0.030 | **PASS** |
| `lib/stdlib/lint.lua` (228 constraints, 20 CHKT) | 0.36 ms | 89.7 KB | 0.049 | **PASS** |

All three gates pass (<500 ms / <2 MB / <5×) with comfortable margins on both files. Heap grew ~8× from baseline due to `abstract_body` Lambda allocation + reified CHKT/HOUnify; wall time grew ~4×. See `docs/perf/log.md` for raw runs.

### Spec gaps surfaced (per F12 — named, not silently filled)

1. **Restricted Miller fragment.** v5.0 admits only `UVar` or `Const` as
   pattern arguments. Full Miller fragment admits arbitrary rigid tree
   args. Owed when corpus example forces it.
2. **No kind inference.** `Type.Lambda.k` is a documentation tag, not a
   kind. Arity mismatches surface as shape errors, not arity errors.
   v5.x extension owed.
3. **No eta-equivalence.** `λx. F x` not equated with `F` during Miller
   check. Real-world impact unknown.
4. **No shift-aware abstraction over nested lambdas.** `abstract_body`
   bails (via `contains_lambda` guard) when result contains an inner
   Lambda. Orchestrator decision owed: reject at abstraction time, or
   support via De Bruijn shift through abstracted binders?
5. **HOUnify residue provenance chaining.** A HOUnify born of a CHKT
   born of a CImpl-nested wanted needs three-deep provenance for good
   error messages. Substrate carries `prov` per-constraint but the
   chaining helper isn't built. Owed when CImpl lands.

### Risks for CEffect (the next natural constraint family)

- **Effect rows are open records.** The substrate already has open
  records (via phase=Open + row extension); effect rows reuse that
  machinery. Risk: row extension during effect tracking interacts with
  the head-watch parked-map differently than CHKT does — effects "rigidify"
  via row-closure, not via constructor head binding. New variant of
  S-Wake-Head likely needed (S-Wake-RowClosed?).
- **Coroutine yield typing** per H2's effect-justification needs a way
  to thread effect rows through arrows. The current `Arrow(args, rets)`
  AST has no effect field; either extend the AST or encode effects as
  an additional implicit arg/ret. Spec-design decision before
  implementation.
- **Effect subsumption is variance-sensitive.** Currently `CSub` is
  routed to `CEq` (the variance-respecting form was already owed for
  CHKT and is now doubly owed). CEffect cannot avoid this — handler
  subsumption is meaningful only with directed subtyping.
- **Soundness floor for unbound effect-row variables at quiescence.**
  Per soundness attacker round-2 finding F2: "default-and-recheck OR
  error" — orchestrator decision owed. The HOUnify pattern here
  (default = error, "ambiguous constructor variable") is one model;
  effects may want default = empty-row instead, with implications for
  generalisation. Decide explicitly per F12, not by analogy.

### Stronger-parity status — same caveat carries over

The two paths in the new fixtures (EXEC vs DOCS) still go through the
same `rule_T_*` functions, exactly as the prior op-sem entry noted.
The forcing function still works (a wrong rule breaks both forms
identically), but the source-vs-doc cross-reference is still the load-
bearing parity check. Independent re-encoding of the rules (e.g. by a
separate agent transcribing the docs into Lua without seeing op_sem.lua)
is still owed before v5.0 is declared stable. **Backlog item carries
forward — not closed by this extension.**

### Test suite parity (A11)

Full suite shows mild flakiness: baseline runs report 540 pass / 45 fail
or 539 pass / 46 fail in successive runs even without any change (the
test infrastructure has "no result from worker" failures from parallel
runner timing). Pre- and post-CHKT runs on the same checkout show the
same noise. No real regression introduced by this extension — but the
test-runner flakiness should be flagged as a separate concern.

### Next entry point

Either:
1. CEffect op-sem extension (the natural next per the re-gate schedule).
2. CRow op-sem extension (interacts with CEffect via row mechanism reuse).
3. CImpl op-sem extension (needed for HOUnify residue provenance chaining; needed before realistic gen-pass CHKT emission).

The CEffect path is the larger commitment — pick first if open to a
deeper-research-risk extension; otherwise CRow is the lower-risk
incremental.

---

## 2026-05-24 — Op-sem v5.0 CSub variance-respecting rewrite: debt half-discharged

Per the CHKT-extension entry's open thread: "CSub variance-routed-to-CEq
won't survive CEffect — the variance-respecting CSub form is now doubly
owed." This entry discharges the v5.0 half of that debt.  Row variance
remains owed for CEffect.

### Deliverables

| File | Change | Commit |
|---|---|---|
| `lib/type/experiments/v5_perf/variance.lua` | new (72 LOC): variance registry sidecar with declare / lookup / at / reset / flip | `0d58a06e` |
| `docs/typechecker-v5-operational-semantics.md` | +165/-10 LOC: 10 new rules (T-CSub-Refl / TVar / Arrow / Const-Var / App-Var / App-Struct / Record-Width / Union-L / Union-R / Mismatch), 5 named spec gaps, cross-reference updated | `d14b769e` |
| `lib/type/static-v5/op_sem.lua` | +246/-4 LOC: 10 rule functions + step_csub dispatcher + variance module re-export | `836985d1` |
| `lib/type/static-v5/op_sem_parity_test.lua` | +294 LOC: 6 fixture blocks (14, 15a–c, 16a–c, 17a–b, 18) — Arrow decomposition, App-Var per declared variance, Record-Width with soundness-critical invariance check, contra-arg sound rejection, TVar routing | `4ebc10ad` |
| `lib/type/experiments/v5_perf/bench_chkt.lua`, `docs/perf/log.md` | bench extended with synthetic CSub load (Arrow + record-width); re-gate PASS on all three gates with comfortable margins | `b29d5fdb` |

### Test results

```
$ timeout 30 bin/cr test lib/type/static-v5/
  pass  lib/type/static-v5/op_sem_parity_test.lua  (61 passed)
1 passed, 0 failed, 1 total  (61 assertions)
```

61 assertions (was 49; +12 across 6 new fixture blocks).  All pass.

Full suite A11 check: 540 pass / 45 fail / 10 skip — exact baseline
match.  No regression.

### Perf re-gate verdict

| File | wall median | heap median | react/emit | Verdict |
|---|---|---|---|---|
| `lib/test/arb.lua` | 1.88 ms | 201.8 KB | 0.027 | **PASS** |
| `lib/stdlib/lint.lua` | 0.63 ms | 104.1 KB | 0.044 | **PASS** |

All three gates pass.  Wall grew ~2× from CHKT baseline due to added
record-width CSubs emitting per-field CEqs; still ~250× wall margin and
~10× heap margin.

### Variance discipline summary

| Type form | Variance | Rule | Soundness basis |
|---|---|---|---|
| Arrow args | contravariant | T-CSub-Arrow | substitutability: callee accepts wider, callers pass narrower |
| Arrow rets | covariant | T-CSub-Arrow | substitutability: callee returns narrower, callers expect wider |
| Named App args (declared) | per-position (co/contra/inv) | T-CSub-App-Var | declaration-site H4 |
| Named App args (undeclared) | invariant (default) | T-CSub-App-Var | sound default (round-1 research §3) |
| Record fields | invariant (always) | T-CSub-Record-Width | mutable fields (CTableSet model) — covariant on mutable is TypeScript-array unsoundness |
| Record width | covariant (forget fields) | T-CSub-Record-Width | structural: wider <: narrower |
| Union LHS | covariant (each branch) | T-CSub-Union-L | each branch must conform |
| Union RHS | exact-branch only (v5.0) | T-CSub-Union-R | no backtracking; v5.x extension owed |
| TVar | invariant (routes to CEq) | T-CSub-TVar | no per-tvar bounds in v5.0 (log item 2/6) |

Citations: `docs/typechecker-v5-operational-semantics.md` § "Subtyping
(variance-respecting)" + soundness sketch.

### Spec gaps surfaced (per F12)

1. **Bounded tvars.** T-CSub-TVar routes to CEq.  Real bounded substrate
   (simple-sub / MLstruct) is a v5.x extension.
2. **Variance under Lambda.** Registry covers named Consts only; type
   lambdas don't yet carry variance.  Acceptable because CHKT β-reduces
   lambdas before dispatch — orphan cases owed.
3. **Union backtracking.** T-CSub-Union-R admits only exact-branch
   match.  Backtracking search owed.
4. **Effect-row variance.** When CEffect lands, handler subsumption
   needs row-tail variance.  Out of v5.0 minimal-core scope.
5. **Intersection types.** No intersection AST variant.  Algebraic
   Subtyping admits intersection-as-contravariant-union.

### CEffect impact

This discharges the v5.0 half of the CSub variance debt.  CEffect's
effect-row variance is a **separate** debt: row tails (open/closed)
need their own variance discipline (Koka-style effect subsumption), and
the row-machinery extension to T-CSub-Record-Width-like rules isn't
written yet.

What changes for CEffect work:
- CEffect can now emit CSub on the value/effect arrow shape and trust
  variance-respecting decomposition; it does NOT need to hand-roll
  contra-arg + co-ret + co-effect-row decomposition into CEq.
- The remaining CEffect-specific work is row-tail variance for the
  effect row itself, not arrow-position variance.
- Estimate: ~40% of the previously-bundled "CSub + CEffect variance"
  surface is now done.  The 60% remaining is row-mechanism (which also
  blocks CRow, so a shared CRow op-sem extension is the more efficient
  path).

### Stronger-parity status carried forward

Same caveat as the prior op-sem entries.  The two paths in fixtures
(EXEC vs DOCS) go through the same rule_T_* functions.  Independent re-
encoding of the rules by a separate agent (without seeing op_sem.lua)
is still owed before v5.0 is declared stable.  **Backlog item carries
forward — not closed by this extension.**

### Next entry point

Either:
1. CRow op-sem extension (the natural next; row mechanism is shared
   between CRow and CEffect's row-tails).
2. CImpl op-sem extension (needed for HOUnify residue provenance
   chaining + realistic gen-pass CHKT emission).
3. Begin gen-pass for the v5.0 minimal core (CEq / CSub / Construction-
   phase / CInst / CHKT all landed now — enough surface for a non-
   trivial fixture set against real Lua source).

---

## 2026-05-24 — Session: independent-encoding parity discharged

### Question entering session

Discharge the "stronger-parity status" backlog: build a second op-sem
interpreter (`op_sem_alt.lua`) transcribed independently from
`docs/typechecker-v5-operational-semantics.md` WITHOUT reading
`op_sem.lua`, then run both interpreters against the existing parity-
test fixtures and compare.

Backlog item carried through two op-sem entries; the agent who built
each cycle flagged it as owed.  Discharge condition: both interpreters
produce equal final substitutions, equal error sets, equal inert-set
sizes on every fixture — OR document divergences for orchestrator
adjudication.

### Methodology

1. Read only: spec doc, `lib/type/experiments/v5_perf/{types,subst,
   constraint,variance}.lua`, the parity test's fixture shapes (no
   rule bodies), and the public state/constraint-tag set advertised
   by `op_sem.lua`'s module-level signatures (function names + the
   `M.resolve` 7-line body, which contains no rule logic).
2. Build `lib/type/static-v5/op_sem_alt.lua` (~990 lines): all ~30
   labelled rules with the names from the doc's cross-reference table,
   plus dispatch helpers `step_ceq`/`step_csub`/`step_tset`/
   `step_mcall`/`step_chkt` and the solver loop.
3. Build `lib/type/static-v5/op_sem_independent_parity_test.lua`
   (~660 lines): 17 fixture variants spanning every constraint shape
   and rule family, each running both interpreters on identical
   constraint sequences and comparing.

### Verdict

**PASS** — no divergences across 17 fixtures, 85 assertions.

```
bin/cr test lib/type/static-v5/
  pass  lib/type/static-v5/op_sem_independent_parity_test.lua  (85 passed)
  pass  lib/type/static-v5/op_sem_parity_test.lua              (61 passed)
2 passed, 0 failed, 2 total  (146 assertions)
```

Fixtures exercised (all PASS, no divergence found):
1. CEq basic (T-CEq-Bind-L, T-CEq-UU)
2. Construction phase (T-CTOpen, T-CTSet-Open-Extend, T-CTSeal)
3. CMethodCall (T-CMCall-Open-Stuck, T-CMCall-Sealed-Field, wake)
4. setmetatable(nil) reject (T-CEq-Const)
5. let-poly CInst (T-CInst, repeated instantiation freshness)
6. multi-return scalar stand-in
7. empty constraint set (S-Quiesce trivial)
9. CHKT Reduce for Functor<Maybe> (T-CEq-Bind-L + T-CHKT-Reduce)
10. CHKT Miller pattern (T-CHKT-Miller, identity constructor)
11. HOUnify ambiguity (T-CHKT-Park + T-HOUnify-Stuck)
12. HOUnify head-rigidification wake (T-CHKT-Park + S-Wake-Head + T-CHKT-Reduce)
13. HOUnify never resolves (T-HOUnify-Stuck)
14. CSub-Arrow decomposition (contra-args + co-rets)
15a/b/c. CSub-App-Var dispatch (co / inv-default / refl fast path)
16a/b/c. CSub-Record-Width (width ok / missing field / invariant field)
17. Arrow contravariance reject (function-of-Dog </: function-of-Animal)
18. T-CSub-TVar routes to CEq

### Discrepancies found

**None.**  Both interpreters produced bit-for-bit identical (under
`types.equal`) tvar resolutions, equal error counts, equal error rule-
label multisets, and equal inert-set sizes at quiescence on every
fixture.

This is meaningful evidence that:
1. The spec doc's rule definitions are unambiguous enough that a
   second agent reading only the doc reproduces the executable form.
2. `op_sem.lua` correctly implements those rules (or implements the
   same misreading as the doc, which the doc-vs-impl parity test
   already catches).
3. No rule has silent disagreement with itself across the two paths.

### Lessons learned about the doc's rules

**Unambiguous (faithful transcription was mechanical):**
- T-CEq-* family: tag-driven, decomposition trivially yields the
  emitted constraints.
- T-CSub-Arrow contra/co orientation: doc gives explicit `CSub(B_i,
  A_i)` formula.
- T-CTOpen idempotency: doc's "If `?t` already has a binding, T-CTOpen
  is a no-op" is unambiguous.
- T-CMCall-Open-Stuck → T-CMCall-Sealed-Field wake-and-step cycle:
  S-Wake fires watchers, parked CMethodCall re-enters W with sealed
  phase visible, T-CMCall-Sealed-Field fires.

**Required interpretation (filled per the spec doc's surrounding
prose, NOT per peeking at op_sem.lua):**
- **Dispatch priority for CEq.**  Doc lists rules in order but
  doesn't formally give a dispatch tree.  Interpreted: UU before
  Bind-L/R, both before tag-equal decomposition, mismatch as fallback.
  This matches what the rule names imply and what the spec's "If `a =
  b`: discharged with no change" hints.
- **T-CSub priority** between Refl / TVar / Arrow / Record / App-Var /
  App-Struct / Union / Const / Mismatch.  Chose: TVar (uvar present)
  before Refl (types.equal), then union-side dispatch, then
  arrow/record/app/const, mismatch as fallback.  Doc doesn't formally
  enforce this; the soundness sketch is consistent with the priority
  but doesn't force it.
- **T-CTSet dispatch tree.**  Spec gives four rules (Open-Fresh,
  Open-Extend, Open-Equate, Sealed-Reject) keyed on phase and binding
  state; the dispatcher's `if/elseif` cascade was an obvious
  reconstruction.
- **T-CHKT-Reduce chain peel.**  Spec says "iter-instantiate(Lambda…
  Lambda body, args)" and notes the substrate's instantiate peels one
  binder at depth 0.  Implemented: walk down up to `length(args)`
  binders, peeling one per arg; emit CEq against `?result` with the
  remainder.  Matches op_sem (verified by parity).

**Areas where the spec doc has explicit gaps (per F12), confirmed not
to bite the test fixtures:**
- Restricted Miller fragment (UVar or Const args only) — covered.
- Kind inference / lambda-arity check — fixture 9 happens to have a
  matching arity.
- Eta-equivalence — no fixture exercises.
- Nested-lambda capture-avoiding abstraction — no fixture exercises.
- HOUnify residue provenance chaining — no fixture exercises.

### Cost

- Transcription time: ~45 min for op_sem_alt.lua (rules + dispatchers
  + solver loop), most of which was wrestling the v4 typechecker's
  narrowing/firewall behaviour (V5Type cast hints needed on every
  deref/walk call, nil-guard locals before passing array-indexed
  values to constraint constructors).  The typechecker hardening is a
  separate observation — op_sem.lua hits the same patterns and likely
  uses similar workarounds.
- Parity test: ~15 min (mostly repetitive fixture mirroring).
- "Wanted to peek" moments: 2.  Both resolved by re-reading the spec
  doc more carefully:
  1. Whether `bind_and_wake` should call both `wake` and `wake_head` —
     spec § "S-Wake-Head" implementation note states "every binding
     rule that extends σ now calls both `wake(?t)` (normal) AND, when
     the bound RHS has a rigid (non-uvar) head, `wake_head(?t)`".
     Implemented per that note.
  2. Whether T-CMCall-Open-Stuck should re-emit a CMethodCall
     constraint object into inert or some other shape.  Spec § "S-Park"
     hypothesis "blockers(C) = B" and the inert-set semantics make
     clear the original constraint (or an equivalent) is parked.
     Used `constraint_mod.method_call` to construct a fresh-id
     constraint for parking.

### Implications

The F2 "spec is runnable" check is now exercised at full strength.
A wrong rule in op_sem.lua would diverge from op_sem_alt.lua on at
least the fixture(s) exercising that rule, and the parity test would
fail with a specific "fixture N diverges; op_sem=X, op_sem_alt=Y"
message.

The stronger-parity caveat that has carried through every op-sem
entry since the original op-sem landed (~`#624` line in this log) is
hereby closed for the v5.0 minimal core.

### Open future work (NOT addressed by this session)

1. Re-run this independent-parity check when CRow / CEffect / CImpl
   extensions land.  Each adds new rule labels; each needs its own
   pair of fixtures + cross-interpreter assertions.
2. Property-based parity: generate random constraint sequences and
   run both interpreters.  Catches rule-priority order divergence
   that fixed fixtures miss.
3. Independent third interpretation by yet another agent, if
   skepticism remains that the two are correlated through shared
   reading of the doc.  Cost-benefit unclear at this point.

### Next entry point

Same as the prior entry: CRow op-sem extension, OR CImpl op-sem
extension, OR begin gen-pass for the v5.0 minimal core.  The op-sem
foundation is now corroborated by two independent encodings — a
stronger basis to build on.

---

## 2026-05-25 — Session close: comprehensive handoff written

Multi-session arc of typechecker v5 work paused for a natural stopping point. State and orientation snapshot lives in **`docs/typechecker-v5-handoff-2026-05-25.md`** — single navigable file capturing all nuance: artifacts + LOC, architecture in one paragraph, load-bearing invariants, falsifiability gates passed (with the "what this does NOT verify" caveats explicit), all 16 named spec gaps sourced and severity-ranked, backlog (pre-stable + post-stable), open H-questions (only H10 remains, not blocking), 5 cross-cutting risks, methodology rules established this session (F9–F14, G12–G13), and a next-session menu with prerequisites + cycle counts + recommended order.

Future session reads the handoff first; dives into this log for chronological detail.

Major outstanding work named in the handoff (not done this session, not silently dropped):
- High-severity spec gaps G7 (CMultiReturn), G8 (CRow narrowing), G12 (CEffect variance)
- Realistic-scale perf untested (10⁵ target vs <500 tested)
- Gen-pass connection to real Lua AST not started
- Substrate promotion from `experiments/` to `static-v5/` owed
- Cutover from legacy + v4 is the long tail
- 4 pre-stable backlog items: exhaustive session mining, missed-gen eval, circular require corpus check, catalog relocation

No silent decisions. No abandoned threads.

---

## 2026-05-25 — Constraints catalog landed in repo

### Question

Where does the v5 constraints catalog live durably?

### Evidence

- Catalog lived at `~/.claude/plans/radiant-gathering-gray.md` (outside repo); flagged as durability risk in the 2026-05-22 session open thread and again in the 2026-05-25 handoff (Option E, cycles <1).
- That on-disk file was overwritten in a later session with a 3,013-char handoff blurb, replacing the 16,643-char catalog. Confirmed durability risk was real.
- Full original content recovered from session JSONL transcript and re-saved verbatim to `docs/typechecker-v5-constraints.md` (16,643 chars, sections A–I intact).

### Decisions closed

- Constraints catalog now lives at `docs/typechecker-v5-constraints.md`. References in `TODO.md`, `docs/typechecker-v5-handoff-2026-05-25.md`, and this log updated to point at the in-repo path. Stale handoff blurb at `~/.claude/plans/radiant-gathering-gray.md` left in place (no longer authoritative).

### Decisions still open

- None opened by this entry.

### Tainted artifacts

- None.

### Next entry point

Unchanged — op-sem follow-ups per the prior session's next-entry list.

---

## 2026-05-25 — G7 dissolved: CMultiReturn replaced by positional Record on Arrow.ret

### Context and motivation

The prior session's handoff named G7 (CMultiReturn union-arity) as a high-severity spec gap requiring its own constraint family. When this session opened, the user questioned the design: "what the fuck is cmultireturn" — pointing out that a dedicated constraint family for multi-return was unnecessary if the type system already had positional Records. This was not a new insight: v4 had used positional Records as a workaround for multi-return (integers as field keys), but the choice was unprincipled there — it was structural accident, not a design decision. In v5, making it a design decision eliminates the CMultiReturn family entirely. No four-rule design, no new constraint form.

### What changed

**Representation pivot**: `Arrow.ret` was changed from `(Type list)` to `(Type)`. Multi-return `(A, B, C)` is now a single type: a positional Record `{1: A, 2: B, 3: C}`. This is not a wrapper — it is the type. There is no CMultiReturn constraint. The load-bearing rule is T-CSub-Record's positional-key dispatch, which was already in place (Phase 3, variance work).

**Covariant vs invariant**: positional Record keys (integer keys) are covariant because multi-return slots are caller-read-only — no write path exists. Named Record fields remain invariant because they are mutable (write soundness requires invariance for field types). This variance distinction is principled, not ad hoc: LSP / write-soundness is the load-bearing reason named fields are invariant; the absence of a write path for positional return slots is the load-bearing reason positional keys are covariant.

**Nil-padding**: over-arity calls discard trailing slots; under-arity calls nil-pad. Both are standard Record subtyping under covariant positional dispatch. The gen-pass invariant: over-arity discard must happen at constraint-emission time (before CSub emission), not inside the solver. Emitting a positional Record with extra keys and letting CSub discard them would be wrong — the solver sees a width mismatch as a potential error. This invariant was surfaced during Phase 4 and must be preserved when gen-pass work begins.

**Fixture 6 update**: fixture 6 was previously a scalar stand-in for multi-return (documented as such). It now uses a real positional Record and tests the full nil-pad shape.

### Five-phase landing

| Phase | Commit | Description |
|---|---|---|
| 1 — substrate | `2ce1e591` | Arrow.ret single type, multi-return as positional Record |
| 2 — op-sem | `07afc26a` | positional Record dispatch with covariant subtyping and nil-pad |
| 3 — collapse | `720a9f6c` | collapse Arrow rules to single ret recursion |
| 4 — fixtures | `c9e018b9` | fixture 6 uses real positional Record; add nil-pad fixtures |
| 5 — docs | this commit | dissolve G7 across handoff, log, constraints catalog, TODO.md |

### Assertion count delta

146 → 187 (+41 assertions). All pass. Both interpreters (`op_sem.lua`, `op_sem_alt.lua`) pass all 187.

### Invariant surfaced (track for gen-pass)

**Over-arity discard must happen before CSub emission.** When a call site returns more slots than the LHS expects, the positional Record emitted by gen-pass must contain only the expected slots. Emitting the full record and letting T-CSub-Record discard the surplus would give the solver a width mismatch on positional keys it cannot distinguish from a genuine type error. This is a gen-pass contract, not a solver fix.

### Decisions closed

- G7 (CMultiReturn, high-severity spec gap): dissolved. No new constraint family needed.

### Decisions still open

- G8 (CRow narrowing suppression), G12 (CEffect variance): still high-severity, unchanged.

### Next entry point

CRow + CEffect unified extension (G8 + G12) per Option A in the handoff next-session menu.

---

## 2026-05-26 — CRow + CIntersection-effects (closes G8 + G12 at op-sem layer)

### Context

Option A from the 2026-05-25 handoff next-session menu: "CRow + CEffect unified
extension — closes G8 + G12, largest unresolved family."

### Evidence and decisions

**Four commits this cycle (parity 187 → 275):**

| Phase | Commit | Description | Parity |
|---|---|---|---|
| Substrate | `05519c88` | Row variables, open records, TRowVar, TRecord.row, TIntersection in types.lua + subst.lua | — |
| CRow rules | `7f7d4d6c` | CRowExtend/Lacks/Close atoms + rules in both interpreters + fixtures 19-22 | 187 → 219 |
| Fixture 8 reinstated | `b1825484` | CRow narrowing suppression (Scenario A: quiescence error; Scenario B: close-then-pass) | 219 → 233 |
| Intersection + effects | `c600a446` | CIntersectionEq/Sub/Member + canonicalize + effect-type API via TConst with "!" prefix + fixtures 23-29 | 233 → 275 |

**G8 (CRow narrowing-suppression soundness floor): CLOSED at op-sem layer.**
CRowLacks parks while the row variable is unbound (open row). At quiescence, any
still-parked CRowLacks becomes an error: S-Quiesce-CRowLacks. This is the soundness
floor: assuming a field is absent on an unclosed row is unsound. CRowClose wakes
parked CRowLacks constraints; those that find the key absent succeed (Closed-Pass);
those that find the key present error (Closed-Fail). Verified by fixture 8
(two scenarios, both interpreters).

**G12 (effect variance discipline): CLOSED at op-sem layer.**
Effects are types (TConst with "!" prefix: !io, !throw, !yield, !os). No parallel
infrastructure is needed — effects compose via TIntersection. CSub decomposition
and conjunction rules handle variance uniformly (existing T-CSub machinery).
CIntersectionEq/Sub/Member with canonical form (flatten+sort+dedupe via
constraint.flatten_parts). F2 enforcement: CIntersectionMember stuck on an
unbound uvar at quiescence → error (S-Quiesce-CIntersectionMember).

**Source pipeline integration NOT done (explicit deferral).**
The op-sem now has correct rules for CRow and CIntersection. However, the source
pipeline — parser support for `&` intersection syntax and `!Name<Args>` effect
syntax, and gen-pass propagation of effects through function bodies — is NOT
implemented. v5 currently constructs these constraints via API in tests only.
Connecting the source pipeline is a separate 2-3 cycle effort. G8 and G12 are
closed at the spec/op-sem layer; they are NOT yet observable from user-written code.

### New gaps surfaced

**G17 (variadic generics):** Accurate typing of `pcall` and `coroutine.resume`
requires variadic generics (the function-argument pack and return-pack must be
typed through the pcall/resume boundary). The current v5.0 `pcall` returns
`(boolean, unknown)` per corpus convention. Full variadic generics is a separate
constraint-family design. Low-to-medium priority; not blocking v5.0 stable.

**v5-source-pipeline-integration (new gap):** Parser + gen-pass wiring for
`&` (intersection) and `!Name<Args>` (effects) must land before G8 + G12 are
observable from user code. Estimated 2-3 cycles. Not blocking op-sem stability.

### Perf re-gate

Harness: `lib/type/experiments/v5_perf/bench_chkt.lua`. The harness is correct
and produces output when invoked via `bin/ld-musl-x86_64.so.1 bin/luajit-bin -e
'...'` or direct LuaJIT. The `bin/cr run` dispatch does not call `M.main(arg)` —
file returns `M` but never invokes it; this is a known harness invocation quirk.
Perf entry recorded in `docs/perf/log.md` under 2026-05-26. All three gates PASS.
Step counts grew from 634/295 (prior CSub re-gate) to 768/343, reflecting the new
CRow + CIntersection dispatch paths. Margins remain >200× on wall, >10× on heap.

### Decisions closed

- **G8**: CRow narrowing-suppression soundness floor — CLOSED at op-sem layer.
  Not yet observable from user code (source pipeline not wired).
- **G12**: Effect variance discipline — CLOSED at op-sem layer. Effects as TConst
  ("!" prefix); intersection composes; no parallel infrastructure. Not yet observable
  from user code.

### Decisions still open

- **G17** (variadic generics): new gap, low-medium prio.
- **v5-source-pipeline-integration**: parser + gen-pass for effects/intersections.
- **G9** (bounded tvars), **G10** (variance under Lambda), **G11** (union backtracking):
  unchanged from prior cycle.
- **H10** (`any` escape hatch for community): still open, not blocking.

### Next entry point

1. v5-source-pipeline-integration: parser + gen-pass wiring for effects and
   intersections. Prerequisite for G8/G12 to be user-observable.
2. G17 (variadic generics) design — needs orchestrator decision before implementation.
3. Pre-stable follow-ups (D + mining) per the 2026-05-25 handoff Option D.
