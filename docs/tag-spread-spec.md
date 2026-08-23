# TAG_SPREAD: Explicit Multi-Return Annotation Syntax

## Problem

The current representation of multi-return function types is ambiguous.

`-> ((integer, integer) | (nil, string))` conflates two distinct meanings:
1. A function that returns a single value whose type is a union-of-tuples
2. A function whose multi-return is described by a union of return patterns

`peek_callee_ret_union` currently resolves this by shape-inspection: if ALL arms of the return union are TAG_TUPLE, treat it as multi-return. This is unsound — a function genuinely returning a single-value-union-of-tuples would be misidentified.

## Solution: Explicit `->` Spread Syntax

Introduce `-> ...(T)` in return position as the explicit multi-return marker.

```
-> integer?              -- single value, type is integer | nil
-> ...(integer)          -- variadic multi-return: every slot has type integer
-> ...((integer, integer) | (nil, string))  -- multi-return union of patterns (string.find style)
```

The `...` before the return type expression is the disambiguator. Without `...`, the return is always a single value regardless of whether the type happens to be a tuple or union-of-tuples.

### What `...(T)` means

Per `docs/semantics.md` §7.1 (ground-truth invariant, listed there as not yet
covered by a fuzz test but still the intended, documented behavior):

> Spread multi-return slot extraction: slot N has exactly the declared type.

No qualifier, no "first slot only." Every slot of a spread multi-return —
however many the caller asks for — has exactly `T`. This is a different
invariant from the regular (non-spread) multi-return case, `docs/semantics.md`
§7 #17: "slot N of a multi-return is the declared type; extra slots are nil."
That one applies to a *fixed*-arity `(A, B)`-style return, where the arity is
part of the type. `...(T)` is the opposite case — the annotation deliberately
does not state an arity, so there is no fixed length for "extra" to be beyond.

`-> ...(union-of-tuples)` (the `string.find`/`pcall` pattern) is a different
question — which of N fixed-arity patterns a single call matched, not how
many `T`-typed values came back — and is handled by its own existing,
untouched mechanism (`ctx._multi_ret` + `narrow.lua:filter_tuple_union_arms`),
not by the per-slot rule above.

## Grammar

```
return_type ::= "->" type_expr                  -- single value
              | "->" "..." "(" type_expr ")"    -- multi-return (spread)
```

The parentheses after `...` are required to avoid ambiguity with rest-params.

## Data Representation

A new AST node type is not needed — the existing return type slot in a function type annotation can carry a `TAG_SPREAD` wrapper:

```
TAG_SPREAD { inner: type_id }
```

When `peek_callee_ret_union` sees `TAG_SPREAD` in the return slot, it unwraps and returns the inner type (which may be a TAG_TUPLE, a union-of-tuples, or a plain type). Without `TAG_SPREAD`, `peek_callee_ret_union` wraps the return in a 1-tuple unconditionally.

## Changes Required

### ann.lua (annotation parser)
- After parsing `->`, check for `...(`
- If present: parse type_expr inside parens, wrap in `TAG_SPREAD`, store as return type
- If absent: parse type_expr normally (single value, no spread)

### constrain.lua — `peek_callee_ret_union`
Current (shape-based hack):
```lua
if ret_t.tag == TAG_UNION then
    local all_tuples = true
    for each arm: if not TAG_TUPLE then all_tuples = false end
    if all_tuples then return ret_slot  -- union-of-tuples exception
end
return types_mod.make_tuple(ctx, { ret_slot })  -- wrap in 1-tuple
```

New (explicit):
```lua
if ret_t.tag == TAG_SPREAD then
    return types_mod.find(ctx, ret_t.data[0])  -- unwrap, return inner (union-of-tuples or plain)
end
return types_mod.make_tuple(ctx, { ret_slot })  -- always wrap non-spread in 1-tuple
```

The union-of-tuples exception is removed. No shape inspection needed.

### solve.lua — `solve_callable`
`solve_callable` produces a scalar `ret` for expression contexts (e.g. `n * fac(n-1)`). This is unchanged — `ret` is the first slot of the return for use as an expression value, not the full tuple.

For `rl > 1` (multiple capture targets), the existing C_INDEX path already handles tuple destructuring.

### constrain.lua — argument spread (future)
`fn(string.find(s, p))` — the last argument is a spread. Not part of this spec; tracked separately.

## stdlib_types.lua Updates Required

Functions currently using the union-of-tuples hack must be re-annotated:

```lua
-- Before (shape-based, ambiguous):
--:: string.find: (s: string, pattern: string, init?: integer, plain?: boolean)
--::   -> ((integer, integer) | (nil, string))  -- WRONG: ambiguous

-- After (explicit spread):
--:: string.find: (s: string, pattern: string, init?: integer, plain?: boolean)
--::   -> ...((integer, integer) | (nil, string))

-- io.open:
--:: io.open: (filename: string, mode?: string) -> ...((file*, nil) | (nil, string))

-- string.byte (variadic multi-return):
--:: string.byte: (s: string, i?: integer, j?: integer) -> ...(integer)
```

## Tests to Write

1. `-> integer` is a single value, not a multi-return
2. `-> ...(integer)` is a 1-slot multi-return; `local x, y = f()` gives `x: integer, y: nil`
3. `-> ...((integer, integer) | (nil, string))` — string.find style; narrowing works after nil-check
4. `-> ((integer, integer) | (nil, string))` (no spread) — treated as single value returning union-of-tuples; no multi-return narrowing
5. `local s, e = string.find(...)` narrows after `if not s then return end`
6. `local result = string.find(...)` gives `result: (integer, integer) | (nil, string)` (first slot of spread = first element of inner)

## Performance Note

`peek_callee_ret_union` now always wraps non-spread returns in a 1-tuple. For rl=1 captures, this adds one tuple allocation + one C_INDEX projection. May want to re-specialize: if return is non-spread AND rl=1, bind directly without tuple barrier. Measure before deciding.
