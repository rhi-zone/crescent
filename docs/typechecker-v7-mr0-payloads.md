# Typechecker v7 MR0 Payloads

This document turns `docs/typechecker-v7-minimal-replay-subset.md` into a
concrete verifier data model.

MR0 is not the full checker. It is the first certificate-replay slice. The
payloads below are intentionally explicit so a verifier can reject missing
semantic work instead of reconstructing it.

## Certificate Envelope

```text
MR0Certificate = {
  version: "v7-mr0",
  kernel_digest,
  target: TargetInput,
  sources: SourceInput*,
  declarations: DeclInput*,
  terms: TermEntry*,
  contexts: ContextEntry*,
  nodes: NodeEntry*,
  roots: RootEntry*
}
```

`declarations` are external inputs. They are not stdlib semantics. MR0 permits
only the trusted primitive-value declarations needed by the fixture being
checked.

The verifier rejects if:

- `version` is not exactly `v7-mr0`;
- target digest differs from the digest referenced by target-dependent nodes;
- a source/declaration digest is missing;
- a root references a failed node;
- any node references a later node.

Nodes are topologically ordered by ID. IDs are local to the certificate.

## Canonical Serialization

MR0 uses deterministic tagged data.

Rules:

- maps serialize with keys sorted by bytewise UTF-8 order;
- arrays preserve order;
- integers serialize in decimal without leading zeroes;
- strings serialize as UTF-8 length plus bytes;
- booleans and nil use fixed atoms;
- no source span participates in semantic equality;
- every enum tag is a closed string from this document.

Canonical digest:

```text
digest(x) = sha256(canonical_serialize(x))
```

If two semantically equal terms serialize differently, that is a verifier bug.

## Inputs

```text
TargetInput = {
  id: "luajit51-crescent",
  digest,
  table_digest
}

SourceInput = {
  source_id,
  digest,
  path_hint?
}

DeclInput = {
  decl_id,
  digest,
  entries,
  trust_kind
}
```

MR0 `DeclInput.entries` may contain only:

```text
trusted_value(name, type = primitive_cap("$SetMetatable" | "$GetMetatable" | "$RawGet" | "$RawSet" | "$RawEqual"))
```

No ordinary stdlib declarations, module declarations, FFI declarations, or
aliases are admitted in MR0.

## Terms

```text
TermEntry = {
  term_id,
  sort,
  payload
}
```

MR0 sorts:

```text
type
pack
effect
predicate
post
place
value_claim
pack_claim
```

Term IDs are content-addressable inside a certificate:

```text
term_id = "t:" + digest(sort, payload)
```

The verifier may recompute IDs and reject mismatches.

## Contexts

```text
ContextEntry = {
  context_id,
  locals,
  identities,
  live_facts,
  dependencies
}
```

`locals` map stable place IDs to value claims.

`identities` map table identity IDs to MR0 table states:

```text
TableState =
  open(fields, metatable_state)
  sealed(record_type, metatable_state)
  escaped

metatable_state =
  none
  fixed(value_claim)
```

MR0 does not admit `__index` or `__newindex`; metatable state exists only for
`$SetMetatable`/`$GetMetatable` replay and dependency invalidation.

Context IDs are also content-addressable:

```text
context_id = "c:" + digest(locals, identities, live_facts, dependencies)
```

## Node Envelope

```text
NodeEntry = {
  node_id,
  family,
  rule,
  inputs,
  outputs,
  premises,
  dependencies,
  provenance?
}
```

`premises` are prior `node_id`s. `dependencies` are not premises; they are
facts whose mutation invalidates the node's output.

## WFNode Payloads

```text
WFNode(rule = wf_type, inputs = { type }, outputs = { ok })
WFNode(rule = wf_pack_closed, inputs = { pack }, outputs = { ok })
WFNode(rule = wf_effect_pure, inputs = { effect = pure }, outputs = { ok })
WFNode(rule = wf_post_true, inputs = { post = true }, outputs = { ok })
WFNode(rule = wf_context, inputs = { context }, outputs = { ok })
```

The verifier checks category separation. A term of sort `pack` cannot satisfy
`wf_type`.

## SubNode Payloads

```text
SubNode(rule = refl, inputs = { a, b }, outputs = { ok })
SubNode(rule = never_left, inputs = { a = never, b }, outputs = { ok })
SubNode(rule = unknown_right, inputs = { a, b = unknown }, outputs = { ok })
SubNode(rule = literal_to_base, inputs = { literal, base }, outputs = { ok })
SubNode(rule = integer_to_number, inputs = { integer, number }, outputs = { ok })
SubNode(rule = union_left, inputs = { union, target }, premises = { each_arm_sub_target })
SubNode(rule = union_right_arm, inputs = { source, union, arm_index }, premises = { source_sub_arm })
SubNode(rule = intersection_left_arm, inputs = { intersection, arm_index, target }, outputs = { ok })
SubNode(rule = intersection_right, inputs = { source, intersection }, premises = { source_sub_each_arm })
SubNode(rule = record_width_depth, inputs = { source_record, target_record }, premises = { field_subs })
SubNode(rule = arrow_closed_pure, inputs = { source_arrow, target_arrow }, premises = { param_subs, return_subs })
```

Complement is deliberately absent from MR0 payloads except as a well-formed type
that cannot be used in a successful subtype proof. This avoids smuggling in an
emptiness decision procedure.

## ExprNode Payloads

```text
ExprNode(rule = literal_nil, outputs = { claim = nil })
ExprNode(rule = literal_boolean, inputs = { value }, outputs = { claim = literal(boolean, value) })
ExprNode(rule = literal_integer, inputs = { value }, outputs = { claim = literal(integer, value) })
ExprNode(rule = literal_number, inputs = { value }, outputs = { claim = literal(number, value) })
ExprNode(rule = literal_string, inputs = { value }, outputs = { claim = literal(string, value) })
ExprNode(rule = local_read, inputs = { context, place }, outputs = { claim })
ExprNode(rule = function_value, inputs = { arrow_type, body_node }, outputs = { claim })
ExprNode(rule = table_literal_fresh, inputs = { context_before }, outputs = { identity, context_after, claim })
ExprNode(rule = sealed_record_claim, inputs = { context, identity, record_type }, outputs = { claim })
```

`function_value` requires `body_node` to be a `StmtNode` or `GenericNode` that
checks the body under the arrow. It does not infer a signature.

## StmtNode Payloads

```text
StmtNode(rule = local_infer, inputs = { before, place, expr_node }, outputs = { after })
StmtNode(rule = local_annot, inputs = { before, place, expr_node, annotation_type, sub_node }, outputs = { after })
StmtNode(rule = assign_local, inputs = { before, place, expr_node, sub_node }, outputs = { after })
StmtNode(rule = assign_field_own_open, inputs = { before, table_claim, key, value_claim }, outputs = { after })
StmtNode(rule = return_closed, inputs = { before, expr_pack, expected_pack, pack_move_node }, outputs = { ok })
```

`assign_field_own_open` rejects unless the table claim contains an identity whose
state is open in `before`.

## PackMove Payloads

```text
PackMoveNode(rule = closed_exact, inputs = { source_pack, target_pack }, premises = { slot_subs })
PackMoveNode(rule = closed_return_adjust, inputs = { source_pack, target_pack }, premises = { adjusted_slot_subs })
PackMoveNode(rule = closed_call_adjust, inputs = { source_pack, target_pack }, premises = { adjusted_slot_subs })
```

MR0 admits closed packs only. Missing values in adjustment are `nil`; surplus
values are discarded only in the movement rules that say so.

## CallNode Payloads

```text
CallNode(rule = call_arrow, inputs = { callee_claim, arg_pack, arrow }, premises = { args_move }, outputs = { result_pack, effect = pure, post = true })
CallNode(rule = call_overload, inputs = { callee_claim, arg_pack, branch_nodes }, outputs = { pack_alt, effect = pure, post = true })
```

`call_overload` must name every matching branch. Branch matching is not searched
by the verifier. If two branches match and produce different effects or
postconditions, MR0 rejects because only `pure` and `true` are admitted.

## IdentityNode Payloads

```text
IdentityNode(rule = fresh_table, inputs = { before }, outputs = { identity, after })
IdentityNode(rule = write_open_own_field, inputs = { before, identity, key, value_claim }, outputs = { after })
IdentityNode(rule = seal_record_observation, inputs = { before, identity }, outputs = { record_type, after })
IdentityNode(rule = set_metatable_fixed, inputs = { before, identity, mt_claim }, outputs = { after })
IdentityNode(rule = get_metatable_public, inputs = { before, identity }, outputs = { result_pack, dependencies })
IdentityNode(rule = raw_get, inputs = { before, identity, key_claim }, outputs = { result_pack, dependencies })
IdentityNode(rule = raw_set, inputs = { before, identity, key_claim, value_claim }, outputs = { after })
IdentityNode(rule = raw_equal, inputs = { left_claim, right_claim }, outputs = { result_claim })
```

`set_metatable_fixed` rejects nil metatable claims and protected current
metatables in MR0.

## PrimitiveCallNode Payloads

```text
PrimitiveCallNode(rule = primitive_call, inputs = { callee_claim, primitive_name, arg_pack, before }, premises = { identity_node }, outputs = { result_pack, after })
```

The verifier checks:

- `callee_claim.type <: primitive_cap(primitive_name)`;
- the primitive name is in the MR0 primitive set;
- the referenced `IdentityNode` rule is the rule authorized by that primitive;
- the output context/result pack matches the identity node.

## UnsafeNode Payloads

```text
UnsafeNode(rule = force_claim, inputs = { site, exported_claim, boundary_kind, reason }, outputs = { claim })
UnsafeNode(rule = trusted_decl_value, inputs = { decl_input, name, exported_claim }, outputs = { claim })
```

`trusted_decl_value` is allowed in MR0 only for primitive capabilities. General
external declarations are an MR1+ environment feature.

## Root Payloads

```text
RootNode(kind = local_annotation, subject, claim, proof)
RootNode(kind = function_signature_export, subject, claim, proof)
RootNode(kind = overload_export, subject, claim, proof)
RootNode(kind = module_file_result_without_imports, subject, claim, proof)
RootNode(kind = unsafe_export, subject, claim, proof)
```

The verifier rejects a certificate with no roots.

## Replay Algorithm

1. Verify input digests.
2. Intern and validate term IDs.
3. Validate context IDs.
4. Iterate nodes in ID order.
5. For each node, validate premises are already accepted.
6. Replay the exact `family/rule`.
7. Recompute outputs and compare with node outputs.
8. Validate roots reference accepted nodes.

No step may search for an alternate rule.

## Adversarial Fixtures

MR0 should have accepted and rejected fixtures before implementation work starts.

Accepted:

- `local x: number = 1` via literal integer and `integer <: number`;
- `local x: "a" | "b" = "a"` via union-right named arm;
- `function f(x: integer): number return x end` via closed call/return movement;
- overloaded function exported only after the body checks under every branch;
- fresh table, own-field writes, sealed record observation;
- alias of trusted `$SetMetatable` capability works by value flow;
- `$RawEqual` returns boolean but exports no structural record facts.

Rejected:

- `local x: integer = 1.5`;
- overload export where one branch body fails;
- use of an overloaded call without naming all matching branches;
- field write through unknown `__newindex`;
- read through `__index`;
- `setmetatable(t, nil)`;
- `rawlen`;
- `type(x) == "string"` narrowing;
- source-name `setmetatable` shadow acquiring primitive behavior;
- unresolved `require` returning `unknown`.

These fixtures are semantic tests for the verifier, not v4/v5 compatibility
tests.
