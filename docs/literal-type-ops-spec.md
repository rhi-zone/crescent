# Type-Level Literal Operations

## Status: needs careful design — not yet specced

Operations on literal types at the type level. String concatenation is one case;
numeric arithmetic and other literal ops are equally in scope. This file captures
known design questions before implementation.

## String concatenation: `..`

`"prefix_" .. K` where K is a string literal → new string literal. Distributes
over union K via existing match semantics — no special distribution rule needed.

**Low priority.** Template literal types exist primarily to retrofit types onto
JavaScript's stringly-typed API patterns: `addEventListener("click", ...)`,
`getX()`/`setX()` Java-style conventions, `data-*` HTML attributes, CSS property
names. These patterns exist because JS is historically dynamic and string-keyed —
TypeScript inherited them and needed type-level string manipulation to describe them.

Lua/crescent has none of this heritage. No DOM, no Java-style getter/setter
convention, no stringly-typed event system. The primary motivation for template
literal types doesn't apply. The structured alternative is equally clean:

```lua
--:: ToGetSet<D> = match D { { key: %K, value: %V, ...%Rest }
--::   => { { key: K, value: { get: () -> V, set: (V) -> nil }, ...Rest } } }
```

Same key, value wrapped in `{ get, set }` — no string ops needed. Implement `..`
when a concrete library actually needs flat string-key generation.

**Numerics in `..`** (when implemented): follow TS prior art — `LIT_INTEGER` and
`LIT_NUMBER` coerce to string representation. `"field_" .. (1 | 2 | 3)` →
`"field_1" | "field_2" | "field_3"`.

**Widened string**: `"prefix_" .. string` = `string`.

**Pattern extraction** (`"get_" .. %Suffix` in arm patterns): separate design pass,
even lower priority than result-position `..`.

**Case transforms**: only on concrete demand.

## Tuple length: `#T`

`#{ A, B, C }` → `3` as `LIT_INTEGER`. The most immediately useful numeric op:

- `Arity<F> = match F { (...%P) -> _ => #P }` — once `(...%P)` param capture is implemented
- `Repeat<T, N>`: accumulate a tuple, stop when `#Acc` matches N — no arithmetic needed
- `TupleAt<T, N>`: direct indexed access `T[N]` — already works with numeric literals

These cover the cases that naively seem to need arithmetic. TS solves the same
problems with tuple accumulator tricks; crescent can do the same with `#tuple`.

## Numeric arithmetic: `+`, `-`, etc.

Crescent has `LIT_INTEGER` as a first-class type — arithmetic would be a genuine
capability TS lacks. But the concrete use cases fold:
- `Repeat<T, N>` → accumulator + `#tuple` (no `N-1` needed)
- `TupleAt<T, N>` → direct indexing (no arithmetic needed)

No concrete use case identified yet. Implement when one appears.

## Boolean ops

Trivially expressible as match aliases — no new primitives needed:

```lua
--:: Not<B>    = match B { true => false, false => true }
--:: And<A, B> = match A { true => B, false => false }
--:: Or<A, B>  = match A { true => true, false => B }
```

## Recommended approach

1. `#tuple` length — concrete use cases exist today (`Arity<F>`, `Repeat`, etc.)
2. String `..` and `LIT_INTEGER` arithmetic — only on concrete demand.
