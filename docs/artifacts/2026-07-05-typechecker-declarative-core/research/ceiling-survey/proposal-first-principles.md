# Static analysis at the computability ceiling — a first-principles derivation

Vantage: computability theory only. No inherited framework (no "abstract interpretation",
no "type system") is assumed; where the traditions' machinery reappears, it is re-derived.

## 0. What Rice's theorem actually licenses

Rice's theorem: for any non-trivial semantic property, the set of *all programs* having it
is undecidable. It is a statement about a decision procedure that must work uniformly over
an infinite, adversarially quantified domain. It says nothing about a *fixed, finite*
program P and a *fixed* claim φ. "P satisfies φ" is one arithmetical sentence. Real
analysis is never the uniform problem; it is a family of single sentences about programs
written by non-adversaries who themselves believed a proof-shaped reason the program works.
Program-specific decidability — finding *that* reason — is the whole game.

Second observation: fix any sound proof system S whose proofs are machine-checkable. Then
{ (P, φ) : some S-proof establishes φ of P } is recursively enumerable — enumerate proof
objects, check each. Dually, for refutable claims, { (P, φ) : some finite execution
witnesses ¬φ } is r.e. — enumerate inputs, run bounded steps. So:

> The set of establishable true claims is r.e. but not recursive. The optimal tool is
> therefore not a decision procedure — it is an **anytime enumerator** of that r.e. set,
> plus an explicit account of what lies outside it.

Everything below is forced by this reframing.

## 1. Architecture — each component derived

**(A) Mechanized executable semantics** (trusted base). "Behavior" must denote before any
claim about it can be true. A small-step operational semantics of the (small, clean,
dynamic) language, written once, executable, and validated by differential testing against
the production interpreter on random programs. Forced because: without a formal denotation
there is no arithmetical sentence to establish — only vibes. This is the *only* semantic
authority; no component may embed a second, informal model of the language.

**(B) A tiny certificate-checking kernel.** Diagonalization kills any fixed analysis: for
every total (always-terminating) analyzer A there is a program+true claim A misses — build
the program from A itself. So reaching the ceiling requires an *open-ended, growing* set
of proof-search strategies, including untrusted ones (learned, heuristic, LLM-generated,
human-sketched). Open-ended searchers can only be trusted one way: they emit
**certificates** (proof objects over the semantics of (A)) checked by one small decidable
kernel. Soundness lives only in the kernel + semantics; everything else may be wrong,
buggy, or hallucinating without loss of soundness. Forced, not chosen.

**(C) Dual enumeration: prover and refuter, three verdicts.** A claim's truth and falsity
are both semi-decidable at worst one side each (by quantifier structure, §2). Run proof
search and counterexample search (guided execution of the semantics — testing *is* the
refutation-complete method for existential claims) concurrently. Verdict is exactly one of
**Proved(certificate) / Refuted(witness input + trace) / Open(receipt)**. There is no
fourth verdict and no default: a claim never silently passes. This is the operational
meaning of "sound + never fakes."

**(D) Claim language stratified by logical complexity.** Claims are sentences over
execution traces of (A). Their quantifier prefix determines which side is semi-decidable:
- Σ1 ("some run reaches X"): provable by a finite witness run; refutable only by proof.
- Π1 (safety, most type-shaped claims: "no run errs"): refutable by a witness run;
  provable only by certificate — the canonical certificate is an **inductive invariant**
  (a set closed under the step relation, derived here as "the finite reason a Π1 sentence
  holds", not inherited as an abstract domain).
- Π2 (termination, liveness, "every request eventually answered"): provable by
  well-foundedness certificates. The Podelski–Rybalchenko/Terminator result is the
  derivation target rediscovered: a program terminates iff a *finite union* of
  well-founded relations covers its reachable transition closure, reducing Π2 to a Π1
  safety check plus finitely many ranking functions
  (http://www0.cs.ucl.ac.uk/staff/b.cook/pdfs/terminator_beyond_safety.pdf,
  https://arxiv.org/abs/1407.4692).
The stratification is forced: it tells the scheduler which enumerator (proof vs execution)
can even in principle close each side of each claim.

**(E) Strategy library = guess-and-check searchers, unboundedly extensible.** Since truths
are r.e.-not-recursive, *any* complete architecture is "enumerate candidate certificates,
check"; strategies only choose the enumeration order. So the library is: candidate-invariant
learners from execution data with implication counterexamples (the ICE model — Houdini is
the conjunctive special case; learner may be arbitrarily heuristic because (B) checks:
http://madhu.cs.illinois.edu/CAV14ice.pdf); ranking-function synthesis; abstraction
refinement re-derived as "when a candidate certificate fails, the failed check is itself
data for the next guess"; exhaustive small-model search; and an LLM proposing invariants —
legitimate *because* it is kernel-laundered. New strategies are data, not architecture.

**(F) Anytime dovetailing scheduler.** The enumerator must be fair or it is not an
enumerator of the whole r.e. set. Staged budgets: at stage k, run every (claim-side,
strategy) pair for c·2^k steps. Fairness theorem: any claim any library strategy can ever
close is closed at some finite stage. Portfolio practice confirms this is also the
*efficient* shape, not just the complete one — CPAchecker's strategy-selection and
parallel-portfolio SV-COMP entries return a result as soon as any member finds one
(https://www.sosy-lab.org/research/pub/2024-TACAS.CPAchecker_2.3_with_Strategy_Selection_Competition_Contribution.pdf).

**(G) Proof memory.** The program is finite and evolves by small diffs; certificates are
compositional over program parts. Persist certificates keyed by the semantic objects they
mention; invalidate by dependency, re-search only the delta. Forced by "anytime" across
sessions, not just within one.

**(H) Trust ledger.** Every Proved verdict is conditional on: kernel correctness, semantics
fidelity, and any human-admitted axioms (§3). These conditions are first-class, listed on
every verdict. Gödel II applies to self-application: the tool can check its kernel's proofs
about everything *except* the kernel's own total correctness; that residue is an explicit
ledger entry, never hidden.

## 2. The frontier, concretely

**Enumeration order.** Outer loop over stages k; inner loop over (claim, side, strategy)
triples ordered by user-assigned value, then by estimated cost from proof-memory
statistics. Dovetailing guarantees limit-completeness relative to the current proof system;
ordering only affects *when*, never *whether*.

**Where unbounded time goes.** Only into Open claims the user has **pinned**. Unpinned
claims get the default staged budget and then rest at Open until the next stage or a code
change invalidates/creates relevant certificates. Budgets are policy (wall-clock per stage,
per claim, per strategy), owned by the human, reported per verdict.

**"Surrendered", operationally.** Open(receipt) where the receipt states: strategies run,
budgets exhausted, best partial artifacts (candidate invariants that almost closed, the
implication counterexamples that broke them), and — when obtainable — a *hardness
certificate*: proof that the claim is equivalent to a known-open statement or independent
of the current axioms. Beyond even that sits the true frontier: Π1 truths unprovable in
*any* fixed sound system (Gödel I). The tool's answer is structural: the proof system is
not fixed — see §3. What can never be escaped: some true claims will sit at Open forever,
and the tool will say so, with receipts, rather than guess.

## 3. The human's role — derived, not assigned

1. **Chooses φ.** Which sentences are worth establishing is a value judgment; no
   enumeration order can compute it. The spec problem is outside the ceiling by type, not
   by difficulty.
2. **Is the axiom rule.** When a pinned claim earns a hardness certificate, the human may
   admit an axiom (or an assumption about the environment) into S, signed into the trust
   ledger. This is exactly how the enumerator escapes any fixed system's Gödel ceiling:
   the human is the tool's non-computable extensibility rule. Every downstream verdict
   displays its axiom dependencies.
3. **Governs budgets and pins** (§2) and triages Refuted verdicts (bug vs wrong spec) —
   the counterexample trace is evidence; which one it indicts is again a value call.
The human is never asked to *believe* the tool: every Proved is a checkable certificate,
every Refuted a replayable trace.

## 4. Top 3 honest failure modes

1. **Semantics–reality gap.** All theorems are about the mechanized semantics (A). If it
   diverges from the production interpreter (or the OS/FFI boundary), every verdict is
   about the wrong object — soundly proved, vacuously so. Differential testing shrinks
   this; nothing eliminates it. This is the largest real risk, and it is invisible from
   inside the tool.
2. **Limit-completeness vs. finite budgets.** The ceiling is reached only "eventually."
   With real budgets, the interesting Π1/Π2 claims may pile up at Open and the tool
   degenerates into an expensive fuzzer plus receipt printer. All practical value lives in
   enumeration-order heuristics (E)/(F), which are empirical engineering, not theory — the
   theory guarantees honesty, not usefulness.
3. **Trust-ledger erosion.** The axiom escape hatch (§3.2) invites rubber-stamping;
   assumptions accumulate until "Proved" quietly means "Proved modulo twelve unexamined
   axioms." Adjacent variant: a kernel bug launders an unsound strategy's certificates.
   Mitigations (tiny kernel, cross-checking a second independent checker, axiom-count
   pressure in the UI) reduce but cannot zero this.

## Sources actually consulted

- Terminator "Beyond Safety" tool paper; transition invariants of height ω:
  http://www0.cs.ucl.ac.uk/staff/b.cook/pdfs/terminator_beyond_safety.pdf,
  https://arxiv.org/abs/1407.4692, http://www.kroening.com/papers/cav2010-2.pdf
- ICE invariant learning (Garg, Löding, Madhusudan, Neider; Houdini as conjunctive ICE
  learner): http://madhu.cs.illinois.edu/CAV14ice.pdf
- CPAchecker strategy selection and parallel portfolio at SV-COMP:
  https://www.sosy-lab.org/research/pub/2024-TACAS.CPAchecker_2.3_with_Strategy_Selection_Competition_Contribution.pdf,
  https://cpachecker.sosy-lab.org/publications.php
