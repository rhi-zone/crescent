# $Values<T> Intrinsic

## Goal

Enable `$PairsReturn<T>` and `$IpairsReturn<T>` to be expressed as
user-definable match aliases instead of compiler intrinsics. Specifically:

```lua
--:: PairsReturn<T> = match T {
--::   { [K]: V } => (K, V),
--::   T          => (string, $Values<T>)
--:: }

--:: IpairsReturn<T> = match T {
--::   T => (integer, $IpairsValues<T>)
--:: }
```

`$Values<T>` is the union of all widened field value types in T — the type
you get for `v` in `for k, v in pairs(t)` when `t` is a named-field table.

## Semantics

```
$Values<T>:
  - T has an indexer { [K]: V }: return V
  - T has only named fields: return union of widen(field.type) for each field
  - T is empty or open with no fields: return unknown
  - T is TAG_UNION: return union of $Values<arm> for each arm
  - T is TAG_INTERSECTION: return $Values<first member that is TAG_TABLE>
  - T is TAG_ANY/TAG_UNKNOWN/TAG_VAR: return unknown
  - T is TAG_NEVER: return never
```

`widen` converts literals to their base type (LIT_INTEGER → TAG_INTEGER,
LIT_STRING → TAG_STRING, etc.) — same as `types_mod.widen`. This matches
the existing behaviour in `intrinsic.lua` `extract_pairs_kv`.

`$IpairsValues<T>` is the same but restricted to numeric indexers and
positionally-named fields ("1", "2", ...):
```
$IpairsValues<T>:
  - T has a numeric indexer { [integer]: V }: return V
  - T has positional fields ("1", "2", ...): return union of their value types
  - Otherwise: return unknown
```

## Why a new intrinsic, not a match pattern?

To replace the intrinsic entirely we'd need a match pattern that says
"union of all field value types." That requires iterating over a type's
fields at match-evaluation time, which match patterns cannot currently do —
they match a single pattern against the whole type, not iterate.

`$Values<T>` is the minimal addition: one new intrinsic that encapsulates
the field-iteration logic already in `extract_pairs_kv`. Once it exists,
`$PairsReturn` and `$IpairsReturn` become expressible in stdlib.d.lua and
their intrinsic branches can be deleted.

The long-term goal (elimination of all `$`-prefixed intrinsics except
`$Require`, `$Opaque`, `$FfiC`, `$GlobalScope`) is served by this: `$Values`
itself is the only new permanent intrinsic addition here, and it is a simple
pure type function with no side effects.

## Implementation

### intrinsic.lua — add $Values and $IpairsValues

Add to the `resolve_intrinsic` dispatch (near the existing `$Keys` branch):

```lua
if name == "Values" then
    -- $Values<T>: union of widened field value types
    local T_tid = types_mod.find(ctx, arg_ids[1])
    return extract_values(ctx, T_tid, false)  -- false = pairs (not ipairs)
end

if name == "IpairsValues" then
    -- $IpairsValues<T>: union of numeric/positional field value types
    local T_tid = types_mod.find(ctx, arg_ids[1])
    return extract_values(ctx, T_tid, true)   -- true = ipairs
end
```

`extract_values` is a refactor of the relevant logic already in
`extract_pairs_kv` (intrinsic.lua lines 274-330). Extract the V-computation
into a standalone function and call it from both the existing
`extract_pairs_kv` and the new `$Values`/`$IpairsValues` branches.

### stdlib.d.lua — replace $PairsReturn and $IpairsReturn

```lua
--:: declare pairs  = <T>(t: T) -> ...(PairsReturn<T>)
--:: declare ipairs = <T>(t: T) -> ...(IpairsReturn<T>)

--:: PairsReturn<T> = match T {
--::   { [K]: V } => (K, V),
--::   T          => (string, $Values<T>)
--:: }

--:: IpairsReturn<T> = match T {
--::   T => (integer, $IpairsValues<T>)
--:: }
```

The `{ [K]: V }` indexer arm is already implemented in match.lua (2026-03-29).
The catch-all arm `T => ...` uses the original alias parameter `T` — because
alias-param substitution happens before match evaluation, `T` is already
concrete at the time the match arms are tried.

### intrinsic.lua — delete $PairsReturn and $IpairsReturn branches

Once the match aliases are in stdlib.d.lua and tests pass, delete the
`PairsReturn` and `IpairsReturn` branches from `resolve_intrinsic`.

## Known Limitation: $PairsReturn Scope Leak

From CLAUDE.md:
> Known leak for $PairsReturn: when two `pairs()` loops are merged into one
> variable, the constraint chain breaks and `$PairsReturn<T>` escapes scope.
> Workaround: explicit `--:` annotation.

The match alias form will have the same limitation because the root cause is
in constraint propagation, not the intrinsic itself. The workaround (explicit
annotation) remains valid. This limitation is NOT a blocker for implementing
`$Values`.

## Tests

Add to `lib/type/static/type_test.lua`:

1. `pairs({ x = 1, y = "hello" })` — iterator value type is `integer | string`
2. `pairs({ [string]: integer })` — iterator types are `string`, `integer`
3. `ipairs({ 1, 2, 3 })` — iterator types are `integer`, `integer`
4. `for k, v in pairs({ name = "alice", age = 30 }) do` — k: string, v: integer | string (widened)
5. Regression: existing pairs/ipairs tests in type_test.lua must still pass

Also add `$Values` and `$IpairsValues` to the list of known type-level
operations in `docs/semantics.md` §8.

## Relation to $Keys

`$Keys<T>` already exists and returns the union of string literal field names.
`$Values<T>` is its symmetric counterpart for values. Consider documenting
them together as a pair in docs/semantics.md.
