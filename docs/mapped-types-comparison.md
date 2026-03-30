# Mapped Types: TypeScript vs Crescent

## What TS mapped types are

A single declaration that iterates over a type's fields and produces a new type:

```typescript
type Partial<T>  = { [K in keyof T]?: T[K] }       // add optional
type Required<T> = { [K in keyof T]-?: T[K] }       // remove optional
type Readonly<T> = { readonly [K in keyof T]: T[K] } // add readonly
type Pick<T, K extends keyof T> = { [P in K]: T[P] } // select keys
type Omit<T, K> = { [P in keyof T as P extends K ? never : P]: T[P] }
// (4.1+) key remapping + filtering
type Getters<T> = { [K in keyof T as `get_${string & K}`]: () => T[K] }
```

## What crescent can express today

```lua
--:: PairsReturn<T>  = match T { { ...[%K]: %V } => (K, V) }   -- precise! ("x", integer) | ("y", string)
--:: IpairsReturn<T> = match T { { ...[%K]: %V } => match K { integer => (integer, V), _ => never } }
--:: Keys<T>         = match T { { ...[%K]: %V } => K }         -- "x" | "y" (literal keys)
--:: Values<T>       = match T { { ...[%K]: %V } => V }
--:: Record<K, V>    = { [K]: V }
--:: ReturnType<F>   = match F { () -> %R => R }
```

After `{ ...[%K]: %V }` is implemented. **Distribution** is per-field — preserves K/V
correspondence within each field evaluation. The gap is **gather/reconstruct**: producing
a single transformed table from all fields.

## The core gap: read vs. read-write

TS mapped types maintain **per-field correspondence**:

```typescript
// For EACH key K, produce T[K]. K and T[K] travel together.
type Partial<T> = { [K in keyof T]?: T[K] }
```

Crescent's `{ ...[%K]: %V }` **distributes per-field** — for each field, K and V are
bound to that field's specific key and value, the result is evaluated, and results are
unioned. For `{ x: integer, y: string } => (K, V)` this gives `("x", integer) | ("y", string)`.

Per-field correspondence IS maintained — but the result is a **union of per-field
evaluations**, not a reconstructed table. `Partial<T>` requires gathering all fields
into one table:

```lua
-- WRONG: gives { ["x"]: integer? } | { ["y"]: string? } — not Partial<T>
--:: Partial<T> = match T { { ...[%K]: %V } => { [K]: V? } }
```

`Partial<T>` is inexpressible because distribution produces a union of single-field tables,
not one table with all fields. A separate **gather/reconstruct** mechanism is needed.

## What TS got right

**Modifier control** (`+?`/`-?`/`+readonly`/`-readonly`) — optionality and mutability are
first-class field metadata in TS, so having syntax to add/remove them is natural and
genuinely useful. `Required<T>` and `Readonly<T>` are everyday utilities.

**Key filtering via `never`** — mapping a key to `never` in the `as` clause drops it
cleanly. Simple, composable, no special syntax for "omit this field."

**Composability with conditionals** — `T[K] extends X ? A : B` inside a mapped type lets
you make per-field decisions based on value type. This is the most powerful combination.

**Key remapping with `as`** (4.1+) — allows renaming keys, enabling getter/setter
generation, prefix/suffix patterns, and event-handler APIs without separate declarations.

## What TS got wrong

**`keyof T` returns `string | number | symbol`** — numeric index signatures and symbol
keys pollute `keyof`. Template literal key remapping requires `string & K` to filter out
numbers and symbols, which is noisy and surprising to new users.

**Homomorphic mapped type primitive passthrough** — when applied to a primitive (`string`,
`number`, etc.), a homomorphic mapped type returns the primitive unchanged, ignoring the
transformation. `Partial<string>` = `string`. This special case exists for ergonomics but
violates the principle of least surprise and creates edge cases.

**Union + mapped type distribution** — `keyof (A | B)` is the intersection of keys (not
the union), and mapped types over union inputs don't distribute the same way conditional
types do. The inconsistency creates subtle bugs that even experienced TS users hit.

**Infer inside mapped inside conditional loses precision** — deeply nested combinations
(`infer` inside a mapped type inside a conditional) degrade to loose types. The composition
breaks in non-obvious ways.

**Eager evaluation in nested cases** — nested mapped types sometimes evaluate eagerly when
lazy evaluation would be correct, causing spurious type errors and compiler performance
cliffs on deep recursive types (though improved in TS 5.x).

## Closing the gap in crescent

Two distinct primitives are needed, not one:

### `{ ...[%K]: %V }` — per-field distribution (already specced)

For each field, K and V are bound, the result expression is evaluated, results are
unioned. Right for PairsReturn, Keys, Values — anything that reads fields. Does NOT
expose optional/readonly flags, and the result is a union, not a reconstructed table.

```lua
--:: Keys<T>   = match T { { ...[%K]: %V } => K }
--:: Values<T> = match T { { ...[%K]: %V } => V }
```

### `$EachField<T, F>` — per-field gather/map (specced, permanent intrinsic)

Iterates each field of T, passes a descriptor `{ key, value, optional, readonly }` to
F (a match alias using `%` captures), collects transformed fields into **one new table**.
Handles flag manipulation that `{ ...[%K]: %V }` cannot express.

```lua
--:: MakeOptional = match { optional: _, ...%Rest } { _ => { optional: true,  ...Rest } }
--:: Partial<T>  = $EachField<T, MakeOptional>

--:: MakeRequired = match { optional: _, ...%Rest } { _ => { optional: false, ...Rest } }
--:: Required<T> = $EachField<T, MakeRequired>

--:: MakeReadonly = match { readonly: _, ...%Rest } { _ => { readonly: true,  ...Rest } }
--:: Readonly<T> = $EachField<T, MakeReadonly>

--:: MakeWritable = match { readonly: _, ...%Rest } { _ => { readonly: false, ...Rest } }
--:: Writable<T> = $EachField<T, MakeWritable>
```

F is a **named alias passed unapplied** — same syntactic position as an HKT constraint
argument. No inline anonymous match expressions in type argument position. `...%Rest`
captures everything not being transformed (key, value, other flags) and splices it back —
you only name the field you're changing. The descriptor fields `optional` and `readonly`
carry the FLAG_OPTIONAL / FLAG_READONLY bits. `$EachField` is a **permanent intrinsic** —
the gather/flag-write operation cannot be expressed as pure match computation.

The two primitives are complementary:
- Distribution (`{ ...[%K]: %V }`) — read fields, union results, no flag access
- Gather/map (`$EachField`) — read fields + flags, transform, emit one table

## Key lessons for crescent design

**Don't add `keyof`** — crescent has `Keys<T>` as a match alias. No built-in `keyof`
operator; it's just a type alias. Keys are always `string` for named fields (no
`string | number | symbol` pollution — Lua tables use string keys for named fields
and integer indexers are separate).

**Don't add homomorphic passthrough** — if `Partial<integer>` is written, it should be
a type error (or `$Throw`), not silently return `integer`. Crescent's design principle:
no silent special cases.

**Union distribution should be explicit** — mapped types over union inputs should
explicitly distribute via match (`match T { ... }`) rather than implicit distribution
rules. What happens to `Partial<A | B>` should be obvious from the alias definition.

**Modifier control is worth having** — optionality (`FLAG_OPTIONAL`) and readonly
(`FLAG_READONLY`) already exist as field flags. Syntax for adding/removing them in type
transformations is a real need. The +/-modifier syntax from TS is clean and worth adapting.

**Keep read and write symmetric** — `{ ...[%K]: %V }` reads; its complement in result
position should write. This symmetry is easier to learn than TS's different syntax for
reading (`T[K]`) vs iteration (`[K in keyof T]`).
