# Typechecker v6 Semantic Kernel Synthesis

This is a pass-1 synthesis from `normalize sessions` history plus the current
v6 docs. It is not a new feature list. Its purpose is to prevent v6 from
recreating v4/v5 ad-hocness by making the semantic domains explicit before more
verticals are added.

Evidence used:

- `normalize sessions list --grep typechecker --all-projects ...`
- recent session `6a12d4d7`: v6/v5 decision review, 19-axis rejection, packs,
  effects, HKTs, typestate, and completion criteria
- session `d6cd6735`: v5 pack substrate and op-sem specs
- session `48b05336`: v4/v5 architecture and feature-interaction failures
- session `df8a5d66`: operational-semantics audit and primitive-closure method
- force-cast searches across sessions: force casts must not be inference sources
- overload/effect searches across sessions: local overload probing and effect
  representation history
- `docs/typechecker-v6-plan.md`
- `docs/typechecker-v6-implementation-plan.md`
- `docs/type-system-design/03-variadic-packs.md`
- `docs/type-system-design/05-effects.md`
- `docs/typechecker-ad-hoc-inventory.md`

Historical decisions are evidence, not authority. When sessions conflict, this
document records the conflict and pins only the smaller kernel implied by the
runtime semantics.

## Anti-Ad-Hoc Method

v6 is allowed to add a rule only if the rule names:

- the semantic domain it consumes and produces;
- the movement site that justifies the conversion;
- the proof obligation it emits;
- the fact it exports after the obligation succeeds;
- the invalidation rule if the fact is scoped or mutable.

If a rule cannot name those, it is not ready. If it needs a name-keyed handler,
it is rejected until represented as a declared type plus a named primitive.

This is stronger than "add invariants after bugs." It is the primitive-closure
discipline from the op-sem audit: every nontrivial operation in a rule is either
a named semantic primitive or a separate rule. Tag dispatch, string matches, and
context side channels are not primitives.

## Kernel Domains

### Value Type

`Type` is the algebra of single Lua values. It contains atoms, literals,
`nil`, `unknown`, `never`, records, arrows, nominals, unions, intersections, and
complements. Nilability is just `T | nil`.

`any` is not in the sound algebra. It is represented only to make unsafe
boundaries visible.

### Pack

`Pack` is an ordered value-list shape:

```lua
Pack = { items = { Type }, rest = Type | nil }
```

A pack is not a value type and is not a lattice element. A pack cannot appear as
a member of `Type.union`, `Type.intersection`, or `Type.complement`.

Packs exist because Lua has value-list positions. Function arguments, function
returns, varargs, and multi-return calls are not single values. The single-rest
invariant follows from Lua: only the tail of a value list can be open.

### Pack Result

`PackResult` is the result domain for an expression in a value-list context:

```lua
PackResult =
  | { tag = "single", pack = Pack }
  | { tag = "union", alternatives = { Pack } }
```

This domain is required. It is not optional precision.

Reason: an overloaded call can produce one of several whole return packs. A
slotwise union of the packs loses correlation:

```lua
-- branch results are ("ok", number) | ("err", string)
-- wrong collapse: ("ok" | "err", number | string)
```

The collapse is sound as a widening in some movement sites, but it is not the
semantic result of the call and must not happen before a movement site demands
slots.

This is the pack instance of a broader correlation rule. Tables have the same
problem after projection: reading or destructuring fields can lose the
relationship between fields unless a separate fact domain preserves it. v6
therefore treats PackResult as the first concrete case of "correlated producer
alternatives," not as a pack-only trick.

### Arrow

Core arrow shape:

```lua
Arrow = { params = Pack, returns = Pack, effects = EffectRow | nil }
```

An individual arrow returns one `Pack`. An overloaded call returns a
`PackResult` union of matching branch packs. Arrow subtyping checks params
contravariantly and returns covariantly through pack movement rules.

### Effect Row

The stable kernel decision is narrower than the latest session's wording:

- effects are not value types;
- effects are not return-pack slot 1;
- if admitted, effects are attached to arrows and discharged by shape-driven
  handler types, not by name-keyed stdlib handlers;
- core v6 must not depend on effects.

There is historical tension about representation. One line of work says effects
are ordinary intersections over arrow types; the later M5 document says effects
are a dedicated `Row(Effect)` component. Do not implement effects until this is
resolved by checking how arrows, intersections, overloads, HKTs, and discharge
compose. The current implementation should keep the arrow effect seam inert.

## Movement Sites

Movement sites are the only places where domains convert.

| Site | Producer domain | Consumer/domain effect |
| --- | --- | --- |
| expression in scalar context | `PackResult` or `Type` | adjusts to one `Type` by Lua scalar rules |
| local binding | `PackResult` | adjusts to the declared or inferred local list |
| assignment | `PackResult` | adjusts to target list arity, then checks each target |
| return | `PackResult` | checks against current function return `Pack` |
| call arguments | argument expression list | adjusts to callee parameter arity, discarding surplus values and padding missing fixed parameters with `nil` |
| overload call | `Type` callee + arg `Pack` | returns `PackResult` over matching branch returns |
| annotation/cast | `Type` or `PackResult` | emits proof obligation or unsafe boundary |

No other code may project pack slots, drop surplus values, nil-pad missing
values, or union return slots. Those are movement-site operations.

## Overloads

Pinned decisions:

- an overloaded value may be represented as an intersection of arrows;
- implementation soundness is checking the body against every overload branch;
- call resolution is local read-only probing over branches, followed by a single
  committed result;
- no branch may be selected by declaration order;
- the result of a multi-match call is a `PackResult` union of whole branch
  return packs.

The phrase "union of matching branch return claims" in the current v6 plan must
be read as a union in `PackResult`, not a slotwise `Type.union`.

## Type Guards

Pinned decisions:

- intrinsic guards can produce flow facts only from named primitives with
  runtime meaning, such as `x ~= nil`, `type(x) == "string"`, literal equality,
  and discriminant field equality;
- user guards are declarations, not trusted facts;
- every true return path must prove the predicate before the guard claim is
  exported;
- invalid explicit guard declarations should be rejected, not downgraded
  silently, unless the spec later pins a diagnostic-preserving downgrade.

Guard facts are invalidated by mutation, alias escape, and calls that may mutate
the identity containing the narrowed fact.

## Unsafe Boundaries

Pinned decisions:

- `--[[: T]]` is checked and emits `producer <: T`;
- `--[[:! T]]` is an explicit unsafe boundary;
- force casts must never feed inference, bind type variables, or repair an
  otherwise failing proof;
- force casts must be grep-able and counted.

This comes up repeatedly in session history: using force casts as inference
sources is a soundness bug, not a convenience.

## What This Refutes

This kernel rejects these implementation shapes:

- representing overloaded multi-return results as slotwise unions before a
  movement site;
- storing pack alternatives inside the value `Type` lattice;
- adding a handler because a callee is named `pcall`, `require`, or
  `setmetatable`;
- using mutable context fields as cross-phase message buses;
- letting annotations, overload declarations, guard declarations, or stdlib
  declarations export facts before their obligations are proven or explicitly
  classified as trusted boundaries;
- widening to `any` or `unknown` when proof search fails or hits a budget.

## Current v6 Audit Findings

The existing v6 prototype is a useful vertical, but it has already crossed one
kernel boundary:

- `lib/type/static-v6/source.lua` builds overloaded pack-call results by unioning
  corresponding return slots in `check_final_call_pack`. This loses pack
  correlation. It should be replaced before adding more pack-consuming movement
  sites.
- Local/assignment pack adjustment is implemented directly in `source.lua`.
  That makes it too easy for each movement site to invent its own pack rules.
  Move this into a `pack_result.lua` or `movement.lua` kernel module.
- `ann.lua` accepts legacy return-pack spellings that should be audited against
  the Pack/PackResult split. Empty return pack syntax is fine; treating a value
  type like `never` as a pack synonym is suspicious and should be pinned or
  removed.
- Effects are not implemented. Keep them absent until the row-vs-intersection
  representation conflict is resolved.

## Required Next Implementation Step

Stop feature growth until pack results are represented directly.

Implement:

```text
lib/type/static-v6/pack_result.lua
```

Minimum API:

- `single(pack) -> PackResult`
- `union({ Pack }) -> PackResult`, preserving whole alternatives
- `to_scalar(ctx, site, PackResult) -> Type`
- `adjust_to_arity(ctx, site, PackResult, n) -> { Type }`
- `check_against_pack(ctx, site, PackResult, expected_pack) -> diagnostics`
- `tostring/key` for fixtures and regression tests

Then refactor:

- arrow calls return `PackResult.single(arrow.returns)`;
- overloaded calls return `PackResult.union(matching_returns)`;
- local bindings, assignments, returns, and expression statements consume
  `PackResult` through movement helpers;
- no slotwise union appears before a movement helper explicitly accepts
  correlation loss.

Regression fixtures must include at least:

- overloaded call returning `("ok", number)` or `("err", string)`;
- assigning both returns to locals preserves or explicitly widens with a
  documented correlation-loss point;
- checking the same result against `("ok", number) | ("err", string)` is not
  faked by `("ok" | "err", number | string)` unless a future tuple/pack-union
  type is explicitly admitted.

## Open Decisions

These remain genuinely open and must not be papered over:

- whether pack correlation can be tracked after destructuring locals, or whether
  destructuring is the explicit correlation-loss boundary;
- how table field projection/destructuring preserves or deliberately loses
  correlation between fields of the same identity;
- how to represent a consumer that accepts a union of whole packs without making
  packs lattice elements;
- whether effects are dedicated arrow rows or an arrow-intersection discipline;
- whether HKTs are core or reserved, and how their kind interface composes with
  effects and typestate;
- exact invalid-guard policy if the declaration is syntactically present but
  proof fails;
- exact severity policy for force casts by source boundary.

The important distinction: these are open because the semantic domains have not
yet forced a single answer, not because we need more axes.
