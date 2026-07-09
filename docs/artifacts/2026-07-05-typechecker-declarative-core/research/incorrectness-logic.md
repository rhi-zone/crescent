# Incorrectness logic and the Hoare/IL pairing — research notes

Shelf for the semantics-linter declarative core (H1 middle layer, H3 ◇-refutation,
verdict-table quadrants). All claims grounded in the primary sources below; section
numbers cite the papers, not the draft.

## Sources (read, not just abstracts)

- [O'Hearn 2020] P. W. O'Hearn, "Incorrectness Logic", POPL 2020 (PACMPL 4(POPL):10).
  Read in full (open-access PDF via UCL Discovery, discovery.ucl.ac.uk/10095439/1/IL.pdf).
- [dVK 2011] de Vries & Koutavas, "Reverse Hoare Logic", SEFM 2011 — as characterized
  in O'Hearn §1, §5.1, §5.3, §7 (priority for the under-approximate triple, ok-only).
- [SIL 2023] Ascari, Bruni, Gori, Logozzo, "Sufficient Incorrectness Logic: SIL and
  Separation SIL", arXiv:2310.18156 — read §1, §4, §5 (taxonomy, Lisbon triples).
- [ISL 2020] Raad, Berdine, Dang, Dreyer, O'Hearn, Villard, "Local Reasoning About the
  Presence of Bugs: Incorrectness Separation Logic", CAV 2020 (plv.mpi-sws.org/ISL/paper.pdf)
  — read frame-rule and bi-abduction sections.
- [LCL 2021/23] Bruni, Giacobazzi, Gori, Ranzato, "A Logic for Locally Complete Abstract
  Interpretations" LICS 2021 (Distinguished Paper); journal version "A Correctness and
  Incorrectness Program Logic", J.ACM 2023; read via the survey "Local Completeness in
  Abstract Interpretation" (Ranzato page, csv23.pdf).
- [Pulse-X 2022] Le, Raad, Villard, Berdine, Dreyer, O'Hearn, "Finding real bugs in big
  programs with incorrectness logic", OOPSLA 2022 — manifest/latent distinction; grounded
  via ISL paper's "manifest and realizable" requirement (ISL §5) and secondary sources.

## 1. The under-approximate triple

Definition (O'Hearn Def. 1, §5.1): with post(r)p = {σ' | ∃σ∈p. (σ,σ')∈r},

    [p] C [q]  iff  post(C)p ⊇ q        (Hoare: {p}C{q} iff post(C)p ⊆ q)

Equivalent "reachability" characterization (Lemma 3, §5.1) — this is the dVK 2011
*definition*:

    [p] r [q]  ⇔  ∀σq ∈ q. ∃σp ∈ p. (σp, σq) ∈ r
    "Every state in the result is reachable from some state in the pre."

So q "speaks nothing but the truth" (§1): it does not rule out other final states, nor
divergence; it asserts positively that everything in q actually occurs. Error postconditions:
quadruples [p]C[ok: q][er: r] where er is the exit condition raised by error() (§4);
sequencing has a short-circuit rule for er. Note the triple is a *termination-involving*
reachability property (§4, p.10:10): "enough paths terminate to cover all the states in
the result assertion" — an existential liveness property, vs Hoare's safety.

**No false positives.** The phrase in the paper (§1): "Because of under-approximation,
reasoning is arranged to avoid false positives (bug suggestions that are not true)."
The formal content is Lemma 3 + Theorem 5 (Soundness, §5.1): every rule preserves truth
of triples, and a true triple means every state in the er-result is genuinely reachable
from *some* presumption state. So yes — O'Hearn's soundness theorem is literally the
never-reject guarantee, but with one crucial caveat: it is relative to the presumption
being suppliable. §4 (10:7–8): "the existence of a (consistent) error assertion does not
indicate a definite bug" — e.g. f(x){assert(x!=0);...} has [x==0]f(x)[er: x==0]; a tool
"would often choose not to flag an error in f(), instead warning at call sites that
supply 0." This is exactly the draft's 𝕋_Γ(P) relativization: an IL triple is a bug
*modulo reachability of p from the program's real entry*. Pulse-X operationalizes this as
**latent** (valid ISL error triple, p not known reachable) vs **manifest** (error occurs
from the emp/unconstrained context) errors; ISL §5 requires erroneous executions to be
"manifest and realizable using only the information at hand" (missing-resource abduction
M forced to emp for error triples) before reporting. ISL's soundness claim: "when ISL
identifies a bug, then there is indeed a bug (no false positives), given the assumptions
of the underlying ISL model."

**Completeness** (Thm 6, §5.1): every true triple over finitely-supported *semantic*
predicates is provable (implication oracle assumed). So the rule system misses nothing;
undecidability lives entirely in the ⇒ side conditions.

## 2. The four quadrants

Two orthogonal taxonomies matter; the draft's verdict table needs both.

**(a) Over/under × forward/backward** ([SIL 2023] Def. 1.1 & Fig. 3). With ⟦r⟧ forward
collecting semantics and ⟦r⃖⟧ backward (states that *can* reach Q):

    HL   {P} r {Q}    valid iff ⟦r⟧P ⊆ Q      forward, over    — proves absence
    IL   [P] r [Q]    valid iff ⟦r⟧P ⊇ Q      forward, under   — proves presence
    NC   (P) r (Q)    valid iff ⟦r⃖⟧Q ⊆ P      backward, over   — necessary preconditions
                                                (Cousot et al. 2013); NC ≃ HL (Prop 5.4:
                                                ⟦r⟧P⊆Q ⇔ ⟦r⃖⟧(¬Q)⊆¬P)
    SIL  ⟨⟨P⟩⟩r⟨⟨Q⟩⟩  valid iff ⟦r⃖⟧Q ⊇ P      backward, under  — sufficient incorrectness
                                                = "Lisbon triples" (Hoare 1978 possible
                                                correctness; every σ∈P has SOME run to Q)

  Consequence-rule directions "are determined by the diagonals" (SIL §1.4): HL & SIL may
  strengthen P / weaken Q; IL & NC the opposite. IL vs SIL quantifier shapes (SIL §5.2):
  NC∀: ∀σ'∈Q. ∀σ∈⟦r⃖⟧σ'. σ∈P  vs  IL∃: ∀σ'∈Q. ∃σ∈⟦r⃖⟧σ'. σ∈P. IL finds the *existence* of
  errors, SIL the *causes* (input states); the two under-approximate logics are distinct
  and neither subsumes the other.

**(b) The design's verdict quadrants** (prove reachable / unreachable / always-ok /
sometimes-bad) collapse onto the two logics, two apiece:

    ◇-claim proven-fine   (reachable)      = IL triple. Proof object: derivation of
                                             [p]C[ε: q∧at(s)] with q consistent; semantic
                                             witness = the states in q (each backed by a
                                             real execution, Lemma 3).
    □-claim proven-wrong  (sometimes-bad)  = IL triple whose result violates φ + the
                                             Principle of Denial (O'Hearn Fig. 1, §2):
                                             [u]c[u'] ∧ u⇒o ∧ ¬(u'⇒o') ⟹ ¬({o}c{o'}).
                                             An IL derivation is a *refutation object for
                                             a Hoare triple* — exactly the draft's F-wrong.
    □-claim proven-fine   (always-ok)      = Hoare/over-approximation. Proof object:
                                             inductive invariant / abstract fixpoint
                                             (post(⟦C*⟧ok)p = ⋀{I | p⇒I ∧ {I}C{I}}, §5.2).
    ◇-claim proven-wrong  (UNreachable)    = Hoare proof of □¬reach. Same proof object
                                             as always-ok: a universal absence argument.

  The literature is explicit that IL does not cover the right-hand pair: "under-approximate
  reasoning ... opens the way to false negatives (missed bugs)" (O'Hearn §2); "O'Hearn
  incorrectness logic cannot be used to prove program correctness because it may exhibit
  false negatives" (LCL survey §1). Conversely "Over-approximate reasoning can prove the
  absence of errors [Cousot & Cousot 1977] ... Tools based on over-approximation suffer
  from false positives" (O'Hearn §2). And negation doesn't rescue either side: "the
  inability to prove an over-approximate spec ... does not imply an error in a program,
  and neither does not having found a bug imply that there are none: thus, the need for
  dedicated techniques for each" (O'Hearn §2, end).
  → **H3 confirmed by the literature**: refuting ◇reachable(s) has no per-trace witness;
  its proof object is an over-approximate derivation (invariant + implication to ⊥ at s).
  The verdict table needs BOTH proof systems; each logic serves one diagonal.

  The bridge principles (O'Hearn Fig. 1, §2, validated by Thm 2):
    Agreement: [u]c[u'] ∧ u⇒o ∧ {o}c{o'} ⟹ u'⇒o'   (under and over cohere)
    Denial:    [u]c[u'] ∧ u⇒o ∧ ¬(u'⇒o') ⟹ ¬{o}c{o'} (under refutes over)
  Testing is the degenerate case: u, u' singletons (§2). Agreement/Denial are logically
  equivalent; they are the *only* interaction rules O'Hearn states between the logics.

## 3. Backward variant: weakest possible precondition, and why IL is forward

- wpp (Hoare 1978 "possible correctness"; O'Hearn §6.3): wpp(π)q = states that CAN reach
  q; wp = must. O'Hearn uses wp/wpp to seed presumptions ("sturdy" = wp forces the bug on
  every run; "flaky" = wpp, bug on some run), then reasons FORWARD to get a sound
  under-approximate post — "when we use backwards reasoning to generate a pre ... we need
  also to be careful to update that post" (§6.3).
- Backwards transformers are ill-behaved in IL (Fact 9, §5.2): valid presumptions need
  not exist ([p]x=41[ok: true] has none), and when they exist there need not be a
  strongest one (choice example, §5.2). So there is no "weakest-precondition calculus"
  for IL triples proper.
- SIL is the principled backward under-approximation: minimal complete system of 5 rules
  (SIL Fig. 7: ⟨⟨atom⟩⟩ ⟨⟨seq⟩⟩ ⟨⟨cons⟩⟩ ⟨⟨choice⟩⟩ ⟨⟨iter⟩⟩), inferring sufficient
  preconditions for error: every P-state reaches the bug. For the draft: an IL witness is
  "∃ input reaching each bad state"; a SIL witness is "this input family always/possibly
  reaches a bad state" — the latter is the better "definition of a family of such T" for
  F-wrong findings (Separation SIL's triple (6) vs ISL's (5), SIL §1.5: "every state in
  the precondition reaches the error, giving (many) actual witnesses").

## 4. The inference-rule system (candidate shape for H1, proven-wrong side)

O'Hearn Figs. 2–3: ~18 rules. Generic (Fig. 2): Empty-under-approximates [p]C[ε:false];
Consequence (flipped: p'⇐p, q⇐q'); Disjunction; Unit/skip; Sequencing (short-circuit er);
Sequencing (normal); Iterate-zero [p]C*[ok:p]; Iterate-non-zero (C*;C then C*); Backwards
Variant; Choice (i=1 or 2); Error [p]error()[ok:false][er:p]; Assume. Variables (Fig. 3):
Floyd FORWARD assignment axiom [p]x=e[ok: ∃x'.p[x'/x] ∧ x=e[x'/x]] (Hoare's backward
axiom is UNSOUND here, §4); Nondet assignment; Constancy (frame analog: conjoin f with
Mod(C)∩Free(f)=∅); Local Variable (with ∃y in post — consequence can't add it later);
Substitution I/II. Derived: Unrolling (⋁_{i≤bound} q_i — "capability similar to symbolic
bounded model checking", §4), derived Choice, derived Local.

Notable structure:
- **No conjunction rule** — dual of Disjunction is unsound (§4 example: two triples with
  incompatible pres). The design's derivation layer cannot combine proven-wrong evidence
  conjunctively.
- **Consequence flipped** = drop disjuncts in post / conjuncts in pre. This is the formal
  license for a solver to prune paths and still be sound on the proven-wrong side —
  "the ∧∨ Symmetry ... supports sound reasoning covering fewer than all the paths" (§2).
  Pulse literally drops disjuncts over a threshold (§6.2).
- **Loops, three tiers**: Iterate-zero (any assertion is an "invariant" — invariants play
  no central role, §4); bounded Unrolling (BMC-style; post(⟦C*⟧ε)p = ⋁_{i≤bound}{q |
  [p]Cⁱ[ε:q]}, §5.2); Backwards Variant for unbounded depth: premise
  [p(n)∧nat(n)] C [ok: p(n+1)∧nat(n)] concludes [p(0)] C* [ok: ∃n.p(n)∧nat(n)] — a
  *subvariant* that decreases when executing backwards (§4; forward version is vacuous).
  Used to get [x==0]\(x=x+1)*[ok: x>=0] covering infinitely many paths (§6.1). Errors
  inside loops: prove the ok "frontier", then one more erroneous iteration via
  Iterate-non-zero (§6.1, completeness proof §5.1).
- Summaries: presumes/achieves pairs ARE procedure summaries (§6); adaptation to call
  sites via Substitution + Constancy (§6.4); soundness requires the *reverse* implication
  check at composition boundaries (§6.4: blocked inference for inc();inc()).
- Grand duality (§8): "For correctness reasoning, you get to forget information as you go
  along a path, but you must remember all the paths. For incorrectness reasoning, you must
  remember information as you go along a path, but you get to forget some of the paths."

## 5. Combining over + under in one analyzer (the verdict table exists)

- **LCL_A** ([LCL 2021/23]) is the published combination. Provable ⊢_A [p]r[q] ensures
  (i) q ≤ ⟦r⟧p (IL-style under-approx), (ii) A(⟦r⟧p) = A(q) (same abstraction as the
  over-approx), (iii) A locally complete for ⟦r⟧ on p. Dichotomy (survey eq. (3)): for
  any spec expressible in A,   ⟦r⟧p ≤ spec ⇔ q ≤ spec — so ONE derivation either proves
  correctness or exhibits a TRUE alarm (q∖spec ⊆ ⟦r⟧p∖spec pinpoints real violations).
  The third verdict is real: when a local-completeness proof obligation C_A^p(⟦e⟧) fails,
  the triple is simply not derivable — the residue is handled by *Abstract Interpretation
  Repair* (Bruni et al., PLDI 2022: refine A, restart; "repair is for abstract
  interpretation what CEGAR is for abstract model checking"). This is literally a
  three-valued scheme {proven-fine, proven-wrong-with-true-alarm, underivable/refine} —
  the closest published analog of the draft's verdict table, and its `undecided` is
  defined exactly as H2 wants: non-derivability in a concrete proof system, with a
  productive move (domain repair) attached.
- Others in the same space: Exact Separation Logic (Maksimović et al. 2022: triples that
  are simultaneously over- and under-approximate); Outcome Logic (Zilberstein et al.
  2023: one triple form ⟨P⟩C⟨Q⊕⊤⟩ encodes Lisbon/under, HL-style for over — "a single
  unified theory ... for both correctness and incorrectness reasoning", SIL §1.1); Raad
  et al. 2024 combine Lisbon + IL triples for non-termination proofs. RacerD's soundness
  story (O'Hearn §6.2 aside) is "an under-approximation of an over-approximation" —
  under-approximate-modulo-assumptions, matching the draft's soundness-relative-to-Γ.
- O'Hearn himself (§2): "we won't study correctness and incorrectness triples together
  ... ultimately, it does make sense for them to be used together."

## 6. Frictions with the draft (things the literature pushes back on)

1. **Witness ≠ trace.** Draft F-wrong says "the finding carries T". O'Hearn's model
   carries no traces: "The model in this paper describes existence of executions leading
   to errors, but not the traces themselves" (§8, Other Models — trace models are listed
   as an OPEN problem, motivated exactly by "the traces would show actual executions,
   leading to actual bugs"). The proof object in IL is (assertion q, derivation); each
   σ∈q is trace-backed only semantically (Lemma 3). Either adopt a trace model (open
   research) or weaken F-wrong's payload to "state family + derivation" — which the draft
   already half-allows ("or the definition of a family of such T").
2. **Never-reject is conditional.** IL's no-false-positives holds modulo presumption
   reachability (latent vs manifest, §4 + Pulse-X). The draft's 𝕋_Γ(P) relativization is
   the right shape; the gate should distinguish manifest (p reachable under Γ from entry)
   from latent findings rather than treating all proven-wrong equally.
3. **H3 is not a hole in the literature — it's a quadrant boundary.** No under-approximate
   logic refutes ◇-claims; the refutation object is an over-approximate derivation
   (invariant). The "graded witness" for that quadrant should be the invariant itself.
4. **No conjunction rule on the proven-wrong side** — constrains how the H1 derivation
   layer may merge evidence (disjunction yes, conjunction no; Constancy/frame is the only
   way to import context).
5. **Assignment axiom direction flips** — any H1 rule set for proven-wrong must use
   strongest-post/forward axioms; reusing Hoare-style backward rules is unsound (§4).
