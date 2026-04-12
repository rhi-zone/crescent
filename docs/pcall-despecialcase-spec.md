# `pcall`/`xpcall` De-Specialcase Spec

## Current Behavior

`pcall`/`xpcall` are special-cased in constrain.lua (search `fname == "pcall"`). The special case synthesizes `(true, fn_ret...) | (false, string)` by peeking at the callee's return type inline.

## Goal

Express `pcall`'s type in stdlib_types.lua, remove the constrain.lua special case.

## The Type

`pcall(f, ...)` where `f: (A, B) -> (R1, R2)` returns `...((true, R1, R2) | (false, string))`.

The return type depends on `f`'s return type. This requires a type-level intrinsic `$PcallReturn<F>` that takes a function type and produces the wrapped union.

## `$PcallReturn<F>` Intrinsic

`$PcallReturn<F>` evaluates to `(true, ...F_returns) | (false, string)` as a union-of-tuples (for use with `-> ...(...)`).

- If F's return is `TAG_TUPLE (R1, R2, ...)`: produces `((true, R1, R2, ...) | (false, string))`
- If F's return is a TAG_SPREAD (already a union-of-tuples): distributes — each tuple arm `(R1, ...)` becomes `(true, R1, ...)`, plus `(false, string)`
- If F's return is a plain type `R`: produces `((true, R) | (false, string))`
- If F's return is TAG_NEVER: produces `((true) | (false, string))` (no returns on success)
- If F is not a function type (TAG_VAR, TAG_ANY, etc.): return `T_UNKNOWN`

## stdlib_types.lua Declaration

```lua
--:: declare pcall: <F: function>(f: F, ...) -> ...$PcallReturn<F>
--:: declare xpcall: <F: function>(f: F, handler: (string) -> string, ...) -> ...$PcallReturn<F>
```

Note: `-> ...$PcallReturn<F>` — the `...` spread wraps the intrinsic result (which is already a union-of-tuples) as the multi-return type.

## Implementation

### intrinsic.lua — `expand_pcall_return`

```lua
local function expand_pcall_return(ctx, arg_ids)
    local F_tid = types_mod.find(ctx, arg_ids[1])
    local F_t = ctx.types:get(F_tid)
    -- must be a function type
    if F_t.tag ~= TAG_FUNCTION then return ctx.T_UNKNOWN end
    local ret_tid = -- extract F's return type slot
    local ret_t = ctx.types:get(types_mod.find(ctx, ret_tid))
    -- build success tuple: prepend true to return slots
    local success_tuple = -- TAG_TUPLE { T_BOOLEAN_LIT(true), ...ret_slots }
    local fail_tuple = -- TAG_TUPLE { T_BOOLEAN_LIT(false), T_STRING }
    return types_mod.make_union(ctx, { success_tuple, fail_tuple })
end
```

Register as `"PcallReturn"` in the dispatch table.

### solve.lua — resolve `$PcallReturn<F>` after F is bound

`$PcallReturn<F>` must be evaluated after the call to `pcall` has bound `F` to a concrete function type. The `resolve_deferred_intrinsic` mechanism introduced for `$Require<T>` handles this — it's called after arg solving in `solve_callable`.

### Variadic args `...`

The `...` in `pcall(f, ...)` passes remaining args to `f`. In the generic declaration, `...` is the variadic rest. The typechecker currently accepts `...` at call sites as `T_ANY` for each extra arg. For now this is acceptable — a future improvement would propagate the arg types to check they match `F`'s parameter types.

### Removing the constrain.lua special case

After `$PcallReturn<F>` is implemented and the declaration is in stdlib_types.lua, run tests. If all pass, delete the `fname == "pcall"` / `fname == "xpcall"` blocks in constrain.lua.

## Tests

1. `local ok, val = pcall(f)` where `f: () -> string` — `ok: boolean`, `val: string | string` (true-arm string, false-arm string)
2. `local ok, val = pcall(f)` where `f: () -> integer` — after `if ok then` narrows val to `integer`
3. `local ok, err = pcall(f)` where `f: () -> never` — ok: boolean, err: string
4. `pcall` with no annotation on f — ok: boolean, rest: unknown
5. Existing `io.open`-style `if not ok then return end` narrowing pattern still works

## Prerequisite

TAG_SPREAD must be in place (done — 0760d62). `resolve_deferred_intrinsic` must be in place (done — 9d92308).
