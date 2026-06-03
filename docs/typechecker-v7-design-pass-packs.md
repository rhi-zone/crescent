# Typechecker v7 Design Pass: Packs, Rest, And Movement

This is an iterative first-principles pass. It is pre-spec design work, but it
chooses the direction for open/rest packs and fixes a hidden ambiguity in the
current kernel: movement direction alone is not enough.

## Question

What is a pack, and how does it move?

Lua does not move single values at call and return boundaries. It moves ordered
value lists with context-sensitive adjustment:

- scalar contexts take the first value;
- returns adjust to the declared return shape;
- calls adjust arguments to formal parameters;
- destructuring adjusts values to binding slots;
- last-position expressions can spread multiple returns;
- varargs capture and re-emit open lists.

Therefore a full checker cannot stop at closed packs.

## First-Principles Derivation

A pack classifies a set of runtime value lists.

```text
Pack = fixed prefix + tail
```

The tail determines whether the list is closed, has a homogeneous rest, or is a
pack variable.

```text
Pack =
  pack(items: Type*, tail: PackTail)

PackTail =
  closed
  rest(Type)
  var(pack_var)
```

`pack([A, B], closed)` contains exactly two values.
`pack([A], rest(R))` contains one `A` followed by zero or more `R`.
`pack([A], var(P))` contains one `A` followed by whatever list `P` denotes.

## Decision

Admit open/rest packs in the full design.

The pure closed-pack kernel remains a proof subset, but it is not enough for a
full Lua checker. Full v7 needs:

- homogeneous rest tails;
- pack variables;
- expression-list spread rules;
- vararg capture and expansion;
- movement kinds that reflect Lua contexts.

## PackAlt

`PackAlt` remains the correlation-preserving alternative form:

```text
PackAlt =
  one(Pack)
  either(PackAlt, PackAlt)
```

Open tails do not remove the need for `PackAlt`. A return like:

```text
either(pack(["ok", T], closed), pack(["err", E], closed))
```

is still different from:

```text
pack(["ok" | "err", T | E], closed)
```

Correlation is preserved until a named movement site loses it.

## Movement Kinds

The previous `co`/`contra` direction is too small. It conflates at least five
different Lua movements.

Choose explicit movement kinds:

```text
PackMove(kind, producer: PackAlt, consumer) => result

kind =
  scalar
  return_to_decl
  call_args_to_params
  destructure_to_slots
  arrow_param_subtype
  pack_subtype_co
```

Each movement kind has its own adjustment behavior and certificate node.

### Scalar

Scalar movement takes the first value of each alternative, or `nil` if the list
is empty.

This is a correlation-loss site:

```text
Scalar(either(A, B)) = Scalar(A) | Scalar(B)
```

### Return To Declaration

Return movement checks a produced pack against a declared return pack.

Lua adjustment applies:

- surplus producer values may be discarded when the consumer is closed;
- missing producer values are `nil`;
- if the consumer has rest, every consumed tail value must satisfy the rest;
- if the producer has rest and the consumer is closed, only demanded positions
  are checked;
- if both have rest, producer rest must subtype consumer rest.

This movement preserves `PackAlt` until each alternative independently proves
the declared return shape.

### Call Arguments To Parameters

Call movement checks an argument list against a callee parameter binder pack.

Lua call adjustment applies to fixed parameters:

- missing arguments become `nil`;
- surplus arguments are discarded unless the callee captures varargs;
- if the callee has rest/vararg parameters, surplus arguments flow into the
  rest tail;
- each formal parameter slot must be satisfied after adjustment.

This differs from function subtyping. A call may pass extra arguments to a
fixed-arity function because Lua discards them; a function type is not
substitutable for another merely because callers might discard values.

### Destructure To Slots

Destructuring movement binds produced values to target slots.

- missing values become `nil`;
- surplus values are discarded;
- each target slot receives a claim;
- if the producer is a `PackAlt`, destructuring must preserve branch identity in
  the resulting slot claims and identity facts until a later correlation-loss
  site.

Slotwise unions are allowed only as explicit widening.

### Arrow Parameter Subtyping

Arrow parameter subtyping is contravariant substitutability between callable
values. It is not the same as a Lua call.

A producer function may stand in for an expected function only if every argument
list accepted by the expected function is accepted by the producer function.

This requires inclusion over parameter pack denotations, with contravariant
element checks. It must not use Lua's call-site discard/missing-argument
behavior as a shortcut unless that behavior is part of the parameter pack
denotation.

### Pack Subtype Covariant

Pack subtype covariance is ordinary list-set inclusion for produced value
lists. It is used by return and yield payload checks after the relevant movement
kind has decided which runtime values are observed.

## Expression Lists And Spread

Lua expression lists have a special last-position rule.

```text
expr_list(e1, ..., en)
```

- `e1` through `e(n-1)` are scalar contexts;
- `en` may produce a full pack;
- if there is no `en`, the list is empty.

This rule is the substrate for:

- `return f()`;
- `a, b = f()`;
- `g(x, f())`;
- vararg forwarding;
- `pcall(f, ...)`;
- coroutine resume arguments.

It must be represented as a named producer rule, not duplicated in calls,
returns, and assignments.

## Varargs

A vararg binding captures a pack tail.

Inside a vararg function:

```text
...
```

has the function's rest pack.

Forwarding `...` in last position preserves the pack. Using `...` in scalar
position takes the first value and loses correlation.

UNRESOLVED: final syntax for pack variables and variadic generics.

## Interaction With Effects

Precise `pcall` requires both effects and open packs:

```text
pcall(f, args...) =
  either(pack([true] + returns(f), closed),
         pack([false, thrown_error], closed))
```

This is schematic. The success branch preserves the protected function's return
pack; the failure branch carries the thrown value. The alternatives must remain
correlated.

Precise coroutine `resume` also requires open packs because resume inputs,
yield outputs, and final returns are all packs.

## Interaction With Places

Pack movement can create places through destructuring.

If a `PackAlt` contains table identity alternatives, destructuring must preserve
which slot claims came from which alternative. Otherwise field facts after
destructuring become unsound.

Example:

```text
either(pack([table(id_ok), "ok"], closed),
       pack([table(id_err), "err"], closed))
```

Destructuring into `t, tag` must not immediately produce:

```text
t : table(id_ok) | table(id_err)
tag : "ok" | "err"
```

unless it records that the correlation was intentionally widened.

## Rejected Alternatives

### Rest As Unknown Tail

Rejected:

```text
pack([A], rest(unknown))
```

as the default representation of uncertain arity.

Reason: it loses arity and element information, and turns missing pack rules
into `unknown` recovery.

### Direction-Only PackMove

Rejected for the full checker:

```text
PackMove(co | contra, producer, consumer)
```

Reason: Lua call adjustment, return adjustment, destructuring, scalar movement,
and arrow substitutability are different semantic operations.

### Slotwise Union By Default

Rejected:

```text
either(pack([A, B]), pack([C, D])) => pack([A | C, B | D])
```

Reason: it destroys return and identity correlation.

### Name-Keyed Stdlib Pack Rules

Rejected:

```text
if callee is "pcall" then special pack handling
```

Reason: `pcall` precision derives from effect discharge plus pack movement, not
from source-name dispatch.

## Adversarial Review

### Soundness Lens

The design is sound-oriented because each Lua list adjustment context is named
separately, with its own proof obligation. It does not reuse function-subtyping
rules for call-site behavior.

Residual risk: destructuring with `PackAlt` and identity facts is subtle. If the
implementation widens too early, table facts become unsound or useless.

### Ad-Hocness Lens

The design removes repeated local spread logic by making expression-list
production a substrate rule.

Residual risk: stdlib functions like `select`, `pcall`, and `resume` may tempt
special-case handlers. They must be expressed through pack variables, effects,
and primitive/external declarations.

### Completeness Lens

Open/rest packs are required for real Lua. This pass moves them from optional
extension to full-design primitive.

Residual risk: pack variables interact with generics and inference. If the
generic story is delayed too long, stdlib signatures may remain schematic.

### Cost Lens

This is more complex than closed tuple types, but the complexity is forced by
Lua semantics. Avoiding it only hides the complexity in ad-hoc call/return
rules.

## Decision

Choose:

```text
full v7 packs have fixed prefixes plus closed/rest/variable tails, and pack
movement is split by semantic movement kind
```

The next design pass should resolve the `set_metatable` fork, because
primitive capabilities now have a representation and table/metatable semantics
are the next major blocker for operators and method dispatch.
