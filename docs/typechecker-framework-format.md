# Typechecker Framework Format

This document specifies F0: the concrete table/JSON object format for framework
theory specs and certificates.

It defines shapes only. It does not specify canonical byte serialization,
semantic digests, or derivation replay. Those are F1+ concerns.

## Format Goals

The format must be:

- deterministic after schema-directed decoding;
- inspectable as JSON;
- representable as Lua tables for fixtures;
- independent of any specific type system;
- strict enough that malformed evidence is rejected before replay.

## Common Object Rules

Every sum object has a `tag` string.

Every object may include:

```text
meta = {
  source_span?,
  label?,
  comment?
}
```

`meta` is diagnostic only and ignored by F0 shape validation. F1+ digest specs
must exclude it from semantic identity.

Unknown fields are rejected unless the enclosing schema explicitly admits a
`meta` map.

JSON `null` is rejected everywhere. Optional fields are omitted, not set to
`null`.

Arrays are ordered. Maps are schema-directed and may only use string keys in
the external JSON format.

## Theory Spec

```text
TheorySpec = {
  tag = "theory_spec",
  theory_id: string,
  version: string,
  namespaces: NamespaceDecl[],
  categories: CategoryDecl[],
  term_heads: TermHeadDecl[],
  binder_schemas: BinderSchemaDecl[],
  judgments: JudgmentDecl[],
  rules: RuleDecl[],
  oracles: OracleDecl[],
  roots: RootDecl[],
  meta?
}
```

`theory_id` and `version` are semantic fields. Changing either changes the
accepted evidence language.

## Namespaces

```text
NamespaceDecl = {
  tag = "namespace",
  name: string,
  meta?
}
```

Examples:

```text
{ tag = "namespace", name = "term_var" }
{ tag = "namespace", name = "type_var" }
```

## Categories

```text
CategoryDecl = {
  tag = "category",
  name: string,
  role?: "context",
  meta?
}
```

`role = "context"` marks an ordinary category as context-like for diagnostics
and root policy checks. It does not give the framework lookup, weakening, or
merge behavior.

## Field Schemas

Field schemas are used by term heads, binders, judgments, oracle payloads, and
roots.

```text
FieldSchema =
  CategoryField
| BinderRefField
| BinderField
| ScopedField
| ListField
| LiteralField
| EnumField
| ObjectField
```

```text
CategoryField = {
  tag = "field_category",
  name: string,
  category: string
}

BinderRefField = {
  tag = "field_bound_ref",
  name: string,
  namespace: string
}

BinderField = {
  tag = "field_binder",
  name: string,
  binder_schema: string
}

ScopedField = {
  tag = "field_scoped",
  name: string,
  binders: BinderSchemaRef[],
  body: FieldSchema
}

ListField = {
  tag = "field_list",
  name: string,
  item: FieldSchema
}

LiteralField = {
  tag = "field_literal",
  name: string,
  literal_kind: "string" | "integer" | "number" | "boolean"
}

EnumField = {
  tag = "field_enum",
  name: string,
  values: string[]
}

ObjectField = {
  tag = "field_object",
  name: string,
  fields: FieldSchema[]
}
```

F0 does not admit open object fields outside `meta`.

F0 scoped fields have fixed binder lists. Telescopes or variadic binder lists
must be encoded as ordinary theory syntax until a later format version admits a
dedicated binder-list field.

## Values

`Value` is the payload language used inside terms, binders, claims, oracle
payloads, and patterns.

```text
Value =
  Term
| BoundRef
| Binder
| Scoped
| Value[]
| ObjectValue
| string
| integer
| number
| boolean

ObjectValue = {
  tag = "object",
  fields: { [field_name: string]: Value }
}
```

`ObjectValue` is schema-directed. It is not an open record facility for theory
semantics.

F0 has no separate global `Symbol` value. Global names should be represented by
declared theory terms, enum/literal fields, or future format extensions. Local
variables are represented by `BoundRef`.

```text
BinderSchemaRef = {
  tag = "binder_schema_ref",
  schema: string
}
```

## Term Heads

```text
TermHeadDecl = {
  tag = "term_head",
  name: string,
  result_category: string,
  fields: FieldSchema[],
  meta?
}
```

Example:

```text
{
  tag = "term_head",
  name = "TyArrow",
  result_category = "Ty",
  fields = [
    { tag = "field_category", name = "param", category = "Ty" },
    { tag = "field_category", name = "result", category = "Ty" }
  ]
}
```

## Binder Schemas

```text
BinderSchemaDecl = {
  tag = "binder_schema",
  name: string,
  namespace: string,
  category: string,
  fields: FieldSchema[],
  meta?
}
```

The `category` describes what kind of syntax the binder ranges over. Binder
schema fields are theory-owned metadata, not framework annotations.

## Terms

```text
Term = {
  tag = "term",
  head: string,
  fields: { [field_name: string]: Value },
  meta?
}
```

Terms do not carry their category redundantly. The category is determined by
the declared term head.

## Binders And Bound References

Binder occurrence:

```text
Binder = {
  tag = "binder",
  binder_id: string,
  schema: string,
  fields: { [field_name: string]: Value },
  meta?
}
```

Bound reference:

```text
BoundRef = {
  tag = "bound_ref",
  binder_id: string,
  namespace: string
}
```

`binder_id` is an F0 reference label local to a scope frame. It is not semantic
identity by itself.

Scope resolution:

- each `Claim.scope` and each `Scoped.binders` list is one scope frame;
- `binder_id` values must be unique within one frame;
- nested frames may reuse the same `binder_id`;
- bound-reference lookup starts at the innermost frame and walks outward;
- `BoundRef.namespace` must match the namespace of the resolved binder schema;
- binder `fields` are checked in the outer scope, not in the scope introduced
  by that binder;
- a `Scoped.body` is checked in the outer scope extended by its binders.

## Scoped Values

```text
Scoped = {
  tag = "scoped",
  binders: Binder[],
  body: Value
}
```

`body` is checked under the scope extended by `binders`.

## Claims

```text
Claim = {
  tag = "claim",
  scope: Binder[],
  judgment: string,
  args: { [param_name: string]: Value },
  meta?
}
```

Root claims usually have `scope = []`. Premise claims may be open under binders
introduced by scoped rule-pattern destructuring.

## Judgments

```text
JudgmentDecl = {
  tag = "judgment",
  name: string,
  params: FieldSchema[],
  meta?
}
```

Judgment parameters may reference declared categories and bound-reference
sorts. Contexts are just category fields whose category has role `context`.

## Rule Declarations

```text
RuleDecl = {
  tag = "rule",
  name: string,
  judgment: string,
  metavariables: MetavariableDecl[],
  conclusion: ClaimPattern,
  premises: PremisePattern[],
  structural_conditions: StructuralCondition[],
  meta?
}
```

```text
MetavariableDecl = {
  tag = "metavariable",
  name: string,
  kind: "category" | "bound_ref" | "binder" | "scoped" | "scalar",
  category?: string,
  namespace?: string,
  mode: "input" | "output" | "fresh"
}
```

F0 rule patterns are first-order and fixed arity. No ellipses, list splats,
associative matching, commutative matching, or implicit premise reordering are
admitted.

## Patterns

```text
ClaimPattern = {
  tag = "claim_pattern",
  judgment: string,
  args: { [param_name: string]: Pattern }
}

PremisePattern = {
  tag = "premise_pattern",
  claim: ClaimPattern,
  scope_from?: ScopedOpenRef
}

ScopedOpenRef = {
  tag = "scoped_open",
  source_metavariable: string,
  binder_metavariables: string[],
  body_metavariable: string
}
```

`source_metavariable` must already be bound by an earlier pattern to a `Scoped`
value. Opening it binds each `binder_metavariables` entry to the corresponding
scoped binder and binds `body_metavariable` to the scoped body under the
extended premise scope.

```text
Pattern =
  { tag = "p_meta", name: string }
| { tag = "p_term", head: string, fields: { [field_name: string]: Pattern } }
| { tag = "p_scoped", binders: string[], body: Pattern }
| { tag = "p_list", items: Pattern[] }
| { tag = "p_object", fields: { [field_name: string]: Pattern } }
| { tag = "p_bound_ref", name: string }
| { tag = "p_binder_ref", name: string }
| { tag = "p_literal", value: string | integer | number | boolean }
| { tag = "p_enum", value: string }
```

`p_binder_ref` refers to a binder metavariable. `p_bound_ref` refers to a
bound-reference metavariable.

F0 list and object patterns are fixed shape. They do not admit rest fields,
optional fields, or unordered matching.

## Structural Conditions

```text
StructuralCondition =
  { tag = "cond_category_eq", left: ConditionOperand, right: ConditionOperand }
| { tag = "cond_binder_eq", left: ConditionOperand, right: ConditionOperand }
| { tag = "cond_binder_neq", left: ConditionOperand, right: ConditionOperand }
| { tag = "cond_alpha_eq", left: ConditionOperand, right: ConditionOperand }
| { tag = "cond_subst", source: ConditionOperand, binder: ConditionOperand, replacement: ConditionOperand, expected_result: ConditionOperand }
| { tag = "cond_literal_eq", left: ConditionOperand, right: ConditionOperand }
| { tag = "cond_list_len_eq", left: ConditionOperand, right: ConditionOperand }
| { tag = "cond_digest_eq", left: ConditionOperand, right: ConditionOperand }

ConditionOperand =
  { tag = "operand_meta", name: string }
| { tag = "operand_field", base: string, path: string[] }
```

`operand_meta` names a rule metavariable. `operand_field` selects a nested
field from the value bound to a metavariable by a rule pattern. `path` is an
ordered sequence of object/term field names; F2 validates only the operand
shape and base metavariable existence, while F3+ decides whether the path is
valid for a matched value.

## Evidence Nodes

```text
EvidenceNode = {
  tag = "evidence",
  node_id: string,
  theory_id: string,
  judgment: string,
  claim: Claim,
  justification: RuleApplication | OracleApplication,
  meta?
}

RuleApplication = {
  tag = "rule_application",
  rule: string,
  premises: string[]
}
```

F0 only defines the oracle application envelope. The first checker slice rejects
oracle applications.

```text
OracleApplication = {
  tag = "oracle_application",
  oracle_kind: string,
  input_payload: Value,
  input_digest?: string,
  result_payload: Value,
  result_digest?: string,
  trust_policy_id: string,
  trust_policy_payload?: Value
}
```

`input_digest`, `result_digest`, and claim digests inside oracle payloads are
opaque F1+ fields. F0 validates only their field shape when present.

## Oracles

```text
OracleDecl = {
  tag = "oracle",
  oracle_kind: string,
  allowed_judgments: string[],
  input_schema: FieldSchema,
  result_schema: FieldSchema,
  trust_policy_schema?: FieldSchema,
  meta?
}
```

The first admitted result schema is exact-claim only:

```text
OracleResultExactClaim = {
  tag = "oracle_result_exact_claim",
  claim: Claim,
  claim_digest?: string
}
```

## Roots

```text
RootDecl = {
  tag = "root_decl",
  root_kind: string,
  required_judgment: string,
  required_claim_pattern: ClaimPattern,
  scope_policy: "closed" | "open"
}

Root = {
  tag = "root",
  root_kind: string,
  node_id: string,
  meta?
}
```

`node_id` is the referenced evidence node ID.

## Certificate

```text
Certificate = {
  tag = "certificate",
  framework_version: string,
  theory_id: string,
  theory_version: string,
  terms?: Term[],
  evidence: EvidenceNode[],
  roots: Root[],
  meta?
}
```

`terms` is optional because terms may appear inline in claims and rule payloads.
An implementation may intern terms for sharing, but interning is not semantic in
F0.

## External JSON Boundary

The external JSON format is schema-directed:

- top-level value is one `TheorySpec` or one `Certificate`;
- duplicate object keys are rejected;
- JSON `null` is rejected;
- arrays preserve order;
- objects use string keys only;
- omitted optional fields use the default named by this spec;
- unknown fields are rejected except inside `meta`.

The MIME types are provisional:

```text
application/vnd.crescent.typeframework.theory+json
application/vnd.crescent.typeframework.certificate+json
```

## F0 Acceptance

F0 is complete when these table-native fixtures can be shape-checked:

- an empty theory with no roots rejected as unusable;
- a combinator theory with no binders;
- a malformed theory with duplicate category names rejected;
- a malformed certificate with unknown term head rejected;
- a malformed certificate with JSON null rejected at decode boundary.
