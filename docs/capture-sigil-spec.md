# Capture Sigil: `%Name` in Match Patterns

## Rule

A name in a match arm **pattern** is a capture (binding) if and only if it is prefixed
with `%`. Everything else is a concrete type reference.

```
capture ::= "%" name
```

At use sites — in result expressions on the right-hand side of `=>` — captures are
referenced by bare name (no `%`):

```lua
--:: ReturnType<F> = match F { () -> %R => R }
--                                    ^^    ^
--                                 capture  use
```

## Motivation

Without an explicit marker, captures are distinguished from concrete type references by
name resolution: unbound names are captures, bound names are concrete. This is fragile:

```lua
--:: R = integer
--:: ReturnType<F> = match F { () -> R => R }  -- R is now concrete! silently broken
```

The `%` sigil makes captures unambiguous regardless of what names happen to be in scope.

## Examples

```lua
--:: ReturnType<F>  = match F { () -> %R => R }
--:: Parameters<F>  = match F { (...%P) -> unknown => P }     -- all params as tuple
--:: Tail<F>        = match F { (integer, ...%P) -> unknown => P }  -- params after first
--:: Last<F>        = match F { (...%P, %L) -> unknown => L }       -- last param type
--:: Init<F>        = match F { (...%P, %L) -> unknown => P }       -- all but last
--:: Keys<T>        = match T { { [%K]: %V } => K, { ...[%K]: %V } => string }
--:: Values<T>      = match T { { [%K]: %V } => V, { ...[%K]: %V } => V }
--:: MetaOf<T>      = match T { { #...%M } => M, _ => nil }

--:: PcallReturn<F> = match F { () -> %R => (true, ...R) | (false, string) }
--:: PairsReturn<T> = match T {
--::   { [%K]: %V }    => (K, V),
--::   { ...[%K]: %V } => (string, V)
--:: }
```

Alias params (`T`, `F`, `A`, `B`, ...) are always concrete — they are declared in the
alias header and substituted before match evaluation. They never need `%`.

## Scope

`%Name` introduces a fresh binding scoped to the arm. The same name may appear as a
capture in multiple arms independently:

```lua
--:: Foo<T> = match T {
--::   { [%K]: %V } => K,   -- %K bound here
--::   { ...[%K]: %V } => K -- %K bound independently here
--:: }
```

## Parsing

In ann.lua, wherever a name is expected in a pattern position, try `%` first:

- `() -> %Name` — return capture in function arm
- `(...%Name) -> T` — rest capture: all params as tuple, must be only param
- `(A, ...%Name, B) -> T` — rest capture with concrete prefix and/or suffix params; at most one `...%Name` per param list. Evaluator matches concrete params from both ends; `...%Name` captures the middle as a tuple.
- `{ [%Name]: %Name }` — key and value captures in indexer arm
- `{ ...[%Name]: %Name }` — key and value captures in all-fields arm
- `{ #...%Name }` — meta-slot capture in meta-spread arm
- `{ field: %Name, ...%Rest }` — named-field captures with rest capture: `...%Rest`
  binds the remaining fields as a table spread; `...Rest` in result position splices
  them back. Useful for pass-through transforms that must survive new fields being
  added to the descriptor. At most one `...%Rest` per table pattern.

At the pattern node level, captures are stored as `TAG_CAPTURE(name_id)` rather than
`TAG_NAMED(name_id)`. The evaluator in match.lua adds `name → resolved_type` to the
binding mapping when it encounters a capture. A `TAG_NAMED` in pattern position is a
concrete type lookup (must resolve or the arm fails).

## Migration

All existing match patterns in stdlib.d.lua use `%`:

| Before             | After              |
|--------------------|--------------------|
| `() -> R`          | `() -> %R`         |
| `{ [K]: V }`       | `{ [%K]: %V }`     |
| `{ ...[K]: V }`    | `{ ...[%K]: %V }`  |
| `{ #...M }`        | `{ #...%M }`       |
| `(...P) -> T`      | `(...%P) -> T`     |

The implicit-unbound-name rule is removed entirely once `%` is implemented. Patterns
without `%` where a capture was expected become a "unknown type reference" error.
