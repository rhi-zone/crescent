# Placement: verification-engine prior art vs. crescent's requirement

Read-and-compare only. No design, no recommendation. Every prior-art claim
below traces to one of the four digest files (`fstar.md`, `refinement.md`,
`gradual.md`, `tiered.md`) by name and claim number/quote. Every claim about
crescent's own design traces to `declarative-design.md`,
`research/ceiling-survey/judgment.md` §5, `open-threads.md` H1–H5, or
`design-pass-abstract-kernel/synthesis.md`. Constraint-verdict claims trace to
repo-root `CLAUDE.md`. One additional fact — that crescent already ships a
pure-Lua DPLL SAT solver and CSP solver — is drawn from `docs/batteries.md`,
crescent's own library inventory, and is called out as such wherever it's
used; it is not one of the four prior-art digests.

The requirement being mapped against (owner's words): an engine able to
support and attempt to prove **arbitrary** claims about code, **as
performant as a type checker** for typechecker-shaped things, with the three
{arbitrary, automatic, fast} properties **not required simultaneously** — the
engine picks the tradeoff **dynamically, per claim**, on one program.

---

## 1. Per-system-family match/mismatch table

### F* (dependent types + SMT) — `fstar.md`

**(a) Ingredients demonstrated**

- *Arbitrary claims*: partial. The core claim language (refinements over a
  dependent core, indexed effects) is fixed; new effects let a definition's
  type carry new *forms* of obligation (Hoare pre/post, cost bounds) "without
  changing the trusted kernel" — `fstar.md` claim 17. Tactics extend
  automation, not the claim language itself — claim 16.
- *Automatic*: partial, and manually dialed. SMT is invoked automatically
  wherever a refinement/logical obligation exists (claim 1), but fuel/ifuel
  and `SMTPat` are hand-tuned per-definition or per-lexical-region knobs the
  docs explicitly recommend turning *down* ("as low as possible... even `0`,
  if possible" — claim 2) rather than trusting full automation.
- *Fast like a typechecker*: **contradicted directly**. Idiomatic verified
  code carries "roughly 20x the artifact volume of proof annotation/lemmas
  per line of implementation" (claim 10); "for simple functions without
  complex proof obligations, F* by default uses an SMT solver" (claim 15) —
  there is no SMT-free typechecking mode for anything carrying a refinement
  type.
- *Dynamic per-claim tradeoff*: **the strongest example of this ingredient
  found in any digest**. `#push-options`/`#pop-options` scope SMT-tier knobs
  "to an arbitrary lexical region — i.e. tier configuration is addressable
  per-definition or even per-sub-expression, not fixed per-module" (claim 3).
  Tactics can pre-simplify a goal specifically to hand SMT something cheaper
  — tiers compose within one definition (claim 6).

**(b) What adopting the mechanism means for crescent**

Not adaptation of an existing crescent piece — crescent's typechecker is not
dependently typed and has no SMT tier at all. Bringing this in means new
substrate from scratch: a refinement/effect layer over the type language, an
SMT integration, and (if tactics are wanted) a tactic language. F*'s own
extension model likewise treats this as substrate: new claim *forms* come
from new effects, not new kernel primitives (claim 17) — the kernel stays
fixed size while the substrate above it grows.

**(c) Constraint verdict**

Z3 is a strictly version-pinned native binary — F* "requires a specific Z3
version... and will refuse to run if the version string does not match"
(claim 21); building F* itself needs an OCaml toolchain plus OPAM packages
and a multi-stage bootstrap (claim 21). No pluggable alternative SMT backend
was found (claim 22).

CLAUDE.md's carve-out reads: "Non-ubiquitous FFI dependencies vendored as
compiled binaries in `dep/`... If FFI code requires a library outside libc,
compile from official source and commit to `dep/` per platform" — worded for,
and already precedented by, `bin/cr`'s vendored per-platform LuaJIT binaries
built via `.github/workflows/build-vendored.yml`. **Genuinely ambiguous
per these rules, not resolved here**: whether that carve-out, sized against a
runtime/interpreter binary, was intended to cover something at Z3's scale —
a full SMT solver with its own strict version-pinning story (Dafny's blog,
cited in `refinement.md`, documents resource-unit counts becoming
incomparable across Z3 versions) and its own separate build toolchain. A
second, independent ambiguity: CLAUDE.md's Hard Constraint "No dependencies
that require a build step — pure Lua + FFI only" is satisfied at
*consumption* time by a prebuilt vendored binary (nothing the consuming
project builds), but *producing* that binary — for F*, an OCaml
toolchain/multi-stage bootstrap; for Z3 alone, CMake/C++ — is itself a build
step performed by maintainers ahead of time, exactly the shape already
accepted for LuaJIT. Whether Z3's build complexity crosses some threshold the
existing LuaJIT precedent doesn't reach is not addressed anywhere in
CLAUDE.md and is not resolved here.

A separate, independent tension: "Pure Lua is the baseline. No library may
hard-depend on a system lib or vendored C lib" — no digest found any
pure-language SMT solver anywhere (`gradual.md` claims 50–52, `tiered.md`
claim 34), so an SMT-backed claim class would have no pure-Lua fallback tier
that can decide *anything* about the same claims — only stay Open. Whether
"pure Lua is the baseline" is satisfied by "Open is always available without
the vendored binary" or requires a real (even if weaker) pure-Lua decision
procedure for the same claim class is not decided by CLAUDE.md's wording and
is flagged, not resolved.

### Refinement types / LiquidHaskell + Flux + Dafny — `refinement.md`

**(a) Ingredients demonstrated**

- *Arbitrary claims*: **no** — all three fix a decidable logic fragment
  (QF-EUFLIA-ish) at design time; "in none of the three systems studied is
  there a first-class, per-claim-chosen dial... What exists is either (a) a
  fixed default automation level with manual opt-out/opt-in knobs... or (b)
  very recent research explicitly naming this as an open gap" (`refinement.md`
  §5 lead sentence).
- *Automatic*: strong within the fragment. LiquidHaskell proves termination
  automatically for 96% of recursive functions at ~1.7 annotation
  lines/100 LoC (§2, measured); the tradeoff is explicit — "more expressive
  predicate logic buys less automation" (§2).
- *Fast*: Flux is "roughly an order of magnitude faster... in addition to
  needing half the specification lines" vs. Prusti on the same suite (§3,
  measured) — fast *relative to a peer tool*, not "as fast as a typechecker"
  in absolute terms; Dafny's own blog reports a function needing 679K Z3
  resource units to verify, breaking entirely on a Z3 version bump with no
  code change (§3).
- *Dynamic per-claim tradeoff*: the one exception found anywhere in this
  digest is the 2025 "Tunable Automation" paper (Verus): `broadcast`/
  `broadcast use` make quantified-fact inclusion "opt-in at whatever
  granularity the proof author picks," evaluated on real Verus codebases
  with mostly-modest (98% of functions ≤2x) but occasionally severe (3x–19x
  tail) slowdown (§5) — explicitly named as "2025-era research, not
  established practice," and it "only tunes automation-vs-speed, not
  arbitrariness... as a third axis" (§5). Everywhere else, the lever is
  binary: stay in-fragment and get automatic proof, or drop to
  `assume`/`#[flux::trusted]` and get none (§5, LiquidHaskell/Flux paragraph).

**(b) What adopting the mechanism means for crescent**

A restricted decidable-refinement layer (extend crescent's type grammar with
predicates confined to a fragment a from-scratch decision procedure could
handle) is an adaptation of crescent's existing type language — moderate new
substrate (a QF-EUFLIA-class decision procedure), not drop-in. Adopting the
*full* LiquidHaskell/Flux/Dafny mechanism (arbitrary SMT-discharged
refinements) requires the same from-scratch SMT integration as the F* row.

**(c) Constraint verdict**

Same native-binary story as F*, independently sourced: Flux's install docs
say to download a Z3 binary and put it on `$PATH` (§6) — an external-install
step in tension with CLAUDE.md's "git clone and run with no external
installs" unless re-packaged through crescent's own vendor-and-loader
pattern. Dafny's pipeline is "Dafny → Boogie → Z3; all three layers are in
the trusted base as ordinarily deployed" (§4) — same solver dependency, same
ambiguity as the F* row on whether vendoring it fits the carve-out's intended
scope. Not re-litigated here; see the F* row's verdict for the shared
ambiguity.

### Gradual typing / gradual verification — `gradual.md`

**(a) Ingredients demonstrated**

- *Arbitrary claims*: narrow. The lineage targets heap/memory-safety
  invariants (recursive data structures) via Viper/Silicon symbolic execution
  (§7 items 47–49), not an open claim language.
- *Automatic per-claim routing*: **the clean negative result directly on
  point for the requirement's third ingredient**. "After searching selective
  verification, VC caching, adaptive verification, and 'automatic hybrid type
  checking,' no system was found that automatically routes an individual
  claim to static vs. dynamic checking without a human-authored imprecision
  marker... gradual verification as it currently exists is prior art for
  gradual discharge of a human-declared boundary — a narrower, different
  claim — not for automatic per-claim routing" (§3, item 22). The programmer
  writes a literal `?` to mark imprecision (§3, item 19) — the tool decides
  how to discharge declared imprecision, never where the boundary goes.
- *Fast*: mixed to bad, where it's been measured at all. Racket's
  contract-boundary overhead (a practice-proven cousin, not gradual
  verification proper) ranges "~1x up to worst cases around 88–105x," with
  "the large majority of partially-typed configurations in almost all
  benchmarks" failing even a generous 3x bar (§5, item 34, measured) — later
  substantially recovered by a JIT reimplementation (item 35). GVC0's own
  overhead number is an unresolved source conflict across re-reads (11–34%
  vs 7.1–90%, §2 item 17) — flagged by the digest itself as unverified.
- *Dynamic per-claim tradeoff*: the "gradual guarantee" (pay-as-you-go,
  precision monotonically shrinks runtime checks toward none, §2 item 13,
  proven not measured) is the formal shape of this, but it is resolved by a
  human-placed precision marker, not automatically per the tool (§3, same
  negative result as above).

**(b) What adopting the mechanism means for crescent**

Two very different substrate costs bundled under one family name. Racket's
baseline contract system is "ordinary predicate functions evaluated at
boundary crossings via proxy/wrapper mechanisms, plus blame tracking" and
"needs no SMT solver at all" (§5, item 37/54) — this is close to a drop-in
assembly job: runtime-checked predicates crescent could implement natively
with no new substrate class. GVC0/Viper-style *static* gradual verification
is the opposite: it requires "the gradual-verification forks of Silver and
Silicon, symlinking Silicon in, and installing Z3" (§7, item 47) — the same
from-scratch SMT-integration substrate cost as the F* and refinement-types
rows.

**(c) Constraint verdict**

Racket-contract-style runtime checks: no solver dependency at all, no
vendoring question arises, fully compatible with the pure-Lua baseline as
this digest documents it. GVC0/Viper: same Z3-dependency ambiguity as the F*
row (§7, item 47–48) — not re-litigated here.

### Infer-style compositional analysis — `tiered.md` §1

**(a) Ingredients demonstrated**

- *Arbitrary claims*: **no** — checker extension is "a uniform registry:
  each checker adds a `{checker; callbacks}` record in
  `registerCheckers.ml`... Extensible for tool authors writing OCaml; not an
  open claim language for end users" (claim 6).
- *Fast/cheap-by-default*: **yes, strongly** — "Infer analyzes 1000+
  code-review diffs/day, each in ~10 minutes, on apps built from millions of
  lines; compositional per-function summaries are what make diff-time
  analysis affordable" (claim 1, measured); RacerD, a compositional race
  detector, hits the same "per-diff analysis under 15 min at
  millions-of-lines scale" (claim 4).
- *Automatic routing / per-claim escalation*: **no** — per the digest's own
  cross-cutting synthesis, compositionality "gives incremental *scope* (only
  touched functions re-analyzed) but not per-claim precision escalation";
  the biabduction→Pulse-X architecture shift (claim 5) is "a global
  architecture swap, not a per-claim dial," and "no evidence of automatic
  tier selection between checkers or precision levels per diff" (family
  cross-cutting section).

**(b) What adopting the mechanism means for crescent**

The *mechanism* — compositional per-function summaries as the cheap-default
tier, re-analyzing only what changed — is an adaptable pattern, not a
transplant of Infer-the-system (which is OCaml-plugin-based per claim 6 and
not something crescent would run). Building a crescent-native compositional
summary cache would be new substrate, but algorithmically simple (cache
keyed by function + dependency set), with no dependency implications either
way.

**(c) Constraint verdict**

Not applicable in the solver-vendoring sense — this is a pure scheduling/
caching architecture, no native solver or C library implied anywhere in the
digest. No constraint tension.

### Abstract interpretation / CEGAR / Astrée — `tiered.md` §2

**(a) Ingredients demonstrated**

- *Arbitrary claims*: **no** — Astrée "proves a fixed menu of runtime-error
  classes... in embedded C (overflow, div-by-zero, invalid pointer
  arith/deref, array OOB, uninitialized use)" (claim 8) — not an open claim
  language.
- *Fast/cheap-by-default*: **no** — Astrée on ~200k lines of Airbus
  flight-control C runs "~6 hrs/run" (claim 7, measured); this is a batch
  tool, not cheap-by-default.
- *Per-claim/precision escalation*: yes, but human-driven — false alarms
  "went 467 → 327 → 11 → 0 as a non-expert added directives (fewer widening
  steps, then partitioning on one function)" (claim 7) — real escalation,
  operated by a human, per-region rather than per-claim. Domain Types
  (claim 9, measured: LOCKS benchmark solve rate 45%→91%→100% across
  domain configs) is the closest *automatic* analogue, but the automation is
  per-variable, not per-claim.
- *Automatic routing*: **no** — "domain selection is manual, not automatic:
  parametric domains tuned via user-written directives" (claim 8); CEGAR
  automates refinement on a counterexample, but "at whole-program-
  abstraction-level... not by claim richness" (claim 10).

**(b) What adopting the mechanism means for crescent**

Abstract interpretation itself is described in this digest as "lattice ops +
fixpoint iteration, nothing native-bound" (claim 35) — algorithmically
implementable in pure Lua, no solver dependency. Adopting it as a cheap
volume tier for crescent would be substantial new substrate (a lattice/
widening framework with domain definitions) but not blocked by any
dependency constraint; it is new work, not adaptation of an existing
crescent piece, and not drop-in.

**(c) Constraint verdict**

No dependency-permissibility issue documented in this digest for abstract
interpretation itself — pure algorithm, no C/solver requirement cited
anywhere in `tiered.md` §2 or its claim 35 (though claim 35 is itself
ANECDOTE-tier, flagged in the digest as "unproven-in-practice, not
architecturally blocked"). Verasco (a *certified*, Coq-proved counterpart to
Astrée's design, claim 30) is a separate research artifact, not something
crescent would vendor.

### Datalog / CodeQL-style deductive analysis — `tiered.md` §3

**(a) Ingredients demonstrated**

- *Arbitrary claims*: **partial, with a documented ceiling**. The query
  layer is genuinely open — "~2,500 analyses across 8 languages, all written
  in QL... strong evidence the claim language is genuinely open to arbitrary
  new predicates without touching the engine" (claim 12) — but "CLOSED at
  the fact layer: a genuinely new fact kind requires extractor + dbscheme
  changes, not just a new query" (claim 14, ANECDOTE-tier per the digest's
  own tag).
- *Fast/cheap-by-default*: **no** — "QL ran ~4x slower than handwritten
  Error Prone (201s vs 46s for 97 analyses)" on Hadoop even in batch mode
  (claim 11, measured); "the whole family pays a whole-database-fixpoint
  cost regardless of claim size" (family cross-cutting synthesis).
- *Per-claim escalation*: **no** — "no shipped incremental Datalog
  evaluation anywhere in the family; CodeQL's Mar 2026 incrementality is
  extraction-layer only... Soufflé's is an unmerged research branch" (claims
  15/18, family synthesis); "every claim pays the same whole-database-
  fixpoint price regardless of how cheap the claim actually is" (claim 22).
- *Automatic routing*: **no** — "nothing routes a claim to a cheaper
  evaluation path; every query re-runs the same engine at the same cost
  tier" (family cross-cutting synthesis).

**(b) What adopting the mechanism means for crescent**

Building an open Datalog-style query layer over a fixed fact schema is a
real adaptation candidate for crescent's typechecker (which already has an
AST/fact substrate to encode as relations) but requires a genuinely new
subsystem — semi-naive evaluation, stratified negation, a query language —
not drop-in. Pure-managed-language precedent exists for the engine itself:
"Jatalog (pure Java, semi-naive evaluation, stratified negation, zero
third-party deps) and Datascript (Clojure/JS, no native deps)... Datalog/
saturation is the most portable of these architectures" (claim 33).

**(c) Constraint verdict**

No solver-vendoring ambiguity at all for the Datalog engine itself — claim 33
is direct evidence that pure-managed-language Datalog engines are real and
shipped, so a pure-Lua semi-naive evaluator is not blocked by any dependency
rule in CLAUDE.md. (Soufflé's own C++-compiled engine, claim 18, is a
separate, faster but non-pure-language implementation choice this digest
also documents — not one crescent would need to adopt to get the mechanism.)

### Demand-driven analysis — `tiered.md` §5

**(a) Ingredients demonstrated**

- *Arbitrary claims*: **no** — "evaluated in this digest only for existing
  analysis kinds (points-to), not as a general open claim language" (family
  cross-cutting synthesis).
- *Cheap-by-default*: **yes, by construction** — demand-driven CFL-
  reachability points-to reports ">10x speedups vs exhaustive analysis where
  only a small part of the points-to graph is needed; other demand-driven
  approaches report 10^2x–10^5x over exhaustive at moderate space overhead"
  (claim 28; the digest flags the primary Sridharan/Bodík number as
  paywalled/unconfirmed, downgrading exact magnitude but not the direction).
  Boomerang is cited as shipped inside production-ish taint tooling
  (FlowDroid, CogniCrypt), not just published (claim 29).
- *Per-claim escalation*: **the strongest evidence for this specific
  ingredient found anywhere across all four digests** — "this is the
  strongest ingredient (c) evidence in the whole digest: cost scales with the
  size of the question, not the size of the program, which is the literal
  definition of per-claim escalation" (family cross-cutting synthesis).
- *Automatic routing*: **no** — "demand-drivenness answers 'how much do I
  compute for this question,' not 'which analysis/tier do I route this
  question to'" (family cross-cutting synthesis).

**(b) What adopting the mechanism means for crescent**

The core idea — scope computation backward from the specific claim being
asked, rather than fixpointing the whole program — is directly transplantable
as an architectural pattern into crescent's checking substrate (e.g. an
on-demand backward query instead of a whole-pool fixpoint). This is new
substrate work (a demand-query interface over whatever fact/edge
representation crescent uses) but algorithmic, with no dependency
implications.

**(c) Constraint verdict**

Not applicable — pure scheduling/query-scoping technique, no native solver
or C library implied anywhere in the digest.

### Portfolio / tradeoff-routing approaches — `tiered.md` §4

**(a) Ingredients demonstrated**

- *Arbitrary claims*: **no** — "fixed analysis/domain menus, not an open
  claim language" (family cross-cutting synthesis).
- *Automatic routing*: **yes — the strongest ingredient (d) evidence found
  in any digest, at program granularity**. Goblint's autotuner: "cheap
  syntactic pre-analysis heuristics pick which abstract domains/analyses to
  enable... auto-selected octagon relational analysis yielded 104 additional
  correct verdicts on SV-COMP NoOverflows vs both track-everything and
  no-octagons" (claim 23, measured). A portfolio solver "was the overall
  SV-COMP winner three consecutive years (2014–2016)" (claim 24). "This is
  the family that actually automates the tier/strategy choice... the closest
  existing analogue to 'automatic routing,' but it routes whole programs to
  whole strategies, never individual claims" (family cross-cutting
  synthesis).
- *Cheap-by-default*: yes — Goblint's syntactic pre-analysis is cheap by
  construction (claim 23).
- *Per-claim escalation*: **no** — "escalation is per-variable (Domain
  Types, claim 9) or per-program (Goblint, portfolio solvers, claims 23-24),
  never per-claim" (family cross-cutting synthesis). One caveat: an
  ML-based algorithm-selection paper (MFH) reporting 81.64% top-1 success
  was **retracted/withdrawn from arXiv** — "cite only as 'attempted,
  contested' — not as evidence ML routing works at that accuracy" (claim 26).

**(b) What adopting the mechanism means for crescent**

Goblint-style cheap syntactic pre-analysis choosing which heavier
analyses/tiers to enable is a pattern crescent could adapt as a top-level
dispatcher, but every citation in this digest operates at whole-program
granularity — using it to route *individual claims* extends the pattern to a
granularity nobody surveyed has built. That extension is open new substrate,
not an adaptation of anything demonstrated.

**(c) Constraint verdict**

The routing/heuristic layer itself (cheap syntactic pre-analysis) is pure
scheduling logic, no dependency issue. Any SMT-solver-backed member *inside*
the portfolio (Theta explicitly integrates "multiple SMT solvers," claim 25)
carries the same solver-vendoring ambiguity as the F*/refinement-types rows —
not re-litigated here.

---

## 2. The gap map

Stated per the digests actually read, confirming, narrowing, or revising the
expected candidates from the task brief:

- **Automatic per-claim routing/tradeoff-selection (as opposed to a human
  picking a tool, or a program-granularity auto-router) is uncovered per
  these four digests.** This is confirmed, not just asserted: `gradual.md`'s
  own explicit "clean negative result" (item 22) states no system automates
  routing of an individual claim between static/dynamic checking without a
  human-placed marker; `refinement.md` §5 states plainly that "in none of
  the three systems studied is there a first-class, per-claim-chosen dial";
  and `tiered.md`'s cross-cutting synthesis states the closest thing to
  automatic routing found anywhere (Goblint's autotuner, SV-COMP portfolio
  solvers) "routes whole programs to whole strategies, never individual
  claims," concluding "a system with all four [ingredients]... is not
  attested anywhere in the prior art gathered here." The one partial
  counter-evidence is the 2025 Verus "Tunable Automation" paper
  (`refinement.md` §5), which does make automation-vs-speed a per-function/
  per-proof-context choice — but that choice is still made by the proof
  *author* ("quantified facts are opt-in at whatever granularity the proof
  author picks"), not the tool, and tunes only automation-vs-speed, not
  arbitrariness. Uncovered as stated — not "impossible," just not attested.

- **Certificate-checked discharge (an independently checkable proof object)
  rather than "trust the tool that ran" is uncovered as any surveyed
  system's *default*, though the pattern itself is named in the literature
  these digests cite.** `fstar.md` claims 6–9 state F*'s pipeline "does not
  describe such an independent certificate-checking step for Z3's unsat
  answers; it treats Z3's answer as authoritative," and that Z3 is "inside
  the trusted computing base, not outside it." `tiered.md` claim 31 makes
  the general statement explicit across the wider field: "Infer, CodeQL,
  CBMC are all trusted-because-tested: no checkable certificate... Dafny/F*/
  Why3 sit in between: formally structured verification conditions, but the
  SMT solver's yes/no is trusted directly — no proof object in the standard
  pipeline." The *pattern* of small-TCB certificate checking is named as
  real, general prior art — `tiered.md` claim 32 ("external solver emits a
  certificate checked by a small independently trusted checker, keeping the
  TCB to checker + core logic") and `refinement.md`'s citation of a paper
  making Dafny's Boogie VC generator "*certifying*... explicitly framed as
  reducing the trusted base shared by Dafny, VCC, Corral, and Viper" (§4) —
  but that same citation states plainly that "today's default Dafny setup
  does not have that independent check." So: the mechanism is attested as a
  research direction, not as anything shipped by default in any system these
  digests examined.

- **A pure-Lua (no-FFI-required) solver tier capable of nontrivial arbitrary
  claims is uncovered for SMT-style theory reasoning specifically, per these
  four digests — with one narrower exception already inside crescent
  itself, per `docs/batteries.md` rather than these digests.** `gradual.md`
  items 50–52 state directly: "No pure-language SMT solver was found
  anywhere — a solver doing real theory reasoning (linear arithmetic,
  arrays, bitvectors, uninterpreted functions via DPLL(T)/Nelson-Oppen),
  written from scratch in any language without a C/C++ core... no pure-Lua
  SAT or SMT solver, toy or production, was found." `tiered.md` claim 34
  corroborates for the JVM specifically: "No pure-managed reimplementation
  competitive with Z3/CVC5 surfaced." `refinement.md`'s dependencies section
  independently reaches the same conclusion: "No source found in this
  research documents a pure-managed-language... reimplementation of Horn-
  clause solving or liquid-type inference for any of the three systems
  studied... all shell out to a native Z3 (or similar) binary." This is
  confirmed uncovered *for SMT* by all three digests that address it.
  Separately — not from any of the four digests, but from crescent's own
  `docs/batteries.md` inventory, worth stating precisely because it narrows
  the gap rather than closes it — crescent already ships a pure-Lua **SAT**
  solver (`lib/sat`: DPLL with unit propagation and pure-literal elimination,
  tested on 3-coloring, pigeonhole UNSAT, 4-queens) and a pure-Lua **CSP**
  backtracking solver (`lib/constraint_solver`: AC-3 arc consistency, MRV+
  degree ordering, forward checking, tested on map-coloring/N-queens/TSP).
  These decide propositional-SAT-level and finite-domain-CSP-level claims
  today, in pure Lua, with no FFI. Neither does theory reasoning (linear
  arithmetic, arrays, uninterpreted functions) — the specific thing every
  digest says has never been done pure-language anywhere. The gap is
  therefore: SAT/CSP-level arbitrary-claim support already exists in
  crescent; SMT-level (theory-reasoning) arbitrary-claim support in pure Lua
  is unattested anywhere in the world per these digests' searches.

## 3. Compatibility notes with the certified core

Descriptive only — where prior-art mechanisms slot into
`declarative-design.md`'s pool/verdict/one-law vocabulary and
`design-pass-abstract-kernel/synthesis.md`'s kernel, and where they strain
it.

- **`Open` with a receipt is a natural carrier for prior art's "opt out of
  proof entirely" escape hatches.** `synthesis.md`'s `Verdict` type
  distinguishes `proved_witness`/`proved_claim`/`refuted`/`open`, each with
  an optional `receipt` string (§2.1). F*'s `admit()` ("produces a term of
  any type with no obligation discharged at all," `fstar.md` claim 4),
  LiquidHaskell's `assume` ("might compromise any safety guarantees,"
  `refinement.md` §1), Flux's `#[flux::trusted]`, and Dafny's `assume`
  (`refinement.md` §1, all four items) are all structurally the same shape:
  a claim admitted to the pool/proof state with an explicit, machine-visible
  "unchecked" tag rather than a false Proved. That shape maps cleanly onto
  `Open` with a receipt naming the reason class ("human axiom, unchecked") —
  the fit is close to direct.

- **External provers slot into the shape of a "producer," but the shape's
  fit is only partial — and the parts that don't fit are exactly where the
  digests document brittleness.** `judgment.md` §5's convergence item 4
  ("small trusted certificate-checking kernel; provers are untrusted
  heuristic engines") and `synthesis.md`'s "rule-honesty/correctness is
  kernel-unverifiable in principle... no structural change closes this"
  (§8) already frame external solvers as one more untrusted producer whose
  `check` result the kernel cannot itself re-verify — logically the same
  category as any hand-written rule. But `synthesis.md`'s actual kernel
  mechanics assume `Rule.check` is sandboxed, deterministic, boundedly-
  terminating Lua code the kernel *replays* under `fuel` (§2.1, graft 5/6 in
  §3) — and that assumption strains against what the digests document about
  real SMT solvers specifically: Z3 has "open, live-tracked
  brittleness/nondeterminism issues... nondeterministic `check-sat-assuming`
  results (unsat vs. unknown) even with a fixed random seed" (`refinement.md`
  §4, Z3 issue #7525), and F*'s own team names "any change to the queries
  fed to Z3 can cause unpredictable verification outcomes" as a live,
  acknowledged problem (`fstar.md` claim 13). An SMT call fits the *outer*
  shape of "untrusted producer, kernel doesn't have to trust it blindly" but
  does not fit the *inner* shape ("replay this deterministically to verify
  it") that `synthesis.md`'s sandboxing/fuel discipline (certification delta
  5, closing fake-Proved path row 6 in §6) is built around — admitting SMT
  as a producer would mean accepting it in the weaker "kernel-unverifiable
  in principle, visible-not-impossible" category already named for every
  rule in `synthesis.md` §8, not the stronger "kernel replays and confirms"
  category the sandboxing discipline otherwise aims for.

- **CodeQL's closed-fact/open-query split is the same shape as
  `synthesis.md`'s named-but-unsolved producer-coordination problem.**
  `tiered.md` claim 14 ("OPEN at the query layer... but CLOSED at the fact
  layer: a genuinely new fact kind requires extractor + dbscheme changes")
  is structurally the same gap `synthesis.md` §4.2 names as unsolved across
  every one of its four candidate kernel designs: "how do two independently-
  written harvesters discover they're talking about the same runtime fact"
  — pushed to an unowned producer-side convention in every candidate, never
  assigned an owner (certification delta 9, §7). CodeQL's dbscheme is an
  existence proof that *a* canonical addressing registry, once built and
  versioned, can hold that open-query/closed-fact line at real scale — but
  it is evidence that the registry `synthesis.md` names as missing substrate
  is buildable, not evidence that crescent's version of it exists.

- **Demand-driven analysis's cost model is a natural fit for a claim-indexed
  pool, but nothing in `synthesis.md` currently scopes computation that
  way.** `tiered.md`'s cross-cutting synthesis calls demand-driven analysis
  the strongest evidence anywhere for "cost scales with the size of the
  question, not the size of the program" — and `synthesis.md`'s pool is
  already claim-indexed (`Id` per pool entry, not per-program). But
  `synthesis.md`'s `close(pool)` is specified as "a monotone fixpoint" over
  the *whole* pool (§2.1) — nothing in the synthesized kernel scopes `close`
  to a single target `Id`'s dependency closure the way a demand-driven query
  would. The fit is directional (claim-indexed data structure, claim-shaped
  question) but not built.

- **Strain point: mechanisms that only produce a boolean, with no
  distinguishable "open," collide with the certified core's mandatory
  three-valued discipline.** `judgment.md` §5's convergence item 1 names the
  three-valued verdict as forced by the problem statement ("a two-valued
  tool must lie or retreat from the ceiling"), and `synthesis.md`'s
  certification delta 1 makes this concrete at the kernel-API level: "the
  kernel never adds an edge on `'unknown'`" — a `Rule.check` that can only
  say yes/no is exactly the shape whose absence of a "don't know" answer
  caused the documented false-Refuted bug (`synthesis.md` §4.1, primitive
  Attack 0: nil/absent conflation). Racket's baseline contracts are
  pass/fail with no "insufficient budget, ask again" state documented in
  `gradual.md` §5 (items 32–37); LiquidHaskell/Flux inside their decidable
  fragment are, per `refinement.md` §5, binary in the same way ("the only
  per-claim lever a user has is binary — stay inside the fragment and get
  automatic proof, or drop to `assume`... There is no intermediate... dial
  documented for either system"). Wrapping either as a `Rule.check` verbatim
  would force collapsing "can't decide this" into a forced true/false answer
  — the same category of bug `synthesis.md` §4.1 already found and closed
  for one specific rule, not something these digests show anyone solving in
  general for binary-only external mechanisms.

## 4. What died

- **"F* is as fast as a typechecker" is directly contradicted by
  `fstar.md`'s own cited measurements.** Claim 10: "the typical code to
  proof ratio for functional correctness and security proofs is more like
  1:20." Claim 15: "there is no separate, pure SMT-free typechecking mode
  for ordinary verified code; SMT is on the routine path for anything
  carrying a refinement type." Claim 12: real measured query costs run
  8–129ms for successful queries and up to 171ms (at a much larger rlimit
  budget) for failed ones — failed queries can burn large resource budgets
  before giving up, not fail cheaply. HACL*'s reported 12 hours of
  verification time for a crypto library at project scale (claim 14,
  anecdote-tier per the digest's own tag) is consistent with the same
  picture but not independently confirmed to the same standard as claims
  10/12/15.

- **"SMT gets called on everything" survives only in a narrower form than a
  literal reading suggests.** `fstar.md` claim 1 states SMT invocation is
  per-obligation — "wherever a refinement/logical obligation exists in the
  term being checked" — not unconditionally on every syntactic construct
  regardless of shape. What the digest *does* support at full strength is
  the narrower claim that idiomatic, routine verified code is pervasively
  on the SMT path (claim 15, claim 10's 1:20 ratio) — the "everything"
  framing overstates the literal invocation condition (claim 1) but
  understates nothing about the practical, routine cost (claims 10/15).

## Open questions this map surfaces

- [owner-call] Whether vendoring a compiled Z3 (or cvc5) binary per platform
  under `dep/`, built from official source via CI on the existing
  `build-vendored.yml`/LuaJIT pattern, falls within CLAUDE.md's
  "non-ubiquitous FFI dependencies vendored as compiled binaries" carve-out,
  or whether a full SMT solver's scale, build-toolchain requirements, and
  version-pinning brittleness (`fstar.md` claim 21; Dafny's Z3-version-
  incomparable resource units, `refinement.md` §3) put it outside what that
  carve-out was written to cover. CLAUDE.md does not address a solver at
  this scale specifically.

- [owner-call] Whether "Pure Lua is the baseline. No library may hard-depend
  on a system lib or vendored C lib" requires every claim class an optional
  SMT tier could decide to also have *some* pure-Lua fallback decision
  procedure (even a weaker one), or whether it is satisfied by such claims
  simply remaining `Open` in the absence of the vendored solver (since
  `Open` is not a failure). This determines whether an SMT-backed claim
  family is structurally permitted under crescent's stated design
  principles at all.

- [owner-call] Whether an SMT call can be admitted into `synthesis.md`'s
  producer/`Rule.check` model given the documented nondeterminism/
  brittleness of real solvers (Z3 issues #7525/#7363, `refinement.md` §4;
  F*'s own "unpredictable verification outcomes... even for simple changes
  like renaming a variable," `fstar.md` claim 13) — i.e. whether that
  brittleness disqualifies SMT from the kernel's deterministic-replay
  discipline specifically, beyond the general "rule-honesty is kernel-
  unverifiable in principle" limit `synthesis.md` §8 already names for
  every producer.

  **2026-07-07 owner resolutions:** (1) NO vendoring of Z3/cvc5-class solver binaries — ruled out regardless of the dep/ carve-out reading. (2) If an SMT-grade tier is ever built, a pure-Lua implementation is mandatory per the standard tier rules (pure Lua baseline; no hard dependency on system/vendored C libs). (3) Owner challenge on record: SMT is the slowest, most brittle family in this survey and entered the map via the cited prior art's own architecture choices, not via a crescent requirement — whether crescent's claim mix needs theory reasoning at all remains [empirical], unanswered.

- [empirical] Whether crescent's existing pure-Lua `lib/sat` (DPLL) and
  `lib/constraint_solver` (CSP backtracking) — per `docs/batteries.md`, not
  one of the four digests — are adequate as a pure-Lua solver tier for a
  meaningful fraction of the arbitrary claims the engine would need to
  decide, given that no digest found any pure-language SMT (theory-
  reasoning) solver anywhere, toy or production (`gradual.md` items 50–52).

- [empirical] Whether Goblint-style cheap syntactic pre-analysis routing
  (`tiered.md` claim 23) or demand-driven query scoping (`tiered.md` claims
  27–29) can be adapted from their demonstrated granularity (program-wide,
  or analysis-kind-wide) down to true per-claim granularity at acceptable
  engineering cost — unmeasured anywhere in these digests because no
  surveyed system does it at that granularity.

- [empirical] Whether the Verus "Tunable Automation" `broadcast`/
  `broadcast use` mechanism (`refinement.md` §5, 2025 research) generalizes
  beyond Verus, and at what slowdown-tail risk if grafted onto a different
  verification core — measured there as 98% of functions ≤2x slowdown but a
  3x–19x tail, on Verus specifically, not elsewhere.

- [empirical] Whether a certifying/certificate-checked VC generator — the
  research direction `refinement.md` §4 cites as reducing Dafny/VCC/Corral/
  Viper's shared trusted base, and the small-TCB pattern `tiered.md` claim
  32 names generally — could close the "no independently-checkable proof
  object" gap identified in §2 above for crescent's engine specifically;
  unmeasured in any of these digests for any system that ships it as its
  default pipeline.
