# Typechecker version history — v1 through the current parked state

Status: documentation/reconstruction artifact, not a new decision. CLAUDE.md's
Hard Constraint says "Ad-hoc accumulation is the documented root cause of
v1→v4 typechecker failure; v5 exists to prevent it" but that lineage — and
everything after v5 — was never written down in one place. This document
reconstructs the full chain from git history (all branches/tags),
`docs/decisions/`, `docs/typechecker-*.md`, `docs/artifacts/`, and session
transcripts, citing a commit hash, file path, or exact quote for every claim.
Where the record is silent or ambiguous, that is stated plainly rather than
filled in.

A session transcript (`normalize` search, session `8a4ca3b3`, 2026-07-21)
shows a user asking exactly the question this document answers, without
getting a resolved answer in-thread:

> "wait — v2? CLAUDE.md talks about v5 and a v1→v4 failure lineage, but
> `lib/type/` has `static/`, `static-v4/`, `static-v5/`, `v9/`. none of those
> say v2. which directory is the current typechecker?"

That confusion is the reason this document exists.

## Caveat on the "v1" framing

The CLAUDE.md line was added in commit `fe277ad3` / `f7725f2b` (2026-05-29,
same content on two branches), whose full commit body reads:

> "Ad-hoc accumulation is the documented root cause of v1->v4 typechecker
> failure; v5 exists to prevent it, yet the newest v5 code accumulated
> name-keyed special-casing because no rule forbade it."

There is **no directory or doc literally named "v1."** The numbering only
becomes explicit starting at v2. Based on `docs/typechecker-v3.md`'s own
words ("v2 kept the inference algorithm from v1"), v1 = the original
online-unification typechecker that preceded the documented
`docs/typechecker-v2.md` rewrite. No dedicated design doc, directory, or
commit range for v1 itself was found — it appears to be the pre-v2 baseline,
referred to only retrospectively.

**Gap:** no primary source separately documents what v1 looked like beyond
"online unification, order-dependent typevar binding" (implied by v3's
critique of it).

## v1 — original online-unification checker (undocumented directly)

- **What it was** (inferred from v3's description, not a v1-specific doc):
  an Algorithm W-style checker that "binds type variables immediately as the
  AST is walked" (`docs/typechecker-v3.md`, "Why v3"). This makes inference
  order-dependent — a generic function's first call site permanently pins
  its type variables to that call's literal types, so later,
  differently-typed-but-compatible calls fail.
- **Why superseded:** `docs/typechecker-v3.md` (lines 5-7): "v2 kept the
  inference algorithm from v1 (online unification) while rebuilding the data
  structures... The data structures are correct and stay. The inference
  algorithm is not." v1's *data structures* were rejected first (→ v2), its
  *inference algorithm* was rejected second (→ v3).
- **Gap:** no dedicated v1 document found; born-date unknown (predates the
  earliest crescent commits found, `ab41ad99` "feat: scaffold crescent").

## v2 — Performance-First Redesign

`docs/typechecker-v2.md`, commit `3722f970`, 2026-03-02.

- **What it was:** a rebuild of the *data structures* only — flat-array AST,
  FFI arena allocation, integer type tags, union-find — while retaining v1's
  online-unification inference algorithm. Explicit design goals: cold-start
  perf competitive with tsgo, sub-100ms incremental checks, 1M+ LOC scale,
  unifying typechecker + linter + dead-code-elimination in one pass.
- **Why superseded:** a header note added to `docs/typechecker-v2.md` itself
  points forward: "the specific tag numbers and the inference algorithm have
  evolved significantly... see `docs/typechecker-v3.md` (constraint-based
  solver that replaced the original online unification described here)."
  The concrete failure mode is documented with a code example in v3.md: an
  unannotated function `v(maj,min,pat)` called first with literal `0,0` args
  gets its type variables permanently bound to `LIT_INTEGER(0)`; a second
  call with a `number` argument then fails — "the first call site wins."
- **What carried forward** (explicit in v3.md, "What stays from v2"):
  flat-array AST, FFI arena, integer node types, lexer/parser/annotation
  parser, type arena, union-find, all type tag constructors,
  prelude/stdlib_types, `.cri` cache format, `errors.lua`/`check.lua`/
  `cli.lua`/`lsp.lua`.

## v3 — Constraint-Based Inference

`docs/typechecker-v3.md`, commit `e3573545`, 2026-03-16.

- **What it was:** split generation from solving — `constrain.lua` walks the
  AST emitting typed constraints (`Unify`, `Sub`, `HasField`, `Callable`,
  `Arith`, `IsReturn`) without binding anything; `solve.lua` then finds a
  most-general unifier across all constraints at once, enabling correct
  let-polymorphism/generalization.
- **Status:** per `docs/decisions/v9-versions-survey.md`, this became the
  long-lived "live legacy checker" — `lib/type/static/` is explicitly called
  "the v2/v3 lineage" (born 2026-02-26, 54 files, 53,077 lines, 11 test
  files + fuzz harness), and it is *still the operational, commit-gating
  typechecker* per `docs/roadmap.md` / `docs/roadmap-v2.md`: "The legacy
  typechecker (`lib/type/static/`, v2/v3 lineage, 53K lines) is the working
  tool and gates all commits."
- **Why it eventually needed replacing** — documented in
  `docs/typechecker-ad-hoc-inventory.md`, the source of the actual mechanism
  behind "ad-hoc accumulation is the documented root cause." An exhaustive
  inventory of `lib/type/static/` found **"105+ ad-hoc instances"**,
  dominated by **"26 magic `ctx._foo` mutable fields... used as inter-phase
  message buses"** (18 distinct fields: `_forall_bounds`, `_hkt_payloads`,
  `_rank_n_call_counter`, etc.), concentrated in `constrain.lua` (58
  instances) and `solve.lua` (42 instances). Root-cause conclusion (quoted):
  "The constraint record is the actual choke point, not the solver... Every
  ctx field is a constraint payload field that wasn't put in the constraint
  because the record doesn't support tagged payloads." Recommendation
  (quoted): **"Do not proceed with any of the five existing [contemporaneous]
  architecture design docs"** — they targeted subtyping/solver-scheduling,
  missing the real problem (constraint schema + ctx-mutation).

## v4 — Greenfield simple-sub / MLstruct rewrite

`lib/type/static-v4`, born 2026-05-19.

- **What it was:** per `docs/typechecker-rewrite-design.md` (commits
  `74dd271b`/`c698aab4`, 2026-05-19 — explicitly "not a description of any
  code currently in `lib/type/static/`... None of the existing
  implementation files were read"), a clean-room design derived from
  Parreaux's *simple-sub* (ICFP 2020) and its negation-aware extension
  *MLstruct* (Parreaux & Chau, OOPSLA 2022), plus Frisch/Castagna/Benzaken
  semantic subtyping. Built: a real algebraic subtyping core
  (`subtype.lua`), equi-recursive μ types, indexed access, complement types
  with DNF-based emptiness checking, match-as-real-complement, full rank-N
  polymorphism with escape-checked deep skolemization, and a
  `driver`/`walker` layer split. Driver + CLI design in
  `docs/typechecker-v4-driver-design.md` (2026-05-20).
- **Modularity assessment** (`docs/decisions/v9-versions-survey.md`): "the
  only factory seam" in any prior version (`M.new_solver()`), but the solver
  is stateful/mutable — "the same mutable-coordination smell that sank
  legacy, in milder form."
- **Why superseded** — two independent pieces of evidence:
  1. `docs/decisions/kernel-recommendation.md` (June 2026), on the
     algebraic-subtyping candidate: **"this well was drunk twice (V4Neg) and
     did not stabilize; v5 rejected v4 wholesale"** — and separately notes
     the algorithm's no-special-casing promise "was the v4 promise that
     failed by accumulation."
  2. The 2026-05-29 CLAUDE.md commit `fe277ad3` states flatly that v5
     "exists to prevent" the ad-hoc accumulation that killed the v1→v4
     lineage, i.e. v4 is named as the last failure point before the v5
     reset.
- **Gap:** no document states the *specific* technical trigger for
  abandoning v4 (vs. v3) beyond "did not stabilize" / the
  ad-hoc-accumulation framing — no v4-specific postmortem doc exists
  analogous to `typechecker-ad-hoc-inventory.md` (that inventory is scoped
  to legacy `static/`, not `static-v4`).

## v5 — Constraint + operational semantics rewrite

`lib/type/static-v5`, born 2026-05-24.

- **What it was:** constraint-based (`constrain.lua`) with an explicit
  operational-semantics module (`op_sem.lua`) *and* a second, independent
  implementation (`op_sem_alt.lua`) cross-checked via parity tests
  (`op_sem_parity_test.lua`, `op_sem_independent_parity_test.lua`, fixtures
  F-B1..F-B10) — the "multiple implementations + parity" discipline.
  Diagnostics split into a separate `error_format.lua` module. Design docs:
  `docs/typechecker-v5-discovery-tainted.md`, `-unframed.md`,
  `-research-report.md`, spec docs A/B/C (2026-05-22 through 2026-05-26).
- **Explicitly meant to prevent ad-hoc accumulation** — this is the version
  CLAUDE.md's Hard Constraint names as existing "to prevent" the v1→v4
  failure mode.
- **Its own failure of that goal, documented in real time:** the very
  commit that added the Hard Constraint (`fe277ad3`, 2026-05-29) states:
  **"yet the newest v5 code accumulated name-keyed special-casing because no
  rule forbade it."** v5 itself relapsed into the failure mode it was built
  to prevent, which is why the Hard Constraint had to be made an explicit,
  enforced rule rather than relying on design intent.
- **Ultimate status:** `docs/roadmap.md`/`docs/roadmap-v2.md` list v5 among
  the 8 replacement attempts that did not produce a viable successor to
  legacy `static/` (see Terminal status below); it is not cited as reaching
  cutover.
- **What carried forward** (`docs/decisions/v9-versions-survey.md`): the
  parity-test discipline and the separated-diagnostics module pattern were
  flagged as worth mining for v9.

## v6 — Clean modular prototype

`lib/type/static-v6`, born 2026-05-31.

- **What it was:** the youngest, smallest pre-proof prototype (3,250 lines).
  `init.lua` exposes ten separately-required modules (`ann`, `types`,
  `normalize`, `packs`, `calls`, `source`, `subtype`, `diagnostics`, `facts`,
  `env`). `subtype.lua` is pure, `opts`-threaded, side-effect-free — "no ctx
  mutation, no message bus" (contrast legacy's 26 ctx fields) — assessed in
  the v9 survey as **"the cleanest decomposition in the repo."** Introduced
  `facts`/`facts_env` (flow facts as first-class) and `packs` (value-list
  adjustment) modules ahead of the later mechanized proof-dev independently
  landing the same distinctions.
- **Why it stalled:** `docs/typechecker-v6-m2-blockers.md` shows M2 (broader
  statement support) was gated on unresolved policy questions
  (pack-adjustment fixtures, union-right call behavior, slot-claim
  assignment) that are still open in that doc's text — no
  resolution/closure commit found for these blockers. Per the v9 survey:
  "Incomplete (~111 assertions, smallest corpus); never reached breadth. No
  constraint solver / inference of consequence." It was not rejected on a
  stated defect so much as never finished before v7 work began (v7's first
  commit is 2026-06-02, one day after v6's last commits on 2026-06-01/06-02).
- **Gap:** no explicit "v6 is dead, here's why" document was found — its
  supersession by v7 is inferred from commit-date adjacency and v7's own
  status as "the current track" in contemporaneous docs, not from a stated
  rejection.

## v7 / v7_mr0 — Replay-only certificate verifier, MR0 slice

`lib/type/v7_mr0`, born 2026-06-03; design docs from 2026-06-02.

- **What it was:** not an inference pipeline but a trusted replay/acceptance
  verifier for a "minimal realizable slice" (MR0): content-addressed
  canonical serialization (`canonical.lua`), an 814-line adversarial fixture
  corpus (`fixtures.lua`), replay-only acceptance with explicit
  unsafe/trusted boundaries, and rule-verifier functions (`validate_type`,
  `replay_wf`, `replay_sub`, `replay_pack_move`, `replay_call`). Design docs
  span 2026-06-02 through 2026-06-05 (place-binder, pack-movement,
  metatable-lookup, operator-metamethod, generics-typelevel,
  certificate-schema design passes — 20+ docs in the git log).
- **Its own audit's verdict:** `docs/typechecker-framework-v7-mr0-audit.md`
  — quoted directly: **"v7 MR0 is not a framework instance."** The theory
  was hardcoded in trusted Lua side-conditions rather than expressed as a
  declarative theory spec, which the audit flags as the thing "to not
  repeat."
- **Why superseded:** `docs/typechecker-v7-roadmap.md`'s own final section,
  "Frozen Frontier," states directly: **"This was the active v7 frontier
  before the framework pivot. It is retained only as historical state for
  v7 prototype work, not as the current top-level queue... New active work
  starts at `docs/typechecker-framework.md`."** It also lists M9
  ("Mechanized Kernel," proving the kernel in a proof assistant) as
  "**Design blocked.**" v7 was not rejected on a demonstrated defect — it
  was actively superseded by a pivot to the theory-agnostic "framework"
  direction.
- **What carried forward:** per the v9 survey, "canonical serialization +
  content-addressed terms/contexts/nodes, explicit roots, explicit unsafe
  boundaries, and the 814-line adversarial fixture style" were flagged as
  reference material if v9 ever emits proof certificates.

## framework — theory-agnostic derivation checker

`lib/type/framework/`, no version number; the v7 pivot target.

- **What it was:** a three-layer design (`docs/typechecker-framework.md`,
  "Core Distinction"): a theory-agnostic derivation checker/evidence
  format, a theory layer (syntax classes/judgments/rules/oracles), and
  theory-specific frontends. Reached a documented, tested milestone: shape
  validation (`1cdb0d97`), first-order replay (`217cd2bc`), alpha
  normalization (`846949d7`), alpha-aware replay (`7b4934a8`), scoped
  pattern matching (`db28fb73`), binder-condition replay (`146cced9`),
  scope-carrying refactor (`8c2d5fa7`) — described in
  `docs/typechecker-framework-binder-replay.md` as "the first milestone
  capable of replaying STLC."
- **Why rejected — and the postmortem's most important finding:**
  `docs/typechecker-framework-postmortem.md` establishes, by direct
  citation, that **the rejection commit `f3966774` ("docs: mark framework
  as rejected static analysis direction") is purely documentary** — it
  changed no implementation file, cited no failing test, no
  un-expressible theory, and no demonstrated soundness defect. The
  postmortem's stated conclusion: **"the framework was rejected on
  judgment, not on a demonstrated defect."** The only quoted reasoning,
  from `docs/static-analysis-map.md`: *"not automatically the right
  architecture just because it is more general."* It had not even been run
  against its own planned validation theories (System F subset, nominal OO,
  structural flow, imperative state) — "The rejection preceded that stress
  test rather than resulting from it."
- **Lessons explicitly carried forward** (quoted from the postmortem):
  1. "Replay must never compare binder source names as semantic identity" —
     semantic binder identity is lexical position, independently re-derived
     later in the agnostic-analysis track.
  2. Capture-avoidance must be a *checked* condition (`cond_subst`), never
     assumed.
  3. Alpha-stable digests as an identity invariant.
  4. **"the trust discipline"** — only the framework checker + declarative
     theory spec are trusted; solvers/frontends/inference engines are
     untrusted evidence producers — called in the postmortem **"the single
     most important finding to carry forward, because losing it is how
     ad-hoc accumulation re-enters."**

## v9 — DIP-oriented, proof-anchored rewrite

- **Gap / naming note — "v8" is missing.** No "v8" typechecker directory,
  design doc, or commit was found anywhere in git history or docs
  (`grep -rln "\bv8\b" docs/*.md` returns only unrelated hits —
  `native-tiers.md` and an incidental `v8` string in
  `typechecker-rewrite-design.md`). The version numbering jumps from
  v7/framework directly to v9. No document explains the skip; this is an
  open gap.
- **What it was:** designed against a newly-completed **mechanized proof
  development** (`proof/*.v`, Coq/Rocq, 29 increments, all `Qed`, closed
  under global context — no axioms/`Admitted`) as its trusted spec.
  `docs/decisions/v9-versions-survey.md` — a read-only decision-input
  survey, done before any v9 code was written — is the single richest
  document on the whole lineage: it inventories every prior version's
  directory, size, test count, and modularity, and concludes **"fresh
  architecture, mine assets — not code."** It explicitly rejects salvage of
  legacy `static/` ("its 105+ ad-hoc instances... ARE the documented rot the
  proof-dev exists to prevent"), v4 (stateful solver), v5 (hand-derived
  op-sem, no proof backing), and v6 (incomplete, still
  static-require-coupled, not true DIP).
- **Implementation:** built with a real dependency-inversion architecture
  (commit series `feat(v9): ...`, `190e08eb` through `6ec70482`): a v0 type
  lattice, total AST lowering, record/function-type lattices, intra-file
  inference, annotation seam, stdlib/global declarations, control-flow
  narrowing (compound conditions, loops, reachability-at-merge), index
  signatures, string metatables, cross-module summaries with a caps-first
  `$Require` resolver.
- **Product framing:** `docs/decisions/v9-product-definition.md` / commit
  `2e1751a1` ("product definition — strict discipline enforcer, total
  semantics / bounded dynamism, owner-held power dial") and `f3bccc1f`
  ("correct product identity — TS-but-sound with full flow typing; ceiling
  is the type language... not inference power").
- **Why it failed, per the terminal record:** `docs/roadmap.md`/
  `docs/roadmap-v2.md`, "Parked: typechecker replacement" section — quoted
  directly: **"The last viable candidate (v9) measured ~3% hard-true
  precision — not acceptable."** No document was found that further
  decomposes *what* drove that 3% number (e.g., which construct classes it
  failed on); the roadmap states the outcome, not the diagnostic breakdown.
  **This is a genuine gap** — the underlying measurement artifact for the
  3% figure was not found.

## toy_checker — post-v9 sketch testing a claims-engine substrate

`lib/toy_checker/`, commits `a3f5d3a4`/`7feb8430`/`251454a5`, ~2026-07-08.

- **What it was:** per
  `docs/artifacts/2026-07-08-toy-checker-findings/notes.md`, a tiny toy
  language (let/fn/call/if-else, subtyping, generics; AST-as-tables, no
  parser) testing whether "a claims-engine with moded obligations, open
  producers, and saturation-pool scheduling" could serve as a typechecker
  substrate. Started with two obligation modes (in/out), needed a third
  ("accumulate," for recording lower bounds without collapsing to Unify),
  then a fourth mechanism (producer-initiated deferral for
  `Sub(uvar, uvar)`).
- **Root-cause finding (quoted):** "modes are a static approximation of a
  dynamic property" — whether an obligation is ready to run depends on
  runtime solver state, not a fixed label declared at creation time; "Sub
  isn't one operation... it's four different runtime behaviors... wearing
  one name." Real typecheckers (syntax-directed algorithms, or two-phase
  constraint-gen+solve) get scheduling for free from AST tree structure; the
  toy pool "threw away that structure and spent three iterations trying to
  reconstruct it from mode annotations."
- **Terminal status (quoted):** **"Parked... No clean resolution was
  found"** for the open hard problem: "Edge direction through shared
  variables is sometimes dynamic... the dependency graph isn't fully known
  at constraint emission time."
- Cross-referenced in `docs/roadmap.md`: "The follow-up (toy_checker) hit an
  unsolved hard problem: dynamic constraint-graph edge direction in the type
  inference engine."

## declc — declarative-core / claim-kernel substrate

`lib/declc/`, commits `97935de9`/`143dda13`/`f3297ee6`/`bdce309b`,
~2026-07-05 to 07-06.

- **What it was:** per
  `docs/artifacts/2026-07-05-typechecker-declarative-core/README.md`, the
  output of an owner-led session that put a "machinery-first"
  semantics-linter sketch through ~10 adversarial subagent audits, arriving
  at a certified declarative core: "a pool of graded assumptions,
  mutual-consistency checking with three-valued verdicts, and one law (a
  hypothesis must independently survive as an obligation)."
- **First-slice execution result** (commit `bdce309b`): run over 8 real
  `lib/` files (json, csv, bigint, lru, trie, queue, uuid, deque) — 2,401
  claims harvested (522 stated / 40 axiom / 1,839 mined), 2,174 checked
  topics, and the result was **"ALL Open — zero Proved, zero Refuted."**
  Root cause identified in the commit message: `harvest_stated`'s site/slot
  vocabulary never coincides with `harvest_mined`'s or `harvest_axiom`'s, so
  cross-provenance corroboration "can structurally never fire under current
  conventions" — described as "Hole H1 (the missing middle derivation
  layer), demonstrated concretely rather than asserted." A manual
  spot-check of 8 sampled claims from `json.lua` confirmed correctness of
  the individually-derived claims, i.e., the pieces worked but never
  composed into a verdict.
- **Flagged discrepancy — not resolved here.** One synthesis doc
  (`docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/synthesis.md`)
  explicitly draws a throughline back to the CLAUDE.md constraint, but
  misattributes which version the Hard Constraint names — quoted: *"this is
  the same shape as the v9 precision failure CLAUDE.md's hard constraints
  cite as the reason v5 exists (ad-hoc, demo-fit correctness that reads as
  generality)."* CLAUDE.md's actual text (per the commit that introduced
  it, `fe277ad3`/`f7725f2b`) says "v1→v4 failure," not "v9 precision
  failure" — this later doc appears to conflate/re-narrate the constraint's
  origin. This mismatch is reported, not resolved: it is unclear whether it
  reflects a genuine later re-grounding of the rule or a misremembering by
  the session that wrote the synthesis doc.

## Terminal status of the whole lineage

`docs/roadmap.md` and `docs/roadmap-v2.md` (both current, roadmap-v2 marked
authoritative per commit `f5b9426e`/`2b25c63b`) state, verbatim:

> "A replacement has been attempted 8 times (v4, v5, v6, v7, framework, v9,
> toy_checker, declc) without producing a viable successor... **Status:**
> Parked, not abandoned. Autonomous agent-directed development was declared
> dead by owner verdict as of 2026-07-08 (supervision cost exceeded
> value)... **To resume:** Requires either (1) solving the hard problem, or
> (2) finding a fundamentally different approach that avoids it entirely."

The legacy v2/v3-lineage `lib/type/static/` remains the operational,
commit-gating checker despite its documented 105+ ad-hoc instances.

## External-tooling adjacent decision (context, not a version)

`docs/decisions/why-not-external-lua-typechecker.md` (June 2026, status
"resolved") is not a crescent typechecker version but is relevant context:
it documents why LuaLS, Teal, Luau, and emmylua-analyzer-rust were all
rejected as replacements — chiefly because they're "ambient by
architecture" (undeclared names silently widen rather than error), which
conflicts with crescent's load-bearing no-ambient-globals /
capability-visibility requirement.

## Open gaps (stated exactly as found — not filled in)

1. **v1** has no dedicated design doc, directory, or commit range — only
   reconstructable from v3's retrospective description of it.
2. **Why "v8" is missing** from the numbering (v7/framework → v9) — no
   document found explaining the skip.
3. **The v9 "~3% hard-true precision" figure** — stated as a bare number in
   `docs/roadmap.md`/`roadmap-v2.md`; no underlying measurement/benchmark
   artifact breaking down what specifically produced that number was found.
4. **v4's specific technical failure trigger** beyond "did not stabilize" /
   general ad-hoc-accumulation framing — no v4-specific postmortem
   analogous to `typechecker-ad-hoc-inventory.md` (that inventory covers
   legacy `static/`, not `static-v4`) was found.
5. **v6's closure** — no explicit rejection document; inferred only from
   commit-date adjacency to v7's start and the fact that v6's M2 blockers
   doc shows unresolved open questions with no follow-up closure commit
   found.
6. **The synthesis.md "v9 precision failure ... reason v5 exists" line**
   appears to misstate the CLAUDE.md constraint's actual textual origin
   (which cites v1→v4, not v9) — reported as an unresolved discrepancy in
   the record, not resolved either way.
