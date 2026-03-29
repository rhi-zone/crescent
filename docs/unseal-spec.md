# `--:: unseal` — Implementer Spec

## Background

`$Opaque<T>` and `$Opaque<T, U>` are now implemented. Callers holding an opaque handle can access fields declared in `U` (two-arg form) but cannot access the full inner type `T`. `--:: unseal` is the explicit opt-in to recover `T`.

## Design (from docs/access-control.md)

`--:: unseal Foo` in a scope means: within this scope, `Foo` has type `T` instead of `$Opaque<T, ...>`. This is the crescent equivalent of Rust's `unsafe {}` — it screams "something deliberate is happening here" and is impossible to do accidentally.

## V1 Implementation: `$unseal(x)` intrinsic function

Rather than a scope-mutation declaration, v1 uses an intrinsic expression:

```lua
local inner = $unseal(handle)
--: InternalType
```

Or with inline annotation:
```lua
local inner = --[[: InternalType]] $unseal(handle)
```

`$unseal(x)` is an intrinsic that takes an opaque handle and returns its inner type `T`. The typechecker evaluates `$unseal(x)` by:
1. Resolving `x`'s type to `TAG_NOMINAL`
2. Checking `ctx._opaque_nominals[nominal_id]` — must be an opaque nominal (error if not)
3. Returning the inner type stored in the nominal node

This is safe because: the caller explicitly writes `$unseal`, making intentional access visible in code review. No accidental unsealing.

## Annotation-level unseal: `--:: unseal Name`

For use in type annotations (not expression code), allow:
```lua
--:: unseal HttpServer
```

Effect: within the `--::` annotation scope following this declaration, `HttpServer` refers to the inner structural type, not the opaque wrapper. Used when writing type aliases that need to inspect opaque internals.

This is lower priority than the expression-level `$unseal()`. Implement expression-level first.

## Implementation

### intrinsic.lua — `$unseal` as a type-level intrinsic

`$unseal` is unusual — it's used as an expression intrinsic, not a type-level one. It needs special handling in constrain.lua/solve.lua.

In constrain.lua, when `ExprRule[NODE_CALL_EXPR]` encounters a callee named `$unseal`:
1. Get the argument type `arg_tid`
2. Find it: `obj_t = ctx.types:get(find(ctx, arg_tid))`
3. If `obj_t.tag != TAG_NOMINAL` or `ctx._opaque_nominals[nominal_id]` is nil: error "argument to $unseal must be an opaque type"
4. Return the inner type stored in the nominal: `obj_t.data[inner_type_slot]`

The return type is known at constraint-gen time (no deferred solving needed) because opaque types store their inner type at creation.

### Result: inner type is usable directly

```lua
local server --: $Opaque<InternalServer, { start: () -> () }>
local internal = $unseal(server)  -- type: InternalServer
internal.hidden_field  -- OK
```

## Tests

1. `$unseal` on a one-arg opaque returns the inner type; field access works
2. `$unseal` on a two-arg opaque returns the inner type (same as one-arg)
3. `$unseal` on a non-opaque type (plain table) is an error
4. `$unseal` on a newtype nominal is an error (newtype ≠ opaque)
5. The inner type returned by `$unseal` is the full structural type, not the exposed view

## Files to Touch

- `lib/type/static/constrain.lua` — ExprRule for `$unseal` call
- `lib/type/static/type_test.lua` — tests
- `lib/type/static/intrinsic.lua` — register `$unseal` name (even if implementation is in constrain.lua)
