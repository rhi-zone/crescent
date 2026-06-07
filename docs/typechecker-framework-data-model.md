# Typechecker Framework Data Model

This document refines `docs/typechecker-framework.md` into the first concrete
framework-level data model.

The data model is intentionally type-system-agnostic. It must be able to host
STLC, System F, nominal OO sketches, structural flow sketches, and eventually a
Crescent theory without baking any of those systems into the framework.

## Boundary

Framework-owned concepts:

- theories;
- namespaces and bound references;
- syntactic categories;
- binders and scopes;
- terms;
- context roles for theory-declared syntax;
- judgments;
- rule schemas;
- evidence nodes;
- roots;
- explicit oracle nodes;
- canonical serialization.

Theory-owned concepts:

- which categories exist;
- which term heads exist;
- which judgments exist;
- which rules are admitted;
- which oracle kinds are admissible;
- what theorem or soundness obligation the accepted roots are meant to support.

Frontend-owned concepts:

- parsing;
- inference;
- overload resolution;
- constraint solving;
- source spans;
- user-facing diagnostics beyond replay failure.

## Theory Spec

A theory spec is declarative input to the framework:

```text
TheorySpec {
  theory_id,
  version,
  categories,
  term_heads,
  judgment_schemas,
  rule_schemas,
  oracle_schemas,
  root_schemas
}
```

The framework does not assume that a theory has a category named `Type`, a
subtyping judgment, effects, classes, rows, unions, or records. If those exist,
they are ordinary theory declarations.

Theory IDs and versions are part of certificate digests. Changing any rule,
category, binder convention, or oracle policy changes the accepted evidence
language.

## Categories

A category is a syntactic class.

Examples from possible theories:

```text
STLC:       Term, Ty
System F:  Term, Ty, Kind
OO sketch: Expr, ClassName, MethodSig, ClassTable
Flow:      Expr, Ty, Fact, Place
```

The framework only checks that a term inhabits the category claimed by its head
and by the enclosing rule schema. Category meaning is theory-local.

## Namespaces And References

The framework owns namespaces for references. F0 only represents local bound
references directly.

```text
BoundRef {
  namespace,
  binder_id
}
```

Namespaces are framework-level so unrelated binders cannot accidentally share
meaning. A theory may choose simple namespaces such as `term_var` and
`type_var`, or richer namespaces such as `class`, `method`, `field`, and
`effect_label`.

F0 has no separate global `Symbol` value. Global declarations should be encoded
as ordinary theory terms, enum/literal fields, or future format extensions.

## Terms

A term is a category-indexed tree.

```text
Term {
  category,
  head,
  fields
}
```

Each `head` is declared by the theory:

```text
TermHead {
  name,
  result_category,
  field_schemas
}
```

Fields may contain:

- literals admitted by the theory spec;
- bound references;
- subterms;
- lists of subterms;
- binders;
- scoped subterms.

The framework checks structural well-formedness. It does not reduce, compare,
subtype, normalize, or evaluate terms unless those operations are represented by
theory judgments and evidence.

## Binders And Scope

Binders are framework-level because alpha-equivalence and capture-avoiding
substitution are cross-cutting requirements.

The framework represents scoped fields explicitly:

```text
Scoped {
  binders,
  body
}
```

A binder declares:

```text
Binder {
  namespace,
  category,
  fields
}
```

`fields` are checked against a theory-declared binder schema. A binder may have
no annotation, one type annotation, a pattern shape, a telescope tail, module
metadata, or any other theory-owned metadata. The framework owns only the
binding identity, namespace, category, and scope boundary.

Examples:

```text
lambda: Scoped([x : term_var annotated by Ty], body : Term)
forall: Scoped([A : type_var annotated by Kind], body : Ty)
```

Canonical serialization must be alpha-stable. The first implementation should
use a canonical binder index form internally, even if frontends use source names
for diagnostics.

## Contexts

Contexts are not a separate framework object system.

A context is an ordinary theory-declared category whose term heads are marked
with the role `context`. This keeps contexts, heaps, class tables, flow fact
sets, typing environments, and module environments inside the same syntax,
matching, binder, and canonicalization machinery as all other theory objects.

```text
Category TypingContext { role = context }

CtxEmpty : TypingContext
CtxExtend(prev : TypingContext, var : BoundRef(term_var), ty : Ty)
  : TypingContext
```

Examples:

```text
term_binding(x, Ty)
type_binding(A, Kind)
class_decl(C, ClassInfo)
flow_fact(place, Fact)
heap_cell(location, Ty)
```

For context-role categories, the framework can check only ordinary syntactic
facts: term head, field categories, binder scope, and literal equality. It does
not decide lookup, weakening, exchange, inheritance, fact join, heap update,
class table search, flow merge, or environment priority. Those are theory
judgments with evidence or explicit oracle boundaries.

## Judgments

A judgment schema declares a family of claims.

```text
JudgmentSchema {
  name,
  parameters
}
```

Parameters may reference declared categories, binder-reference sorts, and
framework scalar kinds. Contexts are referenced through their declared category,
not through a separate parameter kind.

Examples:

```text
WF(ctx, term)
HasType(ctx, expr, ty)
Subtype(ctx, left_ty, right_ty)
Reduces(ctx, from, to)
Assignable(ctx, place, value_ty, next_ctx)
```

The framework treats these as opaque predicates with typed parameters. It only
knows how to check that a concrete claim matches the declared schema.

Concrete claims are scoped objects:

```text
Claim {
  scope,
  judgment,
  arguments
}
```

`scope` is an ordered binder environment. Bound references in claim arguments
must resolve in that scope or in a nested scoped term. Root schemas may require
closed claims; premise evidence may be open under binders introduced by scoped
rule-pattern destructuring.

## Rule Schemas

A rule schema is a declarative constructor for evidence.

```text
RuleSchema {
  name,
  conclusion_pattern,
  premise_patterns,
  structural_conditions
}
```

Rule schemas may use metavariables. The framework matches the conclusion claim
and premises against rule patterns under an explicit metavariable discipline.

```text
Metavariable {
  name,
  category,
  mode
}
```

Modes:

- `input`: must be fixed by the conclusion or an earlier premise;
- `output`: may be produced by a premise and used by later premises or the
  conclusion;
- `fresh`: generated by the rule subject to freshness constraints.

Repeated metavariable occurrences impose syntactic equality after
alpha-normalization. If a relation cannot be expressed by pattern matching,
freshness, or premise ordering, it must be a separate judgment with evidence or
an oracle.

Rule patterns may destructure scoped fields:

```text
open scoped_field as (binder, body) in premise_patterns
```

The opened binder extends the scope of the selected premise patterns. Reusing
that binder metavariable elsewhere in the rule imposes binder-identity equality
after alpha-normalization. This is framework-owned scope plumbing, not a
language-specific typing rule.

Allowed structural conditions are narrow framework-known checks only:

- category equality;
- binder identity equality;
- binder identity inequality;
- alpha-equivalence;
- explicit syntactic substitution checks over bound references;
- literal equality;
- list length equality;
- digest equality.

No semantic lookup is a framework side condition. Context lookup, substitution
lemmas, overload candidate selection, subtyping, reduction, field lookup,
inheritance, flow-fact movement, and heap updates must be represented as
ordinary theory judgments with evidence, or as explicit oracle nodes.

Syntactic substitution checks must name `source`, `binder`, `replacement`, and
`expected_result`. The framework verifies only alpha-stable structural traversal
and capture avoidance. Beta, reduction, substitution lemmas, and definitional
equality remain theory judgments or oracles.

## Evidence Nodes

Evidence is a DAG of claims.

```text
EvidenceNode {
  node_id,
  theory_id,
  judgment,
  claim,
  justification
}
```

`justification` is one of:

```text
RuleApplication {
  rule_name,
  premise_node_ids
}

OracleApplication {
  oracle_kind,
  input_payload,
  input_digest,
  result_payload,
  result_digest,
  trust_policy
}
```

Rule applications are checked by replaying the declared rule schema. Oracle
applications are accepted only if the theory declares that oracle kind for the
target judgment and the active trust policy admits it.

The framework never treats a missing premise as a request to infer one.

## Roots

Roots state which accepted claims matter.

```text
Root {
  root_kind,
  node_id
}
```

Examples:

```text
program_has_type
module_exports
declaration_is_safe
class_table_well_formed
```

Root kinds are theory-declared. The framework checks that each root's `node_id`
points to an accepted evidence node with the judgment shape required by that
root schema.

## Oracles

An oracle is an explicit trust boundary, not a side condition.

```text
OracleSchema {
  oracle_kind,
  allowed_judgments,
  input_schema,
  result_schema,
  trust_policy_schema
}
```

Examples:

```text
SMTValidity
ExternalDeclaration
HostRuntimeFact
LegacyCheckerResult
UserUnsafeAssertion
```

Each oracle application must carry enough digested input to make the trusted
claim auditable and cache-safe. Digests do not replace payloads in the external
certificate; they bind inspectable payloads to cache keys and root digests. A
future binary encoding may optimize this, but the external interchange format
should remain deterministic and inspectable.

The first oracle result format is exact-claim only:

```text
OracleResult {
  claim,
  claim_digest
}
```

The checker verifies that `claim` is byte-for-byte the node claim after
canonicalization. Richer oracle result mappings require a separate declarative
mapping language whose syntax is canonicalized into the theory digest.

## Canonical Serialization

Canonical serialization is framework-owned for:

- theory specs;
- terms;
- claims;
- evidence nodes;
- roots;
- oracle applications.

Requirements:

- deterministic map ordering;
- explicit tags for every sum variant;
- alpha-stable binder encoding;
- no implicit numeric widening;
- no host-language table identity;
- digest includes theory ID and version;
- digest includes the selected root set.

JSON is acceptable as the first external certificate format. A binary encoding
may be added later only if it is a byte-for-byte canonical encoding of the same
abstract data model.

## First Full Validation Target

The first full concrete theory should be STLC, after the derivation checker has
binder replay and lookup-as-evidence.

STLC must require no framework changes beyond ordinary declarations for:

- categories `Term`, `Ty`, and `TypingContext`;
- term heads for variables, lambdas, applications, and arrows;
- context-role term heads for empty and extended typing contexts;
- judgments for well-formed types and typing;
- rules for variable lookup, arrow introduction, and arrow elimination.

If STLC needs a framework feature not listed here, that feature is probably a
real framework primitive. If STLC needs a Crescent-specific concept, the data
model is already wrong.

## Open Problems

- Whether rule schemas need a stronger pattern language before System F.
- How much substitution machinery should be framework-owned beyond
  capture-avoidance and alpha-equivalence.
- Whether oracle trust policies are framework-global or theory-local with a
  framework-defined shape.
