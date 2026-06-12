# Static Analysis Map

This document names the current static-analysis artifacts and their authority.
It exists to prevent old typechecker tracks from regaining authority by
accident.

## Status

Static analysis is not one linear `vN` track.

The current map is:

- `v4`: the running Crescent checker.
- `v5`: abandoned architecture and prior-art mine.
- `v6`: design exploration, not an implementation target.
- `v7_mr0`: prototype residue, not a product direction.
- `framework`: rejected proof/evidence direction, retained as prior art.
- `agnostic static analysis`: active design direction, not yet implemented.

No artifact becomes canonical merely because code exists for it.

## v4

`lib/type/static-v4/` is the checker that currently runs.

Authority:

- may be patched for concrete user-visible bugs;
- may be used as a behavior corpus;
- may be mined for feature inventory and failure cases.

Limits:

- not a model for the future architecture;
- not trusted as a soundness proof;
- not evidence that a feature belongs in the next system.

## v5

`lib/type/static-v5/` is abandoned.

Authority:

- useful for mining decisions, failed attempts, and test cases.

Limits:

- not a target for repair;
- not a source of architectural authority;
- not a reason to preserve operational-semantics machinery.

## v6

The v6 documents are design exploration.

Authority:

- useful as recorded reasoning and rejected/viable alternatives.

Limits:

- not an implementation target unless a later document explicitly re-adopts a
  piece with a project-relative reason;
- not a bridge from v5 to product code.

## v7 MR0

`lib/type/v7_mr0/` and the v7 MR0 documents are prototype residue.

Authority:

- evidence replay experiments;
- canonical serialization experiments;
- examples of premature theory-specific commitment.

Limits:

- dead as "the next Crescent typechecker";
- not a product direction;
- not a license to implement more v7 features.

Terms such as `scope_from` belong to this prototype/framework experiment space.
They should not drive implementation.

## Framework

`lib/type/framework/` and `docs/typechecker-framework*.md` are rejected as the
static-analysis direction.

Authority:

- useful for mining ideas about data formats, replay, canonicalization,
  evidence, and oracle boundaries;
- useful as negative/falsification material for a future static-semantics
  design.

Limits:

- dead as "the next Crescent typechecker";
- dead as the current type-system-agnostic framework direction;
- not a Crescent typechecker;
- not a source of Crescent semantics;
- not automatically the right architecture just because it is more general.

New framework implementation work should not happen. The active agnostic static
analysis direction must not inherit this artifact's assumptions, terminology, or
implementation shape by default.

Why it was rejected, what it had validated, and the substrate-independent
findings the agnostic direction must preserve:
`docs/typechecker-framework-postmortem.md`. The short version: rejected on
judgment of premature theory-specific commitment, not on a demonstrated defect —
it reached its STLC-capable binder-replay milestone with tests.

## Agnostic Static Analysis

The active design direction is a fully agnostic static-analysis substrate.
Entry point: `docs/agnostic-static-analysis-design.md`.

It is not a Crescent checker first. It should be able to host static semantics
for very small calculi, for conventional typed languages, and eventually for
Crescent/Lua. Crescent is a client and stress test, not the defining center.

Authority:

- should be designed from first principles rather than from v4/v5/v7/framework
  implementation residue;
- should treat v4/v5/v6/v7/framework material as evidence, examples,
  counterexamples, and prior decisions, not authority;
- should make language-specific semantics explicit as hosted definitions rather
  than built into the substrate.

Current status: the object model is settled
(`docs/agnostic-static-analysis-object-model.md`), the propositional,
untyped-lambda, cyclic/fixpoint-evidence, and STLC validation passes are written,
and **mechanization has landed through STLC**. The code lives in
`lib/type/analysis/`: the substrate (`init.lua`), four independent hosted
semantics (`prop.lua` = `prop.logic.min`, `lambda.lua` = `lambda.untyped.min`,
`dataflow.lua` = `dataflow.reach.min`, `stlc.lua` = `stlc.min`), and tests
(`prop_test.lua`, `lambda_test.lua`, `dataflow_test.lua`, `stlc_test.lua`,
`substrate_test.lua`, 153 assertions) that mechanize every worked example plus
the un-falsifiable-on-paper probes (claim identity, scheduling
order-independence, cycle termination, unknown propagation, adversarial
smuggling, fixpoint witnessing, deep derivation trees, claim-identity-under-
context). Mechanization findings are recorded in the object-model and four
validation docs. The STLC rung (`docs/agnostic-static-analysis-stlc.md`)
introduced the first hosted `type` vocabulary, typing contexts, and deep
derivation trees with **no substrate change** — types and contexts ride
`ArgValue` claim args, and structural substrate claim identity is exactly right
for context-dependent judgments. The tiny Crescent slice (ladder rung 5, the
final rung) is now **fully mechanized** (all four passes DONE, 2026-06-12) in
`lib/type/analysis/{slice_ty,slice_subtype,slice_ty_arg,crescent_slice,
crescent_slice_parse,slice_narrow}.lua` (+ tests), per
`docs/agnostic-static-analysis-crescent-slice.md` (`crescent.slice.v1`, the first
consumer of the ratified kernel). The §7 corpus grading run
(`lib/type/analysis/corpus_test.lua`) Accepts all 11 fixtures (0 errors), matching
every Expected Verdict, with no fixture-keyed carve-out and no substrate change.
**Mechanization through the whole ladder is complete**; `lib/type/analysis/`
now also holds the slice's six modules and a subtype benchmark.

Rung status (ladder, design doc):

- 1 propositional — mechanized.
- 2 untyped lambda — mechanized.
- 3 cyclic/fixpoint-evidence — mechanized (`dataflow.reach.min`); substrate
  unchanged, witness model holds.
- 4 STLC — mechanized (`stlc.min`); substrate unchanged. Hosted `type`
  vocabulary, typing contexts, and deep evidence trees all hosted; arg-schema
  open item closed (no schema mechanism, no identity override needed).
- 5 tiny Crescent slice — **mechanized** (all four passes DONE, 2026-06-12;
  `docs/agnostic-static-analysis-crescent-slice.md`, `crescent.slice.v1`). First
  consumer of the ratified kernel (`docs/decisions/kernel-recommendation.md`):
  bidirectional synth/check spine, ONE cycle-guarded equirecursive (hash-consed μ)
  subtype relation, local generic instantiation as witnessed evidence, separate
  flow-narrowing layer. v1 type grammar derived whole from the Lua value universe;
  `for-in` decided (`pairs`/`ipairs` + numeric included, general iterator protocol
  deferred). Capability-reachability and imperative-store pressure absorbed here
  (stores handled flow-insensitively by check-against-declared-element-type).
  Code in `lib/type/analysis/{slice_ty,slice_subtype,slice_ty_arg,crescent_slice,
  crescent_slice_parse,slice_narrow}.lua` (+ tests + `slice_subtype_bench.lua`).
  **Corpus result: all 11 fixtures Accept (0 errors), matching every Expected
  Verdict** (`corpus_test.lua`, the §7 grading run); the five legacy REMAINS gaps
  (boolean `and`, closure return-slot, table-widening, redundant-cast, hamt
  tag-narrow) all closed, the six FIXED guards held. The substrate (`init.lua`) was
  **not touched** across any pass — the ladder's falsifiable bet settled at target.
  **Adversarial audit round 1 (2026-06-12): 5 findings fixed** (well-formedness now
  a hard precondition; `lit_int` integer validation; `unknown` narrowing; subtype
  DAG memoization; `instantiate_witness` callee binding), each a permanent
  regression test (§9.7).

Limits:

- the propositional, lambda, cyclic/fixpoint, and STLC rungs are mechanized (the
  tiny Crescent slice is next); fixpoint *acceptance* via post-hoc witnesses is
  demonstrated (`dataflow.reach.min`), and the substrate hosts mutually-dependent
  claims without accepting circular justification;
- not the existing `lib/type/framework/`;
- not a universal inference engine by assumption;
- not allowed to smuggle Crescent-specific rules into the substrate.

## Acceptance/Falsification Corpus

`lib/type/analysis/corpus/` — kernel-agnostic fixture set for the tiny Crescent
slice rung (ladder step 5). Eleven minimal self-contained `.lua` fixtures encoding
documented legacy-checker failures with expected-correct verdicts; `corpus.md`
is the manifest with source fire references, feature families, and actual
legacy-checker verdicts from `bin/cr check`. Five fixtures expose REMAINS gaps
(active in current checker); six are FIXED regression guards. The corpus orders
the slice's tests, never its design. See `docs/agnostic-static-analysis-design.md`
§"First Validation Ladder" for the methodological rule.

## Crescent Static Semantics

Crescent static semantics is a later hosted design, not the root direction.

It may eventually define Crescent-specific judgments, effects, tables,
mutation, metatables, modules, annotations, guards, overloads, and escapes. It
should be designed against the agnostic substrate only after that substrate's
shape is clear enough to avoid another ad-hoc checker.

## Working Rule

Before coding static-analysis work, name which artifact is being changed.

Use this status language:

- `patch v4`: fix the running checker.
- `mine prior art`: read v4/v5/v6/v7 for decisions or failures.
- `design agnostic static analysis`: work on the first-principles substrate.
- `design Crescent static semantics`: make a Crescent-specific hosted-semantics
  decision only after the substrate boundary is clear.

If the work cannot be named as one of those, stop and write the missing framing
first.
