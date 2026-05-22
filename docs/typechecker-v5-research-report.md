# Typechecker v5 — Research Report

Eight research agents fanned out on 2026-05-22 to characterise prior work, sibling-session history, and the published literature relevant to a sound type-system redesign. Each prompt was framed on its source ("describe X on its own terms"), not on a target hypothesis — per F12 (no pre-loaded subagent prompts) and F14 (no slacking).

This report consolidates findings. Each agent's section is preserved close-to-verbatim (agent-voice prefixes stripped). A synthesis section at the end identifies cross-cutting themes and explicit open questions for the user to close before mechanism work begins. Synthesis is marked as synthesis; findings are findings.

The eight tracks:

1. Prior crescent typechecker work — catalog of design docs, shipped/superseded/abandoned.
2. Prior Claude Code sessions — decisions made, forgotten, re-made.
3. Sound type systems for dynamic languages — Typed Lua, Pallene, Luau, Sorbet, TypeScript, Hack, mypy/Pyright/Pyre, Roc, Reticulated.
4. Constraint-based inference — HM, HM(X), OutsideIn(X), THIH, simple-sub, MLstruct, MLsub, Local TI.
5. HKT — Yallop/White, Haskell, Scala, GHC kind polymorphism, OCaml's refusal, TypeScript proposals.
6. Effect systems — Koka, Frank, Eff, Plotkin/Pretnar foundations, OCaml 5, Talpin-Jouvelot, row polymorphism, Lean/Idris, mtl/freer.
7. Linear / typestate / construction-phase — Strom-Yemini, Rust, Linear Haskell, session types, Mezzo, Pony, ATS, Idris 2 QTT, Java @Initialized, Granule.
8. Production-compiler solver architectures — GHC, OCaml, Chalk, MLstruct, Souffle, abstract interpretation worklists, TypeScript, Sorbet.

---

## 1. Prior crescent typechecker work — design-doc catalog

**Timeline (chronological order, classified Shipped/Superseded/Abandoned/Open):**

- `typechecker-v2.md` — **Shipped**. Foundation still in use. Data structures (flat-array AST, FFI arena, union-find), parser, type arena, `.cri` format all current. Inference algorithm (online unification) was replaced.
- `typechecker-v3.md` — **Shipped**. Constraint-based inference; `constrain.lua` + `solve.lua` replaced `infer.lua`. v2's data structures retained.
- `typechecker-hm-phase1.md` — **Shipped**. HM let-polymorphism Phase 1. Commits `5a9e1b4b`, `ccf96435`, `2ac9ab31`, `490ef49e`, `36e5f292`.
- `typechecker-hm-phase2.md` — **Shipped**. HM Phase 2 field-value-type propagation. Commits `772fb7dd`, `9260751e`, `391bde98`. `_forall_ops` records body constraints parameterized by free tvars; re-emitted per call site. Closes soundness gap H10 (fuzz invariant flip at `92f866b2`).
- `typechecker-variance.md` — **Demoted**. Audit found structural invariance, parameter contravariance, and skolem binding already prevent the claimed gap. Design committed but deprioritised as F6.
- `typechecker-v4-deferred-constraints-design.md` (K6f) — **Open**. Designed, not shipped. Deferred-constraint queue: TV-attached waiter lists, pending queue, `defer`/`wake`/`solve` API. Implementation blocked on commitment (commit `56fa9694` is stub only).
- `typechecker-v4-driver-design.md` — **Shipped, v4-specific**. K1–K3 implemented per design. `lib/type/static-v4/driver.lua` + `driver/decode.lua`.
- `typechecker-v4-stdlib-design.md` — **Shipped**. K3. `lib/type/static-v4/stdlib_types_v4.lua` built directly as V4Type Lua values.
- `typechecker-h2-correct-design-v1-superseded.md` — **Superseded** by v2. Proposed channel-separation; flawed because multi-return narrowing for `string.find` doesn't use the preserve-channel mechanism.
- `typechecker-h2-correct-design-v2.md` — **Superseded** by v3. Recommends (V) revert + (X) deferred instantiation, or (Y) type-level multi-return flow. Verdict: (X) is the right substrate long-term.
- `typechecker-h2-correct-design-v3.md` — **Open**. Phasing for (X) deferred instantiation. P2 (~300 LOC, one session), P3 (method calls), P4 (re-land H2).
- `typechecker-hkt-broader.md` — **Shipped, partial**. HKT H1, H3, H4, H5, H6 landed. H2 (record-of-generics) committed then reverted (`9f025732` revert, `213d8516` original). H2 awaits (X) before re-landing.
- `typechecker-rank-n.md` — **Shipped**. Rank-N polymorphism. Commits `289bc54d` (eager-pin HKT bounds), `a017b046` (call-site subsumption via skolem flags).
- `soundness-audit.md` — **Live document**. Gaps 1–11 catalogued. Gap 1 fixed 2026-03-15; Gaps 8/9/10/11 fixed; Gap 2 mitigated (implicit-any warning); Gap 3 demoted; Gap 4 verified acceptable; Gaps 5–7 deemed rare/acceptable.
- `typechecker-rewrite-design.md` — **Design for next substrate**. Closed set of constraints `{<:}`, deferred work as thunks, worklist architecture replacing 4-pass. Design phase for v5; not shipped.
- `typechecker-solver-fundamentals.md` — **Reference**. Solver invariants, passthrough in constraint returns. Active in v4.
- `typechecker-solver-architecture-v2.md` — **Shipped**. Commits `4eebb1de` (solve2 core), `c3f59312` (C_UNIFY/C_SUB), `f2686228` (C_BOUND/C_NARROW_NIL/C_ESCAPE_CHECK), `63c55f18` (TV ownership), `e2762912` (C_CALLABLE). Replaces 4-pass with worklist-to-quiescence. Passthrough emit-during-solve (`c26ed415`).
- `typechecker-solver-emit-during-solve.md` — **Shipped**. Constraint generation during solving.
- `typechecker-method-dispatch-audit.md` — **Shipped (legacy)**. K6e finding: legacy has `prim_index`/`prim_meta` registry (principled). v4 initial K6e missed this and shipped ad-hoc lookup; reverted in `4b3abbe4`.
- `typechecker-ad-hoc-inventory.md` — **Audit**. Lists ad-hoc dispatch sites. Spec criterion violated in 17+ places.
- `typechecker-parity-discovery.md` (K6) — **Shipped (read-only)**. Parity audit of v4 vs legacy across 783 files. 130 driver crashes, 153 v4-strict (deferred sub-phases), 473 detail divergences, 1 v4-lax. Driver structurally incomplete.
- `session-audit-2026-05-20.md` — **Audit/meta**. 42-hour session review naming P1–P5 failure patterns.

**Concept inventory** (every named D-/H-/K-/F-series concept with status):
- D6 (4-pass + deferral + waiters) — diagnosed as wrong, not yet replaced.
- D11 (gen-time mutable side-channels) — diagnosed as wrong, not yet replaced.
- D14 (implicit constraint provenance) — diagnosed as wrong, not yet replaced.
- B5/B7 — payload-as-data constraints (v5).
- A1 — soundness non-negotiable.
- K1–K3 shipped (driver, decoder, stdlib).
- K4 (--summary), K5/K5b (--v4, --compare CLI) shipped.
- K6 (parity discovery) read-only report shipped.
- K6a–K6e shipped; K6e re-done via `4b3abbe4` to use legacy `prim_index` pattern.
- K6f (deferred constraints) design only.
- K7 (cutover) not yet attempted.
- HKT H1/H3/H4/H5/H6 shipped; H2 reverted, awaits (X).
- HM Phase 1 shipped (all sub-phases); Phase 2 shipped (commits 1–6).

**Reverted work:**
- `9f025732` — H2 record-of-generics dispatch. Reason: regression (broke 9 multi-return correlated narrowing tests); root cause was instantiation timing implicit in callee-tag invariant. Resolution: (X) redesign pending.
- `13e6885f` — v4 disjunct-try backtracking. Recognized as temporary measure violating CLAUDE.md rule. Removed; rule added. Later K6e/K6f violates same rule (temporary deferred-TV logic).

**Open threads at last commit:**
- K6f (deferred-constraint queue) — designed, stub only.
- H2 re-landing — reverted, awaits (X) completion.
- v5 substrate selection — in discovery; H2/H4/H10 still open.
- Annotation-parser bridge to v4 (sub-phase J) — not implemented.
- Constraints catalog location — at `~/.claude/plans/...`, should migrate to repo.

**Documentation hygiene:**
- `typechecker-parity-discovery.md` (K6) is undated; should be prefaced "snapshot at commit XYZ."
- `typechecker-roadmap.md` is obsoleted by v5 decision to design-from-scratch; not yet marked stale.
- Methodology constraints F9–F14 added this session are *new rules*, not updates to CLAUDE.md (which has a 300-line soft cap). Canonical-source question unresolved.

---

## 2. Prior Claude Code sessions — multi-session decision arcs

**Arc 1: HM Subsumption as Foundation (sessions c0dbc248 → 86216d68 → df8a5d66)**
- c0dbc248 (May 9): HM accepted as foundational paradigm; Phase 1–3 work framed around HM constraint machinery.
- 86216d68 (May 18): User demands honest evaluation. Audit finds call-site subtyping check for `<T>` parameters is absent — the checker accepts any argument silently (N1: `(number)->number` passes when `<T>(T)->T` is required). Verdict: HM is not the right substrate.
- df8a5d66 (May 22, 88h): Operational semantics task redirected from "continue v4 walker" to "write the solver end-to-end from first principles." User: *"the architecture has always been the issue, right?"*
- **Status: In flux.** HM accepted implicitly, then explicitly rejected by audit, then K-phase continued building on HM machinery despite that verdict. df8a5d66 opens a reckoning, defers reconciliation.

**Arc 2: K6e Method Dispatch (sessions 4b24c1b4 → 86216d68 → df8a5d66)**
- 4b24c1b4 (May 16): K6e ships `env.bindings[recv.name]` dispatch in commit `a04ea8b5`. Report claims *"ad-hoc string-fallback rejected per CLAUDE.md no-ad-hoc-conditions."* Actual code violates the rule.
- 86216d68 (May 18): User: *"is there a reason to cop out?"* Agent admits the shape is unsound.
- df8a5d66 (May 22): Session audit explicitly flags K6e as "confidence overstatement." Commit `4b3abbe4` refactors using legacy's `prim_index`/`prim_meta` registry.
- **Status: Resolved** via refactor + audit documentation.

**Arc 3: 5 Handler Shapes as "Fundamental" (4b24c1b4 → df8a5d66)**
- May 16: Handoff certifies 5 shapes (pure-emit, sync-unify, backtracking, aggregation, mid-iteration-deferral) as fundamental without adversarial audit.
- May 22 Phase 1 audit: Shape 4 (union aggregation) is **accidental** — a new `C_DISTRIBUTE_OVER_UNION` constraint kind eliminates it. Shape 5 splits: 5a folds into Shape 1; 5b remains fundamental. Shapes 2/3/1 validated.
- **Status: Reversed via audit.** Pattern: prior session claims "fundamental" → current session audits → some claims fail → designs a replacement primitive.

**Arc 4: V4 vs V5 — Spec-First or Code-First? (df8a5d66 → a9ec0954)**
- df8a5d66 USER MSG 3: *"violating soundness is unacceptable, full stop."* Rejects K6f-vs-K6-reparity framing.
- Convergence on three-phase spec-writing: Phase 1 audit of shapes, Phase 2 op-sem, Phase 3 reconcile code to spec.
- a9ec0954 USER MSG 5: *"the #1 issue is you have repeatedly — in previous iterations — clearly (no offense) slacked off when designing so we've gotten actual straight garbage results."*
- **Status: In progress.** Strategic redirect from K-phase to spec-first; this v5 session.

**Arc 5: Judgment Rules vs Pattern-Based Rules in CLAUDE.md (84df5cc5 → df8a5d66)**
- May 14: Judgment rules accumulate in CLAUDE.md ("avoid reactive dispatch," "no ad-hoc anything").
- df8a5d66 USER MSG 9: Polish loop becomes reactive — 93 subagent dispatches across 85 turns.
- df8a5d66 Phase 1: Session audit names "Reactive sub-agent dispatch instead of thought" as Failure Pattern 3.
- TODO-typecheck.md line 620: *"The audit recommends not re-adding judgment-rules to CLAUDE.md from single corrections. Rules require repeated patterns across sessions."*
- **Status: Codified.** Meta-decision: judgment-rules-on-demand → pattern-requires-multi-session-evidence.

**Recurring user corrections (quoted, multi-session frequency):**
- *"violating soundness is unacceptable, full stop."* (df8a5d66) — soundness is the floor across all sessions.
- *"#2 i think. exploration on current type system INCLUDING design docs and then an honest initial overview"* (86216d68) — demand unfiltered honesty.
- *"the idea is that if you can't do it yourself then the whole point of agentic ai is kinda useless"* (df8a5d66) — reject delegation-as-hedge.
- *"every time you've handed me an architectural problem, I've substituted a tactical question and worked it to convergence."* (df8a5d66) — substitution pattern named explicitly.
- *"For any reimplementation, grep legacy first before claiming the v4 path is principled."* (TODO-typecheck.md) — pattern observed across sessions.

**Unwritten decisions (lost to transcripts only):**
- HM-fit audit verdict (df8a5d66): HM rejected as substrate. Cited in session audit but not in any persistent design doc.
- Three open questions for rank-N (df8a5d66 turn 13): skolem scope representation, `_forall_bounds` interaction, variance. Stated as design-doc future work, not binding constraints.
- Shift from "K6f implementation" to "spec-first redesign" (df8a5d66 USER MSG 3): recorded in handoff JSONL, not in a design doc.
- Phase 1/2 outcomes (df8a5d66): the spec exists, but binding constraints it imposes on Phase 3 are not extracted as a checklist.
- "Less judgment, more shape-rules" — only in session narrative, not in CLAUDE.md.

**Stuck loops:**
- **K6e → Polish → K6f**: K6e shipped with soundness issue (declared complete by deferring fix); polish loop refines spec narration but ships zero code; K6e–K6f overlap flagged but unresolved.
- **Phase 3 deferred pending spec audit** (df8a5d66 turns 44–58): polish loop finds spec internally inconsistent (*"the spec does not pass"*); rather than fix spec before Phase 3, both A3 and A2 deferred. Phase 3 never launches.

---

## 3. Sound type systems for dynamic languages — literature

**Typed Lua** (Maidl et al., Lua Workshop 2014; PhD 2015): Source-to-source. Union types, refinement via `is`/`as`, table types with field-level specificity, `any` for unannotated interop. Soundness model: authors disclaim formal soundness for novel features (open table types, projection types, typed/untyped boundary). Migration: file-by-file via `tlc`, with `any` flowing freely. Project largely dormant since ~2017.

**Pallene** (Gualandi & Ierusalimschy, SBLP 2018; SCP 2020): **Separate** statically-typed language compiled AOT to a Lua C module, sharing Lua's GC and value representation. Closed, monomorphic core: records, arrays, primitives, function types, nil-distinct from union. Lua/Pallene boundary inserts dynamic tag checks. Gives up: full unions, metatable polymorphism, ad-hoc table shapes — sacrifices nearly all idiomatic Lua dynamism. Point: C-competitive throughput for hot inner loops.

**Luau** (Roblox, 2021–present): Lua 5.1 fork. **Deliberately unsound** — Jeffrey (HATRA 2023) frames gradual typing as type-error *suppression*. Semantic subtyping: types interpreted as sets of values, subtyping as set inclusion. Non-strict mode optimises for false-positive minimisation. Local type inference, table refinement, intersections/unions via semantic subtyping, generics, type states for common Lua idioms. Telemetry shows ~100× more untyped than typed sessions in Roblox population.

**Sorbet** (Stripe, open-sourced 2019): C++ Ruby checker. Gradual with explicit `# typed:` sigils (ignore < false < true < strict < strong). **Hybrid static + runtime** — `sig` blocks insert runtime type checks at method boundaries, so `T.untyped` flowing into typed code fails loudly. `T.unsafe(x)` is explicit force-cast. `strong` is documented as nearly unusable. Migration: per-file sigils, RBI stubs, Tapioca autogeneration.

**Diamondback Ruby** (Furr et al., OOPSLA 2009) and **Hummingbird** (Ren & Foster, ECOOP 2016): DRuby inferred types via constraint generation; gave up on metaprogramming. Hummingbird's contribution: type signatures *gathered at runtime* as methods are created, then statically type-checked at first call. Soundness relies on re-checking when signature environment changes. Neither saw industrial uptake; both informed Sorbet.

**TypeScript --strict** (Microsoft, 2012–): Design non-goal #3 is "apply a sound or provably correct type system." `--strict` bundles strictNullChecks, strictFunctionTypes, strictBindCallApply, noImplicitAny, etc. **Openly-admitted unsoundness even in strict mode:**
1. Arrays are covariant in element type (despite mutation making them invariant).
2. Method parameters are bivariant even under strictFunctionTypes (only non-method function-type parameters become contravariant — the exclusion exists so `Array<T>` etc remain useful).
3. `any` infects checking silently.
4. Type guards (user-defined `x is T`) are unchecked predicates.
5. `as` casts are unrestricted.
6. `Object.assign`, index signatures, optional properties admit holes.
7. Class field initialisation outside constructor escapes strictPropertyInitialization.

**Hack** (Meta, 2014–): PHP dialect on HHVM. Strict mode requires every name annotated. Shapes (structural records), generics with declaration-site variance, enums, async/await typing, refinements, type-constants on classes, **reified generics** (runtime-available type parameters). Aims for sound strict mode. GitHub issue #8287 documents holes around mutable inout parameters, object mutation, shape subtyping (width vs depth), bounded quantification. `dynamic` type (added 2020) is deliberately-unsound bridge.

**mypy --strict, Pyright, Pyre**: None claim soundness — Python typing is gradual, `Any` is explicit escape. PEP 484 says checkers MAY differ on edge cases. Shared gaps: `Any` contagious; `cast` unchecked; descriptors, `__getattr__`, decorators that change signatures, metaclasses, `**kwargs` all under-checked. Variance defaults differ (mypy invariant, Pyright stricter on protocol variance).

**Roc** (Feldman et al., 2019–): Strict eager pure-functional ML descendant. Claimed sound, with global HM-style inference extended with extensible records and tag unions. No annotations required anywhere. Row-polymorphic records, open/closed tag unions, abilities (typeclass-like), effects via platforms, lambda sets. **Deliberate sacrifices for decidable principal inference: no HKT and no arbitrary-rank polymorphism** — FAQ states explicitly either feature breaks decidable principal-type inference.

**Reticulated Python** (Vitousek & Siek, 2014–2019): Research vehicle. Distinguishing contribution: **transient gradual typing** — instead of higher-order proxies/contracts at typed/untyped boundaries, transient inserts cheap first-order tag checks at every use site of typed values. Proven sound in an open-world setting. Catch: transient soundness is weaker than guarded — guarantees type-*tag* correctness at observation points, not full structural conformance. Higher-order types only checked shallowly.

### Convergences
- **Boundary enforcement is the soundness lever.** Sorbet (runtime sig checks), Hack `dynamic` (HHVM enforcement), Reticulated (transient tag checks), Pallene (Lua/Pallene FFI boundary) all locate soundness at the typed/untyped frontier. Pure compile-time systems cannot recover guarantees once `any`/`untyped` flows in.
- **`any`-equivalent escape hatches are universal among gradual systems** and universally admitted as principal unsoundness. Only Roc (non-gradual) lacks one.
- **Mutable containers under subtyping** are a recurring gap.
- **Metaprogramming is universally hostile to static soundness.** Hummingbird's JIT type-checking is the most ambitious attempt; everyone else bans (Hack, Pallene), demands stubs (Sorbet, mypy), or admits unsoundness.

### Divergences
- **Aspirational vs admitted soundness**: Hack-strict, Reticulated, Roc *aspire to* full soundness; Luau and TypeScript *deny it as a goal*. Sorbet, mypy/Pyright/Pyre, Typed Lua, Pallene sit between.
- **Semantic vs syntactic subtyping**: Luau is the only system in the set using set-theoretic semantic subtyping; rest use traditional syntactic.
- **Runtime story**: Sorbet, Reticulated, Hack-`dynamic`, Pallene-boundary emit runtime checks; TypeScript, Luau, mypy, Pyright, Pyre, Typed Lua erase fully at compile time.

---

## 4. Constraint-based inference literature

**Hindley-Milner / Algorithm W** (Damas-Milner POPL 1982): Equality constraints over first-order type terms. In original W, constraints not reified — solved on-the-fly via Robinson unification during a single recursive AST traversal. Pottier & Rémy (ATTAPL Ch. 10) split this into generation + solving phases: *"in the first stage, programs are translated to constraints such that the constraint is solvable iff the program is typable, and in the second stage, the constraint is solved without further reference to the program."* No subtyping; prenex polymorphism only.

**HM(X)** (Odersky, Sulzmann, Wehr, TAPOS 1999): Parameterised over a constraint domain X. Constraint language has `∃α.C`, conjunction, type schemes carry constraints: `∀α[C].τ`. Sulzmann-Stuckey later showed HM(X) type inference is CLP(X) solving — reduces inference to constraint-logic-programming over X. Discusses instances for polymorphic records, equational theories, and subtypes.

**OutsideIn(X)** (Vytiniotis, Peyton Jones, Schrijvers, Sulzmann, JFP 2011): Extends HM(X) with **implication constraints** `Q ⊃ C` carrying local *given* assumptions Q and *wanted* constraints C. Wanted/given distinction is fundamental. "Outside-in" solving: solve outer constraints first, never let inner givens influence outer solution. Honest admission: *"the constraint solver only accepts programs with principal types, even when the type system specification accepts programs that do not enjoy principal types."* Canonical statement of the price paid for tractability.

**THIH — Typing Haskell in Haskell** (Jones 1999/2000): Qualified types `P ⇒ τ` where P is a list of class predicates. Predicates are first-class data, not reified equality constraints — closer to a tagged constraint store. Operations: `reduce` (context reduction via entailment) and `split` to separate deferred vs retained predicates. Strongly-connected-component analysis for mutually recursive groups.

**simple-sub** (Parreaux ICFP 2020): Subtyping constraints `τ ≤ τ'`. Constraints **not reified** — immediately propagated into mutable variable bounds. Each tvar has (lower, upper) bounds. `constrain(τ ≤ τ')`: if one side is a variable, add the other to its appropriate bound and propagate to all bounds on the other side. A cache prevents infinite loops on cyclic constraints. Recursive propagation, not a worklist. Level-based generalisation (à la OCaml). Author admits: *"the most complex part of Simple-sub is actually its simplification algorithm."*

**MLstruct** (Parreaux & Chau OOPSLA 2022): Extends simple-sub to a **Boolean algebra** of structural types: conjunction, disjunction, negation, plus subtyped records, equirecursive types, class tags. First ML-style system combining unions/intersections with principal type inference. Backtracking-free — the BAS structure gives a normal form so the solver never undoes a choice.

**Algebraic Subtyping / MLsub** (Dolan PhD 2016, Distinguished Dissertation 2017): Subtyping `τ ≤ τ'` over a distributive type lattice. **Polar types** — input (negative) and output (positive) positions syntactically distinct, unions only positive, intersections only negative. **Biunification** — analogue of unification for subtyping; each variable carries lower and upper bound sets; bisubstitution refines both simultaneously. Types representable as automata; biunification implementable on automata. *"An open world of types is assumed, so that no typeable program becomes untypeable by the addition of new types."* Limitation: theory "very hard to approach for laymen" (Parreaux's reformulation motivation); type readability without simplification is poor.

**Local Type Inference** (Pierce & Turner, POPL 1998 / TOPLAS 2000): Deliberately *no* global constraints. Two local techniques: (1) **local type argument synthesis** at polymorphic applications, solving small local constraint set over type arguments only; (2) **bidirectional propagation** alternating synthesise/check modes. *"Missing annotations are recovered using only information from adjacent nodes in the syntax tree, without long-distance constraints such as unification variables."* Supports impredicative polymorphism in F<: precisely because inference is local.

### Cross-cutting observation: gen-time vs solve-time

Literature trajectory: **fused** (Algorithm W — generation = solving = unification, all during traversal) → **separated** (Pottier-Rémy HM(X) framework — emit a constraint, then solve) → **fused-with-mutation** (simple-sub, MLstruct — traverse and mutate variable bounds in place, no reified constraint store).

The honest separation phase (HM(X), OutsideIn(X)) made implication and scope explicit at the cost of larger intermediate constraint stores and a non-trivial solver. The Parreaux line argues — by demonstration — that for subtyping a fused mutation discipline plus a cache suffices, with simplification deferred to a post-pass. OutsideIn(X)'s explicit principality-over-completeness admission remains the most honest statement of the practical trade-off.

---

## 5. HKT literature

**Yallop & White, FLOPS 2014** — "Lightweight Higher-Kinded Polymorphism": Canonical defunctionalization-based encoding for languages without native HKT. Each type constructor `F` gets an opaque "brand"; a single binary type `('a, 'f) app` represents the suspended application `F<A>`. The brand acts as a tag; `inj`/`prj` newtype-wrap concrete `F<A>` into `(A, F_brand) app`. Inference fully ML-style — no new type-level machinery. Pain: every `F<A>` site needs explicit inj/prj round-trips; variance lost (`('a, 'f) app` is invariant); partial application requires a brand per arity; the "alias problem" — two type aliases `F = G` cannot share a brand without coherence breakage.

**Defunctionalization for type constructors** (Reynolds 1972 → modern): Reynolds' original defunctionalization replaced higher-order functions with first-order tags plus an `apply` function. Type-level analogue replaces type-constructor variables with brand tags plus a binary `App` type former. GHC's `Data.Singletons.Defun` mechanically defunctionalizes type-level functions — each n-ary function generates n+1 symbol tags and an `Apply` instance. Suspended call = tag, an empty data constructor.

**Haskell HKT + kind inference**: HKT since Haskell 1.0. Kind inference is monovariant: recursive datatypes inferred at their monomorphic kind unless given a CUSK (complete user-supplied kind). Augustsson-style kind inference uses unification over a simple kind grammar — first-order, decidable. Variance not declared (Haskell is non-subtyping).

**Scala HKT** (`F[_]`, Aux, Scala 3 type lambdas): Scala 2 supports HKT directly: `trait Functor[F[_]]` quantifies over a unary constructor. Partial application required type projections or kind-projector plugin. Scala 3 makes type lambdas first-class: `[A] =>> Either[E, A]`, with declaration-site variance (`[+A] =>> ...`). HKTs in Scala 3 are types upper-bounded by a type lambda — kind of a type is its bounds, unifying kinds with subtyping lattice. Inference incomplete for higher-order unification (third-order undecidable, Huet).

**GHC kind polymorphism** (Yorgey et al. POPL 2012): `PolyKinds` + `DataKinds`. Kind polymorphism lets `data Proxy (a :: k) = Proxy` quantify over all kinds. Inference: kinds inferred via first-order unification with kind variables. `*` defaulting dropped under PolyKinds.

**Constraint kinds in GHC** (Bolingbroke 2011): `ConstraintKinds` unifies types and constraints by giving constraints a kind `Constraint`. Constraint synonyms, constraint families, abstraction over constraints. Decidability: constraint solving with type families generally undecidable; GHC uses `UndecidableInstances` as escape.

**OCaml's lack of HKT — historical reasons**: (a) The module system already provides abstraction over type constructors via functors — Leroy's "Applicative Functors" (POPL 1995) covers most HKT use cases. (b) Adding HKT to a system with row polymorphism, polymorphic variants, GADTs, and the value restriction interacts badly with principality — OCaml team has refused features compromising principal inference. (c) Higher-order unification undecidable beyond Miller pattern fragment (Huet 1973). Workarounds: Yallop/White brands, first-class modules, modular implicits.

**TypeScript HKT proposals** — why none have landed: Issue #1213 open since 2014. Community uses two encodings: (a) **fp-ts URI** — `URItoKind<A>` interface that callers extend via declaration merging; (b) **hkt-toolbelt** — encodes type-level functions as interfaces with `Apply` member, fed by conditional types. PR #40368 attempted native; closed without merge. Stated obstacles: declaration-merging URI covers common case; full HKT requires tens of thousands of compiler lines changed; structural typing has no obvious lifting to constructor variables; TS inference is bidirectional + constraint-based with no backtracking — higher-order unification breaks invariants.

**MLstruct on HKT**: Published MLstruct paper does **not** address HKT directly. Algebraic subtyping bounds type variables by intersection/union constraints rather than equality — suggests a path for HKT under subtyping (bound a constructor variable by an intersection of constructor shapes) but not formally extended in print.

**Singletons / dependent encodings** (Eisenberg & Weirich, Haskell Symp. 2012): Promotes term-level functions to type families via Template Haskell. To avoid quantifying over type families directly (GHC type families not first-class), `singletons` defunctionalizes them: each type family `F :: a -> b` becomes a symbol `FSym0 :: a ~> b` plus `Apply` instance. "Suspended F<A>" = a tag of empty data declaration `data FSym0 :: a ~> b`, applied via `type family Apply (f :: a ~> b) (x :: a) :: b`. Cleanest type-level mirror of Reynolds.

### Cross-cutting answers

**Deferred instantiation / suspended `F<A>` data structure** — three patterns recur:
1. **Binary `App` type with brand tags** (Yallop/White, fp-ts, jane-street higher_kinded) — suspended call is a value of an abstract two-parameter type.
2. **Empty data tags + `Apply` type family** (singletons, hkt-toolbelt) — suspended call is a nullary data constructor at type level, reduced by an explicit `Apply` type family/conditional type.
3. **Type lambdas as syntactic objects** (Scala 3, System F-omega) — suspended call is a beta-redex held unreduced in the AST until weak-head-normalized during subtype checking.

(1) and (2) are defunctionalization; (3) is direct higher-order. (1)+(2) preserve first-order unification; (3) requires higher-order pattern unification (Miller, decidable in the pattern fragment; undecidable in general per Huet/Goldfarb).

**What goes wrong adding HKT post-hoc**:
- GHC: kind defaulting bugs, `Constraint`/`Type` confusion, role inference breakage every few releases.
- OCaml: refused entry because principal inference + module system cover the use case and interaction with row/polyvariants unclear.
- TypeScript: structural-subtyping has no obvious lifting to constructor variables; inference is unification-free and bidirectional — higher-order unification machinery foreign; declaration merging already provides "good enough" escape valve.

**Variance for type constructors**: Scala does this best in practice — declaration-site variance lifts naturally to type lambdas (`[+A] =>> F[A]`). Haskell punts (no subtyping). The Yallop/White encoding loses variance entirely (invariant `app`). Scala 3's type-interval theory (Hu & Lhoták) gives the most principled treatment.

---

## 6. Effect systems literature

**Koka** (Leijen, MSFP 2014 / POPL 2017 / 2021): Effects are **rows** of labels on Leijen's scoped-labels record system. `<exn, io | e>` is a sequence where duplicate labels are *allowed* and ordered. Inference: Hindley-Milner extended with row unification — Algorithm W with extra unifications swapping adjacent distinct labels. Effect rows attach to function arrows (`int -> <io> int`), not to values. Let-generalisation preserved by attaching row to arrow rather than result, so value restriction not needed. No full HKT, sidestepping worst impredicativity issues. Subtyping: no — effect subsumption encoded by row *polymorphism*.

**Frank** (Lindley, McBride, McLaughlin, POPL 2017): *Abilities* (sets of interfaces) on computation types `[E]A`. **No effect variables in source code** — effect polymorphism is implicit via an "ambient ability" propagated *inwards* through bidirectional checking, rather than accumulated outwards. Every function is a (possibly trivial) handler. Multihandlers handle commands from multiple computation arguments at once.

**Eff** (Bauer & Pretnar, 2010–2014): Effects as *sets* (called "dirt") of operation symbols decorating value types — closer to Talpin-Jouvelot. Constraint-based inference with **effect subtyping**. Pretnar (2014) gives a complete polymorphic effect inference algorithm for an ML-style core. Subtyping monotone on dirts (set inclusion); handlers shrink dirts (non-monotone at term level). Practical type *display* requires aggressive simplification.

**Algebraic Effects & Handlers — Foundations** (Plotkin, Power, Pretnar): Effects = equational theories of operations; the free model is the corresponding monad. A handler is a model; handling construct is the homomorphism. This is the substrate every system above sits on. Original formulation deep; shallow (Hillerström & Lindley 2018) is a derived variant.

**OCaml 5 Effect Handlers** (Sivaramakrishnan et al., PLDI 2021): **Untyped** in surface language — effects are runtime tags; OCaml type system does *not* track them. Pragmatic retrofit decision. Operations declared via extensible `_ Effect.t` GADT. Deep + shallow both provided. **One-shot** continuations enforced dynamically. Type soundness preserved precisely because effects erased from types — at cost of unhandled-effect errors being runtime failures.

**Polymorphic Effect Inference** (Talpin & Jouvelot, 1992): Foundational algorithm — Algorithm W extended with subeffect constraints. Crucial design rule: **let may generalise a type only when the bound expression is total (effect-free)**. Avoids unsoundness analogous to ML value restriction with references. Every later system inherits some version of "no generalisation under effects."

**Row Polymorphism for Effects** (Leijen 2005): Scoped-labels record calculus. Key choice: **allow duplicate labels** rather than carry a "lacks-l" predicate. Result: row equality is unitary modulo label-swap; unification has no constraint side-store. Cleanly HM.

**Lean 4 / Idris 2**: Lean 4 has no algebraic effect handlers — core team rejected because two known efficient encodings (open unions / monomorphisation) blow up either runtime or compile time, unacceptable for self-hosting bootstrap. Idris 2 keeps a library-level effects approach with dependent types in indices.

**mtl vs freer-simple** (Haskell library approach): mtl — monad transformer stack + type classes with functional dependencies; **static dispatch**, fast after specialisation, but transformer stack order observable and quadratic instances. freer-simple/extensible-effects/polysemy/fused-effects — effects = open union, computations = free(r) monad indexed by effect list; **dynamic dispatch** at effect-row level; ~30× slower without inlining. Library approaches limited by no *deep* control over the continuation.

### Cross-cutting themes

**Subtyping vs row polymorphism**. Two ways to make `caller: <io>` flow into `expects <io|net>`: (a) subtyping (Eff, Talpin-Jouvelot); (b) instantiate a row variable in the callee's polymorphic type to extend it (Koka, freer). Frank does neither — propagates caller's ability inwards via bidirectional checking. Subtyping more flexible but pushes inference into constraint-set territory; row polymorphism keeps unification unitary but forces all polymorphic functions to *quote* their row variables in source.

**Sound-but-incomplete vs sound-and-complete**. Most pragmatic systems are sound and incomplete. Bauer-Pretnar 2014 gives a complete algorithm for ML-with-subtyping core. Recent "Deciding not to Decide" (arXiv:2510.20532) claims sound and complete inference for higher-rank polymorphic functions by *deferring* effect resolution to points with sufficient information.

**HM let-generalisation pain points** — three recurring problems:
1. Generalising under non-trivial effect can be unsound (Talpin-Jouvelot "must be total" restriction).
2. Effect subtyping with polymorphism flirts with undecidability (Pierce, Lillibridge); systems restrict to row equality (Koka) or accept incompleteness and pay in simplification (Eff).
3. Open rows interact with principal types — duplicate-labels design picks unitary unification at cost of unfamiliar row equality; predicate-based systems (lacks-l) restore familiar set semantics but need qualified types.

**HKT interaction**. None of the surveyed languages combines first-class HKT *and* a full row-polymorphic effect system *and* HM inference. Haskell has HKT but library-level effects. Koka has effect rows but limited HKT. Frank's bidirectional checking sidesteps the question. Current evidence: requires either bidirectional annotations or "decide not to decide" deferral.

---

## 7. Linear / typestate / construction-phase literature

**Typestate** (Strom & Yemini 1986; Aldrich/Sunshine/Saini 2009): Tracks abstract state of a value refining its nominal type. Operations annotated with pre/post-typestates; checker propagates state forward, rejects programs invoking an operation in the wrong state. Original NIL system: `uninit ⊑ partial ⊑ init` for initialisation degree. Strom-Yemini assumed no aliasing — sound only for unique references. Plaid (OOPSLA 2009, FTfJP 2010) restores soundness under aliasing via *access permissions* (unique/shared/immutable/pure) combined with state.

**Rust borrow checker (NLL, two-phase borrows)**: Tracks ownership, exclusive/shared borrows, lifetimes. Affine type discipline + region inference / dataflow on MIR. NLL replaced lexical scopes with CFG-based liveness. Two-phase borrows split `&mut` into reservation (read-only, may coexist with shared) and activation (at first write) — makes `v.push(v.len())` typecheck. Rust doesn't model "partially initialized" structurally; `MaybeUninit` or builders simulate dynamically.

**Linear Haskell** (Bernardy et al. POPL 2018): Multiplicity on the *arrow* (`A %1 -> B` vs `A %ω -> B`), not the type. Multiplicities form a semiring. Multiplicity polymorphism lets one definition serve both linear and unrestricted callers. Linear = "consumed exactly once" in WHNF sense — values can be aliased internally as long as function consumes argument linearly. Paper's headline example *is* safe mutable arrays built linearly then frozen: `newArray :: ... -> (Array %1 -> Ur b) -> b`.

**Affine types**: "Use at most once" — weakening allowed, contraction forbidden. Rust's ownership is essentially affine.

**Session types** (Honda 1993; Honda-Yoshida-Carbone): Linear types over communication channel endpoints whose type evolves with each send/receive. Multiparty via global type projected onto local types. Structurally identical to typestate but for channels.

**Mezzo** (Pottier & Protzenko, ICFP 2013): *Permissions* — propositions about program state, distinct from types. A permission `x @ list int` is duplicable (immutable) or affine (mutable/unique). Permission `r @ Record { f: τ_old }` is rewritten by `r.f <- v` to `r @ Record { f: τ_new }` — the *type* of a field can change during construction. **Gradual initialization is a Mezzo headline example.**

**Pony reference capabilities** (Clebsch et al. AGERE 2015): Six capabilities (iso, trn, ref, val, box, tag) form a subcapability lattice. `consume` moves an iso/trn; `recover` blocks build an iso/val from temporarily-elevated capability inside. Canonical "build then freeze" idiom: `recover val ... end` — construct mutably inside, recover as immutable on exit.

**ATS** (Xi, FoSSaCS 2003+): Dependent indices + linear resource types ("viewtypes"). Linear views describe stateful resources; dependent indices express sizes, bounds, state machines. Uninitialised cell has view `T?`; assignment changes view to `T`.

**Idris 2 Quantitative Type Theory** (Atkey LICS 2018; Brady ECOOP 2021): Quantity `0/1/ω` on every binder. `0` = erased, `1` = linear, `ω` = unrestricted. Types live at quantity 0 — dependent types compose cleanly with linearity.

**Java Checker Framework — initialization** (`@Initialized`, `@UnderInitialization`, etc.): Hierarchy `@UnknownInitialization ⊐ @UnderInitialization ⊐ @Initialized`. Nullness Checker uses **freedom-before-commitment** (Fähndrich & Leino, OOPSLA 2003): inside a constructor, `this` has `@UnderInitialization` type; `@NonNull` fields may temporarily be null; only after constructor finishes is the object "committed" to `@Initialized`. Field of declared type `@NonNull T` reads as `@Nullable T` when accessed through `@UnderInitialization` receiver, writes require `@NonNull`. Once committed, field is `@NonNull` on both read and write.

**Granule** (Orchard et al. ICFP 2019): Linear use augmented with *grades* — semiring-indexed modalities `□_r A` meaning "an A usable with grade r." Grades can be natural numbers (use counts), intervals, security levels, sensitivities.

### Special focus: `local t = {}; t.x = 1; t.y = 2; setmetatable(t, mt); return t`

The pattern: allocate empty table → mutate fields → seal (via `setmetatable`) → return as a sealed value. Smallest sound extension distinguishing under-construction from sealed?

**Diagnosis per system:**

- **Strom-Yemini typestate** is essentially designed for this. Three states: `empty ⊑ {x:int} ⊑ {x:int,y:int} ⊑ sealed(T)`. Each assignment is a typed transition; `setmetatable` is the transition into sealed state. Soundness requires no aliasing of `t` during construction — which the textbook `local t = {}; ...; return t` pattern satisfies. **This is the minimal model.**
- **Plaid / access permissions** add explicit `unique` permission to recover soundness if `t` is passed to a helper during construction.
- **Rust as-is** rejects the pattern at the field level (no incremental struct construction except via struct literal). Closest analog: `MaybeUninit<T>` + `assume_init()` — runtime-trivial but the type-level seal is discharged by an `unsafe fn` the programmer must guarantee.
- **Linear Haskell** models it cleanly: `newTable :: (Table %1 -> Ur Sealed) -> Sealed`; each `setField :: Table %1 -> Key -> V -> Table` returns a fresh linear handle; `seal :: Table %1 -> MT -> Ur Sealed` consumes the handle. Sound and inferable but requires CPS/linear-state plumbing.
- **Affine alone** is insufficient: tracks aliasing but not field-set evolution. Must compose with typestate.
- **Mezzo** is arguably the *most natural* fit. Permission `t @ Table { x: missing }` rewrites to `t @ Table { x: int; y: missing }` to `t @ Table { x: int; y: int }`, then `setmetatable` transforms permission to `t @ Sealed(T)`. **No separate typestate concept needed — permissions over mutable records subsume the construction phase.**
- **Pony** maps the pattern to `recover val ... end`: build inside `recover` as `ref`/`trn`, exit gives `val`. Seal moment is `recover` block boundary.
- **ATS** uses views: `t @ Table?` → `t @ Table{x=int}` → ... → `t @ Sealed(T)`. Equivalent power to Mezzo, heavier annotation.
- **Idris 2 QTT** can carry the table at quantity 1 and use a dependent index for the field set. Sound and dependent but overkill.
- **Checker Framework** is the closest production-grade analog already deployed. Freedom-before-commitment is the same idea in OO clothing.

**Smallest extension that suffices for the Lua snippet, assuming no aliasing during construction:** a typestate lattice on table values with two binary distinctions — `open` vs `sealed`, and a row of currently-assigned keys — plus a flow-sensitive checker over local variables. Concretely:

1. `{}` produces `Table[open, fields={}]`.
2. `t.k = v` (when `t : Table[open, fields=F]`) updates to `Table[open, fields=F ∪ {k:typeof(v)}]`.
3. `setmetatable(t, mt)` (when `t : Table[open, fields=F]`) produces `Sealed<T>` where `T` is the structural type with row `F` and metatable `mt`.
4. Any escape of `t` (assignment to another variable, capture by closure, store into another table, pass to a function not annotated to accept `open`) requires `t` to already be `Sealed`.

Strom-Yemini typestate restricted to "unique local table" — a single boolean (`open`/`sealed`) plus a row that grows monotonically, no aliasing required because escape is forbidden in the open state. Checker Framework's freedom-before-commitment is the same idea in OO clothing.

---

## 8. Production-compiler solver architectures

**GHC** (OutsideIn(X) + inert-set solver): Worklist + *inert set*. Pop wanted/given, canonicalize (decomposes, reorients), interact with inert set; new constraints feed back. Implications nested: simple wanteds solved first, then implication constraints recursively. Quiescence: empty worklist with no implications generating new ones. Termination: measure-decreasing canonicalisation + strict rewriting discipline (givens rewrite givens/wanteds/derived; wanteds do NOT rewrite givens). Type-family reduction gated by `-freduction-depth` (default 200) — explicit fuel/retry budget. Centralised in `TcSMonad`: `InertSet` + worklist; **kick-out** when new equality is added, dependent inerts evicted back to worklist. Constraints carry `EvVar`/coercion witness. Post-hoc: GHC removed *Derived* constraints around 9.4 — three-flavor design simplified to two.

**OCaml** (Rémy levels + ref unification): **No worklist**. Syntax-directed and eager. Generalisation delayed to `let`-binding boundaries; **level tracking subsumes dependency reasoning a worklist would otherwise need**. Single union-find graph of mutable tvars carrying integer levels. Unification updates `min(level_a, level_b)` on shared roots. One bottom-up pass per expression; occurs-check ensures termination. **Levels do double duty for (a) generalisation scope, (b) escape detection of locally-declared types, (c) MLF rank tracking, (d) module-level type escape.** Kiselyov highlights this as the elegance — one mechanism subsumes several that would otherwise be ad-hoc.

**Chalk (Rust trait solver)**: Two solvers developed. (1) Recursive — depth-first goal decomposition with stack-based cycle table. (2) **SLG solver** (PR #59, Matsakis 2017): *table* per canonical subgoal; *strands* are partial derivations yielding answers incrementally. On-demand SLG (PR #77) made it lazy. Per-table: strand either produces an answer, blocks on another table (re-awakened when that table grows), or fails. **SLG with overflow** — every goal carries a size bound (instantiation depth); exceeding it produces "no answer" (sound but incomplete) rather than diverging. Forest of tables, each with answer set, waiting strands, dependency edges. Coinductive cycles succeed-by-assumption: cycle back to coinductive goal is "delayed," discharged at root if all other paths succeed.

**MLstruct** (Parreaux): Constraint-generation followed by bounded type variables — each tvar has explicit lower-/upper-bound sets. Subtype constraints `S <: T` propagated through bound graph. Memoisation on `(S, T)` plus finite type term structure bounds the propagation graph. Side-effecting `lowerBounds`/`upperBounds` mutable fields + global subtype-constraint cache. Equirecursive types: cycles detected by hash-consing/cache hits, folded into mu-types at simplification stage.

**Souffle Datalog**: Stratified semi-naïve evaluation. Rules partitioned into strata by topological sort of predicate dependency graph (with negation/aggregation as stratification barrier); within a stratum a fixpoint is computed via semi-naïve iteration where only the *delta* of newly-derived tuples drives the next round. Per-stratum quiescence: iteration that derives no new tuples ends fixpoint. **Stratification guarantees termination over finite domains; for infinite domains the programmer is responsible. No "fuel" — semi-naïve is a structural argument.** SCCs of predicate dependency graph form strata.

**Abstract Interpretation worklists** (Cousot, Nielson, Bourdoncle): Two traditions. (1) Worklist (Kildall, Wegbreit) — maintain set of dirty nodes; pop, apply transfer function, push successors if value changed. (2) **WTO** (Bourdoncle 1993) — precompute weak topological ordering of CFG identifying SCCs and a hierarchy; iteration follows WTO recursively, applying **widening** at designated heads. Replaces dynamic worklist with static traversal schedule. **Widening is precisely the canonical "retry budget" of static analysis — a bounded-imprecision step taken to ensure convergence on infinite-height lattices.**

**TypeScript (checker.ts)**: **Demand-driven**. No global worklist; types computed lazily by getter functions memoised into `resolvedType` field. Each entry point checks `resolvingFlag` sentinel for re-entry. Diagnostics deferred via `deferredDiagnosticsCallbacks` arrays evaluated after primary checking. Termination: **patchwork of fuel/depth budgets** — `instantiationDepth`, `instantiationCount`, `currentNode` stack limits, conditional-type resolution depth, type-alias circularity counters. Exceeding any → TS2589 "Type instantiation is excessively deep and possibly infinite." Side-channels everywhere: `links` maps on symbols/nodes, intersection/union cache tables, relation cache. **No single store. TS is the archetype of accreted scheduling.**

**Sorbet** (Stripe): Phase pipeline: Namer → Resolver → CFG-builder → Inference. Inference itself is **forward-only over the CFG**: each basic block visited once in reverse postorder; environments joined at merge points. **Single pass; no fixpoint loop.** Deliberate, documented choice. Per-block `Environment`, with `mergeWith` and `computePins` for joins. **Forward-only design pushes burden onto users: loop-carried type changes that would require a second pass instead produce `IncompatibleAssignment` errors and demand a `T.let` annotation.** Sorbet's docs explain this as explicit complexity/perf trade-off: a fixpointing inference would be "a slower algorithm." Multi-threading: each file's inference independent; Sorbet parallelises across files at phase boundaries.

### Cross-cutting observations

**Single vs multiple scheduling mechanisms:**
- **Single, by design**: OCaml (levels + union-find), Souffle (semi-naïve + stratification), Sorbet (forward CFG pass), WTO-based AI.
- **Single, by reduction to logic**: Chalk-SLG (one tabling mechanism subsumes both inductive and coinductive solving via delayed subgoals).
- **Multiple, accreted**: TypeScript (lazy memo + deferred diagnostics + per-feature depth limits + narrowing caches), GHC (worklist + inert kick-out + implication nesting + type-family reduction stack — share a monadic substrate but distinguishable).

**Retry-budget systems and motivation:**
- GHC `-freduction-depth` — open type families can loop.
- Chalk SLG overflow — designed in from start because Rust's trait system permits programs whose decidability is unknown.
- TypeScript `instantiationDepth`/TS2589 — added reactively; conditional+mapped types are Turing-complete.
- Abstract interpretation widening — fundamental; infinite-height lattices have no other termination story.

**Documented "wrong choices":**
- GHC's *Derived* constraints removed; fundeps still considered architecturally awkward.
- Chalk's original recursive solver superseded by SLG — incompleteness and inability to handle coinduction cleanly.
- Sorbet's forward-only inference documented as known limitation.
- TypeScript's per-feature limits acknowledged scattershot in checker.ts comments; #38737 documentation issue open precisely because global picture is undocumented.

---

## 9. Synthesis — cross-cutting themes

This section IS synthesis (marked explicitly). It collects patterns across the eight tracks. It does NOT make v5 design decisions.

### 9.1 Three patterns for "deferred work" in solvers

1. **Worklist + monotone facts** (Souffle, ascent-interpreter, abstract interpretation, GHC's inert-set in its constraint-monotone subset). Quiescence is decidable from worklist emptiness. Termination by monotonicity over a finite lattice (or stratified for non-monotone extensions).
2. **Levels / scope-indexed unification** (OCaml). No worklist; a per-tvar level integer subsumes the dependency reasoning a worklist would otherwise need. Single mechanism doing multiple jobs.
3. **Tabling / memoisation with delayed answers** (Chalk SLG, MLstruct cache, TypeScript memo). Each subgoal yields answers incrementally; cycles handled by delay tokens; quiescence is per-table.

D6 (4-pass + deferral + waiters) is none of these — it's an accretion of three mechanisms that don't compose. Replacing it requires picking one of the three patterns above and committing.

### 9.2 Two patterns for "data on the constraint" (B5/B7)

1. **Reified constraints with full payload** (HM(X), OutsideIn(X), Souffle facts, Chalk goals). The constraint object carries everything needed to solve it; the solver is a function of the constraint and the store.
2. **Mutable bounds on type variables** (simple-sub, MLstruct, Algorithm W in its imperative form). Constraints are not reified — they immediately update tvar bound sets via recursion + cache. The "data" lives in the tvars themselves.

These are not exclusive. simple-sub/MLstruct prove that for subtyping, mutation + cache scales. But provenance tracking and implication nesting (D14, OutsideIn's wanted/given) push toward reified constraints because the metadata has nowhere else to live.

### 9.3 Provenance (D14) — the literature is mostly silent

OutsideIn(X) tracks given vs wanted as a flavour bit; GHC's `CtEvidence` carries an evidence term. MLstruct has `TypeProvenance` tagging source location and origin role. Most other systems have no first-class provenance — errors are reconstructed from positions on tvars (OCaml) or from CFG structure post-hoc (abstract interpretation, Sorbet).

The crescent diagnosis (D14 "implicit constraint provenance") names a gap the published literature mostly does not address. GHC's wanted/given distinction is the closest analog, and it's there for a different reason (local-assumption scoping under GADTs and type families). Importing wanted/given to crescent would solve the declared-vs-inferred race even though it wasn't designed for that purpose.

### 9.4 Sound model for setmetatable-post-construction (H4)

The literature gives a clear answer:

**Smallest sufficient extension** = Strom-Yemini typestate restricted to unique local tables. A single `open`/`sealed` bit plus a monotonically-growing field row, with escape (assignment to another variable, capture by closure, store into another table, pass to a function not annotated to accept `open`) forbidden in the open state.

Mezzo permissions and Java's freedom-before-commitment are the production-grade analogs. Linear Haskell models it with arrow multiplicities. Rust's `MaybeUninit` simulates it dynamically. The shape is well-understood; the question for v5 is whether the typestate extension stays within the type system or is a separate pluggable checker (like CheckerFramework on Java).

### 9.5 HKT — defunctionalisation is the standard answer

Three patterns: binary `App` + brand tags (Yallop/White, fp-ts), empty data tags + `Apply` family (singletons), or direct type lambdas (Scala 3, F-omega). Scala 3 makes type lambdas first-class — most expressive. Yallop/White is most portable — works in any HM core. fp-ts shows the pattern adapts to a TS-like structural-subtyping core.

OCaml's refusal of HKT is informative: even teams with strong soundness culture have weighed the trade and chosen "module functors + brands" over native HKT. Whether v5's HKT (per H1) is direct or defunctionalised is an implementation choice; both can be sound; the literature does not clearly favour one. The crescent docs (`typechecker-hkt-broader.md`) suggest the direct path is partially implemented.

### 9.6 Effects — Koka's row + arrow-attachment is the proven pattern for HM

Row polymorphism on the arrow type avoids ML's value restriction without giving up generalisation. Frank's bidirectional approach also works but requires more annotation at function boundaries. Eff's set-based subtyping is more elegant but requires constraint-set solving and inferred-type simplification.

The crescent question (H2 — effects in scope for v5?) is governed by whether the user wants to pay the inference complexity cost. Koka's implementation is the proof-by-existence that HM + effect rows + handlers + sound generalisation is buildable. None of the three combine with full HKT in a published system — that's an open research question relevant to crescent given H1 already chose HKT.

### 9.7 Sound type systems for dynamic languages — recurring soundness landmines

Universal across all surveyed systems:
- `any`/`untyped` escape hatch — admitted unsoundness everywhere except Roc (which gives up gradual entirely).
- Mutable containers under subtyping — covariant arrays in TypeScript, shape subtyping holes in Hack, generic variance issues in Sorbet.
- Metaprogramming — banned (Hack, Pallene), stubbed (Sorbet/Tapioca, mypy/.pyi), or admitted unsound (Luau, TypeScript).
- Method dispatch on dynamically-changing receiver shape — universally hard; Sorbet's runtime sigs catch some, transient gradual typing (Reticulated) gets the rest cheaply.

For crescent: A1 (soundness non-negotiable) puts us in Roc's camp, not gradual. The cost is what Roc gave up — no HKT, no rank-N. Since H1 puts HKT in scope and `typechecker-rank-n.md` shipped, v5 explicitly exceeds Roc's chosen scope. The systems that combine sound HKT/rank-N with practical inference are Haskell (with annotations on higher-rank), Scala 3 (with structural subtyping plus interval-bounded kinds), and the academic line MLsub/MLstruct (subtyping + principal inference, no HKT in published form).

### 9.8 Methodology lessons specifically applicable

The session-history mining (track 2) and the production-compiler track (8) converge:
- **Multiple coexisting scheduling mechanisms grow by accretion** (TypeScript is the warning example). Each individual retry-budget or memoisation cache is locally justified. The global picture is undocumented and ungraspable.
- **Specifying a single mechanism up-front and refusing accretion is a design choice** that Sorbet, Souffle, OCaml, and Chalk-SLG all made consciously. Each accepts a known limitation (no fixpoint in Sorbet; user-handled non-monotone in Souffle; pattern-fragment higher-order unification in OCaml).
- **The grep-legacy-first rule has direct production analog**: GHC removed Derived after years; Chalk replaced its recursive solver after years. Both removals were preceded by audits showing the older mechanism was carrying unprincipled cases.

---

## 10. Open questions for the user before mechanism work begins

These are the v5 decisions that the research illuminates but does not close. Each must be settled — by the user, with a log entry under F11 — before any operational-semantics writing begins.

1. **H2: Effects in scope for v5?** Research shows Koka-style row+arrow gets you most of the way with HM-compatible inference, but no published system combines it with HKT (already in scope per H1) and full soundness. Including effects is a research bet, not engineering.
2. **H4: Sound model for setmetatable-post-construction.** Research recommends Strom-Yemini typestate restricted to unique local tables — concrete shape sketched in §9.4. Question for user: accept that shape, or examine Mezzo permissions / Linear Haskell arrows / Java freedom-before-commitment as alternatives.
3. **H10 (new): `any` escape hatch for community release.** Research shows every gradual system without one loses adoption. But every gradual system *with* one ships unsoundness. The literature does not resolve this; it's a project-positioning question.
4. **Substrate decision implied by §9.2.** Reified constraints (HM(X)-style) or mutable bounds (simple-sub style)? Each has soundness story; they imply different mechanism designs. The OutsideIn(X) line shows reified + scoped givens is the only known route to sound rank-N + GADTs simultaneously. simple-sub/MLstruct show mutation + cache is faster and simpler when subtyping but no rank-N.
5. **Scheduler choice implied by §9.1.** Worklist (Souffle-style) vs Levels (OCaml-style) vs Tabling (Chalk-SLG-style). All three are single-mechanism; D6 was three mechanisms. The crescent v5 constraints (B1, B2) name worklist-to-quiescence specifically, but Levels would also satisfy those constraints with a different elegance budget.
6. **Constraint vs solver responsibility for HKT (§9.5).** Direct type lambdas (Scala 3) require higher-order unification machinery in the solver. Defunctionalisation (Yallop/White) keeps the solver first-order at the cost of inj/prj ceremony. The crescent docs suggest the direct path is partially implemented; whether to continue it is an implementation choice.

---

## 11. Gaps and caveats

- Web research had API 529 overloads through much of this session; some agents took 3+ retries to complete. Specific PDF content (Yallop/White, Yorgey et al., Leroy 1995, Hu & Lhoták, Bauer/Pretnar) was reconstructed from search abstracts + standing knowledge — not always primary-source verified. Treat per-paper claims as citation-anchored summaries, not direct paraphrase.
- "Affect" (POPL 2025, affine effect system) and Bach Poulsen's higher-order effects framework appeared in search but were not deeply surveyed.
- MLstruct on HKT specifically — research turned up no formal extension. The synthesis suggestion (algebraic-subtyping bounds for constructor variables) is the agent's reading of the related work, not a published result.
- Lean 4 coverage shallow; only the design-rejection rationale.
- The session-history mining is bounded to the sessions in `~/.claude/projects/-home-me-git-rhizone-crescent/*.jsonl`; older context (pre-March 2026) was not accessible.

## 12. References (consolidated)

Sound type systems: Maidl 2014 Lua Workshop; Gualandi & Ierusalimschy SBLP 2018; Jeffrey HATRA 2021/2023; sorbet.org; Furr et al. OOPSLA 2009; Ren & Foster ECOOP 2016; TS 2.6 release notes + checker.ts; hacklang.org; PEP 484; roc-lang.org/faq; Vitousek & Siek arXiv 1610.08476.

Constraint inference: Damas & Milner POPL 1982; Pottier & Rémy ATTAPL Ch.10; Odersky/Sulzmann/Wehr TAPOS 1999; Vytiniotis et al. JFP 2011; Jones THIH 2000; Parreaux ICFP 2020 (simple-sub); Parreaux & Chau OOPSLA 2022 (MLstruct); Dolan PhD 2016; Pierce & Turner TOPLAS 2000.

HKT: Yallop & White FLOPS 2014; Yorgey et al. POPL 2012; Bolingbroke ConstraintKinds; Eisenberg & Weirich Haskell Symp. 2012; Leroy POPL 1995; Hu & Lhoták arXiv 2107.01883; TS issue #1213; fp-ts; singletons library.

Effects: Leijen MSFP 2014 + POPL 2017; Lindley/McBride/McLaughlin POPL 2017 (Frank); Bauer & Pretnar JLAMP 2015; Pretnar LMCS 2014; Plotkin & Pretnar LMCS 2013; Sivaramakrishnan et al. PLDI 2021; Talpin & Jouvelot JFP 1992; Hillerström & Lindley TyDe 2016; Brady ICFP 2013; Kiselyov & Ishii Haskell 2015.

Linear/typestate: Strom & Yemini IEEE TSE 1986; Aldrich et al. OOPSLA 2009; Matsakis NLL RFC; Bernardy et al. POPL 2018; Honda CONCUR 1993; Honda/Yoshida/Carbone JACM 2016; Pottier & Protzenko ICFP 2013; Clebsch et al. AGERE 2015; Xi FoSSaCS 2003; Atkey LICS 2018; Brady ECOOP 2021; Fähndrich & Leino OOPSLA 2003; Orchard et al. ICFP 2019.

Solver architectures: Simon PJ et al. OutsideIn(X) JFP 2011; Kiselyov on OCaml levels; Saleil & Pottier PACMPL 2025; Matsakis Chalk blog series; Bourdoncle 1993; Cousot & Cousot POPL 1977; checker.ts source; Sorbet internals.md; Souffle docs + Sallinger 2019.

Crescent internal: `typechecker-v2.md`, `typechecker-v3.md`, `typechecker-hm-phase1.md`, `typechecker-hm-phase2.md`, `typechecker-hkt-broader.md`, `typechecker-rank-n.md`, `typechecker-variance.md`, `typechecker-h2-correct-design-v3.md`, `typechecker-v4-deferred-constraints-design.md`, `typechecker-v4-driver-design.md`, `typechecker-v4-stdlib-design.md`, `typechecker-rewrite-design.md`, `typechecker-solver-architecture-v2.md`, `typechecker-solver-emit-during-solve.md`, `typechecker-method-dispatch-audit.md`, `typechecker-ad-hoc-inventory.md`, `typechecker-parity-discovery.md`, `soundness-audit.md`, `session-audit-2026-05-20.md`, `typechecker-roadmap.md`, `TODO-typecheck.md`.

Sibling sessions: `~/.claude/projects/-home-me-git-rhizone-crescent/{4b24c1b4,86216d68,84df5cc5,c0dbc248,df8a5d66,a9ec0954}.jsonl`.
