# Type-Level Literal Operations

## Status: needs careful design — not yet specced

Operations on literal types at the type level. String concatenation is one case;
numeric arithmetic and other literal ops are equally in scope. This file captures
known design questions before implementation.

## String concatenation: `..`

`"prefix_" .. K` where K is a string literal → new string literal. Distributes
over union K via existing match semantics — no special distribution rule needed.

**Low priority.** Template literal types (`get_${K}`, `on${EventName}`) are a niche
pattern chosen for specific API aesthetics — not a fundamental need. The structured
alternative works equally well in both TS and Lua:

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

## Numeric arithmetic

Crescent has `LIT_INTEGER` as a first-class type. Type-level integer arithmetic is
a genuine extension TS never got — useful for tuple length, array indexing, recursive
type counting.

- `LIT_INTEGER(n) + LIT_INTEGER(m)` → `LIT_INTEGER(n + m)`
- `(1 | 2 | 3) + 1` → `2 | 3 | 4` via match distribution
- `integer + integer` (widened) → `integer`
- Division, negative numbers, floats: restrict to `LIT_INTEGER` `+`/`-` in v1

## Other literal ops

- **Tuple length**: `#(A, B, C)` → `3` as `LIT_INTEGER`. Enables `Arity<F>`.
- **Boolean**: `not true` → `false`. Probably only useful inside $EachField
  descriptor arms. Low priority.

## Recommended approach

1. String `..` in result expressions with numeric coercion (TS-compatible) first.
2. `LIT_INTEGER` arithmetic (`+`, `-`) second.
3. Pattern extraction (`"prefix_" .. %Suffix` in arm patterns) — separate pass.
4. Case transforms, tuple length, boolean ops only on concrete demand.
