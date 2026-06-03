# Typechecker v7 Design Pass: Generics, Kinds, And Type-Level Computation

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses the first-order boundary for generics and type-level computation.

## Question

What type-level computation is admitted before HKTs/rank-N?

The checker needs generic functions, generic aliases, recursive data, opaque
types, match types, and record field folds. But admitting arbitrary
higher-kinded functions before kinding, reduction, and termination are specified
would recreate the v4/v5 ad-hoc solver problem.

## First-Principles Derivation

Type-level computation is not value computation. It must be:

- kinded;
- total or reject on nontermination/budget failure;
- deterministic;
- side-effect free except for explicitly committed diagnostics;
- represented in certificates.

If type-level computation can construct `Type`, `Pack`, `Effect`, or
postcondition fragments, kinding must happen before those terms enter the value
type algebra.

## Decision

Choose a first-order type-level core before HKTs/rank-N:

```text
Kind =
  Type
  Pack
  Effect
  FieldDescriptor
  TypeFn(arg_kinds..., result_kind)
```

Admit:

- rank-1 bounded type parameters;
- generic aliases and generic functions;
- named first-order type-level functions;
- match types with deterministic reduction;
- guarded recursive aliases;
- nominal/opaque constructors with stable origin IDs;
- field descriptors and restricted field folds.

Reject for now:

- rank-N function values;
- arbitrary higher-kinded type variables;
- anonymous type-level lambdas as values;
- impredicative instantiation;
- type-level computation with speculative diagnostics or hidden state.

## Rank-1 Generics

Rank-1 generics quantify at declarations:

```text
forall <T <: Bound>. Type
```

Generic function bodies are checked with skolems:

```text
T := skolem(T, Bound, level)
```

The body must typecheck for the skolem, not for an inferred convenient witness.
Skolems must not escape their scope except through the quantified result.

This is enough for ordinary generic functions and aliases without rank-N.

## Generic Instantiation

Using a generic value instantiates its parameters with explicit or inferred
types satisfying bounds.

Instantiation emits certificate nodes:

```text
ForallElim(generic_id, args, bound_proofs)
ForallIntro(decl_id, skolem_context, body_proof)
```

Inference failure rejects. It must not create `unknown` type arguments unless
`unknown` satisfies the declared bound and the resulting use remains sound.

## Kinds

Kinds classify type-level terms.

Required base kinds:

- `Type`: value types;
- `Pack`: value-list types;
- `Effect`: contextual-control effects;
- `FieldDescriptor`: structural field metadata for record folds.

Only terms of kind `Type` enter ordinary value-type subtyping. Only terms of
kind `Pack` enter pack movement. Only terms of kind `Effect` enter effect
subsumption.

## Named Type-Level Functions

First-order type-level functions are named declarations:

```text
typefn F<A: K1, B: K2> -> K = body
```

They are not runtime values. They cannot be passed as arbitrary higher-kinded
arguments unless their name is accepted by a rule that expects a named
`TypeFn`.

This gives `$EachField<T, F>` a non-HKT route:

```text
F : TypeFn(FieldDescriptor) -> Type
```

where `F` is a named type-level function, not an arbitrary type variable of
higher kind.

## Match Types

Match types are the general type-level computation substrate.

Required properties:

- scrutinee kind is known;
- patterns are kinded;
- branches are checked before reduction;
- branch order is deterministic;
- unmatched cases reject or suspend according to a specified rule;
- reduction preserves correlation where the input kind carries alternatives;
- diagnostics are emitted only on committed reduction paths.

Speculative branch diagnostics are rejected.

## FieldDescriptor

Record field folds operate over `FieldDescriptor` values:

```text
FieldDescriptor = {
  key,
  value_type,
  optional,
  readonly,
  source_record
}
```

Field descriptors are type-level data. They are not string encodings like
`$opt_foo` or `$ro_bar`.

Folds over fields must specify:

- field enumeration order or prove order independence;
- optional/readonly handling;
- indexer handling;
- open-row behavior;
- failure behavior for non-record inputs.

## Recursive Aliases

Recursive aliases are admitted only with guarded unfolding.

Options:

- iso-recursive aliases with explicit fold/unfold;
- equi-recursive aliases with guarded normalization and cycle detection.

Decision direction: start with guarded equi-recursive aliases for type
normalization, with certificate nodes for unfold steps and budget failure as
rejection.

UNRESOLVED: exact normal form and equality algorithm.

## Opaque And Nominal Types

`$Opaque<T>` / `$Opaque<T, U>` belongs to this family as a nominal constructor.

Required rules:

- stable origin ID;
- hidden representation type;
- optional public view type;
- scoped unseal/projection authority;
- module-boundary interaction;
- certificate node for origin creation and view proof.

Opaque identity must not depend on call-site fingerprints or textual alias
names.

## `$Throw` / `$Catch`

`$Throw` / `$Catch` are type-level diagnostic/control operators, not runtime
effects.

They may be admitted only as part of committed-path type-level reduction.
Speculative branches must not emit diagnostics.

## Rejected Alternatives

### Arbitrary HKTs Now

Rejected for the next design stage:

```text
F<_> as an unconstrained higher-kinded type variable
```

Reason: this requires full kind polymorphism, type-level application,
definitional equality, and termination rules. The first-order named `TypeFn`
route covers field folds without admitting the whole feature.

### Untyped Match Evaluation

Rejected:

```text
match T with cases ...
```

without kinding every pattern and branch.

Reason: unkinded match is just a solver plugin.

### Helper Intrinsics As Substitute For Match

Rejected:

```text
$Keys, $Values, $PairsReturn, $EachUnion, ...
```

as permanent primitives when they only compensate for missing match/type-level
computation.

Reason: that path recreates a bag of one-off solvers. Helpers may exist only as
aliases or temporary rejected features until the substrate exists.

## Adversarial Review

### Soundness Lens

The design is sound-oriented because type-level computation is kinded,
deterministic, terminating-or-rejecting, and certificate-visible.

Residual risk: recursive aliases and complement/emptiness can interact badly.
The equality/normalization algorithm must reject on budget failure rather than
widening.

### Ad-Hocness Lens

The design channels `$EachField` and helper intrinsics through a general
first-order substrate instead of adding one intrinsic per missing operation.

Residual risk: named `TypeFn` could become a hidden HKT if functions are passed
around too freely. The rule must keep them first-order until HKTs are admitted.

### Expressiveness Lens

This is weaker than full HKTs/rank-N, but covers common generic aliases,
generic functions, match types, field folds, and opaque types.

Residual risk: some desired abstractions may require true HKTs. Those should be
recorded as pressure for a later HKT pass, not smuggled into first-order rules.

### Certificate Lens

Every reduction, instantiation, skolem introduction, unfold, and nominal-origin
creation needs a certificate node.

Residual risk: certificate size may grow. Compression is allowed only if the
verifier can replay the same deterministic reductions.

## Decision

Choose:

```text
rank-1 generics plus kinded first-order type-level computation now; HKTs and
rank-N remain later extensions
```

The following passes choose operator/metamethod semantics and then the
cross-cutting certificate schema.
