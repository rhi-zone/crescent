# Argument Literal Widening

## Problem

Literal values passed to generic functions pin the typevar to the literal type, breaking subsequent calls:

```lua
--:: <T> id: (x: T) -> T
id(0)      -- binds T = LIT_INTEGER(0)
id(1)      -- ERROR: LIT_INTEGER(1) not assignable to LIT_INTEGER(0) -- WRONG
```

Root cause: `constrain.lua` binds the typevar at the call site using the argument's inferred type, which for a literal `0` is `LIT_INTEGER(0)`. Each call to the same generic function creates fresh typevars (they don't share), but the problem manifests when a function is called multiple times in the same file — or more precisely when the typechecker enforces a constraint that was accumulated from a first call against a second call. Actually the bug is slightly different: it's that `0` as a literal in argument position should widen before being used to instantiate a typevar.

## Correct Rule

**Argument position is not a narrowing position.** In narrowing contexts (if-guards, pattern matches, explicit annotations), literals stay literal — that's the point. In argument position, a literal is just a value being passed; the caller doesn't intend to constrain the function's typevar to that specific literal forever.

Widening rules at argument position:
- `LIT_INTEGER(n)` → `integer`
- `LIT_NUMBER(f)` → `number`
- `LIT_STRING(s)` → `string`
- `LIT_BOOLEAN(b)` → `boolean`
- `LIT_OPAQUE_KEY` → unchanged (not a user literal)

This applies only when binding a typevar (TAG_VAR). It does NOT apply to:
- Checking a concrete annotated parameter type (e.g. `(x: 0) -> nil` — passing `1` is an error)
- Narrowing contexts

## Implementation Location

In `constrain.lua`, when a call argument is being unified with a fresh typevar (`C_CALLABLE` emission or direct `bind_to`):

```lua
-- Before binding arg_tid to a fresh typevar:
local arg_t = ctx.types:get(types_mod.find(ctx, arg_tid))
if arg_t.tag == TAG_LITERAL then
    arg_tid = widen_literal(ctx, arg_tid)  -- widen before binding
end
```

`widen_deep` already exists for generic constraint checks. A simpler `widen_literal` that handles only top-level literals (not deep table fields) is sufficient here.

## Interaction with Intrinsics

`$Require<T>` needs `T` to remain a string literal so the module lookup works. This creates a tension:

**Resolution**: widening happens at typevar-binding time for user-defined generics. Intrinsics are not resolved at typevar-binding time — they are resolved separately by the intrinsic evaluation path in `resolve_named_type` / `intrinsic.lua`, which inspects the bound TV's actual tag AFTER solving. So by the time `$Require<T>` evaluates, `T` has been solved; if the caller passed a string literal and widening was applied, `T` = `string`, and `$Require<string>` returns `unknown` (correct — we don't know which module).

For `$Require<T>` to see the literal, widening must NOT be applied at the `require()` call site. Since `require()` is currently special-cased in constrain.lua (not going through the generic typevar path), this is automatically handled — the special case reads the literal argument directly. When `require()` is de-specialcased to use `$Require<T>`, the intrinsic evaluation path inspects the bound TV after solving, and that TV will have been widened. This means `require("lib.json")` with widening gives `T = string` → `$Require<string>` = `unknown` — WRONG.

**True resolution**: `$Require<T>` is an intrinsic that needs literal propagation. When de-specialcasing `require()`, the intrinsic must bypass argument widening. This is implemented as: in `solve_callable` / `constrain.lua`, when the callee resolves to a function whose return type contains a TAG_INTRINSIC depending on a typevar, do NOT widen that typevar's argument. Alternatively: `$Require<T>` checks the original (un-widened) call argument directly, bypassing the generic typevar mechanism entirely.

The simplest implementation: implement argument literal widening for all generics EXCEPT calls where the return type is (or contains) a parameterized intrinsic. This is an acceptable special case because the number of parameterized intrinsics is small and fixed.

## Tests

1. `id(0); id(1)` both pass where `id: <T>(T) -> T`
2. `id(0); id("x")` passes — different calls, different types, both valid
3. `f --: (x: 0) -> nil; f(1)` — error (concrete annotation, not typevar)
4. `require("lib.json")` still returns declared module type, not `unknown`
