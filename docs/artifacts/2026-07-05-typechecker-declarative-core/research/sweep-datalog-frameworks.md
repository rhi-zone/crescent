# Sweep: Datalog / declarative program-analysis frameworks (2026-07-05)

Family: Doop (OOPSLA 2009), Soufflé (CAV 2016), QL/CodeQL (ECOOP 2016),
Flix (PLDI 2016). Frame-breaker hunt against the certified formulation
(graded assumption pool, mutual-consistency, three-valued verdicts,
hypothesis-survives-as-obligation).

Sources (all read in full text except where noted):
- [DOOP] Bravenboer & Smaragdakis, "Strictly Declarative Specification of
  Sophisticated Points-to Analyses", OOPSLA 2009 (yanniss.github.io PDF).
- [FLIX] Madsen, Yee, Lhoták, "From Datalog to Flix: A Declarative Language
  for Fixed Points on Lattices", PLDI 2016 (plg.uwaterloo.ca PDF).
- [QL] Avgustinov, de Moor, Peyton Jones, Schäfer, "QL: Object-oriented
  Queries on Relational Data", ECOOP 2016 (DROPS PDF).
- [SOUF] Jordan, Scholz, Subotic, "Soufflé: On Synthesis of Program
  Analyzers", CAV 2016 (Springer abstract + souffle-lang.github.io docs).

## (a) Is layer 2 just a Datalog analysis?

Largely yes — and the collapse is real, with three precise residuals.

What maps directly:
- Pool of graded assumptions from three sources = EDB facts carrying
  (claim-key, provenance, grade) attributes. Doop demonstrates the whole
  pattern at scale: "the full end-to-end analysis in Datalog", ~180 rules /
  2500 lines per analysis, input facts extracted from the program [DOOP §1,
  §3]. No source special-casing is exactly Datalog's posture: rules see
  attributes, not fact origins.
- Propagate-to-closure = least fixpoint of Horn rules ("known facts are
  propagated using the rules until a maximal set is reached" [DOOP §2]).
- Contradiction detection is a POSITIVE derivation — conflict(A,B) :-
  claim(A,..), claim(B,..), incompatible(..) — plain Horn, no negation
  needed. Never-reject is Datalog's native mode: engines derive findings,
  they do not gate; rejection is a reporting policy outside the model.
- The "fine" verdict (□ no contradiction) is one negation over the derived
  conflict relation at a final stratum — within stratified negation limits
  everywhere (see (d)).
- Hypothesis-survives-as-obligation: reify "used in Γ" and "checked as
  obligation" as relations; the law is a coverage query
  (usedAsHypothesis(c), !discharged(c) → violation). Meta-level but
  expressible; QL does comparable reification routinely.
- ◇-witnesses: a derived conflict's witness is its proof tree. Soufflé has
  first-class provenance/proof-tree extraction; Datalog derivations are
  witnesses by construction.

What does NOT collapse (the precise misfits):
1. **Witness-status grading (wrong-with-witness vs undecided) is a
   may/must split, and Datalog least-fixpoint natively over-approximates.**
   A derived conflict over may-facts means "possibly contradictory," not
   "wrong on a real execution." An under-approximate (must) component needs
   its own dual rule set — Flix shows this is writable (their Strong Update
   analysis does flow-sensitive singleton/must points-to [FLIX §6.1]) but it
   is a second analysis to design, not a payload bit you get free.
2. **Grade feedback would break stratification.** If verdicts ever demote a
   contradicted assumption's standing in Γ *within the same closure*
   (belief revision), that is negation in a recursive cycle — outside every
   surveyed system (see (d)); it lands in well-founded/stable-model
   territory (ASP). If grades are static credences assigned at generation
   (the certified reading: grade = credence, set by source), stratification
   holds: Γ-selection → closure → conflicts → verdicts, four strata, legal.
3. **Incrementality** — see (c). The engines give batch closure; a per-edit
   gate needs delta evaluation none of the surveyed systems ship.

Verdict: layer 2's semantics IS a stratified-Datalog-with-lattices program.
The implementation question collapses to "write the rules + a must-dual for
witness status + an incremental evaluation story." That is a massive
simplification of the semantics and a relocation (not removal) of the two
hard engineering problems.

## (b) Flix lattice-valued facts vs credence grades — same mechanism?

Essentially yes, with one law to respect. Flix: every predicate's last
attribute carries an element of a user-defined complete lattice; facts in
the same "cell" (same key tuple) merge by join; rule bodies may apply
monotone transfer/filter functions; minimal model = compact interpretation,
least under the pointwise lattice order [FLIX §5: cells, compactness,
minimal-model definitions]. Termination guaranteed when "every lattice is
actually a complete lattice, of finite height, and every function is strict
and monotone" [FLIX §9].

Credence pool as Flix program: claim(key; grade) with grade in a finite
credence lattice; merge-by-join = "take the strongest credence asserted for
this claim"; propagation credence = meet of premise credences (monotone, so
legal as a Flix transfer function). Finding strength = witness-status ×
credence is a product of two finite lattices — itself a finite-height
lattice, directly a Flix payload. The design's "product order" note is
literally Flix-shaped. (This is also the Green et al. provenance-semiring
pattern — min/max semiring — worth knowing as the more general frame.)

The law: Flix demands monotone functions over a fixed lattice. Any credence
combinator that is non-monotone (e.g. evidence-counting that can *lower* a
merged grade) exits the mechanism. Caveat: PLDI-2016 Flix "does not support
any form of negation" [FLIX §5.4, §11]; modern Flix has stratified negation
in its Datalog subset, but negating lattice-valued atoms remains restricted
(non-monotone). The final "fine" stratum must negate the *existence* of a
conflict fact, not compare lattice payloads under negation.

## (c) Performance at repo scale (the real cost model)

- [DOOP] DaCapo + JDK: context-insensitive median 10x faster than Paddle
  (7.4–10.9x); 1-call-site-sensitive avg 16.3x, "from several minutes to
  below a minute"; analyses over 7200 s counted as failed; typical wins
  "from several hundreds of seconds to just a few tens of seconds."
- [SOUF] points-to of OpenJDK7 — 1.4 M program variables, 350 K objects,
  160 K methods — in under a minute, via synthesis to parallel C++.
- [QL] reimplementation of 97 Error Prone checks runs in 201 s vs 46 s for
  the hand-written Java (≈4x overhead); deployed "on multi-million line
  code bases"; QL first compiled to SQL ("performance was disappointing…
  very complex SQL"), then to a bespoke Datalog engine.

Cost model for the design: whole-repo fact extraction + closure is
**tens of seconds to minutes** in the best-tuned engines, after a decade of
optimization (Doop's win required "optimizations across rules… indexing
scheme… for all rules" [DOOP §5] on the commercial LogicBlox engine).
Against a gate-latency ambition (crescent's own 30 s per-file check budget):
batch closure fits CI, not per-edit gates. Semi-naïve evaluation is
incremental in *additions only*; none of the surveyed engines ship
incremental *retraction* (edit = retract + re-derive); that needs
DRed/DDlog-style differential evaluation, a separate literature. This is
the sweep's main cost warning, not a semantics problem.

## (d) Negation / stratification limits

Uniform across the family:
- Doop's engine (LogicBlox commercial Datalog) "allows 'stratified
  negation', i.e., negated clauses, as long as the negation is not part of
  a recursive cycle" [DOOP §2].
- Soufflé: "rules involving negation must be stratifiable"; cyclic negation
  (A :- !B. B :- !A.) rejected; negated literals cannot bind variables —
  witnesses must be grounded by positive atoms first [SOUF docs /rules].
- QL: "(mutual) recursion is only allowed under an even number of
  negations, which is a variant of the stratified negation restriction";
  stratification is checked on the compiled Datalog, not at QL level
  [QL §2, §5].
- Flix 2016: no negation at all; flags "interesting connections between
  negation and lattices" as open [FLIX §11].

Consequence for the design: mutual-consistency checking fits because
contradiction is positive and only the fine/undecided boundary needs one
top-stratum negation. The grounding rule (Soufflé) is a nice alignment: a
negative verdict cannot conjure a witness — witnesses only come from
positive derivations, which is exactly the design's witness-status
asymmetry. If the design ever needs verdict→Γ feedback, stratified Datalog
is out; well-founded semantics (natively THREE-VALUED: true/false/undefined)
or ASP is the escape hatch — and the well-founded third value is a
suggestive match for "undecided."

## Frame-threat summary

The frame-threatening finding is (a): the certified formulation's layer 2
is expressible as a stratified Flix-style program almost clause-for-clause;
what survives as genuinely hard is (1) the must/may dual for
wrong-with-witness, (2) incremental re-evaluation for gate latency, (3) the
static-grades assumption that keeps stratification legal.
