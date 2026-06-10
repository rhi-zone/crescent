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
- `Crescent static semantics`: future Crescent checker design, not yet written.

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

New framework implementation work should not happen. If the project later wants
a framework-like substrate, it needs a fresh design that does not inherit this
artifact's assumptions, terminology, or implementation shape by default.

## Crescent Static Semantics

The Crescent static semantics is the future design for checking Crescent code.

Authority:

- should define Crescent-specific judgments, effects, tables, mutation,
  metatables, modules, annotations, guards, overloads, and escapes;
- should use v4/v5/v6/v7 material only as evidence, not authority.

Limits:

- not yet designed;
- should not be backfilled from framework implementation details;
- should not inherit v7 terminology unless that terminology is independently
  justified.

## Working Rule

Before coding static-analysis work, name which artifact is being changed.

Use this status language:

- `patch v4`: fix the running checker.
- `mine prior art`: read v4/v5/v6/v7 for decisions or failures.
- `design Crescent static semantics`: make a Crescent-specific static semantics
  decision.
- `new substrate`: write a fresh first-principles design before any general
  proof/static-semantics implementation.

If the work cannot be named as one of those, stop and write the missing framing
first.
