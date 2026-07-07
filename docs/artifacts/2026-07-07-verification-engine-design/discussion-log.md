# Verification-engine design discussion — 2026-07-07

Informal design conversation between owner and orchestrator, following the
prior-art survey in `../2026-07-07-verification-prior-art/`. Records owner
rulings (binding) and orchestrator framings (UNVERIFIED — most stated from
memory, flagged "check later"; a companion verification pass lives in
`./reasoning-verification.md`). Cross-refs:
`../2026-07-05-typechecker-declarative-core/{declarative-design.md, design-pass-abstract-kernel/synthesis.md, open-threads.md}`.

## Owner rulings (binding)

1. No vendoring of Z3/cvc5-class solver binaries — ruled out regardless of
   the `dep/` FFI carve-out. (Recorded also in
   `../2026-07-07-verification-prior-art/placement.md`.)
2. If an SMT-grade tier is ever built, it must be a pure-Lua implementation
   (standard tier rules: pure-Lua baseline, no hard dep on system/vendored C
   libs).
3. Timeouts-as-surrender are unacceptable. Budget exhaustion must NOT
   discard work. Budgets must be able to vary AND accumulate across contexts
   (interactive < pre-commit < overnight) against the SAME claim, with
   progress carried over. Implication discussed: `Open(receipt)` becomes a
   resumption token / checkpoint, not an apology; progress monotone across
   sessions; nothing paid for twice. (Owner's specific objection: not
   nondeterminism, but the inability to have varying budgets — a timeout
   throws away paid work.)
4. Typechecker-shaped claims must run at typechecker SPEED as an
   ALGORITHM-PERFORMANCE property, not as a compute-rationing/budget
   outcome. Consequence discussed: the fast floor must be discharged by
   dedicated native algorithms (unification as real unification,
   subtype-checking as a real structural walk), plugged in as producers —
   NOT by encoding typing rules as data for a generic engine to evaluate.
   Evidence cited: unoptimized datalog ~1000x slower than optimized at
   identical semantics (Doop paper); QL ~4x slower than handwritten analysis
   at scale (ECOOP 2016).
5. No hardcoded "typechecker-shaped" boundary by fiat. Owner is unconvinced
   that hardcoding a fragment boundary is a good idea. Reconciliation
   discussed: fragment fast-paths must be admitted by a CHECKABLE STRUCTURAL
   PROPERTY (a producer declares + demonstrates what it decides), never
   keyed to a name/identity/file. Discriminator: is the special case entered
   by a checkable structural property (legitimate — a tier being born) or by
   recognizing an individual (banned — the v1→v4 ad-hoc disease)?
6. Claim/site identity should be STRUCTURAL, not positional. declc currently
   uses site = "file:line", which breaks structural-sharing memoization (a
   comment added at the top of a file re-keys every claim below it). Owner's
   hot take: disk memoization makes most re-typechecking free IF it is
   specifics-agnostic (structural sharing). Noted convergence: this is the
   SAME object as the meeting-problem / Hole H1 seam from the 2026-07-05
   work.

## Orchestrator framings (UNVERIFIED — stated from memory, pending ./reasoning-verification.md)

- [UNVERIFIED] Typecheckers vs SMT are one algorithm family, not two
  architectures. Typechecker algorithms (unification, biunification/MLsub,
  datalog, abstract interpretation) are CLOSURE engines: forced steps, run
  to fixpoint, polynomial, because their fragments have principal solutions
  (no forced choice → no search). SMT's core (DPLL(T)/CDCL(T)) is a SEARCH
  loop wrapped around closure engines; the theory solvers inside (congruence
  closure, simplex) are themselves saturation procedures. What forces the
  wrapper is boolean disjunction (x=1 ∨ x=2 has no most-general solution →
  case-split → exponential). The architectural distance between tsc and Z3
  is exactly: what happens at a disjunction.
- [UNVERIFIED] The fork at a disjunction: join (approximate — MLsub's
  lattice join, abstract-interp widening; fast, loses precision), split
  (enumerate exactly — SMT; pays exponentially), or give up.
- [UNVERIFIED] Alternatives to join/split/give-up, each with a distinct COST
  SHAPE (not just a different dial position): (a) defer/residuate — carry
  the disjunction symbolically, later facts may determinize it free (watched
  literals, CLP, typeclass deferral); (b) share instead of enumerate — BDDs,
  egraphs/equality-saturation hold all branches in one structure
  (memory-heavy, ordering-sensitive; NOTE: saturation-B's identity-merge
  failure in the hand-eval is this family's known failure mode); (c)
  sample/execute — resolve by concrete witness (run/fuzz/property-test);
  refutation-shaped → slots into `Refuted(trace)`; crescent owns `lib/test`
  infra; (d) CEGAR join-then-refine — approximate, undo the join only where
  a counterexample proves precision loss mattered (pay per demonstrated need
  — closest to "engine picks the tradeoff"); (e) k-bounded disjunction —
  keep k disjuncts exact, join beyond k (a literal numeric dial); (f)
  anytime fair enumeration — split but stream under budget, interruptible,
  monotone (== the FP spine in the ceiling survey); (g) residuate-to-runtime
  — emit a dynamic check (gradual verification / contracts); zero static
  cost, paid in runtime + late failure.
- [UNVERIFIED] No shortcut past the exponential: exact disjunction
  resolution is SAT (NP-complete); every technique above REDISTRIBUTES the
  cost (memory / precision / completeness / runtime / lateness /
  per-proven-need), none removes it. The only genuine "shortcut" is
  empirical, not algorithmic: real programs' disjunctions are shallow and
  structured, sparsely inhabiting the worst case — this is why CDCL eats
  industrial instances and why join-everything typecheckers rarely get
  caught.
- [UNVERIFIED] Memoization is amortization, not escape: CDCL clause learning
  is memoized refuted-subspaces; tsc caches subtype-pair comparisons; Infer
  reuses per-function summaries (cross-run = incremental checking, the
  biggest real-repo speed lever). Defeated by adversarial input, fed well by
  real code. crescent's declc ledger (content-addressed by code-hash +
  assumption-set, invalidation as logged event) is already
  claim-memoization infrastructure; the parked val-interning/hash-consing
  TODO is what makes cache keys cheap.
- [UNVERIFIED] Legitimate vs banned hardcoding (same as ruling 5's
  discriminator): structural fragment fast-paths (detect Horn / 2-SAT /
  difference-logic / disjunction-free, dispatch to the polynomial algorithm
  — SMT theory solvers ARE this) vs identity-keyed cases (rot under
  refactoring).
- [UNVERIFIED] Disjunction-policy framing (the orchestrator's candidate
  synthesis, explicitly speculative): one closure core over producer rules,
  where the per-claim DISJUNCTION POLICY is the dial — join
  (typechecker-fast), split-with-budget (SMT-grade), or refuse (`Open` +
  receipt naming the choice point that exceeded budget). "Routing" becomes
  selection of a policy over one engine's choice points, not dispatch across
  different engines; trust stays uniform because it's one kernel. Under this
  reading "tiers" may be the wrong concept — orderings emerge per-claim from
  cost declarations rather than being a designed ladder. Related
  distinctions surfaced: ladder (F*) vs portfolio/selection (SV-COMP) vs
  demand-driven decomposition vs per-claim dial (Verus "tunable automation"
  paper) — four different concepts currently sharing the word "tier".
- [UNVERIFIED] Checkpoints (from ruling 3) as first-class persisted state
  introduce a NEW trusted surface: a forged checkpoint is a new fake-Proved
  path and needs the same certificate discipline as verdicts. Precedent
  claimed (verify): incremental SAT keeps learned clauses across calls;
  CEGAR state resumes. Ledger keys (code-hash, assumption-set) are exactly
  checkpoint-validity conditions, so invalidation-on-change falls out rather
  than being new design.
- [UNVERIFIED] Structural-identity precedent claimed (verify): Unison
  (definitions identified by hash of structure, names are metadata, rename
  cannot invalidate), rust-analyzer salsa (query memoization with structural
  keys), GHC interface fingerprints.

## Compatibility with the certified core (descriptive)

- `Open(receipt)` is the natural escalation/resumption carrier (ruling 3).
- Producers are the natural home for native fragment dischargers (ruling
  4) — a discharger declaring "what I decide + what I cost" returning
  verdict-or-receipt is a producer wearing solver clothes.
- Ledger (code-hash, assumption-set) keys double as checkpoint-validity +
  memoization keys.
- Concrete conflict to fix: site = "file:line" violates structural sharing
  (ruling 6).

## #3 handoff seed — the site-identity design object

The one concrete design object every thread tonight converged on is that
claim/site identity must become structural rather than positional. It is
simultaneously (a) the meeting-problem fix (Hole H1 — independently-produced
claims meet iff structural identity coincides), (b) the
memoization/structural-sharing key (ruling 6, owner hot take), and (c) the
speed-floor enabler (structural keys make cross-time re-checking free). This
design pass is certification-layer surgery and should run in a FRESH
session, AFTER `./reasoning-verification.md` confirms-or-corrects the
[UNVERIFIED] framings this discussion leaned on — designing on unverified
foundations is the failure mode the surrounding sessions diagnosed. Inputs
for that pass: this file, `./reasoning-verification.md`,
`../2026-07-07-verification-prior-art/placement.md`,
`../2026-07-05-typechecker-declarative-core/{declarative-design.md, open-threads.md (H1-H5), design-pass-abstract-kernel/synthesis.md}`.
