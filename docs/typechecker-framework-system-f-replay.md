# Typechecker Framework System F Replay

This document specifies F5: replaying the System F validation theory with the
same framework checker substrate.

F5 should add no new framework semantics beyond F4. Its purpose is to prove that
the existing binder, scoped-opening, and syntactic-substitution machinery can
express type abstraction and type application.

## Scope

Included:

- all F4 replay behavior;
- multiple binder namespaces;
- type binders;
- term binders;
- nested scoped terms/types;
- `cond_subst` over type syntax;
- System F accepted/rejected fixtures.

Excluded:

- new replay machinery;
- definitional equality;
- type-level reduction;
- implicit instantiation;
- inference;
- oracles.

If F5 needs new framework machinery, that is a design failure or a missing F4
requirement.

## Required Theory

F5 uses `docs/typechecker-framework-system-f.md`.

The checker must treat that theory like any other theory spec. It must not
hardcode:

- `TyForall`;
- `TmTyLam`;
- `TmTyApp`;
- `SubstTy`;
- type-variable lookup;
- term-variable lookup.

All of those are theory declarations, rule schemas, structural conditions, or
fixtures.

## Replay Requirements

F5 must replay:

- `wf_forall`;
- `forall_intro`;
- `forall_elim`;
- type lookup through term context extension;
- term lookup through type context extension;
- structural type substitution through arrows and foralls.

These exercise interaction between:

- term-variable namespace;
- type-variable namespace;
- nested scope frames;
- context-role syntax;
- open premise claims;
- binder identity equality;
- capture-avoiding substitution.

## Forall Introduction

The key rule shape:

```text
rule forall_intro:
  open type lambda body as (X, body)
  HasType(CtxType(ctx, ref(X)), body, B)
  WFTy(CtxType(ctx, ref(X)), B)
  ----------------------------------------------
  HasType(ctx, TmTyLam(scoped X. body), TyForall(scoped X. B))
```

Replay must:

- open the term's scoped type binder;
- bind `X` as a type-binder metavariable;
- check the body premise under `X`;
- check result type well-formedness under `X`;
- construct/match `TyForall(scoped X. B)` using the same binder identity;
- reject if the result type uses a different binder identity with the same
  source name.

## Forall Elimination

The key rule shape:

```text
rule forall_elim:
  HasType(ctx, fn, TyForall(forall_body))
  open forall_body as (X, B)
  WFTy(ctx, A)
  SubstTy(B, X, A, B_subst)
  --------------------------------
  HasType(ctx, TmTyApp(fn, A), B_subst)
```

Replay must:

- bind `forall_body` from the first premise;
- open the scoped forall body;
- perform structural substitution with explicit expected result;
- reject if the rule path omits an explicit `cond_subst`;
- reject if it tries to use definitional equality instead of substitution.

## Structural Substitution Cases

F5 must test `cond_subst` cases for:

- `TyUnit`;
- matching `TyVar`;
- non-matching `TyVar`;
- `TyArrow`;
- shadowing `TyForall`;
- non-shadowing `TyForall`;
- alpha-renaming before descending under `TyForall`.

The checker may implement substitution generically over framework syntax, but
the fixture set must demonstrate these System F cases.

## Accepted Fixtures

F5 should accept:

```text
(/\X. \x:X. x) [Unit] unit
```

It should also accept an alpha-renamed equivalent:

```text
(/\Y. \z:Y. z) [Unit] unit
```

Both must produce the same root digest.

## Rejected Fixtures

F5 should reject:

- type application through a rule without a `cond_subst` structural condition;
- substitution with the wrong expected result;
- capture-prone substitution that is not alpha-renamed;
- `forall_intro` where the term type binder and result forall binder are
  different binders with the same source label;
- term-variable lookup through a type context extension without evidence;
- type-variable lookup through a term context extension without evidence;
- any attempt to use an oracle for System F replay.

## Non-Goals

F5 does not prove System F progress/preservation.

It only validates that the framework can replay explicit System F typing
evidence without hidden type equality, reduction, or inference.

## F5 Acceptance

F5 is complete when:

- System F accepted fixtures replay;
- alpha-renamed accepted fixtures share root digests;
- all rejected fixtures fail with expected diagnostic categories;
- no checker code branches on System F term-head names except through declared
  theory schemas and structural conditions;
- no new framework structural condition is added for System F.
