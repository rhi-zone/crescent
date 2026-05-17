# Generic Type Parameters

Three orthogonal features on type parameters: constraints, HKT constraints, and defaults.
These compose freely: `<T: U = Default>`, `<F: SomeGeneric = ConcreteImpl>`.

## Regular constraints: `<T: U>`

T must be assignable to U at every call site.

```lua
--:: declare require = <T: string>(module: T) -> $Require<T>
--:: AssertExtends<T: U, U>  -- assertion alias: no body needed, constraint IS the check
--:: Clamp<T: number> = match T { ... }
```

`U` is any type expression — structural, union, intersection, alias:
```lua
--:: Serialize<T: { to_string: () -> string, ... }>
--:: Merge<T: { ... }, U: { ... }>
--:: Either<T: Serializable & Comparable>  -- & composes constraints
```

`<T: string>` means T is assignable to `string` — includes `string` itself, string
literals, and unions thereof. Same semantics as TypeScript's `T extends string`.

## HKT constraints: `<F: SomeGeneric>`

`SomeGeneric` is written **unapplied** — no `<...>`. The constraint is on the
*constructor* (kind), not on a concrete instantiation.

```lua
--:: Mappable<F: Container, A> = { map: <B>((A) -> B) -> F<B> }
--:: LiftA2<F: Applicative, A, B, C> = (F<A>, F<B>, (A, B) -> C) -> F<C>
```

`<F: SomeGeneric>` means: F is a type constructor with the same arity as `SomeGeneric`.
At use sites where `F<A>` is written, the result is checked structurally — compatibility
with `SomeGeneric<A>` is verified at instantiation.

Contrast:
- `<F: SomeGeneric>` — HKT constraint (F is a constructor of the same kind)
- `<T: SomeGeneric<integer>>` — regular constraint (T is a concrete type assignable to
  the instantiation `SomeGeneric<integer>`)

### What works (Approach 2, B1)

`F<A>` composition at direct call sites is supported via bidirectional
propagation. The kind bound `<F: SomeGeneric>` pins F to SomeGeneric at the
call site, and the alias body of SomeGeneric is pattern-matched against the
actual argument to back-solve the inner type arguments (`A`, `B`, ...).

```lua
--:: Maybe<A> = { tag: "some", value: A } | { tag: "none" }
--:: declare fmap = <F: Maybe, A, B>(fa: F<A>, f: (A) -> B) -> F<B>
local x = { tag = "none" } --: Maybe<integer>
local y = fmap(x, function(a) return tostring(a) end)
-- y : Maybe<string>
```

Return-only HKT slots (e.g. `pure: <M: Maybe>(a: A) -> M<A>` where M never
appears in a param) are pinned eagerly to the bound alias, so the return
slot resolves to `Maybe<integer>` once A is bound from the argument.

### Known limitations

- **Match-typed alias bodies cannot be inverted.** When the bound alias's
  body is a `match` type (`type Foo<X> = match X { ... }`), Approach 2
  cannot pattern-match the actual against the body to recover X. The
  typechecker emits an explicit "non-invertible alias body" error.
See `docs/typechecker-hkt-broader.md` for the design and the explicit
test pins H1-H6 (plus H2a-H2f for record dispatch) in
`lib/type/static/type_soundness_test.lua`.

## Generic defaults: `<T = Default>`

T defaults to `Default` if omitted at the call site.

```lua
--:: Nullable<T = unknown>    = T | nil
--:: Result<T, E = string>    = { ok: true, value: T } | { ok: false, error: E }
--:: Wrap<T, F = Container>   = F<T>   -- HKT default
```

Call sites:
```lua
--: Nullable           -- T = unknown  →  unknown | nil
--: Nullable<integer>  -- T = integer  →  integer | nil
--: Result<integer>    -- E = string   →  { ok: true, value: integer } | { ok: false, error: string }
--: Result<integer, Error>             →  { ok: true, value: integer } | { ok: false, error: Error }
```

The default must satisfy any constraint on the same parameter:
```lua
--:: Clamp<T: number = integer>  -- valid: integer <: number
--:: Clamp<T: number = string>   -- invalid: string </: number — error at definition site
```

## Combining constraint and default: `<T: U = Default>`

```lua
--:: Serialize<T: Encodable = string>
--:: Container<T, Err: Error = RuntimeError>
--:: Lift<F: Functor = Maybe, A>
```

Order within a parameter: constraint first, then default — `<T: U = Default>`. Both are
optional independently; any combination is valid.

## Parsing

In ann.lua, a generic parameter `<Name>` is extended to:

```
generic_param ::= Name (":" bound)? ("=" default_type)?
bound         ::= type_expr   -- if unapplied alias name: HKT constraint
                              -- otherwise: regular constraint
default_type  ::= type_expr
```

Distinguishing HKT from regular constraint: if `bound` resolves to a generic alias name
with no `<...>` application, it is an HKT constraint (`TAG_ALIAS` node, unapplied).
If it resolves to any other type expression (including an applied alias `SomeGeneric<X>`),
it is a regular constraint.

## In `declare` function signatures

```lua
--:: declare require = <T: string>(module: T) -> $Require<T>
--:: declare map = <F: Functor, A, B>(fa: F<A>, f: (A) -> B) -> F<B>
```

Generic parameters on `declare` follow the same rules.
