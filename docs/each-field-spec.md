# `$EachField<T, F>` — Per-Field FlatMap

## Purpose

`$EachField` is the general primitive for table type transformations: for each field in
T, apply F to get zero or more output fields, collect all into one new table.

Map, filter, and key-remap are all special cases:
- **F returns `{ D }`** — one field out (map / transform)
- **F returns `{}`** — zero fields out (filter / drop)
- **F returns `{ D1, D2 }`** — two fields out (expand)

Tuple syntax uses braces: `{ A, B }` is a 2-tuple, `{ D }` is a 1-tuple, `{}` is an
empty tuple. Parens are multi-return in function return position only.

## F: a single-parameter named alias

F is a **named alias with one parameter**, passed unapplied to `$EachField` (same
syntactic position as an HKT argument). No inline match expressions.

F receives a **field descriptor**:

```
{ key: string, value: unknown, optional: boolean, readonly: boolean }
```

and returns a **tuple of field descriptors** — `{}`, `{ D }`, `{ D1, D2, ... }`.

## Examples

### Flag transforms (map)

```lua
--:: MakeOptional<D> = match D { { optional: _, ...%Rest } => { { optional: true,  ...Rest } } }
--:: MakeRequired<D> = match D { { optional: _, ...%Rest } => { { optional: false, ...Rest } } }
--:: MakeReadonly<D> = match D { { readonly: _, ...%Rest } => { { readonly: true,  ...Rest } } }
--:: MakeWritable<D> = match D { { readonly: _, ...%Rest } => { { readonly: false, ...Rest } } }

--:: Partial<T>  = $EachField<T, MakeOptional>
--:: Required<T> = $EachField<T, MakeRequired>
--:: Readonly<T> = $EachField<T, MakeReadonly>
--:: Writable<T> = $EachField<T, MakeWritable>
```

`{ optional: _, ...%Rest }` captures everything except the field being changed into
`Rest`; `{ optional: true, ...Rest }` reconstructs the descriptor with the override.
`...%Rest` does not contain `optional`, so there is no conflict. The outer `{ ... }`
is the return tuple (one element); the inner `{ optional: true, ...Rest }` is the
descriptor.

### Filter (drop fields)

```lua
--:: DropOptional<D> = match D { { optional: true, ... } => {}, _ => { D } }
--:: NonOptional<T>  = $EachField<T, DropOptional>
```

`{ optional: true, ... }` is an open structural pattern — matches any descriptor with
`optional = true`, ignoring other fields. `{}` drops the field. `{ D }` keeps the
descriptor unchanged (D is the alias parameter, already the full descriptor).

### Key remap (rename fields)

```lua
-- requires type-level .., see docs/literal-type-ops-spec.md
--:: ToGetter<D> = match D { { key: %K, value: %V, ...%Rest } => { { key: "get_" .. K, value: () -> V, ...Rest } } }
--:: Getters<T>  = $EachField<T, ToGetter>
```

### Expand (one field → many)

No concrete examples yet — all natural expand cases require type-level string
concatenation (`"get_" .. K`), not yet implemented. The `{ D1, D2 }` return shape
is theoretically supported but has no working stdlib examples until then.

## Open question: parameterized F

`Pick<T, Keys>` needs F to close over a `Keys` parameter:

```lua
--:: PickKey<Keys><D> = match D { { key: %K, ...%Rest } => K extends Keys => { Rest }, _ => {} }
--:: Pick<T, Keys>    = $EachField<T, PickKey<Keys>>
```

Requires partial application of generic aliases — not yet designed.

## Implementation

`$EachField<T, F>` in `intrinsic.lua`:

1. Enumerate fields of T (named fields + indexers) as descriptors.
2. For each descriptor, instantiate F with D = descriptor type → evaluate → get a tuple.
3. Collect all descriptor types from all tuple elements (flattening).
4. Construct and return a new table type from collected descriptors.

`$EachField` is a **permanent intrinsic** — per-field gather with flag read/write and
tuple-return semantics cannot be expressed as pure match computation.

## Descriptor field types

| Field      | Type    | Meaning                          |
|------------|---------|----------------------------------|
| `key`      | string  | field name (string literal)      |
| `value`    | unknown | field value type                 |
| `optional` | boolean | FLAG_OPTIONAL (true = optional)  |
| `readonly` | boolean | FLAG_READONLY (true = readonly)  |

Indexer fields: `key` = indexer key type (e.g. `integer`), not a string literal.

## Relation to `{ ...[%K]: %V }`

`{ ...[%K]: %V }` distributes per-field and unions results — right for reading fields
(PairsReturn, Keys, Values). `$EachField` gathers per-field results into one new table
— right for writing/transforming fields. They are complementary, not redundant:

- `match T { { ...[%K]: %V } => K }` — union of all key types (result is a union type)
- `$EachField<T, MakeOptional>` — new table with all fields made optional (result is a table type)

`{ [%K]: %V }` (without `...`) matches ONE structural element — the table's indexer. It does NOT
distribute. `{ ...[%K]: %V }` is the iteration form.
