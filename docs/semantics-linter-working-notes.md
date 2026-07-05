# Semantics linter — working notes (2026-07-05)

STATUS: record of an owner-led design conversation. NOTHING here is greenlit
for building. Several assistant framings were rejected mid-conversation and
are listed as dead below. One owner objection is OPEN and unresolved. Treat as
conversation state, not design truth.

## The definition (owner-set bars)

- "Lints the semantics": the object of analysis is what the code DOES —
  values, flows, effects at runtime. A finding is a statement about behavior,
  never about a formalism ("cannot assign A to B" is not a legal output).
- Sole static gate: it IS the replacement for the legacy checker
  (pre-commit/CI run it; gate = "no new findings"). No sidecar half-product.
- Stronger than SOTA typechecking: must not miss a single TRUE type error a
  SOTA flow-typing checker (with mutation support) would catch — dominance
  over truths, not over reports (matching tsc's truths while disagreeing
  exactly on its false positives).
- Coverage: MORE bug classes than SOTA checkers and linters combined (tsc +
  xo + oxlint), as dominance over the transferable class set plus extras
  (Lua-specific hazards, house discipline: caps-first, `(nil, errmsg)`
  convention, annotation lies), not raw count.
- Annotations are pins AND evidence, audited in both directions: an
  annotation that lies is itself a finding; behavior inference must be
  independent enough of annotations to contradict them.

## Architecture sketch (conversation state)

- Two claim streams + a judge. Behavior engine: an abstract evaluator shaped
  like Lua's actual evaluator (one case per language form, real evaluation
  order/scoping/multivalue rules, over value descriptions carrying
  provenance), annotation-blind, each form's case differentially testable
  against the shipped interpreter. Runs forward (may-facts) and backward
  (weakest-precondition-style interrogation per candidate).
- Intent stream, three channels: stated (`--:`/`--::` contracts compiled to
  claims), universal (axiom catalog: reaching the evaluator error state is
  unintended, code is meant to be reachable, values meant to be consumed,
  handles meant to close; plus house axioms), mined beliefs
  (guards/dereferences imply author beliefs; contradictions at belief
  strength).
- Claims: modal propositions about evaluation events — arrives(site, slot,
  V), happens/paired (effects), reachable/consumed, relates(f, R); □ (all
  executions) vs ◇ (some execution, with witness). Same annotation emits
  claims binding different parties (params bind callers, returns bind the
  body) — that split IS the both-ways audit.
- Solver: claim → refutation query → forward screen (empty intersection =
  sound discharge; discharged pins are a real product) → backward provenance
  chase accumulating conditions over small theories (tags, nilability, rows,
  aliasing union-find, guard comparisons) → conviction with witness / sound
  kill (localizes forward slop) / undecided with residual obligation. Chases
  terminate at annotated boundaries (assume-guarantee; pins are refutation
  firewalls). Budgets are the latency contract.
- Three verdicts (proven fine / proven wrong with graded witness / undecided)
  is where Rice's-theorem residue goes — undecided, labeled, never silently
  either way. Verdict grade = witness-condition status × intent strength
  (axiom > stated > belief); the gate is a cut in that product order.
- Fixpoints: localized at cycles (loop transformer, recursive SCCs, μ-shaped
  descriptions), widening for termination (analyzer totality is an invariant
  — adversarial input can force imprecision, never divergence); stated claims
  on recursive functions check coinductively (assume at recursive call sites)
  instead of iterating.
- Closed-world trade: evaluator shape synthesizes closed-world facts;
  open-world universals come from stated claims at boundaries or verdicts go
  undecided (structural pressure to annotate exports). What judgment-shaped
  checkers keep: decidability-by-construction, spec-as-rules, separate
  compilation. What they can't produce: behavior statements with provenance.
- Performance: forward screen carries the tsc-equivalent product at tsc-class
  cost (candidates ARE checker complaints); refutation is
  candidate-proportional, budgeted, staged off the latency path (gate answers
  at screen latency + in-window refutation; deep grounding continues
  async/CI). Cold full-tree deep runs are CI artifacts. Recorded v9 smoke
  numbers (~1.5k files/seconds-scale forward solve in LuaJIT) suggest the
  order of magnitude, cited as measurement not promise.

## The uniformity class (owner's take: the checker MUST cover this kind of linting)

Ad-hoc poisoning as a checkable class: uniformity claims — "behavior
independent of user-level name identity except via declared tables" —
formally noninterference with the declaration table as declassifier.
Module-level pin declares sanctioned channels. Three tiers: (1) structural
AST rule (name-literal comparison/indexing outside sanctioned tables) —
buildable immediately, standalone pre-commit check guarding the linter's own
construction; (2) behavioral property tests from the declaration tables
(fresh isomorphic entries must behave isomorphically; α-renaming
self-composition; lib/test fuzz/shrinking provides witnesses) — DYNAMIC,
exhibits violations only; (3) semantic dependence/label analysis in the
engine (labels cleared only at declassifier lookups; implicit flows tracked
under labeled branches), refuter witness = the diverging renaming pair.

## OPEN OBJECTION (unresolved)

The assistant characterized uniformity-under-renaming as a 2-safety
hyperproperty (pairs of executions; outside single-run static analysis;
static routes = label/dependence analysis or self-composition at doubled
cost). The owner's response, verbatim: "seems wrong." NOT resolved — the next
session should re-derive whether the hyperproperty framing (and the
tier-2/tier-3 split it implies) is actually correct before building anything
on it.

## Dead framings (rejected mid-conversation, do not revive)

precision-first/abstention linter; witness/presence-prover as the gate
identity ("what a copout"); formal-semantics-grounded verdicts as the meaning
of "semantics linter"; "mutation × flow core" as an established object;
dataflow/"flow" as the presupposed analysis frame; "types as uniquely
human-writable"; "types as known-optimal summary compression"; "global
coherence obligation" as a real typechecker/flow distinction;
skolemization-avoidance via per-call-site reanalysis.

## Postmortem linkage

`docs/postmortem-agentic-sessions-2026-07.md` records why prior iterations
died procedurally (ad-hoc at contact; no terminal states; ritual
multiplication; verification-tail deaths; plausibility loops). The uniformity
class is the postmortem's countermeasure moved into the artifact. Bootstrap
order: tiers 1–2 exist before/while the linter is built; the linter absorbs
them as a catalog class.
