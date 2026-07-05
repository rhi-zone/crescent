# Proposal: an engineering-first architecture for static reasoning to the computability frontier

Vantage: tech lead of a small team that must ship this and have it survive a real codebase.
Evidence base: Coverity's deployment retrospective ([CACM 2010](https://cacm.acm.org/research/a-few-billion-lines-of-code-later/), read via
[LWN summary](https://lwn.net/Articles/374255/)), Infer at Meta ([CACM 2019, "Scaling Static Analyses at Facebook"](https://dl.acm.org/doi/10.1145/3338112)),
SLAM/SDV ([CACM 2011, "A Decade of Software Model Checking with SLAM"](https://cacm.acm.org/research/a-decade-of-software-model-checking-with-slam/)),
Astrée ([the Astrée analyzer, ENS](https://www.astree.ens.fr/); [DASIA 2009 paper](https://www.astree.ens.fr/papers/DASIA-2009.pdf)).

The deployment record, compressed to four facts that force the design:

1. **Coverity**: false-positive rate above ~30% kills a tool. Users who don't understand a
   report mark it false even when it's a real bug; trust decays in a vicious cycle. Coverity
   chose unsoundness to survive. We refuse unsoundness, so we must make false positives
   *structurally impossible* rather than merely rare — which forces three-valued verdicts.
2. **Infer**: the same analysis that was ignored as a batch bug list got a **>70% fix rate at
   diff time**, delivered as a code-review bot on changed code. Compositional (summary-based)
   analysis is what made diff-time latency possible on tens of MLoC. This forces
   compositional summaries and diff-scoped reporting; batch mode is for dashboards, not humans.
3. **SLAM/SDV**: the model checker was maybe a third of the product. The rules for the Windows
   driver API, the environment model of the kernel, and the pushbutton harness were the rest —
   and were what made verdicts meaningful. This forces environment models and specs to be
   first-class, versioned artifacts, not an afterthought.
4. **Astrée**: zero false alarms was achieved only by narrowing the domain (synchronous
   control code, no dynamic allocation) and specializing abstract domains to it. The lesson is
   not "narrow your language"; it is that *precision is bought per-domain*, so the engine must
   be a portfolio of domains/provers with an escalation ladder, not one algorithm.

## 1. Architecture

**A. Semantics kernel.** One small, executable formal semantics of the language — the single
source of truth. Every analyzer is differentially tested against the reference interpreter
(millions of generated programs, continuously). Forced because: with multiple provers, the only
way "sound" stays true in year three is a shared oracle cheap to test against. This is the
anti-Coverity-drift mechanism; a soundness bug here is a sev-0.

**B. Claim ledger (the fact store).** The unit of the whole system is a *claim*:
`(property, code-region content-hash, assumption-set) → verdict`, where verdict is exactly one of
**PROVED** (with certificate or proof sketch), **REFUTED** (with a concrete, replayable
counterexample trace), or **SURRENDERED** (with a machine-readable reason: the specific program
point, the missing invariant/spec, or the exhausted budget). Verdicts are content-addressed and
versioned by (analyzer version, semantics version, assumption-set hash). Forced because:
incrementality is impossible without precise invalidation; trust is impossible without
reproducibility; and "explicitly surrendered" must be a *stored, queryable object*, not an
absence of output. The boring parts — cache keys, verdict versioning, invalidation on
dependency-hash change — are the product; a stale PROVED shown once destroys the tool.

**C. Compositional summary engine.** Per-function summaries (pre/post over the abstract
domains in play), computed bottom-up, cached by hash of the function body plus callee-summary
hashes. Forced by Infer's result: this is the only architecture with demonstrated diff-time
latency at MLoC scale, and diff-time is the only delivery channel with a demonstrated fix rate.

**D. Prover portfolio with an escalation ladder.** Cheap to expensive, each rung consuming the
previous rung's failures: (1) flow/type-shaped analysis; (2) abstract interpretation over a
reduced product of domains, Astrée-style, with domains pluggable per property class;
(3) compositional separation-logic/bi-abduction for heap and resource properties; (4) bounded
model checking / symbolic execution (CBMC/kani-style) for the claims the abstractions lost,
yielding either a bounded proof (recorded as PROVED-UP-TO-BOUND, a distinct, honest verdict) or
a counterexample; (5) an interactive-proof escape hatch where a human supplies an invariant and
the tool *checks* it. Forced because no single technique's precision/cost point covers the
frontier; every deployed success specialized, and a portfolio is how you specialize without
forking the product.

**E. Refutation engine.** Every failed proof attempt is immediately handed to directed
testing (fuzzing/concolic seeded by the abstract counterexample). Forced because the difference
between "REFUTED with a trace you can replay" and "warning" is the difference between the
>70% fix rate and the ignored bug list; a claim should leave the SURRENDERED bucket in either
direction automatically whenever compute allows.

**F. Boundary models.** The environment — I/O, FFI, `eval`, the runtime's own C surface — gets
explicit, versioned models with named assumptions, SLAM/SDV-style. Every PROVED verdict carries
the assumption-set it depends on; changing a model invalidates exactly the dependent claims via
the ledger. Unmodeled boundary calls don't weaken verdicts silently — they force SURRENDERED
with reason `unmodeled-boundary(<call>)`.

**G. Orchestrator.** Budgets compute across the ladder, schedules re-proof on diffs first,
burns background compute on the surrender ledger (oldest and hottest-code claims first), and
never blocks a commit on anything but rung-1/2 latency.

## 2. The frontier as shipped UX

The computability frontier is not an error state; it is a *first-class dataset with a burn-down
UI*. Concretely:

- The surrender ledger renders like coverage, not like alarms: "this module: 96.2% of generated
  claims proved, 0 refuted, 41 surrendered — 29 need a loop invariant, 8 blocked on unmodeled
  FFI, 4 budget-exhausted (retryable)." Nobody is accused; nothing floods.
- **Diff-time is the only push channel.** The author of a change sees exactly: new REFUTED
  claims (with replayable trace — these are bugs, full stop) and *newly* surrendered claims
  their change introduced. Pre-existing surrenders never appear in review. This is the direct
  transplant of Infer's one proven delivery mechanism.
- Every SURRENDERED item states what would resolve it, in order of cheapness: "give me an
  invariant here," "model this FFI call," "raise the bound," "this is genuinely
  Rice-territory (property depends on `eval` of runtime input) — suppress-with-signature or
  add a runtime monitor." Suppression is a signed, versioned assumption in the ledger, not a
  comment that rots.
- No verdict is ever silently downgraded. If an analyzer regression makes a previously PROVED
  claim unprovable, the ledger shows the transition and who/what caused it.

## 3. The human's role

Humans supply exactly the inputs the frontier makes uncomputable, and nothing else: (a) the
properties worth claiming (specs), (b) invariants and boundary models when the ladder asks,
(c) the priority order for burning down surrenders, (d) signed acceptance of residual
assumptions. Humans never triage false positives — that job class is abolished by construction
(three-valued verdicts admit no "probably wrong" output). Human-written invariants and models
are *checked*, never trusted: an invariant is verified inductive before use; a boundary model
ships with generated runtime monitors so production traffic continuously tests it. The human is
a spec author and an assumption signer — the two roles Coverity's data says humans will
actually perform, versus alarm janitor, the role they demonstrably abandon.

## 4. Top 3 honest failure modes

1. **Boundary-model debt.** The SLAM lesson in reverse: models of the environment lag reality,
   and every stale model is a silent soundness hole wearing a PROVED badge. Mitigation is the
   runtime monitors and model versioning, but a team that stops paying this tax ships a liar.
   This is the most likely way the tool dies while appearing healthy.
2. **The surrender ledger becomes wallpaper.** If surrenders accumulate faster than background
   compute plus human invariant-writing retires them, the coverage number plateaus, leadership
   reads it as "the tool can't do it," and we've rebuilt Coverity's ignored bug list with
   better typography. The diff-time gate contains the damage but doesn't fix legacy code.
3. **Ledger/invalidation bugs.** One user who reproduces a stale PROVED — a cache key that
   missed a dependency, a summary not invalidated across a semantics bump — loses trust
   permanently, and per Coverity's data, trust does not come back. The mitigation (differential
   testing against the kernel, conservative over-invalidation) costs us the latency we bought
   with compositionality; this tension never fully resolves.

Sources actually consulted: [Coverity CACM retrospective](https://cacm.acm.org/research/a-few-billion-lines-of-code-later/) (via [LWN](https://lwn.net/Articles/374255/) and search excerpts; cacm.org blocked direct fetch), [Scaling Static Analyses at Facebook](https://dl.acm.org/doi/10.1145/3338112), [A Decade of Software Model Checking with SLAM](https://cacm.acm.org/research/a-decade-of-software-model-checking-with-slam/), [Astrée](https://www.astree.ens.fr/) / [DASIA 2009](https://www.astree.ens.fr/papers/DASIA-2009.pdf).
