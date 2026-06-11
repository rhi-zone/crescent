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
untyped-lambda, and cyclic/fixpoint-evidence validation passes are written, and
**mechanization has landed**. The code lives in `lib/type/analysis/`: the
substrate (`init.lua`), three independent hosted semantics (`prop.lua` =
`prop.logic.min`, `lambda.lua` = `lambda.untyped.min`, `dataflow.lua` =
`dataflow.reach.min`), and tests (`prop_test.lua`, `lambda_test.lua`,
`dataflow_test.lua`, `substrate_test.lua`, 108 assertions) that mechanize every
worked example plus the un-falsifiable-on-paper probes (claim identity,
scheduling order-independence, cycle termination, unknown propagation,
adversarial smuggling, fixpoint witnessing). Mechanization findings are recorded
in the object-model and three validation docs. The cyclic/fixpoint rung
(`docs/agnostic-static-analysis-fixpoint.md`) confirmed a fixpoint is hostable as
a post-hoc witness with **no substrate change**. Next: STLC against running code.
After STLC: tiny Crescent slice (ladder compressed — no further synthetic rungs).
See "Next Pass" in `docs/agnostic-static-analysis-design.md`.

Rung status (ladder, design doc):

- 1 propositional — mechanized.
- 2 untyped lambda — mechanized.
- 3 cyclic/fixpoint-evidence — mechanized (`dataflow.reach.min`); substrate
  unchanged, witness model holds.
- 4 STLC — next.
- 5 tiny Crescent slice — not started. (Capability-reachability and
  imperative-store pressure absorbed here from the real target; ladder
  compressed after STLC.)

Limits:

- the propositional, lambda, and cyclic/fixpoint rungs are mechanized (STLC is
  next); fixpoint *acceptance* via post-hoc witnesses is now demonstrated
  (`dataflow.reach.min`), and the substrate hosts mutually-dependent claims
  without accepting circular justification;
- not the existing `lib/type/framework/`;
- not a universal inference engine by assumption;
- not allowed to smuggle Crescent-specific rules into the substrate.

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
