# Typechecker Framework Crescent Spike

This document specifies F6: the first tiny Crescent theory fixture set after
the framework has replayed non-Crescent validation theories.

F6 is not the full Crescent checker. It is a falsification test: can a small
Crescent-like fragment be expressed as declarative framework theory rules
without importing v7 MR0 node families or hidden solver code?

## Preconditions

Do not start F6 implementation until:

- F3 combinator replay works;
- F4 STLC replay works;
- F5 System F replay works;
- F1 root digests are alpha-stable;
- F2 rejects malformed scoped/binder evidence.

## Scope

Included:

- scalar type atoms;
- integer and number literals;
- value claims;
- closed packs;
- pure closed arrows;
- `integer <: number`;
- closed exact pack movement;
- pure arrow call.

Excluded:

- unions and intersections;
- nilability beyond a scalar atom fixture if needed;
- overloads;
- tables;
- mutation;
- effects;
- metatables;
- modules;
- FFI;
- stdlib declarations;
- primitive capabilities;
- unsafe/oracle boundaries.

## No MR0 Node Families

F6 must not use:

- `WFNode`;
- `SubNode`;
- `PackMoveNode`;
- `ExprNode`;
- `StmtNode`;
- `CallNode`;
- `UnsafeNode`;
- `PrimitiveCallNode`.

Those names may appear in commentary comparing to MR0, but not in the framework
certificate format or checker implementation.

Every accepted claim is an ordinary `EvidenceNode` proving a declared judgment
by applying a declared rule.

## Theory Categories

```text
Category Ty
Category Pack
Category ValueClaim
Category PackClaim
Category Expr
```

No category is built into the framework.

## Term Heads

Types:

```text
TyInteger : Ty
TyNumber : Ty
TyArrow(params: Pack, returns: Pack, effect: string) : Ty
```

Packs:

```text
PackClosed(items: [Ty]) : Pack
```

Claims:

```text
ValueClaim(type: Ty) : ValueClaim
PackClaim(pack: Pack) : PackClaim
```

Expressions:

```text
ExprInteger(value: integer) : Expr
ExprNumber(value: integer) : Expr
ExprConst(name: string) : Expr
ExprCall(fn: Expr, args: [Expr]) : Expr
```

F6 intentionally uses integer numeric payloads only. Non-integer Lua number
identity remains outside F1/F6 until a target-independent numeric decision is
made.

## Judgments

```text
WFTy(ty: Ty)
WFPack(pack: Pack)
Subtype(a: Ty, b: Ty)
PackMove(source: Pack, target: Pack)
HasValue(expr: Expr, claim: ValueClaim)
HasPack(exprs: [Expr], claim: PackClaim)
Call(callee: ValueClaim, args: PackClaim, result: PackClaim)
```

These names are theory-local. The framework does not know that `Subtype` is
subtyping or that `Call` is a function call.

## Rules

### Type Well-Formedness

```text
wf_integer:
  ----------------
  WFTy(TyInteger)

wf_number:
  ----------------
  WFTy(TyNumber)

wf_arrow:
  WFPack(params)
  WFPack(returns)
  effect == "pure"
  -------------------------------
  WFTy(TyArrow(params, returns, effect))
```

### Pack Well-Formedness

```text
wf_pack_empty:
  ------------------------
  WFPack(PackClosed([]))

wf_pack_one:
  WFTy(A)
  ------------------------
  WFPack(PackClosed([A]))
```

F6 admits only empty and one-element packs. Wider packs wait until the framework
has list-pattern fixture coverage.

### Subtyping

```text
sub_refl:
  WFTy(A)
  ----------------
  Subtype(A, A)

sub_integer_number:
  -----------------------------
  Subtype(TyInteger, TyNumber)
```

No solver search. If a certificate wants transitivity, a later theory rule must
state it explicitly.

### Pack Movement

```text
pack_move_empty:
  -----------------------------------------
  PackMove(PackClosed([]), PackClosed([]))

pack_move_one:
  Subtype(A, B)
  -----------------------------------------
  PackMove(PackClosed([A]), PackClosed([B]))
```

No call/return adjustment yet. Exact closed movement only.

### Literal Values

```text
integer_literal:
  -----------------------------------------------
  HasValue(ExprInteger(n), ValueClaim(TyInteger))

number_literal_from_integer_payload:
  ----------------------------------------------
  HasValue(ExprNumber(n), ValueClaim(TyNumber))
```

Both payloads are integers in F6. This avoids non-integer canonicalization.

### Expression Packs

```text
pack_empty:
  --------------------------------------
  HasPack([], PackClaim(PackClosed([])))

pack_one:
  HasValue(expr, ValueClaim(A))
  -----------------------------------------
  HasPack([expr], PackClaim(PackClosed([A])))
```

### Pure Arrow Constants

The theory may declare one fixture constant:

```text
id_integer : TyArrow(PackClosed([TyInteger]), PackClosed([TyInteger]), "pure")
```

As F6 has no oracle/trusted declaration machinery, this constant should be an
ordinary theory rule for the fixture:

```text
const_id_integer:
  ---------------------------------------------------------------------
  HasValue(ExprConst("id_integer"),
           ValueClaim(TyArrow(PackClosed([TyInteger]),
                              PackClosed([TyInteger]),
                              "pure")))
```

This is not a stdlib rule. It is a closed fixture constant.

### Calls

```text
call_pure_arrow:
  HasValue(fn, ValueClaim(TyArrow(params, returns, "pure")))
  HasPack(args, PackClaim(arg_pack))
  PackMove(arg_pack, params)
  ---------------------------------------------------------
  Call(ValueClaim(TyArrow(params, returns, "pure")),
       PackClaim(arg_pack),
       PackClaim(returns))
```

The call judgment is separated from expression typing so F6 can avoid specifying
evaluation order, multi-return expression syntax, or statement contexts.

## Accepted Fixture

```text
Call(
  ValueClaim(TyArrow(PackClosed([TyInteger]), PackClosed([TyInteger]), "pure")),
  PackClaim(PackClosed([TyInteger])),
  PackClaim(PackClosed([TyInteger])))
```

with premises proving:

- `ExprConst("id_integer")` has the arrow value claim;
- `ExprInteger(1)` has integer value claim;
- `[ExprInteger(1)]` has integer pack claim;
- exact one-slot pack movement succeeds by `sub_refl`.

## Rejected Fixtures

F6 should reject:

- passing `TyNumber` where `TyInteger` is required;
- using `integer <: number` backwards;
- omitting the `PackMove` premise;
- claiming a pure call result without a `call_pure_arrow` rule application;
- using an MR0 `CallNode`;
- using a trusted declaration/oracle for `id_integer`;
- using non-integer numeric payloads.

## Migration From MR0

MR0 can be used only as comparison material.

Allowed mining:

- fixture idea: integer literal accepted as integer;
- fixture idea: integer can move to number;
- fixture idea: pure closed-arrow call needs pack movement.

Not allowed:

- MR0 payload names;
- MR0 verifier helper functions;
- MR0 context object shape;
- MR0 primitive capability declarations;
- MR0 target profile assumptions.

## F6 Acceptance

F6 is complete when:

- the tiny Crescent theory is represented as a normal framework theory spec;
- accepted fixtures replay through ordinary rule applications;
- rejected fixtures fail with expected diagnostics;
- no checker code branches on Crescent term-head names;
- no `lib/type/v7_mr0/` module is imported;
- no MR0 node-family name appears in certificates.
