# M7 — Record mutability, width subtyping, field attributes, and indexers

*Normative module spec of the unified type-system design. Depends on **M1**
(`01-lattice-and-subtyping.md`: the lattice / RDNF / complement / emptiness /
subtyping algorithm; a sealed record is a value type / lattice atom (M1 §1.1);
record subtyping is structural decomposition into per-field obligations (M1
§3.1)). Reconciles with **M6** (`06-setmetatable-construction.md`: the
open→sealed phase lifecycle and the explicit M6→M7 seam, M6 §6) and assumes
**M4** (`04-hkt-kinds.md`: a field/index value that is `App(F, A)` reaching a
record rule is kind-`Type`, already β-reduced — M7 reasons over `Type`-kinded
field and value types). M7 specifies the **field-variance rule** (readonly ⇒
covariant, mutable ⇒ invariant; the **supertype's** modifier governs), **width
subtyping** via open/closed rows gated by that rule, the **field-attribute
model** (optional + readonly — the semantic model; the surface sigil is DEFERRED
to a UX batch), and the **indexer `{[K]:V}` as a region DISTINCT from the open
row `...`**, with named-fields-plus-indexer mixtures and indexer subtyping.
Aligns to `docs/type-system.md` (philosophy, fixed) and satisfies the soundness
floor of `docs/typechecker-v5-constraints.md` §A.*

Primary sources reconciled here:

- **`docs/typechecker-v5-operational-semantics.md` § "Principled literals and
  records (TLiteral + TRecord)"** (Spec C, commit `7a627c26`) — the three-region
  `TRecord = {fields, indexes, row}` node, the `TField = {type, optional,
  readonly}` and `TIndex = {key, value}` descriptors, the **revised T-CEq-Record**
  and **T-CSub-Record** (the readonly⇒covariant / mutable⇒invariant rule with the
  supertype-governs clause, optional-presence, key contravariance). **M7 ADOPTS
  this three-region `TRecord` and its variance rule as its realization** and
  generalizes the literal-widening case (which Spec C added for the literal pair)
  to the whole field-variance axis.
- **`docs/typechecker-v5-operational-semantics.md` § "Subtyping
  (variance-respecting)"** — the *superseded* `T-CEq-Record` /
  `T-CSub-Record-Width` (the unconditional-`CEq`-invariance rule, the "fields are
  mutable in v5.0" soundness-floor comment). M7 **replaces** the unconditional
  invariance with the variance rule; the comment's unenforced invariant is now
  enforced (Y4/Y6).
- **`docs/typechecker-v5-operational-semantics.md` § "Row polymorphism (CRow
  family)"** — `TRowVar`, `CRowExtend`/`CRowLacks`/`CRowClose`, the open/closed
  row distinction and its **G8 soundness floor** (absence on an unclosed row is
  unsound). M7 reuses this row machinery unchanged; it adds **no** new row
  mechanism, only routes width-subtyping surplus through it.
- **`docs/type-system.md` § "Field modifiers: attributes, not keywords"
  (~§380–408)** — the attribute-vs-keyword decision, the surface-sigil OPEN
  questions (~§402–406: sigil `@`/`#`, attribute arguments, arena representation,
  `$EachField` interaction), and the *"fields are mutable in v5.0"* soundness
  ordering. M7 **DECIDES the semantic model** (optional + readonly + variance)
  and **DEFERS the surface sigil/syntax** to a UX batch (§4.5), per the plan.
- **`docs/v5-gaps.md`** — **record-width-invariance**, **Y4**, **Y6**, and the
  **record axis of prefix-scoping** (the `$opt_`/`$ro_`/`$idx_`/`$opaque_`
  field-name encodings → structured field descriptors). Quoted §8.
- **`docs/typechecker-v5-constraints.md` §A** — the soundness floor (§7).

M1 owns the lattice, RDNF, complement, emptiness, and structural decomposition
(M1 §3.1 dispatches `Record <: Record` to "width + per-field variance (M7)").
**M7 fills in that obligation**: *which* per-field obligation (`CSub` for
readonly/covariant, `CEq` for mutable/invariant), the width rule, the indexer
composition. M6 owns the phase (when a record's shape is fixed) and guarantees
each field has **one fixed type at the seal**; **M7 specifies variance on a
SEALED record** and redefines none of M6's phase lifecycle (§6). The discipline
in one sentence: **on a sealed record, a field's variance is decided by the
supertype field's `readonly` modifier — covariant if readonly, invariant if
mutable — and width subtyping forgets extra subtype fields, gated by that rule.**

---

## 1. The three-region record (adopted from Spec C)

### 1.1 The node

M7 adopts the v5 Spec C `TRecord` as the M1 `Record{fields, indexes, row}`
constructor (M1 §1.1 names it; M7 fills it in):

```
Record = { tag = "record", fields, indexes, row }
  fields  : { [string]: Field }      -- named fields, keyed by bare name
  indexes : Index[]                  -- index signatures, first-class
  row     : RowVar | nil             -- open (row var) vs closed (nil)

Field = { type, optional, readonly }
  type     : Type                    -- a value type (M1 §1.1), Type-kinded (M4)
  optional : boolean                 -- field may be absent (§4.1)
  readonly : boolean                 -- governs variance (§3)

Index = { key, value, readonly }
  key      : Type                    -- the index key type (e.g. string)
  value    : Type                    -- the indexed value type
  readonly : boolean                 -- governs index-value variance (§3, §5)
```

Three **distinct regions**, each load-bearing and each meaning a different thing:

1. **`fields`** — a finite map of statically-known **named** fields, keyed by the
   **bare name** (no `$opt_`/`$ro_` prefix — those encodings are retired, §8). The
   per-field attributes live on the `Field` descriptor as **real booleans**, not
   on the key. This closes the record axis of prefix-scoping.
2. **`indexes`** — a list of **index signatures** `{[K]: V}`: a uniform rule for
   *all* keys of type `K`, distinct from any specific named field (§5).
3. **`row`** — the **open/closed marker**: a `RowVar` (open — the record may have
   *more, unknown* named fields) or `nil` (closed — the named-field set is
   exactly `dom(fields)`). This is the **structural-subtyping marker** (`...`),
   and it is **NOT** an index signature (§5.1 — the CLAUDE.md hard rule).

`fields`, `indexes`, and `row` are three orthogonal axes. A record may have any
combination: named fields only, an indexer only, both, with an open or closed
row. The mixtures are specified in §5.

### 1.2 Why the regions are distinct (the CLAUDE.md hard rule, restated)

CLAUDE.md: *"`...` is a structural-subtyping marker. `{[string]:T}` is an index
signature. Confusing them is wrong on either side."* M7 encodes the two as
**different regions** so they cannot be confused by construction:

- The **row** `...` (`row : RowVar | nil`) says *"this record may have additional
  named fields beyond those listed, of unknown name and type"*. It is a
  **width-subtyping affordance**: an open row absorbs extra fields a subtype
  carries (§5.6); a closed row forbids them. The row never *types* a key — it
  only marks whether the named-field set is exhaustive.
- The **indexer** `{[K]: V}` (an `indexes[]` entry) says *"every key of type `K`
  maps to a value of type `V`"*. It is a **typing rule over a key domain**: it
  assigns a value type to a (possibly infinite) set of keys. It participates in
  subtyping with key contravariance + value variance (§5.3), entirely unlike the
  row.

A record `{ [string]: number }` (one indexer, closed row, no named fields) is
**not** the same as `{ ... }` (open row, no indexer): the former *types every
string key as `number`*; the latter *says nothing about the types of the
unlisted fields* (they are absorbed, not constrained). M7 keeps them in separate
regions precisely so neither side can collapse into the other (§5.1 makes the
non-equivalence normative).

### 1.3 Walker treatment (adopted from Spec C, recorded for migration)

`shift`/`instantiate`/`equal`/`collect_uvars` recurse into all three regions
(Spec C § "Walker treatment", adopted unchanged): `shift`/`instantiate` descend
through every `fields[k].type` and every `indexes[i].key`/`.value` (the scalar
attributes `optional`/`readonly` copy unchanged; `row` is a `RowVar`, never
shifted); `equal` compares domains, the per-field attributes (attributes are part
of identity), the index list pairwise, and row agreement; `collect_uvars` unions
over field types and index key/value (the `RowVar` contributes nothing). The
**positional branches are dropped** — a positional sequence is a `TPack` (M3),
never a record (Spec C; M3 §1). M7 states no positional record rule.

---

## 2. Records as lattice atoms; subtyping is structural decomposition (M1 seam)

A **sealed** record is an M1 value type / lattice atom (M1 §1.1; the seal is M6's,
§6). Record subtyping is **structural decomposition** (M1 §3.1): `Record <:
Record` is decomposed into per-region obligations, *not* decided by a record-shaped
special case. M7 specifies exactly which obligations.

> **The decomposition contract (M1 §3.1 → M7).** `CSub(Record_a, Record_b)`
> decomposes into: (1) **named-field obligations** (§3, §5.2), (2)
> **index-signature obligations** (§5.3), (3) **row obligations** (§5.6). Each
> obligation is itself an M1 `CSub`/`CEq` on **field/value types**, which flow
> back through M1's algorithm. A field type may contain `Neg`/unions (M1 §1.2):
> e.g. a falsy-branch narrowing produces a field type `T & ~nil`, and the
> per-field obligation `CSub(F_a[k].type, F_b[k].type)` is an ordinary M1 subtype
> query that routes through the emptiness procedure (M1 §3.3–3.4) when the field
> type is a non-trivial negation. **M7 adds no record-shaped reasoning to M1; it
> only names the obligations.** This is how the no-special-casing hard constraint
> holds: a new field attribute changes *which obligation* a field emits, never
> adds a matrix cell to the subtyping dispatcher.

`CEq` between two records is `CSub` both directions; equivalently, the **revised
T-CEq-Record** (Spec C, adopted): domains, per-field attributes, index lists, and
rows must all agree, and field types + index key/value pairs are equated (§5.4).
Attributes are **part of record identity** (two records that differ only in a
field's `readonly` flag are not equal) — adopted from Spec C and v4's
`struct_equal` (which compares flag bytes for the same reason).

---

## 3. The field-variance rule (the core soundness rule)

This is the heart of M7. It **replaces** the v5 "all named fields invariant via
`CEq`" workaround (the superseded `T-CSub-Record-Width`, op-sem § "Subtyping
(variance-respecting)") with a principled, attribute-driven rule.

### 3.1 The rule

> **Field variance (normative).** For a field/index in the **supertype**:
> - **`readonly` ⇒ COVARIANT**: emit `CSub(v_sub, v_super)` on the field type.
> - **mutable (the default, no `readonly`) ⇒ INVARIANT**: emit `CEq(v_sub,
>   v_super)` on the field type.
>
> **The SUPERTYPE's modifier governs.** Whether a field position is checked
> covariantly or invariantly is decided by the **expected** (supertype) field's
> `readonly`, not the supplied (subtype) field's.

Formally, the per-position variance subgoal (shared by named fields §5.2 and
index values §5.3 — *one* rule, no special-casing the indexer):

```
field_subgoal(fld_a, fld_b) =          -- fld_a in subtype, fld_b in supertype
    fld_b.readonly ? CSub(fld_a.type, fld_b.type)   -- covariant
                   : CEq (fld_a.type, fld_b.type)    -- invariant (mutable)
```

There is a second, **modifier-compatibility** half (the supertype-governs clause
applied to the modifiers themselves, not just the types):

> **Modifier compatibility (normative).** A `readonly` supertype field may be
> satisfied by **either** a `readonly` or a mutable subtype field. A **mutable**
> supertype field may be satisfied **only** by a mutable subtype field — a
> `readonly` subtype field against a mutable supertype field is **rejected**.
>
> Formally: if `fld_b.readonly` then `fld_a` may be readonly *or* mutable; if
> `¬fld_b.readonly` then `fld_a` must be mutable.

### 3.2 Why this is sound

The soundness basis is the **read/write capability** of a field (Spec C
§ "Record CSub"; M1 §1.3; the well-known TypeScript-array unsoundness):

- A **mutable** field is a **read-and-write** position. Width/depth subtyping that
  *narrowed* such a field covariantly would be unsound: if `{x: integer} <: {x:
  number}` were admitted (covariant on a mutable field), then through the
  supertype reference one could **write** a `number` (e.g. `3.5`) into a slot the
  subtype believes holds an `integer`, corrupting the subtype's invariant. This is
  exactly the mutable-covariance hole. **Therefore a mutable field is INVARIANT**
  (`CEq`): the field types must be *equal*, so reads and writes both agree. This
  is the soundness floor `type-system.md` records as *"fields are mutable in
  v5.0"* — now **enforced** by the `CEq` emission, not merely commented (Y4/Y6,
  §8).
- A **`readonly`** field opts out of writes — it is a **read-only** position. With
  no write capability, the classic hole cannot be triggered: a reader of a
  `readonly number` field is satisfied by a slot that holds an `integer` (every
  `integer` *is* a `number`, and no write can install a non-`integer`).
  **Therefore a readonly field is safely COVARIANT** (`CSub`): `{readonly x:
  integer} <: {readonly x: number}` holds. This is the standard read-only
  covariance result and matches the immutability-enables-covariance rule in every
  sound system that has it (e.g. covariant arrays only when immutable).

The **supertype-governs** direction is the substitutability argument: subtyping
`a <: b` means *"a value of `a` is usable wherever a `b` is expected."* The
expected type `b` declares the **capability the consumer will exercise**:
- If `b`'s field is `readonly`, the consumer will only **read** it. A subtype that
  supplies a *narrower* value (covariance) is fine — every read still returns a
  `b`-typed value — and a subtype that is *itself* mutable is also fine (the
  consumer simply will not write through the `readonly` view). Hence a readonly
  supertype field accepts readonly *or* mutable subtype fields, covariantly.
- If `b`'s field is **mutable**, the consumer may **write** it. A subtype must
  therefore (i) agree on the type exactly (invariance, so a write of any
  `b`-valid value is also `a`-valid) and (ii) **itself be writable** — a
  `readonly` subtype field cannot satisfy a mutable supertype field, because the
  consumer's write would violate the subtype's read-only contract. Hence a mutable
  supertype field demands a mutable subtype field, invariantly.

This is why **the supertype's modifier governs**: the supertype encodes the
consumer's intended capability, and soundness is about what the consumer is
permitted to do.

### 3.3 Consequences pinned (adopted from Spec C, generalized)

- `{ x: integer }` is **NOT** `<: { x: number }` (mutable named field, invariant;
  would require `integer = number`, rejected).
- `{ readonly x: integer }` **IS** `<: { readonly x: number }` (readonly named
  field, covariant; `CSub(integer, number)` holds).
- `{ readonly x: integer }` **IS** `<: { x: integer }`? **No** — mutable supertype
  field, readonly subtype field: modifier-incompatible, rejected (§3.1).
- `{ x: integer }` **IS** `<: { readonly x: integer }` (mutable subtype field
  satisfies a readonly supertype field; covariant, `CSub(integer, integer)`
  holds). You may supply a mutable field where a readonly one is expected.
- **Literal widening through a record** (the record-width-invariance gap, §8):
  `{ readonly tag: "leaf" } <: { readonly tag: string }` holds via `CSub("leaf",
  string)` (the M1 literal-widening atom edge). Under the old all-invariant rule
  this required `"leaf" = string` and was rejected — that is the bug
  record-width-invariance names. **The variance rule closes it**: a readonly field
  widens covariantly. (A *mutable* `tag` field still requires equality — correctly,
  because a mutable `tag` could be written.) This is the generalization of Spec
  C's literal-pair widening to the whole field axis.

---

## 4. The field-attribute model (semantic model DECIDED; sigil DEFERRED)

`type-system.md` (~§380–408) decides field modifiers are **attributes, not
keywords** (an open metadata mechanism the parser handles generically and the
checker interprets), and flags the **surface sigil** (`@`/`#`), **attribute
arguments**, **arena representation**, and **`$EachField` interaction** as OPEN.
Per the plan, **M7 decides the SEMANTIC model** (which attributes exist and what
they mean) and **DEFERS the surface sigil/syntax** to a UX batch (§4.5). M7 does
**not** invent a sigil normatively.

### 4.1 `optional` — the field may be absent (domain agreement on optionality)

> **`optional` (normative semantics).** A field with `optional = true` **may be
> absent** from a record value. It is the type-level statement *"this key may or
> may not be present"* — equivalently, a present-field of type `T` **or** an
> absent key.

Optionality is a **presence** attribute (does the key exist), distinct from the
field's *type* (what the value is if present) and distinct from a nullable type
`T | nil` (the key is present but the value may be `nil`). These are different:
`{ x?: integer }` (x may be absent) is not the same shape as `{ x: integer | nil
}` (x is present, value may be nil) — though they often coincide in Lua, where an
absent key and a `nil` value are indistinguishable at runtime. M7 keeps them
distinct at the type level (the presence axis is the row/optional region; the
value axis is the field type); their runtime coincidence is an M9/M11 narrowing
concern, not an M7 conflation.

**Subtyping with optionality — domain agreement (normative):**

- A **required** subtype field (`¬optional`) satisfies a **required or optional**
  supertype field (a guaranteed-present value is fine where an optional one is
  expected).
- An **optional** subtype field satisfies an **optional** supertype field (both
  agree the key may be absent), subject to the value variance (§3).
- An **optional** subtype field does **NOT** satisfy a **required** supertype
  field: a possibly-absent field cannot be supplied where a guaranteed-present one
  is demanded — **reject** (the "required field missing" case, generalized to
  presence). This is the *domain-agreement* soundness: the supertype's required
  domain must be a subset of the subtype's guaranteed-present domain.
- A supertype **optional** field **absent** from the subtype is **OK** (the
  supertype optional field may simply be the always-absent case — §5.2).
- A supertype **required** field absent from the subtype is **reject** (missing
  required field), unless an indexer covers it (§5.2, §5.3).

This is exactly Spec C's optional-presence clause (T-CSub-Record, named-field
obligations) restated as the **domain-agreement** soundness principle: the set of
keys the supertype *requires* must be covered by the set of keys the subtype
*guarantees*, and the set of keys the subtype *may carry* must be permitted by the
supertype (open row / matching optional).

### 4.2 `readonly` — governs variance (per §3)

> **`readonly` (normative semantics).** A field with `readonly = true` is a
> **read-only** position: it may be read but not written through this view.
> `readonly` is **prescriptive** (`type-system.md` §"Why not infer from usage":
> *"`@readonly` means 'writing is a bug,' not 'happens to not be written
> currently.'"*). Its sole subtyping consequence is the variance of §3: a readonly
> field is covariant, a mutable field invariant; the supertype's `readonly`
> governs.

`readonly` on an **index** (`Index.readonly`) means the same for the indexer's
value (§5.3). `type-system.md` §408 confirms the surface admits `readonly [K]: V`,
so `Index` carries `readonly` as the same attribute (Spec C). A producer that
never emits `readonly` index signatures defaults the index to mutable/invariant.

### 4.3 The attribute model is extensible, but M7 fixes only these two

`type-system.md` §384 makes the attribute mechanism **open** (the parser collects
`attr`-tagged metadata generically; the checker defines which it understands). M7
**defines the two attributes the type checker understands today** — `optional`
and `readonly` — and their semantics (presence and variance). Other attributes
named in `type-system.md` (`@deprecated`, `@lazy`, `@sealed`, `@private`, …) are
**not** given checker semantics by M7: a future attribute with type-checking
consequence is a **new substrate decision** (a new attribute with a defined
subtyping/variance/presence rule, escalated), not a silent extension. M7's
`Field`/`Index` descriptors carry `optional` and `readonly` as the booleans Spec C
defines; an open attribute *list* (for `@deprecated` etc. with no subtyping
consequence) is an arena-representation question deferred with the sigil (§4.5).

> **`$EachField` / mapped types (semantic note, mechanism deferred).** Per
> `type-system.md` §400, attributes are **type-level data on the field
> descriptor**: a mapped type can inspect and rewrite them (`MakeOptional<T>` adds
> `optional` to each field; `MakeReadonly<T>` adds `readonly`). M7 fixes the
> **semantic substrate** for this: because `optional`/`readonly` are real fields on
> the `Field` descriptor (not key-mangled prefixes), a transform sees them as
> descriptor data and may set them — there is **no flag-mutation API**, just
> descriptor-field assignment. The **transform/match mechanism itself** (how
> `$EachField` iterates fields and whether it sees attributes as descriptor fields
> or a separate list) is an **M8 match-type** concern over the M7 descriptor shape
> and is flagged in M8's scope, not finalized here (§9, OPEN-QUESTION 4). M7
> guarantees only that the attributes are structured descriptor data a transform
> *can* manipulate.

### 4.4 Why structured descriptors, not `$`-string encodings (gap mechanism)

The v5 substrate encoded attributes as **field-name prefixes** (`$opt_x`,
`$ro_x`) and indexers/opaque keys as **mangled keys** (`$idx_N`, `$opaque_K`) —
the record axis of the prefix-scoping gap (§8). M7's model is **structured
descriptors**: `optional`/`readonly` are booleans on `Field`; an indexer is an
`indexes[]` entry; an opaque key is a single-key index `{key = Const(K)}`. This is
a **mechanism** (a structured node dispatched on `tag` and real fields), not a
result: subtyping reads `fld.readonly` (a boolean), never matches `k:match("^%$ro_")`.
This is the project's no-special-casing constraint applied to the type
representation, and it is what makes the field-variance rule expressible at all
(a string-prefix cannot carry the variance the rule needs without re-introducing
name-matching). The full retired-encoding correspondence is the Spec C mapping
table (§8).

### 4.5 The surface sigil and syntax — DEFERRED to a UX batch (explicit)

> **DEFERRED (not decided by M7).** The **surface sigil** for attributes (`@name`
> vs `#name` vs other — `type-system.md` §403 notes `#` already marks meta-fields),
> whether **attributes carry arguments** (`@range(0,100)`, §404), the **exact
> arena representation** of the open attribute list (§405), and the **`$EachField`
> transform's view** of attributes (§406) are **UX/surface-syntax questions with
> no soundness content for M7's variance and presence rules**. M7 decides the
> *semantic model* (optional + readonly + their subtyping consequences) and
> **deliberately does not invent a sigil normatively** — that is decided once, in
> a UX batch, rather than per-module. The internal representation M7 specifies is
> the Spec C `Field = {type, optional, readonly}` / `Index = {key, value,
> readonly}` descriptor; whatever surface sigil the UX batch chooses lowers to
> setting those booleans. (The syntax sketch in `type-system.md` §408 —
> `field?: T` for optional, `readonly field: T` for readonly — is illustrative,
> not normatively fixed by M7.)

---

## 5. Width subtyping, the indexer, and their composition

### 5.1 Indexer `{[K]:V}` is DISTINCT from the open row `...` (normative)

Restating §1.2 as a normative non-equivalence (the CLAUDE.md hard rule):

> **The indexer region (`indexes`) and the row region (`row`) are distinct and
> non-interchangeable.** An open row `...` is a **width affordance** (the record
> may carry additional *named* fields, unconstrained in type, absorbed by row
> unification). An index signature `{[K]: V}` is a **typing rule** (every key of
> type `K` has value type `V`). Neither subsumes the other:
> - `{ [string]: number }` (indexer, closed row) is **NOT** `{ ... }` (open row,
>   no indexer): the former constrains every string key to `number`; the latter
>   constrains nothing about the unlisted fields.
> - `{ ... }` (open row) is **NOT** `{ [string]: unknown }` (indexer to `unknown`):
>   the open row *absorbs* extra fields without assigning them a type the way an
>   indexer to `unknown` would (an indexer to `unknown` would force every read to
>   `unknown`; an open row leaves the absorbed fields' types to row unification,
>   which may later bind them precisely).
>
> A constraint generator that lowers `...` into an indexer, or an indexer into a
> row, is wrong on either side. M7 keeps them in separate `Record` regions so the
> conflation is structurally impossible.

### 5.2 Named-field obligations (width + variance + optionality)

`CSub(Record_a, Record_b)` (subtype `a`, supertype `b`), **named-field
obligations**, per supertype field `k ∈ dom(F_b)` (adopted from Spec C
T-CSub-Record, generalized with §3/§4.1):

- **`k ∈ dom(F_a)` (present in subtype):** emit `field_subgoal(F_a[k], F_b[k])`
  (§3.1 — `CSub` if `F_b[k].readonly`, else `CEq`), **and** check modifier
  compatibility (§3.1) and presence (§4.1: if `F_b[k]` is required but `F_a[k]` is
  optional, reject).
- **`k ∉ dom(F_a)` (absent in subtype):**
  - `F_b[k].optional` ⇒ **OK** (a supertype optional field may be absent — §4.1).
  - `¬F_b[k].optional` but a subtype index `X_a[j]` admits the literal key `k`
    (`CSub(literal(string,k), X_a[j].key)` holds) ⇒ the supertype required field
    is covered by the subtype's indexer; emit the value obligation against that
    index value (§5.3).
  - else ⇒ **reject** with `missing_field`.

**Subtype-only named fields** (`k ∈ dom(F_a) ∖ dom(F_b)`) are **forgotten** — this
is depth+width subtyping: a record with *more* named fields is a subtype of one
with *fewer*, provided the supertype's row admits the surplus (§5.6). The width
direction is the standard one: **wider (more fields) is the subtype**.

### 5.3 Index-signature obligations (key contravariant, value per its modifier)

Per supertype index `X_b[i] = {key=K, value=V, readonly=ro}` (adopted from Spec C,
generalized):

- **Each subtype named field** `k ∈ dom(F_a)` whose name-as-literal is admitted by
  the index key (`CSub(literal(string,k), K)` holds): the field's value must
  satisfy the index variance — emit `CSub(F_a[k].type, V)` if `ro`, else
  `CEq(F_a[k].type, V)` (the **same** §3 variance rule, index value vs field value
  — no special-casing the indexer).
- **Each subtype index** `X_a[j]` covering part of `K`: the **key is
  contravariant** (a consumer position — the argument you index *with*), so emit
  `CSub(K, X_a[j].key)` (the supertype key is a subtype of the subtype key — a
  subtype indexer may admit **more** keys, exactly arrow-argument contravariance);
  the **value follows the §3 variance rule** — `CSub(X_a[j].value, V)` if `ro`,
  else `CEq(X_a[j].value, V)`.
- If neither a named field nor a subtype index witnesses the supertype index `K`,
  the obligation is vacuously satisfied only when the subtype is **open** on that
  key region; a closed subtype with no witness is a `missing_index` error.
  (v5.0-conservative form, adopted from Spec C: emit the obligations that *do*
  match; backtracking over which witness covers which index is a later extension,
  §9 OPEN-QUESTION 3.)

> **Key contravariance + value variance (normative split).** Index **keys** are
> contravariant consumer positions (`CSub(K_super, K_sub)`); index **values**
> follow the §3 readonly/mutable variance (`CSub` if readonly, `CEq` if mutable).
> Both interpreters must agree on this split (key contra, value per readonly).
> This is the exact analogue of arrow subtyping (args contra, ret per its variance)
> — and is **not** a new dispatch rule, but the §3 field rule applied to the index
> value plus contravariance on the key, reducing entirely to M1 `<:` on the key
> and value types.

### 5.4 Record `CEq` (attributes part of identity)

`CEq(Record_a, Record_b)` (the **revised T-CEq-Record**, adopted from Spec C):
domains equal, per-field `optional`/`readonly` agree, index lists pairwise-agree,
rows agree; field types and index key/value pairs are **equated** (`CEq`).
Domain/attribute/index-count/row mismatch ⇒ reject. Attributes are part of
identity (§2). This is the both-directions specialization of §5.2/§5.3 and is the
disposition M6's `T-CTSet-Open-Equate` demotes to (M6 §1.3 fact 3 — refinement
during construction is `CEq`).

### 5.5 Named-fields-plus-indexer mixtures

A record may carry **both** named fields and an indexer (the common Lua case: a
table with a few known fields plus arbitrary string-keyed entries). The mixture
composes the §5.2 and §5.3 obligations, with the precedence rule:

> **Named fields shadow the indexer for their own keys.** A named field `k` with
> `Field` descriptor takes precedence over any index whose key admits `k`: reading
> `t.k` resolves to `F[k].type` (the named field), not the index value. The
> indexer applies to keys **not** named (and not otherwise resolved). In
> subtyping, a supertype named field `k` is checked against the subtype's named
> field if present, else against the subtype's covering index (§5.2 third bullet);
> a supertype indexer is checked against *both* the subtype's named fields whose
> key it admits *and* the subtype's indexes (§5.3).

This shadowing is the sound reading: a more specific named field is at least as
precise as the indexer's uniform rule. A consistency obligation is **not**
required between a record's own named field and its own indexer at construction
(M6's Open phase fixes the named field's type independently); but when such a
record is a *subtype* against a supertype indexer (§5.3 first bullet), the named
field's value is checked against the index value — that is where the named
field/indexer interaction is enforced, and it is enforced **in the supertype's
direction**, soundly.

### 5.6 Row obligations (open vs closed; reuse the CRow machinery)

The **row** decides whether the subtype may carry **extra named fields** beyond
those the supertype lists. M7 reuses the v5 row machinery (`TRowVar`,
`CRowExtend`/`CRowLacks`/`CRowClose`, and the **G8 soundness floor**) **unchanged**
— it adds no new row mechanism, only routes width surplus through the existing row
var:

- **Supertype row closed (`ρ_b = nil`):** the supertype's named-field set is
  exhaustive. Width subtyping still **admits forgetting** extra subtype fields (a
  wider subtype is fine); the closed supertype row only constrains that every
  supertype *required* field/index is covered (§5.2/§5.3). Extra subtype fields are
  dropped (forgotten), *not* rejected — closing the supertype row does not forbid
  the subtype from being wider; it forbids the *supertype* from being treated as
  open. (A closed row is about what *this* record promises, not about what a
  subtype may add.)
- **Supertype row open (`ρ_b` a `RowVar`):** the row var **absorbs** the surplus
  subtype fields via row unification (`CRowExtend`/`CRowClose`, unchanged). This is
  the open-record case: `{ x: T, ... }` accepts any record with at least `x: T`.
- **The G8 soundness floor (preserved).** A `CRowLacks` on an *unclosed* subtype
  row cannot confirm absence — assuming a field absent on an open row is unsound
  (op-sem § "Row polymorphism" S-Quiesce-CRowLacks). M7 inherits this floor: the
  §5.2 "field absent in subtype" branch is sound only against a **closed** subtype
  row (or an open row that is later closed and confirmed lacking the key); a
  required supertype field against an open, never-closed subtype row is a
  row-unresolved error, not a silent pass.

> **Width subtyping composes with the variance rule (the gating, normative).**
> Width (forgetting fields) and depth (per-field subtyping) are **gated by §3**:
> the extra fields are forgotten freely (width is always sound — a value with more
> fields is usable where fewer are needed), but each **common** field's obligation
> is the §3 variance subgoal (depth — `CSub` for readonly, `CEq` for mutable). The
> two are orthogonal: width never relaxes the per-field variance, and the variance
> never blocks forgetting an extra field. This is the precise composition the
> superseded all-invariant rule got wrong (it forgot fields correctly but forced
> *every* common field to `CEq`, blocking sound readonly covariance — Y6).

---

## 6. The M6 seam (variance on a sealed record; no phase redefinition)

M6 §6 hands M7 a clean axis. M7 honors the seam exactly:

- **M6 owns the phase.** A record is **Open** (mutable shape, off-lattice) during
  construction and **Sealed** (fixed shape, a lattice value) thereafter; the seal
  point and the bound-once ordering are M6's (M6 §1, §4). **M7 redefines none of
  this.** M7's field-variance rule applies **only to a SEALED record** — a record
  that is an M1 lattice value, the only kind subtyping observes (M6 §1.3 fact 1: no
  subtype query observes an Open record).
- **M6 guarantees one fixed type per field at the seal** (M6 §1.3 fact 3:
  `T-CTSet-Open-Equate` demotes re-assignment to `CEq`, so a field has *one* type
  when sealed). This is **the precondition M7's variance rule needs**: variance is
  a statement about a field's *fixed* type, which only exists post-seal. M7's rule
  could not be stated on an Open record (whose field types are still being
  unified).
- **The two mutabilities, kept distinct (Y6 split, M6 §6):**
  - **Shape mutability** (add/remove fields) — **M6's**, fully determined by phase
    and **enforced** (`T-CTSet-Sealed-Reject`). M7 says nothing about it.
  - **Field mutability** (is a present field reassignable → its variance) —
    **M7's**, the `readonly`/mutable axis of §3. M7's rule **replaces** the
    unconditional-CEq-invariance with readonly⇒covariant / mutable⇒invariant.
  These are **orthogonal axes**: a Sealed record (shape fixed) may still have
  *mutable* fields (reassignable in place, hence invariant) or *readonly* fields
  (not reassignable, hence covariant). Sealing fixes the *shape* (which keys
  exist); the per-field `readonly` attribute fixes the *variance* (whether each
  present key's value may be reassigned). M6 closed the shape axis of Y6; **M7
  closes the field-variance axis** — the two halves of Y6.
- **The merged (own ∪ `__index`-inherited) record's subtyping is M7's** (M6 §6
  last bullet). M6's §5 chain walk *resolves* a field's type (own record or via the
  `__index` chain); **M7 decides `t₁ <: t₂` over the resolved/observable field
  sets** using §3/§5. The seam: M6 supplies *which field types are observable*; M7
  supplies *the subtyping over them*. M7's width/variance rule applies to the
  observable field set exactly as to an own-only record — the chain-reachable
  fields participate in width and depth like any named field, with their own
  `readonly` attributes governing variance.

No phase rule, no seal rule, no `__index` rule is restated or changed in M7. M7
reconciles its field-variance rules **with** M6's phase ordering and §5 lookup,
per the M6 §6 contract.

---

## 7. Soundness alignment (constraints §A)

- **§A1 (soundness floor).** The field-variance rule never accepts an unproven
  relation: a mutable field demands `CEq` (the M1 atom/structural rules reject a
  non-equal pair), a readonly field demands `CSub` (routed through M1, including
  the emptiness procedure for negated field types). The mutable-covariance hole is
  **closed by construction** (§3.2): a mutable field is invariant, so the
  TypeScript-array unsoundness is unreachable through a record. A missing required
  field, a modifier incompatibility, an uncovered supertype index, and an
  unresolved row all **reject** (§4.1, §5.2, §5.3, §5.6), never widen.
- **§A2 (`unknown` never casts away).** Width subtyping forgets *extra* subtype
  fields (sound — narrowing the visible field set), never *invents* a field or
  widens a present field to `unknown`. An indexer to `unknown` is a *declared*
  uniform value type, not a cast-away.
- **§A3 (`any` does not exist) / §A4 (no internal force casts).** M7 introduces no
  `any` and no escape hatch. The variance rule **removes** force casts that the old
  all-invariant rule forced at the gen-pass (Y4's per-field-`CSub` workaround in
  `constrain.lua` becomes unnecessary — §8): the principled rule types those paths
  directly. No widening to `any`.
- **§A14 (single timeout).** M7 adds no new unbounded procedure: every obligation
  is a finite decomposition into M1 `CSub`/`CEq` on field/index/key/value types,
  each of which inherits M1's bounded emptiness budget when it carries non-trivial
  negation. The record decomposition itself is finite (over the finite `fields`
  map and `indexes` list). M7 tightens, never loosens, §A14.
- **B-series (scheduling/provenance).** Each re-emitted per-field/per-index
  obligation carries the originating record-subtype query's provenance, so a
  missing field, a variance mismatch, or an uncovered index blames the source
  expression (M1 §6).

No item here is closed by a hardcoded result: the variance rule, width subtyping,
the indexer obligations, and the optional-presence rule are all **substrate
mechanisms** (attribute-driven obligations reducing to M1 `<:`), not record-shaped
special cases — per the CLAUDE.md planning rules and the README cross-walk
discipline.

---

## 8. Closes

- **record-width-invariance** (`v5-gaps.md`):
  > *"T-CSub-Record-Width treats named fields as invariant (decomposes via CEq),
  > blocking literal widening (`$LitInt(1) <: integer`) and other covariant cases
  > through record subtyping."*

  Closed by the **field-variance rule** (§3): a `readonly` field decomposes via
  `CSub` (covariant), so literal widening through a record (`{readonly tag:
  "leaf"} <: {readonly tag: string}`) and every other readonly-covariant case now
  succeeds (§3.3). A *mutable* field still decomposes via `CEq` — correctly,
  because it is writable. The blanket invariance is replaced by an
  attribute-driven, soundness-justified rule. Mechanism (the `readonly`-governs-
  variance decomposition), not a per-case widening special case.

- **Y4** (`v5-gaps.md`):
  > *"Module export uses per-field CSub to dodge T-CSub-Record-Width's CEq
  > invariance; substrate workaround in gen-pass — constrain.lua:2543-2580."*

  Closed by the same field-variance rule: the gen-pass per-field-`CSub` workaround
  was the *symptom* of the missing variance rule (it manually emitted covariant
  obligations the substrate's all-`CEq` rule refused). With §3 in the substrate,
  the workaround is **deleted** — the gen-pass emits an ordinary record `CSub` and
  the substrate's variance rule produces the right per-field obligation. The
  workaround moves from gen-pass back into the principled substrate rule (mechanism,
  not a result).

- **Y6** (`v5-gaps.md`, field-variance half):
  > *"T-CSub-Record-Width uses CEq for named fields based on 'Invariant: fields are
  > mutable in v5.0' comment the rule doesn't enforce or check."*

  Y6 has two halves (per M6 §6 / README). **M6 closed the shape axis** (no field
  added/re-typed after seal, `T-CTSet-Sealed-Reject` — enforced). **M7 closes the
  field-variance axis**: the "fields are mutable → invariant" comment is now an
  *enforced rule* — a **mutable** field IS invariant (`CEq`), but the rule
  **checks the `readonly` attribute** and makes a readonly field covariant (`CSub`).
  The unenforced comment becomes the enforced, attribute-conditional §3 rule. The
  precondition (one fixed type per field at the seal) is M6's guarantee (§6).

- **prefix-scoping (record axis)** (`v5-gaps.md`):
  > *"Field-name encodings (`$idx_N`/`$pos_N`/`$opt_`/`$ro_`/`$spread_`/
  > `$computed_`/`$opaque_`) → structured field descriptors (NOT scoped)."*

  Closed for the **record axis** by the **three-region `TRecord` with structured
  descriptors** (§1, §4.4): `$opt_x` → `fields.x.optional = true`; `$ro_x` →
  `fields.x.readonly = true`; `$idx_N` → an `indexes[]` entry; `$opaque_K` → a
  single-key index `{key = Const(K)}`; `$pos_N`/`"1".."n"` → a `TPack` (M3, not a
  record); `$spread_` → M3's pack `rest`; `$computed_N` → a named field or index
  per the resolved key type (no key-mangle). Subtyping reads `fld.optional`/
  `fld.readonly` (real booleans dispatched on `tag`), never matches a name prefix.
  Mechanism (structured descriptors), not a `$`-string result. (The *type-name*
  axis of prefix-scoping — `$LitInt`/`$Idx`/`$Unit` etc. — is closed elsewhere:
  literals in M1 §1.1 / Spec C `TLiteral`, indexed access in M11, `$Unit` as the
  `unit` primitive in Spec C; M7 closes the **field-descriptor** axis only.)

Each closure is a **substrate mechanism**, not a hardcoded result, per the
CLAUDE.md planning rules and the README cross-walk discipline.

---

## 9. Migration / blast-radius note (for the later implementation program)

M7 changes the implemented v5 substrate. M7 performs **no** migration (the design
program writes no code); it records the cost. Much of the M7 shape **already
landed** in the v5 substrate as Spec C (commit `7a627c26`): the three-region
`TRecord`, the `Field`/`Index` descriptors, and the readonly⇒covariant /
mutable⇒invariant rule with the supertype-governs clause are **already specced
into op-sem** (§ "Principled literals and records"). M7's job is to **adopt that
as the unified design's realization** and reconcile it with M1's decomposition and
M6's seam. The remaining blast radius:

1. **Replace the superseded `T-CSub-Record-Width`** (op_sem.lua, the
   `dom(G) ⊆ dom(F)` + unconditional-`CEq` rule, op_sem.lua ~:255–262 / ~:673–696)
   with the **T-CSub-Record** variance rule (Spec C / §3, §5). This is the
   record-width-invariance / Y6 closure. The op_sem_alt twin must be re-encoded
   independently from this spec (parity).
2. **Delete the gen-pass Y4 workaround** (`constrain.lua:2543-2580`, the module-
   export per-field-`CSub`). With §3 in the substrate, the gen-pass emits a plain
   record `CSub`. This is a *removal*, gated on (1) landing first.
3. **Retire the `$`-field encodings** (`ann.lua:448-516`, `constrain.lua:1671,2277`):
   the producer emits the three-region `TRecord` with `Field`/`Index` descriptors
   directly (the Spec C correspondence table, §8). The `is_positional` predicate
   and `"1".."n"` record keys are dropped (positional → `TPack`, M3). This is the
   record axis of prefix-scoping; it is largely Spec C's already-specced migration.
4. **The row machinery is reused unchanged** (§5.6): `TRowVar`,
   `CRowExtend`/`CRowLacks`/`CRowClose`, and the G8 soundness floor are **kept, not
   rewritten** — M7 only routes width surplus through them. No new row mechanism.
5. **Keep, do not rewrite:** the Spec C `TRecord`/`TField`/`TIndex` node shape and
   walker treatment (§1.3 — already landed); the revised `T-CEq-Record` (§5.4 —
   already landed); the `atomic_subtype` literal-widening edges (M1 §3.1 — the
   record covariance composes with them, §3.3). These are the v5 substrate
   decisions M7 **reconciles in**, not against.

**Parity discipline (carries forward).** Both `op_sem.lua` and `op_sem_alt.lua`
must independently encode the field-variance rule (the readonly/mutable `CSub`/`CEq`
split), the key-contravariance/value-variance index split (§5.3), the
optional-presence domain rule (§4.1), and the width/row composition (§5.6). The
parity fixtures (a readonly-covariance fixture, a mutable-invariance-rejection
fixture, an indexer key-contravariance fixture, a named-field-shadows-indexer
fixture, an optional-presence fixture) are a deliverable of the implementation
program. M7 is written as relations + per-region obligations (not a single
reference implementation), so the two encodings remain possible and produce
byte-identical obligations.

**Behavior conservation (§A11).** The test suite stays green at every migration
commit. Staging: land the three-region `TRecord` + walker (Spec C — done) →
replace `T-CSub-Record-Width` with the variance rule (record-width-invariance/Y6,
strictly admits more readonly-covariant programs) → delete the Y4 gen-pass
workaround (after the rule lands) → retire the `$`-field encodings. Each a green
commit.

---

## 10. Open questions (for the reviewer — genuine forks not resolved unilaterally)

1. **The attribute surface sigil and syntax.** **DEFERRED — UX batch (§4.5),
   explicit per the plan.** `@name` vs `#name` (the `#`-meta-field collision,
   `type-system.md` §403), whether attributes carry arguments (§404), the exact
   arena representation of an open attribute list (§405). **No soundness content
   for M7's variance/presence rules.** M7 fixes the *semantic model* and the
   internal `Field`/`Index` descriptor shape; the surface lowers to setting those
   booleans. Decided once in a UX batch, not invented here.

2. **`optional` vs `T | nil` — keep distinct or coincide in Lua?** **M7 keeps
   distinct (§4.1); confirm against M9.** `{x?: integer}` (presence) and `{x:
   integer | nil}` (nullable value) are different type-level shapes that *coincide
   at Lua runtime* (absent key ≡ `nil` value). M7 keeps the presence axis (row /
   optional) distinct from the value axis (field type). Whether M9's narrowing
   ever needs to *unify* them (a `t.x ~= nil` guard narrowing an optional field to
   present) is an M9 detail; M7's lean is they stay distinct and M9 bridges via
   narrowing-as-intersection. Conservatively sound either way (keeping them
   distinct never admits an unsound relation). **Confirm jointly with M9.**

3. **Index-coverage backtracking (which witness covers which supertype index).**
   **DEFERRED — later extension (§5.3), adopted from Spec C's v5.0-conservative
   form.** When a supertype index `K` could be witnessed by several subtype named
   fields/indexes, M7 (like Spec C) emits the obligations that *do* match and errors
   on an uncovered closed-row index, rather than backtracking over witness
   assignments. This is **conservatively sound** (it rejects some valid programs,
   never accepts an invalid one — the §A1-safe direction). Full backtracking is a
   later extension owed when the corpus demands it; it would route through M1's
   emptiness/disjunction substrate, not a record special case.

4. **`$EachField` / mapped-type view of attributes.** **DEFERRED — confirm jointly
   with M8 (§4.3).** Whether a mapped/match transform sees `optional`/`readonly` as
   *descriptor fields* (inspectable/rewritable like value fields) or as a *separate
   attribute list* (`type-system.md` §406) is an **M8 match-type** mechanism over
   the M7 descriptor shape. M7 guarantees only that the attributes are **structured
   descriptor data** a transform *can* manipulate (not key-mangled prefixes); the
   transform's exact view is M8's to fix. **Confirm jointly with M8.**

5. **Width subtyping against a *generic* (unbound-tvar) supertype parameter.**
   **DEFERRED — confirm jointly with M6 §11.2 and M2.** When a record flows into a
   parameter that is an unbound tvar (not yet known to be record-typed), the seal
   (M6 §11.2) and the width/variance rule (here) both depend on *when the record is
   observed as a record*. M7's lean: the variance rule applies once the supertype
   tvar's bound rigidifies to a record (via M2's bound graph); until then the
   obligation is a bound-graph edge (M1 §5 / M2), not a record decomposition. This
   couples to M6's escape-point seal (§11.2) and M2's bound handling.
   **Conservatively sound** (no record decomposition against an unbound tvar — it
   becomes a bound, observed later). **Confirm jointly with M6/M2.**
