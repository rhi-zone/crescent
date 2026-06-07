# STLC Framework Theory

This document instantiates the type-system-agnostic framework with the simply
typed lambda calculus.

STLC is not the target language. It is the first full validation theory: if the
framework cannot express STLC without special cases, the framework data model is
wrong.

## Scope

Included:

- variables;
- lambda abstraction;
- application;
- unit term;
- unit type;
- arrow types;
- typing contexts;
- type well-formedness;
- term typing.

Excluded:

- subtyping;
- inference;
- effects;
- recursion;
- products, sums, records, references, classes, and modules;
- beta-reduction and operational semantics.

Beta-reduction is intentionally excluded from the first STLC theory because the
first validation target is derivation replay for typing, not progress and
preservation. A later STLC-safety theory may add reduction and soundness
theorems.

## Theory Spec

```text
TheorySpec {
  theory_id = "framework.stlc.v0",
  version = "0",
  categories = [Ty, Term],
  namespaces = [term_var],
  term_heads = [...],
  context_schemas = [TypingContext],
  judgment_schemas = [WFTy, HasType, Lookup],
  rule_schemas = [...],
  oracle_schemas = [],
  root_schemas = [TermHasTypeRoot]
}
```

There are no oracles. Every accepted typing claim must be justified by ordinary
rule evidence.

## Categories

```text
Category Ty
Category Term
```

`Ty` is the category of STLC types.

`Term` is the category of STLC terms.

The framework does not know that either category is a "type" or an "expression"
outside this theory.

## Term Heads

Types:

```text
TyUnit : Ty

TyArrow {
  param : Ty,
  result : Ty
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
```

The lambda binder has no framework-owned annotation field. Its parameter type is
an ordinary field of `TmLam`, and the binder identity is scoped over `body`.

## Context

The STLC context is a theory-declared inductive structure:

```text
CtxEmpty : TypingContext

CtxExtend {
  prev : TypingContext,
  var : BoundRef(term_var),
  ty : Ty
} : TypingContext
```

The framework checks only that this is well-formed structured data. Lookup is
not a framework side condition; it is the `Lookup` judgment below.

The context uses binder references rather than source names. Those binder
references must resolve in the surrounding claim scope. Source names may exist
in frontend metadata but are not trusted identity.

## Judgments

```text
WFTy(ctx : TypingContext, ty : Ty)

Lookup(ctx : TypingContext, var : BoundRef(term_var), ty : Ty)

HasType(ctx : TypingContext, term : Term, ty : Ty)
```

`WFTy` is included even though this STLC has only unit and arrows. Keeping it
explicit tests premise replay and prevents hidden well-formedness assumptions.

`Lookup` is explicit to avoid context lookup as framework magic.

## Rules

### WF Unit

```text
rule wf_unit:
  ----------------
  WFTy(ctx, TyUnit)
```

Metavariables:

```text
ctx : TypingContext input
```

### WF Arrow

```text
rule wf_arrow:
  WFTy(ctx, A)
  WFTy(ctx, B)
  -------------------------
  WFTy(ctx, TyArrow(A, B))
```

Metavariables:

```text
ctx : TypingContext input
A   : Ty input
B   : Ty input
```

### Lookup Head

```text
rule lookup_head:
  -------------------------------
  Lookup(CtxExtend(ctx, x, A), x, A)
```

`CtxExtend(ctx, x, A)` is an ordinary fixed-arity theory constructor. The
framework does not search the context.

Metavariables:

```text
ctx : TypingContext input
x   : BoundRef(term_var) input
A   : Ty input
```

### Lookup Tail

```text
rule lookup_tail:
  Lookup(ctx, x, A)
  x != y
  --------------------------------
  Lookup(CtxExtend(ctx, y, B), x, A)
```

`x != y` is a framework structural binder-identity inequality check after
alpha-normalization, not a source-name comparison.

Metavariables:

```text
ctx : TypingContext input
x   : BoundRef(term_var) input
y   : BoundRef(term_var) input
A   : Ty input
B   : Ty input
```

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
  Lookup(ctx, x, A)
  -------------------------
  HasType(ctx, TmVar(x), A)
```

### Arrow Introduction

```text
rule arrow_intro:
  WFTy(ctx, A)
  open lambda body as (x, body)
  HasType(CtxExtend(ctx, ref(x), A), body, B)
  WFTy(ctx, B)
  ----------------------------------------------
  HasType(ctx, TmLam(A, scoped x. body), TyArrow(A, B))
```

The binder `x` in the lambda body and the context entry must be the same binder
identity. The scoped-pattern opening extends the premise claim scope with binder
`x`; `ref(x)` is the bound reference to that binder. The repeated binder
metavariable requires alpha-normalized binder-identity equality.

Metavariables:

```text
ctx  : TypingContext input
x    : Binder(term_var) input
A    : Ty input
B    : Ty input
body : Term input
```

### Arrow Elimination

```text
rule arrow_elim:
  HasType(ctx, fn, TyArrow(A, B))
  HasType(ctx, arg, A)
  ---------------------------
  HasType(ctx, TmApp(fn, arg), B)
```

Metavariables:

```text
ctx : TypingContext input
fn  : Term input
arg : Term input
A   : Ty input
B   : Ty input
```

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
(\x:Unit. x) unit
```

The root claim is:

```text
HasType(CtxEmpty, TmApp(TmLam(TyUnit, scoped x. TmVar(ref(x))), TmUnit), TyUnit)
```

The evidence closure contains:

- `WFTy(CtxEmpty, TyUnit)` by `wf_unit`;
- `Lookup(CtxExtend(CtxEmpty, ref(x), TyUnit), ref(x), TyUnit)` by
  `lookup_head` under the lambda binder scope;
- `HasType(CtxExtend(CtxEmpty, ref(x), TyUnit), TmVar(ref(x)), TyUnit)` by
  `var` under the lambda binder scope;
- `HasType(CtxEmpty, TmLam(TyUnit, scoped x. TmVar(ref(x))),
  TyArrow(TyUnit, TyUnit))` by `arrow_intro`;
- `HasType(CtxEmpty, TmUnit, TyUnit)` by `unit_intro`;
- root application typing by `arrow_elim`.

This example requires binder replay, explicit lookup evidence, and first-order
rule-pattern matching. It requires no subtyping, inference, or Crescent-specific
concepts.

## Framework Pressure Points

STLC intentionally tests:

- binder identity and alpha-stable serialization;
- scoped term fields;
- context values as structured claim parameters;
- context lookup as ordinary evidence;
- repeated metavariable equality across premises and conclusion;
- root digest closure over a small evidence DAG.

If any of these require hardcoded STLC behavior, the framework is too weak.
