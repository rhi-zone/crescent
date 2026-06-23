# Decision: metatable representation — keep the static `tmeta`/`merge_fields` model; reject first-class/dynamic-metatable overhauls

**Status:** resolved — June 2026 (design-it-twice: 4 decorrelated candidate
designs + 4 adversarial judges, all grounding in `proof/*.v`).
**Verdict:** the existing static encoding stays. No first-class/dynamic-metatable
representation is built now.

---

## Decision

Metatables remain a **term-subterm** (`tmeta own proto`) **flattened to a plain
`BRec`** via `merge_fields` (proof-kernel increments 21–25). `subtype.v` / `ssub.v`
remain **byte-unmodified**, exactly as every shipped metatable feature has been. No
first-class or dynamic-metatable representation is introduced.

This decision exists to stop the four candidate overhauls below from being
re-litigated. They were each weighed against the actual proof development and each
fails for a concrete, code-grounded reason.

---

## The four rejected candidates (with the fatal reason)

- **C1 — reserved `@meta` field + "one resolution mechanism".** Making the
  metatable an ordinary `BRec` field forces the frozen `srec` width rule to either
  **leak/forge** the metatable (a user can just write the `@meta` field; width
  subtyping cannot reserve a key) **or edit the frozen `subtype.v`/`ssub.v`**. The
  sentinel-key exclusion that would prevent this is a name-keyed handler
  (forbidden). The "one mechanism" unification is cosmetic: `__index`-as-table is a
  key-indexed projection (needs `merge_fields`, not an arrow), and binary operators
  carry a load-bearing **`BAtom`-left disjointness invariant** that preservation
  depends on. The mechanisms are genuinely distinct; collapsing them is a rename,
  not a unification.

- **C2 — store-registry (parallel metastore + a fixed metatable-slot type `MS`).**
  A freshly-allocated table's metatable-slot type must be **fixed at alloc**;
  `BTop` is dequiv to "no `BRec`", so the overwhelmingly common case
  `t = {}; setmetatable(t, mt)` is **untypeable**. The invariant slot only permits
  installing a metatable of the **exact declared shape** — no subclassing, no
  conditional — so it is dynamic in name only. It is also a ~197-lemma /
  75-step-rule rewrite of an already-`Qed`'d metatheory.

- **C3 — type-level `BRecMt` constructor.** Dominated by the status quo. Git
  history shows every metatable feature shipped with `subtype.v`/`ssub.v`
  **byte-unmodified** by flattening to `BRec`. `BRecMt` edits the **frozen kernel**
  in ~9 fixpoints, and the `SsRecMtForget` rule grafts the operational-soundness gap
  back into `ssub` while its **inert denotation hides that gap from `ssub_sound`
  (silent unsoundness)** — all to deliver an *inert* metatable that still cannot
  model the one genuinely-open axis: first-class metatable **values** for dynamic
  mutation, which need a `V`/`denote`-level value, not a type refinement.

- **C4 — desugar into the records-of-refs core.** Dispatch desugaring is **strictly
  lossier**: a function-valued `__index` narrows to `BArrow BBot BTop` → returns
  `BTop`, versus `tmeta`'s exact type. It is blocked on the same substrate the
  status quo is, and it replaces flat, already-`Qed`'d metatheory with a
  binder-heavy, unproven elaboration + simulation. Not a base to build on.

---

## The reframe (the key finding)

All four candidates shared the **wrong premise** that the job was "represent dynamic
metatables." It is not. The static `tmeta`/`merge_fields` model **already** handles
prototype-OOP method inheritance with **exact types** and a **frozen kernel**:

- Evidence: `oop_inherited_typed` in `proof/typing.v` types an inherited method at
  its **exact** type (not a widened arrow).
- The runtime miss is resolved by the existing **`SMetaProjProto`** fall-through —
  never by an absent-key read.

The genuinely-open frontier is **narrower and substrate-blocked, not
representation-blocked**. Picking any of C1–C4 would build a new representation to
solve a problem the current representation does not have, while leaving the real
substrate gaps untouched.

---

## The one clean graft (kept for later, gated)

`setmetatable` / `getmetatable` can be modeled **without any new core constructor and
without touching `subtype.v`**, over a reserved `__meta` ref field:

- `setmetatable(t, mt)  ≈  tassign (tproj t "__meta") mt`  (return `t`)
- `getmetatable(t)      ≈  tderef (tproj t "__meta")`

This is pure existing `TAssign` / `TProj` / `TDeref`.

**Caveat (load-bearing):** this stores and retrieves the metatable *value* but does
**not by itself** unify dynamic dispatch with the static `tmeta` path. Adopting it
coherently — so that dispatch *reads the stored metatable* — is **gated on the
absent-key / index-signature substrate below**. Without that substrate it is a
**parallel encoding** of metatables, which is worse than not having it.

---

## The real substrate prerequisites (what the dynamic-metatable frontier is blocked on)

Framed as substrate needs, not result deficits:

1. **Sound optional / absent-key field reads** — read a possibly-absent key
   yielding `T | nil`. Subtlety: for a **closed** record an absent key is exactly
   `nil`; for the current **open** `BRec` ("other keys allowed") an absent key
   *might* be present, so this is entangled with the open-vs-closed-record /
   index-signature distinction. (This is already the deferred "rawget on a key
   absent from own returning `nil`" item — proof-kernel increment 25.)

2. **Index signatures `{[K]: V}` in `BTy`** — deferred per `subtype.v`'s comment;
   `BRec` is a fixed finite key list. Unlike `BRecMt`, this has a **real
   denotation** (tables where every `K`-typed key maps to a `V`-typed value) and a
   real subtyping semantics — a justified, denotation-bearing kernel extension. But
   it is **high-stakes** (touches the frozen, reality-validated core) and deserves
   its **own design pass** before any code.

3. **Precise function-type narrowing (intersection-typed `ttypetest`)** — for
   function-valued `__index` / `__newindex`. Already-deferred substrate; otherwise
   the metamethod narrows to `BArrow BBot BTop` and returns `BTop`.

---

## Ordering consequence (substrate before consumers)

The dynamic-metatable **consumers** — `setmetatable`-driven dispatch,
function-valued metamethods, dynamic-shape tables — must **not** be built before
their substrate. They are deferred **behind** it. The static prototype-OOP model
already in tree (increments 21–25) is the **supported metatable story** until the
substrate prerequisites above are built.

---

## Re-evaluation triggers

Revisit only when:

- the absent-key / index-signature substrate (prerequisites 1–2) is built and
  reality-validated, at which point the `__meta` ref graft can be adopted coherently;
  or
- a use case appears that the static model demonstrably **cannot** type with exact
  types on a frozen kernel (the reframe above asserts no such case exists for
  prototype-OOP inheritance — a counterexample falsifies it).

Picking up any of C1–C4 is **not** a valid trigger; this record exists precisely to
prevent that.
