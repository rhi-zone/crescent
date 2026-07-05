# Breadth sweep: soft typing (2026-07-05)

Frame-breaker hunt against the certified formulation in `../declarative-design.md`
(pool of graded assumptions from three sources / mutual-consistency / three-valued
verdicts / never-reject / hypothesis-obligation law). Sources fetched this session;
quotes marked [EXTRACTED] came from PDF text pulled and read directly, [SEARCH]
from search-result summaries (weaker provenance).

## 1. Cartwright & Fagan, "Soft Typing" (PLDI 1991)

The origin paper. Extends Hindley-Milner with recursive types and limited union
types (encoded via "slack variables" turning subtype inequalities into unification
equalities); the inference engine "did not reject pro[grams]" but "could be used to
insert dynamic run-time checks where needed and inform a programmer that such
checks were necessary" [EXTRACTED, authors' own 2003/4 retrospective,
https://www.cs.rice.edu/~javaplt/papers/sigplan39-4.pdf]. Shared with the certified
design: never-reject is lifted straight from here — "a type checker need not reject
programs containing 'ill-typed' phrases" [SEARCH, ACM abstract,
https://dl.acm.org/doi/10.1145/113445.113469]. Different: (i) it is inference-only —
the premise is that programmers write NO annotations, so there is exactly one
generation source, not three; (ii) never-reject is coupled to program TRANSFORMATION
(insert checks, restore typability, keep soundness), not to report-only verdicts;
(iii) there is one globally-solved type per expression, not a pool of possibly
mutually inconsistent assumptions — inconsistency is resolved silently by widening
to a union or inserting a check, never surfaced as a graded finding. No credence,
no provenance, no hypothesis/obligation split (nothing is ever hypothesized because
nothing is ever claimed by a human). Not the certified design under another name.

## 2. Wright & Cartwright, "A Practical Soft Type System for Scheme" (LFP 1994 / TOPLAS 19(1) 1997)

Soft Scheme: the scaled-up engineering artifact — full R4RS, mutation,
continuations, improved slack-variable algorithm, "essentially linear time"
[EXTRACTED, retrospective]. "A soft type checker uses the types inferred ... to
eliminate run-time checks that are provably unnecessary; any remaining run-time
checks are flagged as potential program errors" [SEARCH, TOPLAS abstract,
https://dl.acm.org/doi/10.1145/239912.239917]. Shared: the output is closest in
spirit to the design's verdicts — sites split into proven-fine (check removed) and
flagged (check remains, "potential error"), i.e. roughly fine/undecided. Different:
the split is two-valued-plus-inspection, not three-valued; there is no
wrong-with-witness grade computed from witness-status × credence — the programmer
is the grading function, expected to inspect every flag and decide "genuine error
or weakness of the type system" (Typed Scheme's paraphrase of the premise,
[EXTRACTED] below). This is the system whose field experience constitutes the
death certificate (§4).

## 3. Aiken, Wimmers & Lakshman, "Soft Typing with Conditional Types" (POPL 1994)

Replaces unification with type-inclusion constraints over union, intersection,
recursive, and CONDITIONAL types; "conditional types enable analysis of control
flow using type inference" [SEARCH, ACM,
https://dl.acm.org/doi/10.1145/174675.177847]. A conditional type gives a branch a
type that is conditioned on the outcome of the guard predicate — the type system
itself consumes what the code's own guards imply. Shared: this is the closest
historical precedent for the design's third source, beliefs MINED from
guards/derefs — the Rice line had the same move as if-splitting rules "based on the
syntactic predicates in the test expression," which Tobin-Hochstadt & Felleisen say
"inspired occurrence typing" [EXTRACTED, arXiv:1106.2575 §9.1]. Different: mined
guard facts enter as hard constraints inside one global solution, not as graded
pool entries; a mined fact can never be found WRONG (it is definitionally true of
the branch), whereas the certified design's mined beliefs are fallible credences
that can be contradicted. Cost profile noted by Cartwright/Fagan: SBA-family
analyses are cubic without polyvariance, exponential with [EXTRACTED,
retrospective] — a warning for consistency-checking over a large pool.

## (a) Is any of these already the assumption-pool + consistency design?

No. Structural test: soft typing is the DEGENERATE CORNER of the certified design —
one generation source (inference/mining only; annotations excluded by explicit
premise: "programmers shouldn't have to write down type definitions or type
declarations. Soft typing should work via type inference only" [EXTRACTED,
arXiv:1106.2575 §9.1]), uniform implicit credence (every constraint equally hard),
two-valued site verdicts, and inconsistency handled by silent repair (union-widen
or check-insert) rather than surfaced as a finding with a witness. No pool, no
grades, no mutual-consistency reporting, no law. The design is not soft typing
renamed; it is, if anything, soft typing with the three parameters un-degenerated.

## (b) What killed soft typing — and does the killer apply?

Felleisen (co-author of the successor line, firsthand): "soft type systems are
complex and brittle. On one hand, these systems may infer extremely large types for
seemingly simple expressions, greatly confusing the original programmer ... On the
other hand, a small syntactic change to a program without semantic consequences can
introduce vast changes into the types of both nearby and remote expressions.
Experiments with undergraduates ... suggest that only the very best understood the
tools well enough to make sense of the inferred types ... For the others, these
tools turned into time sinks with little benefit" [EXTRACTED, arXiv:1106.2575
§9.1]. Plus the HM error-recovery problem: "when the type system signals a type
error, it is extremely difficult — often impossible — to decipher its meaning and to
fix it" [EXTRACTED, ibid.]. The SBA branch fixed explainability ("easy to
communicate ... how a value might flow into a particular operation") at cubic-to-
exponential cost [EXTRACTED, ibid.; retrospective]. Gradual typing's autopsy adds:
no programmer control, no annotations-as-enforced-contracts (Siek & Taha 2006;
Siek, "What is Gradual Typing", https://jsiek.github.io/home/WhatIsGradualTyping.html).
Notably the Cartwright/Fagan retrospective itself contains no mea culpa — it reads
as a success story (influence on exception analysis, occurrence typing); the
"death" verdict is entirely the successors'.

Does the killer apply? Three components, separable:
1. **Illegible findings** — mostly pre-answered: the design requires a WITNESS for
   every wrong verdict (finding strength = witness-status × credence), which is
   exactly the fix the field itself made (SBA flow paths). Non-witnessed output is
   confined to "undecided."
2. **Brittleness of inferred facts under small edits** — LIVE THREAT. Mined beliefs
   are inference by another name; if a small semantically-neutral edit reshuffles
   the mined-belief pool, findings churn exactly as Soft Scheme's types did. The
   design has no stated stability/locality story. This is the single most
   frame-threatening carry-over.
3. **Adjudication burden** — LIVE THREAT, second order. Soft Scheme died because
   every flag was "maybe a false positive" and the programmer was the triage
   function. The design's "undecided" bucket recreates this unless credence-ranked
   reporting actually suppresses/deprioritizes low-grade undecideds; an
   undecided-flood is the same time-sink failure mode.
Also a soundness note: soft typing could afford never-reject WITHOUT lying because
inserted runtime checks caught whatever inference missed. A report-only never-reject
system forfeits that backstop — its "fine" is only as good as the pool. The graded
(non-absolute) verdict semantics already owns this, but it should be owned
explicitly: the design's "fine" is soft typing's "check eliminated" minus the
safety net.

## (c) Graded provenance / mined beliefs / hypothesis-obligation law precedents?

- **Graded provenance**: none anywhere in the family. All constraints are equal;
  no credence, no source classes. (There is a faint shadow in Soft Scheme's output
  ranking — primitive checks vs. likely-error flags — but it is reporting polish,
  not semantics.)
- **Mined beliefs**: strong precedent. Conditional types (Aiken 1994) and Rice
  if-splitting → occurrence typing mine the code's own guards. But mined facts are
  infallible constraints there, never fallible graded assumptions that can lose a
  consistency contest.
- **Hypothesis/obligation law**: no analogue, structurally impossible — the family
  admits no human claims at all (no annotations by premise), so nothing ever enters
  as a hypothesis needing independent discharge. The law is genuinely novel
  relative to this family.

## Sources

- Cartwright & Fagan, Soft Typing, PLDI 1991: https://dl.acm.org/doi/10.1145/113445.113469
- Cartwright & Fagan, Retrospective (20 Years of PLDI): https://www.cs.rice.edu/~javaplt/papers/sigplan39-4.pdf [full text extracted]
- Wright & Cartwright, TOPLAS 19(1) 1997: https://dl.acm.org/doi/10.1145/239912.239917
- Aiken, Wimmers, Lakshman, POPL 1994: https://dl.acm.org/doi/10.1145/174675.177847
- Tobin-Hochstadt & Felleisen, Typed Scheme (HOSC/arXiv): https://arxiv.org/pdf/1106.2575 [§9.1 full text extracted]
- Siek & Taha 2006 characterizations: http://scheme2006.cs.uchicago.edu/13-siek.pdf ; https://jsiek.github.io/home/WhatIsGradualTyping.html
