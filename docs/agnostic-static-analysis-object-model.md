# Agnostic Static Analysis Object Model

Status: active design direction, second pass.

This document refines `docs/agnostic-static-analysis-design.md` into the first
object model. It is not a JSON format, Lua API, proof assistant encoding, or
replacement typechecker implementation plan.

## Design Goal

The object model must represent static-analysis work without choosing a type
system, source language, solver, or proof calculus.

The smallest useful unit is:

```text
an analyzer accepts or rejects claims about artifacts under named assumptions
```

The model therefore starts with identity, artifacts, claims, evidence,
dependencies, and trust. Syntax trees, binders, types, environments, heaps, and
effects are hosted vocabulary unless a later derivation proves they are
substrate-level.

## Object Kinds

### Identity

Every persistent object that can be referenced by evidence has an identity.

```text
Id {
  space,
  local
}
```

`space` names the identity namespace, such as `artifact`, `observation`,
`claim`, `evidence`, `trust`, or a hosted-semantics namespace.

`local` is an opaque stable key inside that space.

The substrate does not interpret `local` as a source name, path, AST index, or
semantic binder identity. Hosted semantics may define identities with those
meanings.

### Artifact

An artifact is an analyzed object.

```text
Artifact {
  id,
  kind,
  content_ref,
  digest?,
  meta?
}
```

`kind` is descriptive, not semantic authority. Examples: `source_text`,
`syntax_tree`, `cfg`, `module_graph`, `bytecode`, `archive`, `trace`.

`content_ref` points to the stored content. It may be inline data, a path, a
content-addressed blob, or a reference into another artifact.

`digest` is optional at the object-model level. Concrete encodings should use
digests when artifacts cross trust or cache boundaries.

### Observation

An observation is a named fact extracted from one or more artifacts.

```text
Observation {
  id,
  predicate,
  args,
  source_artifacts,
  support
}
```

`predicate` is a symbol owned by the selected analysis semantics. The substrate
does not know whether `node_head`, `edge`, `declares`, `writes`, or
`imports_capability` are meaningful.

`support` records why the observation may be used:

- `checked`: derivable from artifact content by a checker;
- `trusted`: admitted by a visible trust boundary;
- `assumed`: local hypothesis scoped to a larger evidence object;
- `derived`: accepted from other observations or claims.

### Claim

A claim is a proposition that can be accepted, rejected, or left unknown.

```text
Claim {
  id,
  semantics,
  predicate,
  args,
  scope?,
  subject_artifacts
}
```

`semantics` names the hosted static semantics that owns the claim predicate.

`scope` is intentionally opaque in the substrate. It may later host lexical
scope, path conditions, dataflow point, module context, proof assumptions, or
other analysis-local context. The substrate only preserves it as part of claim
identity and dependency tracking.

### Evidence

Evidence is an object offered in support of a claim.

```text
Evidence {
  id,
  claim,
  method,
  inputs,
  result
}
```

`method` is selected by the claim's semantics. Examples:

- `rule_application`;
- `artifact_check`;
- `dataflow_fixpoint_witness`;
- `solver_witness`;
- `counterexample`;
- `trusted_boundary`;
- `delegated_checker_result`.

The substrate does not require all evidence to be proof trees. A semantics may
use proof trees, traces, witnesses, normalized solver outputs, or small
checker-specific certificates.

### Dependency

A dependency records what an accepted claim relies on.

```text
Dependency {
  from_claim,
  kind,
  target,
  invalidation?
}
```

`target` may be an artifact, observation, claim, evidence object, or trust
boundary.

`kind` is semantics-owned, but the substrate reserves broad classes:

- `artifact_content`;
- `observation`;
- `accepted_claim`;
- `trusted_boundary`;
- `assumption`;
- `external_tool_result`.

`invalidation` describes when the dependency stops being valid. Examples:
artifact digest changes, module declaration changes, store abstraction changes,
capability policy changes, path condition no longer holds.

The substrate does not compute every invalidation relation by itself. It must
store them so incremental and audit tools can reason about them.

### Trust Boundary

A trust boundary is a visible place where analysis accepts something it did not
fully check.

```text
TrustBoundary {
  id,
  kind,
  issuer,
  scope,
  payload_digest?,
  policy
}
```

Examples:

- external declaration file;
- hand-written assertion;
- unchecked cast;
- FFI declaration;
- target platform specification;
- SMT solver result without proof;
- cached result from a different checker.

Trust boundaries are not errors. They are part of the product when made visible
and auditable.

## Analysis State

The state of an analysis run is:

```text
AnalysisState {
  artifacts,
  observations,
  claims,
  evidence,
  trust_boundaries,
  accepted,
  rejected,
  unknown
}
```

The substrate distinguishes three result classes:

- `accepted`: evidence was checked or explicitly trusted under policy;
- `rejected`: evidence failed, or a counterexample was accepted;
- `unknown`: no accepted evidence exists and no rejection proof exists.

`unknown` is not `accepted`. It cannot be consumed as proof by another claim
unless a hosted semantics explicitly admits unknown-as-input through a visible
rule or trust boundary.

## Checker Interface

A checker consumes:

```text
CheckRequest {
  state,
  requested_claims,
  semantics_registry,
  trust_policy
}
```

It produces:

```text
CheckResult {
  accepted_claims,
  rejected_claims,
  unknown_claims,
  diagnostics,
  dependency_graph,
  trust_summary
}
```

This interface deliberately says nothing about inference. A producer may
populate `state.claims` and `state.evidence` before checking, or the checker may
invoke a producer under a policy. Either way, accepted claims must still carry
evidence and trust summaries.

## Semantics Registry

A semantics registry maps a semantics identifier to its checker obligations.

```text
SemanticsEntry {
  id,
  version,
  claim_predicates,
  observation_predicates,
  evidence_methods,
  checker,
  trusted_methods
}
```

The registry is not a language spec by itself. It says how to validate claims
for a hosted semantics.

The first implementation may encode each `checker` as ordinary Lua code. A
later mechanized version may encode some entries in a proof assistant. The
object model should support both without changing accepted-claim semantics.

## What Is Not In The Substrate Yet

These are intentionally absent:

- syntax categories;
- term heads;
- binders;
- alpha-equivalence;
- substitution;
- subtyping;
- effects;
- heap/state models;
- fixed-point solvers;
- type variables;
- module environments.

They are not rejected. They are withheld until a validation semantics forces
them to become substrate-level rather than hosted vocabulary.

## First Concrete Validation

The first validation semantics should be propositional logic.

Reasons:

- no program language;
- no binders;
- no types;
- no dataflow;
- no mutation;
- enough structure to test claims, evidence, dependencies, trusted assumptions,
  accepted/rejected/unknown, and diagnostics.

Minimal predicates:

```text
prop(name)
and(a, b)
implies(a, b)
not(a)
```

Minimal evidence methods:

```text
assumption
and_intro
and_elim_left
and_elim_right
modus_ponens
contradiction
trusted_axiom
```

This is not because propositional logic is the end goal. It is the smallest
test that can falsify the object model without importing language-specific
machinery.

## Next Pass

The next pass should specify the propositional validation semantics using this
object model, including:

- exact claim predicates;
- exact evidence methods;
- dependency recording;
- trust summary behavior;
- accepted/rejected/unknown examples;
- one adversarial example that tries to smuggle a typechecker concept into the
  substrate.
