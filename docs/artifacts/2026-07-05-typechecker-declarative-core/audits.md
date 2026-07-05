# Audit findings — condensed, with provenance (2026-07-05)

All items [AUDIT-FINDING] unless marked otherwise. Disk sources are full
agent transcripts under
`/tmp/claude-1000/-home-me-git-rhizone-crescent/882b7410-8eb6-440b-abe2-10b3d26970b8/tasks/`
(ephemeral; the load-bearing content is transcribed here). Findings 1–3 and
the era comparison were foreground audits relayed by the orchestrator as
verbatim summaries — not independently re-verified from disk.

## 1. Derivation audit (foreground)

The sketch has a spine: "prove, at gate latency, that behavior contradicts
intent — where intent comes from annotations, axioms, and the code's own
guards — and label everything unprovable as undecided." The core is mostly
bar-forced. Three non-derived grafts:

- **Uniformity class** — postmortem graft, contested.
- **Mined-beliefs channel** — one option presented as required. NOTE: later
  session work made mined assumptions central to the certified formulation
  (one of the three ungraded-equal sources), so this graft-flag is partially
  superseded.
- **Differential-testing shape of the evaluator** — a process countermeasure
  encoded as architecture.

## 2. Concept-hygiene audit (foreground)

~20 nouns for ~6 roles. judge = solver. The chain
claim → refutation-query → candidate → checker-complaint →
residual-obligation is one thing stage-renamed. "Two claim streams" is a
false symmetry — only one stream emits claims. Two different things are
each called "the both-ways audit." Undefined load-bearing terms: candidate,
forward slop, graded witness, small-theory interface.

## 3. Era comparison v1→v9 (foreground)

- v1 died of order-dependence (documented in typechecker-v3.md); v3 died of
  scheduling (D6 "Wrong"); v4 died of ad-hoc accumulation; v5/v6/v7/
  framework/agnostic died WITHOUT contact (5 of 10 eras never falsified);
  v9 died procedurally per the postmortem.
- Against the postmortem's five procedural killers, the sketch has:
  ad-hoc-at-contact = structural-partial; terminal states = NOTHING
  (dominance bars re-import the killer); ritual multiplication = nothing;
  verification-tail = nothing; plausibility loops = stated intention only.

## 4. Paradigm placement (agent acbbde2dfc8cee494, on disk)

- Verdict: none of HM/MLsub/Prolog/SMT is the genus. The design is "model
  checking's problem statement solved with abstract interpretation's engine
  with an SMT-shaped refutation subroutine." Claim layer ≈ LTL-adjacent
  (□/◇, counterexample traces); fact engine is Cousot vocabulary verbatim;
  small theories ≈ Nelson-Oppen-style combination used the way symbolic
  execution uses SMT. HM matches least — what the owner reaches for from HM
  is the declarative/algorithmic split itself, which is exactly hole H1.
- H1 middle layer's prior-art shelf is the AI/verification shelf, not HM's:
  Cousot's calculational abstract-interpretation framework; 3-valued /
  abstract model checking (Bruns–Godefroid; Clarke–Grumberg–Long); O'Hearn
  incorrectness logic — Hoare proves fine / incorrectness proves wrong = the
  verdict table stated as proof systems.
- Bidi adjudication (same agent, later round): bidirectional checking
  (Pierce–Turner; Dunfield–Krishnaswami ⇑/⇓) is the right name for one layer
  only (boundary/annotation discipline); no assumption mining, no global
  consistency pool, wrong rejection semantics for the whole. Composite named
  as: bidi-shaped boundary audit + Dialyzer-genus interior + verification-
  shelf verdicts.
- Annotations-collapse (same agent, final round — the load-bearing verdict):
  all three annotation-specific distinctions killed (both-ways = two pool
  entries sharing provenance; certification not stated-only; assume-
  guarantee = banned propagation vocabulary, residue = the hypothesis role
  in Γ). Result: two layers + one role bit; the one law = a hypothesis must
  independently survive as an obligation. Full chain transcribed in
  `declarative-design.md`.

## 5. Falsifiability audit (agent a9c1a6ad4033e1f7d, on disk)

- Load-bearing risky assumptions A1–A7: A1 dominance-at-screen-cost (only
  evidence: v9 smoke ~1.5k files, cost only; dominance itself pure hope);
  A2 refutation chase converts in budget (no evidence; "this is the spine");
  A3 behavior-statement output producible end-to-end (no finding ever
  derived); A4 pins can be firewalls AND audited (unresolved tension, no
  worked example); A5 undecided volume tolerable (no evidence); A6 the
  abstraction gap (differential testing never touches the abstraction/
  widening itself); A7 the uniformity/hyperproperty framing (OPEN; kills a
  class, not the architecture).
- Corrected kill-order (after rejecting hand-run-on-paper as sufficient for
  A2): (1a) expressibility-by-inspection on 5 real git-history bugs + 5
  legacy false positives — days, first; (1b) chase convergence requires a
  human hand-run or a minimal real solver — "an LLM simulation is the
  plausibility engine and counts as no evidence," so A2's cheapest lethal
  test costs a small build (lib/json screen prototype growing a minimal
  chase), merging with the screen-cost and dominance tests.
- Architecture-fixable classification: only A4 is cleanly architecture-
  fixable, plus the theory-set half of A2. Five and a half of seven are
  bars- or problem-level (A1, A3 bars; A5, A6 problem; A7 bars-or-problem;
  A2's Rice floor). All three late residuals (form coverage, budget×
  precision at scale, ad-hoc-at-contact) are not architecture-fixable.

## 6. HM/MLsub/MLstruct comparison + concession rounds (agent a375512c62af61986, on disk)

- Fair-fight round: HM ≈ 6 rules; MLsub ~10 declarative but thesis-scale
  machinery; MLstruct largest. All three fail B1 (behavior statements)
  structurally and B3 (flow/mutation truths) at least extensibly. The bar
  delta maps almost completely onto the 9-part design; the one contestable
  part is the dual forward+backward architecture (Astrée is forward-only;
  Infer is one mechanism). HM's simplicity is purchased by refusing
  B1, B3, B4, half of B5, and the sole-gate half of B2.
- Concession round 1 (multi-return/metatables): "unrepresentable" was
  overclaimed → correct claim is representable-with-known-extensions whose
  sum is Luau-scale (variadic packs; type classes/rows), plus two genuinely-
  outside residues: `select('#')` reflection and aliased metatable mutation
  (flow, not structure).
- Concession round 2 (operators-as-calls): holds-only-for-polymorphic.
  Monomorphic operator sites typecheck as ordinary application (full
  concession); polymorphic `+` has no HM principal type without classes/
  intersections/row-constraints; mixed-type dispatch is type-directed
  desugaring. Complexity-class accounting unchanged.
- Concession round 3 (repo generics count): ~15 annotated generic functions
  in the repo; ~90% (13/15) opaque-parametric and plain-HM-survivable; 0
  operator-touching unconstrained; 2 already-constrained. Owner's "we lose
  ALL generic functions" inaccurate for this repo, directionally right for
  the language.
- [OWNER-CERTIFIED] The owner ruled the repo-count irrelevant to the
  ambition: the design bar is set by the language and the goal, not by the
  current repo's annotation population.
