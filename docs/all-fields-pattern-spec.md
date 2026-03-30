# All-Fields Pattern: `{ ...[K]: V }`

## Goal

Enable `$Keys`, `$Values`, `$IpairsValues`, `$PairsReturn`, and `$IpairsReturn` to be
eliminated as intrinsics by providing a single match arm pattern that distributes over
**all** entries in a table type — both named fields and indexers.

## Pattern Syntax

```
match_arm_pattern ::= ...
                    | "{" "..." "[" name "]" ":" name "}"  -- all-fields pattern
```

Example:

```lua
--:: PairsReturn<T> = match T {
--::   { [K]: V }    => (K, V),        -- indexer case (already exists)
--::   { ...[K]: V } => (string, V)    -- named-field case: K is always string
--:: }
```

The `{ ...[K]: V }` pattern matches **any table type** (it never fails to match) and binds:
- `K` → the union of all key types (string literal names widened to `string`, plus any indexer key type)
- `V` → the union of all widened value types (same as `$Values<T>`)

## Semantics

For a table type `T`:

```
{ ...[K]: V } matches T:
  - Always succeeds (even for empty tables, open tables, and non-tables — see below)
  - K binds to: union of string (if any named fields exist)
                 ∪ indexer_key_type (if T has an indexer { [KI]: VI })
                 = unknown   if T has neither
  - V binds to: $Values<T>  (union of widened value types, same semantics)
```

For non-table types, the pattern still succeeds but binds `K` and `V` to `unknown`.
This keeps the match total — callers can use it as a catch-all arm.

### Named fields

For a table with only named fields `{ x: integer, y: string }`:

- `K` → `string`  (all named-field keys are string literals, widened)
- `V` → `integer | string`  (union of all widened field value types)

### Indexer

For a table with an indexer `{ [string]: integer }`:

- `K` → `string`
- `V` → `integer`

### Mixed (named fields + indexer)

For `{ x: integer, [string]: boolean }`:

- `K` → `string`  (string from fields ∪ string from indexer = string)
- `V` → `integer | boolean`

### TAG_UNION input

For `T1 | T2` — distribute: `K` = union of all arm K-bindings, `V` = union of all arm V-bindings.

### TAG_ANY / TAG_UNKNOWN / TAG_VAR

- `K` → `unknown`, `V` → `unknown`

### TAG_NEVER

- `K` → `never`, `V` → `never`

## Relationship to `{ [K]: V }` (indexer pattern)

The existing `{ [K]: V }` pattern (already implemented) matches **only** tables that have
an explicit indexer. It fails for named-field tables. The new `{ ...[K]: V }` pattern
**always succeeds** and covers both cases.

In a match with both arms:

```lua
--:: PairsReturn<T> = match T {
--::   { [K]: V }    => (K, V),
--::   { ...[K]: V } => (string, V)
--:: }
```

The first arm handles indexer tables (K can be non-string). The second arm is the
fallback for named-field tables (K is always `string` after widening).

## Eliminating All Remaining Intrinsics

With `{ ...[K]: V }` and the already-implemented `{ [K]: V }`, all remaining provisional
intrinsics become expressible in stdlib.d.lua:

```lua
--:: PairsReturn<T> = match T {
--::   { [K]: V }    => (K, V),
--::   { ...[K]: V } => (string, V)
--:: }

--:: IpairsReturn<T> = match T {
--::   { [K]: V }    => match K { integer => (integer, V), _ => never },
--::   { ...[K]: V } => never
--:: }

--:: $Keys<T> ... -- see below
```

### `$Keys<T>` via `{ ...[K]: V }`

```lua
--:: Keys<T> = match T {
--::   { [K]: V }    => K,
--::   { ...[K]: V } => string
--:: }
```

Once `{ ...[K]: V }` exists, `$Keys` can be deleted.

### `$Values<T>` and `$IpairsValues<T>`

```lua
--:: Values<T> = match T {
--::   { [K]: V }    => V,
--::   { ...[K]: V } => V
--:: }
```

`$Values` and `$IpairsValues` can be deleted.

### Result: zero provisional `$`-intrinsics

After this pattern is implemented, the permanent intrinsics are:
- `$Require` — module system hook
- `$Opaque` — nominal identity
- `$FfiC` — closes over `ffi.cdef` call sites
- `$GlobalScope` — the global environment type

All other `$`-prefixed operations (`$PcallReturn` already eliminated,
`$PairsReturn`/`$IpairsReturn` already eliminated, `$Values`/`$IpairsValues` would be
eliminated) become match aliases expressible in stdlib.d.lua.

## ipairs and integer-key filtering

`ipairs` only yields integer-keyed entries. The approach is **not** a key-type constraint
on the pattern itself (no `{ ...[K: integer]: V }` syntax) — instead, use a downstream
match to filter:

```lua
--:: IpairsReturn<T> = match T {
--::   { [K]: V }    => match K { integer => (integer, V), _ => never },
--::   { ...[K]: V } => never
--:: }
```

- The `{ [K]: V }` arm matches tables with an explicit indexer. `match K { integer => ... }`
  narrows the result: if the indexer key is `integer`, yield `(integer, V)`; otherwise `never`.
- The `{ ...[K]: V }` fallback arm produces `never` for named-field tables (ipairs doesn't
  iterate them meaningfully — they have no numeric ordering).

This is consistent with what ipairs actually does: it only works on sequence-like tables.

### Why not `{ ...[K: integer]: V }`?

Two separate needs are in play:

1. **Filter which entries appear in results** (ipairs semantics: "yield only integer-keyed
   entries, ignore the rest") — handled by downstream `match K { integer => ..., _ => never }`.
   The pattern itself stays total; the filtering is explicit in the result expression.

2. **Constrain the input shape** ("this table must have these fields / this structure") —
   handled by pattern intersection `P & { ...[K]: V }`, where `P` can be any pattern:
   `{ [integer]: unknown } & { ...[K]: V }` requires an integer indexer;
   `{ foo: string, bar: number, ... } & { ...[K]: V }` requires specific named fields.

`{ ...[K: integer]: V }` conflates these two: it looks like an input constraint but acts
like a result filter. Keeping them separate is cleaner — `{ ...[K]: V }` is always total,
and the caller chooses to filter results or constrain inputs via the mechanisms above.

## Implementation in `match.lua`

The `{ ...[K]: V }` pattern is a new case in `eval_match_arm`. At match-arm evaluation time:

1. **Detect** the pattern: a table pattern with `...` before `[K]: V`.
   Syntactically this is distinguished from `{ [K]: V }` by the leading `...`.

2. **Always succeed** (never return `nil`).

3. **Bind K**: collect key types:
   - For each named field: add `string` (widened from literal names)
   - For indexer `{ [KI]: VI }`: add `KI`
   - Union all collected types → if none, bind `K` = `unknown`

4. **Bind V**: use the same logic as `extract_values(ctx, T_tid, false)` from intrinsic.lua
   (or equivalently, call `$Values<T>`). Bind `V` = result.

5. **For TAG_UNION input**: distribute across arms, union K-bindings and V-bindings.

6. **For TAG_ANY/TAG_UNKNOWN/TAG_VAR/TAG_NEVER**: bind K and V appropriately (unknown/never).

### Parsed representation

In ann.lua, when parsing a match arm pattern `{ ...[K]: V }`:

- Emit a new `PAT_ALL_FIELDS` pattern node with two binding names: K and V
- Distinct from `PAT_INDEXER` (`{ [K]: V }`)

### In `match.lua:eval_match_arm`

Add a branch for `PAT_ALL_FIELDS`:

```lua
elseif pat.kind == PAT_ALL_FIELDS then
    local k_name = pat.k_name
    local v_name = pat.v_name
    local k_tid, v_tid = eval_all_fields(ctx, input_tid)
    local new_mapping = copy_mapping(mapping)
    new_mapping[k_name] = k_tid
    new_mapping[v_name] = v_tid
    return eval_result_expr(ctx, arm.result, new_mapping)
```

`eval_all_fields(ctx, tid)` computes K and V for any input type (the logic described in §Semantics above).

## Data Representation

In the parsed AST for a match arm pattern, add:

```lua
PAT_ALL_FIELDS = N   -- new constant in defs.lua (or match.lua)
-- node: { kind = PAT_ALL_FIELDS, k_name = "K", v_name = "V" }
```

## Tests

Add to `lib/type/static/type_test.lua`:

1. `match { x = 1, y = "hello" } { { ...[K]: V } => V }` → `integer | string`
2. `match { [string]: integer } { { ...[K]: V } => K }` → `string`
3. `PairsReturn<{ x: integer, y: string }>` → `(string, integer | string)`
4. `PairsReturn<{ [string]: integer }>` → `(string, integer)`
5. `IpairsReturn<{ [integer]: string }>` → `(integer, string)`
6. `IpairsReturn<{ x: integer }>` → `never` (named-field tables yield never from ipairs)
7. `Keys<{ x: integer, y: string }>` → `string`
8. `Keys<{ [integer]: boolean }>` → `integer`
9. `Values<{ x: integer, y: string }>` → `integer | string`
10. Regression: existing pairs/ipairs tests still pass after `$Values`/`$IpairsValues` are deleted

## Migration: deleting `$Values` and `$IpairsValues`

Once `{ ...[K]: V }` is implemented and the above tests pass:

1. Replace `PairsReturn` and `IpairsReturn` in stdlib.d.lua with the new match-alias forms
2. Replace `Keys` (if added to stdlib) with the new form
3. Delete `$Values` and `$IpairsValues` branches from `intrinsic.lua`
4. Delete `extract_values` from `intrinsic.lua` (logic now lives in `match.lua:eval_all_fields`)
5. Update `docs/semantics.md` §8 — remove `$Values`/`$IpairsValues` rows

## Relation to Existing Patterns

| Pattern         | Matches           | Binds            | Can fail? |
|-----------------|-------------------|------------------|-----------|
| `{ [K]: V }`    | Indexer tables    | K=key, V=value   | Yes (no indexer → fail) |
| `{ ...[K]: V }` | Any table (total) | K=key∪, V=val∪  | No        |
| `() -> R`       | Any function      | R=return type    | No        |

The `{ ...[K]: V }` pattern follows the same "total catch-all" design as `() -> R` in
function-arm patterns: it always succeeds and is intended as the fallback arm.

## Future: Pattern Intersection (`P & Q`)

Pattern intersection `P & { ...[K]: V }` would allow constraining the *input* while
binding K/V from all entries. Concrete cases worth preserving:

```lua
-- Tables with specific named fields:
--:: FooBarEntries<T> = match T {
--::   { foo: string, bar: number, ... } & { ...[K]: V } => (K, V)
--:: }

-- Tables with an integer indexer (K is already integer after the constraint):
--:: IntIndexedEntries<T> = match T {
--::   { [integer]: unknown } & { ...[K]: V } => (K, V)
--:: }
-- Note: K here is integer (from the indexer), not string | integer —
-- the left pattern restricts which tables match, so V also only comes
-- from integer-indexed entries when the table is a pure indexer table.
-- For mixed tables { x: string, [integer]: boolean }, K would be
-- string | integer because { ...[K]: V } still sees all fields.

-- Union of known shapes:
--:: ShapeAOrB<T> = match T {
--::   (A | B) & { ...[K]: V } => (K, V)
--:: }
-- Accepts only tables that are subtypes of A | B; binds all their entries.
```

These are all real use cases that would be awkward to express without `&`. The two operations are orthogonal:

- **`{ ...[K]: V }` result filter** (`match K { integer => ... }`): controls what appears
  in the *output* of the match result expression.
- **Pattern intersection** (`P & { ...[K]: V }`): controls what *input* types are accepted.

Pattern `&` is not needed for `{ ...[K]: V }` itself — the existing use cases (PairsReturn,
IpairsReturn, Keys, Values) are all covered without it. It's a separate future feature that
composes naturally with this pattern when input-shape constraints are needed.
