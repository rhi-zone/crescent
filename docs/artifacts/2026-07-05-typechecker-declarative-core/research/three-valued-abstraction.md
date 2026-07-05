# Three-valued abstraction & AI soundness frameworks — shelf notes

Sources actually read (full texts fetched and extracted):

- [BG99] Bruns & Godefroid, "Model Checking Partial State Spaces with
  3-Valued Temporal Logics", CAV'99, LNCS 1633.
  https://patricegodefroid.github.io/public_psfiles/cav99.pdf
- [BG00] Bruns & Godefroid, "Generalized Model Checking: Reasoning about
  Partial State Spaces", CONCUR 2000.
  https://patricegodefroid.github.io/public_psfiles/concur2000.pdf
- [CGL94] Clarke, Grumberg & Long, "Model Checking and Abstraction",
  TOPLAS 16(5), 1994. (POPL'92 version is the ancestor.)
  https://courses.cs.washington.edu/courses/cse550/22au/papers/CSE550.ModelChecking.pdf
- [CC00] Cousot & Cousot, "Temporal Abstract Interpretation", POPL 2000.
  https://www.di.ens.fr/~cousot/publications.www/CousotCousot-POPL-00-ACM-p12--25-2000.pdf

Referenced but not fetched (flagged as such): [GJ03] Godefroid &
Jagadeesan, "On the Expressiveness of 3-Valued Models", VMCAI'03 (PKS,
MTS, KMTS equally expressive); [LT88] Larsen & Thomsen, "A Modal Process
Logic", LICS'88 (origin of may/must); [SRW99] Sagiv, Reps & Wilhelm,
"Parametric Shape Analysis via 3-Valued Logic", POPL'99.

## 1. How 3-valued model checking DEFINES ⊥ (→ hole H2)

The single most design-relevant fact: **⊥ is not defined as "no
derivation exists in some proof system." It is a value in the semantic
domain of a compositional abstract evaluation, and it is defined relative
to an explicit abstract MODEL, not relative to the raw concrete
semantics.**

Machinery in [BG99]:

- A *partial Kripke structure* (Def 6) is `(S, L, R)` with
  `L : S × P → {true, ⊥, false}` — the third value lives in the model.
- Formulas are evaluated by *Kleene's strong 3-valued logic*: ∧ = min,
  ∨ = max under the **truth ordering** `false < ⊥ < true`; ¬ swaps
  true/false and fixes ⊥. Modalities: `[s ⊨ ◇φ] = max{[t ⊨ φ] | sRt}`,
  `[s ⊨ □φ] = min{...}` (Def 7). ⊥ is *computed*, bottom-up, one clause
  per connective — exactly the shape of a derivation system.
- Separately there is the **information ordering** `≤`: `⊥ ≤ true`,
  `⊥ ≤ false`, x ≤ x. Two orders, kept distinct. Truth ordering drives
  evaluation; information ordering drives refinement.
- The **completeness preorder** ⪯ (Def 8) is a bisimulation-like relation
  where labels may gain information: `s1 ⪯ s2` requires
  `L1(s1,p) ≤ L2(s2,p)` plus the two zig-zag transition conditions.

**Theorem 9 [BG99]** (logical characterization, the property-preservation
theorem): `(∀φ : [s1 ⊨ φ] ≤ [s2 ⊨ φ]) iff s1 ⪯ s2`. Paper's gloss:
"any formula φ ... that evaluates to true or false on a partial Kripke
structure has the same truth value when evaluated on every more complete
structure." So:

- **Both definite verdicts transfer** from the abstract (less complete)
  structure to every refinement, including the fully concrete system.
  This is the two-sided regime the crescent design wants: proven-fine AND
  proven-wrong are both sound, in the same framework, from one theorem.
- ⊥ transfers nothing; it means "evaluate on a more complete structure"
  ([BG99] §3).

**Reduction to two classical checks (Theorem 12 [BG00]):** from a
3-valued labelling derive an *optimistic* completion `Mo` (⊥ ↦ true) and
*pessimistic* completion `Mp` (⊥ ↦ false); then
`[M,s ⊨ φ] = true if (Mp,s) ⊨ φ; false if (Mo,s) ⊭ φ; ⊥ otherwise.`
⊥ is literally "the two bracketing complete models disagree." Same
asymptotic complexity as 2-valued checking. ([BG99] §4 gives the fused
single-pass CTL algorithm carrying (pessimistic, optimistic) label pairs.)

**Answer to H2.** The literature never defines undecided against the raw
semantics (where, as the draft notes, it would be empty). It defines it
against a *chosen abstraction*: undecided = the abstract compositional
evaluation of the claim over the analyzer's model yields ⊥. The "missing
derivation system" of H1/H2 is, in this tradition, exactly: (a) an
abstract model of `𝕋_Γ(P)` (the analog of the partial Kripke structure),
(b) a per-connective 3-valued evaluation, (c) a preservation theorem in
the shape of Theorem 9 connecting the model to `𝕋_Γ(P)` via a
completeness/refinement preorder. H2 dissolves once the model is a named
object of the spec rather than implementation vocabulary — [BG99] shows
this layer can itself be stated declaratively (two orders, one preorder,
one theorem).

## 2. Two grades of ⊥: too-coarse vs genuinely unknowable (→ H2, F-undec)

[BG00] shows Kleene ⊥ overshoots. With `p = ⊥` at the only state,
`p ∨ ¬p` evaluates to ⊥ compositionally, yet is true in *all*
completions; likewise the non-tautological `q ∧ (p ∨ ¬p)` ([BG00] §4.1).
So they define the **thorough semantics** (Def 15): `[φ]t = true` if all
completions satisfy φ, `false` if none does, ⊥ only if "there exist a
more complete structure for which the formula holds and a more complete
structure for which the formula does not hold" — ⊥ is then *genuinely
unknowable relative to the model*. **Generalized model checking**
(Def 16) is the decision problem "does some completion of (M,s) satisfy
φ?"; it "generalizes both model checking and satisfiability checking"
(fully-⊥ model = satisfiability; complete model = model checking).

The price is precise and steep: GMC for propositional logic is
NP-complete (Thm 22), PML PSPACE-complete (Thm 21), CTL
EXPTIME-complete (Thm 20) — same as satisfiability for branching logics
(Thm 24) — and for LTL it is EXPTIME-complete (Thm 27), i.e. **strictly
harder than both LTL model checking and LTL satisfiability (both
PSPACE)**. Compositional Kleene evaluation stays linear (Thm 12/[BG99]).

Design consequence: `undecided` is not one thing. There is a spectrum of
derivation systems of increasing strength (compositional Kleene →
thorough/GMC), each with a sound definition of ⊥, trading residue size
for cost. F-undec should be parameterized by which one the linter runs,
the way the gate cut is a parameter. An `undecided` finding could even
carry *which* semantics left it undecided (cheap ⊥ = "abstraction/logic
too coarse, refinable in principle"; thorough ⊥ = "your Γ genuinely does
not determine this").

## 3. Verdict-transfer asymmetry: one-sided vs two-sided abstraction (→ verdict table)

[CGL94] is the one-sided pole. **Existential abstraction** (Def 3.3):
given surjection `h : D → D̂`, the minimal abstract structure `M_min` has
`Î(â) iff ∃d. h(d)=â ∧ I(d)` and `R̂(â1,â2) iff ∃d1 d2. h(d1)=â1 ∧
h(d2)=â2 ∧ R(d1,d2)` — abstract transitions are ∃-projections of
concrete ones (over-approximation). `M ⊑h M̂` (Def 3.2) is the
approximation ordering; `M_min` is "the most accurate approximation to M
consistent with h", and anything ⊒ it (e.g. `M^app` computed symbolically
from program text, §4 — never from the concrete state space) also works.

**Preservation (Thm 5.6):** for every ∀CTL* formula φ (universal path
quantification only, over abstract atomic propositions):
`M̂ ⊨ φ implies M ⊨ φ`. One direction only; the paper is explicit that
falsity in the abstract system says nothing about the concrete system.
Dually (folklore stated via the same machinery): an under-approximation
preserves ∃CTL* truths upward, i.e. violations-with-witnesses.
**Exactness** (Def 4.3.1/4.3.4, Lemma 4.3.2, §4.3): if the equivalence
induced by h is a *congruence* with respect to the primitive relations of
the program, `M_min` is an exact approximation and preservation becomes
iff, for **full CTL***.

Mapping onto the draft's verdict table:

- The draft's (F-fine) for □-claims is CGL's regime: proven-fine
  transfers downward through an over-approximation of `𝕋_Γ(P)`.
- The draft's (F-wrong) with witness is the dual regime: a witness is
  sound only if produced from an under-approximation (a "must" component)
  — an abstract-counterexample from an over-approximation may be spurious
  (this is the entire premise of CEGAR, Clarke-Grumberg-Jha-Lu-Veith).
- Wanting BOTH in one system is precisely what forces the two-relation /
  3-valued models: modal transition systems carry *must*-transitions
  (under, every refinement has them) and *may*-transitions (over, some
  refinement may drop them) [LT88]; □ evaluates over may, ◇ over must.
  Partial Kripke structures, MTSs, and KMTSs are equally expressive and
  inter-translatable with no complexity change [GJ03 — not fetched,
  abstract only]. So **yes: the draft's verdict table (fine / wrong /
  undecided with both definite verdicts sound) is literally the
  PKS/MTS story**, with the completeness preorder ⪯ playing "analyzer's
  model refines to the real `𝕋_Γ(P)`".

Where the draft differs from the literature:

1. **Trace claims vs state logic.** [BG99/BG00] preservation is stated
   for propositional modal logic / μ-calculus over states. The draft's
   claims are trace/event properties (closer to LTL). [BG00] §4.3 notes
   the completeness preorder "is not logically characterized by the
   3-valued extension of LTL" — it is stronger than needed for linear
   behaviors — and weakening it doesn't make GMC easier. The draft's J3
   □/◇ over an execution set is the linear-time face; the transfer
   theorem it needs is the LTL-shaped one, and the branching machinery is
   sufficient but not tight.
2. **Witness provenance.** In [BG99], `false` needs no witness trace —
   the evidence is the evaluation itself; definiteness is guaranteed by
   Theorem 9. The draft additionally demands a *concrete* witness T for
   (F-wrong). That is an extra obligation the 3-valued framework does not
   discharge: it guarantees a violating concrete execution *exists*, and
   must-transitions make abstract counterexamples concretizable, but
   exhibiting T is a separate (CEGAR-style) step.
3. **H3 dissolves.** Refuting `◇φ` (dead code) is `□¬φ`; in the 3-valued
   framework this quadrant is not witness-shaped at all — its evidence
   object is the abstract model plus the (□-side) evaluation, i.e. the
   same kind of object as (F-fine). "Graded witness" for that quadrant
   should be "the derivation," not "a trace family." The literature
   treats fine-□ and wrong-◇ as the SAME evidence class (universal),
   and wrong-□ and fine-◇ as the same (existential, witness-bearing).
   The draft's table should be factored by ∀/∃ evidence class, not by
   fine/wrong.

## 4. Cousot's calculational framework (→ derivation obligations per form)

[CC00] grounds the whole picture one level deeper: **set-based model
checking is itself an abstract interpretation of trace-based semantics.**
The *universal checking abstraction* (Def 45/46):
`α∀M(φ) = {s | M↓s ⊆ φ}` — the states all of whose traces satisfy φ;
existential dually `α∃M(φ) = ¬α∀M(¬φ) = {s | M↓s ∩ φ ≠ ∅}` (Def 49).
These are exactly the draft's J3: `𝕋 ⊨ □φ` is "entry state ∈ α∀", `◇` is
α∃. The draft's J3 is already a checking abstraction in Cousot's sense.

The **calculational method** (§8, generic compositional AI): the abstract
semantics is not written and then proven sound; it is *derived*. Per
language operator `n` with concrete transformer `Jn`, the obligations
are:

1. choose an abstraction signature per argument/result (§8.8) and a
   Galois connection per domain (§6, Hyp 39);
2. **monotonicity** of the abstract transformer (Hypothesis 28);
3. **(semi-)commutation** (Hypothesis 32):
   `α(Jn(x1..xn)) = / ⊑ Jn^a(α x1, .., α xn)` — equality gives
   completeness, inclusion gives soundness;
4. fixpoint transfer (Props 14–16) handles μ/ν.

Lemma 36 / §8.15 then lift per-operator commutation to soundness (and,
with equality, completeness) of the *entire* compositional semantics by
structural induction. The abstract transformer itself is obtained by
simplifying `α ∘ Jn ∘ γ` ("calculational design of the abstract
semantics", §11, e.g. deriving `pre[τ]` for the ⊕ operator, §11.2). For
the crescent engine ("abstract evaluator shaped like Lua's evaluator"):
per Lua form, the obligation is one semi-commutation proof between the
trace-collecting concrete step (J1's rule for that form) and the abstract
step, over a stated Galois connection on event/trace sets — nothing else.
The □/◇ layer then comes for free from Def 45/49. This is also the
principled answer to the repo's no-special-casing constraint: a form
whose transformer can't be derived is a substrate gap in the Galois
connection, visibly so.

**Incompleteness is structural, not just Rice** (§11–13): even for
*finite* systems, α∀ only semi-commutes with disjunction of path formulas
(58) and with pre/post when forward and backward modalities mix (56);
counter-example (60) is a 2-state transition system. Their reading of the
folklore "set-based MC is complete for propositional μ-calculus" (§9):
"this is misleading since an incomplete abstraction is hidden in the ∀-
and ∃-based definitions." Complete fragments exist: the μ∀+-calculus —
forward-only, ∨ restricted so one disjunct is a state formula — covering
∀CTL+ (§13), dually ∃CTL+. Design consequence: some of the linter's
`undecided` residue is *forced by the state-based engine shape* on
specific claim shapes (disjunctive path claims; past/future mixing, e.g.
`consumed(s)` which relates a past production to a future use), and the
claim grammar can be deliberately kept inside a complete fragment or the
residue accepted knowingly, per claim constructor.

## 5. Property provenance / graded trust: absent (→ the grade axis)

None of the four sources grades properties/assumptions by trust. Checked
explicitly: [BG99]/[BG00] ⊥ is about the *model's* information, never
about confidence in a *claim*; [CGL94] assumptions enter only as the
choice of h; [CC00]'s lattices order information, not provenance. The
related-work sections ([BG99] §7, [BG00] §5 — Segerberg, Morikawa,
Fitting's many-valued/multi-expert modal logics, [SRW99]) stay on the
truth-value axis. Nearest neighbors, all distinct from the draft's grade
axis: (a) multi-valued model checking over quasi-boolean lattices
(Chechik et al., e.g. "Multi-valued Model Checking via Classical Model
Checking", CONCUR'03 — search hit, not fetched) makes *truth* many-valued,
not provenance; (b) assume-guarantee reasoning has assumptions but they
are binary trusted; (c) quantitative confidence in assurance cases
(GSN-community, e.g. arXiv:2605.22213 — search hit) is a separate
community with no integration into abstraction-soundness theorems.
**Finding: the draft's J4 grade axis (axiom/stated/belief as provenance
metadata on claims, with the gate as an upward-closed cut in the product
order) has no counterpart in the 3-valued-abstraction literature. It is
orthogonal to everything above and composes cleanly with it — and it is
plausibly the design's genuinely novel contribution.** The draft's
Γ-relative soundness ("modulo honesty of boundary assumptions") is the
standard relative-soundness shape; grading Γ itself is not.
