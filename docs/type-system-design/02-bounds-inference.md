# M2 — Bounds and inference

*Normative module spec of the unified type-system design. Depends on **M1**
(`01-lattice-and-subtyping.md`). M2 realizes the bound-graph interface M1 §5
fixed: it specifies polar lower/upper bounds per variable, their transitive
closure, polar coalescing at generalization, recursive μ-types via hash-consing,
and the mandatory in-progress cache that makes the whole thing terminate. Aligns
to `docs/type-system.md` (philosophy, fixed — "infer aggressively, widen
reluctantly", principal types) and satisfies the soundness floor of
`docs/typechecker-v5-constraints.md` §A.*

Primary sources reconciled here:

- `docs/typechecker-rewrite-design.md` §2.2 (bound propagation, the cache),
  §2.2 "Coalescing" (polar coalescing + μ via hash-consing), §4.1–4.2 (simple
  vs RDNF representations). **The canonical statement of the algorithm.**
- `docs/typechecker-v5-operational-semantics.md` § "Simple-sub bounds
  (normative)" — the v5 "Spec A" bound graph already implemented this session
  (state `⟨σ, W, I, B, C⟩`, the three T-CSub-TVar cases, the termination cache,
  polar coalescing at quiescence). **M2 ADOPTS Spec A as its realization** and
  reconciles it with M1's lattice.
- simple-sub (Parreaux, ICFP 2020) — polar bounds, level-based generalization,
  recursive-type detection via hash-consing, coalescing into compact types.
- MLstruct §3.2 (Parreaux & Chau, OOPSLA 2022) — bounds-and-transitive-closure
  construction; the regular-types cache argument for termination.

M1 owns the lattice, RDNF, complement, the emptiness procedure, and the step
budget (default `4096`). **M2 does not redefine any of them**; it routes bound
re-emissions through them and cites them.

---

## 1. Frame: what M1 fixed, what M2 fills in

M1 §5 fixed the **interface** between the RDNF lattice (which handles structure)
and the **polar bound graph** (which handles type variables). The fixed points
M2 builds on, verbatim from M1 §5.1:

- **Two relations on variables, one addressing scheme.** `CEq` (`α := τ`) uses
  the union-find substitution and **merges roots**; subtyping between two unbound
  variables (`α <: β`) records a **directional edge** `α → β` and does **not**
  merge. All bound storage and edges are keyed by the union-find **root**
  (`subst.find(id)`).
- **Three variable cases, each done-with-re-emission** (Upper, Lower, Flow), all
  cache-guarded.
- **The closure invariant** `⋃lowers <: ⋂uppers`, *maintained* by eager
  re-emission, **not separately checked**.
- **Bind verifies bounds.**
- **The mandatory in-progress cache** (record-before-recursion).
- **Bounds are simple types that MAY contain `¬τ`** (M1 §5.2); the bound graph
  re-emits and the lattice decides — the bound graph never understands negation.
- M1 §5.3 **forbids** re-introducing the v5 "meet of uppers" shortcut.

M2 fills in what M1 §5 deferred:

1. The **full state and propagation rules** for the three variable cases and the
   merge (§2–§4 — adopting Spec A, reconciled with M1's decomposition).
2. **Polar coalescing at generalization** (§5) — positive var → union of lowers,
   negative var → intersection of uppers, μ-wrapping of recursive bounds.
3. **Recursive μ-types via hash-consing** (§6) — representation, lazy expansion,
   recursion detection.
4. The **termination cache** (§7), specified precisely enough that both
   interpreters terminate identically.

M2 introduces **no new constraint kind** (M1 §3: the closed vocabulary is
`{ <: }`; `CEq` is the conjunction of both directions). Bounds, coalescing, μ,
and the cache are *mechanisms over* `CSub`/`CEq`, not new constraints.

---

## 2. State: the polar bound graph

The solver state `⟨σ, W, I⟩` (M1 §6, from the v5 substrate's worklist machine)
is extended to `⟨σ, W, I, B, C⟩`, adopting Spec A's components verbatim:

| Component | Meaning |
|-----------|---------|
| `B.lower : Root → Set<SimpleType>` | per-root **lower-bound set**. `L ∈ B.lower[r]` means `L <: α` for every α with `find(α)=r`. |
| `B.upper : Root → Set<SimpleType>` | per-root **upper-bound set**. `U ∈ B.upper[r]` means `α <: U`. |
| `B.edge_up : Root → Set<Root>`   | bound-graph out-edges. `r' ∈ B.edge_up[r]` iff `α <: β` was recorded (α∈r, β∈r'). |
| `B.edge_down : Root → Set<Root>` | the dual in-edges, so lower-bound propagation walks predecessors without a graph search. |
| `C : Set<Hash>` | the in-progress / termination cache (§7). A hash is in `C` iff that `CSub(L,U)` obligation has been discharged-or-assumed. |

**Bounds are simple types (M1 §2.1, §5.2), not RDNF.** A member of `B.lower[r]`
or `B.upper[r]` is a primitive, literal, constructor application, boolean
combination **including `Neg`**, quantifier wrapper, or `Mu`. They are stored
**unnormalized**; RDNF is computed only when a re-emission routes a non-trivial
negation into M1's emptiness procedure (§3.3) or at coalescing (§5). This is the
M1-interface seam (§8).

**Canonical location.** `B` and `C` live in the substitution
(`lib/type/experiments/v5_perf/subst.lua`) keyed by root, **migrated on union
alongside watchers** — the decided design of Spec A. They are written into the
abstract machine state purely so the two interpreters agree on what is
observable; they impose no representation beyond "keyed by root, monotone".

**Monotonicity (load-bearing).** `B.lower`, `B.upper`, `B.edge_up`, and `C` only
ever **grow** (union merges entries, never net-loses an obligation). No bound is
ever retracted. This preserves the monotone-σ premise behind M1 §6's `S-Wake`
and the termination order, and is the reason re-emission can be eager without
risking an oscillation.

**Set membership and dedup** are modulo `types.equal` after `deref` (Spec A's
`bounds_contains`). `B.edge_up`'s reflexive-transitive closure is materialized
eagerly (§3), so "does `L` flow to `U`" never walks the graph at query time.

---

## 3. The three variable cases (transitive closure by eager re-emission)

After `deref`, when at least one side of a `CSub` is an unbound `UVar`, exactly
one of three cases applies. **None park** (none are stuck): each is **done with
re-emission**, possibly emitting transitive obligations, all cache-guarded (§7).
This is the central reconciliation with M1 §6 — the bound graph is *not* a second
wake substrate; its progress is driven entirely by emission onto `W` at the
moment a bound or edge is added.

### 3.1 Upper — `α <: T`

LHS an unbound uvar, RHS non-uvar. Add `T` to the root's upper set; for **every**
existing lower `L`, re-emit `CSub(L, T)` (cache-guarded) to maintain the closure.

```
σ⟦τ_a⟧ = UVar(α)    r = find(α)    σ⟦τ_b⟧ = T    T not a uvar
B' = B with T added to upper[r]
─────────────────────────────────────────────────────────────────  T-CSub-TVar-Upper
σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [ CSub(L, T) | L ∈ B.lower[r] ]_cache, done⟩   B := B'
```

### 3.2 Lower — `T <: α`

RHS an unbound uvar, LHS non-uvar. Add `T` to the root's lower set; for **every**
existing upper `U`, re-emit `CSub(T, U)` (cache-guarded).

```
σ⟦τ_b⟧ = UVar(α)    r = find(α)    σ⟦τ_a⟧ = T    T not a uvar
B' = B with T added to lower[r]
─────────────────────────────────────────────────────────────────  T-CSub-TVar-Lower
σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [ CSub(T, U) | U ∈ B.upper[r] ]_cache, done⟩   B := B'
```

### 3.3 Flow — `α <: β` (distinct roots)

Both sides unbound uvars with **distinct** roots. Record the directional edge
`r_α → r_β`. Per M1 §5.1 and the **Spec A bound-flow CORRECTION (sound
direction)**: for edge `α → β` (`α <: β`), a **lower** `L` of α flows **forward**
to β (`L <: α <: β ⇒ L <: β`); an **upper** `U` of β flows **backward** to α
(`α <: β <: U ⇒ α <: U`). Re-emit the cross-product these create (cache-guarded).
**Do not merge the roots** — merge is reserved for `CEq` (§4).

```
σ⟦τ_a⟧ = UVar(α)   σ⟦τ_b⟧ = UVar(β)   r_α = find(α)   r_β = find(β)   r_α ≠ r_β
B' = B with r_β added to edge_up[r_α]  (and r_α to edge_down[r_β]),
            B.upper[r_β] ∪-added into upper[r_α]   -- uppers of β flow back to α
            B.lower[r_α] ∪-added into lower[r_β]   -- lowers of α flow forward to β
emitted = [ CSub(L, U) | L ∈ lower[r_α]', U ∈ upper[r_β]' ]_cache
─────────────────────────────────────────────────────────────────────────────  T-CSub-TVar-Flow
σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, emitted, done⟩   B := B'
```

(`r_α = r_β`: reflexive, discharged with no change — subsumed by M1's
`T-CSub-Refl`.)

> **Spec A migration note (sound-direction).** Spec A's original prose said "α's
> uppers flow to β; β's lowers flow to α", which the P2.1 CORRECTION found
> **inverted and unsound** (it dropped the transitive obligation `L <: α <: β ⇒
> L <: β`, e.g. a multi-return value losing a conflict with a later annotation).
> M2 normatively adopts the **corrected** direction above (lowers forward,
> uppers backward) — the standard simple-sub / MLstruct §3.2 closure. Both
> interpreters MUST encode this direction; the inverted prose is superseded.

### 3.4 Why eager re-emission gives transitive closure

The flow rule is **transitive in one step only**; deeper transitivity is achieved
because (a) each flowed-in bound is itself re-emitted as a `CSub(L, T)` /
`CSub(T, U)` against the *concrete* uppers/lowers via §3.1/§3.2, and (b) adding
an edge into a node that already has out-edges flows along them. The eager-closure
**on-add invariant**: *whenever an edge or a bound is added, the obligations its
addition creates are re-emitted in the same step, before the step completes.*
Neither interpreter may defer re-emission to quiescence. Cyclic edge-graphs are
made to terminate by the cache (§7).

### 3.5 The closure invariant is maintained, never separately checked

`⋃ B.lower[r] <: ⋂ B.upper[r]` holds because every lower meets every upper through
a re-emitted `CSub` (§3.1–3.3). It is **not** a separate check (M1 §5.1). A genuine
violation — e.g. `integer <: α` and `α <: string` — surfaces as a re-emitted
`CSub(integer, string)` that M1's atomic/structural rules (M1 §3.1) reject, blamed
at the originating constraint's provenance (M1 §6 B-series). This is the precise
sense in which the bound graph "re-emits and the lattice decides" (M1 §5.2).

---

## 4. CEq: bind-verifies-bounds and merge-reconciliation

### 4.1 Bind verifies bounds

Binding a root to a concrete type must honor the accumulated bounds. `T-CEq-Bind`
(M1 §5.1) is: bind as before (occurs-check unchanged), then **verify** every
accumulated lower `L <: τ` and upper `τ <: U` by re-emitting those `CSub`s
(cache-guarded).

```
σ⟦τ_a⟧ = UVar(α)   r = find(α)   σ⟦τ_b⟧ = τ   τ not a uvar   α ∉ FV(τ)
─────────────────────────────────────────────────────────────────────────  T-CEq-Bind-Bounds
σ ⊢ CEq(τ_a, τ_b) ⇒
  ⟨σ[r ↦ τ],
   [ CSub(L, τ) | L ∈ B.lower[r] ]_cache ++ [ CSub(τ, U) | U ∈ B.upper[r] ]_cache,
   done⟩
```

A bound that τ violates surfaces as an ordinary subtyping error. After binding,
the root's bound sets are **retained** (they remain valid facts about a
now-concrete root; re-emission keys include root identity, so no rework loops).

### 4.2 Merge reconciles bounds AND edges

`CEq(α, β)` between two unbound uvars merges roots via union-find (smaller id
wins, for determinism — M1 §6). The extension reconciles `B`:

```
r_w = winner, r_l = loser (after union)
lower[r_w] := lower[r_w] ∪ lower[r_l]      upper[r_w] := upper[r_w] ∪ upper[r_l]
edge_up[r_w] := edge_up[r_w] ∪ edge_up[r_l]    (and dually edge_down)
emitted = [ CSub(L, U) | L ∈ lower[r_w], U ∈ upper[r_w] ]_cache   -- only cross-pairs are new
──────────────────────────────────────────────────────────────────────────────────  T-CEq-UU-Bounds
σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ ∪ {α ↔ β}, emitted, done⟩
```

The migration *is* the existing `subst.union` watcher-migration loop extended to
the bound/edge maps. Because merge collapses the directional distinction, any edge
`r_l → r_w` or `r_w → r_l` becomes a self-loop on `r_w` and is **dropped** (a node
trivially flows to itself). The cross-pair re-emission is cache-guarded, so it
cannot loop on a cyclic graph. Equality is thus **stronger** than mutual
subtyping: merging may discard the directional distinction precisely because `CEq`
asserts both directions at once. This is the "later CEq merge reconciles two
variables' edges/bounds" requirement (M1 §5.1).

> **Reconciliation with M1's no-"meet of uppers".** M1 §5.3 forbids restoring the
> v5 pre-Spec-A "meet of uppers at quiescence" path (a single representative upper
> computed by meeting all uppers). M2 honors this: §4.1/§4.2 verify bounds and
> reconcile by **re-emitting `CSub`s** that route through M1's decomposition and
> emptiness, **not** by collapsing the upper set into one meet. The polar bound
> sets are coalesced **only at generalization** (§5), never mid-solving.

---

## 5. Polar coalescing at generalization

After inference reaches a generalization boundary, each root that is still
**unbound** but carries bounds is coalesced into a user-facing / cache-facing type
by **polarity** (simple-sub coalescing; rewrite-design §2.2 "Coalescing"). This is
the principled treatment that M1 §5.3 mandated in place of meet-of-uppers.

### 5.1 The polar rule

- A root occurring **positively** (a value flowing *out* — produced) coalesces to
  **`⋃ B.lower[r]`**, the union of its lower bounds.
- A root occurring **negatively** (a value flowing *in* — consumed) coalesces to
  **`⋂ B.upper[r]`**, the intersection of its upper bounds.
- A root occurring at **both** polarities is retained as a variable in the output
  (the simple-sub "compact type" keeps such variables), carrying **both** a lower
  face and an upper face.
- An empty lower set coalesces to **`never`** (`⊥`); an empty upper set to
  **`unknown`** (`⊤`) — the lattice top/bottom (M1 §1.1).

**Polarity (normative — same weight as M1's parity pins).** A position is
**positive** if reached through an **even** number of enclosing **contravariant
flips** from a producing occurrence, **negative** if **odd**. The contravariant
flips are exactly two kinds: **(a) arrow-argument positions** (M1 §3.1
contravariant args) **and (b) `Neg`/complement occurrences** — negation is
contravariant (`A <: B ⟺ ¬B <: ¬A`, M1 §3.2), so each enclosing `~`/complement
is a flip on equal footing with an arrow argument. Arrow returns and covariant
constructor positions preserve polarity. This polarity is the *same* polarity M1's
structural decomposition already threads; M2 reuses it, it is not a second notion.

**Consequence (coalescing against the opposite polar face).** A variable reached
through an **odd** number of `~`/complement occurrences is in **negative**
position and therefore coalesces against the **opposite** polar face: an
occurrence that would otherwise be positive (`⋃ B.lower[r]`) coalesces instead to
`⋂ B.upper[r]` when nested under one `~`, and a would-be-negative occurrence
coalesces to `⋃ B.lower[r]` — each additional `~` flips the face again.

**Scope of the parity rule (the M1 §3.2 move-across case).** A `¬τ` **bound
value** produced by M1's §3.2 move-across rule (e.g. `τ₁ ∧ ¬τ₂` recorded as a
*lower* of `α`) raises **no** polarity question for the variable that **owns** the
bound: that variable owns a lower, so it is in positive position and coalesces to
`⋃ B.lower[r]` as usual — the leading `¬` lives *inside the bound value*, not on a
path to the owning variable. The parity rule above applies only to a variable
**nested inside** such a `¬τ` (i.e. a variable on a path that passes through the
complement): that nested variable is reached through one `~` and so coalesces
against the opposite face per the consequence above. Internal-vs-user-written
makes no difference — parity is **structural** over arrow-args + `Neg`, not
sensitive to how the `¬τ` arose.

### 5.2 Generalization points and levels

Coalescing fires at **generalization boundaries**, where a binding's inferred type
is closed over the variables introduced at its level and not escaping into the
enclosing context. M2 commits to **simple-sub level-based generalization** (the
discipline `type-system.md` §"Infer aggressively, widen reluctantly" requires for
principal types, and that rewrite-design §6 names as the foundation): each fresh
variable carries the **level** at which it was introduced; a variable generalizes
at a boundary iff its level is deeper than the boundary's and it does not occur in
the type of any binding at an outer level.

> **Scope seam with M13 (rank-N).** M2 owns the *let-level* generalization
> mechanism (close over not-escaping variables; coalesce by polarity). M2 does
> **not** own deep-skolemization at higher-rank subsumption points, the skolem
> escape check, or where to skolemize nested binders — those are **M13**. M2's
> level machinery is the substrate M13 lifts to arbitrary rank; M13 may add
> skolem introduction points but does not change the polar coalescing rule here.
> This is the substrate-before-consumers split (M2 substrate, M13 consumer).

### 5.3 Coalescing-time simplification (and only then)

The dominated-bound drop (`integer & number → integer`, `string | "GET" → string`
on the union side) and the boolean-algebra simplifications (distributivity,
factorization, `T & ~T = never`, hash-consing) are applied **only here, at
coalescing** — never mid-solving, where they would prematurely commit and break
principal types. This is Spec A's `reduce_intersection` / `structurally_subtype`
pair, **repurposed**: both interpreters MUST ensure they are *not* invoked during
constraint solving, only when materializing the coalesced form. The result of
coalescing-plus-simplification is M1's user-facing "compact type" (M1 §2.2): RDNF
plus the simplification pipeline. Hash-consing the post-simplification form
(M1 §2.2) gives the structural equality the subtyping cache, match-arm dispatch
(M8), and IDE hover rely on.

### 5.4 Principal types are preserved

Coalescing **reads** accumulated bounds; it never *chooses* a representative
mid-inference. Because the solver accumulates a union of lowers and an
intersection of uppers and defers the choice to this point (rewrite-design §2.2),
and because §3 maintains the full transitive closure losslessly, the coalesced
type is the **principal** type for the binding — the most general type consistent
with all constraints (simple-sub's central guarantee). This is the M2 obligation
under `type-system.md` Principle 1; the no-meet-of-uppers discipline (M1 §5.3,
§4.2) exists precisely to keep it.

---

## 6. Recursive μ-types via hash-consing

A variable whose bounds mention itself denotes a **recursive type**. M2 represents
these with the equi-recursive `Mu(X, T)` constructor (M1 §1.1; full lattice-closure
treatment is **M12**, which M2 feeds).

### 6.1 Detection at coalescing (hash-consing)

During the coalescing walk (§5), recursion is detected by **hash-consing** (Parreaux
2020; rewrite-design §2.2): the walk records, in an **in-progress map keyed by
root**, each root it is *currently* coalescing. If the walk re-encounters a root
already in that map — `B.lower[r]` or `B.upper[r]` transitively mentions `r` — it
emits a **back-reference** to the μ-binder for that root instead of recursing,
and wraps the completed result in **`μX. …`** with `X` standing for `r`. The
in-progress map is the coalescing-time analogue of the §7 solving-time cache: both
are *record-before-recursion* to cut a cycle.

### 6.2 Representation and lazy expansion

`Mu(X, T)` is **equi-recursive**: `μX. T ≡ T[X ↦ μX. T]` (M12). The representation
is the folded form `Mu(X, T)`; expansion is **lazy** — a `Mu` is unrolled one step
only when a structural rule (M1 §3.1) needs to inspect its head, and the unrolled
copy is **hash-consed** so repeated unrollings of the same μ share structure and
compare by identity. Lazy + hash-consed expansion is what keeps the lattice's
operations terminating over recursive types (the regular-types property).

### 6.3 μ-wrapping of recursive bounds is new substrate (blast radius)

The v5 substrate's Spec A coalescing *names* μ-wrapping (op-sem § "S-Quiesce —
polar coalescing", the recursive-bound bullet) but the substrate has **no `Mu`
node wired through coalescing** yet. M2 makes μ-wrapping of recursive bounds
**normative**, which is **new substrate** for the implementation program (see §9
blast-radius). It depends on M1's `Mu` constructor being present (M1 §1.1) and on
M12's lattice-closure rules; M2 specifies the *detection-and-wrap at coalescing*,
M12 specifies *how the lattice's operations close over the resulting `Mu`*.

---

## 7. The mandatory in-progress cache (termination)

Termination is a **soundness-class concern** (M1 §6 §A14; rewrite-design §2.2):
re-emission on a cyclic bound graph diverges without the cache. The cache is
**mandatory, not an optimization**.

### 7.1 Cache key

```
key(L, U) = hash(⟨head(deref L), head(deref U)⟩)
```

where `head` is the **top-level constructor tag** plus, **for a uvar leaf, its
union-find root id** (so two syntactically-distinct uvars sharing a root collide,
and a uvar vs a different root does not). Two obligations with equal keys are the
same obligation. This is M1 §5.1's "structural head hash including the union-find
root id", stated for re-emission.

### 7.2 Record-before-recursion

```
k = key(L, U)    k ∈ C
──────────────────────────────────────  S-Sub-CacheHit
CSub(L, U) ⇒ ⟨σ, ε, done⟩            (the relation is ASSUMED to hold; emit nothing)

k = key(L, U)    k ∉ C
──────────────────────────────────────  S-Sub-CacheMiss
CSub(L, U) ⇒ process normally, with C := C ∪ {k} recorded BEFORE recursion
```

The record-before-recursion ordering is what cuts cycles: a regular type whose
bound graph forms a loop re-encounters its own key and discharges via
`S-Sub-CacheHit` rather than re-emitting forever. **Every** obligation re-emitted
by §3 and §4 is gated by this cache.

### 7.3 Termination argument (precise, and identical across interpreters)

The state space decreases along the M1 §6 well-founded order (σ extends
monotonically; `W` shrinks one per step; `I` reactivations are bounded). The
**one** source of re-emission *not* structurally smaller than its antecedent is
the bound-add re-emission of §3/§4 (the re-emitted `CSub(L, U)` may have arbitrary,
possibly cyclic, `L`, `U`). Termination for that source is recovered **only** by
the cache:

- Crescent types are **regular** (finite under the μ-folding §6 induces) and σ
  allocates finitely many tvars, so the set of distinct `(deref L, deref U)` keys
  reachable by re-emission is **finite** — its size is `O(K²)` where `K` is the
  number of distinct deref'd subterms across the constraint set.
- Each key is re-emitted-from at most once before its entry is in `C` (record-
  before-recursion), so total re-emission work is `O(K²)`, finite.

This is MLstruct §3.2 ("type-variable bound graphs may contain cycles, and since
types are regular the cache guarantees termination") transcribed to the op-sem.

**Identical across interpreters (parity).** Termination rests on three quantities
that are **fully determined by the spec, not by an implementation**: (a) the cache
key (§7.1 — head tag + union-find root id, no representation freedom); (b) the
record-before-recursion ordering (§7.2); (c) the μ-detection in-progress map
(§6.1 — keyed by root, same key shape). Because all three are pinned, both
`op_sem.lua` and `op_sem_alt.lua` cut the **same** cycles at the **same** points
and reach quiescence on the **same** state. The emptiness step budget that bounds
a *single* negation decision (default `4096`) is **M1's**, not M2's — M2 inherits
it unchanged; the §7 cache bounds the *number of re-emitted obligations*, M1's
budget bounds the *work inside one emptiness decision*. The two are orthogonal and
together give whole-file termination within `type-system.md` / §A14's ceiling.

### 7.4 Cache and `CEq` merges (M1 open-question 3, resolved here)

M1 deferred to M2 the question of whether a `CEq` merge needs a cache rekey. **M2
resolves it: no rekey is required.** When a merge changes a loser root's id,
prior cache entries keyed on the loser are **stale-but-harmless**: each such entry
records that an obligation was *assumed to hold*, and after the merge that
obligation is **subsumed** by the winner root's (now-unioned) bounds — assuming a
now-stronger fact is monotone and sound. The cross-pair re-emission of §4.2 is
itself cache-guarded against the **winner** root's keys, so the merge re-establishes
closure without needing the stale entries invalidated. A rekey would cost a pass
over `C` per merge for no soundness gain; M2 does not require it. (Should a future
need arise it remains M2's owner, but none is identified.)

---

## 8. The M1-interface seam

The single place M1's lattice and M2's variable layer meet (M1 §5.2):

- **Bounds are simple types in the full lattice, including `Neg`.** §3's `T`, `L`,
  `U` may be any simple type, and the §3.2 move-across-via-negation rule (M1 §3.2)
  produces bounds containing `¬τ` (e.g. `τ₁ ∧ ¬τ₂` as a lower of `α`). M2's bound
  graph stores them **unchanged**.
- **The bound graph never understands negation; it re-emits, the lattice decides.**
  When a re-emitted `CSub(L, U)` has a non-trivial negation in `L` or `U`, M2's
  re-emission routes it into M1's **emptiness procedure** (M1 §3.3–3.4): `L <: U`
  becomes `dnf₀(L ∧ ¬U) ≡ never`, bounded by M1's step budget, with M1's
  conservative post-timeout disposition (reject, never widen).
- **Coalescing produces simple types that flow into M1's RDNF/emptiness** (§5.3):
  the coalesced `⋃lowers` / `⋂uppers` are simple types; the compact-type
  materialization runs them through M1's RDNF + simplification. This is **new
  relative to Spec A**, whose coalescing produced ad-hoc reduced forms with no
  `Neg` and no RDNF — see §9.

The seam is closed: M2 adds nothing to M1's decision procedures; it feeds them.

---

## 9. Migration / blast-radius note (for the later implementation program)

M2 changes the implemented Spec A substrate (commit `20f66c53`) in three ways. M2
does **not** perform the migration (the design program writes no code); it records
the cost.

1. **Coalescing must produce simple types that flow into M1's RDNF/emptiness.**
   Spec A's coalescing (`reduce_intersection` / `structurally_subtype` at
   quiescence) produces ad-hoc reduced forms over a substrate with **no `Neg` and
   no RDNF**. Once M1 adds `Neg` and the RDNF normalizer, coalescing must emit
   simple-type unions/intersections (possibly containing `Neg` from the §3.2
   move-across rule) and materialize the compact type through M1's RDNF +
   simplification pipeline. This is the largest M2-attributable change and is
   **gated on M1's `Neg` + normalizer** landing first (substrate-before-consumers).
2. **μ-wrapping of recursive bounds is new** (§6.3). Spec A *names* the recursive-
   bound bullet but the substrate has no `Mu` wired through coalescing. The
   implementation adds: hash-consing detection during the coalescing walk (in-
   progress map keyed by root), `Mu(X, T)` construction, and lazy + hash-consed
   expansion. Gated on M1's `Mu` constructor and feeds M12.
3. **Bounds/edges migrate into `subst.lua`, both interpreters read one substrate.**
   `op_sem.lua` currently keeps `upper_bounds`/`lower_bounds` on `OpSemState`; the
   migration moves `B` (and `C`) into the substitution keyed by root, migrated on
   union by the existing watcher-migration loop. This **resolves R1**: both
   interpreters read the same substrate rather than one lagging the other.

**Keep, do not rewrite** (Spec A decisions M2 reconciles *in*, unchanged): the
union-find substitution; the three-cases / merge structure (§3–§4 — adopted from
Spec A verbatim except the sound-direction correction, which is already in P2.1);
the termination cache protocol (§7 — adopted verbatim); the keys-by-root
discipline.

**Parity discipline (carries forward).** Both `op_sem.lua` and `op_sem_alt.lua`
must **independently** encode M2 (§3–§7); the parity fixtures are a deliverable of
the implementation program. M2's spec is written as relations + re-emissions +
pinned cache/μ keys (not a single reference implementation) so two independent
encodings remain possible and terminate identically (§7.3). **R1** is resolved by
both interpreters encoding §3–§7 from this spec, not by one catching up to the
other — the empirical divergence (`CSub(?x,integer); CSub(?x,number)` →
`op_sem` 0 errors, `op_sem_alt` 1 error) disappears once both implement the three
cases + cache.

**Behavior conservation (§A11).** The test suite stays green at every migration
commit; behavior is conserved, mechanism is not. Stage: migrate `B`/`C` into
`subst.lua` → encode three cases + cache in both interpreters (closes R1) → route
re-emitted negations through M1's emptiness → coalescing emits simple types into
RDNF → μ-wrap recursive bounds. Each stage a green commit.

---

## 10. Soundness alignment (constraints §A)

- **§A1 (soundness floor).** No bound is ever retracted (§2 monotonicity); the
  closure invariant surfaces violations as rejected `CSub`s (§3.5); re-emitted
  negations route through M1's emptiness, whose timeout disposition **rejects**
  (M1 §3.4). M2 never admits an unproven `<:`.
- **§A2 (`unknown` never casts away) / §A3 (`any` does not exist).** An empty
  upper set coalesces to `unknown` (§5.1) — the honest top, not a permissive
  cast; coalescing introduces no `any` and no escape hatch.
- **§A11 (behavior conservation).** §9 staged migration keeps the suite green.
- **§A14 (single timeout).** §7's cache + M1's step budget keep the whole-file
  check terminating within the §A14 ceiling; §7.3's `O(K²)` re-emission bound is a
  deterministic count, tightening never loosening §A14.
- **B-series (scheduling/provenance).** M2 adds no new wake substrate (§3 — done,
  not stuck); re-emitted obligations carry the originating `CSub`'s provenance
  (§3.5), so conflicts and timeouts blame the source expression.

No item below is closed by a hardcoded result: each is a substrate mechanism
(bound graph, cache, polar coalescing, μ-detection), per the CLAUDE.md planning
rules and the README cross-walk discipline.

---

## 11. Closes

- **bounds-spec-gap (FULL)** (`v5-gaps.md`):
  > *"Uvar-bounds substrate (5.F4 … upper/lower sets, meet-at-quiescence,
  > compatible-bound reduction, integer<:number lattice) lives only in
  > op_sem.lua — never in docs/…-operational-semantics.md (still says 'route to
  > CEq, no bounds'). Dual-interpreter premise broken until specified. DECISION
  > 2026-05-27: adopt fuller simple-sub (polar bounds + transitive L<:T
  > re-emission) per typechecker-rewrite-design.md §2.2; spec-first then
  > dual-encode."*

  M1 fixed the interface (partial). **M2 specifies the full mechanism**: polar
  lower/upper bound sets with transitive closure (§3), bind-verifies-bounds and
  merge-reconciliation (§4), polar coalescing at generalization (§5), μ via
  hash-consing (§6), the mandatory cache (§7). The meet-of-uppers shortcut is
  **not** restored (§4.2, honoring M1 §5.3); coalescing is polar, at
  generalization only. Substrate mechanism, not a result.

- **R1** (`v5-gaps.md`):
  > *"op_sem_alt.lua no longer implements the current spec: T-CSub-TVar … is
  > pre-5.F4 simple version with no bounds accumulation; op_sem.lua has post-5.F4
  > bounds substrate. … Cannot close by 'catch op_sem_alt up' — bounds substrate
  > is unspecified (see bounds-spec-gap). … DECISION: adopt fuller simple-sub;
  > spec normatively first, then both interpreters re-encode."*

  Closed by **specifying the bounds substrate normatively (§3–§7) so both
  interpreters encode it independently** (§9 parity). The cache key, the
  record-before-recursion ordering, and the μ-detection key are pinned (§7.3), so
  the two terminate identically — the dual-interpreter "formal grounding" is
  restored at the spec level. The empirical divergence resolves once both encode
  the three cases + cache.

- **G9** (`v5-gaps.md`):
  > *"Bounded tvars: T-CSub-TVar routes to CEq instead of respecting bounds."*

  Closed by the **three variable cases** (§3): `T-CSub-TVar` no longer routes to
  `CEq`; an `α <: T` records an upper bound (and re-emits against lowers), `T <: α`
  records a lower bound, `α <: β` records a directional flow edge — all distinct
  from the `CEq` union-find merge (§3 vs §4). Subtyping information through a
  variable is preserved, not collapsed to equality. Substrate mechanism.

(R1 and G9 and bounds-spec-gap share a root — the missing bounds substrate — and
are kept as separate items per the `v5-gaps.md` rule against consolidation.)

---

## 12. Open questions (for the reviewer — genuine forks not resolved unilaterally)

1. **Both-polarity variable retention vs forced coalescing.** **DEFERRED — confirm
   jointly at M13.** §5.1 retains a both-polarity root as a variable carrying both
   faces (the simple-sub compact type). At a generalization boundary this becomes a
   bound quantifier; at a non-generalizing boundary it must stay a free variable.
   The exact interaction with M13's level-correct generalization at nested binders
   (when does a both-polarity variable get quantified vs left free vs skolemized?)
   is an M2/M13 seam. M2's lean: retain-as-variable and let M13's level discipline
   decide quantification. Conservatively sound either way (retention never admits
   an unproven `<:`); confirmed jointly with M13.

2. **μ-canonicalization for the subtyping cache.** **DEFERRED — confirm jointly at
   M12.** §6.2 hash-conses unrolled μ-copies so they compare by identity. Two
   *differently-folded* but equivalent recursive types (`μX. A|X` vs an unrolled
   `A | μX. A|X`) must hash-cons to the same canonical form for the §7 cache and
   M1's subtyping cache to treat them as equal. Whether canonicalization happens at
   fold-time (§6.1) or as a separate normalization pass is an M2/M12 detail; M2's
   lean is fold-time canonicalization. No soundness content (a missed equality only
   costs a redundant re-check, never an unsound accept); deferred to M12 where
   lattice-closure-under-μ is specified in full.

3. **Polarity of a variable reached only through `Neg`.** **RESOLVED — pinned in
   §5.1.** Negation is contravariant (`A <: B ⟺ ¬B <: ¬A`, M1 §3.2), so a `Neg`/
   complement occurrence is a polarity flip on equal footing with an arrow
   argument; §5.1 now pins polarity normatively as the parity of enclosing
   contravariant flips over **(a) arrow-args AND (b) `Neg`**. A variable reached
   through an odd number of `~` is therefore negative and coalesces against the
   opposite polar face. The earlier internal-vs-user-written concern is answered:
   **parity is structural** — it counts the `Neg` occurrences on the path
   regardless of whether the `¬τ` was user-written or produced by the §3.2
   move-across rule, so there is no fork. §5.1 also clarifies that a `¬τ` *bound
   value* raises no polarity question for the variable that **owns** the bound
   (it owns a lower → positive → `⋃lowers`); the parity rule applies only to a
   variable **nested inside** the `¬τ`. The soundness stake that made this a fork
   is discharged by the structural rule.
