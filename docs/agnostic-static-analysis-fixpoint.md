# Agnostic Static Analysis: Cyclic / Fixpoint-Evidence Validation

Status: validation design pass (mechanized).

This document instantiates `docs/agnostic-static-analysis-object-model.md` with a
minimal dataflow semantics whose claims are *mutually dependent* and whose joint
consistency is certified by a fixpoint witness. Its purpose is to answer, against
running code, whether the substrate's claim / evidence / dependency model can host
cyclic (fixpoint) evidence without learning what a solver, lattice, iteration, or
transfer function is.

It is scheduled **before STLC** deliberately (ladder rung 3). Every example through
the propositional and lambda rungs relies on *acyclic* evidence — a derivation that
bottoms out at axioms/artifacts with no claim depending (transitively) on itself. A
fixpoint witness breaks that assumption. Discovering the break after STLC would
invalidate the STLC pass, so the probe runs first (substrate before consumers).

This is not a typechecker, a dataflow framework, or a solver. It is a hosted
semantics that happens to reason about a tiny graph.

## Why This Semantics

The rung needs the *smallest* semantics that genuinely forces mutually-dependent
claims. Candidates considered:

- **Definite initialization over a CFG.** Forces dataflow, but the lattice is
  richer (must-vs-may) and the join is subtler than needed to exert the cyclic
  pressure. More machinery than the question requires.
- **Forward reachability over an explicit directed graph (chosen).** The transfer
  rule is the simplest non-trivial one — `reachable(n)` iff `n` is a source or some
  predecessor is reachable — and a graph cycle `a -> b -> a` makes `reachable(a)`
  and `reachable(b)` *genuinely mutually dependent*: each justifies the other.
  This is the minimal shape that breaks acyclic evidence. Anything smaller (a DAG)
  stays acyclic and exerts no pressure.

So the semantics is `dataflow.reach.min`: reachability over a tiny node/edge/source
graph artifact. The cycle is the point.

## The Bet, Stated Precisely

The design's bet (design doc, open question 5) is that a fixpoint is expressible as
a **post-hoc witness**, not a computation the substrate performs:

1. An **untrusted producer** (a solver, a worklist iterator, anything) proposes a
   whole **assignment**: a map from node to asserted reachability. The substrate
   trusts none of how it was produced.
2. The hosted checker verifies **local consistency** of that assignment at *every*
   node against the transfer rule — reading the asserted values **from the witness
   payload**, never by consuming neighbour claims as premises. A node's asserted
   value must equal the join of its neighbours' *asserted* values.
3. That check is **acyclic by construction**: it reads the assignment and the graph
   and nothing else. There is no claim → claim input edge, even though the nodes are
   mutually dependent. The mutual dependency lives *inside* the single assignment
   the witness certifies.
4. Each per-node `reachable(n)` claim is then accepted by **projecting** the single
   accepted witness: its one dependency points at the witness claim, never at a
   neighbour `reachable` claim.

The whole cross-node coupling is thereby collapsed into one self-contained object
(the assignment) that one self-contained evidence method (`fixpoint_witness`)
checks. The substrate sees a witness claim with one artifact dependency, and N
projection claims each with one accepted-claim dependency on the witness. A DAG, not
a cycle.

## Semantics Entry

```text
SemanticsEntry {
  id = "dataflow.reach.min",
  version = "0",
  claim_predicates = [
    "fixpoint",
    "reachable",
    "not_reachable"
  ],
  observation_predicates = [],
  evidence_methods = [
    "fixpoint_witness",
    "witness_projection"
  ],
  trusted_methods = []
}
```

The substrate does not interpret these predicates. The dataflow semantics owns their
meaning. There is deliberately **no** `lattice`, `transfer_function`, `widening`,
`iterate`, or `solver` method — see Adversarial Checks.

## Artifact Shape

A graph artifact is plain `ArgValue` data:

```text
ReachGraph =
  { nodes:   [name, ...]
  , edges:   [{ from, to }, ...]
  , sources: [name, ...]      -- nodes reachable a priori
  }
```

The substrate stores it opaquely (artifact `content_ref`). It never learns these are
graph elements. The hosted checker *parses and validates* it at the boundary
(`parse_graph`), never casts — the same discipline prop/lambda established.

## Claim Forms

### fixpoint

```text
fixpoint(graph_ref, assignment)
```

The whole `assignment` (a map node → bool) is a simultaneous fixpoint of the
reachability transfer rule over the graph. This is the claim that carries the cyclic
content; the per-node claims are derived from it.

`assignment` is opaque to the substrate (`ReachAssign = { [name]: boolean }`). An
absent key means *undetermined*, not false (see Unknown Member).

### reachable

```text
reachable(graph_ref, node)
```

The node is reachable. Accepted only by projecting an accepted `fixpoint` that
asserts the node `true`.

### not_reachable

```text
not_reachable(graph_ref, node)
```

The node is not reachable. A **separate positive claim** — like lambda's
`free_in` / `not_free_in`. `unknown` for one is not acceptance of the other.

## Evidence Methods

### fixpoint_witness

Validates `fixpoint(graph_ref, assignment)`. Self-contained:

- reads the graph artifact and the assignment from the claim args;
- checks `is_fixpoint`: for every node `n`, `assignment[n]` is a determined boolean
  *and* equals `expected_reach(graph, assignment, n)` (the transfer rule applied
  using the assignment's own asserted values).

Dependencies:

- one `artifact_content` dependency on the graph. **No accepted-claim dependency on
  any neighbour** — this is the load-bearing point.

Rejection:

- a locally-inconsistent member (asserted value ≠ transfer-rule value) rejects;
- an undetermined (absent) member rejects (not a *total* fixpoint).

### witness_projection

Validates `reachable` / `not_reachable` by reading off a single node's value from an
accepted `fixpoint` claim.

Inputs:

- exactly one input: an accepted `fixpoint` claim over the same graph.

Dependencies:

- one `accepted_claim` dependency on the witness claim.

Rejection:

- input is not a `fixpoint` claim, or over a different graph;
- the witness does not determine the node;
- the witness asserts a value contradicting the projection (`reachable` over a node
  the witness says is false, or vice versa).

Scheduling:

- if the witness is not yet accepted, return `unknown` (retry next sweep), never
  `reject`. This is the lambda-rung lesson: a required-but-not-yet-accepted input
  yields `unknown`, so results are order-independent.

## Worked Examples

The graph used below (`cyclic_graph` in the tests):

```text
nodes   = [s, a, b, c]
edges   = [s->a, a->b, b->a]
sources = [s]
```

`a` and `b` are mutually reachable through the cycle; `c` is isolated. The unique
total fixpoint is `{ s=true, a=true, b=true, c=false }`.

### Acceptance (the cyclic fixpoint)

Claim: `fixpoint(g, { s=true, a=true, b=true, c=false })`.
Evidence: `fixpoint_witness`.

```text
accepted: fixpoint
dependencies(fixpoint): [artifact(g)]        -- NO claim->claim edge
trust_summary(fixpoint): [unverified_hosted_checker]
```

The cyclic `a <-> b` coupling is certified, but it appears nowhere as a substrate
dependency edge: it is internal to the assignment.

### Projection

Claims: `reachable(g, a)`, `reachable(g, b)`, `not_reachable(g, c)`.
Each accepted by `witness_projection` with the accepted `fixpoint` as its sole input.

```text
accepted: reachable(a), reachable(b), not_reachable(c)
dependencies(reachable(a)): [fixpoint]       -- points at the witness, not at reachable(b)
```

Every per-node claim depends on the **witness**, never on a neighbour — asserted by
the test that walks `dependency_graph` and checks each `accepted_claim` edge targets
the fixpoint claim.

### Unknown Member

Assignment `{ s=true, a=true, c=false }` — `b` is absent (undetermined).

```text
rejected: fixpoint              -- not a TOTAL fixpoint; diagnostic names node b
unknown:  reachable(a)          -- its witness was not accepted; never accepted, never rejected
```

The undetermined member is intrinsic to the assignment, not to scheduling, so the
outcome is **order-independent**: the test runs witness-first and projection-first
and gets identical accepted/rejected/unknown counts. This answers the rung's
unknown-propagation question: an undetermined witness member does not silently become
`false`; the witness fails to certify, and dependents stay `unknown` (never consumed
as proof), order-independently.

### Broken Witness (rejection)

Assignment `{ s=true, a=true, b=false, c=false }`. The producer *claims* simultaneous
consistency, but `b` has predecessor `a=true`, so the transfer rule expects `b=true`.

```text
rejected: fixpoint              -- locally inconsistent at node b
```

A second broken case: `{ s=false, ... }` denies a source node, expected `true` →
rejected at `s`. The checker trusts none of the producer's computation; it only
trusts its own local check, and the local check refuses.

A third: projecting `not_reachable(g, a)` off the *true* fixpoint (which says
`a=true`) rejects the projection — the witness contradicts it.

### Shuffled-Order Equivalence (acceptance)

The full example (witness + three projections) is submitted in four evidence orders,
including all-projections-before-the-witness. Every order accepts all four claims
(the worklist retries projections until the witness lands). Order-independence holds
for acceptance, not just for the unknown case.

## Adversarial Checks

### Do Not Promote Lattice / Transfer / Widening

Attempt: add `lattice`, `transfer_function`, `widening`, or `iterate` as substrate
vocabulary (an evidence method, a dependency kind, or an object field).

Rejected. None of these are substrate concepts. The substrate sees only: a claim with
opaque args, one evidence method that returns accepted/rejected/unknown, and
dependency records over the witness. The lattice (booleans under `false <= true`), the
transfer rule, and any iteration that produced the assignment are **entirely inside
the hosted checker and its untrusted producer**. The substrate's `evidence_methods`
set for this semantics is `{ fixpoint_witness, witness_projection }` — no solver
vocabulary appears. The registry would admit no `iterate` method because the contract
does not list one.

### Do Not Make The Substrate Iterate To A Fixpoint

Attempt: have the substrate compute the fixpoint (run the worklist *over node values*
rather than over evidence acceptance).

Rejected. The substrate's worklist is over **evidence acceptance** (which evidence can
fire given what is already accepted) — a generic, semantics-agnostic loop that exists
for prop and lambda too. It is *not* a dataflow iteration over lattice values. The
node-value fixpoint is computed by the untrusted producer and merely *checked* by
`is_fixpoint`. The substrate never widens, never joins, never iterates a transfer
function.

### Do Not Promote Cyclic Dependency Edges

Attempt: record `reachable(a)` depends-on `reachable(b)` depends-on `reachable(a)` as
substrate `accepted_claim` edges.

Rejected, and structurally impossible in this semantics: projections depend only on
the witness. See Design Pressure.

## Design Pressure Found

This is the honest report the rung exists to produce.

### 1. A fixpoint IS expressible as a post-hoc witness — the substrate needed no change.

The substrate (`init.lua`) was **not modified**. The witness model fit the existing
object model exactly: one `fixpoint` claim accepted by a self-contained evidence
method, N projection claims each with a single accepted-claim dependency on the
witness. The 72 prior assertions still pass; the rung adds 36 (108 total). The bet
held against running code.

### 2. The `Dependency` shape needs nothing new; `A -> B -> A` never appears.

The rung's second load-bearing question — what must `Dependency` express for
mutually-dependent claims, and does `A -> B -> A` need to appear — answers cleanly:
**it does not appear at all**. Every dependency points at the witness. The existing
`Dependency.kind = accepted_claim` (projection → witness) and `artifact_content`
(witness → graph) classes suffice. The mutual dependency is real but is *content of
the certified assignment*, not a substrate edge. This is the structural reason the
witness model is sound: it converts a cyclic justification into an acyclic check of a
single proposed solution.

### 3. Cycle-detection-as-error did NOT need to change, and must not.

The rung's third question — does the substrate's cycle-detection-as-error behaviour
need to change — answers **no**, and the doc records why that is the right answer for
*all* static analysis, not just dataflow:

- The new evidence form (`fixpoint_witness`) introduces no claim → claim input cycle,
  because it reads asserted values from its own payload. So cyclic dataflow does not
  require the substrate to *accept* an evidence cycle.
- A genuine evidence cycle (evidence whose inputs trace back to its own claim, with no
  accepted base) still means *the producer failed to supply a base case*, and is
  still correctly an error. The dataflow rung does not change that: it routes the
  cyclicity into a witness *instead of* leaving it as an evidence cycle. The lesson
  generalizes: a sound analysis that needs cyclic reasoning supplies a checkable
  witness of the joint solution; it does not ask the checker to accept a circular
  justification. Cycle-detection-as-error stays the correct default for every hosted
  semantics, because an *unwitnessed* evidence cycle is exactly a missing base case.

The tests confirm both halves: an adversarial `reachable <-> reachable` wiring is
*rejected* (input is not a fixpoint claim) and terminates; the prop cycle probe still
emits a cycle diagnostic and accepts nothing, proving this rung left the detector
untouched.

### 4. The witness model is structurally incapable of forming a claim cycle here.

An honest negative finding: under `dataflow.reach.min` you **cannot** construct a
claim → claim evidence cycle. Projections depend only on the witness (a sink); the
witness depends on no claims (a source). The dependency graph is always a star: one
witness, N leaves. This is not a limitation to fix — it is the design's bet realized.
Any hosted semantics that needs cyclic reasoning is expected to do the same collapse:
move the cycle inside a witnessed object, leaving acyclic checks. If a future semantics
*cannot* perform that collapse — if it genuinely needs the substrate to accept a
circular justification — that is the finding that would force a new substrate evidence
form, and it must be justified for all static analysis then, not pre-reserved now.

### 5. Unknown under a fixpoint is order-independent and never coerced to false.

An undetermined witness member fails certification (the witness is not *total*), and
dependents stay `unknown`. The substrate's "unknown is never consumed as proof" rule
carries through unchanged: a projection off a non-accepted witness is `unknown`, not
`false`. The outcome does not depend on evidence submission order, because the missing
member is a property of the assignment, not of scheduling.

## Object-Model Changes

**None.** No field, kind, method class, or result class was added to the substrate or
the object model. The fixpoint rung is hosted entirely in `dataflow.lua` using the
existing `fixpoint`/`reachable`/`not_reachable` claim predicates, the
`fixpoint_witness`/`witness_projection` evidence methods, and the existing
`artifact_content` / `accepted_claim` dependency kinds. The object model's
`dataflow_fixpoint_witness` example evidence method (listed under `Evidence.method`)
is now realized by a concrete hosted semantics.

## Mechanization (lib/type/analysis)

- `dataflow.lua` — `dataflow.reach.min`: graph/assignment parsers, the transfer rule
  (`expected_reach`), the local-consistency check (`is_fixpoint`), and the checker.
- `dataflow_test.lua` — 36 assertions mechanizing every worked example: cyclic-graph
  fixpoint acceptance, projection with witness-only dependencies, the undetermined-
  member case (rejection + unknown projection + order-independence), three broken-
  witness rejections, shuffled-order acceptance equivalence, and termination of an
  adversarial cyclic wiring plus a re-assertion that cycle-detection-as-error is
  unchanged.

Full suite (`bin/cr test lib/type/analysis/`): 108 assertions, all passing (72 prior
+ 36 new).

## Next Pass

STLC, written against the running substrate. Only now — after the cyclic/fixpoint
probe confirms the substrate hosts mutually-dependent claims via post-hoc witnesses
without special pleading, and without changing the acyclic-evidence assumptions the
checker relies on — can STLC build on top. STLC may introduce hosted `type` claims but
must not promote `type`, `context`, `binder`, substitution, derivation replay, or any
solver vocabulary into substrate primitives.
