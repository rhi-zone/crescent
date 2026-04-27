# Ubiquitous Language

Domain vocabulary for Crescent. Use these terms precisely in code, docs, and conversations.

## Tier
_Avoid:_ version, fallback, layer

One of three independent implementation levels for a library: `system > ffi > pure`. Selected at load time via `pcall`; each tier is a complete, standalone implementation — not a wrapper around a lower tier. Introspectable via `M._tier`.

Confusing "tier" with "fallback" implies the lower tiers are incomplete approximations; they are not.

## Cap / Capability
_Avoid:_ option, dependency, import

An I/O function injected as a parameter rather than imported from globals. The foundation of sandbox safety: code should receive only what it needs, not access to `os`, `io`, or other global namespaces. Note: `opts.x or global.x` is still a violation — defaulting through options to a global defeats the pattern.

## Opaque
_Avoid:_ private, hidden, encapsulated

A nominal type whose internal structure is completely hidden outside its defining module. Declared with `$Opaque<T>` or `$Opaque<T,U>`. Callers cannot inspect or construct the inner value without `unseal`. Enforces identity-based typing: two opaques with the same shape are not the same type.

## Unseal
_Avoid:_ unwrap, extract, cast

The operation that recovers the inner type from an opaque. Requires explicit use; not automatic. Tracked as `ANN_UNSEAL` in the typechecker.

## Newtype
_Avoid:_ type alias, typedef, wrapper

A distinct type wrapping another, declared with `--:: newtype`. Assigns a `nominal_id` at the declaration site. Requires explicit conversion; not structurally interchangeable with the underlying type even though the runtime representation is identical.

## Nominal Typing
_Avoid:_ structural typing (different concept)

Identity-based type dispatch: two types are the same only if they are the same declaration, not if they have the same shape. Used by opaques and newtypes. The default in Crescent is **structural** — nominal is an explicit opt-in.

## Row Polymorphism
_Avoid:_ open type, any, dictionary

The `...` in table types (e.g. `{ x: T, ... }`) representing an open field set. A table with `...` accepts any table with at least those fields. Distinct from `[K]: V` (index signature — see below).

## `...` vs `[K]: V`
_Avoid:_ treating these as equivalent

`...` (row polymorphism) means "has at least these fields, may have more." `[K]: V` (index signature) means "all string keys map to V." Using `[string]: T` on a concrete data object makes it open for arbitrary key access, which is almost never intended. CLAUDE.md calls this out explicitly as a known trap.

## Rowvar
_Avoid:_ type variable (different kind)

A row variable representing an open table field set, distinct from a regular type variable (`TAG_VAR`). Tracked as `TAG_ROWVAR` in `types.lua`. Enables structural subtyping over table fields.

## Annotation
_Avoid:_ (context-dependent — three distinct senses)

Three distinct things share this name:
1. **Syntax**: a `--:` or `--::` comment attaching a type to a declaration
2. **Typechecker pass**: the phase that walks the AST and attaches type information
3. **Annotation arena**: a temporary arena for pattern AST nodes (see below)

Always clarify which sense is meant.

## Annotation Arena
_Avoid:_ type arena, main arena

A temporary arena for pattern AST nodes (captures, `all_fields`, `rest_fields`, `meta_spread`). Separate from the three main arenas (types, fields, lists). IDs from the annotation arena are not interchangeable with IDs from the main type arena. Tags like `TAG_TYPEOF` are annotation-arena-only.

## TypeSlot
_Avoid:_ type node, type object

A 32-byte FFI struct (`tag`, `flags`, `reserved`, `data[7]`) that is the fundamental unit of type representation. Types are stored as flat arrays of TypeSlots; integer indices into these arrays are the "type references" passed around the typechecker.

## Constraint-Based Inference
_Avoid:_ type propagation, type assignment

The type inference model: the typechecker emits constraints during the annotation pass, then `solve.lua` resolves them separately via unification. The two phases are distinct — emitting a constraint does not immediately produce a type.

## Narrowing
_Avoid:_ casting, coercing

Type refinement in conditional branches. After `if x then`, the type of `x` is narrowed from `T | nil` to `T` inside the branch. Implemented in `narrow.lua`.

## Parity Tests
_Avoid:_ unit tests, integration tests

Tests asserting byte-for-byte identical output across all implementation tiers. Catch edge cases where a higher tier behaves differently from the pure Lua reference implementation. Fuzzing is used to find inputs that expose parity failures unit tests miss.

## Vendorable
_Avoid:_ installable, publishable

A library designed to be copy-pasted into a project with zero external dependencies. The library works standalone; no package manager, no `require` outside the vendored tree. Core Crescent philosophy.

## Codec Interface
_Avoid:_ serializer, parser

The standard encode/decode API pattern: primary names are `string_to_foo` / `foo_to_string`; `encode` / `decode` are provided as aliases. Symmetric and descriptive — the direction of conversion is always readable from the name.
