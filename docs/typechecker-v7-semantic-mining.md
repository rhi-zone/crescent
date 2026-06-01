# Typechecker v7 Semantic Mining

This document records semantics worth mining for v7 and the ad-hocness checks
that decide whether a mined idea may enter the kernel.

Mining is not adoption. A feature observed in Crescent v4/v5 or another type
system is admissible only after it is restated as a small kernel contract with
well-formedness, reduction/subtyping rules, failure behavior, and certificate
nodes.

## Ad-Hocness Filter

A mined rule is suspect if any of these are true:

- it dispatches on a surface name instead of a typed head, kind, or judgment;
- it depends on parser/source spelling instead of semantic binding identity;
- it hides state changes inside a value type or ordinary arrow;
- it collapses correlated alternatives into slotwise unions before a named
  movement site;
- it performs speculative type-level computation with diagnostics or mutable
  context side effects;
- it has a trusted bridge to filesystem, FFI, globals, or declarations without a
  certificate boundary;
- it accepts a user-supplied guard/assertion/overload without checking the body
  under the exported contract;
- it returns `unknown` or a broad fallback as a convenience instead of as a
  specified safe top with explicit movement restrictions;
- it exists only because the implementation currently lacks a more general
  substrate.

Passing this filter is necessary, not sufficient. The imported rule still needs
a kernel contract.

## Crescent-Local Sources

### `$Require<T>`

Current contract: a literal string module name maps to a declared module or CRI
export type; nonliteral or unresolved modules return `unknown`.

v7 classification: trusted module-interface bridge, not pure type computation.

Ad-hocness risks:

- current implementation records side effects such as pending require metadata;
- module lookup depends on loader/cache state;
- unresolved modules returning `unknown` is safe only if `unknown` cannot be
  silently consumed as concrete structure.

v7 admission condition: `$Require` needs a module environment in the kernel
context and a certificate node proving that the interface used for a module name
matches the checked artifact or an explicit trusted boundary.

### `$Opaque<T>` / `$Opaque<T, U>`

Current contract: construct a nominal identity over `T`; the two-argument form
exposes view `U` while keeping the hidden representation nominal.

v7 classification: nominal-type constructor.

Ad-hocness risks:

- identity currently depends on call-site/fingerprint machinery;
- view validation must be a real subtype/observation proof, not a field loop;
- unsealing and module boundaries must agree on identity provenance.

v7 admission condition: nominal identities must be semantic atoms with stable
origin IDs. `$Opaque<T, U>` requires `U` to be a justified view of `T`, and field
access through the view must be ordinary record observation on `U`, not a solver
special case.

### `$FfiC`

Current contract: synthesize a closed table from `ffi.cdef` call sites so
`ffi.C`/`ffi.load` expose declared C symbols.

v7 classification: trusted FFI-state bridge.

Ad-hocness risks:

- it is not a pure type-level function;
- it depends on parsing C declarations and file-local side effects;
- missing-symbol behavior must be specified instead of inherited from tests.

v7 admission condition: FFI declarations become an explicit external-declaration
environment with a certificate or trusted boundary. `$FfiC` may then project a
closed record from that environment.

### `$GlobalScope`

Current contract: synthesize a closed table from `--:: declare` globals; `_G`
has that exact table shape.

v7 classification: trusted declaration-scope bridge.

Ad-hocness risks:

- depends on declaration load order and root-scope snapshot;
- can silently reintroduce ambient global behavior if the source of declarations
  is not explicit.

v7 admission condition: the global-scope record must be derived from an explicit
declaration environment in the certificate. No undeclared fallback indexer is
allowed.

### `$Throw<...Msg>` / `$Catch<T, Default?>`

Current contract: `$Throw` emits an authored diagnostic and reduces to `never`;
`$Catch` intercepts authored `$Throw` during type-level evaluation.

v7 classification: type-level diagnostic/control operator, not ordinary pure
type computation.

Ad-hocness risks:

- diagnostic side effects during speculative evaluation are order-sensitive;
- context flags such as catch mode are fragile under backtracking;
- solver errors and authored throws are different failure classes.

v7 admission condition: model type-level computation as producing either
`ok(Type)` or `throw(TypeMessage)`, with `$Catch` as an explicit reduction rule.
Diagnostics are emitted only after the selected reduction path is committed.

### `$EachField<T, F>`

Current contract: iterate record fields, pass a descriptor
`{ key, value, optional, readonly }` to type function `F`, and gather returned
field descriptors into a record.

v7 classification: type-level record fold/flatMap.

Ad-hocness risks:

- descriptor shape is a second record language unless specified precisely;
- indexer and row behavior is incomplete if only named fields participate;
- legacy descriptor/result compatibility paths can become de facto semantics.

v7 admission condition: define a `FieldDescriptor` kind, descriptor
well-formedness, distribution over unions, indexer/row policy, and gather
failure behavior. If HKTs are not admitted, `F` must be a restricted named
type-level function form.

### `$PatternReturn<P>` / `$FindReturn<P>`

Current contract: for literal Lua patterns, count captures and produce the
return pack for `string.match`, `string.gmatch`, or `string.find`; dynamic
patterns fall back to a broad safe shape.

v7 classification: domain-specific type-level evaluator for Lua pattern
syntax.

Ad-hocness risks:

- easy to become an approximate parser with unsound capture counts;
- runtime Lua pattern semantics are detailed and version-sensitive;
- broad fallback must be safe for all dynamic patterns.

v7 admission condition: specify the accepted Lua-pattern grammar subset, prove
capture-count soundness for that subset, and define dynamic/unsupported patterns
as a conservative overapproximation.

### Match Aliases Replacing Helper Intrinsics

Current contract: `Keys`, `Values`, `PairsReturn`, `IpairsReturn`, and
`PcallReturn` can be ordinary aliases using match patterns, tuple spread, and
field distribution.

v7 classification: prefer the general match/type-level substrate over one-off
`$` helpers.

Ad-hocness risks:

- if a helper is admitted because a match form is missing, the helper becomes a
  fossilized special case;
- match evaluation must preserve correlation and suspend/reject rather than
  guessing.

v7 admission condition: admit the match substrate and delete helper intrinsics
from the kernel unless a helper has independent semantic necessity.

## External Systems

### TypeScript

Mineable ideas:

- assertion signatures distinguish returned values from continuation facts;
- overload declarations have a separate implementation signature;
- conditional/mapped types show the demand for type-level computation.

Reject for v7 as-is:

- TypeScript is deliberately pragmatic and unsound in several areas;
- overload implementation signatures are not the same as checking a body under
  every overload branch;
- user type predicates/assertions can be trusted more than v7 permits.

v7 import rule: use the surface distinction between return values and
postconditions, but require proof of guard/assertion facts and overload bodies.

Primary references:

- TypeScript Handbook: narrowing and assertion functions.
- TypeScript Handbook: function overloads.
- TypeScript Handbook: conditional and mapped types.

### Flow

Mineable ideas:

- type guards refine branch facts;
- exact/inexact object distinctions are an explicit row/width boundary.

Ad-hocness warning: guard soundness depends on the checker proving or trusting
the predicate source. v7 cannot admit arbitrary predicate annotations as facts.

v7 import rule: branch refinement is a scoped fact transition. Exact object
typing supports the v7 distinction between closed records, open rows, and
indexers.

Primary reference:

- Flow documentation: type guards.

### Typed Racket

Mineable ideas:

- occurrence typing treats predicates as propositions about program terms;
- refinements are scoped to control-flow paths and invalidated by mutation or
  aliasing.

Ad-hocness warning: predicates must have a proposition semantics. A function
returning boolean is not automatically a guard.

v7 import rule: guard facts are proof-producing predicates attached to branch
edges, not global type changes.

Primary reference:

- Typed Racket Guide: occurrence typing.

### Luau

Mineable ideas:

- semantic subtyping over unions/intersections;
- type packs for multiple returns and variadics;
- table state/refinement for Lua idioms.

Reject for v7 as-is:

- Luau intentionally accepts gradual unsoundness and non-strict behavior;
- implementation-oriented table heuristics are not soundness evidence.

v7 import rule: keep semantic subtyping and packs, but every table refinement
must route through explicit identity/seal/alias rules.

Primary references:

- Luau type checking documentation.
- Luau research/design material on semantic subtyping where available.

### Koka

Mineable ideas:

- effects are computation properties carried by arrows, not value types;
- effect rows support polymorphism and handler/discharge rules.

Ad-hocness warning: modeling effects as strings or special return slots
recreates the v5 failure mode. Effect labels need kinding, payload subtyping,
composition, and discharge rules.

v7 import rule: effects remain excluded until admitted as a dedicated arrow
component with row well-formedness and certificate nodes.

Primary reference:

- Koka book/reference on effect types and effect handlers.

### OCaml / ML

Mineable ideas:

- value restriction prevents unsound polymorphism with mutable state;
- levels/skolems handle generalization and escape without per-feature hacks.

Ad-hocness warning: adding rank-N, mutable references, or polymorphic storage
without a unified generalization/escape discipline will create hidden
unsoundness.

v7 import rule: if rank-N or general references are admitted, include
skolem/level escape checks and a value restriction or equivalent capability
rule.

Primary references:

- OCaml manual sections on polymorphism and the value restriction.
- OCaml implementation literature on levels/generalization.

### Rust

Mineable ideas:

- traits/associated types provide named semantic interfaces for type-level
  operations;
- unsafe code is explicit and audited as a boundary rather than disguised as a
  normal proof.

Ad-hocness warning: importing trait-like machinery before kinds/HKTs are
specified would only rename ad-hoc dispatch.

v7 import rule: trait/interface mechanisms are future work gated on kinding,
associated type equality, and certificate evidence.

Primary reference:

- Rust Reference: traits, associated items, and unsafe code.

### Coq / Proof Assistants

Mineable ideas:

- judgments as inductive relations;
- proof terms/certificates checked by a small kernel;
- executable extraction can reduce implementation/spec drift.

Ad-hocness warning: mechanization does not prove the frontend generated the
right terms unless certificates connect source constructs to kernel judgments.

v7 import rule: define the kernel first as judgments and certificate checking
obligations. The production checker may be heuristic, but accepted programs
must have replayable proof objects.

Primary reference:

- Coq Reference Manual: inductive definitions, universes, extraction.

## Import Order

The safe import order is:

1. value lattice, packs, and record/table identity already in the v7 kernel;
2. nominal opacity (`$Opaque`) because it is a value-type constructor;
3. match substrate and field descriptors before `$EachField`;
4. module/declaration/FFI environments before `$Require`, `$GlobalScope`, and
   `$FfiC`;
5. proof-producing guards/assertions before assertion signatures in stdlib;
6. effects only after an arrow effect component and row semantics exist;
7. HKTs/rank-N only after kinds, quantifiers, skolemization, and escape checks.

Any reversed dependency is an ad-hocness warning.

## Required Output Of Each Mining Pass

Each imported feature must add:

- a kernel contract;
- at least one soundness obligation;
- certificate node shape;
- rejection behavior when preconditions are unmet;
- a note explaining why the rule is substrate, not a one-off result.

If those cannot be written, the mined feature remains outside v7.
