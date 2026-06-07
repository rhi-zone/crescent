# Typechecker Framework Shape Validator

This document specifies F2: shape validation for theory specs and certificates.

F2 validates that F0 objects are well-formed framework data. It does not replay
rules, compute accepted roots, or decide theory semantics.

## Inputs

```text
ShapeInput {
  framework_version,
  theory_spec,
  certificate?
}
```

`certificate` is optional so a theory spec can be validated independently.

## Outputs

```text
ShapeResult =
  ShapeOk { indexes }
| ShapeRejected { errors }
```

`indexes` are implementation caches derived from the validated input, such as
categories by name and term heads by name. They are not semantic evidence.

## Validation Order

1. Validate common object rules.
2. Validate theory declaration uniqueness.
3. Validate field schemas.
4. Validate term-head and binder-schema declarations.
5. Validate judgment, rule, oracle, and root declarations.
6. If a certificate is present, validate certificate envelope.
7. Validate all certificate values under their expected schemas.
8. Validate evidence node references and root references.

F2 should collect independent errors where possible, but it must not guess
repair intent.

## Common Object Validation

Reject:

- unknown `tag`;
- missing required field;
- unknown field outside `meta`;
- JSON `null`;
- Lua `nil` stored as an array/map value;
- duplicate JSON keys;
- sparse arrays;
- mixed array/map tables;
- non-string map keys;
- metatables in table-native fixtures.

`meta` may contain diagnostic data but is not recursively interpreted as
framework data.

## Theory Declaration Validation

Reject duplicate names for:

- namespaces;
- categories;
- term heads;
- binder schemas;
- judgments;
- rules;
- oracle kinds;
- root kinds.

Reject declarations that reference missing names.

Context-role categories are ordinary categories. F2 verifies only that
`role = "context"` is an admitted role string.

## Field Schema Validation

For each `FieldSchema`, validate:

- `field_category.category` names a declared category;
- `field_bound_ref.namespace` names a declared namespace;
- `field_binder.binder_schema` names a declared binder schema;
- `field_scoped.binders[*].schema` names declared binder schemas;
- `field_scoped.body` is itself a valid field schema;
- `field_list.item` is valid;
- `field_literal.literal_kind` is admitted by F0;
- `field_enum.values` is non-empty and has no duplicates;
- `field_object.fields` has unique field names.

F2 does not decide whether a field schema is useful or inhabited.

## Term Head Validation

For each term head:

- `result_category` must name a declared category;
- field names must be unique;
- every field schema must be valid.

F2 does not require every category to have a term head. Empty categories are a
theory choice.

## Binder Schema Validation

For each binder schema:

- `namespace` must name a declared namespace;
- `category` must name a declared category;
- binder field names must be unique;
- every binder field schema must be valid.

Binder fields are checked in the outer scope when binder values are validated.

## Judgment Validation

For each judgment:

- judgment parameter names must be unique;
- every parameter schema must be valid.

F2 does not know which judgment is typing, subtyping, lookup, or reduction.

## Rule Declaration Validation

For each rule:

- `judgment` must name a declared judgment;
- metavariable names must be unique;
- each metavariable kind must be admitted by F0;
- `category` is required for `kind = "category"`;
- `namespace` is required for `kind = "bound_ref"` or `kind = "binder"`;
- modes are `input`, `output`, or `fresh`;
- conclusion judgment must match the rule's declared judgment;
- premise judgments must name declared judgments;
- patterns may reference only declared metavariables;
- structural condition operands must be explicit `operand_meta` or
  `operand_field` objects;
- structural condition operands may reference only declared metavariables.

F2 checks pattern shape but does not perform rule replay or determine whether a
rule is sound.

## Pattern Validation

F2 validates that:

- `p_meta.name` names a declared metavariable;
- `p_term.head` names a declared term head;
- `p_term.fields` exactly match the term-head field names;
- `p_scoped.binders` names binder metavariables;
- `p_list.items` are valid patterns;
- `p_object.fields` have unique names;
- `p_bound_ref.name` names a `bound_ref` metavariable;
- `p_binder_ref.name` names a `binder` metavariable;
- `p_literal.value` is in the F1 initial value domain;
- `p_enum.value` is a string.

F2 does not match patterns against claims. F3 does that.

## Scoped Open Validation

For each `scope_from`:

- `source_metavariable` must name a `scoped` metavariable;
- `binder_metavariables` must name `binder` metavariables;
- `body_metavariable` must name a metavariable compatible with the scoped body;
- binder count must be fixed by the source scoped field's schema when known.

If binder count cannot be known from the schema, the rule is rejected in F2.
F0/F2 do not admit variadic scoped openings.

## Structural Condition Validation

Validate condition operands by tag:

- `operand_meta.name` names a declared metavariable;
- `operand_field.base` names a declared metavariable;
- `operand_field.path` is a non-empty dense array of strings;
- `cond_category_eq`: operands are category-compatible;
- `cond_binder_eq`: operands are binder-compatible;
- `cond_binder_neq`: operands are binder-compatible;
- `cond_alpha_eq`: operands are syntax-compatible;
- `cond_subst`: source/replacement/expected_result are syntax-compatible,
  binder is binder-compatible;
- `cond_literal_eq`: operands are scalar-compatible;
- `cond_list_len_eq`: operands are list-compatible;
- `cond_digest_eq`: operands are digest-scalar-compatible.

F2 does not execute conditions. For `operand_field`, F2 does not prove that
the selected path exists for every future match; it validates only the explicit
operand shape and declared base metavariable.

## Oracle Declaration Validation

For each oracle declaration:

- `oracle_kind` must be unique;
- each `allowed_judgments` entry must name a declared judgment;
- `input_schema` must be valid;
- `result_schema` must be valid;
- `trust_policy_schema`, if present, must be valid.

F2 does not admit oracle applications in the first checker slice. It only
validates that oracle declarations are well-formed format objects.

## Root Declaration Validation

For each root declaration:

- `root_kind` must be unique;
- `required_judgment` must name a declared judgment;
- `required_claim_pattern.judgment` must match `required_judgment`;
- `scope_policy` must be `closed` or `open`;
- the claim pattern must be shape-valid.

F2 does not check whether any certificate root is accepted.

## Certificate Envelope Validation

For a certificate:

- `framework_version` must be supported;
- `theory_id` and `theory_version` must match the selected theory spec;
- evidence node IDs must be unique;
- root entries must have declared root kinds;
- every root `node_id` must reference an evidence node;
- every rule application must name a declared rule;
- every premise node ID must reference an evidence node;
- oracle applications are rejected in the first checker slice unless explicitly
  enabled by a later milestone.

F2 does not require premises to precede consumers. F3 may choose topological
ordering for replay.

## Value Validation

Values are validated under expected field schemas.

Term values:

- head must name a declared term head;
- fields must exactly match the term-head schema;
- each field value must validate against its field schema.

Bound references:

- namespace must name a declared namespace;
- `binder_id` must resolve in the current scope stack;
- resolved binder schema namespace must match the reference namespace.

Binders:

- `binder_id` must be unique in the current scope frame;
- schema must name a declared binder schema;
- fields validate in the outer scope.

Scoped values:

- binders validate in the outer scope;
- body validates in the scope extended by the binders.

Claims:

- claim scope binders validate as one outer frame;
- judgment must name a declared judgment;
- args must exactly match judgment parameters;
- each arg validates against its parameter schema under the claim scope.

## Evidence Node Shape Validation

For each evidence node:

- `theory_id` must match the certificate theory;
- `judgment` must match `claim.judgment`;
- claim must shape-validate;
- rule applications must name declared rules;
- oracle applications are rejected by the first checker slice;
- premise IDs must exist.

F2 does not check that the rule conclusion matches the claim. F3 does that.

## Diagnostics

Minimum diagnostic categories:

- unknown tag;
- missing required field;
- unknown field;
- duplicate declaration;
- missing declaration reference;
- malformed field schema;
- malformed term value;
- unresolved bound reference;
- binder namespace mismatch;
- malformed claim;
- malformed rule declaration;
- malformed structural condition;
- malformed evidence node;
- malformed root.

Diagnostics may include source spans from `meta`, but source spans do not affect
validation.

## F2 Acceptance

F2 is complete when fixtures demonstrate:

- a valid combinator theory shape-checks;
- a valid STLC theory shape-checks;
- duplicate category names are rejected;
- unknown term heads are rejected;
- bound references outside scope are rejected;
- binder namespace mismatches are rejected;
- unknown rule names are rejected;
- roots pointing at missing evidence are rejected;
- oracle applications are rejected in the first checker slice.
