# Spread-in-Tuple-Position Syntax: `(A, ...R)`

## Goal

Enable `$PcallReturn<F>` to be expressed as a user-definable match alias
instead of a compiler intrinsic. Specifically:

```lua
--:: PcallReturn<F> = match F { () -> %R => (true, ...R) | (false, string) }
```

Where `R` is bound to the multi-return tuple of F by the existing `() -> %R`
function-arm pattern (see match.lua lines 185-218), and `...R` splices R's
elements into the result tuple.

## Current State

`() -> %R` in a match arm already binds R:
- If F returns 1 value: R = that value type (e.g. `integer`)
- If F returns N>1 values: R = TAG_TUPLE(all return types)

But `(true, ...R)` cannot currently be written — `...R` in tuple position
is not parsed.

## Syntax

```
tuple_type ::= "(" type_expr ("," type_expr)* ("," "..." name)? ")"
             | "(" "..." name ")"
```

`...R` in the last position of a tuple spreads the binding named `R`. `R`
must be a name that will be bound by the match pattern (i.e. a TAG_NAMED
alias param or match arm binding).

## Semantics

At match result-expression evaluation time (in `env.lua` `substitute_inner`
when processing a TAG_TUPLE that contains a trailing TAG_SPREAD entry):

1. Resolve the spread's inner type (TAG_NAMED → look up binding in mapping).
2. If the binding is **TAG_TUPLE**: splice its elements in-place.
   - `(true, ...TAG_TUPLE(A, B, C))` → TAG_TUPLE(true_lit, A, B, C)
3. If the binding is **a non-tuple type** (R was bound to a single return):
   - `(true, ...integer)` → TAG_TUPLE(true_lit, integer)
   - Treat the type as a 1-element spread.
4. If the binding is **TAG_NEVER** (F returns nothing): the spread contributes
   zero elements — `(true, ...never)` → TAG_TUPLE(true_lit).

This allows `$PcallReturn<F>` to be written entirely in stdlib.d.lua:
```lua
--:: PcallReturn<F> = match F { () -> %R => (true, ...R) | (false, string) }
```
and the `$PcallReturn` intrinsic in `intrinsic.lua` can be deleted.

## Data Representation

In the parsed type for a tuple like `(true, ...R)`:
- `true` is a TAG_LITERAL(LIT_BOOLEAN, 1) element (normal)
- `...R` is stored as a TAG_SPREAD(TAG_NAMED(R)) element at the end

The TAG_TUPLE in memory stores element type IDs in the list pool. A spread
element is simply a TAG_SPREAD entry in the element list, same as in table
field lists. The position (last) is not enforced structurally — it's a
semantic constraint (only the last element can be a spread).

## Files to Change

### ann.lua — parse `...Name` in tuple position

In `parse_tuple` (or wherever comma-separated tuple elements are parsed):
- After parsing a `,`, if the next token is `...`:
  - Consume `...`
  - Parse the following name as a TAG_NAMED reference
  - Wrap in TAG_SPREAD
  - Append to element list
  - Require `)` next (spread must be last)

### env.lua — splice spreads in `substitute_inner` TAG_TUPLE case

Currently TAG_TUPLE in `substitute_inner` iterates elements and substitutes
each. Add spread handling:

```lua
if tag == TAG_TUPLE then
    local new_elems = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local elem_tid = substitute_inner(ctx, ctx.lists:get(i), mapping, seen, eval_seen)
        local elem_t   = ctx.types:get(types_mod.find(ctx, elem_tid))
        if elem_t.tag == TAG_SPREAD then
            -- Splice inner type's elements
            local inner_tid = types_mod.find(ctx, elem_t.data[0])
            local inner_t   = ctx.types:get(inner_tid)
            if inner_t.tag == TAG_TUPLE then
                for j = inner_t.data[0], inner_t.data[0] + inner_t.data[1] - 1 do
                    new_elems[#new_elems + 1] = ctx.lists:get(j)
                end
            elseif inner_t.tag ~= TAG_NEVER then
                new_elems[#new_elems + 1] = inner_tid  -- single type, treat as 1-elem
            end
            -- TAG_NEVER: contribute zero elements
        else
            new_elems[#new_elems + 1] = elem_tid
        end
    end
    seen[tid] = nil
    return types_mod.make_tuple(ctx, new_elems)
end
```

### stdlib.d.lua — replace $PcallReturn intrinsic declaration

```lua
--:: declare pcall  = <F: function>(f: F, ...any) -> ...(PcallReturn<F>)
--:: declare xpcall = <F: function>(f: F, handler: (string) -> string, ...any) -> ...(PcallReturn<F>)
--:: PcallReturn<F> = match F { () -> %R => (true, ...R) | (false, string) }
```

### intrinsic.lua — delete $PcallReturn expansion

Once the above is in place and tests pass, delete the `PcallReturn` branch
from `resolve_intrinsic` and remove the eager-evaluation path from
`constrain.lua` (`try_eager_intrinsic_return`).

## Tests

Add to `lib/type/static/type_test.lua` under a "spread in tuple position" section:

1. `PcallReturn<() -> integer>` resolves to `(true, integer) | (false, string)` — the spread of a single return
2. `PcallReturn<() -> (integer, string)>` resolves to `(true, integer, string) | (false, string)` — the spread of a multi-return tuple
3. `PcallReturn<() -> ()>` (void) resolves to `(true) | (false, string)` — spread of never = zero elements
4. `local ok, x = pcall(f)` where `f: () -> integer` — `ok: boolean`, `x: integer | nil`
5. `local ok, x, y = pcall(f)` where `f: () -> (integer, string)` — `x: integer | nil`, `y: string | nil`

## Relation to Existing `$PcallReturn` Intrinsic

The existing eager-evaluation path in `constrain.lua` (lines 1392-1439) was
added as an optimization — it lets `if-guard` branches narrow correctly after
pcall. Once the match alias is in place and the solver handles TAG_MATCH_TYPE
lazily, the eager path is dead code. Remove it after the match alias tests pass.

The one remaining difference: the intrinsic currently handles the
`(true, ...R)` form implicitly by constructing the tuple manually in Lua.
The match alias expresses the same thing declaratively. If there are edge
cases where the behaviors differ, write a parity test before deleting the
intrinsic.
