# Typechecker Framework Canonicalization

This document specifies F1: canonical serialization and semantic identity for
the F0 framework object format.

It defines semantic projections and digests. It does not specify derivation
replay.

## Inputs

F1 canonicalizes:

- `TheorySpec`;
- `Certificate`;
- terms;
- binders;
- scoped values;
- claims;
- rule declarations;
- evidence nodes;
- oracle envelopes;
- roots.

The source object format is `docs/typechecker-framework-format.md`.

## Non-Semantic Fields

The following are excluded from every semantic projection:

- `meta`;
- source spans;
- comments;
- display labels;
- JSON object member order;
- Lua table identity.

Unknown fields remain rejected by F0 shape validation. F1 does not silently
ignore unknown semantic-looking fields.

## Canonical Value Domain

The initial F1 canonical value domain is:

- tagged objects;
- arrays;
- maps with string keys;
- strings;
- integers;
- booleans.

Rejected before canonicalization:

- JSON `null`;
- Lua `nil` as a stored array/map value;
- NaN;
- non-integer numbers;
- infinities;
- functions, threads, userdata, cdata;
- metatables;
- sparse arrays;
- mixed array/map tables in table-native fixtures;
- duplicate JSON object keys.

Non-integer numeric canonicalization can be added as a separate decision because
cross-runtime identity matters.

## Encoding

Canonical serialization is a byte encoding over the semantic projection.

Required properties:

- every sum variant has an explicit tag;
- maps sort keys by bytewise UTF-8 order;
- arrays preserve order;
- strings are length-prefixed UTF-8 bytes;
- integers use decimal without leading zeroes;
- booleans use fixed atoms;
- object tags participate in the encoding;
- omitted optional fields are encoded as absent, not null.

The first implementation must document its exact byte grammar before accepting
fixtures. The grammar may be simple, but it is part of F1 and must be stable.

## Semantic Projection

Projection removes non-semantic fields and normalizes object shape.

Example:

```text
project({
  tag = "term",
  head = "TyUnit",
  fields = {},
  meta = { label = "unit" }
})
=
{
  tag = "term",
  head = "TyUnit",
  fields = {}
}
```

Projection never evaluates theory syntax. It only removes non-semantic wrapper
data and checks that F0 already accepted the shape.

## Binder Identity

Source `binder_id` labels are not semantic identity.

F1 encodes binders by lexical scope position:

```text
Claim.scope binder 0
Claim.scope binder 1
Scoped.binders binder 0
Scoped.binders binder 1
```

Bound references encode as de Bruijn-style references:

```text
BoundRef {
  namespace,
  depth,
  index
}
```

`depth = 0` refers to the innermost scope frame. `index` is the binder position
inside that frame.

This makes alpha-renaming stable:

```text
scoped x. TmVar(x)
scoped y. TmVar(y)
```

have the same semantic projection if their binder schemas and fields match.

## Binder Fields

Binder fields are projected in the outer scope, matching F0 scope validation.
The binder being declared is not visible inside its own fields.

If a theory needs self-referential binder metadata, it must encode that through
ordinary scoped syntax rather than binder fields.

## Terms

Term projection:

```text
TermProjection = {
  tag = "term",
  head,
  fields
}
```

The category is not duplicated in the term projection. It is determined by the
theory spec's term-head declaration.

Inline and interned terms project identically. Interning is a storage concern,
not semantic identity.

## Claims

Claim projection includes:

- scope projection;
- judgment name;
- projected arguments.

```text
ClaimProjection = {
  tag = "claim",
  scope,
  judgment,
  args
}
```

The claim digest must include the theory digest, because the same syntactic
claim has different meaning under different theory specs.

## Theory Digest

```text
theory_digest = sha256(canonical(project(theory_spec)))
```

The digest commits to:

- theory ID;
- version;
- namespace declarations;
- category declarations;
- term-head declarations;
- binder schemas;
- judgment schemas;
- rule schemas;
- oracle schemas;
- root schemas.

It excludes only `meta`.

## Evidence Node Digest

Evidence node projection:

```text
EvidenceProjection = {
  tag = "evidence",
  theory_digest,
  judgment,
  claim_digest,
  justification
}
```

For rule applications, `justification` includes:

- tag `rule_application`;
- rule name;
- ordered premise evidence digests.

For oracle applications, `justification` includes:

- tag `oracle_application`;
- oracle kind;
- projected input payload digest;
- projected result payload digest;
- trust policy ID;
- projected trust policy payload digest if present.

The first implementation may use user-supplied `node_id` labels for references,
but semantic root identity must be computed from reachable node projections, not
from source labels alone.

`node_id` labels are artifact-local references. They participate in
`certificate_digest`, but not in semantic evidence digests unless a future
node-ID policy explicitly makes them semantic.

## Root Digest

Accepted root identity is a Merkle DAG over the reachable accepted evidence
closure.

For one root:

```text
root_digest = sha256(canonical({
  tag = "root",
  root_kind,
  theory_digest,
  root_claim_digest,
  reachable_evidence
}))
```

`reachable_evidence` is the canonical sorted set of reachable evidence node
digests. Sorting is by digest bytes.

Premise order remains inside each evidence node digest. Unreachable evidence
nodes do not affect a root digest. Rejected nodes do not affect a root digest.

Root-set digest:

```text
root_set_digest = sha256(canonical({
  tag = "root_set",
  roots = sort(root_digest*)
}))
```

## Certificate Digest

Certificate digest is for artifact identity, not proof identity:

```text
certificate_digest = sha256(canonical(project(certificate)))
```

It may include unreachable evidence because it identifies the artifact as
provided. Root digests identify accepted proof content.

## Digest Prefixes

Human-facing IDs should use prefixes:

```text
theory:<hex>
claim:<hex>
node:<hex>
root:<hex>
rootset:<hex>
cert:<hex>
```

The prefix is not included inside the hashed payload unless explicitly stated
by the implementation. The hash payload must include a tag field to prevent
cross-kind collisions.

## External JSON

External JSON decoding must reject duplicate keys before F1 projection.

Decoded JSON objects are schema-directed F0 values. F1 canonicalization works
over decoded F0 objects, not raw JSON bytes.

Two JSON documents with different object key order but the same decoded F0
object have the same semantic projection.

## Table-Native Fixtures

Lua table fixtures must not rely on `pairs` order. The canonicalizer sorts map
keys itself.

Fixture tables must avoid:

- metatables;
- sparse arrays;
- mixed array/map tables;
- non-string map keys;
- values outside the canonical domain.

## F1 Acceptance

F1 is complete when fixtures demonstrate:

- `meta` changes do not change theory or claim digests;
- object key order does not change digests;
- alpha-renamed STLC identity terms produce the same claim digest;
- two different binder scopes with the same source names do not collide;
- changing a rule schema changes the theory digest;
- unreachable evidence changes certificate digest but not root digest;
- premise reordering changes an evidence node digest when the rule premises are
  ordered.
