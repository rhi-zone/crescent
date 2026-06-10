# Agnostic Static Analysis Design

Status: active design direction, first pass.

This document starts the static-analysis design from first principles. It does
not continue `v7_mr0` or `lib/type/framework/`. Those artifacts may be mined for
examples and failure modes, but they do not define the architecture.

## Core Thesis

Static analysis is checked reasoning about program artifacts.

The root object is not a type, a constraint, a solver, an AST walker, or a
language-specific checker. The root object is a claim about an artifact, plus
an account of why that claim is valid under an explicit semantics.

```text
artifact + semantics + evidence => accepted claim
```

Typechecking is one hosted use. Linting, capability checks, dataflow proofs,
module-safety checks, definite-assignment checks, and proof-carrying compiler
passes are also hosted uses.

## Non-Negotiables

- The substrate must not define what a type is.
- The substrate must not define Crescent semantics.
- Existing v4/v5/v6/v7/framework code is prior art, not authority.
- Unsound accepted claims are fatal.
- Incomplete analysis is acceptable.
- Unknown interactions reject or require an explicit trusted boundary.
- Inference engines and solvers are untrusted producers unless their outputs
  are checked.
- Any trusted boundary must be explicit in the artifact being checked.

## Primitive Vocabulary

### Artifact

An artifact is the thing being reasoned about.

Examples:

- source syntax;
- desugared syntax;
- bytecode;
- an IR graph;
- a module graph;
- a capability graph;
- a control-flow graph;
- a serialized proof object.

The substrate should not assume artifacts are trees. Many useful analyses are
over graphs, tables, traces, indexes, or external declarations.

### Observation

An observation is extracted data about an artifact.

Examples:

- node `n` has head `Call`;
- edge `e` connects block `a` to block `b`;
- symbol `s` resolves to declaration `d`;
- bytecode instruction `i` writes register `r`;
- module `m` imports capability `c`.

Observations may be produced by parsers, indexers, or frontends. If an
observation is trusted, that trust must be visible. If it is untrusted, it must
be checkable from the artifact or justified by another accepted claim.

### Claim

A claim is a proposition about artifacts or observations.

Examples:

- expression `e` has property `p`;
- variable `x` is definitely initialized at point `q`;
- path `p` is unreachable;
- function `f` requires capability `cap`;
- module `m` exports declaration `d`;
- term `t` has type `T` under semantics `S`.

The substrate treats all of these uniformly as claims. "Type" is not privileged.

### Semantics

A semantics defines what makes claims valid.

It supplies:

- claim forms;
- admissible rules;
- required inputs;
- allowed trusted boundaries;
- invalidation or dependency rules when claims depend on mutable facts;
- what counts as a checked result.

A semantics may describe a programming language, a tiny calculus, a module
system, a capability discipline, or a checker-specific analysis.

### Evidence

Evidence is the support for a claim.

Examples:

- a derivation tree;
- a proof certificate;
- a normalized trace;
- a counterexample;
- a solver result with checkable witnesses;
- an explicit trusted oracle result.

Evidence is not required to be human-authored. A producer may generate it. The
important boundary is that evidence is checked by a smaller, more trusted
checker, or marked as a trusted boundary.

### Producer

A producer creates observations, claims, or evidence.

Examples:

- parser;
- elaborator;
- type inference engine;
- dataflow solver;
- SMT solver;
- IDE incremental checker;
- handwritten annotation importer.

Producers are not trusted by default.

### Checker

A checker validates that evidence supports claims under a selected semantics.

The checker should be as small as practical for the chosen semantics. There may
be multiple checkers with different trust levels. A fast local checker may
accept trusted boundaries that a mechanized verifier later expands.

## Core Shape

The minimal static-analysis unit is:

```text
AnalysisUnit {
  artifact,
  semantics_id,
  inputs,
  observations,
  claims,
  evidence,
  trusted_boundaries
}
```

The accepted output is:

```text
AcceptedClaim {
  claim,
  semantics_id,
  dependencies,
  trust_summary
}
```

The rejected output is:

```text
RejectedClaim {
  claim,
  reason,
  counterevidence?
}
```

This is intentionally abstract. Concrete encodings come later.

## Design Invariants

### Evidence Before Inference

The substrate should not ask "how do we infer this?" first. It should ask:

```text
What claim is being accepted, and what evidence would make acceptance sound?
```

Inference is a producer problem. Sound acceptance is a checker problem.

### Semantics Before Features

A feature is admitted only when its claims and validity rules are named.

For example, "overloads" is not a substrate feature. A hosted language may
define claims about callable alternatives, implementation checking, and call
selection. Another hosted language may not have overloads at all.

### Dependencies Are First-Class

Accepted claims depend on artifacts, observations, other claims, and trusted
boundaries. Those dependencies must be visible.

This matters for:

- mutation and invalidation;
- incremental checking;
- diagnostics;
- proof export;
- auditing unsafe assumptions.

### Trust Is First-Class

Trusted boundaries are allowed, but not hidden.

Examples:

- external declaration file;
- FFI signature;
- target platform rule;
- SMT oracle;
- unchecked cast;
- handwritten assertion.

The substrate must preserve where trust entered and which accepted claims depend
on it.

### Hosted Semantics Own Their Vocabulary

Terms such as `type`, `effect`, `flow fact`, `capability`, `subtype`,
`environment`, `heap`, and `module` belong to hosted semantics unless the
substrate can justify them for all static analysis.

The default answer is that they are not substrate primitives.

## Rejected Inheritances

The new design does not inherit these from prior tracks:

- v4's running checker architecture;
- v5's operational-semantics machinery;
- v6's typechecker-specific kernel shape;
- v7's Crescent-centered runtime categories;
- the rejected framework's `theory/evidence DAG/replay` representation;
- implementation terms such as `scope_from`.

Some ideas may later be reintroduced, but only by derivation from this design,
not because the old documents used them.

## First Validation Ladder

The substrate should be tested by increasingly hostile hosted semantics.

These are design tests, not product checkers:

1. Propositional logic: claims and evidence with no programs.
2. Untyped lambda calculus: artifact structure, binding, alpha-equivalence, and
   simple evaluation claims.
3. STLC: hosted `type` vocabulary without making types substrate primitives.
4. Definite assignment: graph/dataflow claims with fixed-point evidence.
5. Capability reachability: graph claims with explicit authority boundaries.
6. Imperative store sketch: mutation, invalidation, and dependency tracking.
7. Tiny Crescent slice: only after the previous tests do not force special
   pleading.

If a step requires adding a substrate primitive that is only meaningful for
Crescent, the design has failed.

## Open Questions

These are load-bearing and should be answered before implementation:

1. What is the smallest concrete object model for artifacts, observations,
   claims, and evidence?
2. Is the substrate a proof checker, a dependency tracker, a claim database, or
   a composition of those?
3. What must be trusted in the first implementation slice?
4. How are binders represented without inheriting the rejected framework's
   representation?
5. How are graph/fixed-point analyses represented without baking in one solver?
6. What is the distinction between a failed claim, an unknown claim, and a
   trusted claim?
7. What is the smallest validation semantics worth mechanizing first?

## Next Pass

The next design pass should define the object model:

- identity and naming;
- artifact references;
- claim syntax;
- evidence syntax;
- dependency records;
- trust summaries;
- serialization boundaries.

No Crescent feature work should start before that object model exists.
