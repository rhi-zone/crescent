# Type-Level Literal Operations

## Status: needs careful design — not yet specced

Operations on literal types at the type level. String concatenation is one case;
numeric arithmetic and other literal ops are equally in scope. This file captures
known design questions before implementation.

## String concatenation: `..`

`"prefix_" .. K` where K is a string literal → new string literal. Distributes
over union K via existing match semantics — no special distribution rule needed.

**Numerics in `..`**: TS prior art — template literals accept `string | number |
bigint | boolean | null | undefined`, e.g. `` `prefix_${1 | 2 | 3}` `` →
`"prefix_1" | "prefix_2" | "prefix_3"`. Crescent follows the same rule: `LIT_INTEGER`
and `LIT_NUMBER` coerce to their string representation in `..`. Integer key fields
produce string keys when concatenated.

**Widened string**: `"prefix_" .. string` = `string`. `string .. string` in pattern
position for extraction — arm fails (can't extract from non-literal).

**Pattern extraction**: `"get_" .. %Suffix` as a match arm pattern. Natural in
crescent; TS required `infer R extends string` hacks. Open questions:
- Input doesn't match prefix → arm fails, match continues
- Input is widened `string` → arm fails
- Multiple segments: `"get_" .. %Mid .. "_id"` — ambiguity needs thought

**Case transforms**: TS added `Uppercase`/`Lowercase`/`Capitalize`/`Uncapitalize`
as permanent intrinsics. Lua has `string.upper`/`string.lower` — natural parallel,
but only on concrete demand.

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
