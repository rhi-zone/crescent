# Type-Level String Operations

## Status: needs careful design — not yet specced

Type-level string manipulation is hairy enough to warrant its own spec before
implementation. This file captures the known design questions.

## The useful minimal: literal concatenation in result expressions

`"prefix_" .. K` where K is a string literal type → new string literal.
Distributes over union K via existing match semantics (no special distribution rule
needed). This unblocks key-remapping use cases like `Getters<T>`.

This is the minimal useful subset. Do not implement pattern extraction until the
design is settled.

## Known hairy parts

### Lua `..` coerces numbers

In Lua, `1 .. "foo"` is legal and produces `"1foo"`. If K is an integer key (from an
indexer table), `"field_" .. K` should produce a string literal. TS doesn't face this —
crescent needs a decision: allow numeric types in `..` (producing string), or restrict
to string literals only.

### Widened string

`"prefix_" .. string` = `string` (reasonable). `string .. string` in pattern position
for extraction is non-deterministic — where does the split happen? Pattern extraction
over widened strings should probably be `never` or an error.

### Pattern extraction (reverse direction)

`"get_" .. %Suffix` as a match arm pattern — extracts the suffix from a string literal.
This is what TS had to hack around with `infer R extends string` in conditional types.
Crescent could do it more naturally, but the semantics need careful thought:

- Only literal prefixes? Only suffix? Both?
- What if the input doesn't start with the prefix? → arm fails (match moves on)
- What if K = `string` (not a literal)? → `Suffix = string` (widened), or arm fails?
- Nested: `"get_" .. %Prefix .. "_id"` — match a middle segment?

### Case transforms

TS added `Uppercase<K>`, `Lowercase<K>`, `Capitalize<K>`, `Uncapitalize<K>` as
permanent intrinsics — they can't be expressed as concatenation. Lua has
`string.upper`/`string.lower`. If crescent needs these, they'd be type-level
intrinsics too — more surface area, but the Lua parallel is natural.

## Recommended approach

1. Spec and implement literal concatenation in result expressions only first.
2. Leave pattern extraction for a separate design pass.
3. Decide on numeric coercion before implementing #1.
4. Case transforms only if a concrete use case demands them.
