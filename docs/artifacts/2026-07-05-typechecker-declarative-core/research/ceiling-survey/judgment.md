# Judgment: ceiling-survey proposals

Adversarial judgment of five anonymous entries against the problem statement: sound
static establishment of every computationally establishable true claim about real
programs' behavior, with everything beyond explicitly surrendered — never silently
missed or faked.

Entries (by filename, treated as anonymous): **V** (proposal-verification.md),
**AI** (proposal-abstract-interpretation.md), **ENG** (proposal-engineering.md),
**FP** (proposal-first-principles.md), **E** (proposal-e.md).

## 1. Convergence analysis

Independent convergence is evidence a design element is forced by the problem, not
chosen by taste. The convergent elements:

1. **Three-valued verdict type as an architectural fact, not a reporting convention.**
   PROVED / REFUTED / SURRENDERED (V, AI, ENG, FP) or consistent / contradicted /
   undecided (E). 5/5. Every entry independently concludes that "never silently missed
   or faked" is a property of the *output type*: a two-valued tool must lie or retreat
   from the ceiling.
2. **A single mechanized operational semantics as sole ground truth.** V-C1, AI-C0,
   ENG-A, FP-A, E-C1. 5/5. "Sound" and "true" are meaningless except relative to one
   fixed semantics; multiple informal models silently prove different theorems.
3. **Surrender as a first-class, machine-readable artifact carrying the residual
   obligation and reason class.** V-C6 ledger, AI-C5 ledger, ENG-B stored queryable
   verdicts, FP Open(receipt). 4/5 strongly; E has per-claim `undecided` but no ledger
   machinery.
4. **Small trusted certificate-checking kernel; provers are untrusted heuristic
   engines.** V-C5, AI-C6, FP-B. 3/5 fully; ENG substitutes differential testing
   against the semantics (weaker — see review); E has nothing here.
5. **Dovetailed prover/refuter pair — proof search and counterexample search run
   concurrently, so every claim establishable either way is eventually settled.**
   V-C3 refuter, AI-C4(a), ENG-E, FP-C. 4/5. E's contradicted-with-witness gestures
   at it without the dual enumeration.
6. **Portfolio of methods, no single algorithm; cheap volume tier feeding expensive
   per-claim tiers.** V-C3, AI-C2/C3, ENG-D, FP-E/F. 4/5.
7. **Environment (FFI, eval, I/O) as explicit, versioned assumptions attached to every
   dependent verdict.** V-C7, AI assumption ports, ENG-F, FP-H trust ledger; E partially
   via Γ-hypotheses. 4.5/5.
8. **Human as untrusted hint supplier — input is always machine-checked, never
   believed; wrong hints cost completeness, never soundness.** 5/5 (V §3, AI §3,
   ENG §3, FP §3, E §3). The strongest full-house convergence besides the verdict type.
9. **Instance-level decidability as the answer to Rice: real programs are not
   diagonal adversaries; the game is deciding *this* program, not the uniform
   problem.** Explicit in V §0 and FP §0; implicit in AI's repair loop and ENG's
   escalation ladder. 4/5.
10. **Budgets make the realized frontier resource-indexed; "couldn't afford it" must
    never be disguised as "uncomputable."** V, AI, ENG, FP. 4/5.
11. **Self-diagnosed killer risk: the semantics–reality gap.** Named as a top failure
    mode by V(1), AI(2), ENG(1), FP(1). 4/5 — convergence even on where the design dies.

Verdict on forcedness: the verdict type, the single semantics, the surrender artifact,
the untrusted-human discipline, and the kernel/certificate split are forced by the
problem statement. Any composite must contain them.

## 2. Per-proposal adversarial review

### V (verification-tradition)

**Strongest unique contribution:** the composition argument. V alone argues that no
single frontier-reaching mechanism subsumes another and supplies the connective tissue
— the invariant blackboard (C4) where each prover consumes others' certified results —
plus industrial existence proofs (Astrée, SLAM2, Terminator) that each region near the
frontier is individually reachable. Others assemble portfolios; V explains why the
portfolio composes into more than its members.

**Most serious flaw:** the load-bearing element is the one V itself admits is least
buildable. Soundness = kernel-only holds only if every portfolio member emits checkable
certificates, and V concedes (failure 3) that extracting proof objects from industrial
engines is "brutally hard" and that under pressure the project trusts provers directly
— at which point soundness silently becomes the conjunction of five heuristic
codebases, the exact failure the architecture exists to prevent. The design's honesty
story survives; its soundness story is a promissory note on the hardest open
engineering problem in the field. Secondary: the blackboard creates cross-prover
fixpoint coupling with no confluence or reproducibility argument.

### AI (abstract interpretation)

**Strongest unique contribution:** the completeness-repair loop (C4). AI is the only
entry with a *theory of why an unknown occurred*: an alarm is evidence of domain
incompleteness, a repairable property (Giacobazzi–Ranzato–Scozzari complete shells;
local completeness, LICS 2021), not fate. Also unique: the exact-fixpoint zone (C2) —
where a decidable fragment admits an exact least fixpoint, widening would *itself* be
a silent miss. That observation directly services "every establishable claim" and no
other entry makes it.

**Most serious flaw:** the heart is a semi-procedure with no convergence story and no
at-scale deployment evidence. Least complete extensions can degenerate toward the
concrete domain; the repair loop's termination is exactly the undecidable thing; and
the local-completeness program it leans on is 2021–2022 theory with essentially no
industrial record. AI admits it: the headline promise is met "only in the limit," and
the entry itself names the spot "where the design most resembles marketing." Measured
against the statement, AI's distance-to-ceiling claim rests on the least-proven
machinery of the five.

### ENG (engineering-first)

**Strongest unique contribution:** the verdict lifecycle. Content-addressed claims
keyed by (property, code-hash, assumption-set), precise invalidation, diff-time-only
delivery, "no verdict is ever silently downgraded," and PROVED-UP-TO-BOUND as a
distinct honest verdict. No other entry notices that a *stale* PROVED is a fake — that
no-silent-faking is a property of the cache and the timeline, not just of the prover.
That is a real extension of the problem statement's mandate into the temporal
dimension.

**Most serious flaw:** it quietly abandons the ceiling. The ladder tops out at bounded
model checking plus human-supplied invariants; there is no dovetailed semi-decision
mode, no completeness-in-the-limit claim, no mechanism that even aspires to "every
establishable claim gets established." And its soundness discipline is the weakest:
differential testing of analyzers against a reference interpreter finds soundness bugs
but cannot establish soundness — it replaces the kernel/certificate discipline (which
3/5 entries independently found forced) with an empirical smoke test. ENG optimizes
adoption, a criterion the problem statement never mentions, and pays for it in both
dimensions the statement does mention.

### FP (first-principles)

**Strongest unique contribution:** the reframing that makes the ceiling precise. The
set of establishable claims is r.e. but not recursive, therefore the optimal tool is
an anytime *fair enumerator* of that set — not a decision procedure. From this FP
alone derives: the diagonalization argument that any fixed total analyzer misses a
true claim, forcing an open-ended, untrusted, kernel-laundered strategy library
(including learned/LLM strategies as *data, not architecture*); quantifier
stratification (Σ1/Π1/Π2) telling the scheduler which side of each claim is even
semi-decidable; hardness certificates in surrender receipts; and the human as the
axiom rule — the tool's non-computable extensibility escaping any fixed system's
Gödel ceiling. This is the tightest fit to the statement's ceiling clause of all five.

**Most serious flaw:** it proves honesty and punts usefulness — by its own admission
"the theory guarantees honesty, not usefulness." Fair dovetailing over
(claim × side × strategy) at the millions-of-implicit-claims scale of a real codebase
is combinatorially vacuous without a mass-production volume tier (V's abstract
interpreter role), which FP lacks; it has no heap/aliasing story, thin
compositionality, and concedes it may degenerate into "an expensive fuzzer plus
receipt printer." FP is a correctness proof for the *shape* of the tool, missing most
of the tool.

### E (consistency-of-beliefs)

**Strongest unique contribution:** the claim-population problem. Everyone else assumes
claims exist (harvested or user-written, flat and trusted-as-stated); E alone asks
where claims come from at annotation density zero and what to do when the
*specification lies*. Mined presupposition beliefs, credence grading, annotations as
high-credence-but-fallible pool entries, and the hypothesis/obligation law ("anything
assumed must independently survive as an obligation") — that law is a genuinely
load-bearing soundness invariant the other four would each benefit from stealing.

**Most serious flaw:** it forfeits the competition on its own terms, twice, by its own
hand. First, "no completeness is promised anywhere" — a direct abdication of the
statement's core mandate that every establishable truth gets established. Second, the
admitted missing middle layer: no derivation system, no proof objects, `undecided`
literally undefined ("neither verdict derivable" is vacuous without a derivation
relation), refutation of ◇-claims undefined, no heap model. E is a semantics of
verdict *meaning* plus an IOU for the entire analysis. It answers an adjacent, real
question — which contradictions to surface, under untrusted specs — not the question
posed.

## 3. Ranking

Criteria, derived from the statement in order: (a) soundness discipline — can a fake
PROVED occur, structurally; (b) distance-to-ceiling credibility — mechanism plus
evidence for approaching "every establishable claim"; (c) no-silent-loss enforcement —
is every miss forced into an explicit artifact; (d) honesty of the surrender story —
residual obligations, reason classes, no "budget" laundered as "uncomputable";
(e) buildability, tiebreaker only.

1. **V.** Best (b) of the five — existence proofs per mechanism plus the composition
   argument; full marks on (c)/(d); (a) strong on paper, gated on certificate
   extraction. Wins because it is FP's enumerator already instantiated with the actual
   known frontier-reaching engines.
2. **FP.** Best-founded (a) (kernel forced by diagonalization, not chosen) and the
   only principled account of *why* the ceiling is reachable in the limit and of
   escaping fixed-system Gödel limits (axiom rule); loses to V on (b) because the
   enumerator without a volume tier and heap story is credible only asymptotically.
   (V vs FP is close: V is the what, FP the why; V edges it on evidence.)
3. **AI.** Unique positive mechanism against silent loss (repair converts every alarm
   into an attack on incompleteness; exact tier refuses to widen where decidable) —
   arguably the best pure (c) — but (b) rests on unproven-at-scale theory and an
   admittedly divergent loop.
4. **ENG.** Excellent (c)/(d) machinery over time (staleness, downgrades, invalidation)
   but weakest (a) (testing in place of certificates) and no (b) story at all; it is a
   superb deployment shell around somebody else's prover.
5. **E.** Sole owner of claim provenance and spec-fallibility, but incomplete as an
   analysis architecture (no derivation layer) and explicitly non-compliant with the
   completeness mandate.

## 4. Dominance check

**No entry is strictly dominated.** Each owns at least one element no other covers:
V the blackboard composition; FP the r.e./fairness foundation, stratification, and
axiom rule; AI the repair loop and exact-fixpoint zone; ENG the verdict lifecycle and
temporal no-fake discipline; E claim mining, credence, and the hypothesis/obligation
law. **E comes nearest to dominated** — on every ceiling-facing criterion it is
covered better elsewhere — but its claim-population layer is a real hole in the other
four (V-C2's harvester is flat and trusts annotations), so it survives as a component
supplier rather than a contender.

## 5. Synthesis — best-achievable composite

- **Spine: FP.** Claims as quantifier-stratified sentences over one mechanized
  semantics; the tool is an anytime fair enumerator with dual prover/refuter search;
  soundness lives solely in a tiny certificate kernel; verdicts are
  Proved(cert) / Refuted(trace) / Open(receipt); the human is untrusted hints, budget
  authority, and the signed axiom rule.
- **From V:** the concrete portfolio as the strategy library's founding members —
  abstract interpreter as the mass-production volume tier, CEGAR/IC3, termination
  synthesis, WP→SMT — plus the invariant blackboard so certified partial results
  compose across engines.
- **From AI:** the completeness-repair loop as the response to every volume-tier
  alarm (refute, else repair the domain, locally), and the exact-fixpoint rule:
  never widen inside a decidable fragment.
- **From ENG:** the ledger substrate — content-addressed claims, assumption-set
  hashing, dependency invalidation, verdict-transition visibility, diff-scoped
  delivery, PROVED-UP-TO-BOUND as a distinct verdict.
- **From E:** the claim harvester upgraded with mined presupposition beliefs and
  credence-as-priority; annotations as fallible high-credence entries; the
  hypothesis/obligation law governing every assumption admitted anywhere.

**Open in all five:** (1) the semantics–reality gap — fidelity of the mechanized
semantics to FFI/eval/OS is unprovable from inside and every entry names it as its
likeliest death; (2) heap/aliasing under unrestricted dynamic mutation — only E even
names it, none has a mechanism; (3) the budget-vs-limit gap — every architecture
reaches the ceiling only asymptotically, and none can make the *realized* frontier
provably approach the computability frontier at feasible cost; (4) certificate
extraction from industrial-strength engines at acceptable engineering cost; (5)
surrender-flood economics — claim volume vs human hint throughput, where every entry's
honesty risks becoming honesty without adoption.
