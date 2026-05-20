# Legacy typechecker — method dispatch on primitive receivers

Audit of how `lib/type/static/` resolves `s:upper()`, `(3):floor()`, etc.

## Mechanism

The legacy typechecker uses a **principled, per-primitive-tag registry**, not
the v4 K6e shortcut of indexing `env.bindings["string"]` at the call site.

Two ctx-level registries, both keyed by primitive `TAG_*` value (not by name):

- `ctx.prim_index` — `TAG_* → TID of the table used as the primitive's
  `__index` (the source for `s:method` lookups).
- `ctx.prim_meta` — `TAG_* → TID of the operator-metamethod table for that
  primitive (used by `solve_arith`, concat, comparison, etc.).

Both are declared in `ctx_types.lua:180` and `types.lua:198-201`, populated
once during prelude loading, and re-populated whenever an `--:: augment string
{...}` declaration adds fields. Method-call dispatch then reads through the
registry; it never inspects the binding named `"string"`.

## Population

`prelude.lua:299-323` derives the registries from declared type aliases:

```
ctx.prim_meta[TAG_NUMBER]  = body of alias  `number_meta`
ctx.prim_meta[TAG_INTEGER] = body of alias  `integer_meta`
ctx.prim_meta[TAG_STRING]  = body of alias  `string_meta_ops`
ctx.prim_index[TAG_STRING] = binding TID of `string`
```

`stdlib_types.lua` declares these aliases and the `string` library table —
they are not hardcoded in the checker; they are user-replaceable Lua-side
declarations.

`--:: augment` re-runs the same logic: `constrain.lua:5198-5305` (and the
mirror pass in `prelude.lua:284-292`) merges augment fields into the existing
binding and, when the augmented name is a primitive (`string`/`number`/
`integer`/`boolean`), updates `ctx.prim_index[prim_tag]` and (when the augment
adds meta fields) `ctx.prim_meta[prim_tag]`. The registries stay coherent with
augmentations regardless of which order declarations come in.

## Dispatch sites

`s:method(...)` resolution — `solve.lua:1713-1744`. Receiver type's
`TAG_LITERAL` is normalized to base tag, then `ctx.prim_index[base_tag]` is
read and `types_mod.table_field(ctx, idx_tid, name_id)` looks the method up.
On miss: `"no method `name` on this type"`. The binding named `"string"` is
never consulted.

Other principal sites that consume the registries:

- `unify.lua:677-705` — primitives satisfy `{ #__op: fn }` meta-only table
  constraints via `prim_meta` (subtyping side).
- `unify.lua:706-744` — primitives satisfy named-field table constraints
  (e.g. `string <: { sub: _ }`) via `prim_index` (subtyping side).
- `solve.lua:574-585`, `solve.lua:914-925`, `solve.lua:2692` — operator
  metamethod lookup (`+`, `..`, comparison) for primitives reads `prim_meta`.
- `solve.lua:1071-1097` — meta-bound propagation back to primitive `prim_index`.

In every case the entry point is the per-tag registry, not the
identically-named global binding.

## Tuple/literal narrowing

`TAG_LITERAL` is always normalized to its base tag before registry lookup
(unify.lua:682-688, solve.lua:1717-1723). String literals therefore dispatch
through the same `prim_index[TAG_STRING]` as bare `string` values, with the
identical method set. There is no separate literal-method path.

## `setmetatable` — typed via match patterns, not stateful tracking

`stdlib_types.lua:38`:

```
--:: declare setmetatable = <T, MT>(t: T, mt: MT) -> T & MT & { #...MT }
```

The return type purely structurally re-types the value: the result has both
`T` and `MT`'s named fields plus `MT`'s meta slots (`{ #...MT }` is the
meta-spread, implemented via `TAG_PAT_META_SPREAD` per `lib/type/static/
CLAUDE.md`). The legacy checker does **not** track "binding X had
`setmetatable` called on it" — narrowing is per-expression-result through the
return type. `getmetatable` is the symmetric `MetaOf<T> = match T { { #...%M }
=> M, _ => nil }` (stdlib_types.lua:39-40).

This is precise for code that uses the return value of `setmetatable`
(`local obj = setmetatable({...}, MT)`, the idiomatic shape) and imprecise
for code that mutates after construction (`local obj = {}; setmetatable(obj,
MT); obj:method()`) — the in-place case is not tracked. Crescent's "all data
fields in the literal" rule (project CLAUDE.md) means the imprecise case is
not the recommended pattern.

## Verdict

**Principled, not the v4 K6e shortcut.** Three independent properties of the
legacy design that the shortcut does not have:

1. Lookup is keyed by `TAG_*`, not by the source-level identifier `string`.
   Rebinding the global `string` to something else (or shadowing it locally)
   would not break `"":upper()` dispatch — `prim_index` is a separate map.
2. `TAG_LITERAL` normalization is centralized; literal and non-literal
   receivers go through the same path.
3. Augmentation maintains an invariant (`augment` updates the registry); the
   shortcut has no augment story at all.

The v4 K6e mechanism (read `env.bindings["string"]` at the call site, take
`.fields[method_id]`) coincidentally produces the right answer because the
runtime convention `string.__index = string` makes the library table and the
`__index` table identical for the string primitive — but it is brittle along
each of the three axes above and would need parallel ad-hoc carve-outs for
`number`/`integer`/`boolean` and for every augment.

## Implication for v4

Match the legacy design, not the K6e shortcut.

- v4 needs ctx-level `prim_index` (and eventually `prim_meta`) registries
  keyed by primitive tag, populated from declared aliases/bindings during
  prelude load, and updated by `--:: augment` if v4 will support it.
- The method-call walker (K6e) should normalize literal → base tag and read
  `prim_index[base_tag]`, never `env.bindings[<name>]`.
- `setmetatable` typing reuses the existing meta-spread machinery (`{ #...MT
  }`); no special binding-state tracking is required.

This is one of the few places where matching legacy verbatim is the right
call — the registry design is load-bearing for soundness (point 1) and
ergonomics (points 2-3), not legacy accretion.
