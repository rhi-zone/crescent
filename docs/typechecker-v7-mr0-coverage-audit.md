# Typechecker v7 MR0 Coverage Audit

This audit compares `docs/typechecker-v7-mr0-payloads.md` with the current
standalone verifier in `lib/type/v7_mr0/`.

## Current Verifier

Implemented replay families:

- `WFNode(wf_type)`;
- `WFNode(wf_pack_closed)`;
- `SubNode(refl | never_left | unknown_right | literal_to_base |
  integer_to_number | union_right_arm)`;
- `PackMoveNode(closed_exact | closed_call_adjust)`;
- `CallNode(call_arrow)`;
- literal `ExprNode` rules;
- `UnsafeNode(force_claim | trusted_decl_value)`;
- root validation by accepted proof.

Implemented fixture stance:

- accepted fixtures cover scalar annotations, named union-right introduction,
  explicit trusted primitive-capability boundaries, and closed arrow calls with
  named pack movement;
- rejected fixtures pin boundary behavior for overload calls, overload export,
  identity replay, primitive calls, predicate narrowing, imports, missing call
  pack movement, and call output mismatch.

## Gaps By Payload Family

`WFNode`:

- Missing `wf_pack_closed`, `wf_effect_pure`, `wf_post_true`, and `wf_context`.
- These are small but should be implemented only with the payload family that
  consumes them, otherwise they become inert green checks.

`SubNode`:

- Missing union-left, intersections, record width/depth, and arrow subtyping.
- Arrow subtyping is not prerequisite for the first `CallNode(call_arrow)`
  replay if the certificate names the exact arrow term being called.

`ExprNode`:

- Literal nodes exist.
- Local reads, function values, fresh table literals, and sealed-record claims
  require context and identity terms; defer until context replay is designed in
  the verifier.

`StmtNode`:

- Entire family missing.
- `return_closed` depends on closed pack movement, but statement replay should
  not be implemented before pack claims have a stable verifier representation.

`PackMoveNode`:

- `closed_exact` and `closed_call_adjust` are implemented.
- `closed_return_adjust` is still missing because it should be introduced with
  statement return replay.

`CallNode`:

- `call_arrow` is implemented.
- `call_overload` is still missing because branch matching must be explicit and
  no branch search is allowed.

`IdentityNode` and `PrimitiveCallNode`:

- Entire families missing.
- Do not implement primitive calls before identity replay; primitive calls must
  authorize exactly one identity transition, not emulate it.

`GenericNode`:

- Entire family missing.
- Overload export should remain rejected until there is a body-proof payload for
  every branch. Accepting an overload export from branch types alone would repeat
  the v4/v5 overload unsoundness.

Canonical serialization and digest checks:

- Entire layer missing.
- This is required before accepting external certificate files, but not before
  table-native verifier fixtures. Keep the distinction explicit.

## Implemented Follow-Up Slice

`PackMoveNode` plus `CallNode(call_arrow)` are now admitted by the table-native
MR0 verifier.

Implemented representation:

```text
type arrow = {
  tag = "arrow",
  params = pack,
  returns = pack,
  effect = "pure",
  post = true
}

pack = {
  tag = "pack",
  items = type*,
  rest = nil
}

value_claim = {
  type = type
}

pack_claim = {
  pack = pack
}
```

Implemented replay rules:

- `PackMoveNode(closed_exact)` requires source and target closed packs with the
  same length, plus one accepted subtyping premise per slot.
- `PackMoveNode(closed_call_adjust)` is currently identical to `closed_exact`;
  no missing-value or surplus-value adjustment is admitted yet.
- `CallNode(call_arrow)` checks the callee claim's type is exactly the named
  arrow, its argument pack is moved by the named pack-move premise into the
  arrow parameter pack, and its output is the arrow return pack with
  `effect = pure` and `post = true`.

Adversarial fixtures now reject missing pack-move premises, mismatched call
outputs, pack-move target mismatches, and overload calls.

## Next Implementation Slice

Choose between statement return replay and canonical serialization.

Statement return replay is the smallest semantic continuation if the goal is to
accept the full `function f(x: integer): number return x end` fixture. Canonical
serialization is the smaller trust-boundary continuation if the goal is to
accept certificates from disk instead of in-memory fixtures.

Do not implement primitive capability calls next; they depend on identity replay
and would otherwise be a disguised special case.

## Original Pack/Call Plan

This was the plan implemented by the follow-up slice:

Admit `PackMoveNode` plus `CallNode(call_arrow)` over table-native certificates.

Minimum representation:

```text
type arrow = {
  tag = "arrow",
  params = pack,
  returns = pack,
  effect = "pure",
  post = true
}

pack = {
  tag = "pack",
  items = type*,
  rest = nil
}

value_claim = {
  type = type
}

pack_claim = {
  pack = pack
}
```

Replay rule:

- `PackMoveNode(closed_exact)` requires source and target closed packs with the
  same length, plus one accepted subtyping premise per slot.
- `PackMoveNode(closed_call_adjust)` is identical to `closed_exact` for MR0's
  first call slice; no missing-value or surplus-value adjustment is admitted
  until fixtures require it.
- `PackMoveNode(closed_return_adjust)` remains rejected until statement return
  replay exists.
- `CallNode(call_arrow)` checks the callee claim's type is exactly the named
  arrow, its argument pack is moved to the arrow parameter pack by the named
  premise, and its output is the arrow return pack with `effect = pure` and
  `post = true`.

Adversarial checks:

- reject call replay without a pack-move premise;
- reject mismatched call output even if argument movement succeeds;
- reject non-pure or non-true arrow payloads in MR0;
- reject overload call until `call_overload` has explicit branch matching
  payloads.
