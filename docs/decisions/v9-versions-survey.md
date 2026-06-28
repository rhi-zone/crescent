# v9 Typechecker — Prior-Versions Survey + Mining Analysis

Status: decision-input artifact. READ-ONLY survey; no code was changed producing
it. Purpose: decide **fresh-start vs salvage/mine** for v9 — the modular,
hotswappable Lua/LuaJIT typechecker built against the mechanized proof-dev
(`proof/*.v`) as its proven spec — and identify *specifically what to mine*.

The HARD requirement for v9 is **modularity via Dependency Inversion (DIP)**:
type representation, subtyping decider, narrowing, constraint/inference strategy,
parser/AST, and diagnostics each behind an interface so any implementation is
*replaceable*, not load-bearing. The user recalled "some earlier versions had
it." This survey checks that claim against the actual code.

Method: enumerated every version directory under `lib/type/`, sized each, counted
test corpora, inspected module boundaries and dependency-injection seams, and read
the history docs (postmortem, ad-hoc inventory, v7 first-principles, proof-kernel
increments 1–29). Evidence is cited by path. Where a modularity claim does not
hold up in the code, this says so.

## TL;DR

- **Recommendation: fresh architecture, mine assets — not code.** Build v9 fresh
  against the proof-dev's relation seams (`has_type` / `ssub` / `dsub` / `synth` /
  `check`). Lift the **test/fixture corpora** as the conformance goldmine, and
  **mine ideas** (v6's module split, v4's MLstruct subtyping core, v5's parity
  discipline, v7_mr0's certificate/replay model). No prior version is structured
  for DIP, so none is a salvage base.
- **The modularity claim is half-true.** No prior version has true DIP
  (interface-injected, hotswappable components). v6 has the cleanest *file/module
  boundaries* with pure `opts`-threaded functions; v4 has the only *factory* seam
  (`new_solver()`) and explicit driver/walker layering. Those are "modular by
  decomposition," not "modular by inversion." The distinction matters for v9.
- **The proof-dev already is the seam map.** `has_type` (declarative spec),
  `ssub`/`decide_ssub` (syntactic decider), `dsub`/`gdecide` (semantic decider),
  `synth`/`check` (bidirectional engine) are *exactly* the interfaces v9 should
  invert behind. The spec/engine seam is not something v9 must invent — it is
  already proven in Coq.

## STEP 1 — Versions discovered

All under `lib/type/` (total 119,827 Lua lines across the tree). Born-dates from
`git log --diff-filter=A`. The live default checker is `lib/type/static` (the
"v2/v3" lineage), dispatched by `bin/cr-check.lua` (v4/v5/v6 are opt-in via
`--v4/--v5/--v6`).

| Path | Born | Lua files | Lines | Test files | Role |
|------|------|-----------|-------|-----------|------|
| `lib/type/static` | 2026-02-26 | 54 | 53,077 | 11 + fuzz | **Live legacy checker** (v2/v3 lineage) |
| `lib/type/static-v4` | 2026-05-19 | 35 | 18,020 | 8 | Greenfield simple-sub / MLstruct rewrite |
| `lib/type/static-v5` | 2026-05-24 | 17 | 16,467 | 9 | Constraint + operational-semantics rewrite |
| `lib/type/static-v6` | 2026-05-31 | 22 | 3,250 | 8 | Clean modular prototype (records/packs/facts) |
| `lib/type/v7_mr0` | 2026-06-03 | 4 | 2,608 | 1 | Replay-only certificate verifier (MR0 slice) |
| `lib/type/framework` | — | 9 | 3,111 | 4 | **Rejected** theory-agnostic framework |
| `lib/type/experiments/v5_perf` | — | 9 | 2,485 | 1 | v5 perf experiment |
| `lib/type/analysis` | — | 44 | 19,381 | 11 | Corpus + analysis harness (16-file fixture corpus) |
| `lib/type/search` | — | 3 | 749 | 1 | (search experiment) |
| `proof/*.v` | — | — | ~1.9 MB `.v` | — | **Mechanized spec** (29 increments, Coq/Rocq) |

Supporting history docs read: `docs/typechecker-framework-postmortem.md`,
`docs/typechecker-ad-hoc-inventory.md`, `docs/typechecker-v7-first-principles.md`,
`docs/typechecker-framework-v7-mr0-audit.md`, `docs/proof-kernel.md`,
`docs/type-system-design/` (7 design notes), `docs/type-system.md`,
`docs/typechecker-reference.md`. (There is no `docs/decisions/throughlines.md`;
the CLAUDE.md pointer is stale — the throughlines content lives inline in the root
CLAUDE.md "Ecosystem Design Principles" section.)

## STEP 2 — Per-version assessment

### `lib/type/static` — the live legacy checker (v2/v3 lineage)

- **What it is.** The shipped typechecker (`bin/cr-check.lua` default,
  `lib/type/static/cli.lua`). Constraint-generation + solver architecture:
  `parse.lua`/`lex.lua` → `constrain.lua` (gen) → `solve.lua`/`solve2.lua` →
  `unify.lua`/`narrow.lua`/`match.lua`. Type representation in `types.lua` (interned
  tag-arena, `intern.lua`/`arena.lua`). Handles the largest Lua subset by far:
  records, unions/intersections, generics, rank-N (`forall`), HKT payloads, match
  types, FFI cdefs (`cdecl_*`, `cdef.lua`), metatables, multi-return, narrowing,
  stdlib declarations (`stdlib_types.lua`, `prelude*.lua`). Also carries lint-style
  `rules/` (dead_locals, naming, unannotated, predicate_return).
- **Modularity / DIP — POOR (monolithic, ctx-coupled).** `docs/typechecker-ad-hoc-inventory.md`
  catalogs **105+ ad-hoc instances**, dominated by **26 magic `ctx._foo` mutable
  fields (18 distinct) used as inter-phase message buses** — `_forall_bounds`,
  `_last_multi_return*`, `_var_origin`, `_hkt_payloads`, `_rank_n_call_counter`, etc.
  58 ad-hoc sites in `constrain.lua`, 42 in `solve.lua`. The gen/solve split is
  "enforced by convention, not mechanism." Handler dispatch is sequential if-elif on
  type tags, not table dispatch. No injected dependencies (grep for cap/dep/injected
  params in `lib/type/static`: none). This is the *opposite* of hotswappable.
- **Mineable assets — the CONFORMANCE CORPUS (highest-value asset in the repo).**
  ~3,263 assertion/test calls across 11 test files (`type_test.lua`,
  `type_complex_test.lua`, `type_soundness_test.lua`, `annotation_totality_test.lua`,
  `cdecl_test.lua`, `cdef_test.lua`, …) **plus a full property/fuzz harness**:
  `fuzz_alg.lua`, `fuzz_arb.lua`, `fuzz_eval.lua`, `fuzz_eval_arb.lua`,
  `fuzz_test.lua`. This is years of accumulated real-Lua acceptance/rejection cases —
  the single most valuable thing to carry forward, as spec-validation corpus for v9
  (re-expressed against v9's frontend, not lifted as code).
- **Slop / failure modes — the documented root cause of v1→v4 failure.** The 18 ctx
  side-channels ARE the ad-hoc accumulation the proof-dev exists to prevent
  (`docs/proof-kernel.md` §Decision). The inventory's own conclusion: "**Do not
  proceed with any of the five existing design docs** … the session's prior
  architectural work was misdirected." The constraint *record* (no tagged payloads)
  forced every cross-phase datum into mutable ctx. Carrying this code forward
  re-imports the rot.
- **Lessons.** Right: breadth of Lua coverage, the interned type arena, the test
  corpus, FFI cdef integration. Wrong: ctx-as-message-bus, if-elif tag dispatch,
  constraint record without typed payloads, soundness-by-remembered-test.

### `lib/type/static-v4` — greenfield simple-sub / MLstruct

- **What it is.** A from-scratch rewrite "derived from `docs/typechecker-rewrite-design.md`
  (itself derived from simple-sub and MLstruct)" (`lib/type/static-v4/README.md`).
  Phases 4a–4g: a real **algebraic subtyping core** — type rep + subtyping algorithm
  (`subtype.lua`, `types.lua`), equi-recursive μ types, indexed access `T[K]`,
  complement `~T` with **DNF-based emptiness checking** and the MLstruct negation
  rewrite, **match types as bidirectional pattern destructors** (`_` desugars to a
  real complement type, not a syntactic special case), **full rank-N polymorphism**
  with deep-skolemization + escape check (`forall.lua`), effects on arrows, and
  content-addressed cache primitives (`cache.lua`). Layered into `driver/` and
  `walker/` subdirs.
- **Modularity / DIP — MODERATE (the only factory seam).** `subtype.lua` exposes
  `M.new_solver()` — a stateful solver *instance* factory, the closest any version
  gets to an injectable component. `cache.lua` and `walker/require_resolve.lua` take
  injected dependencies as params (the only two files in any version that do). The
  driver/walker layering is a genuine boundary. But the solver is mutable/stateful
  (`add_lower`/`add_upper`/`link_vars`/`decompose` mutate `s`), and modules are
  statically `require`'d siblings — replaceable by editing requires, not by
  inversion. Modular by layering, not by DIP.
- **Mineable assets.** The **MLstruct subtyping engine is the strongest algorithmic
  asset** — DNF emptiness, complement, match-as-destructor, rank-N skolemization. This
  is exactly what the proof-dev's `gdecide` (emptiness-based, increment 6) and `ssub`
  (structural, increment 9) decide; v4's Lua is a candidate *reference* for the
  `dsub`/`gdecide` engine — **mine the algorithm, validate against the proof, do not
  lift verbatim**. ~550 test assertions. The `driver`/`walker` split is a reusable
  layering idea.
- **Slop / failure modes.** Stateful solver (the same mutable-coordination smell that
  sank legacy, in milder form). Effects-as-finite-atom-set on arrows is a
  pre-commitment the proof-dev revisits (increment-7 arrows are pure; effects staged).
- **Lessons.** Right: derive subtyping from a real theory (MLstruct), wildcard-as-real-
  complement, escape-checked rank-N. Wrong: stateful solver instances re-introduce
  coordination state; premature effect commitment.

### `lib/type/static-v5` — constraint + operational semantics

- **What it is.** Constraint-based (`constrain.lua`) with an explicit **operational
  semantics module** (`op_sem.lua`) and a SECOND independent implementation
  (`op_sem_alt.lua`). Annotation parsing (`ann.lua`), separated **error formatting**
  (`error_format.lua`), stdlib types, snapshot fixtures.
- **Modularity / DIP — MODERATE (parity-validated, separated diagnostics).** No DIP
  injection, but two notable seams: (1) **diagnostics are a separate module**
  (`error_format.lua` + test) — a clean cut v9 should keep; (2) **multiple
  implementations of one spec, cross-checked** — `op_sem.lua` vs `op_sem_alt.lua` with
  `op_sem_parity_test.lua` and `op_sem_independent_parity_test.lua` (fixtures
  F-B1..F-B10). That parity discipline is precisely the "multiple implementations +
  parity tests" the project mandates, and is the *behavioral* precursor to v9's
  "swap the engine, parity-test against the proof."
- **Mineable assets.** The **operational-semantics spec + parity-test harness** (the
  cross-implementation discipline), `error_format.lua` as a diagnostics seam, the
  `fixtures/` + `__snapshots__/` prose-only fixtures (`occurs_check`, `missing_method`,
  `not_a_record`, effect-rejection cases). ~466 assertions.
- **Slop / failure modes.** Still constraint-coordination-shaped; op-sem encoded in Lua
  rather than derived from a proven spec (the proof-dev now supplies that).
- **Lessons.** Right: separate diagnostics, dual-implementation parity. Wrong: hand-
  written op-sem with no proof backing (superseded by `proof/typing.v`).

### `lib/type/static-v6` — clean modular prototype (the closest to "had it")

- **What it is.** The youngest, smallest, cleanest pre-proof prototype (3,250 lines).
  `init.lua` exposes **ten named, separately-required modules**: `ann`, `types`,
  `normalize`, `packs`, `calls`, `source`, `subtype`, `diagnostics`, `facts`, `env`.
  Notably introduces a **`facts` / `facts_env`** module (flow facts as a first-class
  concept) and a **`packs`** module (value-list/pack adjustment, `pack_result`) —
  both of which are *exactly* the proof-dev's later distinctions (packs in increment
  22; facts/narrowing in increments 13/15).
- **Modularity / DIP — BEST file boundaries, but still not DIP.** `subtype.lua` is
  **pure `opts`-threaded functions** — `M.is_subtype(a, b, opts)`,
  `subtype_union_left/right(a,b,opts)`, `subtype_intersection_left/right`,
  `definitely_disjoint(a,b)` — **no ctx mutation, no message bus** (contrast legacy's
  26 ctx fields). This is the cleanest decomposition in the repo and the strongest
  basis for the user's "some versions had it." BUT: the ten modules are static sibling
  `require`s; nothing is injected behind an interface, so a part is swapped by editing
  the require, not by inversion. It is **modular-by-decomposition and side-effect-free,
  one refactor away from DIP** — but not DIP today.
- **Mineable assets.** The **module decomposition itself is the template for v9's seam
  map**: types / normalize / subtype / packs / facts / calls / diagnostics / env / ann
  / source maps almost 1:1 onto the proof-dev's relations. The pure-function,
  opts-threaded `subtype.lua` is a clean shape to lift the *style* from. The `facts`
  and `packs` modules are conceptually validated by the proof-dev.
- **Slop / failure modes.** Incomplete (~111 assertions, smallest corpus); never
  reached breadth. No constraint solver / inference of consequence.
- **Lessons.** Right: side-effect-free subtyping, named module boundaries, first-class
  facts and packs. The decomposition is correct; it just needs inversion added and the
  proof-dev as its spec.

### `lib/type/v7_mr0` — replay-only certificate verifier

- **What it is.** Not a checker — a **replay/acceptance verifier** for a minimal
  realizable slice (MR0). `canonical.lua` (content-addressed serialization),
  `fixtures.lua` (814 lines of adversarial fixtures), replay-only acceptance, explicit
  unsafe/trusted boundaries. Rules live as verifier functions (`validate_type`,
  `replay_wf`, `replay_sub`, `replay_pack_move`, `replay_call`).
- **Modularity / DIP — N/A (different shape).** It is a trusted replay kernel + an
  evidence model, not an inference pipeline. `docs/typechecker-framework-v7-mr0-audit.md`
  judges it "not a framework instance" because the theory is hardcoded Lua rather than
  a declarative `TheorySpec`.
- **Mineable assets.** **Canonical serialization + content-addressed terms/contexts/
  nodes, explicit roots, explicit unsafe boundaries, and the 814-line adversarial
  fixture style** — this is the closest existing code to the proof-dev's *certificate*
  model (the `synth`/`check` replay DAG, increments 8–10). If v9 emits proof
  certificates (recommended), v7_mr0's canonicalization and replay shape is the
  reference.
- **Slop / failure modes.** Theory hardcoded in trusted Lua side conditions — the audit
  flags this as the thing to *not* repeat (move rules into data the proof checks).
- **Lessons.** Right: certificates, content addressing, adversarial fixtures, visible
  trusted boundaries. Wrong: trusted hardcoded theory functions.

### `lib/type/framework` — REJECTED (prior art only)

- **What it is.** A theory-agnostic three-layer derivation checker (theory-agnostic
  evidence format + theory layer + frontends). Reached an STLC-capable binder-replay
  milestone with tests (`alpha.lua`, `replay.lua`, `shape.lua`, `canonical.lua`).
- **Status.** **Rejected** on judgment, not on a demonstrated defect
  (`docs/typechecker-framework-postmortem.md`): "not automatically the right
  architecture just because it is more general." It pre-committed to derivation DAGs +
  binder-aware replay as the universal shape before the substrate question was settled.
- **Mineable assets — three carry-forward *findings*, not code:** (1) **source binder
  names are never semantic identity** (use de Bruijn / lexical position — the proof-dev
  already does this in `typing.v`); (2) **capture-avoidance must be a checked condition,
  not assumed**; (3) **alpha-stable digests**; (4) **the trust discipline** — only the
  checker + declarative spec are trusted; solvers/frontends/inference are untrusted
  evidence producers ("the single most important finding to carry forward, because
  losing it is how ad-hoc accumulation re-enters").
- **Lessons.** The trust boundary is the structural defense against ad-hoc rot — v9 must
  keep it: the proof-dev's `has_type` is the trusted spec; v9's inference is an
  untrusted evidence producer whose output is checked.

## STEP 3 — The proof-dev (`proof/*.v`) as v9's spec

`docs/proof-kernel.md` documents **29 increments**, all `Qed`, `Print Assumptions`
= *closed under the global context* (no axioms, no `Admitted`, no `Classical`). The
chain compiles `subtype.v → typing.v → ssub.v → check.v`. This is not a toy: it
covers literals, records (width/depth/permutation), arrows (contra/co-variance),
unions, intersections, negation, Boolean-algebra laws (distributivity both
directions, De Morgan, complement), flow narrowing (truthiness increment 13,
type-test `type(x)=="T"` increment 15), references/mutation + store soundness
(16–19, M4), primitive operators (20), imperative statements + while (21),
ascription (21), multi-return (22), metatables + metamethods `__index`/`__newindex`/
`__call`/binary ops/`__concat`/`__unm`/`__len`/right-operand fallback (21–24), raw
`rawget`/`rawset` (25), varargs (26), multiple-assignment (27), numeric for (28),
generic for-in / iterator protocol (29) — each with **progress + preservation**.

**The seams v9 builds against are already proven relations** (this is the key
finding — v9 does not invent its abstraction; it implements proven ones):

| Proof relation (file) | What it is | v9 interface it becomes |
|------|------|------|
| `has_type : list BTy -> tm -> BTy -> Prop` (`typing.v`) | **Declarative typing spec** — the abstraction; non-syntax-directed (TSub fires anywhere) | The *specification* every v9 engine is checked against |
| `synth` / `check` (`check.v`) | **Bidirectional algorithmic engine**, proven `synth_sound` / `check_sound` vs `has_type`; `synth_principal` (least type) | The *inference strategy* interface — ONE proven engine; alternatives must be parity-checked against `has_type` |
| `ssub` / `decide_ssub` (`ssub.v`) | **Syntactic** subtyping decider, total + terminating, `decide_ssub_correct` sound+complete vs `ssub`, `ssub_sound` vs `dsub` | The *subtyping decider* interface (structural fragment) |
| `dsub` / `gdecide` (`subtype.v`) | **Semantic** (value-set) subtyping; `gdecide` three-valued emptiness-based decider, unconditionally sound | The *subtyping decider* interface (full Boolean fragment) — the `DUnknown` arm is where deferral is honest |
| `BTy` + `denote` (`subtype.v`) | **Type representation** (atoms/union/inter/neg/top/bot/rec/arrow/ref) + its value-set denotation | The *type representation* interface |
| `tm` de-Bruijn + `step` (`typing.v`) | **AST** + operational semantics | The *parser/AST* target (frontend lowers source → `tm`-shaped IR) |

Critically, the proof-dev **already demonstrates the spec/engine inversion**:
`has_type` is the spec, `synth`/`check` is *one* engine proven against it, and the
two subtyping deciders (`ssub` structural, `gdecide` semantic) are *interchangeable
backends* differing only in fragment/precision. That is DIP, mechanized. v9 mirrors
this: each Coq relation → one Lua interface, with the proof as the parity oracle.

The proof also hands v9 its **honest-deferral protocol**: `gdecide`'s three-valued
`DSub|DNotSub|DUnknown` (increment 6 CORRECTED) is the model for "never answer when
not proven" — the fix for legacy's fail-optimistic ad-hoc. v9's deciders should be
three-valued for the same reason: a definite answer is never wrong; uncertainty is
explicit, not papered over.

## STEP 4 — Synthesis & recommendation

### Fresh vs salvage — **fresh architecture, mine assets (hybrid, weighted toward fresh)**

Weighed against the two binding constraints — (a) DIP/hotswap modularity, (b)
proof-dev-as-spec:

- **Against salvaging legacy `static`:** its 105+ ad-hoc instances and 26 ctx
  message-bus fields ARE the documented rot the proof-dev exists to prevent. Its own
  inventory says do not build on the prior design. Salvaging it re-imports the failure
  mode. Reject as a base.
- **Against salvaging v4/v5/v6 as bases:** none has DIP. v6 is closest in *shape* but
  is incomplete (3.2k lines, 111 assertions) and still static-require-coupled; adopting
  it as a base means finishing a half-built checker whose seams aren't inverted anyway.
  v4's solver is stateful. None was built against the proof — their semantics are
  hand-derived and now superseded by `proof/typing.v`.
- **For fresh:** v9's spec (the proof-dev) did not exist when any prior version was
  written (`static` 2026-02, proof-dev increments are recent). The proven relations
  give v9 a *better* foundation than any prior code — and they already encode the
  inversion. Building fresh against `has_type` with proof-parity tests is the only path
  that satisfies both constraints simultaneously.
- **Why hybrid, not pure-fresh:** the **test/fixture corpora and several algorithms are
  genuinely valuable and proof-orthogonal.** Discarding ~3,200 legacy assertions + the
  fuzz harness + v5's parity fixtures + v7_mr0's adversarial corpus would throw away the
  single best spec-validation asset in the repo. Mine those.

**Verdict: fresh DIP architecture, with the proof-dev as the spec and parity oracle;
mine corpora as conformance suites and mine algorithms/ideas as references — lift no
version's pipeline code wholesale.**

### Specifically what to mine (ranked)

1. **Test & fixture corpora (HIGHEST — the spec-validation goldmine).**
   - `lib/type/static/` 11 test files, ~3,263 assertions + the fuzz harness
     (`fuzz_alg.lua`, `fuzz_arb.lua`, `fuzz_eval.lua`, `fuzz_eval_arb.lua`,
     `fuzz_test.lua`). Years of real-Lua accept/reject cases.
   - `lib/type/analysis/corpus/` — 16 curated fixtures (`fixture_boolean_narrowing`,
     `fixture_pairs_return_leak`, `fixture_coinductive_recursive_types`,
     `fixture_cross_module_type_alias`, `fixture_hamt_recursion`,
     `fixture_table_construction_widening`, `xmod/`, …) + `corpus.md`.
   - `lib/type/static-v5/fixtures/` + `__snapshots__/` prose-only diagnostic fixtures
     (`occurs_check`, `missing_method`, `not_a_record`, effect-rejection) and the
     `op_sem` parity fixtures (F-B1..F-B10).
   - `lib/type/v7_mr0/fixtures.lua` — 814 lines of adversarial replay fixtures.
   Re-express these against v9's frontend; partition into "must pass" (proven-sound
   constructs) and "currently `DUnknown`/deferred" buckets.

2. **MLstruct subtyping algorithm (HIGH — reference for the semantic decider).**
   `lib/type/static-v4/subtype.lua` + `empty.lua` + `forall.lua` + `match.lua`: DNF
   emptiness, complement, match-as-real-complement, rank-N skolemization + escape
   check. Reference implementation for v9's `dsub`/`gdecide` backend — validate against
   the proof, do not lift verbatim.

3. **v6 module decomposition (HIGH — the seam-map template).**
   `lib/type/static-v6/` (`init.lua` + the pure-`opts` `subtype.lua` + `facts`/`packs`/
   `normalize`/`diagnostics`/`env`). Lift the *decomposition and the side-effect-free
   subtyping style*, add inversion, retarget to the proof relations.

4. **Parity-test discipline + separated diagnostics (MEDIUM).**
   `lib/type/static-v5/op_sem_parity_test.lua`,
   `op_sem_independent_parity_test.lua`, `error_format.lua`. The cross-implementation
   parity harness is the runtime analog of proof-parity; `error_format` is the
   diagnostics-seam shape.

5. **Certificate/replay machinery (MEDIUM — if v9 emits certificates).**
   `lib/type/v7_mr0/canonical.lua` + the replay/content-address model, for emitting
   proof-checkable certificates matching the proof-dev's `synth`/`check` DAG.

6. **Framework carry-forward FINDINGS (cross-cutting, not code).** de-Bruijn binder
   identity, checked capture-avoidance, alpha-stable digests, and **the trust
   discipline** (spec trusted; inference untrusted evidence producer). Already
   reflected in `proof/typing.v`; keep them as v9 invariants.

### What to avoid (the rot — do not carry forward)

- **`ctx._foo` mutable message-bus fields** (legacy: 26 instances). The dominant
  documented failure. v9 carries cross-phase data in **typed payloads on the IR /
  certificate**, never mutable ctx.
- **if-elif-on-tag handler dispatch** (legacy: 21 carve-outs). Use table/relation-
  directed dispatch keyed to the proof's typed node families.
- **Constraint records without typed payloads** — the actual choke point per the
  inventory. v9's constraint/evidence schema must carry tagged payloads.
- **Stateful mutable solver instances** (v4) — coordination state is the milder form of
  the same disease.
- **Fail-optimistic deciders** — the increment-6 trap (`None` conflating "proven empty"
  with "deferred"). v9 deciders are three-valued; uncertainty is explicit.
- **Hardcoded theory in trusted Lua side conditions** (v7_mr0 audit) — rules live in
  data the proof checks, not in trusted procedural code.
- **Special-casing / name-keyed handlers** of any kind (root CLAUDE.md Hard
  Constraints) — the v1→v8 throughline.

### Proposed modular seam map for v9 (each behind a DIP interface)

Mirrors the proof-dev relations 1:1; every box is hotswappable, parity-checked against
its proof relation. (Modularity precedent column: which prior version, if any, had a
clean seam at this boundary — to mine the shape from.)

| Seam (interface) | Responsibility | Proof anchor | Mine shape from |
|------|------|------|------|
| **Type representation** | `BTy` constructors + denotation | `BTy`/`denote` (`subtype.v`) | v6 `types.lua`; legacy interned arena (`intern`/`arena`) |
| **Subtyping decider** | sub query → `DSub\|DNotSub\|DUnknown` | `ssub`/`decide_ssub` + `dsub`/`gdecide` | v4 MLstruct `subtype.lua`; v6 pure `is_subtype` |
| **Narrowing / facts** | flow facts over places; truthiness + type-test guards | increments 13/15; `facts` | v6 `facts.lua`/`facts_env` |
| **Inference strategy** | bidirectional `synth`/`check`; emit certificate | `synth`/`check` (`check.v`) | fresh (proof-anchored); v5 constraint gen as alt backend |
| **Constraint solver** (alt strategy) | constraint gen + solve, parity-checked vs `synth` | (engine variant of `has_type`) | v4 `new_solver` factory; v5 `constrain` |
| **Packs / value-lists** | call/return multivalue adjustment | increments 22/26/27; `packs` | v6 `packs.lua`/`pack_result` |
| **Parser / AST → IR** | source → de-Bruijn-style typed IR | `tm` + `step` (`typing.v`) | legacy `lex`/`parse`; lower to proof-shaped IR |
| **Diagnostics / reporting** | errors, snapshots, summaries | (outside the proof) | v5 `error_format.lua`; legacy `errors.lua` |
| **Certificates / replay** (optional) | emit + replay proof-checkable evidence | `synth`/`check` DAG | v7_mr0 `canonical.lua` |
| **Trusted boundaries** | FFI / declare / casts / target profile | v7 first-principles "trusted boundaries"; framework trust discipline | legacy `cdef`/`stdlib_types`; framework findings |

The two subtyping backends (`ssub` structural, `gdecide` semantic) are the concrete
proof that the **decider seam is genuinely hotswappable** — same interface, two proven
implementations, different fragment/precision. v9 should ship both behind one interface,
parity-tested, exactly as the proof carries both.

### Open design forks for v9 (genuine no-default choices to decide explicitly)

1. **Three-valued vs two-valued public API.** The proof's `gdecide` is `DSub|DNotSub|
   DUnknown`; `decide_ssub` is total `bool`. v9 must decide whether `DUnknown`
   surfaces to users (honest deferral) or is internally resolved by falling to the
   semantic backend. Recommendation lean: three-valued internally, with `DUnknown`
   from the structural decider triggering the semantic decider before any user-facing
   verdict.
2. **Single engine vs dual-engine parity from day one.** Ship only `synth`/`check`, or
   also a constraint-solver backend (mined from v4/v5) cross-checked against it? Parity
   cost vs the safety of two independent realizations (the project's own
   "multiple-implementations + parity" mandate argues for two).
3. **Certificate emission now vs later.** Emit proof-checkable certificates (v7_mr0
   shape) from the start — enabling external replay verification — or defer until the
   core checker is stable. Affects the IR/evidence schema design *now*, so decide early.
4. **Type representation: interned arena (legacy) vs immutable structural (v6/proof).**
   Performance (LuaJIT, hot-path allocation) vs cleanliness/hashability. The proof uses
   immutable structural `BTy`; legacy uses an interned tag-arena for speed. v9's
   `BTy`-interface lets both exist behind it, but the *default* is a real choice.
5. **Frontend IR shape: de-Bruijn (proof-faithful) vs named-with-resolved-binders.**
   The proof uses de-Bruijn (binder identity = position). A source-facing checker may
   prefer names + a resolution pass. Pick the lowering target the IR commits to.
6. **How far to track the proof's frontier.** The proof is at increment 29 (generic
   for) but several constructs are `DUnknown`/deferred (full connective subtyping in
   checking, intersection-narrowing, coupled negated records, non-`NoDup` projection).
   v9 must decide its initial "must-pass" fragment vs its honest-`DUnknown` fragment,
   and partition the mined corpora accordingly.

## Honesty note on the modularity claim

The user's recollection that "some earlier versions had it" is **partially borne out
but should not be over-trusted as a salvage signal**: v6 has the cleanest module
boundaries and the only side-effect-free subtyping; v4 has the only factory seam and a
real layering. Neither is DIP — nothing in any version is injected behind an interface
such that an implementation is swappable without editing requires. The genuine DIP
precedent in this repo is **the proof-dev itself** (`has_type` spec vs `synth`/`check`
engine vs the two interchangeable subtyping deciders). v9's modularity should be derived
from that proven inversion, with v6's decomposition and v4's algorithm as shape
references — not salvaged from a version that "already had it," because none fully did.
