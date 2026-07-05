# Sweep: refinement types / liquid types (2026-07-05)

Family surveyed against the certified formulation (pool of graded assumptions
about executions; mutual-consistency checking; three-valued verdicts;
never-reject; hypothesis-must-survive-as-obligation). Provenance: everything
below is [WEB-SOURCED] unless marked [ANALYSIS] (this agent's comparison work).

## Sources

- Rondon, Kawaguchi, Jhala, "Liquid Types", PLDI 2008.
  https://goto.ucsd.edu/~rjhala/liquid/liquid_types.pdf
- Vazou, Seidel, Jhala, Vytiniotis, Peyton-Jones, "Refinement Types for
  Haskell", ICFP 2014. https://goto.ucsd.edu/~nvazou/refinement_types_for_haskell.pdf
- Vazou, Seidel, Jhala, "LiquidHaskell: Experience with Refinement Types in
  the Real World", Haskell Symposium 2014.
  https://goto.ucsd.edu/~nvazou/real_world_liquid.pdf
- Jhala, Vazou, "Refinement Types: A Tutorial", FnT-PL 2021.
  https://dl.acm.org/doi/10.1561/2500000032
- Vazou, Tanter, et al., "Gradual Liquid Type Inference", OOPSLA 2018.
  https://arxiv.org/abs/1807.02132
- Jhala, "Liquid Types vs. Floyd-Hoare Logic" (LH blog, 2019).
  https://ucsd-progsys.github.io/liquidhaskell-blog/2019/10/20/why-types.lhs/
- Flanagan, Leino, "Houdini, an Annotation Assistant for ESC/Java", FME 2001.
  https://users.soe.ucsc.edu/~cormac/papers/fme01.pdf
- Ernst et al., "The Daikon system for dynamic detection of likely
  invariants", SCP 2007. https://plse.cs.washington.edu/daikon/

## What the family is

Refinement types attach logical predicates to types ({v:int | v >= 0});
subtyping becomes SMT-checked implication. Liquid types (PLDI'08) make
inference decidable by predicate abstraction over a finite user-supplied set
of "logical qualifiers" Q: Hindley-Milner produces templates with unknown
refinements (kappa variables), subtyping produces Horn-style implication
constraints, and a fixpoint iteratively WEAKENS each kappa from the
conjunction of all Q-instantiations until all constraints hold. Dsolve
verified array safety in OCaml benchmarks with near-zero annotations.
LiquidHaskell scaled this to ~10k+ LOC of real libraries (bytestring, text,
vector-algorithms, xmonad).

## (a) Liquid inference vs the assumption-pool + consistency shape

Overlap is real and close. [ANALYSIS] Liquid inference IS a pool of candidate
claims (instantiations of Q at each program point) plus a global
mutual-consistency pass (the fixpoint deletes any candidate contradicted by a
constraint). The tutorial confirms the mechanism is exactly Houdini-style:
start from the full candidate pool, refute candidates against the
constraints, keep the largest consistent subset. That is
structurally the certified design's pool + consistency check — with two hard
differences: (1) liquid solving MONOTONICALLY DELETES refuted candidates to
reach one consistent fixpoint, whereas the certified design KEEPS
contradicted assumptions and reports the contradiction as a graded finding;
(2) liquid candidates are ungraded — refutation is binary, no credence.

Known scaling behavior and the failure mode it predicts:
- Qualifier-set sensitivity: precision is bounded by Q; a missing qualifier
  silently yields weaker types and downstream failures far from the cause.
  [ANALYSIS] Analogue for the design: the belief-mining rules play the role
  of Q. If the miners can't express a needed claim, the pool is silently
  incomplete — but under never-reject this degrades to "undecided", not to a
  false error. The design's three-valued verdicts absorb the classic liquid
  failure mode; the residual risk is UNDECIDED-INFLATION, not wrong blame.
- Global inference / module boundaries: the tutorial states plainly that
  liquid "inference is global and requires top-level annotations, making it
  unsuitable for modular code components and library code" and that
  "inference failure results in obscure error messages." Gradual Liquid Type
  Inference (OOPSLA'18) exists specifically because this "seriously hampered
  the migration of existing code to use refinements."
  [ANALYSIS] Prediction for the design: a whole-pool consistency check is a
  global fixpoint of the same genus; expect the same pathology — a
  contradiction's WITNESS surfaces far from its cause unless provenance is
  first-class. The design already carries provenance per pool entry; the
  liquid experience says provenance-in-the-verdict is load-bearing, not
  reporting polish. This is the closest thing to a frame-threat in (a):
  liquid types had pool+consistency and still produced obscure blame,
  because a refuted fixpoint tells you WHAT is inconsistent, not WHICH
  assumption to disbelieve. Grades are the design's answer (disbelieve the
  lowest-credence member of the contradiction) — no liquid-family system
  does this; it is genuinely novel relative to this family, and untested.

## (b) Refinement systems reject; LiquidHaskell as overlay in practice

LH is run as a separate linter-ish pass over already-working GHC code, not a
compiler gate. The experience report: annotation overhead on real code (order
10-30% extra lines on heavily-refined modules); pervasive use of `assume`
("hybrid run-time checks" in spirit) wherever the verifier loses information
— e.g. nonlinear arithmetic — and assumed specs "to allow downstream code to
type-check when upstream modules could not be fully verified." Deprecated
unsound global `invariant` mechanism shows real users demanded
assume-without-proof escape hatches badly enough that unsound ones shipped.
[ANALYSIS] Reading: even a REJECT-semantics tool, deployed over an existing
codebase, is used never-reject-ly — errors are triaged, assumed-away, or
tolerated. The certified design makes the de-facto usage mode the actual
semantics. Crucially, LH's `assume` is exactly a hypothesis admitted to Γ
that never survives as an obligation — the documented soundness leak in LH
practice is precisely the thing the design's one law forbids. That is a
strong pre-emption IN FAVOR of the law: the family's field experience shows
what happens without it (unsound assumes accrete, trust erodes silently, and
nothing tracks how much of the "verified" claim rests on them).

## (c) Type-attached vs free-floating predicates

Explicit comparison exists: Jhala's "Liquid Types vs. Floyd-Hoare Logic" and
the tutorial. The argument for IN-types: syntax-directed decomposition keeps
refinements QUANTIFIER-FREE (containers quantify via polymorphism, structure
via measures on constructors), so the SMT solver never faces quantifier
instantiation — "simple techniques like Houdini predicate abstraction
suffice once quantifiers vanish." Dafny/Why3-style VC generation
(wp-computed, program-point-attached assertions) buys expressiveness and
whole-procedure reasoning at the cost of quantified VCs, brittle solver
behavior, and blame smeared across a whole procedure's VC. The ICFP'14 paper
adds: the "classical translation of refinement types to verification
conditions" is actually unsound under lazy evaluation — the two shapes are
not interchangeable encodings.
[ANALYSIS] The certified design's pool-of-claims-about-executions is closer
to the VC/program-logic side (free-floating, about program points /
executions) than to the type side. The literature's warning transfers: the
type-attachment is what made inference tractable and blame local. A pool
design must recover locality some other way — grades + provenance are the
proposed substitute. No literature found that compares type-attached vs
pooled predicates WITH credences; the comparison exists only for the
ungraded case.

## (d) Graded / trust-weighted precedents

- Nothing in the liquid/refinement family grades refinements by credence.
  Gradual refinement types (and Gradual Liquid Inference) have a
  PRECISION dimension (? = imprecise, "optimistically interpreted") — that
  is a two-point trust scale by another name, but semantics is
  plausibility-of-concretization, not belief strength, and it still rejects.
- Daikon is the real precedent: mined "likely invariants" each carry a
  CONFIDENCE (null-hypothesis probability vs a user threshold) — i.e. graded
  beliefs mined from executions. Daikon + Houdini pipelines (mine candidates
  dynamically, refute statically) are exactly "beliefs from guards/traces
  enter a pool, consistency checking prunes." But in all published
  pipelines the grade is only an ADMISSION filter; once admitted, candidates
  are ungraded and refutation is binary. Grading the VERDICT
  (witness-status x credence-of-contradicted) appears to be novel.

## Verdict

No frame-breaker. Two frame-pressures: (a)/(c) the family's evidence says
locality-of-blame came from type attachment, and global pool consistency
historically produced obscure errors — the design bets grades+provenance
replace that, unverified by any prior system; (b) LH field experience
independently validates both never-reject-as-semantics and the
hypothesis-must-survive-as-obligation law (its absence is LH's documented
soundness leak). Daikon confirms graded mined beliefs are practicable.
