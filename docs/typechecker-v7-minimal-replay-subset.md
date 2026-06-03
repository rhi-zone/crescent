# Typechecker v7 Minimal Replay Subset

This document defines the first verifier prototype slice.

The subset is intentionally small. Its purpose is to prove that v7's certificate
architecture can constrain accepted claims before the full Lua checker exists.

## Decision

The first replay subset is:

```text
MR0 = literals
    + scalar local annotations
    + closed-pack function calls
    + overload declarations checked under every branch
    + explicit unsafe boundaries
    + fresh table identity writes
    + sealed record observations
    + primitive capability calls for $SetMetatable, $GetMetatable, $RawGet,
      $RawSet, and $RawEqual
```

MR0 excludes every feature whose replay would require unresolved machinery:

- open/rest/variable packs;
- contextual effects except `pure`;
- `pcall`, `xpcall`, `error`, `assert` failure precision;
- coroutines;
- match types and first-order `TypeFn` reduction;
- HKTs/rank-N;
- modules, FFI, `$Require`, `$FfiC`, `$GlobalScope`;
- table `__index`/`__newindex` chain walking;
- operator metamethod dispatch;
- target string numeric conversion;
- cdata operators;
- recursive aliases.

Exclusion means reject or unsafe boundary, not fallback to `unknown`.

## Inputs

MR0 certificates require:

```text
TargetProfile("luajit51-crescent")
SourceDigest*
```

`ModuleEnv`, `DeclEnv`, and `FfiEnv` are empty in MR0 except for explicitly
trusted primitive-value declarations needed by the test fixture. This avoids
proving module/FFI/stdlib behavior before the environment bridge is implemented.

## Type Fragment

MR0 admits:

```text
never
unknown
nil
boolean
integer
number
string
literal(base, value)
primitive_cap(name)
arrow(params: closed BinderPack, effects: pure, returns: closed Pack, post: true)
record(fields, indexes = [], row = closed | open)
union
intersection
complement
```

Restrictions:

- no `Postcondition` except `true`;
- no rest or pack-variable tails;
- no effect except `pure`;
- no nominal/cdata/userdata precision beyond scalar atoms unless introduced by
  unsafe boundary;
- no metatable-expanded record observations.

## Well-Formedness Payloads

```text
WFNode(rule = wf_type, term_id)
WFNode(rule = wf_pack_closed, term_id)
WFNode(rule = wf_context, context_id)
```

The verifier checks kind/category separation:

- `Pack` is not a `Type`;
- `Postcondition` is not a `Type`;
- `primitive_cap(name)` uses an admitted primitive name;
- closed packs have finite item lists.

## Subtyping Payloads

MR0 subtyping includes:

- reflexivity;
- `never <: T`;
- `T <: unknown`;
- literal-to-base;
- `integer <: number`;
- union right/left rules only when premises are named;
- intersection right/left rules only when premises are named;
- complement only through explicitly admitted set-algebra rules;
- record width/depth over sealed record observations;
- arrow subtyping for closed pure arrows with contravariant parameters,
  covariant returns, and `post = true`.

Payload:

```text
SubNode(
  rule,
  producer_type,
  consumer_type,
  premises
)
```

No solver search is allowed. If the certificate does not name the rule and
premises, subtyping fails.

## Expression Payloads

MR0 expression nodes:

```text
ExprNode(rule = literal, expr_id, result: ValueClaim)
ExprNode(rule = local_read, expr_id, place_id, context_id, result)
ExprNode(rule = function_value, expr_id, arrow_type, body_proof, result)
ExprNode(rule = table_literal_fresh, expr_id, identity_id, context_before, context_after, result)
```

`table_literal_fresh` creates an open table identity. It does not export a
record type until sealed or otherwise observed by a rule that creates a sealed
record observation.

## Statement Payloads

MR0 statement nodes:

```text
StmtNode(rule = local_infer, stmt_id, before, expr_proof, after)
StmtNode(rule = local_annot, stmt_id, before, expr_proof, annotation_type, sub_proof, after)
StmtNode(rule = assign_local, stmt_id, before, expr_proof, sub_proof, after)
StmtNode(rule = assign_field_own_open, stmt_id, before, table_claim, key, value_claim, after)
StmtNode(rule = return_closed, stmt_id, before, expr_pack_proof, return_pack, pack_move_proof)
```

Field assignment is admitted only for own open table identities or existing own
fields whose write rule is proved. No `__newindex` fallback exists in MR0.

## Calls

MR0 call checking admits:

- ordinary `arrow` values;
- intersections of arrows as overload sets;
- closed argument packs;
- pure effects;
- closed return packs;
- `post = true`.

Payload:

```text
CallNode(
  rule = call_arrow | call_overload,
  callee_claim,
  arg_pack,
  selected_branches,
  param_pack_move_proofs,
  result_pack,
  effect = pure,
  post = true
)
```

Overload call result remains a `PackAlt` over matching branches. Slotwise union
requires a named correlation-loss movement; MR0 should avoid that movement
unless specifically testing it.

## Overload Declarations

Exporting an overloaded function requires body checking under every branch:

```text
RootNode(
  kind = overload_export,
  subject_id,
  exported_claim = intersection(arrow_1, ..., arrow_n),
  proof = OverloadExportNode(...)
)
```

Payload:

```text
GenericNode(
  rule = overload_export_all_branches,
  implementation_id,
  branch_arrows,
  body_proofs
)
```

This uses `GenericNode` only as a coarse certificate family. It does not admit
rank-1 generics.

## Table Identity And Records

MR0 table identity nodes:

```text
IdentityNode(rule = fresh_table, before, identity_id, after)
IdentityNode(rule = write_open_own_field, before, identity_id, key, value_claim, after)
IdentityNode(rule = seal_record_observation, before, identity_id, record_type, after)
IdentityNode(rule = invalidate_field_facts, before, identity_id, reason, after)
```

Record claims require sealed observations:

```text
ExprNode(rule = sealed_record_claim, identity_id, record_type, result)
```

Open construction state is never a `record` type.

## Primitive Calls

MR0 admits primitive capabilities only for:

```text
$SetMetatable
$GetMetatable
$RawGet
$RawSet
$RawEqual
```

Payload:

```text
PrimitiveCallNode(
  primitive_name,
  callee_claim,
  arg_pack,
  before,
  after,
  result_pack,
  dependencies,
  target_profile_id
)
```

Restrictions:

- `$SetMetatable` rejects `nil` metatable claims in MR0;
- `$SetMetatable` rejects protected current metatables under
  `luajit51-crescent`;
- `$GetMetatable` returns public protected view when applicable;
- raw operations bypass metamethods but still use identity state;
- `$RawEqual` does not export structural record equality facts.

## Unsafe Boundaries

MR0 admits explicit unsafe nodes so existing force-cast surfaces can be audited:

```text
UnsafeNode(site, exported_claim, boundary_kind, reason, provenance)
```

Unsafe nodes may be roots or dependencies. They are never accepted as proofs of
the underlying semantic relation.

Primitive-capability unsafe exports require a distinct boundary kind:

```text
boundary_kind = unsafe_primitive_cap_export
```

## Roots

MR0 root kinds:

```text
local_annotation
function_signature_export
overload_export
module_file_result_without_imports
unsafe_export
```

Every accepted user-visible claim must be reachable from a root.

## Rejected In MR0

Rejected unless explicitly unsafe:

- `unknown` arithmetic, field access, or calls;
- unproved module imports;
- any stdlib behavior that requires effects, packs, FFI, or type-level
  computation not in MR0;
- metatable `__index`, `__newindex`, `__call`, or operator metamethod dispatch;
- `setmetatable(t, nil)`;
- `rawlen`;
- `type(x)` narrowing;
- `pcall` precision;
- coroutine precision.

## Adversarial Review

Soundness lens: MR0 is deliberately boring. It should reject common Lua idioms
if their replay depends on unresolved effects, varargs, modules, or metamethods.

Ad-hocness lens: MR0 still includes primitive capabilities, which are dangerous.
The guardrail is that each primitive call is typed by capability value and has a
certificate node; no source-name dispatch is allowed.

Implementation lens: this subset is large enough to test the certificate shape:
subtyping, calls, overload branch checking, table identity, primitives, roots,
and unsafe boundaries all appear.

Scope lens: adding `type` narrowing, `pcall`, or `require` to MR0 would be
tempting, but each would force in another unresolved subsystem. They belong in
MR1+ after their own rules are complete.

## MR1 Pressure

Likely next replay subsets:

1. effects MR: `throws(E)`, `error`, `assert`, `pcall`;
2. pack MR: rest/variable packs, varargs, `select`, expression-list spread;
3. metatable MR: `__index`, `__newindex`, `__call`, operator metamethods;
4. environment MR: `ModuleEnv`, `DeclEnv`, `$Require`, `$GlobalScope`;
5. FFI MR: `FfiEnv`, `$FfiC`, cdata claims.
