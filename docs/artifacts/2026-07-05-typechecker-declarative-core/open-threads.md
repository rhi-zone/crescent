# Open threads (2026-07-05)

Everything here is [OPEN] — unresolved as of session end. Nothing below is
certified; the certified formulation is in `declarative-design.md`.

- [OPEN] **H1 — the middle derivation layer.** There is no declarative
  derivation system between the semantics (`⊨`, undecidable) and solver
  machinery; `undecided` is undefinable without it (H2), and the
  ◇-refutation witness object (evidence for refuting ◇-claims, e.g. dead
  code — a universal-absence proof, not a trace) is undefined (H3). Prior-
  art shelf named by the paradigm audit: Cousot's calculational abstract-
  interpretation framework; 3-valued / abstract model checking
  (Bruns–Godefroid; Clarke–Grumberg–Long); O'Hearn incorrectness logic
  (Hoare proves fine / incorrectness proves wrong = the verdict table as
  proof systems).

- [OPEN] **Uniformity class.** The owner's standing objection to the
  2-safety hyperproperty framing — verbatim response: "seems wrong" — is
  unresolved. The property cannot be expressed in the single-trace claim
  grammar (draft hole H4): either the claim language gains hyper-claims
  (satisfaction over trace pairs) or uniformity lives outside the core.

- [OPEN] **Mined-beliefs presupposition catalog unwritten (H5).** The
  certified formulation makes mined assumptions one of three equal sources,
  but the catalog judgment "form F presupposes φ" exists only as two
  examples (dereference ⇒ non-nil; guard ⇒ both branches believed
  reachable). Declarative in kind; not written.

- [OPEN] **The process-killer gap.** Terminal states, increments, and
  banking are absent from all design material and were untouched by today's
  session. Per the era-comparison audit, against the postmortem's five
  procedural killers the design has: terminal states = nothing (dominance
  bars re-import the killer), ritual multiplication = nothing,
  verification-tail = nothing, plausibility loops = stated intention only.

- [OPEN] **Bar negotiability — the Dialyzer point.** A consistency-only
  design (Dialyzer-genus, no verification side) keeps lie-findings,
  behavior-statement output, and never-reject — but gives up proven-fine
  entirely (nothing certified, only not-yet-contradicted) and the
  dominance-over-tsc-truths bar (success-typing over-approximation
  structurally misses true errors). The owner has not ruled on whether any
  bar is negotiable.

- [OPEN] **Admissible convergence evidence.** [OWNER-CERTIFIED rejection]
  LLM-solver-simulation is not admissible evidence — "an LLM simulation is
  the plausibility engine and counts as no evidence." Convergence evidence
  for the refutation layer requires a human hand-run or a real (minimal)
  implementation. What that minimal implementation is remains open (the
  falsifiability audit proposed a lib/json screen prototype growing a
  minimal chase over 5 real bugs + 5 legacy false positives).
