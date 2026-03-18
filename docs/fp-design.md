# Functional Programming Library Design (`lib/fp/`)

Crescent's functional programming library provides Haskell/PureScript-style abstractions
with ergonomic Lua names and the typeclass dispatch pattern described in
`docs/typeclass-design.md`.

## Goals

- Implement core FP abstractions correctly, not as approximations
- Stress-test the typechecker's HKT and constraint support
- Establish whether typeclass constraints can be expressed type-safely in crescent
- Provide canonical instances that prove the typeclasses work

## Non-goals

- Lazy evaluation (doesn't map to Lua)
- Exotic names (`>>=`, `liftA2`, `<$>`) — use `bind`, `lift2`, `map` instead
- Copying Haskell's stdlib wholesale — derive the right API for Lua

## Typeclass Dispatch

See `docs/typeclass-design.md`. Summary: typeclass instances are stored on values at
`value[Typeclass]`. Typeclass functions look up the implementation internally. The
caller passes the value, not the instance. Two typeclasses with the same method name
don't collide — different table keys.

Primitives (numbers, functions, strings) cannot have metatables, so they require
wrappers (`Sum(42)`, `Fn(f)`). Wrappers use `__call` where applicable so they're
transparent at call sites.

## Typeclass Structure

### The FAM hierarchy as function application in context

All typeclasses in the FAM family are variations on `apply :: (a -> b) -> a -> b`.
Three positions in that signature can independently be "in context f":

| Typeclass    | arg `a` ∈ f | fn `(a→b)` ∈ f | fn produces `f b` | signature |
|--------------|:-----------:|:--------------:|:-----------------:|-----------|
| Mappable     | ✓           | ☐              | ☐                 | `(a -> b) -> f a -> f b` |
| Applicable   | ✓           | ✓              | ☐                 | `f (a -> b) -> f a -> f b` |
| Chainable    | ✓           | ☐              | ✓                 | `(a -> f b) -> f a -> f b` |
| (unnamed)    | ✓           | ✓              | ✓                 | `f (a -> f b) -> f a -> f b` |

The unnamed row is a gap — may be derivable from the others or a distinct typeclass.

### Duals

Reversing arrows gives the dual of each typeclass:

| Typeclass    | Dual          | Key operations |
|--------------|---------------|----------------|
| Mappable     | Contravariant | `contramap :: (b -> a) -> f a -> f b` |
| Chainable    | Comonad       | `extract :: w a -> a`, `extend :: (w a -> b) -> w a -> w b` |
| Applicable   | ?             | Divisible in the contravariant setting; unclear covariant dual |
| (unnamed)    | ?             | Unknown |

Foldable/Traversable have duals too:

| Typeclass    | Dual          | Key operations |
|--------------|---------------|----------------|
| Foldable     | Unfoldable    | `unfoldr :: (b -> Maybe (a, b)) -> b -> [a]` |
| Traversable  | Distributive  | `distribute :: Functor f => f (g a) -> g (f a)` |

### Module list

- `lib/fp/semigroup` — `append :: a -> a -> a`
- `lib/fp/monoid` — `empty :: () -> a` (extends Semigroup)
- `lib/fp/mappable` — `map :: (a -> b) -> f a -> f b`
- `lib/fp/applicable` — `ap :: f (a -> b) -> f a -> f b`, `pure :: a -> f a` (extends Mappable; merges Apply + Applicative)
- `lib/fp/chainable` — `bind :: m a -> (a -> m b) -> m b` (extends Applicable)
- `lib/fp/foldable` — `fold :: Monoid m => t m -> m`, `foldMap`, `foldr`
- `lib/fp/traversable` — `traverse :: Applicable f => (a -> f b) -> t a -> f (t b)` (extends Foldable)

Not yet implemented (derived from matrix + duals):
- `lib/fp/contravariant` — `contramap`
- `lib/fp/comonad` — `extract`, `extend`
- `lib/fp/unfoldable` — `unfoldr`
- `lib/fp/distributive` — `distribute`
- `lib/fp/alt` — `alt :: f a -> f a -> f a` (fallback/choice; Maybe and Either need this)
- `lib/fp/bifunctor` — `bimap :: (a -> c) -> (b -> d) -> f a b -> f c d` (Either needs this)
- `lib/fp/profunctor` — `dimap :: (a -> b) -> (c -> d) -> f b c -> f a d` (Fn needs this)

### Optics

- `lib/fp/optics/lens` — `Lens s a` — focus on a single field; get + set
- `lib/fp/optics/prism` — `Prism s a` — focus on a constructor branch; preview + review
- `lib/fp/optics/iso` — `Iso s a` — bidirectional conversion
- `lib/fp/optics/traversal` — `Traversal s a` — focus on zero or more targets

**Key insight:** `Traversal` unifies with `Traversable`. A traversal over a structure
is exactly `traverse` generalized over an arbitrary focus, not just the structure's
natural element type. The optics library and `Traversable` should share this foundation
rather than duplicate it.

### Instances

**Semigroup/Monoid instances** (wrap primitives):
- `lib/fp/sum` — `Sum(n)`, `__call` transparent, `[Monoid] = { empty=0, append=add }`
- `lib/fp/product` — `Product(n)`, multiply
- `lib/fp/min` — `Min(n)`, minimum
- `lib/fp/max` — `Max(n)`, maximum
- `lib/fp/first` — `First(a)`, take left argument (ignores right)
- `lib/fp/last` — `Last(a)`, take right argument (ignores left)

Note: `First`/`Last` here are the Semigroup instances that ignore one argument — not
to be confused with `Maybe First`/`Maybe Last` which are `First (Maybe a)` treating
`Nothing` as the identity.

**Data types** (implement multiple typeclasses):
- `lib/fp/maybe` — `Nothing`, `Just(a)`. Implements: Mappable, Applicable,
  Chainable, Foldable, Traversable. Also: Semigroup/Monoid when `a` is Semigroup.
- `lib/fp/either` — `Left(e)`, `Right(a)`. Implements: Mappable, Applicable,
  Chainable, Foldable, Traversable (right-biased).
- `lib/fp/fn` — `Fn(f)`. Wraps functions; `__call` makes usage transparent.
  Implements: Mappable (composition), Applicable (S combinator), Chainable (reader/function monad).

### ADT: the general case

`Maybe` and `Either` are both instances of the general algebraic data type (ADT) pattern —
sums of products. `Maybe a` = `1 + a` (one 0-arity constructor, one 1-arity constructor).
`Either a b` = `a + b` (two 1-arity constructors). Both are part of the same infinite
family of n-constructor ADTs.

A general `lib/fp/adt` module should provide `ADT.define` to generate constructors and
`match` for any ADT, eliminating the boilerplate currently duplicated in `maybe`/`either`.
`maybe` and `either` then become thin wrappers that call `ADT.define` and attach typeclass
instances.

```lua
local Either = ADT.define({"Left", 1}, {"Right", 1})
Either[Mappable] = { map = function(f, fa) return Either.match(fa, {
    left  = function(e) return fa end,
    right = function(a) return Either.right(f(a)) end,
}) end }
```

Constructor definitions are ordered arrays of `{name, arity}` pairs — order matters
for `* -> *` instances (last constructor is the `Mappable` focus by convention).

**Naming:** `maybe` and `either` remain as module names for conventional recognisability.
The family relationship is encoded in `ADT.define`, not the module names — the same
reason functions aren't called `Exp`.

## Implementation Order

Each typeclass is implemented together with its primary instances — no typeclass without
at least one instance to test it against.

1. `semigroup` + `first`, `last`, `sum`, `product`, `min`, `max`
2. `monoid` — instances follow from semigroup + empty
3. `maybe` skeleton (Just/Nothing constructors, no typeclass instances yet)
4. `mappable` + `maybe` Mappable instance
5. `foldable` + `maybe`, list instances
6. `applicable` + `maybe` instances (provides both `ap` and `pure`)
7. `chainable` + `maybe` instance
8. `either` — all typeclass instances
9. `fn` — Mappable/Applicable/Chainable instances
10. `traversable` + `maybe`, `either` instances
11. Optics — `lens`, `prism`, `iso`, `traversal` (building on Traversable foundation)

## Pattern Matching

Lua's idiomatic dispatch pattern is table lookup by tag:

```lua
local handlers = {
    just    = function(v) return v.value + 1 end,
    nothing = function(v) return 0 end,
}
handlers[value.tag](value)
```

`Sum.match` (or equivalent) formalizes this — a function that takes a value and a table
of handlers keyed by constructor tag. The typechecker can narrow the type of `value`
inside each handler via discriminated union narrowing on the tag field, which is already
implemented.

Pattern matching in crescent is not a language feature — it is this table dispatch
pattern, integrated with the typechecker's existing narrowing.

## Algebraic Structure

The data types in `lib/fp/` are not arbitrary — they reflect the algebra of types:

- `Unit` = `1` (one value)
- `Bool` = `2` (two values)
- `Maybe a` = `1 + a` (unit plus `a`)
- `Either a b` = `a + b` (coproduct)
- `Pair a b` = `a * b` (product)
- `List a` = `1/(1-a)` (geometric series — lists of all lengths)

Operations on types correspond to operations on their generating functions:
- Differentiation gives one-hole contexts (zippers)
- Integration gives cyclic structures (necklaces for lists)
- The optics hierarchy (Lens, Prism, Traversal) falls out of this calculus directly

This is not just aesthetic — the algebraic structure explains why the typeclass laws are
what they are and why the hierarchy has exactly the shape it does.

## Type System Stress Tests

Each step is also a test of the typechecker's expressiveness:

- Can `<M: Monoid>` constraints be expressed and checked?
- Can `Functor f` (HKT constraint) be expressed?
- Can `traverse :: Applicative f => (a -> f b) -> t a -> f (t b)` be typed?
- Can optic composition (`Lens s a -> Lens a b -> Lens s b`) be typed?

Failures inform what's missing in the type system. The goal is not to paper over gaps
with `any` annotations but to identify them precisely and track them.
