# `$Require<T>` Parameterized Intrinsic — Implementer Spec

## Current State

`require()` is special-cased in `constrain.lua`: when the argument is a string literal, it looks up `ctx.module_types[literal_value]` inline. This is a hardcoded special case that violates the principle "builtins must not be special-cased."

The goal: declare `require` in `stdlib.d.lua` as a generic function using `$Require<T>`, remove the constrain.lua special case.

## Target stdlib.d.lua Declaration

```lua
--:: declare require: <T: string>(module: T) -> $Require<T>
```

This requires three things to work:
1. `<T: string>` — constrained generic (DONE, commit 50706d2)
2. `$Require<T>` where T is a type variable — parameterized intrinsic evaluation
3. Argument literal NOT widened at intrinsic call sites (so T can resolve to LIT_STRING)

## What `$Require<T>` Evaluates To

- If T resolves to `LIT_STRING(s)`: look up `ctx.module_types[s]`; if found return declared type; if not found return `T_UNKNOWN` (missing module is already an error via other checks, not here)
- If T resolves to `string` (widened or non-literal): return `T_UNKNOWN`
- If T is still a free TAG_VAR (unresolved): defer (return a fresh TAG_VAR bound to eventual resolution)

## Where Parameterized Intrinsic Resolution Happens

Currently `resolve_named_type` in `env.lua` (or `intrinsic.lua`) handles `TAG_INTRINSIC` nodes. It only handles `TAG_NAMED` callees — concrete intrinsic names like `$Keys`. It does NOT handle `TAG_TYPE_CALL(TAG_INTRINSIC, type_var)`.

**Change needed in `solve.lua` or `intrinsic.lua`**: when evaluating a `TAG_TYPE_CALL` whose callee is `TAG_INTRINSIC "$Require"` and whose argument is a solved type variable, call `expand_require(ctx, resolved_arg_tid)`.

### Implementation Location

In `intrinsic.lua`, add:

```lua
-- $Require<T>
local function expand_require(ctx, arg_ids)
    local T_tid = types_mod.find(ctx, arg_ids[1])
    local T_t = ctx.types:get(T_tid)
    if T_t.tag == TAG_LITERAL and T_t.data[0] == LIT_STRING then
        local module_name = intern_mod.get(ctx.pool, T_t.data[1])
        local declared = ctx.module_types and ctx.module_types[module_name]
        if declared then return declared end
    end
    return ctx.T_UNKNOWN
end
```

Register in the dispatch table alongside `$Keys`, `$EachField`, etc.

### TAG_TYPE_CALL on Type Variables

The harder part: `resolve_named_type` currently only resolves `TAG_NAMED` (string name). When it encounters `TAG_TYPE_CALL(callee, arg)` where callee is a TAG_INTRINSIC, it must:

1. Resolve the callee to the intrinsic function
2. Pass the (possibly still-bound-TV) arg to the intrinsic
3. If the arg is a free TV: defer (return a fresh TV that will be resolved when arg is solved)
4. If the arg is solved: call `expand_require` immediately

This is the general "parameterized intrinsic" machinery. `$Require<T>` is the first use case; the same machinery will be needed for other parameterized intrinsics later.

**In `solve.lua`**: when solving `TAG_TYPE_CALL` nodes (already handled for user generics via `instantiate`), add a branch: if callee resolves to `TAG_INTRINSIC`, call `expand_intrinsic(ctx, intrinsic_name, [arg_tid])` rather than `instantiate`.

## Argument Literal NOT Widened

See `docs/argument-literal-widening-spec.md`. The cleanest approach for `$Require<T>`:

The intrinsic resolution happens AFTER solving (in the solve phase, not the constraint-gen phase). By solve time, the typevar `T` has been bound to whatever the argument's type is. If argument literal widening was applied at constraint-gen time (when `T` was bound), then T = `string` at solve time and `$Require<string>` = `T_UNKNOWN`.

**Chosen approach**: do NOT apply argument literal widening to intrinsic-return-typed calls. Detect at constraint-gen time: if the callee's return type (after instantiation) contains a `TAG_TYPE_CALL` on a `TAG_INTRINSIC`, skip widening for that call's arguments. This is a small, bounded special case.

Alternative (simpler): since `require()` is currently the only case, keep the constrain.lua special case for `require()` specifically and only add `$Require<T>` as a type-annotation-level alias (for use in annotations, not to replace the special case). Lower priority.

## Removal of constrain.lua Special Case

Only after:
1. Parameterized intrinsic evaluation is implemented and tested
2. Argument literal widening exemption for intrinsic calls is implemented
3. `--:: declare require: <T: string>(module: T) -> $Require<T>` in stdlib.d.lua passes and produces correct types

Then: delete the `if fname == "require" then ... end` block in constrain.lua.

## Tests to Write

1. `require("lib.json")` returns the declared module type when `--:: module "lib.json": { decode: ... }` exists
2. `require("unknown")` returns `unknown` (no declaration)
3. `local mod = require("lib.json"); mod.decode(...)` typechecks correctly (cross-module type)
4. `local path = "lib.json"; require(path)` — `path` is `string` (widened), returns `unknown` (correct)
5. The above four must pass identically whether using the special case OR the `$Require<T>` path

## Files to Touch

- `lib/type/static/intrinsic.lua` — `expand_require`, dispatch registration
- `lib/type/static/solve.lua` — TAG_TYPE_CALL on TAG_INTRINSIC callee
- `lib/type/static/constrain.lua` — argument widening exemption; eventually remove require special case
- `lib/type/static/stdlib.d.lua` — milestone declaration
- `lib/type/static/type_test.lua` — tests
