# Typechecker v7 Design Pass: Contextual Effects

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses the direction for effects in the full checker architecture.

## Question

Is the full arrow effectful from the start?

The design already derives `throws(E)` and `yields(Y, S)` as contextual control
flow. The remaining fork is whether to build the full checker around effectful
arrows now or define normal-return arrows first and bolt effects on later.

## First-Principles Derivation

Running a computation may interact with its dynamic context instead of returning
normally to its direct continuation.

That behavior is not a value, not a pack, not a fact, and not table mutation.
It is contextual control flow.

Therefore function behavior has four independent components:

```text
arrow(params, effects, returns, post)
```

- `params`: what values the direct caller may pass;
- `effects`: what contextual control transitions the computation may perform;
- `returns`: what values the direct caller receives on normal return;
- `post`: what facts hold on normal continuation.

If `effects` is missing from the arrow, the checker has no honest place to
record `error`, assertion failure, `pcall`, coroutine yield/resume, or
higher-order propagation of those behaviors.

## Decision

Choose effectful arrows for the full design.

```text
arrow(params: BinderPack, effects: Effect, returns: Pack, post: Postcondition)
```

The pure subset is:

```text
effects = pure
```

A mechanized kernel may stage `pure` first, but that is a proof-development
subset, not the full architecture.

## Effect Domain

Effects are sets of possible contextual control transitions.

```text
Effect =
  pure
  throws(Type)
  yields(yield: Pack, resume: Pack)
  effect_union(Effect, Effect)
  effect_var(effect_var)
```

`pure` is the empty effect. `effect_union(A, B)` means either effect may occur.

Effect variables are required for higher-order code that propagates callee
effects without knowing them concretely:

```text
with_resource : <E>(Resource, (Resource) ! E -> R) ! E -> R
```

UNRESOLVED: final surface syntax for effect variables and effect-polymorphic
arrows.

## Throws

`throws(E)` means the computation may leave normal control by throwing a value
whose claim is in `E`.

Required behavior:

- `error(e)` introduces `throws(type(e))`;
- `assert(false_like, msg)` introduces `throws(type(msg) | default_error)`;
- ordinary sequencing propagates throws;
- `pcall` discharges throws from the protected function and converts them into
  a correlated return pack.

`throws(E)` is not the same as returning `never`. A throwing computation affects
the enclosing dynamic context, and a protected call can observe it.

## Yields

`yields(Y, S)` means the computation may suspend to a coroutine resumer with
yield pack `Y` and later resume with pack `S`.

Required behavior:

- `coroutine.yield(...)` introduces `yields(Y, S)`;
- coroutine body checking accumulates `yields(Y, S)`;
- `coroutine.create` discharges the yield effect into a coroutine value;
- `coroutine.resume` participates in the protocol by accepting resume pack `S`
  and producing yielded pack `Y` or final return pack `R`.

The yield effect is bidirectional. The yielded values and resume values are
correlated by the coroutine protocol, not independent slotwise unions.

UNRESOLVED: exact `Coroutine<Y, S, R, E>` shape and how body throws interact
with `resume` results.

## Sequencing And Composition

Sequential composition accumulates contextual effects:

```text
effects(s1; s2) = effects(s1) ∪ effects(s2)
```

This is a conservative summary. Path-sensitive refinement may later prove that
some effects are unreachable on a branch, but it must be represented as a proof,
not a fallback.

Normal-return postconditions apply only along paths that return normally.
Throwing and yielding paths do not export normal-continuation facts.

## Discharge

Handlers and contextual constructors discharge effects.

```text
pcall : ((P) ! throws(E) -> R, P) ! pure -> either([true, R], [false, E])
```

The exact pack syntax is schematic; real `pcall` requires open/rest packs.

```text
coroutine.create : (() ! yields(Y, S) -> R) ! pure -> Coroutine<Y, S, R>
```

The exact coroutine API also requires open/rest packs and target-profile
semantics.

Discharge must be explicit in certificates. Effects must not disappear because
a callee name looked like `pcall` or `coroutine.create`.

## Arrow Subtyping

Arrow subtyping includes effect subsumption.

For producer arrow `A` to subtype consumer arrow `B`:

- parameters are contravariant;
- normal returns are covariant;
- postconditions imply expected postconditions;
- producer effects must be a subset of consumer effects.

Intuition:

```text
pure <: throws(E)
throws(E1) <: throws(E2) if E1 <: E2
```

For yields, the yielded pack is covariant and the resume pack is contravariant:

```text
yields(Y1, S1) <: yields(Y2, S2)
  if PackMove(co, Y1, Y2) and PackMove(contra, S2, S1)
```

This follows the same producer/consumer polarity as function parameters and
returns.

## Overloads

Overload branch selection must include effects.

If multiple branches match and their effects differ, the call is accepted only
if the effect alternatives can be represented without losing branch
correlation. Otherwise reject.

This prevents an overloaded assertion or protected-call wrapper from exporting
facts or effects from the wrong branch.

## Primitive Specs

Primitive specs include effects:

```text
PrimitiveSpec = {
  domain,
  effects,
  transition,
  returns,
  post
}
```

Some primitives introduce effects; some discharge effects; some perform identity
transitions. These are separate fields.

`setmetatable` is an identity transition, not a contextual control effect.

## Non-Effects

### IO

IO authority is a runtime capability value. It is not an `io` effect.

If a function reads a file because it receives `FsCap`, the authority is in the
parameter. The effect system does not need to track it for soundness.

### Table Mutation

Table mutation is modeled by identity transitions and fact invalidation.

It is not initially a `mutates` effect. General references or regions may later
derive `mutates(region)`, but only if table identity transitions are not enough.

### Guards And Assertion Facts

The fact-exporting part of a guard/assertion is not an effect.

Runtime failure of an assertion is an effect such as `throws(E)`. The normal
continuation fact remains a postcondition.

### Return And Break

Function `return` is the normal function result path, not an effect.

Lexical `break` is statement-local control. It should be represented in
statement checking, not as an arrow effect, unless a future language feature
lets it escape its lexical context.

## Rejected Alternatives

### Normal-Return Arrows As The Full Design

Rejected for the full checker:

```text
arrow(params, returns, post)
```

Reason: it has no honest slot for `error`, `pcall`, assertions that may fail,
or coroutines. Effects would re-enter later as ad-hoc return encodings or
stdlib special cases.

### Generic Side-Effect Bucket

Rejected:

```text
effects = io | mutates | throws | yields | allocates | ...
```

Reason: this loses the first-principles distinction. IO is authority. Table
mutation is identity transition. Throws/yields are contextual control.

### Effect As Return Pack Variant

Rejected:

```text
error : (...) -> never
pcall : (...) -> boolean, unknown...
```

Reason: protected control observes thrown values. Encoding effects as ordinary
returns loses dynamic-context behavior and pack correlation.

## Adversarial Review

### Soundness Lens

The design is sound-oriented because every nonlocal control behavior has a
place in arrow semantics and must be propagated or discharged.

Residual risk: `pcall` and coroutine APIs depend on open/rest packs. The effect
pass must not pretend those stdlib functions are fully specified until pack
rules exist.

### Ad-Hocness Lens

The design avoids name-keyed handlers by requiring explicit discharge rules and
certificate nodes.

Residual risk: if effect discharge is implemented in stdlib-specific code
instead of kernel rules, the old v5 failure mode returns.

### Minimality Lens

The effect set is intentionally small: `throws` and `yields` only.

Residual risk: users may expect IO or mutation effects. The design must keep the
explanation sharp: those are represented elsewhere unless a new first-principles
derivation requires an effect.

### Higher-Order Lens

Effect variables are likely necessary for real higher-order functions.

Residual risk: effect polymorphism interacts with generics, overloads, and
subtyping. If that interaction is too large for the initial proof, the pure
subset can be staged, but the full architecture still keeps the effect slot.

## Decision

Choose:

```text
the full arrow is effectful from the start; pure is the empty effect
```

The next design pass should resolve open/rest packs, because precise `pcall`,
coroutine resume/yield, varargs, iterators, and multireturn spread all require
pack rules.
