# `pairs`/`ipairs` De-Specialcase Spec

## Current Behavior

`pairs`/`ipairs` are special-cased in constrain.lua (search `fn_name == "pairs"`). The special case extracts `[K]: V` indexer types from the table argument and synthesizes typed loop variables inline.

## The Type Problem

`pairs(t)` returns an iterator triple `(next_fn, t, nil)`. The for-in loop calls `next_fn(t, prev_key)` each iteration, yielding `(key, value)` pairs. For typed iteration, the yielded `(K, V)` types must come from `t`'s type.

This is hard to express in a single generic type because:
1. The key and value types depend on the concrete table type `T`
2. The iterator function must be typed `(T, K) -> (K?, V)`
3. `K` and `V` must be extracted from `T`'s indexer or fields

## Approach: `$PairsIter<T>` and `$PairsKey<T>`, `$PairsVal<T>` Intrinsics

Three intrinsics:
- `$PairsIter<T>` — the iterator function type: `(T, $PairsKey<T>?) -> ($PairsKey<T>?, $PairsVal<T>)`
- `$PairsKey<T>` — the key type of T's indexer (or `string` for field-only tables, `integer` for arrays)
- `$PairsVal<T>` — the value type of T's indexer (or union of all field value types for field-only tables)

### stdlib.d.lua Declaration

```lua
--:: declare pairs: <T>(t: T) -> ...($PairsIter<T>, T, $PairsKey<T>?)
--:: declare ipairs: <T>(t: T) -> ...($IpairsIter<T>, T, integer)
```

where `$IpairsIter<T>` yields `(integer, $IpairsVal<T>)` from numeric indexer.

## Simpler V1: `$PairsReturn<T>` All-in-One

Rather than three separate intrinsics, one intrinsic produces the whole iterator triple type:

```lua
--:: declare pairs: <T>(t: T) -> ...$PairsReturn<T>
```

`$PairsReturn<T>` evaluates to a TAG_TUPLE of `(iter_fn, T, key_or_nil)` where:
- `iter_fn` has type `(T, K?) -> (K?, V)` with K/V extracted from T
- K = T's indexer key type; if no indexer, union of all field name literal types
- V = T's indexer value type; if no indexer, union of all field value types

For `{ [string]: number }`: K = string, V = number
For `{ x: integer, y: string }` (no indexer): K = "x" | "y", V = integer | string
For `{}` (empty open table): K = unknown, V = unknown

### `$IpairsReturn<T>` for ipairs

K is always integer (ipairs only works on arrays). V = T's numeric indexer value type or union of integer-keyed fields.

## Implementation

### intrinsic.lua

```lua
local function expand_pairs_return(ctx, arg_ids)
    local T_tid = types_mod.find(ctx, arg_ids[1])
    local T_t = ctx.types:get(T_tid)
    -- extract indexer key/value types from T
    local K_tid, V_tid = extract_table_kv(ctx, T_tid)
    -- build iter_fn: (T, K?) -> (K?, V)
    local iter_fn = -- TAG_FUNCTION { params: {T_tid, union(K_tid, T_NIL)}, ret: TAG_TUPLE{union(K_tid, T_NIL), V_tid} }
    -- return tuple: (iter_fn, T, K?)
    return types_mod.make_tuple(ctx, { iter_fn, T_tid, types_mod.make_union(ctx, {K_tid, ctx.T_NIL}) })
end
```

`extract_table_kv`: if TAG_TABLE has an indexer, return (indexer_key, indexer_val). If no indexer but has fields, return (union of field name literals, union of field value types). Otherwise (TAG_VAR, TAG_ANY, etc.), return (T_UNKNOWN, T_UNKNOWN).

### for-in loop constraint generation

The for-in loop already calls the first return value (the iterator function) with state and key to get loop variables. Once `pairs` returns a typed iterator triple, the loop variable types should flow naturally through the existing for-in path. Verify this works or adjust `StmtRule[NODE_FOR_IN]` in constrain.lua.

### Removing the constrain.lua special case

After `$PairsReturn<T>` and `$IpairsReturn<T>` are working, delete the `fn_name == "pairs"` / `fn_name == "ipairs"` special-case blocks.

## Tests

1. `for k, v in pairs({ x = 1, y = "hello" })` — k: "x" | "y", v: integer | string
2. `for k, v in pairs({ [string]: number })` — k: string, v: number
3. `for i, v in ipairs({ 1, 2, 3 })` — i: integer, v: integer
4. `for k, v in pairs(t)` where t is `unknown` — k: unknown, v: unknown (no error)
5. Existing typed pairs tests in type_test.lua still pass

## Note on Field-Only Tables

For a table with only named fields and no indexer, `pairs` in Lua yields the field names as strings. So K = string (not a union of literal names) is technically more correct at runtime — `pairs` doesn't know at runtime which keys exist. The literal-name union is a static-analysis enrichment that gives better downstream narrowing but may over-specify. Use `string` as K for field-only tables unless indexer is present.
