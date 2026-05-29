# M3 — Variadic / pack generics

*Normative module spec of the unified type-system design. Depends on **M1**
(`01-lattice-and-subtyping.md`, the lattice / RDNF / complement / emptiness /
subtyping algorithm) and **M2** (`02-bounds-inference.md`, the polar bound graph
+ termination cache). M3 specifies **packs**: the telescope structure for
arrow argument and return positions — tuples, multi-return, varargs, and `(...%P)`
captures — and the arrow shape built over them. Aligns to `docs/type-system.md`
(philosophy, fixed — §"Tuples", §"Varargs, multiple returns, `pcall` wrapping")
and satisfies the soundness floor of `docs/typechecker-v5-constraints.md` §A.*

Primary sources reconciled here:

- `docs/typechecker-v5-operational-semantics.md` § "Match types and variadic
  packs (CMatchEval + TPack)" — the **v5 "Spec B part 1" substrate**: the
  `TPack`/`TPackVar` nodes, `deref_pack` splice, the
  `T-CEq-Pack-{Closed,OpenL,OpenR,OpenBoth}` + `T-CSub-Pack` rules, the
  variance-split closed-pack arity (Phase-2.2 NORMATIVE CORRECTION), the arrow
  redesign `TArrow{args:TPack, ret:TPack}`, and the cache-key extension. Built
  and parity-tested this session (commit `b19adc82`). **M3 ADOPTS Spec B part 1
  as its realization** and reconciles it with M1's lattice and M2's bounds.
- `lib/type/experiments/v5_perf/types.lua` — the `TPack`/`TPackVar` AST nodes,
  `M.pack` / `M.packvar`, `shift_pack` / `instantiate_pack` / `subst_params_pack`,
  `deref_pack` (the splice), `pack_head_key` (the cache token). The substrate M3
  describes; M3 does **not** edit it.
- `lib/type/static-v5/op_sem.lua` § "TPack CEq / CSub (Spec B)" and
  `lib/type/static-v5/op_sem_alt.lua` § "T-CEq-Pack" / "T-CSub-Pack" — the two
  **independent** encodings whose parity M3's spec must keep possible.
- `docs/type-system.md` § "Tuples", § "Tuple subtyping: structural, no magic",
  § "Varargs, multiple returns, `pcall` wrapping" (philosophy).
- `docs/typechecker-rewrite-design.md` §1.1 (functions: "Multi-return as a
  return-position tuple. Varargs as a trailing spread parameter"; arrow variance
  contra-args/co-ret). **It is thin on variadics** — it names tuples/multi-return
  /varargs as constructors and the arrow variance but specifies **no pack
  algebra** (no alignment rule, no splice, no length-polymorphism). M3 fills that
  gap from Spec B part 1, consistent with rewrite-design's arrow-variance frame.
- `docs/v5-gaps.md` G17 (the gap M3 closes).

M1 owns the lattice, RDNF, complement, the emptiness procedure, and the step
budget (default `4096`). M2 owns the polar bound graph, polar coalescing, μ, and
the termination cache. **M3 redefines neither**; it specifies the pack structure
that sits *beside* the lattice (never inside it — §4) and the pack-var binding
discipline that sits *beside* the M2 bound graph (a simpler binding map, not a
second polar graph — §5).

---

## 1. What a pack is, and what it is not

A **pack** is an ordered sequence of types with at most one open tail. It is the
type of a Lua **value list** in exactly two positions: the **arguments** of a
call and the **returns** of a call (and, statically, a tuple literal). It is the
substrate that makes `(...%P)` capture, multi-return, varargs, and tuples one
node instead of four encodings (`type-system.md` §"Tuples"; op-sem §"TPack node").

A pack is **not** a value type and **not** a lattice element. A Lua value is
never "a pack"; a *position that holds several values* is. This distinction is
load-bearing and is pinned normatively in §4: packs are **telescopes for arg/ret
positions**, so a `TPack` may not appear inside a `TUnion` / `TIntersection` /
`Neg`, and there is no `pack ∩ type`, `pack ∪ pack`, or `~pack`.

### 1.1 The node (adopted from Spec B part 1 / `types.lua`)

```
TPack    = { tag = "pack",    items: V5Type[], rest: TPackVar | nil }
TPackVar = { tag = "packvar", id: integer }
```

- `items` is the fixed positional prefix (possibly empty). Each item is an
  ordinary M1 simple type (a value type — primitive, literal, record, arrow,
  uvar, boolean combination, μ, …). **Items are lattice elements; the pack that
  contains them is not.**
- `rest` is a **single optional open-pack position**: `nil` (a **closed** pack,
  exact arity `#items`) or a `TPackVar` (an **open** pack — `#items` fixed
  positions followed by zero or more further positions captured by the pack var).

`TPack` subsumes three previously-distinct encodings (op-sem §"TPack node";
`type-system.md` §"Tuples"):

1. **Multi-return** — `arrow.ret` is a `TPack`. `(string) -> (number, string)`
   has `ret = pack([number, string], nil)`. Replaces the `"1".."n"` record-key
   encoding of returns and the retired `is_positional` predicate.
2. **`(...%P)` / vararg capture** — a `TPack` with the captured-tail bound to
   `rest`. A trailing spread parameter is the `args` pack's `rest`.
3. **Tuples** — `{ number, string }` is `pack([number, string], nil)`, a closed
   pack. A tuple is **not** a record and **not** an array (`type-system.md`
   §"Tuples": a tuple is not assignable to an array).

### 1.2 The single-rest invariant (structural, not a parser check)

There is exactly one `rest` field and it is terminal. A sequence with two open
segments — `(...%P, number, ...%Q)` — is therefore **unrepresentable**: the data
type cannot hold it (op-sem §"TPack node"). This is the **single-rest
invariant**, and it is an invariant *of the data type*, not a rule the parser
enforces and the solver trusts. Every pack operation below preserves it:
`deref_pack`'s splice (§3) flattens a bound `rest` into `items` and carries
through *at most one* surviving `rest`; the alignment rules (§2) bind a `rest`
to a `pack(items, rest')` whose own single `rest'` is the only tail. No operation
can manufacture a two-tail pack.

> **Why single-rest is the right invariant.** Lua value lists adjust only at the
> tail (a call splices its last multi-value expression; earlier multi-values are
> truncated to one). A second interior open segment would have no operational
> meaning — there is no Lua construct that produces "n values, then a hole, then
> m values". The invariant is the type-level image of Lua's tail-adjustment rule.

### 1.3 Substrate operations (preserve packs; adopted from `types.lua`)

The pack-aware variants of M1/M2's structural traversals (`types.lua`
`shift_pack` / `instantiate_pack` / `subst_params_pack` / `equal` /
`collect_uvars`) **return packs** and treat the pack structure as transparent:

- **`shift` / `instantiate` / `subst_params`** map over each `items[i]` (and the
  splice of any bound `rest`). A `TPackVar` id is a gensym (like a `UVar` id):
  **never shifted, never renumbered** by De-Bruijn shifting. These are the M4/M13
  binder mechanics applied through a pack; M3 only fixes that they descend into
  items and preserve `rest`-identity.
- **`equal(p, q)`** ⟺ `#p.items == #q.items`, items pairwise `equal`, **and**
  `rest` agreement (both `nil`, or both `TPackVar` with equal id after deref).
  This is **pack structural equality**, distinct from pack *subtyping equality*
  `CEq` (§2) — `equal` is the syntactic identity used by caches and the parity
  fixtures; `CEq` is the semantic obligation.
- **`collect_uvars(p)`** unions over items and over the splice of a bound `rest`.
  A `TPackVar` itself contributes **no** `UVar` (it is a pack metavariable, not a
  type variable — §5); its binding's contents may.

---

## 2. Pack equality and subtyping

Constraints on packs arise **only** from the arrow rule (§3): the solver never
emits a bare `CSub`/`CEq` whose two sides are packs except as the immediate
decomposition of an arrow constraint. There is no surface syntax that asks
"is this pack a subtype of that pack" outside an arrow (or a tuple-value subtype
query, which the arrow-ret covariant rule subsumes — a tuple is a closed pack
checked covariantly). This keeps packs off the lattice (§4) by construction:
they are produced and consumed only at arrow boundaries and tuple positions.

The deref-splice `deref_pack` (§3) runs **before** any rule fires, so every rule
below sees a pack whose `rest` is either `nil` or an **unbound** `TPackVar`.

### 2.1 Equality — `CEq` on packs (Spec B `T-CEq-Pack-*`)

`CEq(p_a, p_b)` is the conjunction of both subtyping directions (M1 §1.3); on
packs it is realized directly by four arity-aware cases (op-sem §"TPack CEq/CSub";
`op_sem.lua` `rule_T_CEq_Pack`, `op_sem_alt.lua` `T-CEq-Pack`). Let
`n = #p_a.items`, `m = #p_b.items`.

- **T-CEq-Pack-Closed** — both closed. Require `n == m`; emit `CEq(A_i, B_i)` for
  `i ≤ n`. `n ≠ m` ⇒ rejection (`pack arity mismatch`). *Equality demands exact
  arity in both directions — this is correct for `CEq` regardless of variance,
  because equality already asserts both directions and the nil-pad/truncate
  asymmetry of §2.2 is a strictly-covariant relaxation that has no place in a
  symmetric relation.*
- **T-CEq-Pack-OpenL** — LHS open (`rest ρ` unbound), RHS closed, `m ≥ n`. Equate
  the shared prefix `CEq(A_i, B_i)` for `i ≤ n`; bind `ρ ↦ pack(B_{n+1..m}, nil)`
  (the remaining RHS tail). `m < n` ⇒ rejection (LHS demands more fixed positions
  than RHS supplies).
- **T-CEq-Pack-OpenR** — mirror of OpenL.
- **T-CEq-Pack-OpenBoth** — both open. Align the shared prefix by `min(n, m)`;
  bind the **shorter** side's `rest` to `pack(surplus_prefix_items, longer_rest)`
  and equate the two pack-vars (when prefixes are equal-length, bind one rest to
  `pack([], other_rest)`). The surplus prefix items of the longer side are thus
  prepended to the shorter side's tail binding, then the rests reconcile. This
  is the only place a `rest`-to-`rest` equation occurs; it is a binding in
  `pack_bindings`, never a `UVar` merge (§5).

### 2.2 Subtyping — `CSub_v` on packs, variance carried from the arrow site

`T-CSub-Pack` is **positional and length-polymorphic** (op-sem §"T-CSub-Pack";
`op_sem.lua`/`op_sem_alt.lua` `rule_T_CSub_Pack`). It carries a **variance**
`v ∈ {co, contra}` supplied by the enclosing arrow rule (§3) — **never
re-derived inside the pack rule**. For the shared prefix `k = min(n, m)`:

```
subgoal(co,    x, y) = CSub(x, y)      -- covariant position: A_i <: B_i
subgoal(contra, x, y) = CSub(y, x)     -- contravariant position: B_i <: A_i
```

emitting `subgoal(v, A_i, B_i)` for `i ≤ k`, plus the tail/surplus obligations
(below). The variance flips the *direction of each per-item `CSub`*; it does
**not** change the pack-alignment shape (that is always `min(n,m)` prefix
alignment, §2.3).

### 2.3 Open/closed alignment, and the variance-split closed-closed arity

This is the **soundness-relevant** rule established in the prior substrate work
(Spec B Phase-2.2 NORMATIVE CORRECTION). Closed-vs-closed arity is **handled by
variance**, not by a single uniform "arity must match" rejection:

- **Open packs (either side open)** — align the shared prefix by `k = min(n, m)`;
  the open tail **absorbs** the surplus on its side, exactly as
  T-CEq-Pack-OpenBoth aligns, but emitting `subgoal(v, …)` (not `CEq`) on aligned
  positions and reconciling the surplus + rests by the same prefix-alignment. A
  **closed** pack is a subtype of an **open** pack of no greater fixed arity (the
  open tail absorbs the surplus).
- **Closed-vs-closed, `v = contra` (arrow ARGUMENTS)** — arity must match
  **exactly**: `n ≠ m` ⇒ rejection (`arrow_arity_mismatch`). *A function of `n`
  parameters is not a function of `m ≠ n` parameters; supplying it where the
  other is expected is unsound. Contravariant exact-arity is the function-arity
  contract.*
- **Closed-vs-closed, `v = co` (arrow RETURNS)** — **no arity rejection**;
  perform the **Lua multi-return adjustment**: iterate `i ∈ 1..m` and emit
  `CSub(A_i or nil, B_i)`. Surplus callee returns (`n > m`) are **truncated**;
  missing callee returns (`n < m`) **adjust to `nil`** (so `B_i` must admit
  `nil` in those positions, else the obligation `CSub(nil, B_i)` rejects). *A
  callee returning `(A_1..A_n)` is usable where the caller requests `(B_1..B_m)`
  under Lua's value-list adjustment; this is the documented soundness floor (the
  v4 `T-CSub-Record-Width` positional nil-pad/truncate). Requiring exact arity on
  returns would reject sound Lua programs.*

> **Why the split is sound (and why it is not a special case).** The asymmetry is
> not a per-shape hack; it is the **direct image of Lua's call semantics under
> contravariance**. Lua adjusts a value list to its consumer's arity: a call site
> consuming `m` returns from a callee producing `n` pads with `nil` (`n < m`) or
> drops the surplus (`n > m`). At an **argument** position the *callee* is the
> consumer and its declared arity is the contract the caller must meet exactly
> (you cannot drop a required parameter and you cannot supply one the function
> does not accept — except through an explicit vararg `rest`, which is the open
> case). At a **return** position the *caller* is the consumer and Lua's
> adjustment applies. So "exact on contra, nil-pad/truncate on co" is one rule —
> *the consumer's arity governs, and Lua adjusts toward the consumer* — observed
> at both ends of the arrow. The variance carried from the arrow site is exactly
> the bit that says which end is the consumer. Stating it as two cases is the
> readable form of one principle, not two ad-hoc handlers. (Following the cited
> authority — Lua multi-return adjustment / the v4 width-positional rule — over
> the original unqualified "different arity ⇒ rejection" prose, per the Phase-2.1
> precedent that the spec prose carried soundness errors vs. its sources.)

Both interpreters encode this split identically (`op_sem.lua`/`op_sem_alt.lua`
`rule_T_CSub_Pack` both branch on `v` for the closed-closed case); it is a
parity-pinned point.

---

## 3. The arrow shape and the substitution-time splice

### 3.1 Arrow shape — `TArrow{args:TPack, ret:TPack}`, with room for M5

```
TArrow = { tag = "arrow", args: TPack, ret: TPack }
```

(`types.lua` `TArrow`). `M.arrow(args_list, rets_list)` builds
`pack(args_list, nil)` for each; `M.arrow_open` supplies a `rest`. The arrow
rules read both components as packs:

- **T-CEq-Arrow** — emit `CEq` on `args` packs and `CEq` on `ret` packs (via §2.1).
- **T-CSub-Arrow** — emit `CSub_contra` on `args` packs and `CSub_co` on `ret`
  packs (via §2.2). The variance `contra`/`co` is supplied **here**, at the arrow
  rule, and threaded into `T-CSub-Pack` — this is the single origin of the §2.3
  variance split. This is the rewrite-design §1.1 arrow variance (contra-args,
  co-ret) realized over packs.

> **M5 SEAM — the arrow is NOT finalized as a 2-tuple.** M3 fixes the `args` and
> `ret` components and their pack rules. **M5 (effect-system architecture) adds a
> dedicated effect component to `TArrow`** — a third, structurally-compared slot
> (subset-on-labels subtyping), per the program's Foundational Decision #2
> (effects are arrow-only; NOT folded into the return pack's slot-1 as the
> current `stdlib_types.lua` `effectful_fn` does with `return_base & effect` in
> `ret.items[1]`). M3 therefore **does not** treat `{args, ret}` as the complete
> arrow. Implementers must leave the node open for an effect field; the arrow
> equality/subtyping rules M3 states cover `args` and `ret` only, and M5 extends
> T-CEq-Arrow / T-CSub-Arrow with the effect-component obligation. M3 makes no
> commitment about the effect component beyond reserving the seam — putting an
> effect on the return pack would be the very encoding Foundational Decision #2
> forbids, so M3 must not even appear to place anything pack-side that M5 would
> need to move.

### 3.2 Substitution-time splice — `deref_pack` (R↦pack / R↦never)

`deref_pack(p, pack_bindings)` (`types.lua`) walks `p`, replacing a **bound**
`rest` `TPackVar` by its binding and **flattening** the binding's `items` into
`p.items`, recursively, until `rest` is `nil` or an **unbound** `TPackVar`. This
is the **substitution-time splice** — the type-level image of Lua's value-list
splicing of a trailing multi-value:

- **`R ↦ pack([int, str], nil)`**: `pack([true], rest=R)` splices to
  `pack([true, int, str], nil)`.
- **`R ↦ pack([], nil)` (empty pack) / `R ↦ never`**: the tail contributes
  nothing — `pack([true], rest=R)` collapses to `pack([true], nil)`. (An empty
  pack and a `never`-bound rest both mean "no further positions"; the splice
  drops them. This is the v4 `(true, ...R)` splice semantics, now first-class.)
- A binding that is **itself open** carries its own single `rest` through (the
  splice continues resolving it), and the single-rest invariant (§1.2) is
  preserved because the loop carries exactly one surviving `rest`.
- **Cyclic-binding guard** — the splice bounds its depth by the number of
  distinct pack-var ids seen (a `seen` set; `types.lua` `deref_pack`), so a
  malformed cyclic binding terminates rather than looping. This is a
  well-formedness guard, not a semantic feature; a correct solver never produces
  a cyclic `rest` binding (the alignment rules bind a `rest` only to a pack whose
  tail is a *different*, fresh or already-resolved var).

Every rule in §2 runs `deref_pack` (the `resolve_pack` step in `op_sem.lua`)
first, so the rules operate on spliced packs. The splice is **purely
substitutional** — it reads `pack_bindings` and rebuilds, never emitting a
constraint — so it is identical across both interpreters and contributes no
work to the M2 termination cache beyond what the post-splice rule emits.

---

## 4. The pack–lattice boundary (critical — packs are NOT lattice elements)

This is the precise statement of how M3's packs compose with M1's lattice
**without category errors**. M1 §1.1 already lists `Pack{items, rest}` as a
constructor "(M3)" and lists arrows over packs, but defers the rule. M3 pins the
boundary:

### 4.1 The boundary, normatively

A `TPack` is a **telescope** for an arg/ret (or tuple) position. It is **not** a
member of the M1 lattice. Consequently, normatively:

1. **A `TPack` may not appear as an operand of `TUnion`, `TIntersection`, or
   `Neg`.** There is no `pack ∩ type`, no `pack ∪ pack`, and no `~pack`. The M1
   boolean operators are defined over **value types** (sets of runtime values);
   a pack denotes a *position holding several values*, which is not a set of
   values, so the boolean operations have no denotation on it. A solver state in
   which a `TPack` is an operand of a boolean node is **ill-formed** (a solver
   bug, surfaced as an internal error, not a user diagnostic).
2. **The lattice top/bottom (`unknown`/`never`) are value types, not packs.** A
   pack position is empty when `items = []` and `rest = nil` (the empty pack
   `pack([], nil)` — the `unit`/void position; cf. `type-system.md` §"`unit`").
   The empty pack is **not** `never`; `never` is the empty *value* type. The
   splice maps `R ↦ never` (a value-type bottom bound) to "no tail positions"
   (§3.2) — that is the one controlled place a value-type `never` meets a pack,
   and it is handled by the splice, not by putting `never` *in* a pack operand.
3. **The lattice operates on a pack's *items*, never on the pack.** Per-item
   obligations emitted by §2 are ordinary `CSub`/`CEq` on **value types** — they
   re-enter M1's structural decomposition and (if a non-trivial negation arises)
   M1's emptiness procedure. The pack rule is the *router* that turns one
   pack obligation into several value-type obligations; the lattice never sees
   the pack itself.

### 4.2 Why this is the right boundary (no contradiction with M1)

M1's lattice is a **boolean algebra of value sets** (M1 §1.1–1.2). Its three
operators (`|`, `&`, `~`) and its RDNF normal form (M1 §2.2: at-most-one positive
arrow/record/tag per disjunct) are all defined over value-denoting constructors.
An **arrow** *is* such a constructor — `(A) -> B` denotes the set of functions —
so an arrow is a full lattice citizen and may be unioned, intersected,
complemented, and RDNF-normalized. The arrow's **internal `args`/`ret` packs are
not** independently lattice citizens; they are reachable only by **decomposing**
the arrow (M1 §3.1 `Arrow <: Arrow` → contra args, co ret), at which point the
pack rules (§2) take over and immediately re-express the obligation as per-item
value-type `CSub`s. So:

- The lattice closes over **arrows-as-atoms** (RDNF treats an arrow shape as one
  positive constructor — M1 §2.2); it never needs to put a pack in a disjunct.
- A pack is touched **only** during the structural decomposition of an arrow
  obligation (or a tuple-value obligation, which is an arrow-ret-style covariant
  closed pack). It is never an operand of `|`/`&`/`~` and never appears in RDNF.

This composes M1 and M3 cleanly: **M1's lattice is over value types (arrows
included as atoms); M3's packs live one level down, inside an arrow, surfaced
only by decomposition.** There is no `pack∩type`, no pack-union, no
pack-complement — and M1 never asked for any. **No M1 amendment is required.**

> **Tuples are the one apparent exception, and they are not one.** A tuple value
> `{number, string}` is a `pack([number, string], nil)` used as a **value type**
> (you can have `x: {number, string}`). But a tuple-as-value is checked by the
> **arrow-ret covariant closed-pack rule** (§2.3 `v=co`) when used in a subtype
> position, and it is **not** unioned/intersected/complemented as a pack — a
> union of tuples `{number} | {string}` is a union of two **arrow-ret-style
> closed-pack value shapes**, each an atom in the disjunct, exactly as records
> are (M7). If a future need arises to put a tuple inside a boolean operator, it
> is admitted as a **value-type atom** (a closed-pack-shaped constructor), never
> as a raw `TPack` operand — the constructor wrapper is the lattice citizen, its
> internal pack is not. This is an OPEN-QUESTION (§9.3) only insofar as M7/M8 may
> want to pin the wrapper; the boundary itself (raw pack ∉ lattice) is fixed here.

---

## 5. Pack variables vs the M2 bound graph (binding discipline, NOT polar bounds)

This reconciles `TPackVar` with M2's polar bound machinery. The decision is:

> **`TPackVar` does NOT participate in M2's polar lower/upper bound graph. It has
> a simpler binding discipline: a single mutable binding in a `pack_bindings`
> map, set once by unification (the §2 alignment rules), never carrying a
> lower/upper bound set and never coalesced.**

### 5.1 The discipline

- A `TPackVar` is a **pack metavariable**, stored in `pack_bindings` keyed by
  pack-var id (`op_sem.lua` `st.subst.pack_bindings`; op-sem §"TPack node":
  "exactly as `TRowVar` is stored in `row_bindings`"). **Unbound** = an open tail
  of unknown length; **bound to a `TPack`** = that tail spliced in (§3.2).
- It is bound **only** by the §2 alignment rules (`T-CEq-Pack-Open*`, the
  surplus/rest reconciliation of `T-CSub-Pack`). Binding is **unification**, not
  bound accumulation: the rule computes the unique tail that makes the alignment
  hold and writes it. There is no `B.lower`/`B.upper` for a pack var, no edge
  graph, no re-emission cross-product, no coalescing.
- It is **not** a `UVar` (`collect_uvars` ignores it — §1.3); it never enters the
  M2 union-find substitution; `CEq` on two pack-vars is a `pack_bindings` union
  (§2.1 OpenBoth), **not** a root merge.

### 5.2 Why a simpler discipline is correct (and why this is not under-powering)

The M2 polar bound graph exists because a **value-type variable** can flow into
*many* positions at *both* polarities and the principal type must accumulate a
union of lowers + an intersection of uppers, deferring the choice to coalescing
(M2 §5). A **pack variable** is structurally different:

- A pack var occupies **one tail position**, determined by **arity alignment**,
  not by subtyping flow. The alignment rules (§2) compute the tail
  *deterministically* from `min(n,m)` and the surplus — there is no lattice of
  candidate tails to accumulate. Once `min(n,m)` and the surplus are known, the
  tail is the unique pack that closes the gap; it is *unified*, not *bounded*.
- The **value types inside** a pack var's binding are still full lattice
  citizens and **do** flow through M2's bound graph: when `R ↦ pack([α], nil)`
  and `α` is a value-type uvar, `α` gets M2 lower/upper bounds as usual. The pack
  var carries no bounds; its *contents* do. So no expressiveness is lost — the
  subtyping flow happens on the value-type items (M2), the arity/length-poly
  happens on the pack var (a binding). The two concerns are cleanly separated.
- This matches the substrate exactly: `pack_bindings` is a flat `{id ↦ TPack}`
  map (`op_sem.lua`), parallel to `row_bindings`, *not* the `B.lower`/`B.upper`/
  `B.edge_*` structure M2 §2 defines for `UVar` roots.

### 5.3 Reconciliation with M2 — packs in value-type bounds

A pack var never *has* M2 bounds, but a **pack-typed value can be a bound value**
in M2's graph: a generic `pcall`'s constraint `<F: (...P) -> R>` records an
**arrow** (a value type) as `B.upper[r]` for some value-type variable `r`
(op-sem §"Interaction with Spec A (pack-typed bounds)"). M2 stores that arrow
**unchanged** — the bound value is just a value type (M2 §2: bounds are simple
types). When M2 re-emits `CSub(L, U)` against that pack-typed upper bound, the
obligation dispatches `T-CSub-Arrow → T-CSub-Pack` (§2–§3). **No new bounds
machinery is required**; M2's closure invariant `⋃lowers <: ⋂uppers` (M2 §3.5)
now includes pack-arity rejection as one of the ways a re-emitted `CSub` can be
rejected by the structural rules. This is the precise seam: **M2's bound graph
carries pack-typed value bounds opaquely and re-emits; M3's pack rules decide.**
(This parallels M1 §5.2's "the bound graph never understands negation; it
re-emits, the lattice decides" — here, the bound graph never understands pack
arity; it re-emits, M3 decides.)

---

## 6. Termination-cache reconciliation (with M2 §7)

M2 §7 makes the in-progress cache mandatory for termination on cyclic bound
graphs; its key (M2 §7.1) is `hash(⟨head(deref L), head(deref U)⟩)` where `head`
is the top-level constructor tag (plus the union-find root id for a uvar leaf).
M3 extends `head` for the pack constructor, adopting the substrate's
`pack_head_key` (`types.lua`; `op_sem.lua` cache extension):

```
head(deref pack) = ⟨ "pack", #items, rest-id-or-nil ⟩  ++  [per-item head hashes]
```

- The pack head is the token `⟨"pack", #items, rest-id-or-nil⟩` **plus** the
  per-item head hashes (so two packs of equal arity but different leading item
  shapes do not collide — `op_sem.lua` §"pack head"). `rest-id-or-nil` records
  closed-vs-open and, for open, the pack-var id.
- This is computed on the **deref'd** (spliced) pack (§3.2), so a bound `rest`
  has already been flattened into `items` before the key is taken — the key
  reflects the resolved arity, not a pre-splice shape. Two re-emissions that
  resolve to the same spliced pack therefore collide and the second is discharged
  by M2 §7.2 `S-Sub-CacheHit`.
- **Reconciles with M2's `O(K²)` argument (M2 §7.3).** The pack head is a finite
  token over a finite item set (Crescent types are regular — M2 §7.3), so adding
  the pack head shape keeps the set of distinct cache keys finite; pack
  obligations re-emit at most once per key, preserving the `O(K²)` bound. The
  pack head is **fully determined by the spec** (tag + arity + rest-id +
  per-item heads — no representation freedom), so both interpreters compute the
  **same** key and cut the **same** cycles (M2 §7.3 parity property extended to
  packs).

The M1 emptiness step budget (default `4096`, M1 §3.4) is **untouched** — it
bounds work *inside a single value-type emptiness decision*; a pack obligation
that re-emits a per-item value-type `CSub` with a non-trivial negation routes
that *item* obligation through M1's emptiness as usual. Packs add no new
unbounded loop: the splice is depth-bounded (§3.2), alignment is `min(n,m)`
(bounded by arity), and re-emitted item obligations are M2-cache-guarded.

---

## 7. Soundness alignment (constraints §A)

- **§A1 (soundness floor).** Pack subtyping never accepts an unproven relation:
  closed-contra arity mismatch **rejects** (§2.3); closed-co nil-pad emits
  `CSub(nil, B_i)` which **rejects** if `B_i` excludes `nil` (§2.3) — no silent
  arity coercion; the splice is purely substitutional and emits no unverified
  relation (§3.2). The variance split is the *sound* image of Lua adjustment, not
  a relaxation that admits unsound programs (the consumer's arity governs at both
  ends — §2.3 box).
- **§A2 (`unknown` never casts away) / §A3 (`any` does not exist).** Packs
  introduce no top/permissive pack; the empty pack is the void position, not a
  top (§4.1). A pack rule never widens an item obligation to `any`.
- **§A11 (behavior conservation).** §8's migration keeps the suite green; the
  pack substrate is already implemented and parity-tested (commit `b19adc82`), so
  M3's normative content is largely behavior-conserving over the current
  substrate (the open work is the M5 effect-component seam, §3.1, deferred to M5).
- **§A14 (single timeout).** Packs add no unbounded loop (§6); the splice is
  depth-bounded, alignment is arity-bounded, item obligations inherit M1's budget
  and M2's cache. The whole-file check stays within the §A14 ceiling.
- **B-series (provenance).** Per-item obligations carry the originating arrow
  constraint's provenance, so a pack-arity rejection blames the call/return site.

No item in §10 is closed by a hardcoded result: G17 is closed by the **pack
substrate as a general mechanism** (length-polymorphic alignment + splice +
variance-split), declarable for *any* callee arity — not a `pcall`-shaped or
`coroutine`-shaped special case. The mechanism is name-agnostic (op-sem
§"Substrate-before-consumers": no rule is keyed by a stdlib name or effect name).

---

## 8. Migration / blast-radius note (for the later implementation program)

M3's substrate is **already implemented and parity-tested** (Spec B part 1,
commit `b19adc82`): `types.lua` carries the `TPack`/`TPackVar` nodes, `M.pack`/
`M.packvar`, the pack-aware traversals, `deref_pack`, and `pack_head_key`; both
`op_sem.lua` and `op_sem_alt.lua` carry `T-CEq-Pack-*` and `T-CSub-Pack` with the
variance split. M3 records the remaining cost; it performs **no** migration.

1. **The M5 effect-component seam (§3.1) is the one open arrow change.** `TArrow`
   is `{args, ret}` today; M5 adds an effect slot and extends T-CEq-Arrow /
   T-CSub-Arrow. This is **M5's** blast radius, flagged here so M3's arrow rules
   are written not to assume the 2-tuple is final. The current
   `stdlib_types.lua` `effectful_fn` (`return_base & effect` in `ret.items[1]`)
   is the **anti-pattern M5 re-architects** — and is the reason M3 must keep the
   effect *off* the return pack: any M3 rule that reasoned about `ret.items[1]`
   as carrying an effect would entrench exactly what M5 must remove. M3's pack
   rules treat `ret.items` as ordinary value-type returns with no effect
   semantics, leaving the effect to M5's dedicated slot.
2. **The lattice-boundary guard (§4.1) is new normative content, not new code.**
   The substrate already never places a `TPack` inside a boolean node (packs are
   produced only by arrow/tuple construction and consumed only by the arrow/pack
   rules). §4.1 makes the *invariant* normative so M1's `Neg`/RDNF additions
   (M1 §7 blast radius) cannot accidentally admit a pack operand. The
   implementation cost is an assertion/ill-formedness guard at the boolean-node
   constructors, not a rule change.
3. **Cache-key extension is already present** (`pack_head_key`); M3 only pins it
   normatively against M2 §7 (§6). No migration.

**Keep, do not rewrite** (substrate decisions M3 reconciles *in*, unchanged): the
`TPack`/`TPackVar` nodes and `pack_bindings` map; `deref_pack` (the splice); the
four `T-CEq-Pack-*` cases; `T-CSub-Pack` with the variance split; `pack_head_key`.
These are the Spec-B-part-1 decisions M3 adopts verbatim.

**Parity discipline (carries forward).** Both `op_sem.lua` and `op_sem_alt.lua`
already encode the pack rules independently; the parity fixtures are a deliverable
of the implementation program. M3's spec is written as relations + bindings +
the pinned splice/alignment/cache-key (not a single reference implementation), so
the two encodings remain possible and align/splice/terminate **identically**: the
three parity-load-bearing quantities are (a) the `min(n,m)` alignment, (b) the
variance-split closed-closed branch (§2.3), and (c) the `pack_head_key` (§6) —
all fully spec-determined.

**Behavior conservation (§A11).** The pack substrate already passes the suite at
`b19adc82`; M3 adds normative framing (the lattice boundary §4, the pack-var
discipline §5, the cache reconciliation §6) and the M5 seam (§3.1), none of which
change current behavior. The only behavior-affecting future change is M5's effect
component, scheduled in M5.

---

## 9. Open questions (for the reviewer — genuine forks not resolved unilaterally)

1. **Pack-var occurs-check across the splice.** **RESOLVED — pinned in §3.2.**
   The splice is depth-bounded by a `seen` set of pack-var ids (`deref_pack`), so
   a malformed cyclic `rest` binding terminates. A *correct* solver never binds a
   pack var's `rest` to a pack whose tail transitively reaches the same var
   (alignment binds to fresh/already-resolved vars). M3 treats the cyclic case as
   ill-formed-but-guarded, not a semantic feature. No fork: the guard is in the
   substrate and the well-formed discipline is stated.

2. **`CSub_co` nil-pad and `nil`-admitting returns.** **RESOLVED — pinned in
   §2.3.** When `n < m` on a covariant closed pack, the missing positions emit
   `CSub(nil, B_i)`; if `B_i` excludes `nil` this **rejects** (sound — the caller
   asked for a non-nil `m`-th return the callee never produces). This is the
   intended strictness: nil-pad is *not* a license to silently satisfy a
   non-optional requested return. No fork.

3. **Tuple-as-value inside a boolean operator (the §4.2 wrapper).** **DEFERRED —
   confirm jointly at M7/M8.** §4 fixes that a *raw* `TPack` is never a lattice
   operand. A **tuple value** `{number, string}` used in `T | U` or matched in M8
   must be admitted as a **value-type atom** (a closed-pack-shaped constructor
   wrapper that *is* a lattice citizen, its internal pack not). Whether M7 (records
   /tuples) introduces an explicit `Tuple` constructor wrapper distinct from the
   bare arg/ret `TPack`, or treats a closed `TPack` as directly atom-able when it
   appears in value position, is an M7/M8 detail. M3's lean: a closed `TPack` in
   value position is wrapped/atom-treated by M7's record-family rules (a tuple is
   a positional record-shaped atom for lattice purposes), so M3 introduces no
   separate wrapper. Conservatively sound either way (the boundary — raw pack ∉
   boolean operand — is fixed here; only the value-position wrapper shape is
   deferred). Confirmed jointly with M7 (tuple value subtyping) and M8 (matching
   a tuple scrutinee).

4. **Variadic *kind* — does a pack var need a kind under M4?** **DEFERRED — confirm
   jointly at M4.** A `TPackVar` is a pack metavariable, not a type variable (§5),
   so it has no value-type kind. But M4 (HKT/kinds) introduces type-constructor
   variables; whether a pack var is a degenerate kind (`Pack` as a kind alongside
   `Type` and `Type → Type`) or stays entirely outside the kind system is an M4
   question. M3's lean: pack vars are **outside** the kind system (a binding-time
   arity device, not a kinded entity), parallel to row vars. Conservatively sound
   (M3's pack rules never consult a kind); confirmed jointly with M4 when kinds
   are specified.

---

## 10. Closes

- **G17** (`v5-gaps.md`):
  > *"Variadic generics needed for accurate `pcall` and `coroutine.resume`
  > arg-list/return-pack typing; current 5.F2 approximation correct for
  > known-arity callees only — docs/typechecker-v5-handoff-2026-05-26.md §4"*

  Closed by the **pack substrate as a general length-polymorphic mechanism**: the
  `TPack`/`TPackVar` nodes (§1), arity-aware equality/subtyping with `min(n,m)`
  open/closed alignment and the variance-split closed-closed arity (§2), the
  substitution-time splice `R↦pack` / `R↦never` (§3.2), and the arrow built over
  packs (§3.1). A generic callee of **unknown arity** `<F: (...P) -> R>` is now
  expressible: `P` binds the actual argument tail and `R` the actual return tail
  via alignment + splice, so `pcall(f, ...)` types the forwarded args and the
  `(true, ...R) | (false, E)` result *for any `f` arity*, not just known-arity
  callees. **This unblocks the ad-hoc-elimination program (M-final):** the
  name-keyed `build_pcall_ret` / `build_coroutine_create_ret` handlers
  (`v5-gaps.md` adhoc-cluster, Y1) can be replaced by ordinary `--::` declarations
  that the pack rules solve — the substrate G17 names as missing is now specified.
  Substrate mechanism, name-agnostic (§7), not a `pcall`/`coroutine`-shaped patch.

  G17 is **consumed** (not re-closed) by M-final, which deletes the handlers; M3
  supplies the variadic-generics substrate M-final's `pcall`/`coroutine`/iterator
  declarations lower onto.

(G17 is the sole `v5-gaps.md` item M3 closes; the broader adhoc-cluster / Y1 are
M-final's, gated on M3 + M4 + M5 + M8 + M11 per the module map.)
