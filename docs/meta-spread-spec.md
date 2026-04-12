# Meta Slot Spread: `{ #...T }` and `{ #...M }` Pattern

## Goal

Enable precise typing of `setmetatable` and `getmetatable` by expressing
"this type carries the meta slots of T" without enumerating them.

## Syntax

In a table type, `#name: type` declares an individual meta slot (already implemented).
`{ #...T }` spreads **all meta slots** from type T into the table:

```lua
--:: Vec2 = { x: number, y: number, #...number_meta }
```

This is the meta-slot analogue of `{ ...T }` for regular fields.

## `setmetatable`

Currently:
```lua
--:: declare setmetatable = <T, U>(t: T, mt: { __index: U, ... }) -> T & U
```

This only handles `__index` and is wrong for the general case. With `{ #...MT }`:

```lua
--:: declare setmetatable = <T, MT>(t: T, mt: MT) -> T & { #...MT }
```

The result carries the regular fields of T plus all meta slots from MT.
`__index` forwarding is a consequence of solving field access against the intersection
(T's regular fields first, then meta slots provide `__index` for unknown fields).

## `getmetatable`

`getmetatable(t)` returns the metatable — ideally typed as "the thing that was passed
to setmetatable". With a match pattern `{ #...M }` that extracts the meta source:

```lua
--:: MetaOf<T> = match T { { #...%M } => M, _ => nil }
--:: declare getmetatable = <T>(t: T) -> MetaOf<T>
```

`{ #...%M }` in a match arm binds M to the table type reconstructed from T's meta slots
(the inverse of spreading). If T has no meta slots, the arm fails and the fallback `nil` applies — matching
Lua's runtime behaviour where tables without metatables return nil.

### Limitation: roundtrip fidelity

`setmetatable(t, mt)` returns `T & { #...MT }`. Calling `getmetatable` on that result
extracts M bound to "the meta slots of T & { #...MT }", which reconstructs MT's shape
but not its identity. This is fine for practical use (you get the right field types)
but M is a structural reconstruction, not MT itself.

## Match pattern `{ #...M }`

The meta-slot analogue of `{ ...[K]: V }` (all-fields) and `{ [K]: V }` (indexer).

| Pattern          | Extracts              | Binds       |
|------------------|-----------------------|-------------|
| `{ [%K]: %V }`   | Indexer               | K, V        |
| `{ ...[%K]: %V }`| All fields            | K, V        |
| `{ #...%M }`     | All meta slots        | M (as table type) |

`{ #...%M }` succeeds if T has any meta slots; fails if T has none (allowing a fallback arm).

## Arithmetic types

The primary use case for `{ #...T }` in user code is arithmetic value types:

```lua
--:: Vec2 = { x: number, y: number, #...number_meta }
```

This lets `+`, `-`, `*` etc. typecheck on Vec2 values without writing out each
metamethod. `number_meta` is already declared in stdlib_types.lua.

## Implementation notes

- `{ #...T }` in ann.lua: parsed as a spread entry in the meta slot list of the table,
  stored as TAG_SPREAD in the meta list (parallel to how `{ ...T }` works for fields).
- `{ #...%M }` match pattern: new `PAT_META_SPREAD` kind in match.lua; binds M to
  `make_table(ctx, {}, {}, meta_field_list)` — a table type reconstructed from
  the input's meta slots.
- `setmetatable` return type: `T & { #...MT }` — intersection where one member is a
  meta-only table. Field access on the intersection resolves regular fields from T,
  meta slots from `{ #...MT }`.
- `getmetatable` result: `MetaOf<T>` — a match alias using `{ #...M }`.

## Relation to `__index` forwarding

`__index` as a meta slot participates in field access resolution. When `solve_index`
misses on a table's regular fields, it should check `#__index` in the meta slots and
follow the chain. This is currently handled specially for the `setmetatable` return type
(`T & U` where U came from `__index`). With `{ #...MT }`, `#__index` is just another
meta slot — field access resolution becomes uniform: miss on fields → check `#__index`
meta slot → recurse.
