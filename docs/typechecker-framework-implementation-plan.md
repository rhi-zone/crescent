# Typechecker Framework Implementation Plan

This document turns the first framework design pass into an implementation plan.

It is not permission to implement Crescent semantics. The first implementation
must validate the framework substrate with tiny non-Crescent theories before any
future Crescent theory is attempted.

## Current Inputs

Design specs:

- `docs/typechecker-framework.md`
- `docs/typechecker-framework-data-model.md`
- `docs/typechecker-framework-derivation-checker.md`

Validation theories:

- `docs/typechecker-framework-stlc.md`
- `docs/typechecker-framework-system-f.md`

Boundary audit:

- `docs/typechecker-framework-v7-mr0-audit.md`

## Implementation Principle

The implementation is a checker for declarative evidence, not a typechecker for
Crescent.

The trusted path may know about:

- framework object tags;
- category declarations;
- term-head declarations;
- binder scopes;
- claim scopes;
- judgment schemas;
- rule schemas;
- premise ordering;
- structural checks;
- canonical serialization;
- roots.

The trusted path must not know about:

- STLC as hardcoded rules;
- System F as hardcoded rules;
- Crescent scalar types;
- subtyping;
- pack movement;
- Lua target profiles;
- stdlib or module declarations;
- MR0 node families.

## Milestones

### F0: External Object Format

Define a concrete table and JSON shape for:

- `TheorySpec`;
- terms;
- scoped terms;
- context-role terms;
- claims;
- rule schemas;
- evidence nodes;
- roots.

Acceptance bar:

- every object has an explicit tag;
- maps and arrays are schema-directed;
- JSON `null` is rejected;
- source spans are optional metadata and excluded from semantic digests;
- unknown fields are rejected unless a schema explicitly marks a metadata map.

No derivation replay is required in F0.

Current spec: `docs/typechecker-framework-format.md`.

### F1: Canonical Serialization

Implement canonical serialization for the F0 object model.

Acceptance bar:

- deterministic map key ordering;
- array order preservation;
- alpha-stable binder encoding;
- no host-object identity;
- duplicate JSON keys rejected at the external boundary;
- root digest includes framework version and theory digest.

F1 should reuse lessons from `lib/type/v7_mr0/canonical.lua`, not its MR0 object
model.

### F2: Shape Validator

Implement theory and certificate shape validation.

Acceptance bar:

- categories are declared before use;
- term heads match field schemas;
- binder namespaces/categories are valid;
- bound references resolve in claim or nested scoped-term scope;
- judgment claims match schemas;
- evidence node IDs are unique;
- premise references exist;
- roots match root schemas.

No rule replay is required in F2.

### F3: First-Order Rule Replay

Implement rule replay for the first implementation slice:

- no binders;
- no scoped destructuring;
- `input` metavariables only;
- fixed-arity constructor patterns;
- ordered premises;
- no oracles.

Acceptance bar:

- accepts a tiny combinator theory fixture;
- rejects malformed premise order;
- rejects repeated metavariable mismatch;
- rejects unknown rule names;
- rejects ambiguous or unsupported pattern forms.

### F4: Binder And Scoped Claim Replay

Add:

- scoped term fields;
- claim scopes;
- alpha-normalization;
- binder identity equality/inequality;
- scoped rule-pattern destructuring;
- syntactic substitution checks with explicit source/binder/replacement/result.

Acceptance bar:

- accepts STLC identity and application fixtures;
- rejects open roots when root policy is `closed`;
- rejects binder capture;
- rejects context lookup unless represented as evidence.

### F5: System F Replay

Use the same checker to replay the System F subset.

Acceptance bar:

- accepts type abstraction/application fixtures;
- rejects type application without explicit `SubstTy`;
- rejects capture-prone substitution unless alpha-renamed structurally;
- rejects hidden definitional equality.

### F6: Crescent Theory Spike

Only after F5, define a tiny Crescent theory fixture set.

Scope:

- scalar type atoms;
- literal value claims;
- `integer <: number`;
- closed exact pack movement;
- pure closed-arrow call.

Acceptance bar:

- no dependency on `lib/type/v7_mr0/`;
- no MR0 node families;
- every Crescent rule is a theory rule schema;
- every non-structural computation is evidence or an oracle.

## Commit Strategy

Each milestone should be committed independently:

```text
docs/spec -> fixture tables -> validator/replay code -> tests
```

Do not batch Crescent-theory work into framework substrate commits.

## Stop Conditions

Stop for design review if:

- STLC needs a hidden framework lookup rule;
- System F needs hidden type equality or reduction;
- canonicalization cannot be alpha-stable without theory-specific code;
- rule replay needs arbitrary theory-side functions;
- the first Crescent spike cannot be expressed without MR0 node families.
