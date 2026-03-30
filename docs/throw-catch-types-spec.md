# Type-Level `$Throw` and `$Catch`

## Goal

Enable user-defined type error messages from within match aliases, and provide a
mechanism to suppress them. Mirrors Lua's `error()`/`pcall()` at the type level.

## `$Throw<...Msg>`

A variadic intrinsic that evaluates to `never` and emits a diagnostic at the use site.
Each argument in `Msg` is either a string literal (emitted verbatim) or a type (rendered
to its display form). The checker concatenates them to form the diagnostic text.

```lua
--:: MustBeHomogeneous<T> = match T {
--::   { [%K]: %V } => T,
--::   _ => $Throw<T, " must be a homogeneous indexer table, not a named-field table">
--:: }
```

Note: `AssertExtends<T, U>` does NOT need `$Throw` — use a generic constraint instead:
`--:: AssertExtends<T: U, U>`. Generic constraints are checked by the solver and produce
standard diagnostics. `$Throw` is only for structural checks via `match` where the
default solver message would be too opaque and a custom message adds real clarity.

`$Throw` is a **permanent intrinsic** — it has a diagnostic side effect (emitting a
message at the use site) that cannot be expressed as pure type computation. It joins
`$Require`, `$Opaque`, `$FfiC` as a justified exception to the no-new-`$` rule.

## `$Catch<T, Default?>`

Evaluates `T`. If `T` contains a `$Throw` (at any depth), returns `Default` instead.
If `Default` is omitted, returns `T` with all `$Throw` nodes replaced by `never`
(throws stripped silently).

```lua
--:: MaybeReadonly<T> = $Catch<Readonly<T>, T>
-- If T is a table: Readonly<T> succeeds, result is the transformed type.
-- If T is not a table: Readonly<T> throws, $Catch returns T unchanged.

--:: SafeKeys<T> = $Catch<Keys<T>, never>
-- Keys<T> for a non-table throws; $Catch returns never instead.
```

`$Catch` is also a **permanent intrinsic** — it suppresses diagnostic side effects,
which is a meta-operation on the type checker state.

## When NOT to use `$Throw` — bidirectional inference

**`$Throw` should be used sparingly.** The type solver evaluates aliases multiple times,
tentatively, while exploring constraints — `$Throw` fires as a side effect every time,
producing spurious diagnostics for branches that are ultimately not taken. This violates
the assumption that type computation is pure.

`$Throw` is only appropriate at the **outermost annotation boundary** where evaluation
is definitive and deliberate:

```lua
--: AssertExtends<MyType, SomeInterface>  -- fires once, at this site, on purpose
local x = ...
```

**Do not use `$Throw` inside type transformations** like `Readonly<T>`, `Partial<T>`, etc.
These are called speculatively during inference. For non-applicable inputs, return `never`
or the identity type — let the caller use `$Catch` if they want a message, or just accept
that `Readonly<integer>` = `integer` (passthrough) or `never` (strict).

The correct `Readonly<T>` does not use `$Throw`:

```lua
--:: Readonly<T> = match T {
--::   { ...[%K]: %V } => T,  -- transform the table
--::   T => T                  -- passthrough for non-tables (or: _ => never for strict)
--:: }
```

`$Throw` is for **assertion aliases used at annotation sites** — not for transformation
aliases used internally by other types.

## Scope: authored contracts only

`$Catch` intercepts only explicit `$Throw`s placed by the alias author. Regular type
errors — solver diagnostics like "expected integer, got string" — are NOT `$Throw`s and
are NOT intercepted by `$Catch`. This is intentional:

- `$Throw` marks an **expected failure mode** the author anticipated and documented.
- Solver errors are **genuine bugs** in user code — silently swallowing them via `$Catch`
  would hide real mistakes.

`$Catch<Readonly<T>, T>` only does anything if `Readonly<T>` was authored with a
`$Throw` arm. Without it, `Readonly<integer>` might return `never` silently and `$Catch`
has nothing to intercept. The pair is an opt-in contract, not a general error suppressor.

## The Union Problem — Resolved

Without `$Catch`, `integer | $Throw<"oops">` would require a heuristic: fire the throw
only when "unavoidable". With `$Catch`, the rule is simple:

**`$Throw` always fires unless its result is consumed by `$Catch`.**

`integer | $Throw<"oops">` fires — the author should either remove the throw or wrap:
```lua
$Catch<integer | $Throw<"oops">, integer>  -- suppress, get integer
```

No "only when unavoidable" analysis needed. Suppression is explicit and intentional.

## `$Throw` in unions

When a union arm evaluates to `$Throw`, the throw fires at the use site. There is no
"silent never" — if you want silent, use `never` directly. `$Throw` is always loud.

For match aliases that distribute over union inputs: if ALL arms throw, the throw fires.
If SOME arms throw and others succeed, the throw still fires (the type is partially valid
but the author declared an error). Use `$Catch` to recover from partial throws if needed.

## Relation to `pcall`/`error`

| Runtime     | Type level               |
|-------------|--------------------------|
| `error(msg)`| `$Throw<...Msg>`         |
| `pcall(f)`  | `$Catch<T, Default>`     |
| `string`    | string literal type args |

The parallel is intentional. Lua programmers already understand this model.

## Examples

```lua
--:: MustBeHomogeneous<T> = match T { { [%K]: %V } => T, _ => $Throw<T, " must be a homogeneous table"> }
--:: MaybeReadonly<T>      = $Catch<Readonly<T>, T>   -- only if Readonly uses $Throw
--:: TryKeys<T>            = $Catch<Keys<T>, never>   -- only if Keys uses $Throw
```

## Implementation

- `$Throw<...Msg>` in `intrinsic.lua`: resolve each arg — string literals concatenated
  verbatim, type args rendered via `types_mod.display`. Register a diagnostic at the
  current use-site location. Return `T_NEVER`.
- `$Catch<T, Default?>` in `intrinsic.lua`: evaluate `T` in a "catch mode" where
  `$Throw` invocations are intercepted (no diagnostic emitted, return a sentinel).
  If any `$Throw` was intercepted: return `Default` (or `T_NEVER` if omitted).
  If no `$Throw`: return `T` as normal.
- "Catch mode" is a flag on `ctx` (or a wrapper context) that suppresses diagnostic
  emission from `$Throw` and records whether any throws occurred.
