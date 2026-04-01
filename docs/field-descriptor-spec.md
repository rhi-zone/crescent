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

**Read and write types are NOT separate.** Allowing different read/write types (like TypeScript's DOM typings where a getter returns `CSSStyleDeclaration` but the setter accepts `string`) is widely considered bad design. A field has ONE value type. Readonly/writeonly are permission flags, not different types.

A field descriptor is:

```
FieldDescriptor = {
    key:      type,     -- the field name (literal string/integer, or type variable)
    value:    type,     -- the field's value type
    flags:    bitfield, -- readable | writable | optional (3 bits)
}
```

### Flags

Three orthogonal permission bits:

| Flag | Bit | Meaning |
|------|-----|---------|
| `readable` | 0x01 | Field can be read |
| `writable` | 0x02 | Field can be written |
| `optional` | 0x04 | Field can be absent |

Common combinations:
- Normal field: `readable | writable` (0x03) — default
- Readonly field: `readable` (0x01)
- Writeonly field: `writable` (0x02) — rare but symmetric
- Optional field: `readable | writable | optional` (0x07)
- Readonly optional: `readable | optional` (0x05)

This is close to the current implementation (`FLAG_OPTIONAL=0x01, FLAG_READONLY=0x02, FLAG_PRIVATE=0x04`) — the semantic change is that attributes are user-defined transforms on these flags, not hardcoded checker keywords. The representation barely changes.

### Checker rules (general, attribute-agnostic)

The checker has exactly these rules for field access:

- **Read `t.x`**: check `readable` flag. If not readable, emit error. Result type is `descriptor.value`. If `optional` flag set, result is `value | nil`.
- **Write `t.x = v`**: check `writable` flag. If not writable, emit error. Check `v` against `descriptor.value`.
- **Field presence**: if `optional` flag set, the key may be absent from the table.
- **Subtyping**: `readable | writable` <: `readable` (can forget write permission). `required` <: `optional` (can forget presence guarantee).

No mention of "readonly", "optional", "writeonly" by name in the checker. Those are library-defined attribute transforms on the flags.

## Attributes as Transforms

An attribute `@foo` is a type-level function `FieldDescriptor -> FieldDescriptor` defined in the prelude. When the parser encounters `@foo` on a field, it records the attribute name. During type construction, the attribute transform is applied to the default descriptor.

### Prelude definitions (aspirational)

Attribute transforms clear or set flag bits on the descriptor. The exact syntax for flag manipulation in match types is TBD — shown here as pseudocode:

```
@readonly  : clear writable flag
@writeonly : clear readable flag
@optional  : set optional flag
@required  : clear optional flag
@frozen    : clear writable flag + recursively apply to value type
```

The mechanism: attributes are named transforms the checker looks up in the prelude when constructing field descriptors. Each transform receives the current flags and value type, returns modified flags and value type. How this is expressed in match syntax depends on how flags are exposed as type-level data (see open questions).

### Composition

Multiple attributes compose by chaining transforms:

```lua
--: { @readonly @optional x: integer }
```

Equivalent to: `@optional(@readonly(default_descriptor(x, integer)))`.

**Open question:** is order-independent composition always possible? With bitfield flags, `@readonly` clears `writable` and `@optional` sets `optional` — they touch different bits, so order doesn't matter. But could two attributes conflict by touching the same bit? If so: last-wins, or error?

## Mapped Types via Descriptors

`$EachField<T, F>` iterates fields of T, passes each field's descriptor to F, and collects the results into a new table. F is a type-level function `FieldDescriptor -> FieldDescriptor`.

### Prelude mapped types (aspirational)

```
Partial<T>   = $EachField<T, set_optional>       -- set optional flag
Required<T>  = $EachField<T, clear_optional>     -- clear optional flag
Readonly<T>  = $EachField<T, clear_writable>     -- clear writable flag
Mutable<T>   = $EachField<T, set_writable>       -- set writable flag
Frozen<T>    = $EachField<T, deep_clear_writable> -- recursive
```

All standard mapped types become prelude aliases over `$EachField` + flag transforms. The exact mechanism for expressing flag transforms in match syntax depends on how flags are exposed as type-level data (see open questions).

**`$EachField` stays atomic.** Decomposing into `FieldsOf` + `Map` + `TableFrom` introduces three primitives that are only useful composed together. One primitive is simpler than three that only compose one way.

## Subtyping Rules

Field descriptor subtyping follows from flag permissions:

- `value` is **covariant** when readable, **contravariant** when writable, **invariant** when both (the standard rule for mutable references).
- `readable | writable` <: `readable` — can forget write permission (mutable <: readonly).
- `required` <: `optional` — can forget presence guarantee.
- `key` is **invariant** (identity).

## Open Questions

### Resolved: Descriptor shape

`{ key, value, flags }` — three fields. `value` is the one type; `flags` is a 3-bit field (readable, writable, optional). No separate read/write types — differing read/write types (as in TypeScript DOM typings) are bad design. Readonly/writeonly are permission bits, not type-level.

`depth` (shallow vs deep) is a recursive transform (`Frozen<T>` = apply `@readonly` recursively), not a per-field flag. `init` (final/const) is a lifecycle constraint requiring the checker to distinguish construction scope from usage scope — separate mechanism, not a flag.

### Resolved: Attribute arguments

Attribute arguments are type parameters on the transform: `@deprecated("use foo")` is `Deprecated<D, "use foo">`. The general mechanism (match types with parameters) already handles this.

### Resolved: Sigil

`@name`. Universal convention, unused in the current annotation parser, zero ambiguity.

### Resolved: $EachField stays atomic

Decomposing into `FieldsOf` + `Map` + `TableFrom` introduces three primitives only useful composed together. One atomic `$EachField` is simpler.

### Open: Arena representation

Current: `FieldEntry { name_id: i32, type_id: i32, flags: u8 }` (12 bytes). The 3-bit flags model fits in the existing `flags` byte — the change is semantic (attributes as user-defined transforms), not structural. The FieldEntry representation may not need to change at all.

If attributes beyond the core three are needed: an auxiliary attribute list per field, keyed by attribute name. But the core case (the vast majority of fields: readable + writable + required, no extra attributes) stays at 12 bytes.

### Open: How flags are exposed to match / $EachField transforms

The core design question. Attributes are transforms on flags, but how does a match type express "clear the writable bit"? Options:

1. **Flags as literal integers** — match on bit patterns. `flags & 0x02 == 0` means not writable. Powerful but unreadable.
2. **Flags as named booleans in the descriptor** — `{ readable: true, writable: true, optional: false }`. Match destructures them: `match D { { writable: true, ...%Rest } => { writable: false, ...Rest } }`. Clean but requires the descriptor to be a matchable table.
3. **Flags as a type-level enum/set** — `flags: { readable, writable }` as a set of capabilities. Adding/removing from the set. Needs set operations at the type level.
4. **Attributes as opaque transforms** — the checker applies attributes by name lookup, not by exposing flags to match. `$EachField` passes the flag state to F as opaque data; F returns instructions ("clear writable") rather than directly manipulating bits. Less general but simpler.

Option 2 is the most natural if descriptors are already matchable tables. Option 4 is simplest if generality isn't needed yet.

### Open: All-fields pattern and descriptors

The current `{ ...[%K]: %V }` binds key and value from each field. With descriptors, should it bind the full descriptor?

Problem: `{ ...%D }` looks like tuple rest capture, not field iteration. These are different operations with the same syntax — ambiguous. Needs either:
- Different syntax for "iterate field descriptors" vs "capture tuple rest"
- Or: the all-fields pattern always produces descriptors, and `{ ...[%K]: %V }` is sugar for destructuring `D.key` as K and `D.value` as V

This is tied to the broader `$EachField` question: if match can iterate descriptors and `$EachField` can collect results into a table, the two mechanisms need to be clearly distinct in syntax.

## Prior Art

- **TypeScript mapped types**: `{ [K in keyof T]: ... }` with `+?`/`-?`/`+readonly`/`-readonly` modifiers. Hardcoded modifier syntax — exactly what this spec avoids.
- **Scala 3 match types + opaque types**: structural matching + nominal wrappers for access control.
- **Haskell lenses**: `view`, `set`, `over` — field access decomposed into getter/setter pairs. Conceptually similar — fields as paired capabilities.
- **Java/C#/Rust/Python/Kotlin/Swift/C++ annotations/attributes/decorators**: general metadata mechanism for declarations. Universal pattern for the problem of "metadata on things."
- **Row polymorphism** (PureScript, OCaml with row types): fields as first-class type-level data.
