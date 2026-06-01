# Typechecker v6 Records And Table Identity Design

This document pins the v6 implementation boundary for Lua tables. It exists to
prevent the record/table vertical from smuggling ad-hoc behavior into type nodes,
subtyping, or syntax rules.

The normative sources are:

- `docs/typechecker-v6-plan.md` §Table Identity and §Records.
- `docs/type-system-design/06-setmetatable-construction.md` for construction
  phase and seal rules.
- `docs/type-system-design/07-records.md` for record fields, rows, indexers, and
  variance.

## Decision

v6 keeps table identity in the fact/environment layer. It does not add an open
table type node to `StaticType`.

`RecordType` is a structural observation or requirement. It is valid input to
the pure value algebra and pure subtyping only when it represents a sealed
record observation. A table's construction phase is tracked by a table-identity
state, not by `RecordType.row`.

This gives v6 one boundary:

- `StaticType` answers "what value set is being observed or required?"
- table identity facts answer "which mutable runtime table does this value come
  from, and is it still constructible?"

Rules that need mutation, aliasing, escaping, or sealing must go through identity
operations before emitting ordinary subtype obligations.

## Two Kinds Of Openness

There are two unrelated meanings of "open". They must not share one field.

Construction phase:

- `phase = "open"` means the table identity is still under construction.
- Open identities may accept direct construction writes.
- Open identities are off-lattice staging facts and must not be compared by
  `subtype.is_subtype`.
- An open identity becomes sealed at a seal point and never reopens.

Structural row openness:

- `RecordType.row = "open"` means a structural record requirement/observation
  permits unlisted named fields by width subtyping.
- Row openness is a property of a record type.
- Row openness is part of pure record subtyping.
- Row openness does not imply the runtime table can be mutated or extended.

Therefore `RecordType.row = "open"` is not a construction-phase marker, and an
identity with `phase = "open"` is not automatically a structurally open record.

## Core Shapes

The implementation should introduce these shared shapes after the current M2
prototype:

```lua
IdentityId = integer
IdentityPhase = "open" | "sealed" | "escaped"

ValueClaim = {
  type = StaticType,
  identity = IdentityId | nil,
}

TableState = {
  id = IdentityId,
  phase = IdentityPhase,
  own_record = RecordType,
  metatable = ValueClaim | nil,
  escaped_reason = string | nil,
}
```

`ValueClaim` is not a type node. It is the movement-site claim carried by the
source checker and environment. Existing `BindingFact` and `ExprFact` should
eventually carry a `ValueClaim`; their current `type = StaticType` field is the
M2 scalar subset.

`TableState.own_record` records the fields owned by the identity. Metatable and
`__index` lookup are not eagerly flattened into this record. Lookup builds the
observable record view lazily, following M6.

## Why Identity Is Not A Type Node

Adding `TableRef(id)` or `OpenRecord(id)` to `StaticType` would make pure
subtyping depend on mutable environment state. That recreates the v4/v5 failure
mode: a type node would look algebraic while secretly requiring syntax/env
knowledge to interpret it.

The v6 rule is stricter:

- pure subtyping only sees `StaticType`;
- open identities are resolved by source/env operations before subtyping;
- sealing returns a sealed `RecordType` observation that can enter subtyping;
- attempts to subtype an open identity are checker bugs, not fallback behavior.

This makes the seam testable. A code path either has a `ValueClaim` and can ask
records/env to seal or mutate an identity, or it has only a `StaticType` and can
perform pure algebra.

## Identity Operations

The records/env layer should own these operations. Syntax rules should not edit
identity tables directly.

```lua
fresh_table(env, span) -> ValueClaim
bind_alias(env, symbol, claim, span) -> BindingFact
seal_for_observation(env, claim, reason, span) -> ValueClaim | error
write_field(env, receiver_claim, key, value_claim, span) -> error | nil
read_field(env, receiver_claim, key, span) -> ValueClaim | error
escape_identity(env, claim, reason, span) -> ValueClaim
invalidate_alias_facts(env, identity, reason, span)
```

`fresh_table` creates an identity with `phase = "open"` and an empty closed own
record. The initial claim carries the current own-record observation plus the
identity id. The identity id is the authority for future construction writes.

`seal_for_observation` is called before an identity flows into an ordinary
subtype obligation, annotated binding, return requirement, typed field store,
field read requiring fixed shape, method dispatch, or unknown-mutation boundary.
It changes `phase = "open"` to `phase = "sealed"` and returns a claim whose
`type` is the sealed record observation.

`escape_identity` is used when precision is lost: passing to an unknown-mutating
call, storing into an unknown container, returning without a precise expected
record, or exporting through an unchecked boundary. Escaped identities must not
accept construction extension. They may retain a conservative sealed observation
for reads already proven safe, but alias-sensitive flow facts must be
invalidated.

## Field Writes

Field writes are identity-sensitive.

Open direct construction write:

- allowed only when the receiver claim carries an open identity;
- adding a missing field extends `own_record.fields`;
- writing an existing field emits equality/invariance against the existing
  field type;
- the result updates the identity state, not a standalone record type.

Sealed field write:

- allowed only for existing mutable own fields or fields proven writable by a
  later metatable/indexer rule;
- readonly fields reject;
- absent fields reject;
- successful writes check against the existing field type and invalidate
  alias-sensitive field facts for that identity.

Escaped field write:

- direct shape extension rejects;
- existing-field writes require a sealed writable observation;
- if the checker cannot prove the write target is disjoint from existing aliases,
  it invalidates field facts for the identity.

## Field Reads

Field reads observe shape and therefore seal open identities first unless the
operation is explicitly a construction-only introspection rule. v6 should not add
such an introspection rule initially.

Read order:

1. Own named field.
2. Own indexers whose key type accepts the literal/dynamic key.
3. Metatable `__index` chain, with visited-identity cycle guard.
4. Optional/absent handling from M7.

An optional field of type `T` reads as `T | nil`. An absent optional supertype
field is a subtyping rule, not a successful concrete read from a sealed value.

## Alias And Flow Facts

Alias facts are about identities, not variable names.

If two bindings carry the same `identity`, a write through either binding may
invalidate narrowed field facts observed through the other. v6 starts
conservative:

- any write to identity `i` invalidates field facts for `i`;
- any unknown-mutating call receiving identity `i` escapes `i` and invalidates
  field facts for `i`;
- joins retain an identity fact only when all incoming claims carry the same
  identity and compatible sealed observation;
- open identities do not survive joins as open unless every path carries the
  same unescaped identity and the same construction state.

More precise disjoint-key invalidation can be added later, but the conservative
rule is the baseline.

## Record Subtyping

Record subtyping remains pure once both sides are `RecordType`.

The record rule follows M7:

- fields, indexers, and row are distinct regions;
- optional means possibly absent, not `T | nil`;
- required subtype field satisfies optional supertype field;
- optional subtype field does not satisfy required supertype field;
- readonly supertype fields are covariant;
- mutable supertype fields are invariant and require mutable subtype fields;
- index keys are contravariant;
- index values use the same readonly/mutable variance rule;
- row openness is structural width, not mutation permission.

Implementation should put this in `records.lua` or a record-owned helper called
from `subtype.lua`. The helper must accept only `RecordType`, not `ValueClaim` or
`TableState`.

## Minimal Implementation Order

1. Add `ValueClaim`, identity fact annotations, and env storage without changing
   scalar behavior.
2. Add `records.lua` with pure record subtyping helpers and tests.
3. Route `subtype.lua` record-record cases to the record helper.
4. Add `fresh_table` and open construction writes for table literals plus direct
   field assignment.
5. Add `seal_for_observation` before annotation/return/call obligations.
6. Add sealed field read/write rules and conservative alias invalidation.
7. Add `setmetatable`/`__index` only after the non-metatable identity lifecycle
   is green.

The first vertical should deliberately exclude metatables, dynamic indexers, and
module exports. If those are admitted before the identity lifecycle is tested,
they will hide whether the core model is coherent.

## Non-Goals For The First Vertical

- No `TableRef` or `OpenRecord` member in `StaticType`.
- No eager flattening of metatable fields into own records.
- No precise disjoint-field alias analysis.
- No post-seal shape extension.
- No use of `RecordType.row` to represent construction phase.
- No name-keyed `setmetatable` special case outside declared stdlib facts and
  the identity operation it denotes.

## Design Gates

The design is not implemented until these fixtures pass:

- construction write to a fresh table extends the identity;
- annotated binding seals and checks the identity against the annotation;
- missing field after seal rejects;
- readonly field write rejects;
- mutable field covariance rejects;
- readonly field covariance accepts;
- optional field read produces `T | nil`;
- alias write invalidates a prior narrowed field fact;
- structural open-row width subtyping accepts extra fields without permitting
  runtime shape mutation.

