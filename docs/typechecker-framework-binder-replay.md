# Typechecker Framework Binder Replay

This document specifies F4: binder-aware replay for scoped terms, scoped claims,
alpha-equivalence, binder identity, and explicit syntactic substitution.

F4 is the first milestone capable of replaying STLC.

## Scope

Included:

- all F3 replay behavior;
- `binder` metavariables;
- `bound_ref` metavariables;
- `scoped` metavariables;
- `p_scoped`;
- `p_binder_ref`;
- `p_bound_ref`;
- scoped premise opening via `scope_from`;
- binder identity equality/inequality;
- alpha-equivalence;
- syntactic substitution structural checks.

Still excluded:

- oracle applications;
- theory-specific reduction;
- definitional equality;
- type-level evaluation;
- variadic binder lists;
- commutative premise sets.

## Scope Model

F4 uses the F0 scope model:

- each `Claim.scope` is one scope frame;
- each `Scoped.binders` list is one nested scope frame;
- bound-reference lookup starts at the innermost frame and walks outward;
- binder IDs are source labels only;
- semantic binder identity is lexical position after F1 projection.

Replay must never compare binder source names as semantic identity.

## Alpha-Normalization

F4 compares syntax under binders by alpha-normalizing both sides.

Alpha-normalization replaces every resolved bound reference with:

```text
AlphaRef {
  namespace,
  depth,
  index
}
```

`depth = 0` is the innermost scope frame. `index` is the binder position inside
that frame.

Two values are alpha-equivalent when their projections match after this
replacement.

## Binder Pattern Matching

F4 adds support for:

```text
p_scoped
p_binder_ref
p_bound_ref
```

`p_scoped` matches a `Scoped` value and may bind named binder metavariables and
a body pattern.

`p_binder_ref` matches a binder identity already introduced by scoped opening or
claim scope.

`p_bound_ref` matches a bound reference. Repeated occurrences compare by
resolved alpha identity, not source label.

## Scoped Opening

`scope_from` opens a scoped metavariable for selected premise patterns:

```text
ScopedOpenRef {
  source_metavariable,
  binder_metavariables,
  body_metavariable
}
```

Replay requirements:

- `source_metavariable` is already bound to a `Scoped` value;
- binder count equals `binder_metavariables` count;
- each opened binder is bound to the corresponding binder metavariable;
- the body is bound to `body_metavariable`;
- selected premise claim matching occurs under the opened binder scope;
- repeated binder metavariable occurrences enforce alpha-stable binder identity.

This is framework scope plumbing. It is not a language-specific typing rule.

## Binder Identity Conditions

F4 admits:

```text
cond_binder_eq(left, right)
cond_binder_neq(left, right)
```

Both operands must be binder metavariables.

Equality means same resolved binder identity after alpha-normalization.

Inequality means different resolved binder identity in the same namespace.

## Alpha-Equivalence Condition

F4 admits:

```text
cond_alpha_eq(left, right)
```

Operands must be syntax metavariables. Replay alpha-normalizes both values under
their current scopes and compares the projected syntax.

`cond_alpha_eq` is not reduction or definitional equality.

## Syntactic Substitution

F4 admits:

```text
cond_subst(source, binder, replacement, expected_result)
```

Operands:

- `source`: syntax metavariable;
- `binder`: binder metavariable;
- `replacement`: syntax metavariable;
- `expected_result`: syntax metavariable.

Replay performs capture-avoiding structural substitution of references to
`binder` in `source` with `replacement`, then alpha-compares the result with
`expected_result`.

Replay rejects if substitution would capture a free reference from
`replacement` and cannot be avoided by alpha-renaming binders in `source`.

Substitution does not:

- beta-reduce;
- normalize;
- evaluate type-level functions;
- unfold aliases;
- prove semantic equality.

## Claim Scope Replay

F4 validates and replays open premise claims.

A premise claim may have a non-empty `scope` only when the rule pattern opens a
scoped value and explicitly matches that premise under the extended scope.

Root handling remains stricter:

- `scope_policy = closed` rejects non-empty claim scopes;
- `scope_policy = open` admits roots with explicit claim scopes, but root digest
  still alpha-normalizes those scopes.

The first STLC root should be closed.

## STLC Replay Requirements

F4 is sufficient for the STLC theory if it can replay:

```text
rule arrow_intro:
  WFTy(ctx, A)
  open lambda body as (x, body)
  HasType(CtxExtend(ctx, ref(x), A), body, B)
  WFTy(ctx, B)
  ----------------------------------------------
  HasType(ctx, TmLam(A, scoped x. body), TyArrow(A, B))
```

Required framework behavior:

- open `scoped x. body`;
- bind `x` as a binder metavariable;
- bind `body` as a term metavariable under `x`;
- match the premise claim under the extended scope;
- compare `ref(x)` by binder identity, not source spelling;
- produce an alpha-stable root digest.

## Rejected STLC Fixtures

F4 should reject:

- lambda body premise checked without opening the lambda scope;
- lambda body using an unbound variable;
- context entry using a different binder than the lambda body;
- root claim with non-empty scope when root policy is `closed`;
- two alpha-equivalent proofs producing different root digests.

## F4 Acceptance

F4 is complete when:

- STLC identity function replays;
- STLC identity application replays;
- alpha-renamed STLC fixtures produce the same root digest;
- binder mismatch fixtures reject;
- capture-prone substitution fixtures reject;
- `cond_subst` fixtures prove only syntactic substitution, not reduction.
