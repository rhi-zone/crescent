# Typechecker v7 First-Principles Design

This document is pre-spec design work. It tries to derive the shape of a full
sound checker from first principles before writing a complete specification or
implementation plan.

The purpose is to prevent organic growth. If a feature cannot be derived from
the primitives here, either the primitive set is incomplete and must be changed,
or the feature is rejected.

This document is meant to be iterated. It is not final architecture prose. Each
pass should deepen the derivation, find hidden contradictions, and either
strengthen or replace the primitives.

## Iterative Deepening Method

The design process is:

1. state the current primitive categories;
2. derive one feature family from those primitives;
3. look for hidden interactions with every already-derived family;
4. if the derivation fails, either revise the primitives or reject the feature;
5. record design forks explicitly instead of making local choices;
6. repeat until the remaining full spec is mostly transcription.

A pass is successful when it removes ambiguity or exposes a real fork. It does
not have to produce final answers. It must not hide uncertainty by adding
implementation-flavored rules.

The expected output of each pass is one of:

- a stronger primitive;
- a derived feature family;
- an incompatibility proof;
- a forced design fork;
- a rejection rule.

The forbidden output is an ad-hoc local rule that works only for the example
currently under discussion.

## Goal

Build a checker that accepts a program only when every exported static claim is
justified by a sound semantic argument.

The checker is not primarily an annotation parser, a constraint solver, or a
suite of local feature checkers. Those may be implementation techniques. The
semantic goal is:

```text
accepted claim => derivable claim
```

where derivation means either:

- a proof from the kernel rules; or
- an explicit trusted/unsafe boundary whose exported claim is visible in the
  certificate.

## Non-Negotiables

- Unsoundness is fatal.
- Incompleteness is acceptable.
- Unknown interactions reject.
- No fallback to `any`.
- No widening to `unknown` as recovery.
- No source-name magic.
- No hidden global checker state in rules.
- No feature is admitted just because Crescent historically had syntax for it.
- No implementation vertical is evidence that the architecture is coherent.

## Irreducible Runtime Objects

A Lua/Crescent program manipulates:

- single runtime values;
- ordered value lists at call and return boundaries;
- control transitions;
- mutable store identities;
- lexical bindings and places;
- trusted external boundaries.

These are semantically distinct. Collapsing them is a historical source of
ad-hocness.

### Values

Single runtime values include nil, booleans, numbers, strings, functions,
tables, threads, userdata, and cdata.

A value type abstracts a set of possible single values. Therefore nilability is
not special: `T | nil` is ordinary value-set algebra.

### Value Lists

Lua calls and returns move ordered lists of values, not just one value.

A pack abstracts a set of possible value lists. A pack is not a value type.
Correlated return alternatives are alternatives of whole packs, not slotwise
unions.

This distinction is mandatory. Without it, overload returns, `pcall`, iterator
returns, destructuring, and multireturn calls lose correlation.

### Control Transitions

Running code can do more than return normally:

- return a value list to the direct caller;
- throw out to a protected call;
- yield to a coroutine resumer;
- terminate a local statement context, such as break.

These are not all "side effects". The useful category is contextual control:
the computation interacts with a dynamic context instead of simply returning to
its immediate continuation.

This suggests effects for `throws(E)` and `yields(Y, S)`, but not for IO.

### Store Identities

Tables are mutable identities in a store. A record type is a stable observation
of a table identity, not the table itself.

Therefore mutation cannot be modeled as ordinary record subtyping. Writes,
sealing, escape, alias invalidation, and metatable assignment are store
transitions.

### Places And Facts

Flow typing is about facts over stable places:

- local bindings;
- parameters;
- upvalue cells;
- fields of known identities;
- destructured positions;
- possibly imported declarations.

A fact is not a type. A fact is a scoped claim about a semantic place, not a
source expression or source spelling. It may be invalidated by mutation, alias
escape, calls, or control-flow joins.

Type guards and assertion signatures derive from fact transitions. Their
runtime failure behavior, if any, belongs to control semantics, not to the fact
itself.

### Trusted Boundaries

Modules, declarations, FFI, target stdlib profiles, unchecked casts, and legacy
escape hatches can introduce claims not proved inside the program.

These are not type rules. They are trusted boundaries. A sound checker can allow
them only if they are explicit and auditable.

## Derived Static Objects

The static objects should follow from the runtime distinctions above.

### Type

A type classifies one runtime value.

Required constructors derive from value sets:

- atoms and literals;
- union;
- intersection;
- complement;
- `never`;
- `unknown` as top;
- function values;
- table observations;
- nominal/opaque values;
- primitive capabilities.

`any` does not derive as a sound type. It can only be an unsafe boundary.

### Pack

A pack classifies runtime value lists.

Required pack forms derive from Lua call/return behavior:

- fixed prefixes;
- closed tails;
- homogeneous rest tails;
- pack-variable tails;
- correlated alternatives.

Decision direction: full v7 packs have fixed prefixes plus closed/rest/variable
tails, and pack movement is split by semantic movement kind rather than only
covariant/contravariant direction.

See `docs/typechecker-v7-design-pass-packs.md`.

### Arrow

A function value is a callable runtime value. Its summary must include:

- parameter places/types;
- contextual control behavior;
- normal return pack;
- normal-continuation facts.

Therefore the eventual full arrow shape is:

```text
arrow(params, effects, returns, post)
```

where `post` talks about parameter/result places, not arbitrary source names.

### Record

A record is an observation of a table identity after enough stability has been
established.

Record structure derives from table observations:

- named fields;
- optional fields;
- readonly versus mutable capabilities;
- indexers;
- row openness.

Open construction facts are not records and must not be fed to record subtyping.

### Primitive Capability

Some runtime values authorize checker-level transitions that are not ordinary
pure arrows. `setmetatable` is the motivating case.

This derives primitive capabilities as value types. It does not derive
source-name dispatch.

Decision direction: primitive capabilities live in `Type` as
`primitive_cap(name)`. Claim metadata may track provenance, but primitive call
authority is a visible value-type claim.

See `docs/typechecker-v7-design-pass-primitive-capabilities.md`.

## Derived Feature Families

### Overloads

Overloads derive from intersections of callable behaviors.

Sound export requires checking the implementation body against every declared
branch. Sound use requires branch applicability, correlated return alternatives,
and rejection of incompatible postconditions/effects unless a combining rule is
specified.

### Guards

Type guards derive from proof of facts on true-return paths.

They are sound only if every path returning literal true proves the predicate
and if exported facts are invalidated by later writes, calls, or escapes.

### Assertion Signatures

Assertion signatures derive from normal-continuation facts.

They require binder-aware arrows because `asserts x is T` must refer to a
specific parameter/place. Runtime assertion failure requires contextual control
semantics or an unsafe/trusted boundary.

### Effects

Effects derive only for contextual control.

`throws(E)` is required to type `error`, `pcall`, assertion failure, and
protected APIs precisely.

`yields(Y, S)` is required to type coroutine yield/resume precisely.

IO does not derive as an effect because IO authority can be a runtime
capability value.

Mutation does not initially derive as an effect because table mutation is
modeled by store identity transitions. A later region/reference system might
derive `mutates(region)`, but that is not needed for table soundness.

### Modules And Declarations

Module and declaration typing derives from trusted or checked boundaries.

`--:: require`, `$Require`, `$GlobalScope`, and `$FfiC` cannot be admitted as
ordinary type computation. They need environments, provenance, missing-symbol
semantics, and certificate boundaries.

Decision direction: external claims enter through explicit immutable
environments with provenance: `TargetProfile`, `StdlibProfile`, `ModuleEnv`,
`DeclEnv`, and `FfiEnv`. Runtime require, annotation require, stdlib profiles,
globals, and FFI all elaborate to those environments or trusted boundary nodes.

See `docs/typechecker-v7-design-pass-module-provenance.md`.

### Metatables And Operators

Metatable lookup derives from table identity plus operation lookup.

Operators should be specified as operation application:

- first try primitive scalar semantics when applicable;
- otherwise use metatable lookup rules if admitted;
- reject when neither is derivable.

This prevents per-operator ad-hoc predicates.

Decision direction: metatable semantics are built-in lookup/assignment
relations over table identity state. `getmetatable`, `setmetatable`, and raw
operations expose or bypass those relations only through primitive capability
values, never by source-name dispatch. Mutation of receiver, metatable, or
traversed tables invalidates dependent lookup facts.

See `docs/typechecker-v7-design-pass-metatable-lookup.md`.

Decision direction: operator semantics are a single operation judgment over
typed operands. The primitive case uses target-profile operation tables. The
metamethod case uses the metatable lookup relation and ordinary call checking.
Raw operations are primitive capabilities that bypass metamethod dispatch but
not dependency tracking. `and` and `or` are not overloadable operators; they are
value-producing control-flow expression rules over truthiness facts.

See `docs/typechecker-v7-design-pass-operators.md`.

### Generics And Type-Level Computation

Generics derive from parametric reasoning, not from substitution convenience.

At minimum, rank-1 bounded generics need:

- type variables and bounds;
- instantiation;
- skolemization;
- escape checks;
- certificate nodes.

HKTs do not derive automatically. If field folds or match types require higher
kinds, either HKTs must be admitted as a primitive design commitment or the
feature must use restricted first-order type-level functions.

Decision direction: admit rank-1 generics plus kinded first-order type-level
computation now. HKTs and rank-N remain later extensions. Field folds use
restricted named `TypeFn` declarations over `FieldDescriptor`, not arbitrary
higher-kinded variables.

See `docs/typechecker-v7-design-pass-generics-typelevel.md`.

## Design Forks

These are first-principles forks, not implementation TODOs.

### Unknown Movement

`unknown` derives naturally as denotational top. It does not automatically
derive permission to consume an unknown value as a concrete type.

Decision direction: `unknown` is denotational top, and elimination is governed
by each operation's domain. Operations defined for all values may consume
`unknown`; concrete operations require prior narrowing or an explicit unsafe
boundary.

See `docs/typechecker-v7-design-pass-unknown.md`.

### Parameter Places

Postconditions require stable places. Function types need a way to bind those
places.

Decision direction: facts target semantic places, arrows bind parameter places,
and call sites substitute parameter places with stable caller places.

See `docs/typechecker-v7-design-pass-places.md`.

### Primitive Capabilities

Primitive callable behavior must be typed without name magic.

Decision direction: represent primitive capabilities as value types,
`primitive_cap(name)`, not hidden claim metadata.

See `docs/typechecker-v7-design-pass-primitive-capabilities.md`.

### Setmetatable

Both plausible models derive from table identity, but they have different
constructor semantics.

Decision direction: `set_metatable` fixes metatable state and does not by
itself seal own-field construction. Later reads and writes must be
metatable-aware; if the checker cannot prove raw own-field behavior after a
metatable is installed, it rejects rather than pretending the table sealed.

See `docs/typechecker-v7-design-pass-setmetatable.md`.

### Effects In The Core

Throws and yields derive as contextual control, but the proof kernel might stage
them later.

Decision direction: the full arrow is effectful from the start. `pure` is the
empty contextual-control effect. A pure-only mechanized kernel can be a staged
proof subset, but not the full architecture.

See `docs/typechecker-v7-design-pass-effects.md`.

## Coherence Criterion

A proposed feature is coherent if it can be explained as one of:

- value-set abstraction;
- value-list abstraction;
- contextual-control abstraction;
- store-identity transition;
- scoped fact transition;
- trusted boundary;
- parametric/type-level computation with explicit reduction rules.

If it cannot be explained by one of those, the design must either add a new
primitive category or reject the feature.

## Next Design Work

The remaining pre-spec work should continue resolving design forks in dependency
order:

1. What is the operator/metamethod substrate?
   Decision: `OpCheck` with primitive/metamethod/raw cases; `and`/`or` use
   separate truthiness/control-flow rules.
2. What is the final certificate schema?
   Decision: finite replay DAG with immutable context inputs, interned terms,
   typed node families, root claims, explicit dependencies, and visible
   unsafe/trusted boundary nodes.

See `docs/typechecker-v7-design-pass-certificates.md`.
