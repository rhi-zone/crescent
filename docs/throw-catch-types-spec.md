# Type-Level `$Throw` and `$Catch`

## Goal

Enable user-defined type error messages from within match aliases, and provide a
mechanism to suppress them. Mirrors Lua's `error()`/`pcall()` at the type level.

## `$Throw<...Msg>`

A variadic intrinsic that evaluates to `never` and emits a diagnostic at the use site.
Each argument in `Msg` is either a string literal (emitted verbatim) or a type (rendered
to its display form). The checker concatenates them to form the diagnostic text.

```lua
--:: AssertExtends<T, U> = match T {
--::   U => T,
--::   _ => $Throw<T, " is not assignable to ", U>
--:: }

--:: Readonly<T> = match T {
--::   { ...[%K]: %V } => T,  -- (requires all-fields pattern)
--::   _ => $Throw<"Readonly<", T, "> requires a table type">
--:: }
```

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
--:: NonNullable<T>  = match T { nil => $Throw<"NonNullable: got nil">, T => T }
--:: Exact<T, U>     = match T { U => match U { T => T, _ => $Throw<T, " ≠ ", U> }, _ => $Throw<T, " is not ", U> }
--:: MaybeReadonly<T> = $Catch<Readonly<T>, T>
--:: TryKeys<T>       = $Catch<Keys<T>, never>
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
