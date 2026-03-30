# Partial Application of Generic Aliases

## Goal

Enable `Pick<T, Keys>` and `Omit<T, Keys>` via `$EachField`:

```lua
--:: PickKey<Keys, D> = match D {
--::   { key: %K, ...%Rest } => match K { Keys => { D }, _ => {} },
--::   _ => {}
--:: }
--:: Pick<T, Keys>  = $EachField<T, PickKey<Keys>>
--:: Omit<T, Keys>  = $EachField<T, OmitKey<Keys>>

--:: OmitKey<Keys, D> = match D {
--::   { key: %K, ...%Rest } => match K { Keys => {}, _ => { D } },
--::   _ => { D }
--:: }
```

`$EachField` expects F to be a single-parameter callable. `PickKey<Keys>` partially
applies the first argument, returning a value that accepts one more argument (D).

## Design: under-arity application returns TAG_PARTIAL_APP

No new syntax. A multi-param alias called with fewer args than required (and no defaults
cover the gap) returns `TAG_PARTIAL_APP(name_id, partial_args)` instead of an error.

### `resolve_named_type` change

Current: arity mismatch → error.

New: if `arg_ids_len < required_count` AND `arg_ids_len > 0` (at least one arg supplied,
but not enough to fully apply):
- Return `TAG_PARTIAL_APP` node encoding `(name_id, arg_ids)`
- No error

Zero-arg partial application is not supported (just use the alias name unapplied — that
already works as TAG_NAMED passed to $EachField/apply_type_fn).

### TAG_PARTIAL_APP

New tag in defs.lua: `TAG_PARTIAL_APP`.

Node layout: `data[0]` = name_id (interned alias name), `data[1]` = list start,
`data[2]` = list length (the partial args list in ctx.lists).

### `apply_type_fn` change

Add case for TAG_PARTIAL_APP:
- Retrieve name_id and partial_args from the node
- Call `resolve_named_type(ctx, scope, name_id, partial_args ++ [member_tid])`

### `substitute_inner` and `instantiate_inner` in env.lua

TAG_PARTIAL_APP with TAG_VAR-or-TAG_NAMED args must defer (same pattern as
TAG_NAMED with unresolved args). When the partial args are concrete:
- Evaluate eagerly or keep deferred depending on whether the remaining arg is also concrete

In practice: TAG_PARTIAL_APP is only created when partial_args are concrete (resolved at
call site), so deferred evaluation only applies if the partial app is itself under a
generic parameter. Handle conservatively: if partial_args contain any TAG_VAR, keep as
deferred.

## Match arm subtype patterns

`match K { Keys => ... }` where Keys is a bound type param (already substituted to a
concrete type like `"x" | "y"`) should succeed if K is a subtype of Keys. This uses the
existing TAG_NAMED pattern matching path in match.lua: when the pattern is a TAG_NAMED
that resolves to a concrete type, check `is_subtype(ctx, actual_tid, pattern_tid)`.

If this path already works (TAG_NAMED in pattern position does a subtype check), no
change needed. If it only checks equality, extend to subtype.

## Examples

```lua
--:: PickKey<Keys, D> = match D {
--::   { key: %K, ...%Rest } => match K { Keys => { D }, _ => {} },
--::   _ => {}
--:: }
--:: Pick<T, Keys>  = $EachField<T, PickKey<Keys>>
-- Pick<{ x: integer, y: string }, "x"> → { x: integer }

--:: OmitKey<Keys, D> = match D {
--::   { key: %K, ...%Rest } => match K { Keys => {}, _ => { D } },
--::   _ => { D }
--:: }
--:: Omit<T, Keys>  = $EachField<T, OmitKey<Keys>>
-- Omit<{ x: integer, y: string }, "x"> → { y: string }
```

## Non-goals

- Curried declaration syntax (`--:: F<A><B>`) — not needed; under-arity call is enough
- Multi-level partial application (`F<A><B><C>`) — TAG_PARTIAL_APP can only store one
  round of partial args; further partial application (calling TAG_PARTIAL_APP with fewer
  args than remaining) is out of scope for now
- Point-free composition — no `compose(F, G)` for type aliases

## Error cases

- `PickKey<>` (zero args) → error: at least one arg required
- `PickKey<A, B, C>` (too many) → existing error
- TAG_PARTIAL_APP in a position expecting a concrete type (not HKT) → the downstream
  code that receives the type will see TAG_PARTIAL_APP and fail naturally (treating it
  as an unresolved type, likely producing T_NEVER or an error)
