# Typechecker Framework Derivation Checker

This document specifies the first trusted checker for
`docs/typechecker-framework-data-model.md`.

The checker is a replay verifier. It does not infer missing premises, solve
constraints, choose overloads, reduce terms, or search for proofs. It accepts a
certificate only when every accepted root is justified by declared framework
structure, declared theory rules, and admitted oracle boundaries.

## Inputs

```text
CheckInput {
  framework_version,
  theory_spec,
  certificate,
  trust_policy
}
```

`framework_version` selects the framework data model and canonical encoding.

`theory_spec` declares categories, term heads, context-role categories,
judgment schemas, rule schemas, oracle schemas, and root schemas.

`certificate` contains terms, claims, evidence nodes, oracle payloads, and
roots. Contexts are ordinary terms whose category has role `context`.

`trust_policy` selects which declared oracle kinds are admissible for this run.

## Output

```text
CheckResult =
  Accepted { root_digests }
| Rejected { errors }
```

Acceptance means only this:

- the certificate is well-formed framework data;
- every accepted evidence node replays against the theory spec;
- every root points to an accepted evidence node of the required shape;
- every oracle use is explicit and admitted by the active trust policy.

Acceptance does not mean the frontend was correct, optimal, complete, or
deterministic.

## Replay Pipeline

1. Validate the theory spec.
2. Canonicalize the theory spec and compute its digest.
3. Validate certificate envelopes and framework-version compatibility.
4. Validate category, term, binder, bound-reference, context-role, judgment,
   and root shapes.
5. Canonicalize certificate objects and check all declared digests.
6. Topologically order evidence nodes by premise dependencies.
7. Replay each evidence node.
8. Validate roots.
9. Return accepted root digests.

Failure at any step rejects the certificate.

## Theory Spec Validation

The framework checks:

- theory ID and version are present;
- category names are unique;
- term heads reference declared categories;
- binder schemas reference declared namespaces and categories;
- categories marked with role `context` have ordinary declared term heads;
- judgment schemas reference declared categories, binder-reference sorts, or
  framework scalar kinds;
- rule schemas reference declared judgments;
- rule metavariables have declared categories and modes;
- oracle schemas reference declared judgments;
- root schemas reference declared judgments.

The framework does not prove that the theory is sound. It only checks that the
theory is a well-formed input language for evidence replay.

## Certificate Shape Validation

The framework checks:

- every object has a known tag;
- every referenced theory ID and version matches the selected theory spec;
- every term head exists and receives fields matching its schema;
- every scoped field binds only declared binder schemas;
- every bound reference resolves to an in-scope binder;
- every claim scope is well formed;
- every context-role value is an ordinary well-formed term of a category marked
  `context`;
- every claim matches a declared judgment schema;
- every evidence node has a unique ID;
- every premise reference points to an existing evidence node;
- every oracle application matches a declared oracle schema;
- every root matches a declared root schema.

Malformed data is rejected before replay. The checker should report all
independent shape errors it can find without guessing repair intent.

## Canonicalization Checks

Canonicalization is part of replay because certificate identity must not depend
on host-language representation.

The checker computes canonical forms for:

- theory spec;
- terms;
- claims;
- evidence nodes;
- oracle payloads;
- roots.

It rejects:

- duplicate map keys;
- unordered map encodings when the external format claims canonical form;
- unknown tags;
- non-canonical numeric spellings;
- unresolved references;
- alpha-unstable binder encodings;
- digest mismatches.

The first external encoding may be JSON. A later binary encoding must round-trip
to the same abstract objects and digests.

## Evidence Replay

Each evidence node has one conclusion claim and one justification.

```text
EvidenceNode {
  node_id,
  theory_id,
  judgment,
  claim,
  justification
}
```

Replay is local to the selected theory spec.

### Rule Application

For a rule application:

```text
RuleApplication {
  rule_name,
  premise_node_ids
}
```

The checker:

1. Finds the rule schema.
2. Checks that the node claim matches the rule conclusion judgment.
3. Matches the conclusion and premise claims against the rule patterns under
   the declared metavariable modes.
4. Checks that every `input` metavariable is fixed before use.
5. Checks that every `output` metavariable is produced before later use.
6. Checks that every `fresh` metavariable satisfies declared freshness
   constraints.
7. Checks repeated metavariable occurrences by alpha-normalized syntactic
   equality.
8. Opens scoped fields only where the rule schema declares scoped destructuring,
   and checks selected premise claims under the extended binder scope.
9. Checks narrow framework structural conditions.
10. Accepts the node if all premises are already accepted and all checks pass.

Rule replay is deterministic. If more than one match is possible, the rule
schema is ambiguous and the certificate is rejected unless the theory has
declared an explicit disambiguating field.

For the first checker, rule patterns are restricted to first-order constructor
patterns with fixed-arity fields. No ellipses, list splats, associative
matching, commutative matching, or implicit premise reordering are admitted.

### Oracle Application

For an oracle application:

```text
OracleApplication {
  oracle_kind,
  input_payload,
  input_digest,
  result_payload,
  result_digest,
  trust_policy
}
```

The checker:

1. Finds the oracle schema.
2. Checks that the oracle kind is allowed for the target judgment.
3. Checks that the active trust policy admits the oracle kind.
4. Checks that input and result payloads match their declared schemas.
5. Recomputes and checks input and result digests.
6. Checks that the result payload contains the exact node claim and claim digest
   after canonicalization.
7. Records the oracle use in the accepted root digest.

The checker does not call the oracle. It validates an explicit trusted result.
The first oracle result format is exact-claim only; richer result mappings need
a declarative canonical mapping language that is part of the theory digest.
Proof-producing oracles can instead return ordinary evidence nodes and avoid
trust-policy admission.

## Structural Conditions

The framework admits only structural conditions whose meaning is independent of
theory semantics:

- category equality;
- binder identity equality after alpha-normalization;
- binder identity inequality after alpha-normalization;
- alpha-equivalence;
- explicit syntactic substitution checks;
- literal equality;
- list length equality;
- digest equality.

The framework does not admit side conditions for:

- context lookup;
- subtyping;
- assignability;
- overload resolution;
- class or field lookup;
- reduction;
- normalization;
- type-level evaluation;
- flow-fact join;
- heap update;
- effect propagation.

Those must be ordinary premise judgments with evidence, or explicit oracle
applications.

Syntactic substitution is not beta-reduction, normalization, definitional
equality, or a substitution lemma. A substitution structural condition must name
`source`, `binder`, `replacement`, and `expected_result`; the framework checks
only alpha-stable structural traversal and capture avoidance.

## Dependency Ordering

Evidence nodes form a DAG.

The checker rejects:

- cycles;
- missing premise nodes;
- premise nodes with mismatched theory IDs or versions;
- premise nodes that were rejected;
- roots that depend on rejected or unchecked nodes.

Topological replay is an implementation strategy, not certificate semantics.
The canonical root digest must be independent of source ordering and
artifact-local node labels.

## Evidence Identity

Accepted root identity is a canonical Merkle DAG over the reachable accepted
closure.

An evidence node digest includes:

- framework version;
- theory digest;
- judgment digest;
- claim digest;
- justification tag;
- rule name or oracle kind;
- ordered premise evidence digest list;
- oracle input and result payload digests, if any.

Premise order is semantically significant unless the rule schema declares an
explicit commutative premise set. Duplicate premise references are rejected in
the first checker. Rejected nodes and unreachable accepted nodes do not affect a
root digest. Artifact-local `node_id` labels do not affect semantic evidence or
root digests. A root-set digest sorts accepted root digests canonically.

## Root Validation

Each root schema declares:

```text
RootSchema {
  root_kind,
  required_judgment,
  required_claim_pattern,
  scope_policy
}
```

The checker accepts a root only if:

- the root kind is declared;
- the referenced evidence node is accepted;
- the node claim scope satisfies the root scope policy;
- the node judgment matches the root schema;
- the node claim matches the root claim pattern;
- every oracle dependency is admitted by the active trust policy;
- the canonical root digest includes the theory digest, claim digest, evidence
  dependency digests, and oracle payload digests.

## Diagnostics

Diagnostics are not trusted semantics, but replay failure must be explainable.

Minimum diagnostic categories:

- malformed theory spec;
- malformed certificate object;
- unknown category/head/judgment/rule/oracle/root;
- scope or binder error;
- canonicalization or digest mismatch;
- dependency cycle;
- premise mismatch;
- metavariable mode violation;
- structural condition failure;
- oracle policy rejection;
- root mismatch.

The checker should report source spans when the certificate provides them, but
source spans are never part of trusted replay.

## Completeness Boundary

The checker is intentionally incomplete as a proof search engine.

It may reject because:

- a valid proof was not provided;
- a frontend chose the wrong rule;
- a solver result was not packaged as evidence or oracle payload;
- a theory omitted a required rule;
- a real language feature has not been specified.

These are not checker bugs. Silent acceptance without replayed evidence is a
checker bug.

## First Implementation Slice

The first derivation checker prototype should accept only:

- one theory spec loaded from a canonical external file;
- categories;
- term heads without binders;
- context-role terms only as opaque structured claim parameters;
- judgment schemas;
- rule schemas with `input` metavariables only;
- first-order constructor patterns with fixed-arity fields only;
- rule applications with ordered premises;
- roots;
- no oracles.

This is enough to validate a tiny combinator fragment before adding STLC
binders. STLC should be the first real theory after binder replay is present.
The first slice must not claim to validate context extension, lookup, weakening,
or exchange; context-role terms are just syntax until explicit judgments replay
those relations.

## Open Problems

- How expressive the rule pattern language must be before System F.
- Whether proof-producing oracles should have a standard wrapper format.
- Whether rejected evidence nodes may be retained in certificates for
  diagnostics or must be omitted from canonical accepted roots.
