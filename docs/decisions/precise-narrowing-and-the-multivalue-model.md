# Decision: precise positive intersection narrowing — sound for `ttypetest`/direct scrutinees, blocked for `tifn` truthiness narrowing by the multivalue-truncation model (open design fork)

**Status:** substrate finding — June 2026. Characterization only; **no `proof/*.v`
changes were committed** for this record. The verified-sound pieces below build
green and are reusable; the `tifn` truthiness piece is **blocked on an open
architectural design fork** (recorded, not picked).

**Title:** Precise positive intersection narrowing — sound for `ttypetest` and
direct scrutinees, blocked for `tifn` truthiness narrowing by the
multivalue-truncation model.

---

## What was attempted ("Stage A")

Precise POSITIVE intersection narrowing: narrow a conditional's scrutinee to
`U ∩ Pos` (where `Pos` is the positive bound — `truthy_type` for `tifn`,
`tag_type g` for `ttypetest`) so the narrowed binding can be consumed at its REAL
type, dissolving the `truthy_type ⊑ Num` wall (a non-nil consumer can only see the
loose positive bound today, not the scrutinee's declared type intersected with it).

This was investigated and attempted twice. Outcome: **partially sound** — several
pieces are sound and landable — but a uniform `tifn` truthiness rule is **blocked
on a deeper foundational substrate issue** in the multivalue model.

The framing that matters: this wall is a **COMPLETENESS limit, not a soundness
one.** Every increment that hit it (generic-`for`, etc.) still landed **SOUNDLY via
over-approximation** — binding the bound-alone `truthy_type` / `tag_type`, never an
unsound intersection. Precise narrowing is a **precision/completeness improvement**,
deferred behind the fork below; soundness does not depend on it.

---

## Verified-sound pieces (build green; reusable once the fork is resolved)

These are characterized so they are not re-derived. `subtype.v` / `ssub.v` stay
**byte-unmodified** throughout.

- **A1 — `RsInterI` in `rsub`.** Added
  `RsInterI : forall C A B, rsub C A -> rsub C B -> rsub C (BInter A B)` to `rsub`
  (`typing.v`). `rsub_sound` extended via `dinter_glb`; the four
  `rsub_{,arrow_,rec_,tuple_}above_mono` inductions each take a **trivial** new
  case. `subtype.v` / `ssub.v` unmodified.

- **A2 — merged bridge lemmas, generic over the bound type `W`.**
  `truthy_narrows_inter` / `tag_narrows_inter`:
  `has_type S [] v W -> value v -> truthy_value v -> has_type S [] v (BInter W truthy_type)`
  (and the tag analogue). Proved by canonical forms: take the principal type `P`,
  get `rsub P W` from the kind's `inv_*`, get `rsub P Pos` from the existing
  `truthy_narrows` / `tag_narrows`, combine via `RsInterI`, one `TSub`.

- **`ttypetest` POSITIVE narrowing — fully sound and composes; landable on its
  own.** Binder `BInter U (tag_type g)` with the **RAW** scrutinee type `U` works
  because `ttypetest` does **NOT** truncate: there are no `STtMulti*` rules; a
  multivalue is tested by its `TgMulti` tag (`tag_type TgMulti = BTop`) and
  substituted **WHOLE** via `STtTrue`. No truncation step, so the binder's `U` is
  the actual substituted value's type. **This piece is a ready increment.**

- **`tifn` POSITIVE narrowing for DIRECT (non-multivalue) scrutinees — sound in
  isolation.** `SIfnTrue` + the merged bridge at `W := U` gives precise
  then-branch narrowing for a direct scrutinee.

---

## The blocker (precise, with the mechanism)

A **uniform** `tifn` rule with binder `BInter (trunc1 U) Pos` (or `BInter U Pos`)
is **UNSOUND** under the multivalue-truncation step
`SIfnMultiCons : tifn (tret (v::rest)) e1 e2 -> tifn v e1 e2`.

Mechanism. `inv_ifn` / `inv_ret` expose the scrutinee at a **LOOSE,
subsumption-chosen supertype** `U` — e.g. `U = BTop` (since `BTuple Ts <: BTop` via
the universal `SsTop`), or a `BUnion` supertype. After truncation the head `v` has
the **first-COMPONENT** type `T`, which bears **NO** subtyping relation to `U` or to
`trunc1 U`. Concretely:

- With `U = BTop`: `trunc1 U = BTop` and the binder **degenerates** (no precision
  gained).
- With nested / non-flat multivalues (`U = BTuple[BTuple[AInt]]`, head
  `v = tret[w]`): `trunc1 U` (recursing to a fixpoint) `= AInt`, but
  `v : BTuple[AInt]` — so `has_type v (trunc1 U)` **FAILS**.

Neither re-typing the head at `U`, at `trunc1 U`, nor context-narrowing `H1` closes
it: each requires a subtyping relation between the component type and the loose
scrutinee type that **does not hold**.

**Root cause.** The multivalue model permits (a) a multivalue scrutinee to be typed
at an **arbitrarily loose supertype via subsumption** before the conditional, and
(b) **non-flat** multivalues (tuple components that are themselves tuples). Precise
narrowing needs the conditional's binder to track the **truncated** condition
value's type, which these two properties prevent.

---

## The open design fork (genuine no-default architectural fork — recorded, NOT picked)

- **Option 1 — FLAT-multivalue model.** Enforce that multivalue / tuple components
  are single (non-multivalue) values, so `trunc1` is simple / idempotent and the
  head's type equals the first component. Touches the multivalue substrate broadly.

- **Option 2 — TRUNCATE-IN-RULE at `TIfn`.** Type the condition as the
  truncate-to-one of the scrutinee (reusing the existing `tfst` / `TFst` truncation
  machinery) with a **TIGHT** type, so subsumption cannot loosen the scrutinee type
  the binder depends on; narrowing happens on the tight truncated type.
  Reformulates how `tifn` handles multivalues (replacing / constraining the
  operational `SIfnMulti*` truncation).

- **Option 3 — context-narrowing lemma + canonical scrutinee typing.** Shown
  **INSUFFICIENT alone** (the required subtyping relation between component and
  loose scrutinee type does not hold) — recorded here as a **non-solution**, so it
  is not re-attempted as the closer.

Resolving this fork is a **design-it-twice candidate** (architectural, foundational,
touches the multivalue model). The `tifn` precise-truthiness increment is **gated
behind that decision**.

---

## Related, separately-gated frontier

Precise NEGATIVE narrowing (the else-branch `U ∩ ¬Pos`, the intersection/negation
wall) is a **distinct** gate from the positive work above: it remains gated on
**decider routing** (`decide_ssub` vs `gdecide` — the N5 inter-left
non-distributive frontier, `((Int∪Str)∩Bool)(Int∪Str)`). Also a design-it-twice
candidate. Do not conflate it with the multivalue fork.

---

## Re-evaluation triggers

- The multivalue-model fork (Option 1 vs Option 2) is resolved via design-it-twice
  — then the `tifn` precise-truthiness increment is unblocked.
- Independently, the `ttypetest`-positive increment (binder `BInter U (tag_type g)`)
  may be landed **now** as a ready, sound increment without resolving the fork.
- Picking up Option 3 as the closer is **not** a valid trigger; it is recorded here
  as a non-solution.
