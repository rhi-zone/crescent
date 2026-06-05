# Typechecker v7 MR0 Coverage Audit

This audit compares `docs/typechecker-v7-mr0-payloads.md` with the current
standalone verifier in `lib/type/v7_mr0/`.

## Current Verifier

Implemented replay families:

- `WFNode(wf_type)`;
- `WFNode(wf_pack_closed)`;
- `SubNode(refl | never_left | unknown_right | literal_to_base |
  integer_to_number | union_right_arm)`;
- `PackMoveNode(closed_exact | closed_call_adjust | closed_return_adjust)`;
- `CallNode(call_arrow)`;
- `StmtNode(return_closed)`;
- literal `ExprNode` rules;
- `UnsafeNode(force_claim | trusted_decl_value)`;
- root validation by accepted proof.
- optional strict term-ID validation for canonicalizable table-native terms.

Implemented fixture stance:

- accepted fixtures cover scalar annotations, named union-right introduction,
  explicit trusted primitive-capability boundaries, and closed arrow calls with
  named pack movement, and closed returns with named return movement;
- rejected fixtures pin boundary behavior for overload calls, overload export,
  identity replay, primitive calls, predicate narrowing, imports, missing call
  pack movement, and call output mismatch.

## Gaps By Payload Family

`WFNode`:

- `wf_type` and `wf_pack_closed` are implemented.
- Missing `wf_effect_pure`, `wf_post_true`, and `wf_context`.
- The missing rules are small but should be implemented only with the payload
  family that consumes them, otherwise they become inert green checks.

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

- `return_closed` is implemented.
- Local inference, local annotation, local assignment, and field assignment are
  still missing.

`PackMoveNode`:

- `closed_exact`, `closed_call_adjust`, and `closed_return_adjust` are
  implemented as exact closed-pack movement with named slot premises.
- Missing-value and surplus-value adjustment are still not admitted.

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

- Table-native canonical serialization and SHA-256 term IDs are implemented.
- Strict mode can validate `term_id = "t:" .. sha256(canonical(sort, payload))`.
- Non-integer numeric payloads are not canonicalizable yet because MR0 has not
  specified a target-stable numeric literal encoding. This is deliberate:
  inventing `tostring(number)` as a digest input would bake host formatting into
  the trust boundary.
- Source/declaration/context/target digest validation and external certificate
  file parsing are still missing.

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

## Implemented Return Slice

`StmtNode(return_closed)` is now admitted by the table-native MR0 verifier.

Replay rule:

- `return_closed` consumes an existing `pack_claim`, an expected pack term, and a
  named `PackMoveNode`.
- The named pack movement must already be accepted, must have source equal to
  the returned pack claim, and must have target equal to the expected return
  pack.
- The node output is recomputed as `{ ok = true }`.

Adversarial fixtures reject return pack-move target mismatches.

## Next Implementation Slice

Choose between local/context replay and canonical serialization.

Local/context replay is the smallest semantic continuation if the goal is to tie
`return_closed` to an actual parameter binding and eventually accept the full
`function f(x: integer): number return x end` fixture. Canonical serialization is
the smaller trust-boundary continuation if the goal is to accept certificates
from disk instead of in-memory fixtures.

The first canonicalization slice is now present, so the remaining trust-boundary
work is external certificate parsing plus target/source/declaration/context
digest validation.

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
