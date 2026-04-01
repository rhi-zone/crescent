# Field Descriptor Design

Field modifiers (readonly, optional, writeonly, etc.) should not be hardcoded keywords in the checker. They should be **user-defined transforms on field descriptors**, defined in the prelude as library types. The checker has general rules for field access based on the descriptor; specific behaviors like "readonly" emerge from how the descriptor is configured.

This spec defines the field descriptor model, attribute mechanism, and composition rules.

## Status: Open Design

Not yet implemented. Current implementation uses packed flag bits (`FLAG_OPTIONAL`, `FLAG_READONLY`, `FLAG_PRIVATE`) with per-keyword syntax (`readonly name: T`, `name?: T`). This spec replaces that with a general mechanism.

## Design Constraints

1. **Attributes, not keywords.** One syntax for attaching arbitrary named metadata to fields. New modifiers require zero parser changes.
2. **User-defined behavior.** `@readonly`, `@optional`, etc. are transforms defined in the prelude, not hardcoded in the checker. The checker never mentions any attribute by name.
3. **Type-level data.** Field descriptors are matchable/transformable by `$EachField` and match types. Mapped types (Partial, Required, Readonly, Pick, Omit) are prelude aliases, not builtins.
4. **No syntax explosion.** Adding a new modifier doesn't grow the grammar.
5. **Prescriptive.** Attributes express intent ("writing is a bug"), not observation ("happens to not be written").
6. **Composable.** `@readonly @optional` works. Order-independent where possible.

## The Descriptor Model

A field descriptor carries everything the checker needs to handle a field access:

```
FieldDescriptor = {
    key:      type,          -- the field name (literal string or integer, or a type variable)
    value:    type,          -- the stored value type
    read:     type,          -- what you get when reading (may differ from value)
    write:    type,          -- what you can assign (may differ from value)
    presence: "required" | "optional",  -- can the field be absent?
}
```

### Default descriptor (no attributes)

```
{ key: K, value: V, read: V, write: V, presence: "required" }
```

Read and write types equal the value type. Field must be present.

### Checker rules (general, attribute-agnostic)

The checker has exactly these rules for field access:

- **Read `t.x`**: result type is `descriptor.read`. If `descriptor.presence == "optional"`, result is `descriptor.read | nil`.
- **Write `t.x = v`**: check `v` against `descriptor.write`. If `descriptor.write` is `never`, emit error.
- **Field presence**: if `descriptor.presence == "optional"`, the key may be absent from the table. `{ [K]: V }` iteration skips absent fields.
- **Subtyping**: a field with `write: never` is a supertype of one with `write: T` (forgetting write capability is safe). A field with `presence: "optional"` is a supertype of `presence: "required"` (forgetting that the field must exist is safe).

No mention of "readonly", "optional", "writeonly" in the checker. Those are library-defined attribute transforms.

## Attributes as Transforms

An attribute `@foo` is a type-level function `FieldDescriptor -> FieldDescriptor` defined in the prelude. When the parser encounters `@foo` on a field, it records the attribute name. During type construction, the attribute transform is applied to the default descriptor.

### Prelude definitions (aspirational)

```lua
--:: @readonly<D> = match D {
--::   { read: %R, write: %W, ...%Rest } => { read: R, write: never, ...Rest }
--:: }

--:: @optional<D> = match D {
--::   { presence: %P, ...%Rest } => { presence: "optional", ...Rest }
--:: }

--:: @writeonly<D> = match D {
--::   { read: %R, write: %W, ...%Rest } => { read: never, write: W, ...Rest }
--:: }

--:: @frozen<D> = match D {
--::   { read: %R, write: %W, value: %V, ...%Rest } =>
--::     { read: DeepReadonly<R>, write: never, value: V, ...Rest }
--:: }
```

### Composition

Multiple attributes compose by chaining transforms:

```lua
--: { @readonly @optional x: integer }
```

Equivalent to: `@optional(@readonly(default_descriptor(x, integer)))`.

**Open question:** is order-independent composition always possible? `@readonly` sets `write: never`, `@optional` sets `presence: "optional"` — these touch different fields, so order doesn't matter. But could two attributes conflict by touching the same field? If so, what's the resolution rule?

## Mapped Types via Descriptors

`$EachField<T, F>` iterates fields of T, passes each field's descriptor to F, and collects the results into a new table. F is a type-level function `FieldDescriptor -> FieldDescriptor`.

### Prelude mapped types (aspirational)

```lua
--:: Partial<T> = $EachField<T, MakeOptional>
--:: MakeOptional<D> = match D {
--::   { presence: %P, ...%Rest } => { presence: "optional", ...Rest }
--:: }

--:: Required<T> = $EachField<T, MakeRequired>
--:: MakeRequired<D> = match D {
--::   { presence: %P, ...%Rest } => { presence: "required", ...Rest }
--:: }

--:: Readonly<T> = $EachField<T, MakeReadonly>
--:: MakeReadonly<D> = match D {
--::   { write: %W, ...%Rest } => { write: never, ...Rest }
--:: }

--:: Mutable<T> = $EachField<T, MakeMutable>
--:: MakeMutable<D> = match D {
--::   { value: %V, write: %W, ...%Rest } => { write: V, ...Rest }
--:: }
```

All standard mapped types become prelude aliases over `$EachField` + match. No new intrinsics.

## Subtyping Rules

Field descriptor subtyping follows from variance:

- `read` is **covariant** (output position): `{ read: Dog }` <: `{ read: Animal }`
- `write` is **contravariant** (input position): `{ write: Animal }` <: `{ write: Dog }`
- `presence: "required"` <: `presence: "optional"` (required is stricter)
- `key` is **invariant** (identity)
- `value` is for reference only (read/write are what the checker uses)

This means:
- A mutable field (`{ read: T, write: T }`) is a subtype of a readonly field (`{ read: T, write: never }`) — you can always forget write capability.
- A required field is a subtype of an optional field — you can always forget that the field must exist.

## Open Questions

### Descriptor shape

Is `{ key, value, read, write, presence }` the right set of fields? Candidates for additional fields:
- `depth: "shallow" | "deep"` — for deep readonly/frozen
- `init: "required" | "optional"` — for constructor-time vs runtime presence (final/const)
- `visibility: type` — if access control returns to the design (currently designed away via `$Opaque`)
- Or: keep the descriptor minimal and let attributes add arbitrary extra fields?

### Attribute arguments

Should attributes carry arguments? `@range(0, 100)`, `@deprecated("use foo")`. If so, the attribute transform becomes a parameterized type-level function. Increases generality but also complexity.

### Arena representation

Current: `FieldEntry { name_id: i32, type_id: i32, flags: u8 }` (12 bytes with padding). New model needs to represent the full descriptor. Options:
- Expand FieldEntry with read_type_id, write_type_id, presence fields
- Store descriptor as a regular TAG_TABLE in the type arena (uniform but heavier)
- Hybrid: fast-path fields (read, write, presence) inline, extras in an attribute list

### Attribute syntax sigil

`@name` is the most common convention (Java, Python, Rust-proc-macros). But:
- `@` might conflict with future syntax
- `#name` is already used for meta-fields in the current syntax
- Other options: `!name`, backtick-name, prefix keyword `attr name`

### $EachField decomposition

With descriptors as the field representation, can `$EachField` be decomposed into smaller primitives?
- `FieldsOf<T>` — extract descriptors as a tuple
- `Map<Tuple, F>` — apply F to each element (general tuple map)
- `TableFrom<Descriptors>` — assemble table from descriptors

If tuple map exists as a general mechanism, `$EachField` = `TableFrom<Map<FieldsOf<T>, F>>`. Three composable primitives instead of one monolithic intrinsic.

### Interaction with match all-fields pattern

The current `{ ...[%K]: %V }` pattern iterates fields and binds K (key type) and V (value type). With descriptors, should it bind the full descriptor instead?

```lua
match T { { ...%D } => D }
```

Where D is a full field descriptor, not just key+value. This would let match inspect read/write/presence/attributes directly. The `{ ...[%K]: %V }` form becomes sugar for destructuring the descriptor's key and value fields.

## Prior Art

- **TypeScript mapped types**: `{ [K in keyof T]: ... }` with `+?`/`-?`/`+readonly`/`-readonly` modifiers. Hardcoded modifier syntax — exactly what this spec avoids.
- **Scala 3 match types + opaque types**: structural matching + nominal wrappers for access control.
- **Haskell lenses**: `view`, `set`, `over` — field access decomposed into getter/setter pairs. The read/write decomposition in this spec is the same idea at the type level.
- **Java/C#/Rust annotations/attributes**: general metadata mechanism. This spec applies the same pattern to type-level field declarations.
- **Row polymorphism** (PureScript, OCaml with row types): fields as first-class type-level data. This spec's descriptors are row-polymorphic field entries.
