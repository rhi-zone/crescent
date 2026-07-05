# Success typings / Dialyzer + set-constraint analysis — shelf notes

Sources read in full (primary texts, not abstracts):

- [LS06] Lindahl & Sagonas, "Practical Type Inference Based on Success
  Typings", PPDP 2006. (user.it.uu.se/~kostis/Papers/succ_types.pdf)
- [LS04] Lindahl & Sagonas, "Detecting Software Defects in Telecom
  Applications Through Lightweight Static Analysis: A War Story", APLAS 2004
  — the Dialyzer 1.0 paper. (user.it.uu.se/~kostis/Papers/war_story.pdf)
- [JLS07] Jimenez, Lindahl & Sagonas, "A Language for Specifying Type
  Contracts in Erlang and its Interaction with Success Typings", Erlang
  Workshop 2007. (user.it.uu.se/~kostis/Papers/contracts.pdf)
- [Aik94] Aiken, "Set Constraints: Results, Applications and Future
  Directions", PPCP 1994. (theory.stanford.edu/~aiken/publications/papers/ppcp94.pdf)
- [JT15] Jakob & Thiemann, "A Falsification View of Success Typing",
  VMCAI 2015 (arXiv:1502.01278) — abstract + summary only, paywalled body.

## 1. The formal definition of a success typing

[LS06] Definition 1 (verbatim): "A success typing of a function f is a type
signature, (ᾱ) → β, such that whenever an application f(p̄) reduces to a
value v, then v ∈ β and p̄ ∈ ᾱ."

The direction is exactly the over-approximation the draft wants: success ⇒
membership, i.e. the typing is a *necessary* condition for successful
evaluation, never a sufficient one. The authors state the contrapositive as
the tool-relevant property: "if the function is used in a way not allowed by
its success typing (e.g., by applying the function with parameters p̄ ∉ ᾱ)
this application will definitely fail. This is precisely the property that a
defect detection tool which never 'cries wolf' needs" [LS06 §4.1].

Two consequences the paper is explicit about:

- `(any(), …) → any()` is *always* a valid success typing. "Since the type
  signature (any()) → any() is a success typing, the analysis is free to use
  this signature for all functions which are unknown; because e.g. their code
  is not available" [LS06 §4.2, "A final note"]. This is how open programs /
  missing code are handled: unknowns default to the top signature, keeping
  the analysis modular and never manufacturing a false finding.
- The guarantee is "trivially satisfied by success typings which contain no
  type information" [LS06 §7] — the authors say so themselves: the soundness
  statement alone is "relatively weak"; all the value is in how much the
  inference tightens ᾱ, β below any().

Success typings also over-include: they "capture some uses that might result
in a type clash and some type-correct uses which never evaluate to a value
(either due to non-termination or because of throwing an exception)"
[LS06 §4.1]. So divergence and exceptions are folded into "does not reduce
to a value" — the typing constrains only value-producing runs.

`(any()) → none()` is the no-success-typing verdict: for
`add2(X) when is_atom(X) -> X + 2.` "our type inferencing algorithm will
detect a type violation, which is expressed by assigning a typing such as
(any()) → none()" [LS06 §4.2] — i.e. "cannot succeed at all" is expressible
inside the same lattice, as an empty range.

Refined success typings [LS06 Def. 3]: (ᾱ′) → β′ with ᾱ′ ⊆ ᾱ, β′ ⊆ β and
the success property re-required on the restricted domain. Refinement comes
from call sites of module-local ("non-escaping") functions: since Erlang's
module system makes all callers of internal functions visible, their domains
can be narrowed to the union of actual call types. Escape analysis decides
which functions this is legal for. Direct analogue: crescent's closed-world
Γ vs open-world Γ — escaping = boundary, internal = closed.

## 2. Is "a reported discrepancy is genuine" a real theorem?

**No — it is a design requirement plus per-component arguments, not a proved
end-to-end theorem in these papers.** The evidence:

- [LS04 §3.1] states it as desideratum #1: "The methods used in DIALYZER
  should be sound: they should aim to maximize the number of reported
  discrepancies, but should not generate any false positives." Enforced as
  engineering policy: "since soundness currently is a major concern, the
  DIALYZER only reports warnings when it is clear that these are
  discrepancies … if the analysis finds that the patterns in the cases of
  the switch fail to cover all possible type values of the incoming term,
  this is not reported since it might be due to over-approximation caused by
  the path-insensitivity of the analysis" [LS04 §4.3]. I.e. the tool
  *suppresses* any finding whose derivation passed through an
  over-approximation in the wrong polarity.
- [LS06] proves only Proposition 1 (Monotonicity: solver output never more
  general than input) and Proposition 2 (Termination, via depth-k + union-
  width widening). There is no stated soundness theorem connecting the
  solver's output to Definition 1 against an operational semantics; that gap
  is exactly what [JT15] later fills (below).
- [JLS07 §1] gives the cleanest statement of the *policy*: warnings that
  "report only definite type clashes we call the warnings sound. With these
  definitions, the warnings cannot be both sound and complete" — sound-for-
  failure chosen, completeness explicitly abandoned.

Preconditions / how it interacts with dynamism:

- Whole guarantee is relative to the code the analyzer saw. Unknown code =
  (any())→any() [LS06], so unseen modules weaken findings but can't falsify
  them. Hot code loading is *not treated at all* in any of the three
  Erlang papers — no soundness-under-code-replacement statement exists. The
  honest reading: soundness is relative to a program snapshot, same as the
  draft's "relative to 𝕋_Γ(P) modulo honesty of Γ".
- [LS04] analysis starts from BEAM bytecode, needs no source and no
  annotations; guards' silent-failure semantics is itself a defect source
  (their "camouflages" category).
- Sound-for-failure survives dynamic dispatch only because unknown call
  targets decay to top. Dynamically constructed calls (apply/3, message
  sends) are simply not findings sources.
- One real-world soundness hole they own up to: findings can be artifacts of
  a buggy BEAM compiler rather than the source ("The tool confuses
  programming errors with errors in the BEAM bytecode" [LS04 §4.3]) — the
  discrepancy is genuine *in the analyzed object*, not necessarily in what
  the author wrote.

## 3. How assumptions are mined vs stated, and spec-vs-inferred disagreement

Mining (no annotations; [LS04 §3.2–3.3]):

- Substrate: intraprocedural forward dataflow on SSA CFG (Icode), types =
  disjoint union of prime types; later [LS06] the constraint-based
  bottom-up-over-SCC-DAG inference.
- Sources of belief, all presupposition-shaped, matching the draft's
  (Belief) family: (1) explicit type tests/guards — success branch gets
  incoming ⊓ tested-type, fail branch gets the success type subtracted;
  (2) primop/BIF argument demands — "if a call to addition succeeds … from
  that point forward in the CFG the arguments must be numbers as well, or
  else the operation would have failed"; (3) pattern matches; (4) return
  types unioned over non-exception exits, cached in a persistent lookup
  table (PLT) keyed by function, iterated to fixpoint or one-pass bottom-up
  over SCCs. Where fixpointing is skipped, mutually recursive components are
  heuristically widened to any — "the discrepancy analysis remains sound but
  is not complete" [LS04 §3.3].

Stated (-spec contracts; [JLS07] — this is the both-ways audit precedent):

- Let Sigt = inferred success typing, Sigc = contract. Compare via the
  covariant infimum ∩ on function types. Four cases [JLS07 §4]:
  (1) Sigc ∩ Sigt = Sigc — contract narrower than behavior: accepted, used.
  (2) Sigc ∩ Sigt = Sigt — contract wider: accepted ("over-approximating …
      not in conflict").
  (3) incomparable but non-empty meet: accepted, refined typing = infimum.
  (4) Sigc ∩ Sigt = none() — "clearly a violation of the contract and the
      user should be warned … this is also the only case where the user will
      be warned" (soundness-for-failure applied to the spec audit itself).
- So Dialyzer's lying-annotation finding fires only on *provable
  impossibility* (empty meet), not on mere looseness or narrowness. A spec
  that is wrong-but-overlapping is silently intersected in. This is weaker
  than the draft's S-param/S-return two-obligation audit: Dialyzer does not
  separately check "body honors return side" vs "callers honor param side"
  at the declaration — it checks one intersection at the definition, then:
- Trust asymmetry, verbatim [JLS07 §4]: "In general, if a contract cannot be
  disproved at the declaration point, it is trusted and all violations are
  considered to be the fault of the callers." Caller-side: contract domain
  and success-typing domain are both upper bounds, used in conjunction
  (infimum); arg-vs-contract clash or unhandled return type = violation
  reported *at the call site* "even though it might have been the contract
  that was malformed". So there IS a both-ways audit (definition check +
  call-site checks) but blame assignment is a heuristic policy, not derived.
- Why not verify contracts: "the contracts cannot be soundly verified, since
  this is the same problem as having a sound type checker for a dynamically
  typed language" [JLS07 §4]. Verification is best-effort refutation only:
  "contracts are only rejected if they are proved to be false" [JLS07 §5].
- Earlier plan already in [LS04 §4.4]: trust signature until the function is
  analyzed, then compare; on violation, report *and warn that the rest of
  the discrepancy analysis can no longer be trusted* — a poisoned-assumption
  propagation note the 2007 design dropped.
- [LS06 App. A.1] documents a real doc-vs-code lie found by inference alone
  (lists:split accepting improper lists; off-by-one in docs): "it is very
  dangerous to automatically generate type signatures from comments."

## 4. Acknowledged limits — essential vs engineering

Essential (placed by the authors as inherent to the direction):

- No proven-fine certificates, ever. Sound warnings ⇒ incomplete warnings is
  presented as a dichotomy forced by dynamic typing [JLS07 §1]; misses true
  errors by construction (over-approximation; e.g. and/2 gets
  (any(),any())→bool(), so and(42,gazonk) crash is invisible [LS06 §4.2]).
- The guarantee degrades gracefully to vacuity: top typings satisfy Def. 1
  with zero information [LS06 §7]. Precision is entirely an inference
  artifact (refinement, module system, widening limits), not part of the
  semantic contract.
- Depth: "most of the software defects identified by DIALYZER are not very
  deep. Moreover, this seems to be an inherent limitation of the method"
  [LS04 §6] — their words; deadlock freedom etc. out of reach.
- No input/output dependency in the typings (no conditional/intersection
  types): loses e.g. unreachable-clause findings that dependency tracking
  would give [LS06 §5.4]; sacrificed deliberately for readability.

Engineering (they say could be relaxed):

- Path-insensitivity (join = union at CFG merges) — cause of suppressed
  non-exhaustiveness warnings [LS04 §4.3].
- Bytecode start point ⇒ poor warning locations (no line numbers) [LS04 §4.3].
- Widening knobs: union size limit, depth-k abstraction, bounded number of
  distinct call types per function before widening [LS06 §5.3, §6.3].
- No user-defined recursive types (only list() built in) [LS06 §7].
- Witnesses: absent. Findings are program *points* + category (their
  taxonomy: explosives / camouflages / cemeteries [LS04 §4.2]), never a
  concrete failing input or trace. Nothing in these papers produces the
  draft's F-wrong witness object.

## 5. Follow-up work toward refutation/witnesses

- [JT15] Jakob & Thiemann recast success typing as *falsification*: input
  types compiled to logic formulae (output types as recursive types), with a
  proven-correct mapping; the point of the reconstruction is that success
  typing "computes inputs that will definitely cause failures" — i.e. it
  supplies the semantic account (and the definite-failure direction) that
  [LS06] asserted but never proved. This is the closest thing to a
  witness-producing formal layer over success typings: witness = the
  computed bad-input set, still not a concrete trace.
- Sagonas, Silva & Tamarit, "Precise explanation of success typing errors"
  (PEPM 2013) — explanation/slicing of *why* a discrepancy was derived
  (located via search; not read in full for these notes). Explanations of
  derivations, again not runtime witnesses.

## 6. Set constraints [Aik94]

Language: expressions E ::= α | 0 | c(E1,…,En) | E1 ∪ E2 | E1 ∩ E2 | ¬E1
over a Herbrand universe; a system is a finite conjunction of Xi ⊆ Yi;
solution = assignment V → 2^H satisfying all inclusions. Extensions, each
changing the problem: projections c⁻ⁱ (Heintze-Jaffar's original language),
function spaces X → Y, negative constraints X ⊄ Y.

What solving gives: satisfiability is decidable and "all solutions can be
finitely presented" (Thm 1, [AW92]); resolution algorithms transform to a
solved form ≈ regular tree grammars (possibly with free variables). Note: in
general there is *no least solution* (Aiken's even/odd example — two
incomparable solutions); least-solution existence is what enables the cheap
deterministic algorithms. Emptiness/inconsistency surfaces during resolution
via structural constraints: c(X1,…,Xn) ⊆ c(Y1,…,Yn) ⇔ some Xi = 0 ∨ ∀i Xi ⊆ Yi
— the nondeterministic disjunct choice is precisely where the complexity
lives.

Complexity (correcting the tasking's "DEXPTIME"): basic-language
satisfiability is **NEXPTIME-complete** [BGW93 — set constraints ≡ the
monadic class]; constants-only with set operations is NP-complete [AKVW93];
transitive-constraint resolution gives an Ω(n³) floor for "most interesting"
problems; restricted operations + guaranteed least solutions give polynomial
algorithms [JM79, MR85, Hei92] — Heintze's set-based analysis line is the
practical cubic fragment. Tree-automata containment, the deterministic
cousin, is EXPTIME-complete [Sei90]. Design consequence: a pool-consistency
check phrased as unrestricted set-constraint satisfiability is NEXPTIME in
principle; staying in a least-solution fragment (no negation, restricted
ops) is what buys polynomial closure — and note [LS06]'s solver is exactly a
least-solution-style iterate-to-fixpoint over ⊓ with widening, dodging the
disjunction blowup by *not* converting to DNF and interpreting ∨ via
pointwise least upper bound of disjunct solutions.

Graded/soft/weighted constraints: **absent**. [Aik94] contains no notion of
weighted, prioritized, soft, or differentially-trusted constraints; nothing
in [LS06]/[LS04]/[JLS07] has it either. The only trust-ordering found
anywhere on this shelf is [JLS07]'s policy asymmetry (undisproved contract >
inferred info at call sites; blame the caller). Soft-constraint machinery
(semiring-valued CSPs, MaxSAT-style weighting) exists in the constraint-
programming literature but has, per these sources, never been married to
set constraints — the draft's graded pool (axiom > stated > belief) has no
precedent in this shelf and must be argued on its own.

## 7. Design-relevant deltas vs the draft

1. Draft's Sound-wrong ≈ Dialyzer's sound-for-failure, but Dialyzer never
   exhibits a witness T; it guarantees only existence-by-construction of the
   failure. The draft's "carries T" is strictly stronger than anything here;
   [JT15] is the only bridge and it yields input sets, not traces.
2. Draft's Sound-fine (proven-fine certificates) has NO analogue: the shelf
   uniformly holds that sound-fine and sound-wrong cannot both be had in a
   dynamic language, and picks wrong-only. The draft promises both verdicts;
   it must locate proven-fine outside the success-typing tradition (H1's
   missing derivation system is where the whole difference lives).
3. Both-ways audit precedent exists ([JLS07] four-case meet + call-site
   checks) but fires only on empty intersection and assigns blame by policy,
   not proof. The draft's per-party obligation split (S-param vs S-return)
   is finer-grained than the state of the art, and [LS04 §4.4]'s dropped
   idea — flag downstream findings as tainted once a spec is refuted — is
   worth resurrecting for the pool.
4. The mining catalog (H5) has a concrete precedent list: guards, BIF/primop
   argument demands, pattern matches, non-exception return unions — all
   "succeeds ⇒ operands in demanded set" presuppositions [LS04 §3.2].
5. Never-reject + top-decay for unknowns ([LS06]) is the proven-viable way
   to keep soundness under missing/dynamic code; hot-reload soundness is an
   unclaimed gap in the literature, so crescent's "relative to Γ snapshot"
   framing is at the frontier, not behind it.
