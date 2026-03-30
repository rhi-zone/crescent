# All-Fields Pattern: `{ ...[K]: V }`

## Goal

Enable `$Keys`, `$Values`, `$IpairsValues`, `$PairsReturn`, and `$IpairsReturn` to be
eliminated as intrinsics by providing a single match arm pattern that **distributes**
over every entry in a table type — both named fields and indexers.

## Pattern Syntax

```
match_arm_pattern ::= ...
                    | "{" "..." "[" name "]" ":" name "}"  -- all-fields pattern
```

## Semantics: per-field distribution

`{ ...[%K]: %V }` distributes over each field in the table, the same way match
distributes over union arms. For each field, K and V are bound to that field's
specific key and value types, the result expression is evaluated, and all results
are unioned.

For `{ x: integer, y: string }` with arm `{ ...[%K]: %V } => (K, V)`:
- field `x`: K = `"x"`, V = `integer` → `("x", integer)`
- field `y`: K = `"y"`, V = `string`   → `("y", string)`
- result: `("x", integer) | ("y", string)`

This is exactly what `pairs()` iterates — a discriminated union of (key, value) pairs,
one per field. Far more precise than a collapsed `(string, integer | string)`.

For an indexer table `{ [integer]: string }`:
- indexer: K = `integer`, V = `string` → `(integer, string)`

For a mixed table `{ x: integer, [integer]: string }`:
- field `x`: K = `"x"`, V = `integer` → `("x", integer)`
- indexer:   K = `integer`, V = `string`  → `(integer, string)`
- result: `("x", integer) | (integer, string)`

The pattern **always matches** (total) — it never fails an arm.

### TAG_UNION input

Distribute over union arms first (standard match behaviour), then distribute over each
arm's fields. Results from all arms and all fields are unioned.

### TAG_ANY / TAG_UNKNOWN / TAG_VAR

One synthetic iteration: K = `unknown`, V = `unknown`. Keeps the pattern total.

### TAG_NEVER

Zero iterations — result is `never` (empty union).

## Consequence: simplified stdlib aliases

Because `{ ...[%K]: %V }` distributes precisely per-field, PairsReturn collapses to one arm:

```lua
--:: PairsReturn<T>  = match T { { ...[%K]: %V } => (K, V) }
--:: IpairsReturn<T> = match T { { ...[%K]: %V } => match K { integer => (integer, V), _ => never } }
--:: Keys<T>         = match T { { ...[%K]: %V } => K }
--:: Values<T>       = match T { { ...[%K]: %V } => V }
```

The `{ [%K]: %V }` arm in `PairsReturn` is no longer needed — `{ ...[%K]: %V }` handles
indexer tables (K = indexer key type, one iteration) and named-field tables (K = string
literal per field, N iterations) uniformly.

`IpairsReturn`: for `{ [integer]: string }`, K = `integer` → match K passes → `(integer, string)`.
For `{ x: integer }`, K = `"x"` → match K fails → `never`. Correct with one arm.

`Keys<T>` for `{ x: integer, y: string }` → `"x" | "y"` (union of per-field K results).
`Values<T>` for `{ x: integer, y: string }` → `integer | string` ✓

## Eliminating All Remaining Intrinsics

With `{ ...[%K]: %V }`, all remaining provisional intrinsics become expressible:

```lua
--:: PairsReturn<T>  = match T { { ...[%K]: %V } => (K, V) }
--:: IpairsReturn<T> = match T { { ...[%K]: %V } => match K { integer => (integer, V), _ => never } }
--:: Keys<T>         = match T { { ...[%K]: %V } => K }
--:: Values<T>       = match T { { ...[%K]: %V } => V }
```

Delete `$PairsReturn`, `$IpairsReturn`, `$Keys`, `$Values`, `$IpairsValues` from intrinsic.lua.
`$PcallReturn` already eliminated (spread-in-tuple-position, 2026-03-30).

Permanent intrinsics after migration: `$Require`, `$Opaque`, `$FfiC`, `$GlobalScope`.

## ipairs and integer-key filtering

The downstream `match K { integer => ..., _ => never }` approach still applies — see
§Semantics above. `{ ...[%K]: %V }` is always total; filtering happens in the result.

## What `{ ...[%K]: %V }` does NOT do: per-field reconstruction

Per-field distribution gives a **union of result expressions** — one per field. This is
right for iteration (PairsReturn, Keys, Values) but cannot reconstruct a single table
with all fields transformed. `Partial<T>` is inexpressible:

```lua
-- WRONG: distributes, gives { ["x"]: integer? } | { ["y"]: string? } — not Partial<T>
--:: Partial<T> = match T { { ...[%K]: %V } => { [K]: V? } }
```

Table reconstruction (gather all fields into one table with per-field transformation)
requires a separate mechanism — see docs/mapped-types-comparison.md for options.

## Relationship to `{ [%K]: %V }` (indexer pattern)

`{ [%K]: %V }` matches only tables with an explicit indexer (fails for named-field
tables). `{ ...[%K]: %V }` is total and subsumes it — if the input has an indexer,
the indexer is iterated; if it has named fields, those are iterated. The `{ [%K]: %V }`
arm is only needed when you want to *fail* on named-field tables.

## Implementation in `match.lua`

`{ ...[%K]: %V }` is a `PAT_ALL_FIELDS` node. In `eval_match_arm`:

```lua
elseif pat.kind == PAT_ALL_FIELDS then
    local results = {}
    -- iterate named fields
    for each (name_id, value_tid) in table_fields(ctx, input_tid) do
        local mapping = copy_mapping(mapping)
        mapping[pat.k_name] = make_lit_string(ctx, name_id)
        mapping[pat.v_name] = value_tid
        results[#results+1] = eval_result_expr(ctx, arm.result, mapping)
    end
    -- iterate indexers
    for each (key_tid, value_tid) in table_indexers(ctx, input_tid) do
        local mapping = copy_mapping(mapping)
        mapping[pat.k_name] = key_tid
        mapping[pat.v_name] = value_tid
        results[#results+1] = eval_result_expr(ctx, arm.result, mapping)
    end
    -- TAG_ANY/TAG_UNKNOWN: one synthetic K=unknown, V=unknown iteration
    -- TAG_NEVER: zero iterations (return never)
    return types_mod.make_union(ctx, results)
```

This replaces `eval_all_fields(ctx, tid)` — no longer needed as a (K_union, V_union)
extractor. `extract_values` in intrinsic.lua is also deleted once $Values/$IpairsValues
are migrated to match aliases.

## Data Representation

```lua
PAT_ALL_FIELDS = N   -- new constant in defs.lua (or match.lua)
-- node: { kind = PAT_ALL_FIELDS, k_name = "K", v_name = "V" }
```

## Tests

Add to `lib/type/static/type_test.lua`:

1. `PairsReturn<{ x: integer, y: string }>` → `("x", integer) | ("y", string)` (precise!)
2. `PairsReturn<{ [string]: integer }>` → `(string, integer)`
3. `IpairsReturn<{ [integer]: string }>` → `(integer, string)`
4. `IpairsReturn<{ x: integer }>` → `never`
5. `Keys<{ x: integer, y: string }>` → `"x" | "y"` (literal, not widened `string`)
6. `Keys<{ [integer]: boolean }>` → `integer`
7. `Values<{ x: integer, y: string }>` → `integer | string`
8. `match { x = 1, y = "hello" } { { ...[%K]: %V } => (K, V) }` → `("x", integer) | ("y", string)`
9. Regression: existing pairs/ipairs tests still pass

## Future: Pattern Intersection (`P & Q`)

`P & { ...[%K]: %V }` — P constrains the input, `{ ...[%K]: %V }` distributes over its
fields. P is arbitrary:

```lua
--:: Entries<T> = match T {
--::   { foo: string, ... }    & { ...[%K]: %V } => (K, V),  -- named field constraint
--::   { [integer]: unknown }  & { ...[%K]: %V } => (K, V),  -- indexer constraint
--::   (A | B)                 & { ...[%K]: %V } => (K, V),  -- union type constraint
--::   () -> unknown           & { ...[%K]: %V } => (K, V),  -- callable objects (__call tables)
--:: }
```
