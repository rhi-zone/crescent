# M5 — Effect system (full effect rows + effect polymorphism, discharge)

*Normative module spec of the unified type-system design. Depends on **M1**
(`01-lattice-and-subtyping.md`, the lattice / RDNF / complement / emptiness /
subtyping algorithm and its `4096` "too-complex" bail-out), **M2**
(`02-bounds-inference.md`, the polar bound graph + termination cache), **M3**
(`03-variadic-packs.md`, the arrow-over-packs shape and the **reserved M5 effect
seam** — M3 §3.1), and **M4** (`04-hkt-kinds.md`, the kind system, the reserved
`Effect` / `Row(Effect)` kinds, and the §6.1 gating interface). M5 specifies the
**effect system**: effects as a **dedicated, structurally-compared component of
`TArrow`** (Foundational Decision #2 — NOT folded into the return pack's slot-1),
**effect rows** with **effect polymorphism**, **subset-on-labels** row subtyping
reduced to M1 `<:`, **effect inference** with M1's bail-out for the hard cases,
**effect discharge** as a general operation (with `pcall` / `coroutine.create` as
two instances), and the **`Coroutine<Y,S,R>`** value type with its
create/resume/yield typings. It reconciles `docs/throw-catch-types-spec.md`
($Throw/$Catch) as the throw-discharge semantics. Aligns to `docs/type-system.md`
(philosophy, fixed) and satisfies the soundness floor of
`docs/typechecker-v5-constraints.md` §A.*

Primary sources reconciled here:

- **`docs/effects.md`** (the A/B/C/D map — **this module makes the decision**).
  The user has decided **Approach A: full effect rows + effect polymorphism**
  (effects.md §"Approach A"). M5 implements A and cites effects.md's
  propagation / discharge / coloring discussion (§"Coloring problem",
  §"Interaction with pcall", §"Effect polymorphism", Level 1/2/3).
- **`docs/typechecker-rewrite-design.md` §3.1** — *"effects ride on function arrow
  types as an additional, structurally compared component, and effect subtyping
  reduces to subset constraints on effect labels, which is itself a `<:` query."*
  M5 adopts this verbatim as the architectural frame and **upgrades** rewrite-
  design's deliberately-deferred "do not design a full row calculus upfront"
  stance to the full-rows decision the user has now made. The reconciliation:
  rewrite-design kept `{ <: }` as the *only* constraint vocabulary and made
  effect subset a `<:` query; M5 **keeps that** — rows add no new constraint kind,
  only a new kinded entity (`Row(Effect)`) whose subtyping the row machinery
  decides, exactly as M3's packs and M4's constructors are decided beside (not
  inside) the value lattice.
- **`docs/throw-catch-types-spec.md`** — `$Throw`/`$Catch` at the *type-alias*
  level. M5 reconciles these as the **type-computation face of throw discharge**
  (§7.4): `$Throw` is the type-level `error()`, `$Catch` the type-level `pcall()`;
  the **value-level** throw effect `!throw<E>` and its discharge by `pcall` are
  the runtime face. They are the same discharge principle at two layers.
- **`lib/type/static-v5/stdlib_types.lua`** — `effectful_fn` (the
  `return_base & effect` folding into `ret.items[1]` — **the anti-pattern M5
  re-architects off slot-1**, §8), `register_effects` / `declare_effect` (the
  effect registry + arities: `io`/`os` arity 0, `throw` arity 1, `yield` arity 2).
  M5 keeps the registry, moves the effect *off* the return pack.
- **`lib/type/static-v5/op_sem.lua`** — the effect-as-`TConst("!name")` +
  `TIntersection` composition (§"Effects ARE types"), `CIntersectionEq` /
  `CIntersectionMember` / `S-Quiesce-CIntersectionMember` (the F2 enforcement),
  `effect_not_permitted` diagnostics. **These are the five `!throw`/`!yield`
  string-match / intersection-member sites M5 replaces** with a row component +
  an effect-head taxonomy.
- **`lib/type/static-v5/constrain.lua`** — `build_pcall_ret`,
  `build_coroutine_create_ret`, `extract_yield_from_scope`, the 4-level
  `Coroutine` App-decompose, `effect_stack`. The **name-keyed gen-pass handlers**
  M5's declarative discharge makes deletable (consumed by M-final).
- **`lib/type/experiments/v5_perf/types.lua`** — `M.effect` /
  `M.effect_apply` / `M.is_effect` (the `Const("!name")` application chains),
  `M.rowvar` / `row_bindings` (the existing **row-variable substrate**, used for
  record rows today — M5 reuses the *same metavariable discipline* for effect
  rows). M5 describes; M5 does **not** edit it.
- **`docs/typechecker-roadmap.md` F2** (effect tracking — *"the missing piece is
  the full effect-row inference"*); **`docs/v5-gaps.md`** G17, adhoc-cluster
  (effect half), Y1, 5.F3-residual, G12 (closed; the intersection encoding M5
  supersedes).

M1 owns the lattice, RDNF, complement, emptiness, the `4096` budget. M2 owns the
polar bound graph + termination cache. M3 owns packs + the arrow-over-packs shape
(args/ret) and **reserved the third arrow slot for M5** (M3 §3.1, §8). M4 owns
kinds and **reserved `Effect` and `Row(Effect)` as kinds distinct from `Type`**
(M4 §6.1, §11.2). **M5 redefines none of them.** M5 adds the effect component to
the arrow, the row algebra over effect labels, the effect-inference discipline,
and the discharge operation — all *beside* the value lattice (a row is never a
lattice operand), exactly as packs and constructors sit beside it.

> **type-system.md non-goal SUPERSEDED.** `docs/type-system.md` §"Out of scope"
> historically lists *"Effect types (track side effects in the type). Not in
> crescent's design intent."* The user has **overridden** this: effects are now
> in scope and fully designed (this module). M5 **supersedes that non-goal
> entry.** Per the program's "docs change in the same commit as the code that
> motivates them" / "the design will update type-system.md at program
> completion" discipline (README §"Standing philosophy"), M5 **flags** the
> supersession here and the program updates the type-system.md non-goal list at
> program completion (M-final), not piecemeal. Until then this paragraph is the
> normative record that the effect-types non-goal is retired.

---

## 1. The decision (effects.md A/B/C/D — A, with the variant choices fixed)

`docs/effects.md` leaves four approaches open: A (full algebraic effects /
effect rows), B (async-only), C (parameterized coroutines + async sugar), D
(defer to `any`). **The user has decided A.** M5 specifies A and pins the variant
choices effects.md left open under "Design Space":

1. **Full effect rows + effect polymorphism** (effects.md §"Approach A",
   §"Effect polymorphism"). Effects are a polymorphic `Row(Effect)` on arrows;
   functions can be **effect-generic** — generic over a row variable
   `ρ : Row(Effect)`. The motivating example (effects.md §"Effect
   polymorphism": *"`map(f, list)` works whether `f` is async or not. This
   requires effect polymorphism (row polymorphism over effects)"*):

   ```
   map : <A, B, ρ:Row(Effect)> (A -> B ! ρ) -> List<A> -> List<B> ! ρ
   ```

   `map` neither performs nor forbids effects; it **forwards** `f`'s row `ρ` to
   its own result row. This is the type-level dissolution of effects.md's
   **coloring problem** (§"Coloring problem"): a higher-order function is
   *generic* over its callee's color, so it is callable from any color.

2. **Effects are arrow-only**, on the arrow's dedicated `Row(Effect)` component
   (Foundational Decision #2; M3 §3.1 seam; M4 §6.1 reserved the kind). An effect
   is kind `Effect`, a row is kind `Row(Effect)`, **never kind `Type`** — so
   `T & !effect` on a non-arrow value is **ill-kinded and unrepresentable** (M4
   §1.4 kind-error discipline). This is **not** folded into the return pack's
   slot-1 — that encoding (`stdlib_types.lua` `effectful_fn`,
   `return_base & effect` in `ret.items[1]`) is the anti-pattern M5 re-architects
   (§8).

3. **Subset-on-labels effect subtyping, reduced to a `<:` query** (rewrite-design
   §3.1). `! {throw}` is a subtype of `! {throw, io}` (fewer effects = more
   usable). This is decided by the row machinery (§2.4), not by a new constraint
   kind — the constraint vocabulary stays `{ <: }` (M1 §3).

4. **Both-layers coroutine model** (§6): the coroutine *body* carries
   `!yield<Y,S>` as a row effect; intermediate higher-order functions carry it
   **effect-generically** via `ρ`; `coroutine.create` **discharges** the yield
   effect, binding `Y/S/R` into the `Coroutine<Y,S,R>` value it returns.

5. **Discharge is the key operation** (§7): an effect handler **removes a label
   from the row**, propagating the residual. `pcall` removes `throw`;
   `coroutine.create` removes `yield`. Both are instances of one general rule —
   not two name-keyed handlers.

Approaches B/C/D are **rejected by the user's decision** and recorded here as
not-taken: B/C accept coloring as a feature (effects.md §"Coloring problem"); A
dissolves it via effect polymorphism. D (`any` everywhere) is the current state
M5 replaces (the F2 *"effect-row inference"* missing piece).

---

## 2. The effect lattice and effect rows

### 2.1 Effect labels (kind `Effect`)

An **effect label** is a kinded constructor head, kind `Effect` (M4 §6.1, the
reserved base kind distinct from `Type`). The substrate already represents an
effect as `Const("!name")` and a parameterized effect as an `App` chain over it
(`types.lua` `M.effect`/`M.effect_apply`/`M.is_effect`). M5 keeps the
representation and **kinds it**:

```
!io                 : Effect            -- nullary I/O side effect (arity 0)
!os                 : Effect            -- nullary OS/process side effect
!throw              : Type -> Effect    -- !throw<E>  raises an exception of type E
!yield              : Type -> Type -> Effect  -- !yield<Y,S>  yields Y, receives S
```

- A **nullary** effect (`!io`, `!os`) is directly kind `Effect`.
- A **parameterized** effect is an effect *constructor* — `!throw : Type ->
  Effect`, `!yield : Type -> Type -> Effect` — and a label like `!throw<E>` is
  the **fully-applied** `App(!throw, E) : Effect`. The argument types `E`, `Y`,
  `S` are kind `Type` (ordinary value types, full M1/M2 citizens). This is the
  M4 §6.1 commitment realized: *"a parameterized effect (an effect constructor)
  has kind `Type -> Effect`."* Kinding the application (M4 §1.3 `K-App`) ensures
  `!throw<integer>` is well-formed and `!throw<List>` (applying to a constructor)
  is a `kind_mismatch`.
- The **effect arities** come from M4-kinded versions of the substrate's
  `declare_effect` registry (`stdlib_types.lua` `register_effects`: `io`/`os`
  arity 0, `throw` arity 1, `yield` arity 2). M5 keeps the registry; the arity
  becomes the effect constructor's *kind arity* (M4), so an arity error is a
  `kind_mismatch` (M4 §1.4), not a string-length check.

> **The effect-head taxonomy (closes the adhoc-cluster effect half).** The
> substrate string-matches `"!throw"` / `"!yield"` at five gen-pass sites
> (`v5-gaps.md` adhoc-cluster item (2): `constrain.lua` lines 461, 490, 578, 609,
> 687). M5 replaces the string match with a **kinded effect-head taxonomy**: an
> effect head is a `Const` whose **kind is `Effect`** (or an effect-constructor
> kind `Type^n -> Effect`) — *recognized by its kind, not its name spelling*. The
> discharge rules (§7) dispatch on **which label a handler removes**, declared in
> the handler's type, not on a hardcoded `name == "!throw"`. The `"!"` spelling
> prefix is retained only as a human-readable convention; the **discriminator is
> the kind**. This is the substrate mechanism that lets `!throw`/`!yield` (and any
> future effect) be handled uniformly with no name-keyed cell.

### 2.2 Effect rows (kind `Row(Effect)`)

An **effect row** is an unordered, duplicate-free **set of effect labels** with
an optional open tail captured by a **row variable** `ρ`. It is kind
`Row(Effect)` (M4 §6.1 reserved). The node, adopting the substrate's existing
**row-variable** discipline (the same `TRowVar` / `row_bindings` machinery
`types.lua` already uses for *record* rows — M5 reuses the discipline, a separate
row metavariable space keyed for effects):

```
ERow = { tag = "erow", labels: Set(Effect), tail: ERowVar | nil }
ERowVar = { tag = "erowvar", id: integer }      -- a row variable ρ
```

- `labels` is a **set** of fully-applied effect labels (kind `Effect`), keyed by
  the label's hash-consed canonical form (so `!throw<integer>` and
  `!throw<integer>` dedupe, `!throw<integer>` and `!throw<string>` are distinct
  members). Set semantics — **not** a list — because effects.md's row model is a
  *set* of effects (effects.md §"Approach A": composable `Async + Logger +
  State`, order-irrelevant). This is the canonical-form requirement the substrate
  already meets for intersections (`constraint_mod.flatten_parts` flatten/sort/
  dedupe) — M5 lifts it to the row's label set, computed once in the shared
  `constraint_mod` so both interpreters share one canonicalization (parity, §9).
- `tail` is a **single optional open tail**: `nil` (a **closed** row — exactly
  these labels, the *total* effect set) or an `ERowVar` (an **open** row — at
  least these labels, plus whatever `ρ` captures). The single-tail invariant is
  structural (the data type holds one `tail`), exactly the single-rest invariant
  M3 §1.2 pins for packs and the single-row invariant the record row already has
  (`types.lua` `TRecord.row : TRowVar | nil`).
- The **empty closed row** `{} ` (`labels = ∅`, `tail = nil`) is the **pure**
  effect — a function that performs no tracked effect. It is the row analogue of
  the empty pack (M3 §4.1) and is the **identity** for row union (§2.3). It is
  **not** `never` and **not** `unknown`; those are *value-type* top/bottom (M1
  §1.1), and a row is not a value type (§4).

### 2.3 Row operations (kind `Row(Effect)`, beside the value lattice)

Two row operations, both at kind `Row(Effect)`, **never** value-lattice operators
(§4):

- **Row union** `R₁ ⊎ R₂` — the set-union of labels (the open tail, if any,
  carried through; two open tails reconcile by binding, §2.4). Used by **effect
  propagation** (§5): a function body that calls `f ! R₁` and `g ! R₂` has a body
  row `R₁ ⊎ R₂`. Commutative, associative, identity `{}` (the empty row).
- **Row difference / discharge** `R \ ℓ` — remove the label `ℓ` from the row,
  yielding the **residual** row. Used by **discharge** (§7): a handler that
  removes `ℓ` produces `R \ ℓ`. Defined on a *concrete* label; on an open tail
  the residual carries the tail (the handler removes only what it names; whatever
  `ρ` captures flows on — this is what makes a handler **effect-polymorphic** in
  the *other* effects, §7.2).

These are **set operations on label sets**, decidable and terminating with no
emptiness query — there is no boolean algebra of rows (no row complement, no
`~R`), because a row is a *positive set of effects*, not a set of values to be
complemented. This is the deliberate minimality rewrite-design §3.1 chose and the
user's decision preserves: **rows are sets, subtyping is subset; no row-level DNF,
no row-level negation, no row emptiness.** (Contrast M1's value lattice, which
*does* have complement and emptiness — the row level deliberately does not, so it
never pays M1's exponential cost.)

### 2.4 Row subtyping — subset-on-labels, reduced to M1 `<:`

Effect subtyping is **subset-on-labels** (rewrite-design §3.1; the user's
decision). `R₁ <: R₂` (an effect-producing function with row `R₁` is usable where
`R₂` is permitted) iff **every label of `R₁` is matched by a label of `R₂`, and
the tails reconcile**:

```
                  ∀ ℓ₁ ∈ R₁.labels  ∃ ℓ₂ ∈ R₂.labels.  ℓ₁ <:_label ℓ₂
                  ∧  tail-reconcile(R₁.tail, R₂.tail, residual)
─────────────────────────────────────────────────────────────────────  ROW-SUB
                              R₁ <: R₂
```

- **Per-label subtyping `ℓ₁ <:_label ℓ₂`** is an **M1 `<:` query** on the labels'
  *arguments*, per the label constructor's variance. `!throw<E₁> <: !throw<E₂>`
  iff `E₁ <: E₂` (throw is **covariant** in its payload — a handler catching
  `E₂` catches any `E₁ <: E₂`). `!yield<Y₁,S₁> <: !yield<Y₂,S₂>` iff `Y₁ <: Y₂`
  (yielded values, covariant) and `S₂ <: S₁` (received values, **contravariant** —
  the body must accept whatever the resumer may send). These per-label argument
  obligations are **exactly M1 §3.1 `App <: App` per-position variance** (M4 §4
  variance derivation): an effect label *is* an `App`-headed constructor at kind
  `Effect`, so its argument comparison is the same `subgoal(vᵢ, …)` mechanism M1
  uses for any `App`. **This is the precise reduction the user named: "effect
  subtyping is a `<:` query."** A label-set membership question (`∃ ℓ₂ … ℓ₁ <:
  ℓ₂`) decomposes into M1 `<:` obligations on `Type`-kinded arguments; the row
  level only does set membership + tail reconciliation.
- **Tail reconciliation** is the row-variable binding discipline (§2.5), the row
  analogue of M3's pack-var alignment: `R₁` closed `<:` `R₂` open binds `R₂`'s
  tail to absorb nothing extra (closed `<:` open always holds on the membership
  side if every `R₁` label is in `R₂`'s explicit labels); `R₁` open `<:` `R₂`
  closed requires `R₁`'s tail to bind to a row whose labels are all in `R₂`
  (§2.5). Default flow at a *call site* is: the callee's declared row must be a
  subset of the caller's permitted row (the caller permits at least what the
  callee performs).
- **`{} <: R` for any `R`** (the pure row is a subtype of everything — a pure
  function is usable in any effect context). **`R <: {}` only if `R = {}`** (only
  a pure function is usable where purity is required — calling an effectful
  function in a pure context is the rejected coloring violation, surfaced *as a
  subtype failure*, not a special "purity check").

> **Why this is genuinely an M1 `<:` reduction, not a parallel relation.** The
> ROW-SUB rule's *membership* part is set containment (decidable, finite, no
> lattice). Its *content* part — comparing two matched labels' arguments —
> **re-emits ordinary M1 `<:` on `Type`-kinded arguments**, which re-enters M1's
> structural decomposition and (if a non-trivial negation appears in an argument)
> M1's emptiness procedure and its `4096` budget. So the row level adds **no new
> decision procedure**: it is a finite set-membership router (like M3's pack rule
> §2 is a finite alignment router) that turns one row obligation into several
> value-type `<:` obligations. The constraint vocabulary stays `{ <: }` (M1 §3);
> there is no `CRowSub` that the lattice cannot already express — a row obligation
> *is* the conjunction of its per-label `<:` obligations plus a binding.

### 2.5 Row variables vs the M2 bound graph (the row-variable mechanism)

> **DECISION (the program's explicit ask — "do row vars get M2-style polar
> bounds, or a row-unification discipline like M3's pack vars / row vars?").**
> An effect-row variable `ρ : Row(Effect)` does **NOT** participate in M2's polar
> lower/upper bound graph. It has the **same simpler binding discipline as M3's
> pack variables (M3 §5) and as the existing record-row variable** (`types.lua`
> `row_bindings`): a single mutable binding in an `erow_bindings` map, set once by
> row unification (the §2.4 tail reconciliation), never carrying a lower/upper
> bound set and never coalesced.

The reasoning is M3 §5.2's, one level over: M2's polar bounds exist because a
**value-type** variable flows into many positions at both polarities and the
principal type accumulates a union of lowers + intersection of uppers, deferring
to coalescing. An **effect-row variable** is structurally different:

- A row var occupies **one tail position**, determined by **subset/membership
  alignment**, not by a lattice of candidate rows. Once the explicit labels on
  both sides are known, the tail is the unique residual that closes the
  subset gap; it is *unified*, not *bounded*. (Same as M3 §5.1: a pack var is
  bound by alignment; same as M4 §3.3: a constructor var is bound by Miller
  unification — the metavariable carries no value bounds in any of the three.)
- The **effect labels' *arguments*** (the `E`, `Y`, `S` value types inside the
  labels) **do** flow through M2's bound graph as ordinary `Type`-kinded
  variables. When `ρ` binds to `{!throw<α>}` and `α` is a value-type uvar, `α`
  gets M2 lower/upper bounds as usual (e.g. from the `<:_label` obligations of
  §2.4). The row var carries no bounds; its labels' **arguments** do. **No
  expressiveness is lost** — the subtyping flow happens on the value-type
  arguments (M2), the membership/length-poly happens on the row var (a binding).
  This is the exact M3 §5.2 / M4 §3.3 separation, applied to rows.
- **An effect row can be a value-type bound *only as part of an arrow*.** A row
  is never *itself* an M2 bound (a row is not a value type — §4). But an
  **arrow** `(A) -> B ! R` is a value type and *can* be a bound value carried
  opaquely by M2 (M3 §5.3); when M2 re-emits `CSub` against it, the obligation
  dispatches `T-CSub-Arrow → {args pack (M3), ret pack (M3), effect row (§2.4)}`.
  This is the precise seam, identical in shape to M3 §5.3 and M4 §3.3: **M2's
  bound graph carries arrow-with-effect bounds opaquely and re-emits; M5's row
  rules decide the effect component, M3's pack rules the arg/ret components.**

The `erow_bindings` map is a flat `{ id ↦ ERow }` parallel to the substrate's
`row_bindings` and M3's `pack_bindings` — **not** the `B.lower`/`B.upper`/
`B.edge_*` structure M2 §2 defines for `UVar` roots. (Whether the implementation
reuses the *same* `row_bindings` table keyed by a disjoint id space, or a separate
`erow_bindings`, is an implementation packaging detail with no soundness content;
the discipline is identical to record rows either way.)

---

## 3. The arrow with effects (extends M3's arrow shape)

### 3.1 The shape — `TArrow{args, ret, effects}`

M3 §3.1 fixed `args` and `ret` as packs and **explicitly reserved the third slot
for M5**. M5 fills it:

```
TArrow = { tag = "arrow", args: TPack, ret: TPack, effects: ERow }
```

- `args : TPack` and `ret : TPack` — unchanged from M3 (§3.1).
- `effects : ERow` — the arrow's effect row, kind `Row(Effect)` (§2.2). An arrow
  with no declared effects has `effects = {}` (the empty closed row — a **pure**
  function). The default-constructed arrow `M.arrow(args, rets)` (the M3
  constructor) is given `effects = {}` — pure by default, the sound default
  (a function is assumed to perform no effect unless its body or annotation
  introduces one; §5).
- **The arrow itself is kind `Type`** (M4 §1.3 `K-Arrow`, extended per M4 §6.1 to
  *additionally* demand `effects : Row(Effect)`). So an arrow is a full M1 lattice
  citizen (unionable, intersectable, complementable, RDNF-normalizable) **as an
  atom** — the effect row inside it is reached only by decomposing the arrow
  (§3.2), exactly as the arg/ret packs are (M3 §4.2). **The row is never a lattice
  operand**; the arrow is.

### 3.2 Arrow subtyping — M3's pack rules PLUS effect-row subset

M1 §3.1's `Arrow <: Arrow` decomposes contra-args / co-ret (M3 §2–§3). M5 adds
the third obligation:

```
   args contra (M3 §2.2 contra)   ret co (M3 §2.2 co)   R_L <: R_R (§2.4 ROW-SUB)
─────────────────────────────────────────────────────────────────────────────────  T-CSub-Arrow
                  Arrow(args_L, ret_L, R_L)  <:  Arrow(args_R, ret_R, R_R)
```

- **`args` contravariant** — M3 §2.2 `subgoal(contra, …)`, unchanged.
- **`ret` covariant** — M3 §2.2 `subgoal(co, …)`, unchanged.
- **`effects` covariant-as-subset** — `R_L <: R_R` (§2.4): a function performing
  **fewer** effects is usable where **more** are permitted. This is **co-variant
  in the subset order**: a subtype arrow may perform a *subset* of the supertype's
  permitted effects. (The intuition: a `pure` function `(A) -> B ! {}` is usable
  wherever an `(A) -> B ! {io}` is expected — passing a pure function where an
  io-permitting one is wanted is sound; the reverse is not.)

`T-CEq-Arrow` (M3 §3.1) gains the symmetric obligation: `CEq` on the effect rows
(both subset directions, i.e. row equality — equal label sets after canonicaliz-
ation, tails equated by binding — §2.4 in both directions, the row analogue of
M3 §2.1 `T-CEq-Pack`).

### 3.3 The `K-Arrow` kind side-condition (M4 §6.1)

M4 §1.3's `K-Arrow` rule is extended (as M4 §6.1 specified M5 would do):

```
Γ ⊢ each args.items[i] : Type    Γ ⊢ each ret.items[i] : Type    Γ ⊢ effects : Row(Effect)
────────────────────────────────────────────────────────────────────────────────────────  K-Arrow (M5)
                            Γ ⊢ Arrow(args, ret, effects) : Type
```

- The args/ret items kind `Type` (M3/M4). The **effects component kinds
  `Row(Effect)`** — every label in it kinds `Effect`, every label *argument*
  kinds `Type` (§2.1). An attempt to put a `Type`-kinded value in the effect slot
  (or an effect label in the args/ret pack) is a `kind_mismatch` (M4 §1.4),
  caught **before** the lattice or the row machinery runs. This is the kind-level
  enforcement of **effects-arrow-only**: `T & !effect` is unrepresentable because
  `!effect : Effect ≠ Type`, so it cannot be an operand of `&` (`K-Bool` demands
  `Type` operands, M4 §1.3); and a row cannot land in a `ret.items[i]` slot
  because `K-Arrow` demands those items kind `Type`. **Foundational Decision #2 is
  enforced by kinding, not by convention.**

---

## 4. The row–lattice boundary (rows are NOT lattice elements)

The precise statement, parallel to M3 §4 (packs) and M4 §1.1 (constructors):

1. **An `ERow` (or a bare effect label / `ERowVar`) may not appear as an operand
   of `TUnion`, `TIntersection`, or `Neg`.** There is no `row ∩ type`, no
   `row ∪ row` (that is row *union* §2.3, a `Row(Effect)`-kind operation, not the
   value-lattice `∪`), and no `~row`. A row denotes a *set of effects a function
   may perform*, not a set of runtime values, so the value-lattice boolean
   operators have no denotation on it (M4 §1.4 makes this a kind error: a row is
   kind `Row(Effect) ≠ Type`, so `K-Bool`/`K-Neg` reject it). A solver state with
   a row as a boolean operand is **ill-formed** (a solver bug / internal error,
   not a user diagnostic).
2. **The lattice top/bottom (`unknown`/`never`) are value types, not rows.** The
   empty row `{}` is the *pure* effect (§2.2), not `never`; `never` is the empty
   *value* type. A row is empty-of-labels (`{}`) when a function performs nothing;
   that is a normal, common row, not bottom.
3. **The lattice operates on a row's *label arguments*, never on the row.** The
   per-label `<:_label` obligations (§2.4) are ordinary `CSub`/`CEq` on **value
   types** (the `E`/`Y`/`S` arguments) — they re-enter M1's structural
   decomposition / emptiness. The row rule (§2.4) is the *router* that turns one
   row obligation into several value-type obligations plus a set-membership check
   and a tail binding; the lattice never sees the row itself.

This composes M1 and M5 cleanly, **with no M1 amendment**: M1's lattice closes
over **arrows-as-atoms** (RDNF treats an arrow shape as one positive constructor,
M1 §2.2 / M3 §4.2); a row is touched **only** during the structural decomposition
of an arrow obligation (§3.2), at which point the row rule (§2.4) re-expresses it
as per-label value-type `<:` + a binding. The row never enters RDNF, is never an
operand of `|`/`&`/`~`, and M1 never asked for any of those on a row. This is the
**third** instance of the same boundary pattern: packs (M3 §4), constructors
(M4 §1.1), and now rows — all kinded entities that sit one level *down* from the
value lattice, surfaced only by decomposition of a value-type atom (an arrow, an
application).

---

## 5. Effect inference (closes F2)

> **F2 gap text** (`typechecker-roadmap.md`): *"Effect tracking … Walker H landed
> the yield/throw/pcall plumbing; the missing piece is the **full effect-row
> inference**."* M5 supplies the inference; the substrate's plumbing
> (`effect_stack`, the `CIntersectionMember` F2 enforcement) is re-architected
> onto the row (§8).

### 5.1 The body row is inferred by row union over the calls

A function's **inferred effect row** is the **row union** (§2.3) of:

- the effect rows of every function it **calls** in its body (each call site
  contributes the callee's declared/inferred row, after the call's argument
  substitution — a call to `f : (A) -> B ! R` contributes `R`), and
- the effect rows introduced by **effect-introducing primitives** in scope:
  `error(...)` introduces `!throw<E>` (E from the argument); `coroutine.yield(y)`
  introduces `!yield<Y,S>` (Y from the argument, S the received type — §6.3);
  `io.write` introduces `!io`; etc. These primitives' rows come from their
  **stdlib declarations** (§8 — the re-architected `effectful_fn`), not from
  gen-pass name-matching.

minus any labels **discharged** by a handler in the body (§7 — `pcall` removes
`throw`, `create` removes `yield`).

The inferred row is a **fresh open row** during inference — `{ … explicit labels
… | ρ }` with a fresh `ρ` — so that it can still *gain* labels as more of the
body is analyzed (open = "at least these"). At **generalization** (the function's
type is finalized, M2 §5), the row is **closed** (`ρ` defaulted to the empty tail)
**unless** the row var escapes into the function's *signature* (an
effect-polymorphic function, §5.3), in which case `ρ` is **generalized** as a
row-kinded type parameter. This is the row-level analogue of M2's
generalize-or-default decision for value variables, and of M4 §2.2's
defaulting-unbound-`KVar`-to-`Type`: **an inference row var that does not escape
the signature defaults to the empty tail (the closed, total effect set); one that
escapes is generalized to a `Row(Effect)` quantifier.**

### 5.2 Checking against a declared row

When a function is **annotated** `… ! R_decl` (§3), inference computes the body
row `R_body` (§5.1) and emits **`R_body <: R_decl`** (§2.4): the body may perform
**at most** the declared effects. A body that performs an effect not in `R_decl`
(and not discharged) fails the subset check — surfaced as a
`effect_not_permitted` diagnostic (the substrate's existing diagnostic class,
`op_sem.lua`), now produced by a **row subset failure** rather than the
`CIntersectionMember` "part not in intersection" path (§8). This is the F2
enforcement, re-expressed declaratively: *the body's effects must be a subset of
the function's permitted effects.*

### 5.3 Effect polymorphism — the row variable in the signature

An **effect-generic** function quantifies over a row variable:

```
map : <A, B, ρ:Row(Effect)> (A -> B ! ρ) -> List<A> -> List<B> ! ρ
```

- `ρ` is a **`Row(Effect)`-kinded type parameter** (M4 reserved the kind). It is
  introduced by the generic-parameter list `<… ρ:Row(Effect) …>` and instantiated
  at each call site (M13 skolemization for body-checking; M2 instantiation for
  the call) **the same way** a value-type parameter `<A>` or a constructor
  parameter `<F: Type -> Type>` (M4) is — there is **one** generalization /
  instantiation mechanism, parameterized by kind.
- At a **call** `map(f, xs)` where `f : (Int) -> Bool ! {io}`, the row argument
  `ρ` is **inferred** by row unification (§2.4 tail reconciliation) to `{io}`, and
  `map`'s result row becomes `{io}` — the effect **forwards**. At a call with a
  **pure** `f : (Int) -> Bool ! {}`, `ρ = {}` and `map` is pure. **This dissolves
  the coloring problem** (effects.md §"Coloring problem"): `map` is callable from
  any color because it is *generic* over the color.
- `map`'s body **uses `ρ` linearly-forward**: it calls `f` (introducing `ρ` into
  the body row, §5.1) and its result row is exactly `ρ` (no extra labels). The
  body-row check (§5.2) is `ρ <: ρ` (trivially holds) — `map` performs *exactly
  what `f` performs and nothing more*. A `map` that *also* did `io.write` would
  have body row `ρ ⊎ {io}`, and the check `ρ ⊎ {io} <: ρ` **fails** (the body
  performs `io` not in the declared `ρ`) — correctly rejecting a `map` that
  claims to be effect-transparent but is not.

### 5.4 Inference, the Miller fragment, and M1's bail-out

Row unification (§2.4, §2.5) is **set-membership + tail binding** — decidable and
terminating for the common case (closed rows, single open tail, the
effect-polymorphic forwarding of §5.3). It does **not** attempt full row-
unification completeness. Two hardness sources, each handled by reuse, never by a
new mechanism:

1. **The per-label argument obligations** (`<:_label`, §2.4) re-emit ordinary M1
   `<:` on `Type`-kinded arguments; if such an argument carries a non-trivial
   negation it routes through M1's emptiness and **inherits M1's `4096` budget**
   (M1 §3.4). The row level adds **no second budget** — this is the same single
   shared bail-out M4 §3.4 reuses for HKT and M3 §6 inherits for packs.
2. **Ambiguous row unification** — when two open rows with *different* explicit
   labels must reconcile and the tail binding is **not uniquely determined**
   (e.g. `{!io | ρ₁} = {!os | ρ₂}` could bind `ρ₁ ↦ {!os | ρ₃}`, `ρ₂ ↦
   {!io | ρ₃}` for a fresh `ρ₃` — the *principled* most-general unifier — but a
   genuinely under-determined case where no most-general unifier is forced is
   the **row analogue of stepping outside the Miller pattern fragment**). M5's
   decision, **adopting M4 §3.4's discipline verbatim**: **stay in the determined
   fragment; outside it, reuse M1's bail-out — reject with a named diagnostic,
   never guess.** The determined fragment is: closed-vs-closed (decided by set
   equality), closed-vs-open (the open tail absorbs the surplus — unique),
   open-vs-closed (the open tail must bind to a subset — unique or reject), and
   open-vs-open **where one tail is fresh** (bind the fresh tail to the
   residual — unique, the §5.3 forwarding case). Open-vs-open with **two
   non-fresh tails and disjoint explicit labels** is the under-determined case;
   M5 emits `effect_row_ambiguous` (the row analogue of M4's "ambiguous
   constructor variable" / M1's emptiness bail-out) at the originating provenance.
   **This is the documented decidability escape (M1's "too complex → error"),
   applied to rows — not a search, not a guess, not a widening to `any`.**

This is the program's explicit instruction realized: *effect-row inference uses
the Miller-fragment + M1's bail-out for the hard cases; do NOT attempt full
completeness.* The determined fragment covers every effect-polymorphism pattern
effects.md needs (forwarding `ρ`, §5.3); the under-determined residue rejects
rather than guesses.

---

## 6. The both-layers coroutine model

This is the model the user decided. It has **two layers** that the type system
keeps distinct, dissolving function-coloring at the type level while runtime
non-coloring comes from Lua's stackful coroutines (effects.md §"Coloring
problem"; the user's decision).

### 6.1 Layer 1 — the coroutine body carries `!yield<Y,S>` as a row effect

The function passed to `coroutine.create` is, *inside*, a function that may call
`coroutine.yield`. `coroutine.yield(y)` introduces the **row effect**
`!yield<Y,S>` (§5.1): it yields a value of type `Y` (the argument) and the
expression `coroutine.yield(y)` **evaluates to** the received `S` (what the
resumer sends back). So the body function has type `(…) -> R ! {!yield<Y,S> | ρ}`
(`R` its return, `ρ` any other effects it performs). Intermediate higher-order
functions in the body carry `!yield<Y,S>` **effect-generically** via `ρ` (§5.3) —
a helper that calls a yielding callback is generic over the yield effect, so it is
**callable from yielding and non-yielding contexts alike**. **This is the
type-level dissolution of coloring** (effects.md §"Coloring problem"): there is no
separate "coroutine color" — yield is just another effect label, forwarded
effect-polymorphically like any other.

> **This also resolves the orthogonal "yield reads the enclosing-function scope"
> gap** (the substrate's `extract_yield_from_scope`, `effect_stack`,
> 5.F3-residual). The substrate inspects an `effect_stack` to find which enclosing
> function's annotation supplies `Y`/`S` (`constrain.lua`
> `extract_yield_from_scope`; gap Y2, now closed; the empty-stack edge case). In
> the both-layers model **`Y`/`S` ride in the body's effect row** (`!yield<Y,S>`)
> and flow through `create` into the `Coroutine` type (§6.2) — **no scope
> inspection**. The yield effect is part of the body function's *type*, so it is
> sound under reuse (a yielding closure stored and called elsewhere carries its
> `!yield<Y,S>` in its type, not in a dynamic stack). The `effect_stack` device
> is deleted (§8).

### 6.2 Layer 2 — `coroutine.create` DISCHARGES the yield effect

`coroutine.create(body)` **discharges** `!yield<Y,S>` from `body`'s row (§7, the
general discharge operation) and **binds `Y`/`S`/`R` into the value type
`Coroutine<Y,S,R>`** it returns:

```
coroutine.create : <Y, S, R, ρ:Row(Effect)>
                   ( () -> R ! {!yield<Y,S> | ρ} )  ->  Coroutine<Y, S, R>  ! ρ
```

- The body's row is `{!yield<Y,S> | ρ}`. `create` **removes `!yield<Y,S>`**
  (`R_body \ !yield<Y,S>` = the residual `ρ`) and **captures `Y`, `S`, `R`** —
  `Y`/`S` from the (now-discharged) yield label's arguments, `R` from the body's
  return — **into the `Coroutine<Y,S,R>` value type**. So the yield effect is
  *transformed from a row label into value-type parameters of `Coroutine`*. This
  is **exactly parallel to how `pcall` discharges `throw`** (§7.3): a handler
  removes a label from the row and reflects what it removed into the value it
  returns.
- The residual `ρ` becomes `create`'s **own** effect row — any *other* effects
  the body performs (e.g. `!io`) are **not** discharged by `create` (it only
  handles `yield`) and propagate to `create`'s caller. This is the §7.2
  "a handler removes only what it names; the rest flows on" — `create` is
  effect-polymorphic in `ρ`.
- `Coroutine<Y,S,R>` is the **value type** (§6.4) — kind `Type`, an M4-kinded
  constructor `Coroutine : Type -> Type -> Type -> Type`. The yield *effect* has
  been **discharged into a value-type denotation**; there is no `!yield` anywhere
  in `Coroutine`'s type. This is the resolution of effects.md's Level 1 vs Level 3
  tension: the **body** uses Level 3 (effect rows, per-yield precision via the
  label arguments and effect polymorphism), and `create` projects it down to the
  **Level 1** `Coroutine<Y,S,R>` value type for the holder of the suspended
  coroutine.

### 6.3 `resume` consumes the `Coroutine<Y,S,R>`; `yield`'s type

```
coroutine.resume : <Y, S, R> (Coroutine<Y,S,R>, S) -> (boolean, Y | R)
coroutine.yield  : <Y, S>    (Y) -> S  ! {!yield<Y,S>}
```

- **`resume(co, s)`** consumes the `Coroutine<Y,S,R>` value (no effect — it is
  ordinary code calling into a suspended stack), takes a send value `s : S`, and
  returns `(boolean, Y | R)` (the boolean = "still running"; the second component
  is the yielded `Y` if suspended again or the final `R` if returned). **This
  closes 5.F3-residual** (resume-side `S` narrowing): the send argument `s` is
  checked `s <: S` against the coroutine's *own* `S` type parameter — the `S` is
  **bound in the `Coroutine<Y,S,R>` value** (carried from the body's
  `!yield<Y,S>` via `create`, §6.2), so `resume` **binds `S` from the send
  argument by ordinary value-type subtyping** (`s <: S`), no scope inspection, no
  separate narrowing pass. The residual the gap names — *"`resume(co, s)` does not
  bind `S` from the send argument"* — is closed because `S` is a value-type
  parameter of `Coroutine` that `resume` constrains structurally.
- **`yield(y)`** has the row effect `!yield<Y,S>` (Layer 1, §6.1): it yields
  `y : Y` and evaluates to the received `S`. Its **type-level evaluation result is
  `S`** — the substrate's old `extract_yield_from_scope` returned `(Y, S, R)` by
  walking the stack; now `S` is the label's second argument, determined by
  unification at the `create` discharge site (the body and `create` share the
  same `Y`/`S` through the effect row).

### 6.4 `Coroutine<Y,S,R>` as an M4-kinded constructor

`Coroutine : Type -> Type -> Type -> Type` (M4-kinded — a ternary constructor,
the curried `App(App(App(Coroutine, Y), S), R)` the substrate already builds in
`build_coroutine_create_ret`). M5 keeps the *value type* `Coroutine<Y,S,R>` and
its three-parameter shape (effects.md Level 1; TS `Generator<Y,R,Next>`, Python
`Generator[Y,S,R]` prior art) — but it is now produced by **declarative discharge**
(§6.2) rather than the name-keyed `build_coroutine_create_ret` + the 4-level
App-decompose in `constrain.lua` (adhoc-cluster item (3), line 1306). Per-position
variance (M4 §4): `Y` covariant (yielded out), `S` contravariant (sent in), `R`
covariant (returned out) — the same Y/S/R variance as the `!yield` label (§2.4),
because `Coroutine` is the value-type reflection of the yield effect.

---

## 7. Discharge — the general operation (closes the effect half of adhoc-cluster)

### 7.1 The general rule

> **Discharge is the key operation.** An **effect handler** is a function that, in
> typing a callee, **removes one or more labels from the callee's effect row** and
> **reflects what it removed into the value it produces**, propagating the
> **residual** row to its own caller.

Formally, a handler `h` that discharges label `ℓ` over a thunk
`f : (…) -> R ! {ℓ(args…) | ρ}`:

```
                f : (…) -> R ! {ℓ(args…) | ρ}        reflect(ℓ, args, R) = V
─────────────────────────────────────────────────────────────────────────────  DISCHARGE
                h(f) : V ! ρ
```

- It **removes** `ℓ` from `f`'s row (`R_body \ ℓ`, §2.3), yielding the residual
  `ρ`, which becomes `h`'s **own** row — so any *other* effects `f` performs flow
  through `h` to `h`'s caller (the handler handles *only what it names*).
- It **reflects** the discharged label's arguments (and `R`) into a **value type**
  `V` — what the handler returns. The `reflect` function is **declared by the
  handler's own type** (`pcall`'s `reflect` builds `(true,…R) | (false,E)`;
  `create`'s `reflect` builds `Coroutine<Y,S,R>`). It is **not** hardcoded per
  handler name; it is read off the handler's declared `--::` signature (§8).

**Discharge is name-agnostic.** The rule fires for *any* function whose declared
type matches the DISCHARGE shape — a row with a removable label on the argument
arrow, a residual row on the result. `pcall` and `create` are the two stdlib
instances; a user-defined effect handler (effects.md §"Effect handlers": the
`run` scheduler) discharges its effect by the *same* rule. There is **no
`name == "pcall"` or `name == "coroutine.create"` dispatch** — the substrate's
five name-keyed sites (§8) are replaced by this one shape-driven rule. *This is
the substrate mechanism the adhoc-cluster effect half requires; closing it by a
name-keyed handler would be exactly the "substrate moved, not removed" the
program forbids.*

### 7.2 The residual carries the rest (effect-polymorphic handlers)

A handler is **effect-polymorphic in the residual**: its type quantifies
`<… ρ:Row(Effect)>` over the residual row (§5.3), so it discharges *its* label and
forwards everything else. `pcall(f)` where `f : () -> R ! {!throw<E> | !io}`
returns the pcall result **and still carries `!io`** to pcall's caller — pcall
handles `throw`, not `io`. This is the row-difference `R \ ℓ` (§2.3) keeping the
tail, and it is what makes discharge **compose**: nesting handlers peels labels
one at a time, each forwarding the rest.

### 7.3 `pcall` discharges `throw`

```
pcall : <R, E, ρ:Row(Effect)>
        ( () -> R ! {!throw<E> | ρ} )  ->  ( (true, R) | (false, E) )  ! ρ
```

- **Removes `!throw<E>`** from `f`'s row; **reflects** it into the value type
  `(true, R) | (false, E)` — the discriminated success/failure pack-union the
  substrate's `build_pcall_ret` builds (now declarative, §8; closes P2's
  `(true,R...) | (false,E)` shape via M3 packs). The success arm carries the
  return `R`, the failure arm the thrown `E`.
- **Residual `ρ`** is pcall's own row — a `pcall` of a function that also does
  `!io` still surfaces `!io` (§7.2). This is the precise answer to effects.md
  §"Interaction with pcall": *"`pcall(f)` catches errors. If `f` is async, does
  `pcall` interact with the effect?"* — **pcall discharges `throw` only; it
  forwards `yield`** (and every other effect) via `ρ`. So `pcall` of a yielding
  function is well-typed and the `yield` effect propagates — modelling Lua's
  actual behavior (pcall across a yield is fine in Lua 5.2+/LuaJIT) without a
  special case.

### 7.4 `$Throw`/`$Catch` reconciliation — discharge at the type-computation layer

`docs/throw-catch-types-spec.md` defines `$Throw<…Msg>` (type-level `error()` —
evaluates to `never`, emits a diagnostic) and `$Catch<T, Default?>` (type-level
`pcall()` — intercepts `$Throw` during type evaluation). M5 reconciles these as
the **type-computation face of the same discharge principle**:

| Runtime / value layer (M5 effect) | Type-computation layer (throw-catch-spec) |
|-----------------------------------|--------------------------------------------|
| `error(msg)` → `!throw<E>` effect | `$Throw<…Msg>` (type-level error)          |
| `pcall(f)` discharges `!throw`    | `$Catch<T, Default>` discharges `$Throw`   |

- **Same principle, two layers.** Both are **discharge**: a producer raises
  (`error` / `$Throw`), a handler removes it and reflects a fallback (`pcall` →
  `(false,E)` / `$Catch` → `Default`). throw-catch-spec's *"`$Throw` always fires
  unless its result is consumed by `$Catch`"* is the type-level statement of
  §7.1's residual: an undischarged throw propagates (fires); a discharged one is
  caught. throw-catch-spec's "catch mode" flag on `ctx` is the type-computation
  realization of removing `!throw` from a row.
- **They do not unify into one node, and must not.** `!throw<E>` is a
  **value-level effect** on a function arrow (kind `Row(Effect)` component); it
  tracks that *running the function* may raise an `E`. `$Throw`/`$Catch` are
  **type-level intrinsics** in *match aliases* (throw-catch-spec §"Scope: authored
  contracts only") that emit/suppress *checker diagnostics during type
  computation*. They live at different layers (M8 owns match-type evaluation where
  `$Throw`/`$Catch` operate; M5 owns the value-level effect row). M5's reconcil-
  iation is to **name the shared discharge principle** so the two are recognized
  as the same idea — *a producer raises, a handler removes-and-reflects* — at the
  runtime layer (M5) and the type-computation layer (M8 / throw-catch-spec),
  without conflating their nodes. throw-catch-spec's `$Throw`/`$Catch` remain the
  **permanent intrinsics** that doc specifies (M8 consumes them in match-arm
  evaluation); M5 adds the value-level `!throw<E>` effect and its `pcall`
  discharge, and states that the two are the type-vs-value faces of discharge.

---

## 8. Migration / blast-radius — re-architecting `effectful_fn` off slot-1

M5 changes the implemented v5 substrate. M5 performs **no** migration (the design
program writes no code); it records the cost and blast radius.

### 8.1 The arrow gains an effect component (the M3 seam, filled)

`TArrow{args, ret}` → `TArrow{args, ret, effects:ERow}` (§3.1). `M.arrow` defaults
`effects = {}` (pure). `subst`/`shift`/`variance`/`equal` (`types.lua`) and both
interpreters' `T-CEq-Arrow` / `T-CSub-Arrow` gain the **third obligation** (effect
row §2.4). This is the blast radius M3 §3.1 / §8 flagged. **The effect row is a
new node family** (`ERow`/`ERowVar`, §2.2) reusing the existing record-row
`row_bindings` discipline — small, parallel to the established row machinery.

### 8.2 `effectful_fn` is RE-ARCHITECTED off the return pack's slot-1

The current `stdlib_types.lua` `effectful_fn(arg_types, return_base, effects)`
builds `ret.items[1] = return_base & (effect₁ & … & effectₙ)` — folding effects
into the **return pack's first slot as an intersection** (`types.lua`
`intersection(parts)`). **M5 removes this.** The re-architected builder:

```
effectful_fn(arg_types, return_base, effects)
  = TArrow{ args = pack(arg_types),
            ret  = pack([return_base]),     -- return is JUST the value, no & effect
            effects = erow(effects) }        -- effects go in the dedicated slot
```

- The return pack carries **only the value return** (`return_base`) — no effect
  intersection. Effects move to the `effects : ERow` component.
- All ~30 `effectful_fn` call sites in `stdlib_types.lua` (`print` → `{!io}`,
  `error` → `{!throw<E>}`, `os.exit` → `{!os}`, `io.*` → `{!io}`,
  `coroutine.yield` → `{!yield<Y,S>}`, the pure ones → `{}`, etc.) keep their
  *declarations* but the effects land in the row, not the return intersection.
- **The five `!throw`/`!yield` string-match sites** (`constrain.lua` 461, 490,
  578, 609, 687; adhoc-cluster item (2)) are deleted: effect recognition is now
  by **kind** (`Effect`, §2.1 taxonomy), and discharge is the **shape-driven**
  DISCHARGE rule (§7.1), not a name match.

> **Why slot-1 folding is wrong, restated for the implementer.** `return_base &
> effect` puts a `Row(Effect)`-kind entity (an effect) inside a `Type`-kind
> intersection in a *value* position. Under M4's kinding (§3.3), that is a
> `kind_mismatch` — an effect is not kind `Type`, so it cannot be an `&` operand
> (`K-Bool`/`K-Neg` demand `Type`). The substrate "got away with it" only because
> it had no kind-gating and treated effects as plain `TConst`. M5 + M4 make the
> old encoding **unrepresentable**: `T & !effect` cannot be built (Foundational
> Decision #2's *"`T & !effect` on a non-arrow value is meaningless and must not
> be representable"* is now enforced by `K-Bool`, M4 §1.4). The effect *must* be
> on the arrow's row slot or nowhere.

### 8.3 The effect-composition rules are re-architected from intersection to row

The substrate composes effects via **`TIntersection`** (`op_sem.lua`
§"Effects ARE types": `CIntersectionEq` / `CSub-Intersection-Decomp` /
`CIntersectionMember` / `S-Quiesce-CIntersectionMember`). G12 (closed `c600a446`)
established this intersection encoding. **M5 supersedes G12's intersection
encoding** with the row component:

- Effect *composition* (a body doing two effects) is **row union** `⊎` (§2.3),
  not `TIntersection`.
- The F2 *enforcement* (`CIntersectionMember` "is this effect permitted",
  `S-Quiesce-CIntersectionMember` "effect never inferred" at quiescence) becomes a
  **row subset check** `R_body <: R_decl` (§5.2). The `effect_not_permitted`
  diagnostic is kept (it is the right user-facing message); it is now produced by
  a row subset failure, not an intersection-member failure.
- `CIntersectionEq` / `CIntersectionMember` (the `op_sem.lua` rules) are **deleted
  for the effect use** (they may remain if M7/value-intersection needs them, but
  the *effect* composition no longer routes through them). This removes the
  `all_parts_unresolved` / `effect_not_permitted` intersection-member family from
  the effect path.

### 8.4 The name-keyed gen-pass handlers become deletable (consumed by M-final)

`build_pcall_ret`, `build_coroutine_create_ret`, `extract_yield_from_scope`, the
4-level `Coroutine` App-decompose, the `effect_stack` (`constrain.lua`) are
**replaced by declarative `--::` declarations** that the §7 DISCHARGE rule and the
row machinery solve:

- `pcall` / `xpcall` → a `--::` declaration with the §7.3 discharge signature.
- `coroutine.create` → the §6.2 discharge signature; `resume` / `yield` → §6.3.
- The `effect_stack` / `extract_yield_from_scope` scope-walk → **deleted**:
  `Y`/`S` ride in the body's effect row (§6.1), no scope inspection.

M5 **specifies the declarations** (the discharge signatures above); **M-final
deletes the handlers** (it is gated on M3+M4+M5+M8+M11 per the module map). So M5
*closes the design* of the effect half of adhoc-cluster / Y1; the handler deletion
is M-final's implementation payoff, consuming M5's discharge mechanism. **No
behavior is closed by a name-keyed result** — the discharge rule (§7.1) and the
effect-head taxonomy (§2.1) are name-agnostic substrate.

### 8.5 Keep, do not rewrite

The effect **registry** (`register_effects`/`declare_effect`, the arities) — kept,
arities become kind arities (§2.1). The `Const("!name")` + `effect_apply`
representation (`types.lua`) — kept, now kinded `Effect` (M4). The **row-variable
discipline** (`row_bindings`, used for record rows) — kept and **reused** for
effect rows (§2.5). The `Coroutine<Y,S,R>` three-parameter value type — kept (§6.4).
The `effect_not_permitted` diagnostic — kept (§8.3). The canonical-form
flatten/sort/dedupe in `constraint_mod` — kept, lifted to row label sets (§2.2).

**Parity discipline (carries forward).** Both `op_sem.lua` and `op_sem_alt.lua`
must independently encode the row algebra (§2.4 ROW-SUB, §2.5 binding), the
arrow's third obligation (§3.2), the DISCHARGE rule (§7.1), and the discharge
signatures (§6, §7.3). The parity-load-bearing quantities — all fully
spec-determined — are (a) the **row label-set canonicalization** (§2.2, the shared
`constraint_mod`), (b) the **ROW-SUB membership + tail-reconciliation** (§2.4),
(c) the **determined-fragment boundary** and the `effect_row_ambiguous` bail-out
point (§5.4), and (d) the **DISCHARGE shape match** (§7.1). Because the per-label
obligations re-emit M1 `<:` (no new budget) and the row bail-out reuses M1's
discipline (§5.4), both interpreters bail at the identical point (M1's pin) or not
at all — the parity property M1 §F2 requires, extended to effect rows.

**Behavior conservation (§A11).** The substrate's effect *plumbing* exists (Walker
H — F2 plumbing, G12 intersection encoding); M5's re-architecture is staged so the
suite stays green: add the `ERow`/`ERowVar` nodes + the arrow effect slot →
re-point `effectful_fn` to the row → replace the intersection composition with row
union/subset → declare pcall/create/resume/yield with discharge signatures →
delete the gen-pass handlers (M-final). Each a green commit. The user-observable
behavior (effect tracking on functions, `pcall`/`coroutine` typing) is conserved;
the *mechanism* (row component + discharge, not return-intersection +
name-keying) is what changes.

---

## 9. Soundness alignment (constraints §A)

- **§A1 (soundness floor).** Row subtyping never accepts an unproven relation:
  ROW-SUB (§2.4) rejects a body effect not permitted by the declared row (§5.2);
  per-label obligations re-emit M1 `<:` which rejects unsound argument relations;
  discharge (§7.1) reflects exactly what it removes (no silent label drop —
  removing `ℓ` requires the handler's declared type to *name* `ℓ`). The
  under-determined row case (§5.4) **rejects** (`effect_row_ambiguous`), never
  guesses.
- **§A2 (`unknown` never casts away) / §A3 (`any` does not exist).** No
  permissive/top row: `{}` is the *pure* row (the identity for union), not a top;
  there is no row that admits all effects as a "row `any`". A row rule never
  widens a label argument to `any`. Effect inference defaults an unescaped row var
  to the empty tail (closed, §5.1), never to a permissive catch-all.
- **§A14 (single timeout).** Rows add **no new unbounded loop and no new budget**:
  label sets are finite; ROW-SUB membership is finite; tail binding is unification
  (one binding); the per-label argument obligations inherit M1's `4096` budget
  (§5.4); the row bail-out reuses M1's discipline. The whole-file check stays
  within §A14.
- **§H1 / Foundational Decision #2.** Effects-arrow-only is enforced by **kinding**
  (§3.3, M4 §6.1): an effect is kind `Effect ≠ Type`, so it cannot be a value-type
  operand or land in a return-pack slot — the slot-1 folding (§8.2) is
  unrepresentable.
- **B-series (provenance).** Per-label and row-subset obligations carry the
  originating call/return/annotation provenance, so a `effect_not_permitted` or
  `effect_row_ambiguous` blames the source expression.

No item in §10 is closed by a hardcoded result: F2 is closed by the **row
component + inference + discharge as general mechanisms** (§2, §5, §7), declarable
for *any* effect and *any* handler — not a `pcall`/`coroutine`-shaped or
`!throw`/`!yield`-name-keyed special case. The effect-head taxonomy is by **kind**
(§2.1), the discharge rule is by **shape** (§7.1) — both name-agnostic.

---

## 10. Closes

- **F2** (`typechecker-roadmap.md` — *"Effect tracking … the missing piece is the
  full effect-row inference"*). Closed by **effect rows on the arrow
  (`Row(Effect)` component, §3) + subset-on-labels subtyping reduced to M1 `<:`
  (§2.4) + effect-row inference with effect polymorphism (§5) + the
  determined-fragment / M1-bail-out discipline (§5.4)**. The "full effect-row
  inference" the roadmap names as missing is specified: a body row is inferred by
  row union over calls (§5.1), checked subset against the declared row (§5.2), and
  generalized over an escaping row variable for effect polymorphism (§5.3).
  Substrate mechanism, not a result.

- **The effect half of adhoc-cluster** (`v5-gaps.md` — *"effect-name string-
  matching `!throw`/`!yield`, 5 sites"; "Coroutine 4-level decompose"*). Closed by
  the **kinded effect-head taxonomy (§2.1)** (recognition by kind `Effect`, not
  name spelling) + the **general DISCHARGE rule (§7.1)** (shape-driven, not
  name-keyed) + the **declarative pcall/create/resume/yield discharge signatures
  (§6, §7.3)**. The five string-match sites and the 4-level decompose are deleted
  (§8.4), consumed by M-final. Substrate mechanism (taxonomy + discharge shape),
  name-agnostic; closing it by a name-keyed handler would be the forbidden
  "substrate moved, not removed."

- **5.F3-residual** (`v5-gaps.md` — *"Resume-side `S` narrowing incomplete:
  `coroutine.resume(co, s)` does not bind `S` from the send argument"*). Closed by
  the **both-layers model (§6)**: `S` rides in the body's `!yield<Y,S>` effect row
  (§6.1), flows through `create`'s discharge into the `Coroutine<Y,S,R>` value
  type as a value-type parameter (§6.2), and `resume(co, s)` **binds `S` from the
  send argument by ordinary value-type subtyping `s <: S`** (§6.3) — no scope
  inspection, sound under reuse. Substrate mechanism (effect-row → value-type
  parameter via discharge), not a result.

- **G12** (`v5-gaps.md`, closed `c600a446` — the `TIntersection` effect encoding)
  is **superseded** by the row component (§8.3): effect composition is row union,
  not intersection; the F2 enforcement is row subset, not `CIntersectionMember`.
  (G12 was closed by the substrate's intersection plumbing; M5 re-architects that
  plumbing onto the dedicated row slot, per Foundational Decision #2.)

(G17 — variadic generics — is M3's, **consumed here**: pcall's `(true, R…) |
(false, E)` discharge result (§7.3) and create's args/return forwarding lower onto
M3's pack substrate. M5 supplies the *effect* discharge; M3 supplies the *pack*
shape; M-final deletes the name-keyed handlers that lower onto both.)

Each closure is a **substrate mechanism**, not a hardcoded result, per the
CLAUDE.md planning rules and the README cross-walk discipline.

---

## 11. Open questions (for the reviewer — genuine forks not resolved unilaterally)

1. **`Row(Effect)` / `Effect` kind grammar ownership — RESOLVED here (confirming
   M4's lean).** M4 §11.2 deferred *"should `Row(Effect)` and `Effect` be M4-owned
   or M5-owned?"* to a joint M5 confirmation. **M5 confirms M4's lean:** M4 owns
   the *kind grammar entry* (the base kind `Effect` and the `Row(_)` kind-former,
   reserved in M4's kind AST so the kind-error discipline can forbid an effect in
   a value position — M4 §6.1); **M5 owns the *semantics*** (the `ERow`/`ERowVar`
   value-level row nodes §2.2, row union/difference §2.3, ROW-SUB §2.4, the
   binding discipline §2.5, inference §5, discharge §7). This is the clean split:
   M4 reserves the *distinction* (so an effect can never be kind `Type`), M5
   specifies the *inference and subtyping of rows*. No soundness content in the
   packaging; confirmed.

2. **Effect annotation surface syntax (`! R`, `<ρ:Row(Effect)>`).** **DEFERRED —
   UX / annotation-syntax batch (with M4 §11.3).** M5 fixes the *semantics*: an
   arrow carries a row component; an effect-generic function quantifies a
   `Row(Effect)` parameter. The *surface syntax* — `(A) -> B ! {throw, io}` for a
   closed row, `(A) -> B ! ρ` for a row variable, `<ρ:Row(Effect)>` for the
   binder, whether `! throw` (bare) is sugar for `! {throw}`, and where the `!`
   sits relative to the return — is a syntax fork with **no soundness content**,
   batched with M4's `<F: K>` kind-annotation syntax so the `--::` surface is
   decided once. M5's lean: `! {ℓ₁, …, ℓₙ}` / `! ρ` suffix on the return, bare
   `! ℓ` as sugar for `! {ℓ}`, matching effects.md's `! Async` examples and the
   substrate's `!name` spelling. Deferred to the syntax batch.

3. **Effect *aliases* / effect sets as named abstractions.** **DEFERRED — confirm
   with M-final's effect-head taxonomy.** effects.md §"Approach A" shows
   `effect Async { await: … }` — a *named* effect that may bundle operations.
   M5 specifies the *label* level (`!throw`, `!yield`, `!io`); whether a user can
   declare a *named effect alias* (`Async = {!io, !throw<…>}` as a `Row(Effect)`
   alias, or a richer `effect Async { … }` with operation signatures à la Koka) is
   a surface/abstraction question above the label substrate. M5's lean: a named
   effect alias is an ordinary `Row(Effect)`-kinded type alias (a name for a label
   set), expanded at use the way value-type aliases are — no new mechanism. A
   Koka-style `effect Async { await }` with *operation signatures* (where `await`
   is an effect operation whose handler supplies its implementation) is a richer
   feature; M5 leans it is **out of scope for the initial design** (effects.md's
   actual ecosystem patterns — yield, throw, io — are label-level), an
   OPEN-QUESTION escalated to a substrate extension if a corpus need arises, in
   the spirit of M4 §11.4 (kind polymorphism out of scope). Confirmed with
   M-final, which owns the effect-head taxonomy's final shape.

4. **First-class effect handlers beyond pcall/create.** **DEFERRED — confirm with
   M-final.** §7.1 makes DISCHARGE general (any handler matching the shape). The
   stdlib instances are `pcall` (throw) and `create` (yield). Whether a *user* can
   write a first-class effect handler (effects.md §"Effect handlers": the `run`
   scheduler discharging `Async`) with full handler ergonomics — resumable
   handlers, multi-shot continuations — is the deep end of algebraic effects. M5's
   lean: the **discharge shape** (§7.1) admits a user handler that removes a label
   and reflects a value (a *tail-resumptive* / one-shot handler, which is what
   Lua's coroutine-based schedulers are); **multi-shot / deep handlers are out of
   scope** (Lua coroutines are one-shot; effects.md's ecosystem is one-shot CPS).
   This keeps discharge at the expressiveness Lua's runtime actually supports.
   OPEN-QUESTION: confirm the one-shot boundary with M-final's scheduler
   declarations. Conservatively sound (the one-shot discharge rule never admits a
   multi-shot program it cannot model — it simply does not provide multi-shot).
