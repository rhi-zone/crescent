# Proposal: A Verification-Tradition Architecture for Reaching the Computability Ceiling

Vantage: logic/verification — proof systems, model checking, SMT, deductive verification.
Goal restated: every true, computationally establishable claim about a program's behavior
gets established with a sound argument; everything beyond gets an explicit, itemized
surrender. Never a silent miss, never a fake proof.

## 0. The framing that forces the whole design

Rice's theorem forbids a *total* decision procedure over *all* programs. It does not forbid:
(a) semi-decision procedures that are complete-in-the-limit, (b) decidable sub-problems,
(c) deciding the property for *this particular program*, which is a single instance, not the
uniform problem. The industrial record shows the instance-level game is winnable at scale:
Astrée proved absence of runtime errors on Airbus A340/A380 fly-by-wire code with zero false
alarms (astree.ens.fr; Delmas & Souyris, SAS 2007); SLAM2 verified Windows driver protocol
properties with <4% false alarms (Ball et al., CAV 2010); Terminator proved *termination* —
the canonical "undecidable" property — of >20 kLOC driver routines (Cook, Podelski,
Rybalchenko, PLDI 2006). Each system carved out one region near the frontier. The design
problem is therefore *composition*: one architecture in which every known frontier-reaching
mechanism runs, shares results, and accounts for what remains. The output type is forced to
be three-valued per claim: PROVED (with checkable certificate), REFUTED (with witness
trace), or SURRENDERED (with the exact residual obligation and the reason). A two-valued
tool must either lie or stay far from the ceiling.

## 1. Architecture

**C1. Mechanized operational semantics (the ground truth).** A small-step semantics for the
dynamic language, mechanized once, shared by every component. Forced: "sound" is only
meaningful relative to a formal semantics; a portfolio of provers with private informal
semantics silently proves different theorems. Every other component is either proven sound
against C1 or emits certificates checked against C1.

**C2. Claim harvester + claim language.** Claims are formulas over traces (safety and
liveness). Harvested implicit claims — no type-tag error at each operation, no
out-of-bounds, each loop terminates, each contract holds — plus user-supplied claims.
Forced: "establish every true claim" needs an enumerable claim population; implicit claims
are what a typechecker-successor is *for*, and they must be first-class objects with
per-claim status, not an aggregate pass/fail.

**C3. Prover portfolio** — each member is a distinct mechanism for approaching the frontier,
and none subsumes another:
- *Abstract interpreter* (Astrée-lineage): domains for intervals, octagons, heap shape,
  tag-sets. Always terminates (widening), over-approximates, discharges the bulk of
  harvested claims cheaply and mass-produces invariants. Forced as the volume tier: the
  other provers are per-claim and cannot afford millions of claims.
- *CEGAR / predicate abstraction + IC3/PDR* (Clarke et al. 2000; Bradley's IC3; Eén et al.,
  FMCAD 2011): property-directed search for a program-specific inductive invariant,
  refining the abstraction only where a spurious counterexample demands it. This is where
  instance-level decidability lives — it succeeds exactly when *this* program admits a
  finite abstraction adequate for *this* claim, which real programs overwhelmingly do
  (they are engineered to be reasoned about; they are not Rice-adversarial diagonal cases).
- *Termination/liveness prover* (Terminator-lineage): ranking-function synthesis and
  disjunctively well-founded transition invariants (Podelski–Rybalchenko), with
  binary-reachability checks delegated to the safety provers.
- *Deductive verifier* (WP → SMT, Boogie/Dafny-lineage; Leino 2010): for claims whose
  invariants are beyond synthesis, verification conditions go to SMT, and this is the sole
  component that consumes human hints.
- *Refuter*: bounded model checking, symbolic execution, and concrete fuzzing of harvested
  claims. Forced by honesty: a claim that is *false* must become REFUTED-with-witness, not
  linger as surrendered; and prover+refuter running in parallel is the classic dovetailed
  semi-decision pair — one of them halts whenever the truth is establishable either way.

**C4. Invariant blackboard.** Every proven invariant (with certificate) is published;
every prover consumes the others' results as assumptions-already-discharged. Forced: no
single method's reach covers the ceiling; composition of partial results is the only known
route beyond each method's individual frontier (e.g., Terminator needs safety invariants;
the deductive tier needs the abstract interpreter's cheap facts to keep VCs small).

**C5. Certificate checker — small trusted kernel.** Every PROVED verdict carries a proof
object (inductive invariant + inductiveness proof, ranking function + well-foundedness,
SMT proof term) checked by a minimal kernel derived from C1 (the de Bruijn criterion).
Forced: the portfolio members are large heuristic engines; trusting them directly makes
soundness the conjunction of five codebases. With certificates, soundness = kernel only,
and provers are free to be aggressively heuristic.

**C6. Budget scheduler + surrender ledger.** Semi-decision procedures get anytime budgets;
on exhaustion the claim moves to SURRENDERED carrying (i) the residual VC or blocking
obligation, (ii) the reason class: budget-exhausted / needs-hint / depends-on-environment /
true-but-unprovable-in-metatheory. Forced directly by the mandate "explicitly surrendered,
never silently missed": the ledger *is* the explicitness.

**C7. Assumption ledger + residual runtime checks.** Open-world facts (FFI, eval, I/O) are
explicit assume-guarantee assumptions attached to each claim. Any surrendered claim can be
compiled to a runtime monitor (contract with blame), converting static surrender into a
dynamic guarantee — surrender with a safety net, still explicit.

## 2. Where the computability frontier concretely appears

- **Decidable fragments** appear inside components, never as the product's boundary:
  abstract domains with guaranteed termination; decidable SMT theories; finite-state
  quotients found by IC3. The user never has to write in a fragment.
- **Semi-decision** is the default mode: CEGAR, IC3, ranking synthesis, and SMT on
  quantified VCs are all complete-in-the-limit for their verdict. Prover and refuter
  dovetail, so every claim whose truth value is establishable at all is eventually settled
  — budgets, not decidability, cut the run short.
- **Budgets** make the frontier *resource-indexed rather than fixed*: the surrender ledger
  at budget B lists exactly the claims not yet settled at cost B, each with its residual
  obligation. Raising B, adding a hint, or adding a domain monotonically shrinks the ledger.
  The frontier is thus a concrete, inspectable artifact — a list — not an implicit property
  of the tool.
- **Program-specific decidability** is the load-bearing insight: Rice quantifies over all
  programs, but C3's property-directed engines decide the instance whenever the program
  admits an adequate finite abstraction, and real codebases are written by humans who
  themselves needed the program to be locally understandable. Terminator proving
  termination for real driver code is the existence proof that "undecidable in general"
  properties are routinely decidable in the instance.
- **The genuine residue** is threefold and admitted up front: (i) Gödel — some true claims
  have no proof in the fixed metatheory; the ledger's `true-but-unprovable` class exists
  for hint-supplied proofs in a stronger metatheory, else permanent surrender; (ii)
  environment — claims about unmodeled world stay conditional forever; (iii) economics —
  claims whose shortest proof exceeds any feasible budget are surrendered even though
  "computationally establishable" in principle. The design's honesty claim is that all
  three land in the ledger, labeled, never blended into a silent pass.

## 3. The human's role

Auto-active, hint-only, never trusted — the Dafny discipline generalized (Leino 2010: users
supply "only as many proof hints as necessary"). Humans (a) add claims worth proving beyond
the harvested ones, and (b) answer the surrender ledger: an invariant, a lemma, a ranking
function, a ghost decomposition, an environment assumption — each attached to a specific
residual obligation and each *checked* by C5, so a wrong hint costs completeness, never
soundness. Why this point on the spectrum: zero-human fails because invariant discovery is
the actual hard content of proofs and is Gödel/complexity-limited; full-manual (proof
scripts for everything) fails on cost for million-claim real programs — the harvested bulk
must be free. Hint-on-demand puts human effort exactly at the frontier the ledger exposes,
and the ledger's residual VCs make the request concrete rather than "the tool is confused
somewhere."

## 4. Top 3 ways this fails in practice

1. **The semantics gap eats the guarantee.** Real dynamic programs lean on FFI, eval,
   reflective monkey-patching, and the OS. The assumption ledger balloons until "proved,
   conditional on 300 environment assumptions" is epistemically hollow — sound, explicit,
   and irrelevant. Astrée's zero-alarm result required a closed, restricted C dialect and
   years of domain tailoring to one code family; an open dynamic language is the opposite
   setting.
2. **Surrender flood.** On heap-heavy, higher-order dynamic code, invariant synthesis lags
   far behind the harvester's claim volume; the ledger grows faster than human hint
   capacity. The tool is perfectly honest and mostly says "surrendered," and users route
   around it — honesty without adoption. The mitigation (residual runtime checks) quietly
   turns the product into a contract system with a very expensive static preprocessor.
3. **The certificate bottleneck re-widens the TCB.** Extracting checkable proof objects
   from industrial engines is brutally hard (SMT proof formats are lossy/unstable; abstract
   interpreters' certificates are their whole domain implementations). Under schedule
   pressure the project starts trusting provers directly "temporarily," and soundness
   silently becomes the conjunction of five heuristic codebases — the exact failure C5
   existed to prevent. Secondary drag: blackboard coupling creates cross-prover fixpoint
   churn and irreproducible performance cliffs.

## Sources read

- Astrée project page and industrial deployment: https://www.astree.ens.fr/ ;
  Delmas & Souyris, "Astrée: from Research to Industry," SAS 2007,
  https://www.astree.ens.fr/papers/astree_airbus_sas2007.pdf
- Cook, Podelski, Rybalchenko, "Termination Proofs for Systems Code," PLDI 2006,
  http://www0.cs.ucl.ac.uk/staff/b.cook/pdfs/termination_proofs_for_systems_code.pdf ;
  "Terminator: Beyond Safety," CAV 2006.
- Ball et al., "SLAM2: Static driver verification with under 4% false alarms," FMCAD 2010,
  https://ieeexplore.ieee.org/abstract/document/5770931/ ; CEGAR: Clarke, Grumberg, Jha,
  Lu, Veith 2000.
- Eén, Mishchenko, Brayton, "Efficient Implementation of Property Directed Reachability,"
  FMCAD 2011, https://people.eecs.berkeley.edu/~alanmi/publications/2011/fmcad11_pdr.pdf
  (IC3/PDR, Bradley).
- Leino, "Dafny: An Automatic Program Verifier for Functional Correctness," LPAR 2010
  (auto-active verification, Boogie/Z3 pipeline);
  https://alastairreid.github.io/RelatedWork/papers/leino:lpair:2010/
