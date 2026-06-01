# Typechecker Soundness Validation

This document records the current soundness bar for the checker effort.

## Version Line

If the checker is built around a mechanized kernel or proof-producing
acceptance, it is not v6. It is a new architecture line: **v7**.

Reason: v6 is currently a direct implementation prototype beside v4. A
proof-producing or mechanized-kernel-first checker changes the trust model,
acceptance pipeline, artifact format, and definition of implementation
completeness. Treating that as "v6 with stricter tests" would hide the most
important design decision.

v6 may remain useful as research input or disposable prototype code, but it is
not evidence for v7 soundness unless its accepted programs can be justified by
the v7 kernel/certificate rules.

The initial v7 semantic kernel draft is
`docs/typechecker-v7-kernel-semantics.md`.

## Premise

Unsoundness is fatal. A checker that accepts an unsound program because a feature
interaction was unclear has failed, even if the accepted pattern is convenient.

This changes the default:

- unknown interaction means reject or defer;
- approximation may reject valid programs, but must not accept invalid ones;
- `any`, FFI, dynamic require, force casts, and unchecked external facts are
  explicit unsafe boundaries;
- a feature is not admitted until its interaction with the sound core is
  specified.

## Failure Mode

Organic growth is the failure mode.

The v4/v5 failure pattern was not merely bad code organization. It was a series
of locally reasonable decisions that accumulated without a global validation
mechanism. "Thin verticals" can repeat the same failure: each vertical may look
small and testable while still adding one more local semantic exception.

Therefore, implementation slices are not sufficient evidence of architecture.
A new rule must be derivable from the global semantic kernel, or the kernel must
be explicitly extended before implementation.

## What Must Be Validated

The minimum semantic kernel must cover the interactions that can create
unsoundness:

- value-set algebra: atoms, literals, unions, intersections, complement,
  `unknown`, `never`;
- arrows and call movement;
- overload declarations and overload calls;
- returns, including multi-return correlation;
- records and table identity;
- mutation, aliasing, sealing, and invalidation;
- flow facts and user-defined guards;
- unsafe boundaries.

Features outside the kernel are not admitted by default. Effects, HKTs,
refinement types, metatables beyond the core identity model, and module/stdlib
precision require separate admission only after their interaction with this
kernel is specified.

## Validation Options

### Prose Spec Plus Tests

This is the current project habit. It is useful but insufficient as the final
assurance mechanism when unsoundness is fatal. It can document decisions and
catch regressions, but it cannot prove that the implementation has no hidden
semantic rule.

### Mechanized Kernel

A mechanized kernel in Coq, Lean, Isabelle, or HOL can define:

- a small core language;
- operational semantics;
- type syntax and typing judgments;
- subtyping and fact-transition judgments;
- a soundness theorem for the admitted core.

This should not attempt to mechanize full Lua, parser behavior, diagnostics,
module IO, cache behavior, or the entire stdlib. Mechanizing those would be
overkill for the soundness question. Mechanizing the failure-prone semantic
kernel is not overkill if unsoundness is fatal.

### Proof-Producing Checker

A proof-producing checker separates search from trust.

The production checker may remain ordinary Lua code. For an accepted program, it
also emits a certificate: a compact proof object describing which kernel rules
justify each accepted claim. A small verifier checks the certificate against the
formal kernel. If the verifier rejects, the program is rejected, regardless of
what the main checker inferred.

This architecture makes implementation bugs less likely to become silent
unsound acceptance. A bug usually becomes "failed to produce a valid proof."

## Certificate Shape

Certificates should be compact, DAG-shaped, and reference shared terms by ID.
They should not be giant duplicated proof trees.

Typical proof nodes:

```lua
{ rule = "Literal", expr = 12, type = "integer" }
{ rule = "Sub", producer = type_id_a, consumer = type_id_b, proof = proof_id }
{ rule = "Call", callee = proof_id, args = { proof_id }, returns = pack_id }
{ rule = "OverloadDef", branches = { proof_id, proof_id } }
{ rule = "GuardDef", predicate = pred_id, true_returns = { proof_id } }
{ rule = "SealTable", identity = 17, writes = { proof_id }, record = type_id }
```

The verifier must be deterministic. It should not infer overload branches,
invent facts, widen types, or repair missing proof steps. It only checks that the
certificate follows the kernel rules.

## Optional Modes

Proof checking can be optional operationally, but it cannot change semantics.

Modes:

- normal mode: run the checker only;
- audit mode: emit and verify certificates;
- CI strict mode: audit changed files or selected soundness-critical packages;
- release/safety mode: audit every file in the trusted set;
- debug mode: emit certificate traces for a single function or module.

Invariant:

If normal mode accepts a file and audit mode rejects it, normal mode has a bug.
Optional proof checking is a performance/deployment choice, not a second
semantics.

## Implementation Consequences

No further full-checker implementation plan is trustworthy until it states which
validation level it targets.

Allowed near-term work:

- write the semantic kernel rules;
- identify which current v4/v5/v6 rules are outside the kernel;
- design certificate terms for existing accepted constructs;
- build small adversarial examples for kernel interactions;
- prototype proof production for a tiny subset only if the certificate format is
  already specified.

Disallowed near-term work:

- adding new semantic verticals because they are locally small;
- admitting a feature by test coverage alone;
- adding name-keyed handlers as compatibility patches;
- using `any` or `unknown` to recover from missing rules;
- treating v6 implementation progress as evidence that v6 is sound.
