# Proposal: A Consistency-of-Beliefs Architecture for Reaching the Computability Ceiling

Vantage: epistemics — treat the analysis problem not as "check the program against a
specification" but as "check a population of beliefs about the program against each other
and against the program's executions." Goal restated: surface every establishable
contradiction between what a program's authors evidently believe about its behavior and
what its behavior actually is, with explicit evidence grading; never reject a program,
never silently drop a claim, never launder a heuristic guess as a proof.

## 0. The framing that forces the whole design

A specification-first tool has a bootstrapping problem in a small dynamic language: the
specifications mostly do not exist, and mandating them changes the language. But programs
are saturated with *implicit* beliefs about their own behavior — a field access presupposes
non-nil; a guard presupposes both branches were believed reachable; a resource acquisition
presupposes a release; an annotation, where one exists, states a belief outright. None of
these are ground truth: annotations lie, guards go stale, and even "errors are unintended"
is a defeasible default, not an axiom of nature. The forcing observation is that once no
belief source can be trusted absolutely, there is no principled place to draw a line
between "specification" (trusted) and "code" (checked) — so the design refuses to draw
one. Everything is an assumption in one pool; each assumption carries a *credence* (how
strongly the evidence says the author believed it), and the tool's entire job is
mutual-consistency checking of that pool against the program's execution set. A verdict is
then forced to be three-valued per assumption — consistent (holds of all relevant
executions), contradicted (with evidence), or undecided — and the interestingness of a
contradiction is forced to be a *product*: the status of the evidence times the credence
of the assumption it contradicts. A refuted high-credence belief with a concrete witness
execution is a bug report; a refuted low-credence mined belief with weak evidence is a
whisper. The tool never rejects: it has no notion of a program "failing," only of beliefs
that did not survive contact with the semantics.

## 1. Architecture

**C1. Trace semantics (ground truth).** The dynamic language's operational semantics,
taken as given, induces for each program `P` a set of executions: traces of evaluation
events (expression evaluated, name bound, call, return, effect, error). The object of
study is `T_Γ(P)` — the executions of `P` from initial states satisfying a hypothesis set
Γ. Forced: "the author believed X about the behavior" is meaningless without a fixed
definition of behavior, and traces (not final values) are required because the belief
population includes ordering and pairing claims (acquire/release), reachability claims,
and effect claims that no input/output relation captures.

**C2. Claim language.** Beliefs compile to modal closures `□φ` / `◇φ` over trace
propositions: values arriving at a site lie in a set; an event pattern occurs; every
event matching one pattern is followed by a match of another; a site is reachable; a
produced value is later consumed; a function's call/return pairs lie in a relation.
Satisfaction is direct quantification over a trace's events, then over the execution set
(`□` = all executions, `◇` = some execution, whose exhibitor is the witness). Forced:
the population must mix universal beliefs ("this never receives nil") with existential
ones ("this code is meant to run at all"), and a refutation of each has a different
evidence shape, which the verdict grading (C5) must see.

**C3. Assumption pool — three generation sources, no source special-cased.** Every
assumption enters one pool as (claim, credence, provenance):

- *Semantic defaults*: a fixed catalog of claims minted for every program — unhandled
  errors are unintended, code is meant to be reachable, produced values are meant to be
  consumed, paired resources are meant to close. High credence, but defaults, not axioms:
  contradicting one is a finding, not a crash.
- *Author annotations*: an annotation on a definition compiles to ordinary pool entries.
  A parameter annotation mints an obligation on every caller; a return annotation mints an
  obligation on the body — one annotation, two entries sharing provenance. That is a
  compilation fact, not a semantic distinction: nothing downstream treats
  annotation-sourced entries differently. Annotations are not less important than other
  sources, just not blessed as 100% true.
- *Mined beliefs*: code forms that presuppose a proposition mint it at belief-level
  credence — a dereference presupposes the operand is non-nil there; a guard presupposes
  the author believed both branches reachable.

Why the no-special-casing rule is forced rather than aesthetic: any source-keyed branch in
the checking semantics is a place where a lying member of the privileged source becomes
invisible (if annotations are trusted, a lying annotation can never be a finding), and a
place where the other sources' findings are structurally second-class. Uniformity is what
makes "the annotation is wrong" and "the guard is stale" the same kind of output as "the
code is wrong."

**C4. Mutual-consistency checker + the hypothesis/obligation law.** The checker evaluates
each pool entry against `T_Γ(P)`. Some entries additionally serve as *hypotheses*: they
enter Γ and constrain which executions are quantified over (a boundary claim about inputs,
assumed while checking the interior). The design has exactly one law governing this role
split, and it is the load-bearing soundness invariant: **any claim admitted as a
hypothesis must independently survive as an obligation.** Otherwise the tool assumes what
it never checks, and "consistent" verdicts become conditional on unexamined premises.
Which entries enter Γ is policy; the law is not. Forced: this is the entire
assume/guarantee apparatus of interface-boundary checking, reconstructed without giving
annotations a special status — the role (hypothesis vs. obligation) is a bit on a pool
entry, not a property of where the entry came from.

**C5. Three-valued verdicts + graded findings.** Per entry: *consistent* (the execution
set satisfies it), *contradicted* (for a `□`-claim: a witness execution violating it; for
a `◇`-claim: evidence that no execution satisfies it), or *undecided* (the labeled
residue). Finding strength = (evidence status) × (credence of the contradicted
assumption), under the product order; the reporting threshold is an upward-closed cut in
that order, a parameter of the deployment rather than of the semantics. Forced: with an
untrusted, heterogeneous belief population, a binary error list must either drown the user
in mined-belief noise or suppress it wholesale; the product grading is the only structure
in the design that lets weak evidence against strong beliefs and strong evidence against
weak beliefs both surface, distinguishably.

**C6. Reporting layer — where credence lives, and the only place.** The checking machinery
never branches on credence; credence appears only in finding strength (a sort key) and in
Γ-admission policy (where the C4 law already guarantees soundness independently of
credence). Forced: the moment credence gates *checking* rather than *reporting*, it
becomes a soft trust hierarchy and re-imports the special-casing C3 exists to forbid.

## 2. Where the computability frontier concretely appears

Truth of a claim against `T_Γ(P)` is undecidable (Rice); the design's response is to make
the third verdict value the explicit, first-class residue rather than a failure mode.
Soundness is asymmetric and relative to Γ: a *contradicted* verdict on a `□`-claim always
carries a real witness execution (or the definition of a family of them); a *consistent*
verdict means no execution in `T_Γ(P)` violates the claim — modulo the honesty of Γ, which
the hypothesis/obligation law keeps auditable. No completeness is promised anywhere;
`undecided` is where incompleteness pools, per-claim and visible, instead of being blended
into pass/fail.

The candidate proof-theoretic shelf is known and named: over-approximating derivations for
consistent verdicts and under-approximating ones for contradictions is precisely the
Hoare-logic/incorrectness-logic pairing (O'Hearn 2019); three-valued verdicts over an
abstraction are three-valued model checking (Bruns–Godefroid; Clarke–Grumberg–Long); the
derivation-system-vs-semantics gap is what Cousot's calculational abstract-interpretation
framework mechanizes. Precedent also exists for graded evidence specifically: Kremenek et
al. (OSDI 2006) fuse belief sources of differing reliability in a factor graph with
annotations as high-weight nodes, and lattice-annotated facts ship today in Datalog-family
engines (Flix). What does *not* yet exist in this design is the middle layer itself — see
failure mode 1. The frontier story is therefore honest but currently only semantic: the
design defines what verdicts *mean* at the ceiling, and defers what a *derivation* of one
looks like.

## 3. The human's role

The human is a belief source and the verdict consumer — never an oracle. Writing an
annotation adds high-credence pool entries; it buys the author checking of both parties to
the stated interface, and it buys the tool the right to report the annotation itself as
wrong, with evidence, when the body contradicts it. The human never has to annotate:
mined beliefs and semantic defaults populate the pool from bare code, so the tool is
useful at annotation density zero and improves monotonically as annotations are added.
The human also owns the reporting cut (how strong a finding must be to surface) — a
per-deployment sensitivity dial that provably cannot affect what is *checked*, only what
is *shown*. Why this point on the spectrum: trusting the human's annotations fully
re-creates the specification-first bootstrapping problem and makes annotation lies
invisible; ignoring the human wastes the highest-credence evidence available. Treating the
human as one more graded source is the unique position that uses their input without
depending on its truth.

## 4. Top failure modes in practice — honest, and currently open

1. **The middle layer is missing.** The design has a semantics (what verdicts mean —
   undecidable satisfaction over execution sets) and sketches of checking machinery, but
   no declarative derivation system between them: no defined proof objects whose
   soundness/completeness could even be stated. Concretely: `undecided` is only definable
   as "neither verdict derivable," which is vacuous without the derivation system (against
   raw semantics every claim is simply true or false); and refuting a `◇`-claim (e.g.
   establishing dead code) needs a universal-absence evidence object that no trace can be,
   and which is currently undefined. Until this layer exists the proposal is a semantics
   plus an IOU, and the graded-verdict story in §2 is a specification of output shape, not
   of an algorithm.
2. **Aliasing and mutation are unsolved.** The claim language quantifies over events at
   sites; the pool's beliefs are minted at sites. In a language where tables/objects are
   freely aliased and mutated, "the value arriving here is non-nil" interacts with every
   write through every alias, and the design currently has no story — no heap model, no
   ownership or effect discipline, nothing — for keeping site-local beliefs sound under
   mutation. This is the classic graveyard of exactly this genus of tool, and the design
   has not yet engaged it.
3. **Mined beliefs have no stability story.** Beliefs harvested from guards and
   dereferences change when the code is edited for reasons unrelated to behavior — a
   refactor that hoists a nil-check moves or deletes pool entries, so findings can appear
   and vanish under behavior-preserving edits. Nothing in the design yet defines which
   mined beliefs are stable under semantics-preserving transformation, and the
   presupposition catalog itself (which code forms mint which beliefs) exists only as two
   worked examples, not a written catalog.
4. **Per-site three-valued reporting is UX-unprecedented.** No mainstream tool shows users
   consistent/contradicted/undecided per claim with a two-dimensional strength grade.
   Binary-error-list tools have trained users for decades; the risk is that `undecided` at
   realistic volume reads as noise, users collapse the tool in their heads to the binary
   subset, and the design's honesty — its central selling point — is precisely the part
   that goes unread. There is no deployment evidence either way, because no implementation
   exists; convergence evidence would have to come from a human hand-run or a minimal real
   prototype, and neither has been done.

## Sources consulted

- O'Hearn, "Incorrectness Logic," POPL 2020 — under-approximate reasoning as the proof
  theory of refutation; the fine/wrong verdict pair as dual proof systems.
- Bruns & Godefroid, "Model Checking Partial State Spaces with 3-Valued Temporal Logics,"
  CAV 1999; Clarke, Grumberg, Long, "Model Checking and Abstraction," TOPLAS 1994.
- Cousot & Cousot, abstract interpretation as a calculational design framework —
  the candidate discipline for the missing derivation layer.
- Kremenek, Twohey, Back, Ng, Engler, "From Uncertain Beliefs to Certain Errors" /
  factor-graph belief fusion for static analysis, OSDI 2006 — precedent for graded,
  multi-source evidence with annotations as high-weight (not trusted) nodes.
- Lindahl & Sagonas, "Practical Type Inference Based on Success Typings," PPDP 2006 —
  the never-reject, contradiction-seeking posture in a shipping tool for a dynamic
  language.
- Madsen, Yee, Lhoták — Flix lattice-annotated facts, PLDI 2016 — shipping precedent for
  lattice-graded facts in a logic engine.
