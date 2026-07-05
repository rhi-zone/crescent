# Proposal: Static Analysis to the Computability Frontier — the Abstract Interpretation Vantage

Vantage: Galois connections, widening, domain design, sound approximation (Cousot & Cousot,
POPL 1977/1979). Goal restated: every computationally establishable true claim about program
behavior gets established; everything beyond gets an explicit, machine-readable surrender —
never a silent miss, never a fake.

The tradition's honest confession first: classical abstract interpretation buys termination
with widening, and widening trades completeness away *silently* — an alarm may mean "false"
or may mean "my domain can't say". The goal forbids exactly that silence. So this design
keeps the tradition's soundness machinery but re-architects around the completeness results
(Giacobazzi, Ranzato & Scozzari, "Making abstract interpretations complete", JACM 47(2),
2000) and the local-completeness program (Bruni, Giacobazzi, Gori & Ranzato, LICS 2021;
"Abstract Interpretation Repair", PLDI 2022): incompleteness is not fate, it is a *domain
property*, and domains can be repaired — until repair itself hits the uncomputable, at which
point we surrender out loud.

## 1. Architecture — components, and why each is forced

**C0. Concrete semantics kernel.** A small-step operational semantics for the language,
mechanized once; the collecting semantics over it is the sole ground truth. Forced: "sound"
and "true statement" are meaningless except relative to a fixed concrete semantics. Every
other component's correctness is proved (or at minimum stated) as a Galois-connection fact
against C0. Dynamic-language escape hatches (eval, FFI, reflection) are modeled as explicit
*assumption ports*: the semantics of an unmodeled construct is a declared havoc plus an
assumption record, so no verdict silently depends on an unmodeled behavior.

**C1. Claim layer with a three-valued, evidence-carrying verdict type.** Claims are elements
of the concrete domain (sets of behaviors / hyperproperties where needed). Verdicts are
PROVED(proof object), REFUTED(concrete witness trace), or SURRENDERED(reason + residual
obligation). Forced: the goal's core demand is that nothing is silently missed or faked;
that is a property of the *output type*, so it must be architectural, not a reporting
convention. "Unknown" without a machine-readable reason is not a legal verdict.

**C2. Fragment recognizer + exact-fixpoint engines.** Before any approximation, a front end
classifies program slices into decidable fragments and dispatches to *exact* engines: finite
abstractions model-checked exhaustively; pushdown reachability for procedural control;
acceleration for flat/flattable counter-like loops, computing Presburger-definable exact
reachability sets à la FAST (Bardin, Finkel, Leroux et al., "FAST: acceleration from theory
to practice", STTT 2008; "Flat acceleration in symbolic model checking", ATVA 2005). Forced:
the goal says *every* establishable claim; on decidable fragments, widening would forfeit
claims that exact fixpoints establish for free. Where an exact least fixpoint is computable,
computing anything else is a silent miss.

**C3. Approximate tier: a domain library under reduced product, with widening.** For code
outside decidable fragments: intervals, octagons, polyhedra, congruences, shape/heap
domains, trace partitioning, all combined by reduced product; widening/narrowing for
termination. This is the Astrée playbook, and it is kept because it *works*: Astrée proved
absence of run-time errors in Airbus A340/A380 primary flight control software with zero
false alarms after domain specialization (Delmas & Souyris, "Astrée: from Research to
Industry", SAS 2007; Souyris et al., SAFECOMP 2007). Forced: outside decidable fragments a
terminating analysis must approximate; soundness of the over-approximation is what makes
PROVED verdicts here legitimate. But in this architecture C3's alarms are *never* output —
they are inputs to C4.

**C4. The completeness-repair loop (the heart).** Every C3 alarm enters a refutation/repair
alternation:
  (a) **Refute:** an under-approximate engine (symbolic execution / bounded unrolling /
      incorrectness-logic-style reasoning) hunts a concrete witness. Found → REFUTED, with
      trace, checked against C0.
  (b) **Repair:** no witness → treat the alarm as evidence of *incompleteness* and repair
      the domain: complete-shell/kernel constructions (Giacobazzi–Ranzato–Scozzari 2000 give
      constructive least complete extensions for continuous concrete operations), and
      counterexample-guided refinement understood as domain refinement — CEGAR is exactly
      incompleteness-driven domain repair (Giacobazzi & Quintarelli, "Incompleteness,
      Counterexamples, and Refinements in Abstract Model-Checking", SAS 2001; cf. Bruni et
      al., "Abstract Interpretation Repair", PLDI 2022). Re-run C3 in the refined domain.
  (c) **Localize:** repair is guided by *local* completeness (LICS 2021): we do not need a
      globally complete domain (which would typically be the concrete domain itself, i.e.
      no analysis at all) — only completeness along the abstract computation touching this
      claim. The LCL proof system makes "this verdict is exact here" a checkable judgment.
Forced: without this loop, every widening-induced alarm is a silent miss of a possibly-true
claim, which the goal forbids. The loop is what converts "approximation trades completeness
away" from a silent tax into an explicit, iterated attack on each residual claim.

**C5. Surrender ledger.** When the loop exhausts its budget, or repair provably diverges
(the required complete extension degenerates toward the concrete domain; the claim's
fragment is undecidable and no witness is found), the claim exits as SURRENDERED carrying:
the exact residual obligation (an LCL-style local-completeness or invariant obligation), the
assumption ports it depends on, and the reason class (undecidable-fragment / budget /
divergent-refinement). Forced: the goal permits surrender but demands it be explicit and
never faked; the ledger is the artifact that makes the frontier *inspectable*.

**C6. Proof checking.** PROVED verdicts carry certificates (inductive invariants in the
final domain + the Galois soundness argument instance); REFUTED verdicts carry replayable
traces; a small trusted checker validates both against C0. Forced: "never faked" must hold
even against bugs in the analyzer itself; a large heuristic engine is trustworthy only if a
small checker gates its outputs.

## 2. The computability frontier, concretely

- **Exact zone (no widening):** decidable fragments get exact least fixpoints. Finite-state
  slices; pushdown control; flattable loops via acceleration with Presburger-definable
  closures (FAST lineage); domains satisfying the ascending chain condition where lfp is
  reached without widening. Here PROVED/REFUTED is total for expressible claims — every
  true claim in the fragment is established, by decidability.
- **Iterated zone (widening + repair):** everywhere else, C3 widens, C4 alternates
  refute/repair. Each iteration either closes the claim exactly (local completeness
  achieved, or witness found) or strictly refines the domain. This zone is a *semi-*
  procedure: it converges on many real claims (this is empirically the Astrée story —
  domain refinement driven by alarms down to zero false alarms on the target family) but
  has no termination guarantee, by Rice's theorem it cannot.
- **Surrender zone:** the loop is cut by (i) proofs of fragment-undecidability where
  available, (ii) refinement-divergence detection (repair steps approaching the concrete
  domain), (iii) resource budgets. All three produce SURRENDERED ledger entries with
  residual obligations. Honesty note: (iii) means the *realized* frontier is
  resource-bounded, strictly inside the computability frontier; the ledger records which
  cut applied, so "we could not afford it" is never disguised as "it is uncomputable".

## 3. The human's role

The human is an **untrusted oracle and the budget authority** — never a trusted component.
Three inputs, all machine-checked: (1) candidate invariants / ghost annotations / domain
hints discharging SURRENDERED obligations — checking a supplied inductive invariant is
vastly easier than inferring it, so human insight moves claims across the realized frontier
without weakening soundness (this is exactly Astrée's "directives" mechanism, generalized
and made checkable); (2) assumption-port sign-off — declaring environment facts (FFI
contracts, eval-input shapes) which enter every dependent verdict's ledger entry as explicit
assumptions; (3) budget and priority policy — deciding which surrendered claims merit more
repair iterations. The human can never flip a verdict by assertion; they can only supply
artifacts the checker validates. Defense: any trusted-human design fakes verdicts by
construction the day the human errs; any human-free design leaves obligations on the ledger
that a checkable hint would discharge — strictly fewer established truths.

## 4. Top 3 honest failure modes

1. **Refinement divergence and the budget lie.** Least complete extensions can degenerate
   toward the concrete domain; the repair loop can grind unboundedly, and budget cuts then
   file genuinely-establishable claims under SURRENDERED. The architecture is honest about
   this in the ledger, but the headline promise — "everything establishable gets
   established" — is met only in the limit, not by any finite run. This is the gap between
   the semi-procedure and the ceiling, and it is where the design most resembles marketing.
2. **Semantics-model mismatch.** Every verdict is relative to C0. Real dynamic languages
   leak past any clean kernel (eval, FFI, GC/finalizer timing, numeric edge cases).
   Assumption ports contain the damage formally, but if the modeled havoc is *narrower*
   than reality, PROVED verdicts are unsound with respect to the real system — the one
   failure the whole design exists to prevent, reintroduced at the specification boundary.
3. **Ledger overload / collapse into interactive verification.** On large real programs the
   exact tier covers little, repair budgets exhaust fast, and the surrender ledger grows to
   thousands of obligations routed to humans. At that point the tool is a proof assistant
   with an unusually good automation layer, the human is the throughput bottleneck, and
   claims practically established approach what humans annotate — the Astrée zero-alarm
   results took a specialized domain family and expert tuning; generic code has no such
   family waiting.

## Key sources (read/verified this session)

- Astrée on A340/A380, zero false alarms: astree.ens.fr; Delmas & Souyris, SAS 2007
  (astree.ens.fr/papers/astree_airbus_sas2007.pdf); SAFECOMP 2007 experimental assessment.
- Giacobazzi, Ranzato, Scozzari, "Making abstract interpretations complete", JACM 2000
  (complete shells/kernels; least complete extensions for continuous operations).
- Bruni, Giacobazzi, Gori, Ranzato, "A Logic for Locally Complete Abstract
  Interpretations", LICS 2021 (distinguished paper); "Abstract Interpretation Repair",
  PLDI 2022 (math.unipd.it/~ranzato/papers/pldi22.pdf).
- Giacobazzi & Quintarelli, "Incompleteness, Counterexamples, and Refinements in Abstract
  Model-Checking", SAS 2001 (CEGAR as domain refinement).
- Bardin, Finkel, Leroux et al., FAST / flat acceleration: STTT 2008; ATVA 2005 (exact
  Presburger reachability for flattable counter systems).
