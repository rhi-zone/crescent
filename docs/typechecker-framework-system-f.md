# System F Framework Theory

This document instantiates the framework with a small explicitly typed System F
subset.

System F is the second validation theory. Its job is to test whether the
framework handles multiple binder namespaces, scoped type binders, and explicit
syntactic substitution without adding type-system-specific machinery to the
trusted core.

## Scope

Included:

- term variables;
- type variables;
- term lambda abstraction;
- term application;
- type abstraction;
- type application;
- unit term;
- unit type;
- arrow types;
- universal types;
- typing contexts;
- type-variable lookup;
- term-variable lookup;
- explicit syntactic type substitution.

Excluded:

- subtyping;
- inference;
- recursive types;
- existentials;
- products, sums, records, references, classes, modules, and effects;
- beta-reduction, type erasure, and operational semantics.

## Context And Substitution Discipline

Contexts are ordinary theory syntax:

```text
Category TypingContext { role = context }

CtxEmpty : TypingContext
CtxTerm(prev : TypingContext, var : BoundRef(term_var), ty : Ty)
  : TypingContext
CtxType(prev : TypingContext, var : BoundRef(type_var))
  : TypingContext
```

Lookup is evidence, not framework behavior:

```text
LookupTerm(ctx, x, A)
LookupType(ctx, X)
```

Type substitution is a framework structural check only when written as an
explicit substitution condition:

```text
SubstTy(source, binder, replacement, expected_result)
```

The framework checks alpha-stable capture-avoiding traversal. It does not
perform definitional equality, reduction, normalization, or type-level
evaluation. If a future theory wants those, they are separate judgments or
oracles.

## Theory Spec

```text
TheorySpec {
  theory_id = "framework.system_f.v0",
  version = "0",
  categories = [Ty, Term, TypingContext],
  namespaces = [term_var, type_var],
  term_heads = [...],
  judgment_schemas = [WFCtx, WFTy, LookupType, LookupTerm, HasType],
  rule_schemas = [...],
  oracle_schemas = [],
  root_schemas = [TermHasTypeRoot]
}
```

There are no oracles.

## Categories

```text
Category Ty
Category Term
Category TypingContext { role = context }
```

## Term Heads

Types:

```text
TyUnit : Ty

TyVar {
  ref : BoundRef(type_var)
} : Ty

TyArrow {
  param : Ty,
  result : Ty
} : Ty

TyForall {
  body : Scoped([Binder(type_var, Ty, {})], Ty)
} : Ty
```

Terms:

```text
TmUnit : Term

TmVar {
  ref : BoundRef(term_var)
} : Term

TmLam {
  param_ty : Ty,
  body : Scoped([Binder(term_var, Term, {})], Term)
} : Term

TmApp {
  fn : Term,
  arg : Term
} : Term

TmTyLam {
  body : Scoped([Binder(type_var, Ty, {})], Term)
} : Term

TmTyApp {
  fn : Term,
  arg_ty : Ty
} : Term
```

Contexts:

```text
CtxEmpty : TypingContext

CtxTerm {
  prev : TypingContext,
  var : BoundRef(term_var),
  ty : Ty
} : TypingContext

CtxType {
  prev : TypingContext,
  var : BoundRef(type_var)
} : TypingContext
```

## Judgments

```text
WFCtx(ctx : TypingContext)

WFTy(ctx : TypingContext, ty : Ty)

LookupType(ctx : TypingContext, var : BoundRef(type_var))

LookupTerm(ctx : TypingContext, var : BoundRef(term_var), ty : Ty)

HasType(ctx : TypingContext, term : Term, ty : Ty)
```

Contexts are syntactically well-formed as terms by the framework, but global
context validity is a theory judgment. Rules that rely on a valid environment
must premise `WFCtx`.

In lookup rules, metavariables named `x`, `y`, `X`, and `Y` range over
`BoundRef(...)` values unless the rule explicitly opens a scoped binder. In
scoped-opening rules, `ref(x)` or `ref(X)` denotes the bound reference for the
opened binder.

## Context Well-Formedness Rules

### WF Empty Context

```text
rule wf_ctx_empty:
  ----------------
  WFCtx(CtxEmpty)
```

### WF Term Context Extension

```text
rule wf_ctx_term:
  WFCtx(ctx)
  WFTy(ctx, A)
  ---------------------------
  WFCtx(CtxTerm(ctx, x, A))
```

### WF Type Context Extension

```text
rule wf_ctx_type:
  WFCtx(ctx)
  ---------------------------
  WFCtx(CtxType(ctx, X))
```

## Type Well-Formedness Rules

### WF Unit

```text
rule wf_unit:
  WFCtx(ctx)
  ----------------
  WFTy(ctx, TyUnit)
```

### WF Type Variable

```text
rule wf_type_var:
  LookupType(ctx, X)
  ------------------
  WFTy(ctx, TyVar(X))
```

### WF Arrow

```text
rule wf_arrow:
  WFTy(ctx, A)
  WFTy(ctx, B)
  -------------------------
  WFTy(ctx, TyArrow(A, B))
```

### WF Forall

```text
rule wf_forall:
  open forall body as (X, body)
  WFTy(CtxType(ctx, ref(X)), body)
  -------------------------------
  WFTy(ctx, TyForall(scoped X. body))
```

The premise is open under type binder `X`. `CtxType(ctx, ref(X))` is ordinary
context syntax using the bound reference to `X`.

## Lookup Rules

### Type Lookup Head

```text
rule lookup_type_head:
  WFCtx(ctx)
  -------------------------------
  LookupType(CtxType(ctx, X), X)
```

### Type Lookup Tail Over Type

```text
rule lookup_type_tail_type:
  LookupType(ctx, X)
  X != Y
  -------------------------------
  LookupType(CtxType(ctx, Y), X)
```

### Type Lookup Tail Over Term

```text
rule lookup_type_tail_term:
  LookupType(ctx, X)
  WFTy(ctx, A)
  -------------------------------
  LookupType(CtxTerm(ctx, y, A), X)
```

### Term Lookup Head

```text
rule lookup_term_head:
  WFTy(ctx, A)
  --------------------------------
  LookupTerm(CtxTerm(ctx, x, A), x, A)
```

### Term Lookup Tail Over Term

```text
rule lookup_term_tail_term:
  LookupTerm(ctx, x, A)
  WFTy(ctx, B)
  x != y
  --------------------------------
  LookupTerm(CtxTerm(ctx, y, B), x, A)
```

### Term Lookup Tail Over Type

```text
rule lookup_term_tail_type:
  LookupTerm(ctx, x, A)
  -------------------------------
  LookupTerm(CtxType(ctx, X), x, A)
```

Binder inequality is framework structural binder-identity inequality after
alpha-normalization.

## Term Typing Rules

### Unit Introduction

```text
rule unit_intro:
  WFTy(ctx, TyUnit)
  ----------------------
  HasType(ctx, TmUnit, TyUnit)
```

### Variable

```text
rule var:
  LookupTerm(ctx, x, A)
  -------------------------
  HasType(ctx, TmVar(x), A)
```

### Arrow Introduction

```text
rule arrow_intro:
  WFTy(ctx, A)
  open lambda body as (x, body)
  HasType(CtxTerm(ctx, ref(x), A), body, B)
  WFTy(ctx, B)
  ----------------------------------------------
  HasType(ctx, TmLam(A, scoped x. body), TyArrow(A, B))
```

`B` is checked in `ctx`, not under `x`, because System F types contain type
variables but not term variables. A type depending on a term binder is outside
this theory.

### Arrow Elimination

```text
rule arrow_elim:
  HasType(ctx, fn, TyArrow(A, B))
  HasType(ctx, arg, A)
  ---------------------------
  HasType(ctx, TmApp(fn, arg), B)
```

### Forall Introduction

```text
rule forall_intro:
  open type lambda body as (X, body)
  HasType(CtxType(ctx, ref(X)), body, B)
  WFTy(CtxType(ctx, ref(X)), B)
  ----------------------------------------------
  HasType(ctx, TmTyLam(scoped X. body), TyForall(scoped X. B))
```

The type binder in the term and the type binder in the result type are the same
opened binder identity. The premise is checked under the extended type-binder
scope.

The conclusion constructs a second scoped field, `TyForall(scoped X. B)`, using
the same opened binder metavariable `X`. The framework checks this as
alpha-normalized binder-identity equality; no System F-specific equality rule is
hidden here.

### Forall Elimination

```text
rule forall_elim:
  HasType(ctx, fn, TyForall(forall_body))
  open forall_body as (X, B)
  WFTy(ctx, A)
  SubstTy(B, X, A, B_subst)
  --------------------------------
  HasType(ctx, TmTyApp(fn, A), B_subst)
```

`SubstTy` is not a judgment and does not prove semantic equality. It is a
framework structural condition with explicit source, binder, replacement, and
expected result. The checker accepts it only by alpha-stable capture-avoiding
syntax traversal.

Metavariable order:

```text
ctx         : TypingContext input
fn          : Term input
forall_body : Scoped(type_var, Ty) output from premise 1
X           : Binder(type_var) output from scoped destructuring
B           : Ty output from scoped destructuring
A           : Ty input from premise 2
B_subst     : Ty output from SubstTy
```

## Structural Type Substitution

`SubstTy(source, binder, replacement, expected_result)` is defined structurally
over this theory's `Ty` grammar:

```text
SubstTy(TyUnit, X, A, TyUnit)

SubstTy(TyVar(ref(X)), X, A, A)

Y != X
--------------------------------
SubstTy(TyVar(ref(Y)), X, A, TyVar(ref(Y)))

SubstTy(P, X, A, P')
SubstTy(R, X, A, R')
-----------------------------------------------
SubstTy(TyArrow(P, R), X, A, TyArrow(P', R'))

SubstTy(TyForall(scoped X. Body), X, A, TyForall(scoped X. Body))

Y != X
Y not free in A after alpha-renaming if necessary
SubstTy(Body, X, A, Body')
---------------------------------------------------------
SubstTy(TyForall(scoped Y. Body), X, A, TyForall(scoped Y. Body'))
```

The last case is a structural traversal rule: the framework may alpha-rename
`Y` before descent to avoid capture of free type references in `A`. It still
does not perform type reduction or definitional equality.

## Root

```text
RootSchema TermHasTypeRoot {
  required_judgment = HasType,
  required_claim_pattern = HasType(ctx, term, ty),
  scope_policy = closed
}
```

A certificate may choose any closed accepted `HasType` claim as a root.

## Example Derivation Shape

For:

```text
(/\X. \x:X. x) [Unit] unit
```

The root claim is:

```text
HasType(
  CtxEmpty,
  TmApp(
    TmTyApp(
      TmTyLam(scoped X. TmLam(TyVar(ref(X)), scoped x. TmVar(ref(x)))),
      TyUnit),
    TmUnit),
  TyUnit)
```

The evidence closure includes:

- type lookup for `X` under `CtxType(CtxEmpty, ref(X))`;
- term lookup for `x` under `CtxTerm(CtxType(CtxEmpty, ref(X)), ref(x),
  TyVar(ref(X)))`;
- arrow introduction under the term binder;
- forall introduction under the type binder;
- forall elimination with explicit `SubstTy(TyArrow(TyVar(ref(X)),
  TyVar(ref(X))), X, TyUnit, TyArrow(TyUnit, TyUnit))`;
- unit introduction;
- arrow elimination.

This exercises two namespaces, nested scoped binders, context-role syntax, and
syntactic substitution without adding semantic computation to the framework.

## Framework Pressure Points

System F intentionally tests:

- separate term and type binder namespaces;
- scoped destructuring for type-level binders;
- open premise claims under type binders;
- repeated binder identity across term and type syntax;
- explicit syntactic substitution as a structural check;
- context lookup as ordinary evidence across different context constructors.

If this requires hidden type equality, context lookup, or type-level reduction,
the framework boundary is wrong.
