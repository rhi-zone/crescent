# `--:: unseal` — Implementer Spec

## Background

`$Opaque<T>` and `$Opaque<T, U>` are now implemented. Callers holding an opaque handle can access fields declared in `U` (two-arg form) but cannot access the full inner type `T`. `--:: unseal` is the explicit opt-in to recover `T`.

## Design

`--:: unseal Foo` is a `--::` declaration (same syntax family as `--:: x: T`, `--:: module "m": T`, etc.) that rebinds the variable `Foo` to its inner type in the scope following the declaration. The typechecker resolves `Foo`'s opaque nominal, extracts the inner `T`, and shadows the binding.

```lua
local server --: $Opaque<InternalServer, { start: () -> () }>

server.start()       -- OK (exposed in U)
server.hidden_field  -- ERROR: not exposed by opaque type

--:: unseal server
server.hidden_field  -- OK: server now has type InternalServer
```

This is the crescent equivalent of Rust's `unsafe {}` — explicitly visible in code review, impossible to do accidentally.

## Why Not an Expression Intrinsic

`$` prefix is for type-level intrinsics in annotation position (`$Keys<T>`, `$EachField<T,F>`, etc.). Using `$unseal(x)` in expression position would mix the two namespaces. The `--::` form is correct: it's a type-level annotation that affects the scope, not a runtime operation.

## Grammar

```
--:: unseal <identifier>
```

Parsed by `constrain.lua`'s `--::` annotation handler. The identifier must resolve to a variable in the current scope whose type is a `TAG_NOMINAL` with `ctx._opaque_nominals[nominal_id]` set.

## Implementation

### ann.lua — parse `unseal` keyword

In the `--::` annotation parser, add a branch for the keyword `unseal`:
```
if word == "unseal" then
    local name = scan_word(s)
    emit ANN_UNSEAL { name = name }
end
```

### constrain.lua — handle ANN_UNSEAL

In the annotation handler for `--::` declarations, handle `ANN_UNSEAL`:
1. Look up `name` in current scope → `var_tid`
2. Find the type: `obj_t = ctx.types:get(find(ctx, var_tid))`
3. Validate: `obj_t.tag == TAG_NOMINAL` and `ctx._opaque_nominals[nominal_id]` — error if not
4. Extract inner type from nominal (the `T` stored at creation in `expand_opaque`)
5. Rebind `name` in the current scope to the inner type: `env.set(ctx.scope, name_id, inner_tid)`

### Scoping

`--:: unseal` affects the scope from the declaration point forward (like a variable reassignment). If inside a block, the unseal does not propagate outside. This is consistent with how `--::` type annotations on locals work.

## Tests

1. After `--:: unseal server`, field access on hidden fields works
2. Before `--:: unseal server`, hidden field access errors
3. `--:: unseal x` on a non-opaque variable is an error
4. `--:: unseal x` on a `newtype` nominal is an error (newtype ≠ opaque)
5. Unseal inside a block does not affect outer scope (if block scoping is enforced)
6. Two-arg opaque: unseal reveals full `T`, not just the exposed `U`

## Files to Touch

- `lib/type/static/ann.lua` — parse `--:: unseal Name`
- `lib/type/static/constrain.lua` — handle ANN_UNSEAL, scope rebinding
- `lib/type/static/type_test.lua` — tests
