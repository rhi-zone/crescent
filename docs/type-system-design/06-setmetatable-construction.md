# M6 — `setmetatable`, construction-phase soundness, and `__index` chains

*Normative module spec of the unified type-system design. Depends on **M1**
(`01-lattice-and-subtyping.md`, the lattice / RDNF / complement / emptiness /
subtyping algorithm and its `4096` "too-complex" bail-out; a sealed record is a
value type / lattice atom) and **M4** (`04-hkt-kinds.md`, the kind system and the
§6.2 gating interface: an `__index` that is `App(F, A)` is kinded to `Type` and
β-reduced to a record before the field walk). M6 specifies the **open→sealed
table lifecycle generalized** (the construction phase, mutation safety, and the
soundness ordering that a table's type is fixed once sealed), the
**`setmetatable` soundness model** (the H4 fork — soundness is non-negotiable,
the HOW is decided here on the open→sealed phase basis), and **`__index` chain
walking** on missing-field lookup (closes G6) with its **cyclic-chain
termination guard** and its **M4 reduction interface**. It also fixes the
**method-dispatch interface** beyond `obj:method(...)` (P6) and the **M7 record
seam** (M6 references the record interface — named fields + the open/sealed
distinction — and finalizes **no** field-modifier / width-subtyping / mutability
rules; those are M7). Aligns to `docs/type-system.md` (philosophy, fixed) and
satisfies the soundness floor of `docs/typechecker-v5-constraints.md` §A.*

Primary sources reconciled here:

- **`docs/typechecker-v5-operational-semantics.md` § "Construction phase"** — the
  `CTableOpen` / `CTableSet` / `CTableSeal` constraint family and the phase map
  `Φ ∈ {Open, Sealed}` (op-sem § "Notation", `Φ` part of `σ`), `T-CTOpen`,
  `T-CTSet-{Open-Fresh, Open-Extend, Open-Equate, Sealed-Reject}`, `T-CTSeal`,
  `T-CTSeal-Nil-Reject`. **M6 generalizes this lifecycle** and grounds the
  `setmetatable` model on it; M6 does not edit the substrate.
- **`docs/typechecker-v5-operational-semantics.md` § "Method dispatch"** —
  `CMethodCall`, `T-CMCall-{Open-Stuck, Sealed-Field, Sealed-Missing}`, and the
  **explicitly-flagged spec gap**: *"The full `μ.__index` chain walk is out of
  v5.0 minimal scope … This needs an orchestrator decision before the CHKT
  op-sem extension lands (because chain-walking interacts with HKT-shaped
  metatables)."* (op-sem § "Method dispatch", and § "What this spec does NOT
  cover" item 3: *"Chain-walking is owed when CHKT lands."*). **M6 closes this
  gap** with the M4 reduction interface now in place.
- **`docs/typechecker-v5-constraints.md` §H4** — the `setmetatable`-post-
  construction soundness fork. Quoted in full (§4.1). **The question is HOW, not
  WHETHER** (A1 binds soundness); M6 decides HOW and presents the fork
  prominently as a user-decides confirmation (§11.1).
- **`docs/typechecker-v5-constraints.md` §D10** — *"`setmetatable` post-
  construction with type narrowing. Must be modeled SOUNDLY (see H4). — corpus,
  `lib/epoll/init.lua:14,99`."* The corpus pattern (`setmetatable(obj, self)`
  with the class table as metatable carrying `__index`, plus a `--[[:! epoll]]`
  force-cast) is the concrete D10 case M6's model must type without the force
  cast.
- **`docs/type-system.md`** — § "Follow the language" (*"`setmetatable(t,
  {__index = proto})` merges `proto`'s fields into `t`'s type"*; the module
  pattern *"tracked as open table, refined with each assignment"*), and the
  **construction-phase soundness ordering** in op-sem § "Soundness floor"
  (*"Per item 1's construction-phase model, record fields are mutable
  (CTableSet); covariant field subtyping under mutability is the well-known
  TypeScript-array unsoundness"*) — the bound-once / fixed-at-seal invariant M6
  generalizes.
- **`docs/v5-gaps.md` G6** (quoted §7), **P6** (quoted §8: method-dispatch edge
  cases), and **Y6** (the *"fields mutable in v5.0 invariant the rule doesn't
  enforce"* note — enforcement is **M7's**, but M6 records the seam, §6).
- **`docs/typechecker-rewrite-design.md` §1.4 / §7** — narrowing-as-intersection
  (the falsy-branch complement), the substrate M6 uses for `setmetatable`-with-
  narrowing (D10).

M1 owns the lattice, RDNF, complement, emptiness, and the bounded "too-complex"
budget. M4 owns kinds, CHKT β-reduction, and the guarantee that any operand
reaching the value lattice kinds to `Type`. **M6 redefines none of them.** M6
adds the **phase discipline** (a table is *Open* during construction, *Sealed*
thereafter; its type is fixed at the seal) and the **metatable-aware field/method
lookup** (the `__index` chain walk, with the M4 reduction interface and a cyclic
guard). The discipline in one sentence: **a table's value type is determined by
the close of its construction phase and is immutable thereafter; `setmetatable`
is the operation that closes the phase and fixes the type, including the
`__index`-reachable fields.**

---

## 1. The construction-phase model, generalized

### 1.1 Two phases, one soundness ordering

A table literal in Lua is **built field-by-field** and then used. The type system
mirrors this with a **two-phase lifecycle** on every table-typed variable,
generalizing the v5 `Φ ∈ {Open, Sealed}` phase map (op-sem § "Notation"):

- **Open** — the *construction phase*. The table's record shape is **still being
  determined**: fields may be added (`CTableSet` on a new key) and the type of an
  already-present field may be refined (`CTableSet` on an existing key, demoted to
  equality). The record shape is a *work-in-progress*, not yet a lattice citizen
  observable by subtyping.
- **Sealed** — the *use phase*. The table's record shape is **fixed**. It is now a
  **value type / M1 lattice atom** (M1 §1.1: "a sealed record is a value type"):
  it may be unioned, intersected, complemented, narrowed, passed to subtyping,
  and stored in a bound. **No field may be added or re-typed after the seal.**

The **soundness ordering** is the single load-bearing invariant:

> **Bound-once / fixed-at-seal (normative).** A table's type is **mutated only
> during its Open phase** and is **fixed at the moment it is Sealed**. After the
> seal, the type is immutable: it participates in subtyping as a fixed value, and
> any operation that would change its shape (add a field, re-type a field, change
> its metatable) is a **type error**, not a silent re-open.

This is exactly `type-system.md`'s "module pattern … tracked as open table,
refined with each assignment" generalized to *every* table, with the seal as the
explicit phase boundary. It is also the **reason record-field subtyping can be
discussed at all** in M7: a value can only be soundly compared (width, depth,
variance) once its shape is fixed, i.e. once Sealed. M6 owns the *ordering* (when
the shape is fixed); **M7 owns the field-level variance rules that apply to a
sealed record** (§6).

### 1.2 The generalized lifecycle constraints

M6 generalizes the v5 `CTable*` family (op-sem § "Construction phase"). The
constraint vocabulary is unchanged in *shape* — `CTableOpen`, `CTableSet`,
`CTableSeal` plus `CMethodCall` and the new `CMetaIndex` (§5) — but the rules are
restated as the normative lifecycle and reconciled with the M1 lattice and the
M4 reduction interface.

```
CTableOpen(?t)            introduce an Open empty record at ?t
CTableSet(?t, k, τ)       extend / refine ?t's row with field k : τ  (Open only)
CTableSeal(?t, ?μ)        flip ?t to Sealed, bind metatable ?μ
CMethodCall(?t, k, ?r)    dispatch method k through ?t (Sealed), bind result ?r
CMetaIndex(?t, k, ?r)     resolve field/method k through ?t's __index chain (§5)
```

**T-CTOpen** (adopted from op-sem, unchanged). Introduce an empty Open record.
Idempotent if `?t` already bound — gen may emit it defensively.

```
σ(?t) = unbound    Φ(?t) = Open
──────────────────────────────────────────────  T-CTOpen
σ ⊢ CTableOpen(?t) ⇒ ⟨σ[?t ↦ Record(∅) @ Open], ε, done⟩
```

**T-CTSet-Open-Fresh / -Open-Extend / -Open-Equate** (adopted from op-sem,
unchanged). Setting a field on an Open table: bind a fresh single-field record if
unbound; add the field if the key is new; **demote to `CEq(τ', τ)`** if the key is
already present (re-typing an existing field unifies it with the new value, the
v5 mutable-field-during-construction behavior). These three are the
construction-phase mutation rules; they fire **only in the Open phase**.

**T-CTSet-Sealed-Reject** (adopted from op-sem, unchanged, and now the *enforced*
soundness ordering). Setting a field on a Sealed table is an error.

```
σ(?t) = _ @ Sealed
──────────────────────────────────────────────  T-CTSet-Sealed-Reject
σ ⊢ CTableSet(?t, k, τ) ⇒ ⟨σ, ε, error("set on sealed table")⟩
```

This is the rule that **makes the bound-once invariant real**: once Sealed, no
`CTableSet` succeeds. The v5 substrate already has this rule; M6 elevates it from
an op-sem mechanism to the **normative statement of the soundness ordering** (and
notes that the *field-mutability* attribute carried *within* a sealed record —
whether a sealed field is itself reassignable — is **M7's** Y6 concern, §6, a
distinct axis from the table-shape phase).

### 1.3 Mutation safety during construction (why the Open phase is sound)

The Open phase permits mutation (`CTableSet` adds/refines fields); the question
is why this is sound given the lattice's invariant that a value type denotes a
fixed set of values. The answer is the **phase boundary**:

> **An Open record is not a lattice citizen.** While `Φ(?t) = Open`, `?t`'s record
> binding is a **work-in-progress shape**, not a value type. M1's subtyping,
> emptiness, narrowing, and bound-graph operations are defined over **value
> types** (kind `Type`, M4 §1.1). An Open record is *not yet* such a type: it has
> no fixed denotation, so it is **never observed by subtyping** while Open. The
> only constraints that touch an Open `?t` are `CTableSet` (refine), `CTableSeal`
> (close), and `CMethodCall`/`CMetaIndex` (which **park** while Open — §5.1,
> adopted `T-CMCall-Open-Stuck`). Mutation is therefore confined to a region
> where no subtype obligation can observe the intermediate shape.

This is the same boundary M4 draws between constructors and the lattice (M4 §1.1:
"the kind system keeps non-`Type` expressions off the lattice by construction")
and M3 draws between packs and the lattice (M3 §4): **an Open record, like a pack
or an unapplied constructor, is a structured staging entity that becomes a
lattice value only at a well-defined transition.** For the Open record that
transition is the seal. Concretely, soundness of mutation rests on three facts:

1. **No subtype query observes an Open record.** `CMethodCall`/`CMetaIndex` on an
   Open table **park** (`T-CMCall-Open-Stuck`, §5.1); a `CSub`/`CEq` whose side
   derefs to an Open record is a **solver-invariant violation** (gen never emits
   one — a table is sealed before it flows into a subtyping position), surfaced as
   an internal error, never silently compared. So the intermediate shapes are
   invisible to the relation that soundness is about.
2. **The seal is monotone and single-shot.** `Φ` only ever flows `Open → Sealed`,
   never back (op-sem § "Termination": `σ` extends monotonically; `Φ` is part of
   `σ`). The seal happens **at most once** per table (a second `CTableSeal` on an
   already-Sealed `?t` is a no-op `done`, op-sem `T-CTSeal`; re-sealing with a
   *different* metatable is the H4 question, decided §4). Monotone single-shot
   sealing is what lets the bound-graph cache (M2) and the wake machinery treat a
   Sealed record as a stable fact.
3. **Refinement-during-Open is equality, not subtyping.** `T-CTSet-Open-Equate`
   demotes a re-assignment to `CEq(τ', τ)` (op-sem) — the field's type is *unified*
   across writes, not widened/narrowed. So the Open phase never accumulates a
   covariant-under-mutation unsoundness (the TypeScript-array hole, op-sem
   § "Soundness floor"): a field written twice with `τ'` then `τ` must satisfy
   `τ' = τ`, fixing one type for the field before the seal. The variance of that
   fixed field *after* the seal is M7's rule (Y6); M6 guarantees only that the
   field has *one* type at the seal.

### 1.4 The seal point — where the type is fixed

The seal occurs at the syntactic point a table stops being constructed. In Lua
this is one of:

- **`setmetatable(t, mt)`** — the explicit seal (§4). The returned, sealed table
  has `t`'s constructed fields **plus** the `__index`-reachable fields of `mt`.
- **First escape into a use position** — when a table value flows into a position
  that observes its shape (passed as an argument with a record-typed parameter,
  returned where a record type is expected, stored in a typed field, indexed for
  read, method-dispatched). Gen emits a `CTableSeal(?t, ?μ)` with `?μ` an unbound
  metatable tvar (the table has no explicit metatable — its `__index` chain is
  empty) at the escape point, fixing the shape before the observation. This
  generalizes op-sem's `T-CTSeal` (where `?μ` "is allowed to be a `UVar` that may
  bind later"): a table never given a metatable seals with the **empty
  metatable** (no `__index`), and a table given one seals with that metatable.

The seal is the **observable phase boundary**; everything before it is
construction, everything after is use. This is the generalized open→sealed
lifecycle: **build (Open, mutable, off-lattice) → seal (fix the shape + the
metatable) → use (Sealed, immutable, lattice value).**

---

## 2. A sealed table's type includes its `__index`-reachable fields

The seal does not merely freeze the literally-written fields. Per `type-system.md`
(*"`setmetatable(t, {__index = proto})` merges `proto`'s fields into `t`'s
type"*), a sealed table's **observable field set** is its own fields **unioned
with the fields reachable through its metatable's `__index`** (§5 walks the
chain). M6 fixes the model:

> **A sealed table's type is `Record(F_own) @ Sealed` with a bound metatable `μ`.**
> A field/method lookup `t.k` (read) or `t:k(...)` (dispatch) resolves to
> `F_own[k]` if present; **otherwise it walks the `μ.__index` chain** (§5). The
> *type* of a sealed table is the own record plus the chain-reachable fields — but
> the chain is walked **lazily, at lookup time**, not eagerly flattened into
> `F_own` at the seal.

**Lazy chain walk, not eager flatten (normative).** The seal binds `μ`; it does
**not** copy `μ`'s `__index` fields into `F_own`. Lookup walks the chain on a
miss (§5). This is the principled choice for three reasons: (a) it matches Lua's
runtime semantics exactly (the `__index` chain is consulted at access time, and a
later mutation of the proto — during the proto's *own* Open phase — is reflected;
once both are sealed the result is stable); (b) it keeps the own-record small and
avoids quadratic blowup when many tables share one proto (the common OOP case —
the epoll corpus, where every instance shares the class table as `__index`); (c)
it composes cleanly with the M4 reduction interface — an `App(F,A)` `__index` is
reduced **at walk time** (§5.3), when `F` is determined, rather than forced to
reduce at the seal (which might be before `F` is known). The width/variance of
the *merged* view (own ∪ inherited) is **M7's** record-subtyping concern (§6);
M6 fixes the *lookup mechanism* (§5), not the merged record's subtyping.

---

## 3. The metatable interface

A metatable is itself a table value. M6 models only the **`__index`** metamethod
at the type level (the field/method-lookup metamethod); other metamethods
(`__newindex`, `__add`, …) are out of M6 scope and noted as OPEN-QUESTIONS
(§11.4). The `__index` of a sealed metatable is one of:

- **A record** `{ … }` — the proto table. Lookup misses on the child fall through
  to this record's fields (and, recursively, *its* metatable's `__index`, §5.2).
- **A function** `(t, k) -> v` — a computed index. The result type of a miss is the
  function's return type for key `k`; M6 models the **conservative** form: a
  function `__index` makes *every* missing key resolve to the function's return
  type (the function is opaque to the static key). This is sound (it never invents
  a field that does not resolve) and noted as refinable in §11.3.
- **An application `App(F, A)`** — an HKT-shaped metatable (M4 §6.2). This is
  **reduced to a record first** via the M4 interface (§5.3) and then treated as
  the record case.

The `__index` is read from the bound metatable `μ` at lookup time. If `μ` is an
unbound tvar at lookup (the table was sealed with a not-yet-determined metatable),
the lookup **parks** on `μ` (§5.1, reusing the existing watcher machinery) until
`μ` binds — never guessing a field. If `μ` is the empty metatable (no `__index`),
a miss is the terminal `no field`/`no method` error (§5.4).

---

## 4. The `setmetatable` soundness model (closes H4 — soundness non-negotiable)

### 4.1 The fork, quoted

> **H4. Sound model of `setmetatable`-post-construction.** Soundness is
> non-negotiable (A1). Question is HOW to model this pattern soundly, not WHETHER.
> Candidates: linear/affine "table-under-construction" → "table-sealed" types,
> construction-phase typing, restricted mutation patterns, declared-metatable-up-
> front. Downstream consequence on existing code is acceptable (refactor the
> libraries). — user this session; corpus has the pattern.
> *(`docs/typechecker-v5-constraints.md` §H4)*

The candidates collapse to two genuinely-different design bases (the others are
variants):

- **(A) Construction-phase / affine seal** — a table is Open (mutable) during
  construction and `setmetatable` is the operation that **seals** it (flips
  Open→Sealed, binds the metatable, fixes the type). This is the affine
  "table-under-construction → table-sealed" reading and *is* the construction-
  phase reading; they are the same basis (the affine "use-once" of the
  construction capability is exactly "seal at most once"). The substrate already
  leans this way (the `Φ ∈ {Open, Sealed}` map, `CTableSeal`).
- **(B) Declared-metatable-up-front** — a table must declare its metatable (its
  class / `__index` proto) **at allocation**, before any field is written, so the
  table is born with its full intended shape and `setmetatable` post-construction
  is either disallowed or a no-op type-identity.

### 4.2 The decision: Approach A (construction-phase / affine seal)

> **M6 decides Approach A: `setmetatable` is the seal operation of the open→sealed
> construction phase.** A table is Open and mutable until `setmetatable(t, mt)`,
> which (i) checks `t` is still Open (sealing a Sealed table with a *different*
> metatable is an error, §4.3), (ii) binds the metatable `mt` (with its
> `__index`), and (iii) flips `t` to Sealed, fixing `t`'s type to
> `Record(F_own) @ Sealed` with metatable `mt`. The sealed type's observable
> fields are `F_own` plus the `mt.__index`-reachable fields (§2, walked lazily
> §5).

This is recorded **prominently as a user-decides confirmation** in §11.1 — H4 was
flagged "user decides; designer must NOT default," so M6 *picks the principled
option consistent with the substrate and the soundness floor* and surfaces the
alternative (B) with the recommendation for the orchestrator to confirm. The
reasons A is the principled choice:

1. **It is the open→sealed model the program scoped M6 onto** (plan §M6, README
   M6: *"open→sealed table phase soundness"*). The substrate already carries `Φ`,
   `CTableSeal`, and the seal-fixes-the-type behavior. A is not a new mechanism;
   it is the **generalization of the mechanism already present** (§1). B would be
   a *different* mechanism (allocation-time metatable declaration) that the
   substrate does not have and that would require re-architecting table allocation
   in gen — a larger blast radius for less expressiveness.
2. **It types the corpus (D10) without a force cast.** The epoll pattern
   (`lib/epoll/init.lua`): build `obj` field-by-field (Open), then
   `return setmetatable(obj, self) --[[:! epoll]]`. Under A, `obj` is Open while
   its fields are written; `setmetatable(obj, self)` seals it, binding the class
   table `self` as the metatable. `self.__index = self` (the class table is its
   own `__index`, the standard Lua OOP idiom) means the sealed `obj`'s methods
   resolve through the chain to `self`'s methods (§5). The sealed type is `obj`'s
   data fields plus `self`'s methods — exactly `epoll` — so the **`--[[:! epoll]]`
   force cast becomes unnecessary** (it is the §A4-violating workaround the sound
   model removes). Under B, the corpus would have to be rewritten to declare the
   metatable at `obj` allocation, which is the "refactor the libraries" cost H4
   says is *acceptable* but which A avoids entirely.
3. **It is the affine reading made precise.** The "linear/affine table-under-
   construction" candidate is A under a different name: the *construction
   capability* (the right to mutate the shape) is **used up by the seal** — affine
   (at-most-once). `setmetatable` consumes it. After the seal there is no
   construction capability, so no mutation, so the bound-once invariant holds.
   M6's monotone single-shot `Φ` (§1.3) *is* the affine discipline; we state it as
   a phase transition rather than as linear types because the substrate's `Φ` map
   already realizes it and a full linear-type layer would buy nothing beyond
   "seal at most once," which `Φ` gives directly.
4. **It satisfies the soundness floor (A1) by construction.** The sealed type is
   fixed; no field is added or re-typed after the seal (`T-CTSet-Sealed-Reject`);
   the `__index`-reachable fields are resolved by a terminating walk (§5.5); no
   force cast, no `any`, no widening (§9). A1 ("never accept an unproven relation")
   holds because every post-seal lookup either resolves to a concrete field type
   or is a precise `no field` error.

### 4.3 Re-sealing, and `setmetatable(t, nil)`

- **Re-sealing with a *different* metatable is an error.** `setmetatable(t, mt₂)`
  on an already-Sealed `t` (sealed with `mt₁ ≠ mt₂`) **rejects** — it would change
  the fixed shape (the `__index`-reachable fields), violating bound-once. This
  generalizes `T-CTSet-Sealed-Reject` to the metatable axis: *the metatable is
  part of the sealed type and is as immutable as the fields.* (Re-sealing with the
  *same* metatable is the idempotent no-op `done`, op-sem `T-CTSeal`.) A program
  that genuinely needs to swap metatables post-construction is doing something the
  static model treats as a new table; this is the "refactor the library" case H4
  admits, and it is rare (the corpus has none).
- **`setmetatable(t, nil)` is rejected** (adopted from op-sem `T-CTSeal-Nil-
  Reject`, encoded at the stdlib-types boundary: `setmetatable : <T, M: Table>(T,
  M) -> Sealed<T, M>`, so passing `nil` for `M` surfaces as a `T-CEq-Mismatch`).
  Removing a metatable would un-fix the `__index`-reachable fields — the inverse
  of the seal — and is unsound under bound-once. Listed here for traceability; the
  mechanism is the stdlib signature, not a new rule.

### 4.4 `setmetatable` with narrowing (the D10 "with type narrowing" clause)

D10 names `setmetatable`-post-construction *"with type narrowing."* The narrowing
is M1's primitive (M1 §4, narrowing-as-intersection): after a `setmetatable` seal,
a subsequent guard (`if t.tag == "leaf"`) narrows the **sealed** type by
intersection with the discriminating type (`t & { tag: "leaf" }`) exactly as for
any sealed record — there is **no special `setmetatable`-narrowing rule**. The
seal produces a sealed value; narrowing operates on sealed values via M1. M6 adds
nothing here beyond confirming the seam: **sealing then narrowing is (seal via
§4) then (M1 §4 intersection)**, two composed mechanisms, no special case.

---

## 5. `__index` chain walking (closes G6)

### 5.1 The lookup constraint and its phases

Field/method lookup that misses on the own record walks the metatable's `__index`
chain. M6 introduces **`CMetaIndex(?t, k, ?r)`** — *resolve key `k` through `?t`'s
metatable chain, binding result `?r`* — as the constraint that performs the walk,
and reconciles the existing `CMethodCall` onto it:

- **`CMethodCall(?t, k, ?r)`** (method dispatch, `t:k(...)`) is **`CMetaIndex`
  specialized to a callable result**: it resolves `k` through the chain, then
  requires the resolved type to be an `Arrow` and binds `?r` to its return (the
  existing `T-CMCall-Sealed-Field` behavior, extended past the own record by the
  walk). A plain field read `t.k` emits `CMetaIndex` directly (and is then an
  M11 indexed-access on the resolved field type).

The phase rules (generalizing op-sem `T-CMCall-*` to the chain):

**T-Meta-Open-Stuck** (adopted from `T-CMCall-Open-Stuck`). Lookup on an Open
table parks — the shape is not yet fixed.

```
Φ(?t) = Open
──────────────────────────────────────────  T-Meta-Open-Stuck
σ ⊢ CMetaIndex(?t, k, ?r) ⇒ ⟨σ, ε, stuck⟩
```

The constraint moves to the inert set `I` watching `?t`; when `CTableSeal` flips
`?t`, the existing **S-Wake** fires and the lookup re-enters the worklist. This
reuses the substrate's watcher machinery — **no new wake substrate** (op-sem
§ "Interaction with … S-Wake").

**T-Meta-Sealed-Own** (adopted from `T-CMCall-Sealed-Field`, generalized to field
or method). Key present on the sealed own record: resolve to its type.

```
σ(?t) = Record(F) @ Sealed    F[k] = τ
─────────────────────────────────────────────────  T-Meta-Sealed-Own
σ ⊢ CMetaIndex(?t, k, ?r) ⇒ ⟨σ, [CEq(?r, τ)], done⟩
```

**T-Meta-Sealed-Miss** — the headline new rule (G6). Key absent from the own
record: **walk the `__index` chain** (§5.2).

```
σ(?t) = Record(F) @ Sealed    k ∉ dom(F)    μ = metatable(?t)
─────────────────────────────────────────────────────────────────  T-Meta-Sealed-Miss
σ ⊢ CMetaIndex(?t, k, ?r) ⇒ walk(μ, k, ?r, visited = {?t})
```

This **replaces** the v5 `T-CMCall-Sealed-Missing` ("reject, no method `k`"), which
was the explicitly-flagged G6 stub. The walk is defined next.

### 5.2 The walk

`walk(μ, k, ?r, visited)` resolves `k` through the metatable `μ`'s `__index`,
recursively, with a **cycle-visited set** for termination (§5.5):

```
walk(μ, k, ?r, visited):
  if μ is unbound (a tvar):                      -- metatable not yet determined
      PARK on μ; re-enter walk when μ binds       (T-Meta-Park)
  ix := μ.__index
  if μ has no __index (empty metatable):
      ERROR "no field/method k"                   (T-Meta-Terminal-Miss, §5.4)
  case ix of
    Record(F'):                                   -- proto table
      if k ∈ dom(F'):  emit CEq(?r, F'[k]); done  (T-Meta-Chain-Found)
      else:
          μ' := metatable(ix proto's own table)   -- the proto's own metatable
          if μ' already in visited:  ERROR cyclic __index   (T-Meta-Cycle, §5.5)
          walk(μ', k, ?r, visited ∪ {ix})         (T-Meta-Chain-Recur)
    Function((t,k) -> v):                          -- computed index
      emit CEq(?r, v); done                        (T-Meta-Func, conservative §3)
    App(F, A):                                      -- HKT-shaped metatable
      reduce via M4 (§5.3), then re-dispatch on the resulting Record
    UVar:                                           -- __index itself undetermined
      PARK on it; re-enter when bound              (T-Meta-Park)
```

The walk is **the mechanism that closes G6**: a sealed-table missing-field lookup
now traverses the `__index` chain instead of immediately erroring. It is
name-agnostic (no `pcall`/`coroutine`-shaped handler), structural (it dispatches
on the *shape* of `__index`, not on any name), and terminating (§5.5).

### 5.3 The M4 reduction interface (an `App(F,A)` `__index` reduces first)

When `__index` is `App(F, A)` (an HKT-shaped metatable — M4 §6.2 reserved this
exact seam: *"a metatable whose `__index` is `App(F, A)` is resolved by kinding
the application to `Type` and β-reducing it to a concrete record before the field
walk"*), the walk **invokes M4's interface**:

> **M6 calls M4 to (a) kind-check `App(F, A)` to `Type` (M4 §1.3 `K-App`) and (b)
> β-reduce it (`T-CHKT-Reduce`, M4 §3.2) to a concrete `Record` of kind `Type`.**
> The walk then dispatches on that record (the `Record(F')` case). M6 **never
> walks an unreduced or ill-kinded `__index`**: if `App(F, A)` does not kind to
> `Type` it is a `kind_mismatch` (M4 §1.4) at the metatable's provenance; if `F`
> is an unbound constructor variable the reduction **parks via M4's CHKT/HOUnify
> head-rigidity machinery** (M4 §3.2) until `F`'s head rigidifies — the same
> "re-emit, M4 decides" seam M4 §3.3 specifies for applied-constructor bounds.

This is precisely the dependency the program records (M6 *depends on M4*; M4 §6.2
*gates M6*): the chain walk is sound only because **kinding guarantees the walked
`__index` target is a fully-applied `Type`-kinded record** (M4 §6.2 "M6 never
walks an unreduced or ill-kinded `__index`; kinding guarantees the walked target
is a `Type`-kinded record"). M6 holds up its end by routing every `App`-headed
`__index` through M4's reduction before treating it as a record.

### 5.4 Terminal miss — the precise error

When the walk reaches a metatable with no `__index` (or an empty metatable) and
the key is still unresolved, the lookup is a **precise diagnostic**, not a silent
acceptance:

```
walk reaches μ with no __index, k unresolved
──────────────────────────────────────────────────  T-Meta-Terminal-Miss
ERROR "no field/method k" at the lookup provenance
```

This is the **sound terminal** (§A1): a key that resolves nowhere on the chain is
a real error, blamed at the lookup site (M1 §6 B-series provenance). It never
widens to `unknown`/`any` and never invents a field. (It is the chain-walking
generalization of the v5 `T-CMCall-Sealed-Missing` error — same disposition,
reached only after the whole chain is exhausted rather than after the own record.)

### 5.5 Termination — the cyclic `__index` guard (parity-pinned)

Lua permits cyclic `__index` chains (`a.__index = b; b.__index = a`); a naive walk
loops forever. M6 mandates a **visited set keyed by metatable identity**:

> **The walk carries a `visited` set of metatable identities (union-find roots of
> the metatable tvars / hash-cons identities of concrete metatable records). On
> entering `walk(μ', …)`, if `μ'`'s identity is already in `visited`, the walk
> halts with a `cyclic __index` error (T-Meta-Cycle). Otherwise `μ'` is added to
> `visited` before recursing.**

This guarantees termination: the chain has finitely many distinct metatable
identities (σ allocates finitely many tvars; concrete metatables are
hash-consed — M1 §2.2), so the visited set grows monotonically to a bounded size
and the walk halts after at most `|distinct metatables|` steps. The guard is
**parity-load-bearing**: both interpreters (`op_sem.lua` / `op_sem_alt.lua`) must
key `visited` **identically** (union-find root id for tvars, hash-cons id for
concrete records — the *same* identity scheme M1 §5.1 pins for the subtype cache)
so they detect the cycle at the *same* step and emit the *same* `cyclic __index`
diagnostic. A cyclic chain is a **real program bug** (an infinite metatable loop
has no terminating field lookup at runtime either) surfaced precisely, not
silently tolerated. The `cyclic __index` error is a distinct diagnostic class.

> **Soundness-floor reconciliation (§A1, §A14).** The walk's bound is a
> **structural** count (distinct metatable identities on the chain), not a
> wall-clock or step-budget timeout — so it is *not* M1's `4096` emptiness
> bail-out (M4 §2.4 draws the same line: the always-decidable parts never pay for
> the sometimes-hard parts). The walk is *outright decidable and terminating* via
> the visited set; it never invokes M1's emptiness procedure unless a *resolved
> field's type* itself carries non-trivial negation (rare; then that field's
> `CEq`/`CSub` routes through M1 and inherits M1's budget). The chain walk
> tightens, never loosens, §A14: a cyclic chain is cut at the first repeat and
> reported, keeping the per-file `timeout 30` satisfiable on any host.

---

## 6. The M7 record seam (no record-width / mutability / attribute rules finalized here)

M6 references the **record interface** — a record with **named fields** plus the
**open/sealed distinction** — and finalizes **no** field-modifier, width-
subtyping, or mutability rules. Those are **M7** (`07-record-mutability.md`, the
next module). The seam, stated so M7 reconciles cleanly:

- **M6 owns the *phase* (when the shape is fixed): Open vs Sealed, the seal point,
  bound-once.** A record's *transition* from mutable-during-construction to
  fixed-at-seal is M6's. The soundness ordering (§1.1) is the M6 contribution M7
  builds on.
- **M7 owns the *field-level rules on a sealed record*:** the readonly⇒covariant /
  mutable⇒invariant variance rule, width subtyping via open/closed rows, field
  attributes (optional, readonly), named-fields-plus-indexer mixtures, and the
  indexer `{[K]:V}` vs open-row `...` distinction. M6 says **nothing** normative
  about these.
- **The Y6 reconciliation (explicit).** `v5-gaps.md` Y6 notes the v5 substrate's
  *"T-CSub-Record-Width uses CEq for named fields based on a 'fields are mutable in
  v5.0' comment the rule doesn't enforce or check."* M6 distinguishes **two
  different mutabilities** so M7 inherits a clean axis:
  - **Shape mutability** (can fields be *added/removed*) — **M6's**, and **fully
    determined by phase**: Open = shape-mutable, Sealed = shape-fixed
    (`T-CTSet-Sealed-Reject`). M6 *enforces* this (the rejection rule), closing the
    "comment not enforced" half of Y6 *for the shape axis*.
  - **Field mutability** (can a present field be *reassigned*, and therefore is its
    type invariant or covariant under subtyping) — **M7's**. The v5 "fields are
    mutable in v5.0 → invariant via CEq" decision is the **field-variance** axis;
    M7 replaces the unconditional-invariance-by-CEq with the readonly⇒covariant /
    mutable⇒invariant rule. M6 guarantees only that each field has **one fixed type
    at the seal** (§1.3 fact 3), which is the precondition M7's variance rule needs;
    M6 does **not** decide the variance.
- **The merged (own ∪ inherited) record's subtyping is M7's.** §2/§5 produce, on a
  lookup, the field type from the own record or the chain. The *subtyping of the
  sealed table as a whole* (including width over the chain-reachable fields) is
  M7's width/variance rule applied to the observable field set. M6 supplies the
  **lookup** (which field types are observable); M7 supplies the **subtyping** over
  them. The seam is: **M6 resolves `t.k`'s type (own or via §5 walk); M7 decides
  `t₁ <: t₂` over the resolved field sets.**

No record-width-invariance, no field-attribute, no indexer-vs-open-row rule is
stated in M6. M7 reconciles its rules with M6's phase ordering and the §5 lookup.

---

## 7. Closes — G6

- **G6** (`v5-gaps.md`):
  > *"`μ.__index` chain walk missing: sealed-table missing-field lookup does not
  > traverse `__index` chain — docs/typechecker-v5-handoff-2026-05-26.md §6."*

  Closed by the **`CMetaIndex` chain-walk mechanism** (§5): a sealed-table miss
  walks the `μ.__index` chain (§5.2), dispatching structurally on the shape of
  `__index` (record / function / `App(F,A)`), reducing an HKT-shaped `__index`
  via the **M4 reduction interface** (§5.3), terminating via a **metatable-
  identity visited set** (§5.5), and erroring precisely at a terminal miss
  (§5.4). This **replaces** the v5 `T-CMCall-Sealed-Missing` reject stub that was
  the gap. Mechanism (a structural, terminating walk), not a name-keyed handler
  and not a hardcoded result — per the CLAUDE.md planning rules and the README
  cross-walk discipline.

---

## 8. Method-dispatch interface beyond `obj:method(...)` (P6 — noted)

> **P6 gap text** (`v5-gaps.md`): *"Method dispatch edge cases beyond simple
> `obj:method(...)` not modelled — lib/type/static-v5/constrain.lua:37."*

M6 fixes the **interface** for method dispatch (the P6 closure proper is the
gen-pass work that emits the constraints; M6 supplies the constraint they lower
onto, so the closure is a *mechanism* not a per-edge-case handler):

- **`obj:method(...)`** — sugar for `obj.method(obj, ...)`: emit
  `CMethodCall(?obj, "method", ?r)` (resolves `method` through §5, requires an
  `Arrow`, binds `?r` to its return) **and** unify the implicit `self` argument
  with `?obj` (the first parameter is `obj`). This is the existing path.
- **`obj.method(...)`** (no colon, explicit-`self` call) — resolve `obj.method`'s
  type via `CMetaIndex` (§5), then an ordinary `CSub` of the supplied arguments
  against the arrow's argument pack (M3). No `self`-injection. The difference from
  the colon form is **only the `self` argument**, not a different dispatch
  mechanism — both resolve the method type via the same §5 walk.
- **`t.k` field read** (method-valued or not) — `CMetaIndex(?t, "k", ?r)` (§5),
  then M11 indexed-access on `?r` if further indexed. A method stored in a field
  and read (not dispatched) is just a field read of arrow type; no special case.
- **Chained `a:b():c()`** — left-to-right: `a:b()` resolves+binds `?r₁`; `?r₁:c()`
  resolves through `?r₁`'s metatable chain. Each link is one `CMethodCall`; the
  chain of *calls* (distinct from the `__index` chain of §5) is just sequential
  constraint emission, terminating because each emits a structurally-smaller
  obligation.
- **Dispatch on a *union* receiver** (`(A | B):method()`) — decomposes by M1's
  `A | B <: C` rule (M1 §3.1): the method must resolve (via §5) on **both** arms
  to a compatible arrow; the result is the join (union) of the two return types.
  No union-receiver special case — it is M1's union decomposition applied to the
  receiver of a `CMethodCall`.

The unifying statement: **every method dispatch lowers to a §5 `CMetaIndex`/
`CMethodCall` plus M3 argument-pack subtyping plus (for `:`) `self`-unification.**
The "edge cases beyond `obj:method`" are *combinations* of these three
mechanisms, not new dispatch rules — so P6's gen-pass closure emits the same three
constraints in different arrangements, never a per-edge-case handler. M6 fixes the
interface; the gen-pass emission (the P6 line in `constrain.lua`) is implementation
work that consumes it.

---

## 9. Soundness alignment (constraints §A)

- **§A1 (soundness floor).** The sealed type is fixed at the seal and immutable
  thereafter (`T-CTSet-Sealed-Reject`, §4.3 re-seal rejection); a chain lookup
  either resolves to a concrete field type or is a **precise error** (§5.4),
  never an unproven acceptance. The cyclic guard (§5.5) rejects a non-terminating
  chain rather than looping. No post-seal mutation, no force-accept.
- **§A2 (`unknown` never casts away).** A terminal miss errors (§5.4); it does
  **not** widen the result to `unknown`. A function `__index` resolves to the
  function's *declared* return type (§3), not to `unknown`.
- **§A3 (`any` does not exist) / §A4 (no internal force casts).** The model
  **removes** the corpus's `--[[:! epoll]]` force cast (§4.2) by typing the
  pattern soundly — it does not introduce one. No `any`, no escape hatch; the
  walk rejects rather than widens.
- **§A14 (single timeout).** The walk's structural termination (§5.5) keeps the
  per-file `timeout 30` satisfiable; it is decidable and does not invoke M1's
  emptiness bail-out (it tightens, never loosens, §A14 — §5.5 reconciliation box).
- **B-series (scheduling / provenance).** `CMetaIndex` parks on `?t`/`μ` and wakes
  via the existing **S-Wake** (no new wake substrate, §5.1); every re-emitted
  `CEq(?r, τ)` carries the lookup's provenance so a miss / cycle / kind error
  blames the source expression (§5.4, §5.3).

No item here is closed by a hardcoded result: G6 (§7) is closed by the
**structural, terminating chain-walk** (a substrate mechanism), and the
`setmetatable` model (§4) is the **generalized open→sealed phase discipline**, not
a `setmetatable`-shaped special case.

---

## 10. Migration / blast-radius note (for the later implementation program)

M6 changes the implemented v5 substrate. M6 performs **no** migration (the design
program writes no code); it records the cost.

1. **Add `CMetaIndex` and generalize `CMethodCall` onto the walk.** The new
   `CMetaIndex(?t, k, ?r)` constraint (§5.1) and the `walk` routine (§5.2) replace
   `T-CMCall-Sealed-Missing`'s reject stub (`op_sem.lua`
   `rule_T_CMCall_Sealed_Missing`, and the op_sem_alt twin). `CMethodCall` becomes
   `CMetaIndex` specialized to a callable result (§5.1). This is the **G6 closure**
   and the largest single change.
2. **The walk's cyclic-visited set** (§5.5) is new state on the walk, keyed by the
   metatable-identity scheme M1 §5.1 already pins (union-find root / hash-cons id).
   Both interpreters encode it identically (parity, §5.5).
3. **The M4 reduction call** (§5.3) is a new edge from the walk into M4's
   `T-CHKT-Reduce` / kinding. It requires M4 landed first (the
   substrate-before-consumers ordering: M4 gates M6). No M6 code in M4; M6 calls
   M4's existing β-reduction (`instantiate`) and kinding on the `App`-headed
   `__index`.
4. **The seal already exists; the generalizations are small.** `T-CTOpen`,
   `T-CTSet-*`, `T-CTSeal`, the `Φ` map, and `T-CTSeal-Nil-Reject` are **adopted
   unchanged** (§1.2, §4.3). The additions are: the **escape-point seal** (§1.4 —
   gen emits `CTableSeal` with an empty metatable when an unmetatabled table
   escapes into a use position; new gen-pass work), and the **re-seal-with-
   different-metatable rejection** (§4.3 — a phase/metatable check extending
   `T-CTSet-Sealed-Reject` to the metatable axis).
5. **Keep, do not rewrite:** the `Φ ∈ {Open, Sealed}` phase map and the monotone
   single-shot seal (op-sem § "Termination"); the `T-CTOpen`/`T-CTSet-*` Open-phase
   mutation rules (§1.2); the `T-CMCall-Open-Stuck` park-and-S-Wake machinery
   (§5.1 — reused, not replaced); the `setmetatable : <T, M: Table>(T, M) ->
   Sealed<T, M>` stdlib signature (§4.3 — the nil-reject mechanism). These are the
   v5 substrate decisions M6 **reconciles in**, not against.

**Parity discipline (carries forward).** Both `op_sem.lua` and `op_sem_alt.lua`
must independently encode the `CMetaIndex` walk, the cyclic-visited set with the
pinned identity scheme (§5.5), and the M4 reduction edge; the parity fixtures
(a cyclic-`__index` fixture and an HKT-`__index` fixture are obvious additions) are
a deliverable of the implementation program. M6 is written as relations + a
terminating walk (not a single reference implementation), so the two encodings
remain possible and detect cycles / reduce HKT metatables identically.

**Behavior conservation (§A11).** The test suite stays green at every migration
commit. Staging: add `CMetaIndex` + own-record resolution (behavior-conserving
with `T-CMCall-Sealed-Field`) → the chain walk + cyclic guard (G6, replacing the
reject stub — strictly admits more programs) → the M4 reduction edge (after M4) →
the escape-point seal + re-seal rejection. Each a green commit.

---

## 11. Open questions (for the reviewer — genuine forks not resolved unilaterally)

### 11.1 The H4 `setmetatable` soundness fork — PROMINENT, for user confirmation

**This is the H4 user-decides fork. M6 picked the principled option; the
orchestrator should surface it for confirmation.**

- **The fork (H4, `docs/typechecker-v5-constraints.md`):** how to model
  `setmetatable`-post-construction soundly. Two genuine bases (§4.1):
  - **(A) Construction-phase / affine seal** — table is Open (mutable) during
    construction; `setmetatable` is the **seal** that fixes the type and binds the
    metatable. *(= the affine "table-under-construction → table-sealed" candidate;
    the substrate already leans this way via `Φ`.)*
  - **(B) Declared-metatable-up-front** — the metatable / class is declared at
    allocation, before fields are written; `setmetatable` post-construction is
    disallowed or a no-op identity.
- **M6's recommendation: (A).** Reasons (§4.2): it is the open→sealed model the
  program scoped M6 onto and that the substrate already realizes (smallest blast
  radius — generalize, don't replace); it types the D10 corpus (`lib/epoll`)
  **without** the `--[[:! epoll]]` force cast; it is the affine reading made
  precise (the construction capability is consumed by the seal); it satisfies A1
  by construction. (B) would require allocation-time metatable declaration the
  substrate lacks and would force a corpus rewrite that (A) avoids.
- **Downstream consequence (acceptable per H4):** under (A), a program that
  genuinely swaps a metatable post-construction (re-seal with a *different*
  metatable, §4.3) is rejected and must be refactored — H4 says this is acceptable
  ("refactor the libraries"); the corpus has no such case. Under (B) the consequence
  is broader (every OOP allocation site changes shape).
- **Confirm:** approve **(A)**, or direct **(B)**. M6 is written on (A); adopting
  (B) would re-open §1, §4, and the seal-point model (§1.4).

### 11.2 The escape-point seal — exact trigger set

**DEFERRED — confirm jointly with M7 and M9.** §1.4 seals a table at "first escape
into a use position." The precise set of escape triggers (argument with a
record-typed parameter, return, typed-field store, read-index, method-dispatch) is
listed there, but the *exact* boundary — e.g. does passing a table to a
**generic** parameter (an unbound tvar, not yet known to be record-typed) seal it,
or only a parameter known to be record-typed? — couples to M7's width-subtyping
(when is a record *observed*) and M9's narrowing (a narrowed read is an
observation). M6's lean: seal on **any** observation that requires the shape
(conservative — seals early, never observes an Open record); the precise
generic-parameter case is confirmed with M7. Conservatively sound either way
(sealing earlier only fixes the type sooner; it never admits a mutation that
unsoundness needs).

### 11.3 Function `__index` precision

**DEFERRED — refinable, no soundness content.** §3 models a function `__index`
`(t,k) -> v` conservatively: *every* missing key resolves to the function's return
type `v`. A more precise model would use the function's parameter type for `k`
(e.g. a function typed `(t, "foo" | "bar") -> V` resolves only `foo`/`bar` and
misses others). The conservative model is **sound** (it never invents a field that
does not resolve; it may over-accept a key the function would error on at runtime
— but that is the function's contract, not the table's shape). Refining it is an
M11-adjacent indexed-access concern (the function `__index` is effectively an
index signature `{[K]: V}`); deferred to where index signatures are specified
(M7/M11), with M6's conservative form as the floor.

### 11.4 Other metamethods (`__newindex`, `__call`, arithmetic) — OUT OF SCOPE

**Flagged, not opened.** M6 models only `__index` (the field/method-lookup
metamethod — the one G6 names and the corpus uses). `__newindex` (write-miss
interception), `__call` (making a table callable), and the arithmetic/comparison
metamethods (`__add`, `__eq`, …) are **not** modelled in M6. They are recorded as
an explicit out-of-scope marker (in the spirit of M4 §11.4 putting kind
polymorphism out of scope): a future need is a **new substrate decision** (a new
metamethod-aware rule, escalated), not a silent extension of the walk. No current
corpus item beyond `__index` needs them; `__newindex` in particular would
interact with the bound-once invariant (a write-miss on a sealed table) and the
M7 field-mutability axis, so it is best decided *after* M7 fixes field mutability.

### 11.5 Sealing a shared metatable that is still Open

**DEFERRED — confirm at implementation.** In the OOP idiom the metatable is a
class table that may itself still be Open when the first instance is sealed
against it (the class is built, instances created, more class methods added
later). §2's **lazy** chain walk handles this correctly *in principle* (the walk
reads the proto's fields at lookup time, so methods added to the still-Open class
before *it* seals are visible) — but the **ordering** (an instance lookup parking
until the *class* metatable seals, §5.2 `T-Meta-Park` on an unbound/Open `μ`)
needs the implementation to confirm the park-on-Open-metatable wakes correctly
when the class seals. M6's lean: `T-Meta-Park` parks on the metatable's `?t`
exactly as `T-Meta-Open-Stuck` parks on the child's `?t`, and the **same S-Wake**
fires when the metatable seals — no new mechanism. Confirmed at implementation
(a parity fixture: instance sealed before class, class method added then sealed,
instance lookup resolves). Conservatively sound (the lookup parks rather than
resolving against an unfixed metatable).
