# `$Opaque<T, U>` and `--:: unseal` — Implementer Spec

## Background

`$Opaque<T>` (one-arg) is already implemented in `intrinsic.lua` (`expand_opaque`). It creates a nominal newtype anchored at the declaration site. Identity comes from the declaration site (`stable_id`), not from `T`. `T` is the wrapped shape stored as the inner type.

This spec covers:
1. The two-arg form `$Opaque<T, U>` — nominal newtype with a partial exposed view
2. `--:: unseal <name>` — recovers the full inner type from an opaque handle
3. Field access through the exposed view `U`

## Semantics

### `$Opaque<T>` (existing, recap)
- Creates a nominal type `N` with inner type `T`
- `N` is not assignable to `T` and vice versa (nominal barrier)
- Fields of `T` are not accessible through `N`
- `unseal` is required to recover `T`

### `$Opaque<T, U>` (new)
- Creates a nominal type `N` with inner type `T` and exposed view `U`
- `U` must be a structural subtype of `T` — all fields in `U` must exist in `T` with compatible types. The checker validates this at declaration time.
- External callers holding `N` can access the fields declared in `U` directly (field access on `N` resolves through `U`)
- Fields NOT in `U` are inaccessible without `unseal`
- `N` is still nominally distinct from any other opaque type, even with identical `U`
- `$Opaque<T, U>` is assignable to `$Opaque<T>` (drop exposed view, go fully opaque) — identity preserved
- `U` is NOT a sealed row variable in the implementation (the design doc mentions this but it adds complexity for little benefit in v1). In v1: field access on `N` is resolved by looking up in `U`'s fields first; if found, return that type; if not found, error (not `unknown`).

### `--:: unseal <VarName>`
Syntax: `--:: unseal Foo` where `Foo` is a variable in scope whose type is `$Opaque<T>` or `$Opaque<T, U>`.

Effect: within the scope following the declaration, `Foo` has type `T` instead of `$Opaque<T, ...>`. The typechecker replaces the binding in scope.

Alternative (simpler v1): `unseal` is an intrinsic function `$unseal(x)` that returns the inner type. The caller writes `local inner = --[[: InternalType]] $unseal(handle)`. This avoids scope mutation. Preferred for v1.

## Data Representation

`expand_opaque` in intrinsic.lua currently:
```lua
-- arg_ids[1] = inner type T
-- stable_id  = declaration site anchor (nominal ID)
local result = types_mod.make_nominal(ctx, opaque_name_id, nominal_id, T)
```

For two-arg form:
```lua
-- arg_ids[1] = inner type T
-- arg_ids[2] = exposed view U (optional)
-- stable_id  = declaration site anchor
```

`make_nominal` already stores the inner type. The exposed view `U` needs to be stored alongside — either as a second data slot in the nominal type node, or in a side table on `ctx` keyed by nominal_id.

**Recommended**: side table `ctx._opaque_view[nominal_id] = U_tid`. Clean, no node format change.

## Field Access on Opaque Types

In `solve.lua`, `solve_index` (or the field-access path): when `obj_t.tag == TAG_NOMINAL`:
1. Look up `ctx._opaque_view[obj_t.data[nominal_id_slot]]`
2. If present (two-arg form): resolve the field in `U`; if found return its type; if not found, error "field not exposed by opaque type"
3. If absent (one-arg form): error "cannot access fields of opaque type — use unseal"

## Validation: U must be subtype of T

At declaration time in `expand_opaque`:
```lua
if #arg_ids >= 2 then
    local U_tid = arg_ids[2]
    -- check U <: T: every field in U must exist in T with compatible type
    -- use existing try_unify or a structural subtype check
    -- emit error at declaration site if check fails
    ctx._opaque_view[nominal_id] = U_tid
end
```

## Assignability

`$Opaque<T, U>` assignable to `$Opaque<T>`: in `unify.lua`, when checking `TAG_NOMINAL <: TAG_NOMINAL`:
- Currently: same nominal_id required (exact match)
- New: if expected is one-arg opaque and actual is two-arg opaque with same nominal_id, accept (drop the view)

Two `$Opaque<T, U>` with different declaration sites: NOT assignable even if T and U are identical. Nominal identity is declaration site only.

## Tests to Write

1. Field in `U` is accessible on `$Opaque<T, U>` handle
2. Field NOT in `U` is inaccessible (error)
3. `$Opaque<T, U>` assignable to `$Opaque<T>` (drop view)
4. Two `$Opaque<HttpServer, {start:()->()}>` at different sites are distinct — not mutually assignable
5. Declaring `$Opaque<T, U>` where U has a field not in T is a declaration-time error
6. One-arg `$Opaque<T>`: field access is an error "use unseal"

## Files to Touch

- `lib/type/static/intrinsic.lua` — `expand_opaque`: two-arg handling, `ctx._opaque_view`
- `lib/type/static/solve.lua` — field access path for TAG_NOMINAL
- `lib/type/static/unify.lua` — assignability: two-arg opaque to one-arg opaque
- `lib/type/static/type_test.lua` — tests

`--:: unseal` / `$unseal()` is deferred to a follow-up spec. V1 ships `$Opaque<T, U>` for partial exposure; unseal is added when a consumer needs it.
