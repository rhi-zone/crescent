# Typechecker v5 — Operational Semantics (v5.0 minimal core + CHKT)

Per H7 (parallel impl + docs with parity tests). Per F2 (op-sem is a runnable
test, not prose). This file is the **doc form**. The executable form is
`lib/type/static-v5/op_sem.lua`. The parity check is
`lib/type/static-v5/op_sem_parity_test.lua`. If the two forms diverge, the
parity test fails — that is the desired forcing function.

## Scope (v5.0 minimal core)

Six constraint variants, exactly:

| Variant       | Purpose                                            |
|---------------|----------------------------------------------------|
| `CEq(a, b)`   | type equality (unification)                        |
| `CSub(a, b)`  | subtyping (variance-respecting; see T-CSub-* family) |
| `CTableOpen(?t)`              | introduce open empty record at ?t       |
| `CTableSet(?t, k, v)`         | extend ?t's row with field k : v        |
| `CTableSeal(?t, ?μ)`          | flip ?t to sealed, bind metatable ?μ    |
| `CMethodCall(?t, k, ?r)`      | dispatch m through sealed table's μ.__index, bind result tvar ?r |
| `CInst(σ, τ)` | instantiate scheme σ with fresh tvars; equate to τ |

Out of v5.0: `CHKT`, `CEffect`, `CRow`, `CImpl`, `HOUnify`, `CMultiReturn`.
Each lands in a subsequent op-sem extension with its own perf re-gate
(`docs/typechecker-v5-log.md` — Re-gate schedule).

## Notation

Standard sequent-style inference rules; conventions inspired by OutsideIn(X)
[Vytiniotis et al. 2011, §4] adapted to crescent's substrate.

| Symbol      | Meaning                                                          |
|-------------|------------------------------------------------------------------|
| Γ           | typing environment (binding-group local; module env separate)    |
| σ           | substitution `TVarId → (Type, Phase)`, monotone                  |
| Φ           | phase map (part of σ; `Phase ∈ {Open, Sealed}`)                  |
| W           | worklist (multiset of constraints)                               |
| I           | inert set (constraints parked on tvar blockers)                  |
| C           | a single constraint                                              |
| τ           | a `Type` (see `lib/type/experiments/v5_perf/types.lua`)          |
| ?t, ?μ, ?r  | metavariables (`UVar(TVarId)` in the AST)                        |
| ?t ↦ τ      | tvar ?t is bound to τ in σ                                       |
| ?t ↦ τ @ Φ  | tvar ?t is bound to τ with phase Φ                               |
| σ[?t ↦ τ]   | substitution extended by binding ?t to τ                         |
| σ⟦τ⟧        | walk: apply σ recursively to τ                                   |
| ε           | empty / no-op                                                    |
| C ⇒ C'      | constraint C reduces to (emits) C'                               |
| C ⇒ ε       | constraint C is discharged with no successors                    |
| C ⇒ ⊥(msg)  | constraint C is rejected (error)                                 |
| C ↯         | constraint C is stuck (parked into I, watching its blockers)     |
| ⟨σ, W, I⟩   | solver state                                                     |
| ⟨σ, W, I⟩ → ⟨σ', W', I'⟩ | one solver step                                     |
| ⟨σ, ∅, I⟩   | quiescent state (worklist empty)                                 |

**Solver-tvar identity vs De Bruijn levels.** Per log item 2: `UVar(id)`
metavars are gensym ids (never shift); `Var(i)` are De Bruijn-indexed
lambda-bound vars (shift under β). Rules below operate on `UVar`; β-reduction
(rule **R-Beta**) handles `Var` via `instantiate`. The substitution σ binds
*only* `UVar`s.

**Phase as part of binding.** Per log item 1: σ binds each tvar to a pair
`(Type, Phase)`. Rules that read σ may pattern-match on Phase.

**Provenance is preserved but suppressed.** Every constraint carries a
`Provenance` record (`{ file, line, kind }`). Rules propagate it
unchanged through emitted successors; the metavariable `prov` in
hypotheses below stands for "the prov of the antecedent constraint."

## Judgment forms

The op-sem uses one judgment:

    σ ⊢ C ⇒ ⟨σ', emitted, status⟩

Read: under substitution σ, processing constraint C produces extended
substitution σ', emits zero or more new constraints, and yields a status of
`done`, `stuck`, or `error(msg)`. The solver loop wraps this judgment with
worklist management.

The solver loop itself is a separate small-step judgment:

    ⟨σ, W, I⟩ → ⟨σ', W', I'⟩

with two rules (**S-Step** and **S-Wake**) and one terminal condition
(**S-Quiesce**).

## Rules

### Equality / unification

**T-CEq-Refl.** Both sides already equal under σ (after deref).

    σ⟦?a⟧ = τ        σ⟦?b⟧ = τ        τ contains no UVar
    ─────────────────────────────────────────────────────  T-CEq-Refl
            σ ⊢ CEq(?a, ?b) ⇒ ⟨σ, ε, done⟩

(In practice this is degenerate; in the executable spec it falls out of the
UVar-UVar same-root case below.)

**T-CEq-UVar-UVar.** Both sides are tvars (after deref). Union via union-find;
smaller id wins (determinism).

    σ⟦τ_a⟧ = UVar(a)    σ⟦τ_b⟧ = UVar(b)    a ≠ b    min(a,b) wins
    ────────────────────────────────────────────────────────────────  T-CEq-UU
        σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ ∪ {a ↔ b}, ε, done⟩

If `a = b`: discharged with no change. (Subsumed by **T-CEq-Refl**.)

**T-CEq-Bind-L.** Left side is a tvar, right is a non-tvar concrete type.

    σ⟦τ_a⟧ = UVar(a)    σ⟦τ_b⟧ = τ    τ.tag ≠ uvar    a ∉ FV(τ)
    ──────────────────────────────────────────────────────────────  T-CEq-Bind-L
                σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ[a ↦ τ @ Φ_a], ε, done⟩

Side conditions: occurs-check on `a ∈ FV(τ)` — if violated, rule fails over
to **T-CEq-Occurs** (error). Phase of binding preserves the existing Φ_a.

**T-CEq-Bind-R.** Mirror of T-CEq-Bind-L.

**T-CEq-Const.** Two concrete `Const` types.

    σ⟦τ_a⟧ = Const(n_a)    σ⟦τ_b⟧ = Const(n_b)    n_a = n_b
    ───────────────────────────────────────────────────────────  T-CEq-Const
                 σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ, ε, done⟩

If `n_a ≠ n_b`: rejection (error "const mismatch").

**T-CEq-Arrow.** Two concrete arrows.

    σ⟦τ_a⟧ = Arrow(A_1..A_n, R_1..R_m)
    σ⟦τ_b⟧ = Arrow(B_1..B_n, S_1..S_m)
    ─────────────────────────────────────────────────────────────  T-CEq-Arrow
    σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ, [CEq(A_i, B_i)]_i ++ [CEq(R_j, S_j)]_j, done⟩

Arity mismatch ⇒ rejection.

**T-CEq-Record.** Two concrete records.

    σ⟦τ_a⟧ = Record(F)    σ⟦τ_b⟧ = Record(G)    dom(F) = dom(G)
    ──────────────────────────────────────────────────────────────  T-CEq-Record
       σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ, [CEq(F[k], G[k])]_{k ∈ dom(F)}, done⟩

Domain mismatch (missing/extra field) ⇒ rejection.

**T-CEq-App.** Two concrete applications. Emits two sub-equalities.

    σ⟦τ_a⟧ = App(f_a, x_a)    σ⟦τ_b⟧ = App(f_b, x_b)
    ────────────────────────────────────────────────────  T-CEq-App
    σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ, [CEq(f_a, f_b), CEq(x_a, x_b)], done⟩

**T-CEq-Mismatch.** Two concrete types with mismatched head tags.

    σ⟦τ_a⟧ = τ_a'    σ⟦τ_b⟧ = τ_b'    τ_a'.tag ≠ τ_b'.tag    neither is uvar
    ──────────────────────────────────────────────────────────────────────────  T-CEq-Mismatch
                       σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ, ε, error("kind mismatch")⟩

**T-CEq-Occurs.** Occurs-check violation.

    σ⟦τ_a⟧ = UVar(a)    σ⟦τ_b⟧ = τ    a ∈ FV(τ)
    ──────────────────────────────────────────────  T-CEq-Occurs
       σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ, ε, error("occurs")⟩

### Subtyping (variance-respecting)

**Added 2026-05-24.** CSub was previously routed to CEq (T-CSub-AsEq), a
documented stub.  This section replaces that stub with a variance-respecting
dispatch.  The discipline is **declaration-site variance** (per H4 of the
HKT picks): each named constructor carries a per-parameter variance list
in the variance registry (`lib/type/experiments/v5_perf/variance.lua`),
defaulting to **invariant** when undeclared (the sound default per the
round-1 research report §3 — TypeScript-array unsoundness).

Variance markers:

| Marker   | Meaning                                                  |
|----------|----------------------------------------------------------|
| `co`     | covariant:     A <: B ⊢ F⟨A⟩ <: F⟨B⟩                     |
| `contra` | contravariant: A <: B ⊢ F⟨B⟩ <: F⟨A⟩                     |
| `inv`    | invariant:     F⟨A⟩ <: F⟨B⟩ iff A = B                    |

**Soundness floor.** Record fields are **invariant** in v5.0.  Per item 1's
construction-phase model, record fields are mutable (CTableSet); covariant
field subtyping under mutability is the well-known TypeScript-array
unsoundness.  Width subtyping is admitted (forgetting fields) but each
common field's type is required equal.

#### Rules

**T-CSub-Refl.** Same type both sides (after deref + structural equality).

    σ⟦τ_a⟧ = τ      σ⟦τ_b⟧ = τ'      types.equal(τ, τ')
    ─────────────────────────────────────────────────────  T-CSub-Refl
                σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, ε, done⟩

**T-CSub-TVar.** Either side is an unbound `UVar`.  **Superseded 2026-05-29
(Spec A).** v5.0 routed this to `CEq` (no per-tvar bounds); the dual-interpreter
review (R1) found that route loses all subtyping information through a variable
and is the spec gap that makes faithful inference impossible.  The normative
replacement is the **fuller simple-sub bounds system** defined in §"Simple-sub
bounds (normative)" below — three cases (Upper, Lower, Flow), an eagerly-
maintained transitive closure with a mandatory termination cache, and polar
coalescing at quiescence.  This rule is retained here only as a forward
pointer; the operational content lives in that section and **replaces** the
route-to-CEq disposition entirely.

**T-CSub-Arrow.** Decompose with arrow variance (fixed: contra args, co rets).

    σ⟦τ_a⟧ = Arrow(A_1..A_n, R_1..R_m)
    σ⟦τ_b⟧ = Arrow(B_1..B_n, S_1..S_m)
    ─────────────────────────────────────────────────────────────  T-CSub-Arrow
    σ ⊢ CSub(τ_a, τ_b) ⇒
      ⟨σ, [CSub(B_i, A_i)]_i ++ [CSub(R_j, S_j)]_j, done⟩

Arity mismatch is rejected.  Note arg sides are FLIPPED (contravariance):
`A_i` is supertype of `B_i`.

**T-CSub-Const-Var.** Two concrete `Const`s with the same head name and per-
parameter variance lookup.  Currently `Const` is nullary in the AST (named
type without parameters), so this rule is degenerate at the AST level — it
falls into T-CSub-Refl after a name check.  Variance dispatch applies to
**applications** (next rule).

    σ⟦τ_a⟧ = Const(n)     σ⟦τ_b⟧ = Const(n)
    ──────────────────────────────────────────  T-CSub-Const-Var
        σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, ε, done⟩

Name mismatch is rejected as a kind mismatch.

**T-CSub-App-Var.** Two applications with matching head constructor; dispatch
per-position variance from the head's registry entry.

    σ⟦τ_a⟧ = App(... App(App(Const(n), x_1), x_2) ..., x_k)
    σ⟦τ_b⟧ = App(... App(App(Const(n), y_1), y_2) ..., y_k)
    vᵢ = variance.at(n, i)    for i = 1..k
    ──────────────────────────────────────────────────────────────  T-CSub-App-Var
    σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [subgoal(vᵢ, xᵢ, yᵢ)]_i, done⟩

where

    subgoal("co",     x, y) = CSub(x, y)
    subgoal("contra", x, y) = CSub(y, x)
    subgoal("inv",    x, y) = CEq(x, y)

If the head is not a named `Const` (e.g. a `Lambda` β-equivalent shape),
this rule falls through to **T-CSub-App-Struct** below.

**T-CSub-App-Struct.** Applications with non-Const heads (or mismatched
named heads) — fall back to structural decomposition under invariance.

    σ⟦τ_a⟧ = App(f_a, x_a)    σ⟦τ_b⟧ = App(f_b, x_b)
    head(τ_a).tag ≠ "const"  ∨  head(τ_b).tag ≠ "const"
    ─────────────────────────────────────────────────────────────  T-CSub-App-Struct
    σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [CEq(f_a, f_b), CEq(x_a, x_b)], done⟩

**T-CSub-Record-Width.** Width subtyping with invariant fields.  The
**supertype** has fewer fields; common-field types are required equal.

    σ⟦τ_a⟧ = Record(F)    σ⟦τ_b⟧ = Record(G)    dom(G) ⊆ dom(F)
    ──────────────────────────────────────────────────────────────  T-CSub-Record-Width
        σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [CEq(F[k], G[k])]_{k ∈ dom(G)}, done⟩

When `dom(G) ⊄ dom(F)` (supertype demands a field the subtype lacks): reject.

**T-CSub-Union-L.** Union subtype on the LHS: each branch must subtype the
RHS (covariant in the union).

    σ⟦τ_a⟧ = Union(A_1..A_n)
    ─────────────────────────────────────────────────────────────  T-CSub-Union-L
    σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [CSub(A_i, τ_b)]_i, done⟩

**T-CSub-Union-R.** Union supertype on the RHS: it suffices to subtype one
branch.  v5.0 simplification: structural equality on the LHS against any
single branch (no backtracking).  If none match exactly, reject.  Full
backtracking search is a v5.x extension owed when the corpus demands it.

    σ⟦τ_b⟧ = Union(B_1..B_n)    ∃j. types.equal(σ⟦τ_a⟧, B_j)
    ─────────────────────────────────────────────────────────────  T-CSub-Union-R
                  σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, ε, done⟩

**T-CSub-Mismatch.** Two concrete types with mismatched head tags and no
rule above applies.

    σ⟦τ_a⟧ = τ_a'    σ⟦τ_b⟧ = τ_b'    τ_a'.tag ≠ τ_b'.tag    neither uvar
    ────────────────────────────────────────────────────────────────────────  T-CSub-Mismatch
                       σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, ε, error("sub kind mismatch")⟩

#### Soundness sketch

1. **T-CSub-Arrow** preserves substitutability: a function expecting a
   wider arg can safely accept a narrower one (contra-args), and a producer
   of a narrower result satisfies a consumer expecting a wider one
   (co-rets).
2. **T-CSub-App-Var** preserves substitutability for each parameter
   position by definition of declaration-site variance.  The default
   (invariant) is conservatively sound — equality always implies subtyping.
3. **T-CSub-Record-Width** is sound under invariant field types: a wider
   record can be supplied where a narrower is expected (forget the extras);
   each common field's read AND write semantics agree because the types
   are equal.  This explicitly rejects the unsound TypeScript-array
   pattern (covariant field on a mutable position).
4. **T-CSub-Union-L** is sound: every branch of the LHS must satisfy the
   RHS.  **T-CSub-Union-R**'s v5.0 form is sound but incomplete (rejects
   some valid programs); completeness deferred.

#### Spec gaps surfaced (per F12 — named, not silently filled)

1. **Bounded tvars.** ~~No per-tvar lower/upper bound; T-CSub-TVar routes
   to CEq.~~ **CLOSED 2026-05-29 (Spec A).** The fuller simple-sub bounds
   system is now normatively specified in §"Simple-sub bounds (normative)":
   directional bound-graph for `α <: β`, canonical lower/upper sets keyed by
   union-find root, eager transitive re-emission with a structural-hash cache,
   and polar coalescing at S-Quiesce.  Implementation is phase P2 (op_sem.lua
   + op_sem_alt.lua, dual encoders); this section is the spec half.
2. **Variance under Lambda** (HKT constructor-position variance).  The
   registry covers named constructors only; type lambdas don't yet carry
   variance.  Acceptable for v5.0 since CHKT already β-reduces lambdas to
   structural shapes before dispatch.  Owed when a corpus example
   exercises a non-trivial `Lambda` in a CSub LHS/RHS without prior β.
3. **Union backtracking** (T-CSub-Union-R).  v5.0 admits only exact-branch
   match.  Backtracking search owed when corpus demands it.
4. **Effect-row variance** (CEffect).  When CEffect lands, handler
   subsumption needs row-tail variance.  Out of v5.0 minimal-core scope;
   tracked separately in the CEffect risk note.
5. **Intersection types** (no intersection AST variant yet).  Algebraic
   Subtyping admits intersection-as-contravariant-union; owed.

### Simple-sub bounds (normative)

**Added 2026-05-29 (Spec A of a spec-first program; DOCS-ONLY).** This section
is the normative replacement for the v5.0 "route subtyping between variables to
`CEq`" disposition (the old **T-CSub-TVar**).  It specifies the **fuller
simple-sub bounds system** v5 adopts, derived from
`docs/typechecker-rewrite-design.md` §2.2 ("Bound propagation"), which is in
turn MLstruct §3.2 (Parreaux & Chau, OOPSLA 2022): *"the constraint solver
attaches a set of lower and upper bounds to each type variable, and maintains
the transitive closure of these constraints."*

The spec is written to be encodable **independently** by two interpreters
(`lib/type/static-v5/op_sem.lua` and `lib/type/static-v5/op_sem_alt.lua` — the
dual-interpreter premise; R1 found the prior spec broken because it omitted
bounds).  Where it cites current `op_sem.lua` behavior, that is the **divergence
to be removed in phase P2**, not the target.

#### The central coexistence: bound-graph (subtyping) vs union-find (equality)

v5 keeps **two distinct relations on type variables**, with one shared
addressing scheme:

- **Equality** (`CEq`, binding `α := τ`) uses the **union-find substitution**
  in `lib/type/experiments/v5_perf/subst.lua` unchanged.  `CEq(α, β)` merges
  the two roots (**T-CEq-UU**); `α := τ` binds the root (**T-CEq-Bind-L/R**).
  This is the existing monotone σ.
- **Subtyping between two unbound variables** (`α <: β`) does **NOT** merge.
  It records a **directional bound-graph edge** `α → β` ("α flows into β"):
  β's lower bounds flow into α's lowers, α's upper bounds flow into β's uppers.
  α and β stay **distinct**, and the relation is **asymmetric** — `α <: β`
  without `β <: α` is a legal, representable state.  This is full simple-sub:
  faithful flow, not union-find merge.  (This is the decided design; it is not
  re-litigated here.)

The two relations are reconciled by a single rule: **all bound storage and all
bound-graph edges are keyed by the union-find root** (`subst.find(id)`), exactly
as `op_sem.lua`'s `add_upper_bound` / `add_lower_bound` already key by
`subst_mod.find` (op_sem.lua, the `add_upper_bound`/`add_lower_bound` helpers).
Therefore a later `CEq(α, β)` that merges roots `r_α`, `r_β` automatically makes
the surviving root inherit the other's bounds and edges — and the merge rule
(**T-CEq-UU-Bounds** below) explicitly reconciles them and re-establishes the
transitive closure across the newly-joined cross-pairs.  Equality is thus
*stronger* than mutual subtyping: merging is allowed to discard the directional
distinction precisely because `CEq` asserts both directions at once.

This keys-by-root discipline is the mechanism by which "the bound-graph
(subtyping edges) coexists with the union-find substitution (equality/binding)"
required by the design.  There is exactly one source of truth.

#### State (abstract machine extension)

The solver state `⟨σ, W, I⟩` is extended to `⟨σ, W, I, B, C⟩` where:

| Component | Meaning |
|-----------|---------|
| `B.lower : Root → Set<Type>` | per-root **lower-bound set** (`bind_lower`). `L ∈ B.lower[r]` means `L <: α` for every α with `find(α)=r`. |
| `B.upper : Root → Set<Type>` | per-root **upper-bound set** (`bind_upper`). `U ∈ B.upper[r]` means `α <: U`. |
| `B.edge_up : Root → Set<Root>`   | **bound-graph out-edges**: `r' ∈ B.edge_up[r]` iff edge `α → β` recorded (α∈r, β∈r'), i.e. `α <: β`. α's uppers flow to β; β's lowers flow to α. |
| `C : Set<Hash>` | the **subtyping termination cache** (§"Bound-add with cache"). A hash is in `C` iff that `CSub(L,U)` obligation has been discharged-or-assumed. |

All four are **canonical in `subst.lua`** (the decided design: `bind_lower` /
`bind_upper` maps + the edge map live in the substitution), keyed by root, and
**migrated on union alongside watchers** — `subst.union` already migrates
`watchers` and `head_watchers` (subst.lua, the `union` function); `bind_lower`,
`bind_upper`, and `edge_up`/`edge_down` migrate by the same loop (loser's sets
unioned into winner's, loser's entry cleared).  `op_sem.lua` currently keeps
`upper_bounds`/`lower_bounds` on `OpSemState` (op_sem.lua, the `OpSemState`
record and `new_state`); **P2 migrates them into the substitution** so both
interpreters read the same substrate.  `B` and `C` are part of state purely so
the two encoders agree on what is observable; they impose no representation.

Set membership and dedup are modulo `types.equal` after `deref` (as
`bounds_contains` already does).  `B.edge_up` is a relation on roots; its
reflexive-transitive closure is *materialized eagerly* (see below), so a query
"does L flow to U" need not walk the graph at query time.

Monotonicity: `B.lower`, `B.upper`, `B.edge_up`, and `C` only ever **grow**
(modulo union, which merges entries — never a net loss of obligation).  This
preserves the monotone-σ premise on which **S-Wake** and termination rest
(see "Interaction with the watcher/wake machinery").

#### T-CSub-TVar — three cases

After deref, when at least one side is an unbound `UVar`, exactly one of three
cases applies.  None are stuck-and-park: each is **done with re-emission**
(possibly emitting transitive obligations, all cache-guarded).

**T-CSub-TVar-Upper.** LHS is an unbound uvar, RHS is non-uvar (`α <: T`).
Add `T` to α's root's upper set; for **every** existing lower `L`, re-emit
`CSub(L, T)` (cache-guarded) to maintain the closure.

    σ⟦τ_a⟧ = UVar(α)    r = find(α)    σ⟦τ_b⟧ = T    T.tag ≠ uvar
    B' = B with T added to upper[r]
    ──────────────────────────────────────────────────────────────  T-CSub-TVar-Upper
    σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [ CSub(L, T) | L ∈ B.lower[r] ]_cache, done⟩  with B := B'

**T-CSub-TVar-Lower.** RHS is an unbound uvar, LHS is non-uvar (`T <: α`).
Add `T` to α's root's lower set; for **every** existing upper `U`, re-emit
`CSub(T, U)` (cache-guarded).

    σ⟦τ_b⟧ = UVar(α)    r = find(α)    σ⟦τ_a⟧ = T    T.tag ≠ uvar
    B' = B with T added to lower[r]
    ──────────────────────────────────────────────────────────────  T-CSub-TVar-Lower
    σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [ CSub(T, U) | U ∈ B.upper[r] ]_cache, done⟩  with B := B'

**T-CSub-TVar-Flow.** Both sides are unbound uvars with **distinct** roots
(`α <: β`).  Record the directional edge `r_α → r_β`.  Flow β's lowers into
α's lowers and α's uppers into β's uppers, and re-emit the cross-product
obligations these create (cache-guarded), so the closure invariant holds
across the new edge.  **Do not merge the roots** — that is reserved for `CEq`.

    σ⟦τ_a⟧ = UVar(α)   σ⟦τ_b⟧ = UVar(β)   r_α = find(α)   r_β = find(β)   r_α ≠ r_β
    B' = B with r_β added to edge_up[r_α],
                 B.lower[r_β] ∪-added into lower[r_α],
                 B.upper[r_α] ∪-added into upper[r_β]
    emitted = [ CSub(L, U) | L ∈ B.lower[r_α]', U ∈ B.upper[r_β]' ]_cache
    ─────────────────────────────────────────────────────────────────────────  T-CSub-TVar-Flow
              σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, emitted, done⟩  with B := B'

(If `r_α = r_β` the constraint is reflexive — discharged with no change,
subsumed by **T-CSub-Refl**.)

The flow in **T-CSub-TVar-Flow** is **transitive in one step only**; deeper
transitivity is achieved because each flowed-in bound is itself re-emitted as a
`CSub(L, T)` / `CSub(T, U)` against the *concrete* uppers/lowers via the Upper
and Lower rules above, and because adding an edge into a node that already has
out-edges flows along them (the eager-closure invariant: whenever an edge or a
bound is added, the obligations its addition creates are re-emitted before the
step completes).  Cyclic edge-graphs are made to terminate by the cache.

**Polarity note.** Re-emitted obligations carry the **prov of the originating
`CSub`** (per the doc's standing provenance convention), so a conflict surfaces
at the originating constraint — precise blame (the decided design's "conflicts
surface at the originating constraint").

#### Bound-add with cache (the termination protocol)

Every obligation re-emitted by the three T-CSub-TVar cases (and by
**T-CEq-UU-Bounds**) is an ordinary `CSub(L, U)` that re-enters `W` — **but
gated by the cache** `C`:

**Cache key.** `key(L, U) = hash(⟨head(deref L), head(deref U)⟩)` where `head`
is the top-level constructor tag **plus**, for a uvar leaf, its union-find root
id (so two syntactically-distinct uvars that share a root collide, and a uvar
vs a different root do not).  This is the "structural hash of (deref L, deref U)
head+identity" of the decided design.  Two obligations with equal keys are
treated as the same obligation.

**Cache-check rule.** Before a re-emitted `CSub(L, U)` is processed:

    k = key(L, U)    k ∈ C
    ────────────────────────────────────  S-Sub-CacheHit
    CSub(L, U) ⇒ ⟨σ, ε, done⟩            (assumed to hold; emit nothing)

    k = key(L, U)    k ∉ C
    ────────────────────────────────────  S-Sub-CacheMiss
    CSub(L, U) ⇒ process normally, with C := C ∪ {k} recorded BEFORE recursion

The "record before recursion" ordering is what cuts cycles: a regular type
whose bound-graph forms a loop re-encounters its own key and discharges via
**S-Sub-CacheHit** rather than re-emitting forever.  This is mandatory, not an
optimization — without it transitive re-emission on a cyclic bound-graph
diverges.  See "Re-emission termination" in §"Termination argument".

**Coalescing-time note.** The `∪lowers ⊆ ∩uppers` invariant (union of lowers is
a subtype of the intersection of uppers) is *maintained* by the eager
re-emission above (every lower meets every upper through a `CSub`).  It is
**not** separately checked.  A genuine violation (e.g. `integer <: α` and
`α <: string`) surfaces as a `CSub(integer, string)` obligation that the
atomic/structural rules reject — at the originating constraint's prov.

#### T-CEq-Bind — verify bounds before binding

Binding a variable to a concrete type must honor the bounds accumulated on its
root.  **T-CEq-Bind-L** / **-R** are extended:

    σ⟦τ_a⟧ = UVar(α)    r = find(α)    σ⟦τ_b⟧ = τ    τ.tag ≠ uvar    α ∉ FV(τ)
    ─────────────────────────────────────────────────────────────────────────────  T-CEq-Bind-L-Bounds
    σ ⊢ CEq(τ_a, τ_b) ⇒
      ⟨σ[r ↦ τ @ Φ_r],
       [ CSub(L, τ) | L ∈ B.lower[r] ]_cache ++ [ CSub(τ, U) | U ∈ B.upper[r] ]_cache,
       done⟩

That is: bind as before (occurs-check unchanged; failure routes to
**T-CEq-Occurs**), then **verify** every accumulated lower `L <: τ` and upper
`τ <: U` by emitting those `CSub`s (cache-guarded).  A bound that τ violates
surfaces as a normal subtyping error.  After binding, the root's bound sets are
retained (they remain valid facts about a now-concrete root; re-emission keys
include the root identity so no rework loops).  `op_sem.lua` currently binds
without re-checking bounds (op_sem.lua, `rule_T_CEq_Bind_L`) — P2 adds the
verification emit.

#### T-CEq-UU — merge reconciles bounds AND edges

`CEq(α, β)` between two unbound uvars merges roots via union-find
(**T-CEq-UU**, unchanged for the σ part: smaller id wins).  The extension
reconciles `B`:

    σ⟦τ_a⟧ = UVar(α)   σ⟦τ_b⟧ = UVar(β)   r_w = winner, r_l = loser (= find after union)
    lower[r_w] := lower[r_w] ∪ lower[r_l]      upper[r_w] := upper[r_w] ∪ upper[r_l]
    edge_up[r_w] := edge_up[r_w] ∪ edge_up[r_l]   (and dually edge_down)
    -- re-establish closure on the newly-joined cross-pairs:
    emitted = [ CSub(L, U) | L ∈ lower[r_w], U ∈ upper[r_w] ]_cache    -- (only the cross pairs are new)
    ───────────────────────────────────────────────────────────────────────────────────  T-CEq-UU-Bounds
    σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ ∪ {α ↔ β}, emitted, done⟩

The migration itself is the `subst.union` watcher-migration loop extended to the
bound/edge maps (subst.lua, `union`).  Because merge collapses the directional
distinction, any edge `r_l → r_w` or `r_w → r_l` that existed between the two
becomes a self-loop on `r_w` and is **dropped** (a node trivially flows to
itself).  The cross-pair re-emission is cache-guarded, so it cannot loop on a
cyclic graph.  This is the "later CEq merge reconciles two variables'
edges/bounds" requirement of the decided design.

#### S-Quiesce — polar coalescing

At quiescence (`W = ∅`), each root that is still **unbound** but carries bounds
is coalesced into a user-facing / cache-facing type by **polarity**, replacing
the v5.0 single "meet of upper bounds" (op_sem.lua, the `run` quiescence block
that emits `reduce_intersection(uppers)` — this is the disposition P2 replaces):

- A root occurring **positively** (as a value flowing *out* — produced)
  coalesces to **`⋃ B.lower[r]`** (the union of its lower bounds).
- A root occurring **negatively** (as a value flowing *in* — consumed)
  coalesces to **`⋂ B.upper[r]`** (the intersection of its upper bounds).
- A root occurring at **both** polarities coalesces to a variable retained in
  the output (the simple-sub "compact type" keeps such variables), with both a
  lower and upper face.
- A **recursive bound** — `B.lower[r]` or `B.upper[r]` mentions `r` itself
  (detected by **hash-consing** during the coalescing walk, per simple-sub
  / `typechecker-rewrite-design.md` §2.2 "Coalescing") — is wrapped in a
  **`μX. …`** binder, `X` standing for `r`.

Polarity is the standard simple-sub assignment: a position is positive if it is
reached through an even number of contravariant (function-argument) flips from a
producing occurrence, negative otherwise.  An empty lower set coalesces to
`never`; an empty upper set to `unknown` (the lattice top/bottom).

**reduce_intersection / structurally_subtype is a coalescing-time simplifier
only.** The dominated-bound drop (e.g. `integer & number → integer`,
`string | "GET" → string` on the union side) is applied **only here, at
coalescing**, never mid-solving.  It is the existing `reduce_intersection` /
`structurally_subtype` pair (op_sem.lua, those two helpers) repurposed: P2 must
ensure they are *not* invoked during constraint solving (where they would
prematurely commit), only when materializing the coalesced form.  This matches
the decided design (simplifier drops dominated bounds at coalescing time).

#### atomic_subtype — the single primitive lattice

The base-type subtyping facts — `never <: anything`, `anything <: unknown`,
`integer <: number`, literal-widening — are currently **copied three times** in
`op_sem.lua`: in the `step_csub` dispatcher's literal-widening block, in
`rule_T_CSub_Const_Var`'s `integer <: number` special case, and inside
`structurally_subtype` (op_sem.lua, those three sites).  Three hardcoded copies
of one lattice is exactly the special-casing the project's "No special-casing"
hard constraint forbids.

Spec A specifies the lattice **once** as a relation consulted everywhere:

    atomic_subtype(a, b) : the decidable base-lattice judgment, holds iff
      • a = never                              (bottom subtypes all), or
      • b = unknown                            (all subtype top), or
      • a = b                                  (reflexivity on atoms), or
      • a, b are atoms related by the primitive widening lattice
        (integer <: number; each literal singleton <: its base atom).

**T-CSub-Atomic.** When both sides deref to atoms (no decomposable structure),
the relation is decided by one `atomic_subtype` call:

    σ⟦τ_a⟧ = a    σ⟦τ_b⟧ = b    a, b atomic    atomic_subtype(a, b)
    ──────────────────────────────────────────────────────────────────  T-CSub-Atomic
                       σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, ε, done⟩

    (¬atomic_subtype(a, b)) ⇒ ⟨σ, ε, error("not a subtype")⟩

`rule_T_CSub_Const_Var`, the literal-widening dispatcher block, and
`structurally_subtype`'s atom case must **all** delegate to this one
`atomic_subtype` in P2 — no inline lattice facts remain.

**Abstract lattice consultation (composes with Spec C).** `atomic_subtype` must
consult the widening lattice **abstractly**, NOT by string-matching specific
`$`-prefixed names (`$Lit`, `$LitInt`, `$LitNum`).  Those literal-encoding names
are themselves being made **scoped** in Spec C; if `atomic_subtype` hardcoded
`"$LitInt"` etc. it would re-introduce the very name-keyed special-casing this
section removes, and would break under Spec C's renaming.  The normative
requirement is therefore: the lattice exposes a predicate "is `a` a literal
whose base is `b`" and "is `a` the integer atom, `b` the number atom" as
**lattice operations**, and `atomic_subtype` calls those.  The concrete encoding
of literals (whatever `$`-names survive) is a **forward reference — see Spec C**;
this spec deliberately does not pin it.  Until Spec C lands, an implementation
may back the predicate with the current `$Lit*` recognizer, but the *interface*
`atomic_subtype` presents to the rest of the solver must be the abstract one.

#### Interaction with the existing monotone-σ / watcher / S-Wake machinery

The bound-graph is **not** a second wake substrate.  It reuses the existing
machinery:

- **Bounds and edges are monotone** (only grow / merge), so the monotone-σ
  premise behind **S-Wake** and the termination order is preserved.  No bound
  is ever retracted.
- The three T-CSub-TVar cases are **`done`, not `stuck`** — they never park, so
  they add nothing to `I` and create no new watcher class.  (This is the
  decided design: "NOT stuck-and-park — done-with-re-emission."  It also removes
  the v5.0 behavior where `op_sem.lua` parks an `α <: T` csub on `α` —
  op_sem.lua, the `"stuck"` branch in `rule_T_CSub_TVar` — and the quiescence
  drain that binds it to the meet.)
- When `T-CEq-Bind` or `T-CEq-UU` later binds/merges a root, the **existing**
  `S-Wake` fires for any constraints watching that root (e.g. a parked
  `CMethodCall`), exactly as today.  Re-emitted `CSub`s from a bind are placed
  directly on `W`; they do not depend on wake.

**Flagged (no new sub-fork):** the bound-graph needs **no** wake/reactivation
semantics of its own — its progress is driven entirely by *emission onto `W`*
at the moment a bound or edge is added, gated by the cache, not by parking and
later waking.  This is consistent with the seven decided points and introduces
no eighth design fork.  The one place this must be honored by both encoders:
re-emission happens **eagerly, in the same step** that adds the bound/edge
(on-add invariant enforcement), so neither interpreter may defer it to
quiescence.

### Construction phase

**T-CTOpen.** Introduces an empty open record binding.

    σ(?t) = unbound    Φ(?t) = Open
    ─────────────────────────────────────────────────  T-CTOpen
    σ ⊢ CTableOpen(?t) ⇒ ⟨σ[?t ↦ Record(∅) @ Open], ε, done⟩

If `?t` already has a binding, T-CTOpen is a no-op (`done` without change).
This makes `CTableOpen` idempotent — convenient when gen emits it
defensively.

**T-CTSet-Open-Fresh.** Extending an unbound open tvar adds the empty
record then sets the field.

    σ(?t) = unbound    Φ(?t) = Open
    ────────────────────────────────────────────────────────────────────────  T-CTSet-Open-Fresh
    σ ⊢ CTableSet(?t, k, τ) ⇒ ⟨σ[?t ↦ Record({k = τ}) @ Open], ε, done⟩

**T-CTSet-Open-Extend.** Field is new on an existing open record. Add it.

    σ(?t) = Record(F) @ Open    k ∉ dom(F)
    ──────────────────────────────────────────────────────────────────  T-CTSet-Open-Extend
    σ ⊢ CTableSet(?t, k, τ) ⇒ ⟨σ[?t ↦ Record(F ∪ {k = τ}) @ Open], ε, done⟩

**T-CTSet-Open-Equate.** Field is already present on an existing open
record. Demote to equality.

    σ(?t) = Record(F) @ Open    F[k] = τ'
    ──────────────────────────────────────────────────────  T-CTSet-Open-Equate
    σ ⊢ CTableSet(?t, k, τ) ⇒ ⟨σ, [CEq(τ', τ)], done⟩

**T-CTSet-Sealed-Reject.** Per item 1 closure: setting a field on a sealed
table is an error.

    σ(?t) = _ @ Sealed
    ───────────────────────────────────────────────────────────  T-CTSet-Sealed-Reject
    σ ⊢ CTableSet(?t, k, τ) ⇒ ⟨σ, ε, error("set on sealed table")⟩

**T-CTSeal.** Flip phase, bind metatable. v5.0: μ is allowed to be a `UVar`
that may bind later via a separate CEq.

    Φ(?t) = Open
    ────────────────────────────────────────────────────────  T-CTSeal
    σ ⊢ CTableSeal(?t, ?μ) ⇒ ⟨σ[Φ(?t) := Sealed], ε, done⟩

If `Φ(?t) = Sealed` already, no-op (`done`).

**T-CTSeal-Nil-Reject.** Per item 5 closure: `setmetatable(t, nil)`
unconditionally rejected. Encoded at the stdlib-types boundary, not in
this rule (`setmetatable : <T, M: Table>(T, M) -> Sealed<T, M>`); attempting
to pass `Const("nil")` for `?μ` surfaces as a **T-CEq-Mismatch**. Listed here
for traceability; no separate rule.

### Method dispatch

**T-CMCall-Open-Stuck.** Method dispatch on an open table is parked.

    Φ(?t) = Open
    ────────────────────────────────────────────────  T-CMCall-Open-Stuck
    σ ⊢ CMethodCall(?t, k, ?r) ⇒ ⟨σ, ε, stuck⟩

Constraint moves to I, watching ?t. When CTableSeal extends σ, the
watcher fires and re-enters W.

**T-CMCall-Sealed-Field.** Field directly present on the sealed table.

    σ(?t) = Record(F) @ Sealed    F[k] = Arrow(_, [τ_ret, ...])
    ───────────────────────────────────────────────────────────────  T-CMCall-Sealed-Field
        σ ⊢ CMethodCall(?t, k, ?r) ⇒ ⟨σ, [CEq(?r, τ_ret)], done⟩

(v5.0 simplification: takes the first return component as the value. Full
multi-return binding lands with CMultiReturn.)

**T-CMCall-Sealed-Missing.** Sealed, field absent. Future extension: walk
μ.__index chain. v5.0: reject.

    σ(?t) = Record(F) @ Sealed    k ∉ dom(F)
    ─────────────────────────────────────────────────────────────  T-CMCall-Sealed-Missing
    σ ⊢ CMethodCall(?t, k, ?r) ⇒ ⟨σ, ε, error("no method " ++ k)⟩

**Spec gap noted (per F12, not silently filled).** The full μ.__index chain
walk is out of v5.0 minimal scope. The walkthrough did not specify whether
chain-walking is a CMethodCall variant, a derived constraint, or a separate
`CMetaIndexLookup` constraint. **This needs an orchestrator decision before
the CHKT op-sem extension lands** (because chain-walking interacts with
HKT-shaped metatables).

### Instantiation (deferred, Option X form)

**T-CInst.** Instantiate a polytype scheme `∀(α₁..α_n: K_i). τ_body` by
allocating fresh tvars for each binder and equating with the target.

    σ' = σ ∪ {a_i ↦ unbound @ Open}_i    -- fresh metavars for each binder
    body' = instantiate(τ_body, [UVar(a_i)]_i)
    ─────────────────────────────────────────────────────────────────────  T-CInst
       σ ⊢ CInst(∀α₁..α_n. τ_body, τ_target) ⇒ ⟨σ', [CEq(body', τ_target)], done⟩

For v5.0, scheme representation is `{ binders: integer (count), body: V5Type }`
where `body` uses `Var(0)..Var(n-1)` for the bound vars (De Bruijn). After
instantiation the body has no remaining bound `Var`s relative to the scheme's
binders.

**T-CInst-Mono.** Degenerate case: zero binders.

    binders = 0
    ─────────────────────────────────────────────────────  T-CInst-Mono
    σ ⊢ CInst(σ, τ) ⇒ ⟨σ, [CEq(σ.body, τ)], done⟩

### β-reduction (auxiliary, invoked by T-CInst)

Not a constraint rule. `instantiate(body, [a_i])` is implemented per
`lib/type/experiments/v5_perf/types.lua: instantiate`. Repeated De Bruijn
substitution; eager shift on bind.

### Solver loop

**S-Step.** Pop a constraint, apply the matching rule.

    W = C :: W'    σ ⊢ C ⇒ ⟨σ', emitted, status⟩    status = done
    ───────────────────────────────────────────────────────────────  S-Step
                 ⟨σ, W, I⟩ → ⟨σ', W' ++ emitted, I⟩

For `status = error(msg)`: same as done but msg is logged to a side-channel
`errors` (not modelled in the state above for brevity; see executable spec).

For `status = stuck`: see S-Park.

**S-Park.** A stuck constraint moves to I, watching its blocker tvars.

    W = C :: W'    σ ⊢ C ⇒ ⟨σ', ε, stuck⟩    blockers(C) = B
    ──────────────────────────────────────────────────────────────  S-Park
        ⟨σ, W, I⟩ → ⟨σ' annotated to wake C on B, W', I ∪ {C}⟩

Blockers per constraint:
- `CEq(a, b)` / `CSub(a, b)`: any `UVar(id)` appearing in `σ⟦a⟧` or
  `σ⟦b⟧`. In practice CEq is never stuck for v5.0; it only emits or errors.
- `CTableSet(?t, _, _)`, `CTableSeal(?t, _)`, `CTableOpen(?t)`: blocks on ?t
  (but these never stick in v5.0; phase transitions are immediate).
- `CMethodCall(?t, _, _)`: blocks on ?t.
- `CInst`: never stuck.

**S-Wake.** When σ extends (rule S-Step modifies σ for some tvar t with a
new binding or phase flip), every C ∈ I watching t is moved back to W.
(Mechanically: σ.watchers[t] is drained; reactivations counter increments.)

**S-Quiesce.** Termination.

    W = ∅
    ─────────────────────────  S-Quiesce
    ⟨σ, ∅, I⟩ is terminal

At quiescence, every C ∈ I is reported as an error: `stuck constraint` with
its provenance and blocker list. (Inert ≠ error in general — but in v5.0
minimal core, the only constraint that can legitimately stick is
`CMethodCall` waiting for a seal; if quiescence is reached without seal,
the call site is a real bug.)

### Termination argument (sketch)

The state space `(σ, W, I)` is finite-decreasing along a well-founded
order:
- σ extends monotonically (never shrinks). Total binding capacity is
  bounded by the number of fresh tvars ever allocated, which is bounded
  by initial constraint count + total CInst applications × max binders.
- W shrinks by one per **S-Step**; may grow by `emitted.length` per step.
  But `emitted` is structurally smaller than the popped constraint
  (decomposition lemma: CEq on Arrow/Record/App emits CEqs on strict
  syntactic subterms; CInst emits one CEq on instantiated body, which
  is again structurally smaller via the binder count decreasing to 0).
- Reactivations (S-Wake) are bounded by `(# inert) × (# tvars)` since each
  tvar's bind/seal event happens at most once per tvar in a monotone σ.

**Re-emission termination (Spec A extension).** The simple-sub bounds system
(§"Simple-sub bounds (normative)") adds a source of `emitted` constraints that
is *not* structurally smaller than its antecedent: on a bound-add, the solver
re-emits `CSub(L, U)` for accumulated lower/upper pairs, and these `L`, `U` may
be arbitrary (possibly cyclic via the bound-graph) types.  Decomposition alone
does not bound this.  Termination is instead recovered by the **mandatory
subtyping cache**: every re-emitted obligation is keyed by the structural hash
of `(deref L, deref U)` (head tag + union-find identity of any uvar leaves);
a cache hit discharges immediately (`⇒ ε`, the relation is *assumed* to hold),
emitting nothing.  Because crescent types are **regular** (finite under the
μ-folding the bound-graph induces) and σ allocates finitely many tvars, the set
of distinct `(deref L, deref U)` keys reachable by re-emission is finite — its
size is `O(K²)` where `K` is the number of distinct deref'd subterms of the
constraint set.  Each key is processed (re-emitted from) at most once before its
entry is in the cache, so the total re-emission work is `O(K²)`, finite.  This
is the MLstruct §3.2 argument ("type-variable bound graphs may contain cycles,
and since types are regular the cache guarantees termination") transcribed to
the op-sem.  The cache is part of machine state (see §"Simple-sub bounds").

This is the same argument as in the prototype solver
(`lib/type/experiments/v5_perf/solver.lua`) and matches the perf-prototype's
empirical observation of reactivations ≪ emissions.

## What this spec does NOT cover (and why)

Per F12 — explicit gaps, not silently filled:

1. **CMultiReturn into row** (log item 7). Out of v5.0 scope. The
   spec must extend to cover `t.x, t.y = f()` where `f`'s return arity
   is union-shaped. Fixture 6 of the parity test depends on this; for
   v5.0 the fixture is encoded with manual scalar bindings as a
   stand-in, with the gap flagged.
2. **Circular `require` rejection** (log items 3, 4, 8 collapse). This is
   a module-ordering policy, not a constraint rule. Encoded in the
   driver, not in op-sem. Fixture 7 of the parity test verifies the
   driver-level policy; op_sem itself is not consulted.
3. **CMethodCall through μ.__index chain.** v5.0 only resolves direct
   fields on the sealed table. Chain-walking is owed when CHKT lands
   (because metatables can be type-applications).
4. **Row narrowing suppression** (log item 7 soundness floor). Optional
   fixture 8. Not in v5.0 minimal core — it interacts with `CRow` which
   ships separately.
5. **Effect rows**, **HKT**, **CImpl** (local givens). All deferred.

### Higher-kinded type application (CHKT) + higher-order unification residue (HOUnify)

**Added 2026-05-24.** Per the v5 re-gate schedule. Picks: direct type lambdas
with De Bruijn levels for bound vars (per log item 2); Miller pattern
fragment for HO unification; **never commit guessed HO solutions** (soundness
floor) — outside the pattern fragment we emit `HOUnify` and park on head
rigidity of the head constructor variable.

Two new constraint variants:

| Variant                       | Purpose                                        |
|-------------------------------|------------------------------------------------|
| `CHKT(?F, args, ?result)`     | assert `?F<args> = ?result` (HKT application)  |
| `HOUnify(head, args, rhs)`    | residue when Miller pattern check fails        |

`CHKT(?F, args, ?result)` asserts that applying the constructor variable `?F`
to `args` (an ordered list of `V5Type`s) yields `?result`. The substrate
representation of `?F<a₁..aₙ>` is the curried `App(...App(App(?F, a₁), a₂)..., aₙ)`.
`CHKT` exists as a first-class constraint (rather than always emitting
`CEq(App(...), ?result)`) so the solver can dispatch directly into the
Miller-fragment check before falling back to ordinary unification.

#### Miller pattern fragment check

Equation `?F a₁ a₂ … aₙ ≐ T` is in the Miller pattern fragment when:
1. `?F` (after deref) is an unbound `UVar`.
2. Each `aᵢ` (after deref) is a **rigid** type — concrete (any non-uvar tag).
3. The `aᵢ` are pairwise distinct as types (`types.equal`).
4. Every `UVar` free in `T` is either `?F` itself (which would be an occurs
   error and is rejected by side-condition) or appears among the `aᵢ`'s free
   vars closure. **In practice for v5.0** we restrict the check further: each
   `aᵢ` must itself be a single `UVar` (rigid name) or a `Const`; the body
   `T`'s free `UVar`s must be a subset of `{ id(aᵢ) | aᵢ.tag == "uvar" }`.

When in the fragment, the unique most-general solution is:

    ?F := lambda a₁. lambda a₂. … lambda aₙ. T'

where `T'` is `T` with each `UVar(aᵢ.id)` replaced by `Var(n - i)` (De Bruijn
level abstraction, eager-shift discipline per the substrate).

**Note on the v5.0 restriction.** The full Miller fragment admits any rigid
distinct argument (e.g. arbitrary tree-shaped rigid types). v5.0 starts with
the common case (`?F<?a>` or `?F<int>` style) because it covers Functor /
Monad / Applicative dictionary instances and the H2 record-of-generics shape
without forcing the more delicate occurs-check + alpha-equivalence engine.
**Listed as a v5.0 spec gap below.**

#### Rules

**T-CHKT-Miller.** Miller pattern fragment applies.

    ?F = uvar, unbound        each aᵢ rigid (non-uvar)
    aᵢ pairwise distinct       FV(?result_walked) ⊆ allowed
    body' = abstract(?result_walked, [a₁..aₙ])
    ────────────────────────────────────────────────────────  T-CHKT-Miller
    σ ⊢ CHKT(?F, [a₁..aₙ], ?result) ⇒ ⟨σ[?F ↦ λ…λ. body'], ε, done⟩

After binding `?F`, the solver wakes both the binding-watchers and the
head-watchers of `?F` (per substrate extension: head_watchers fire when
`?F`'s binding's top-level tag becomes rigid; the bound λ-chain is rigid).

**T-CHKT-Reduce.** `?F` is already bound to a `Lambda` (or chain of
Lambdas). β-reduce and emit a `CEq` against `?result`.

    deref(?F) = Lambda(k, body)    n = length(args)
    reduced = iter-instantiate(Lambda...Lambda body, args)
    ────────────────────────────────────────────────────────────────  T-CHKT-Reduce
    σ ⊢ CHKT(?F, args, ?result) ⇒ ⟨σ, [CEq(reduced, ?result)], done⟩

**T-CHKT-Rigid-Mismatch.** `?F` deref'd to a rigid non-lambda head (e.g.
`Const("number")`). HKT application on a non-constructor: error.

    deref(?F) = τ    τ.tag ≠ uvar    τ.tag ≠ lambda
    ──────────────────────────────────────────────────────────  T-CHKT-Rigid-Mismatch
    σ ⊢ CHKT(?F, args, ?result) ⇒ ⟨σ, ε, error("HKT app on non-constructor")⟩

**T-CHKT-Park.** Miller fragment doesn't apply AND `?F` is still an unbound
uvar. Emit a HOUnify residue and park on `?F`'s head-rigidity.

    deref(?F) = UVar(f)    not in Miller pattern
    ────────────────────────────────────────────────────────────  T-CHKT-Park
    σ ⊢ CHKT(?F, args, ?result) ⇒ HOUnify(?F, args, ?result), stuck-on-head(?F)

The HOUnify constraint goes into the inert set and is added to
`head_watchers[?F]` (NOT `watchers[?F]`) — it must NOT wake on uvar↔uvar
unions; only when `?F` itself becomes rigid (gets a non-uvar binding).

**T-HOUnify-Wake.** Head of `?F` is now rigid. Retry as CHKT.

    deref(?F) = τ    τ.tag ≠ uvar
    ────────────────────────────────────────────────────────────  T-HOUnify-Wake
    σ ⊢ HOUnify(?F, args, ?result) ⇒ [CHKT(?F, args, ?result)], done

The wake itself is driven by S-Wake-Head (below): when a CHKT/CEq rule
binds `?F`'s root to a non-uvar, drain head_watchers and re-enter.

**T-HOUnify-Stuck.** At quiescence, any remaining HOUnify in inert is an
"ambiguous constructor variable" error.

    quiescent    HOUnify(?F, args, ?result) ∈ I
    ────────────────────────────────────────────────────────────  T-HOUnify-Stuck
    error("ambiguous constructor variable ?F: head shape never rigidified")

**Soundness floor.** We never commit a guessed HO solution. `T-HOUnify-Stuck`
is the only disposition when Miller fails and stays failing. This is the v5
re-gate schedule's stated discipline.

#### Solver loop additions

**S-Wake-Head.** When σ is extended by a binding `?t ↦ τ` with `τ.tag ≠ uvar`
(rigid head), drain `head_watchers[?t]` and re-enter each waker into W.
Driven by the same hook as S-Wake but consulted only when the new binding
contributes a rigid head shape.

Implementation: every binding rule that extends σ now calls both
`wake(?t)` (normal) AND, when the bound RHS has a rigid (non-uvar) head,
`wake_head(?t)`. The two drain different maps; both are needed because a
constraint may be parked on EITHER kind of event.

#### Kind discipline (v5.0)

`Type` already has `Lambda(k: string, b: Type)` in `types.lua`. v5.0 uses
the `k` field as an opaque kind tag for documentation; full kind inference
with kind variables is a v5.x extension. CHKT's correctness in v5.0 does
NOT depend on kind-checking; arity is enforced by the lambda-chain length
(reduce checks `length(args) ≤ depth(lambda chain)`).

**Spec gap (v5.0, named per F12).** Kind inference is owed. Without it,
`CHKT(?F, args, ?result)` where `?F` is bound to a `Lambda` of insufficient
arity becomes a `T-CHKT-Reduce` step that produces a `CEq` between a still-
abstracted lambda and `?result` — the resulting unification surfaces as a
generic shape mismatch rather than an arity error. Acceptable for v5.0;
flagged for kind-checking extension.

#### Spec gaps surfaced (per F12; not silently filled)

1. **Restricted Miller fragment.** v5.0 admits only `UVar` or `Const` as
   pattern arguments; full fragment admits any rigid tree. Extend when a
   real corpus example needs it.
2. **Kind inference.** Lambda-arity is unchecked; mismatches surface as
   shape errors rather than arity errors. Owed.
3. **Eta-equivalence.** `λx. F x` vs `F` are not considered equal in the
   Miller check. Real-world impact unknown; flag when corpus surfaces it.
4. **Capture-avoiding abstraction during T-CHKT-Miller.** The `abstract`
   step replaces `UVar(aᵢ.id)` with `Var(n - i)`. If `T` contains an inner
   `Lambda`, the inner lambda's body uses fresh De Bruijn levels — the
   abstraction must shift them. v5.0 implementation handles the
   no-inner-lambda case; nested-lambda case is owed (orchestrator
   decision: rejected at abstraction time, or supported via shift-aware
   abstract?). Flagged.
5. **HOUnify residue provenance.** A HOUnify that arose from a CHKT that
   arose from a CImpl-nested wanted needs three-deep provenance. Substrate
   carries `prov` per-constraint but the chaining helper isn't built yet.

### Row polymorphism (CRow family)

**Added 2026-05-26.** Substrate: `TRowVar(id)` is a row metavariable (unbound:
open row; `nil` in substitution: closed row). `TRecord.row` is a `TRowVar` id or
`nil` (closed). Row variables are NOT tvar/UVars — they are stored in a separate
`row_bindings` table in the substitution, keyed by row-var id.

Three constraint atoms:

| Atom | Purpose |
|---|---|
| `CRowExtend(rec_ty, key, field_ty)` | Assert that `rec_ty`'s row contains `key` with type `field_ty` |
| `CRowLacks(rec_ty, key)` | Assert that `rec_ty`'s row does NOT contain `key` |
| `CRowClose(rec_ty)` | Close `rec_ty`'s row variable (seal the row) |

#### Rules

**T-CRowExtend-Bind.** Record has an open row var; key is absent. Extend the
field set in place.

    σ(rec_ty) = Record(F, ρ)    ρ is open    key ∉ dom(F)
    ──────────────────────────────────────────────────────────────  T-CRowExtend-Bind
    σ ⊢ CRowExtend(rec_ty, key, field_ty) ⇒ ⟨σ[F ∪ {key=field_ty}], ε, done⟩

**T-CRowExtend-Lookup.** Key already present. Equate types.

    σ(rec_ty) = Record(F, _)    F[key] = existing_ty
    ──────────────────────────────────────────────────────────────  T-CRowExtend-Lookup
    σ ⊢ CRowExtend(rec_ty, key, field_ty) ⇒ ⟨σ, [CEq(existing_ty, field_ty)], done⟩

**T-CRowExtend-Closed.** Row is closed (`ρ = nil`), key absent. Error.

    σ(rec_ty) = Record(F, nil)    key ∉ dom(F)
    ──────────────────────────────────────────────────────────────  T-CRowExtend-Closed
    σ ⊢ CRowExtend(rec_ty, key, field_ty) ⇒ ⟨σ, ε, error("extend on closed row: key absent")⟩

**T-CRowLacks-Open.** Row is open. Park watching the row var id.

    σ(rec_ty) = Record(F, ρ)    ρ ≠ nil (open row)
    ──────────────────────────────────────────────────────────────  T-CRowLacks-Open
    σ ⊢ CRowLacks(rec_ty, key) ⇒ ⟨σ, ε, stuck⟩

Constraint moves to I, watching the row var id ρ. It wakes when `CRowClose`
fires on the same record (closing ρ).

**T-CRowLacks-Closed-Pass.** Row is closed, key absent. Succeed.

    σ(rec_ty) = Record(F, nil)    key ∉ dom(F)
    ──────────────────────────────────────────────────────────────  T-CRowLacks-Closed-Pass
    σ ⊢ CRowLacks(rec_ty, key) ⇒ ⟨σ, ε, done⟩

**T-CRowLacks-Closed-Fail.** Row is closed, key present. Error.

    σ(rec_ty) = Record(F, nil)    key ∈ dom(F)
    ──────────────────────────────────────────────────────────────  T-CRowLacks-Closed-Fail
    σ ⊢ CRowLacks(rec_ty, key) ⇒ ⟨σ, ε, error("lacks violated: key present in closed row")⟩

**T-CRowClose-Bind.** Close the row variable (set to `nil`). Wake rowvar watchers.

    σ(rec_ty) = Record(F, ρ)    ρ ≠ nil
    ──────────────────────────────────────────────────────────────  T-CRowClose-Bind
    σ ⊢ CRowClose(rec_ty) ⇒ ⟨σ[row(ρ) := nil], ε, done⟩

After closing, S-Wake drains the row-var watcher list for ρ and re-enters
all parked `CRowLacks` constraints into W.

**S-Quiesce-CRowLacks.** Soundness floor. Any `CRowLacks` still in I at
quiescence is an error. An open row with no CRowClose issued means the
narrowing "this field is absent" cannot be confirmed.

    quiescent    CRowLacks(rec_ty, key) ∈ I
    ──────────────────────────────────────────────────────────────  S-Quiesce-CRowLacks
    error("row lacks constraint unresolved at quiescence: row var never closed")

This is the G8 soundness floor: assuming absence on an unclosed row variable
is unsound. The solver must see CRowClose before confirming CRowLacks.

### Intersection types and effect composition (CIntersection family)

**Added 2026-05-26.** Effects are types. `TConst` with a `"!"` prefix encodes
effects (`!io`, `!throw`, `!yield`, `!os`). `TIntersection([t₁..tₙ])` composes
types and effects without a parallel CEffect infrastructure. Canonical form is
defined and enforced: flatten all nested TIntersections, sort parts by canonical
key, deduplicate structurally equal parts. `constraint.flatten_parts(ty)` computes
this shared by both interpreters.

Three constraint atoms:

| Atom | Purpose |
|---|---|
| `CIntersectionEq(ty, parts)` | Assert that `ty` equals the intersection of `parts` |
| `CIntersectionSub(ty, parts)` | Assert that `ty` subtypes the intersection of `parts` (covariant sub into every part) |
| `CIntersectionMember(ty, idx)` | Assert that the `idx`-th part of intersection `ty` is well-typed |

#### Canonical form

`canonical(parts)`: flatten all nested `TIntersection` sub-trees, sort the
resulting flat list by `types.canonical_key(t)`, deduplicate structurally equal
(via `types.equal`) consecutive entries.

This is computed once at constraint creation and stored in the atom. Both
interpreters share `constraint.flatten_parts`.

#### Rules

**T-CIntersection-Eq-Canonical.** Both sides reduce to the same canonical form.

    canonical(σ⟦ty⟧) = canonical(parts)
    ──────────────────────────────────────────────────────────────  T-CIntersection-Eq-Canonical
    σ ⊢ CIntersectionEq(ty, parts) ⇒ ⟨σ, ε, done⟩

If the canonical forms differ: emit per-position `CEq` pairs (index-matched
after dedupe), or reject if the part count differs.

**T-CIntersection-Sub-Decomp.** `ty` must subtype the intersection: decompose
into one `CSub(ty, partᵢ)` per part (covariant: the concrete type must satisfy
every part of the intersection).

    parts = [p₁..pₙ]    n ≥ 1
    ──────────────────────────────────────────────────────────────  T-CIntersection-Sub-Decomp
    σ ⊢ CIntersectionSub(ty, parts) ⇒ ⟨σ, [CSub(ty, pᵢ)]ᵢ, done⟩

**T-CIntersection-Sub-Conj.** `ty` is itself an intersection. Decompose LHS too:
each LHS part must subtype each RHS part. (This is sound but may over-require;
correct under the covariant intersection model where the type satisfies all parts.)

    σ⟦ty⟧ = Intersection([q₁..qₘ])    parts = [p₁..pₙ]
    ──────────────────────────────────────────────────────────────  T-CIntersection-Sub-Conj
    σ ⊢ CIntersectionSub(ty, parts) ⇒ ⟨σ, [CSub(qⱼ, pᵢ)]ᵢⱼ, done⟩

**T-CIntersection-Member-Direct.** `ty` is an intersection; the `idx`-th member
exists and is extracted.

    σ⟦ty⟧ = Intersection(parts)    parts[idx] = partᵢ
    ──────────────────────────────────────────────────────────────  T-CIntersection-Member-Direct
    σ ⊢ CIntersectionMember(ty, idx) ⇒ ⟨σ, ε, done⟩

If `idx` out of bounds: error "member index out of bounds."

**S-Quiesce-CIntersectionMember.** F2 enforcement. At quiescence, any
`CIntersectionMember` still in I on an unbound uvar is an error.

    quiescent    CIntersectionMember(ty, idx) ∈ I    σ⟦ty⟧ = UVar(_)
    ──────────────────────────────────────────────────────────────  S-Quiesce-CIntersectionMember
    error("intersection member constraint stuck: type never rigidified")

#### Effect API

Effects are constructed via:

    types.effect(name)              → TConst("!name")
    types.effect_apply(eff, arg)    → TApp(TConst("!name"), arg)

The "!" prefix is the sole distinguisher — effects participate in ordinary
type unification and subtyping without special-casing. An effect intersection
`!io & !throw` is `TIntersection([TConst("!io"), TConst("!throw")])`.

#### Soundness sketch

1. Decomp (T-CIntersection-Sub-Decomp) is sound: a type satisfying a conjunction
   of requirements satisfies each one individually.
2. Conj (T-CIntersection-Sub-Conj) is sound under structural intersection: each
   part of the LHS must satisfy each part of the RHS. Conservative (may reject
   programs where a less-refined intersection model would accept), never unsound.
3. Canonical form ensures deduplication is idempotent and rule matching is
   deterministic regardless of constructor order.

## Cross-reference

| Rule label              | Executable function (op_sem.lua) |
|-------------------------|-----------------------------------|
| T-CEq-UU                | `rule_T_CEq_UU`                   |
| T-CEq-Bind-L            | `rule_T_CEq_Bind_L`               |
| T-CEq-Bind-R            | `rule_T_CEq_Bind_R`               |
| T-CEq-Const             | `rule_T_CEq_Const`                |
| T-CEq-Arrow             | `rule_T_CEq_Arrow`                |
| T-CEq-Record            | `rule_T_CEq_Record`               |
| T-CEq-App               | `rule_T_CEq_App`                  |
| T-CEq-Mismatch          | `rule_T_CEq_Mismatch`             |
| T-CEq-Occurs            | `rule_T_CEq_Occurs`               |
| T-CSub-Refl             | `rule_T_CSub_Refl`                |
| T-CSub-TVar (forward ptr) | superseded — see T-CSub-TVar-{Upper,Lower,Flow} |
| T-CSub-TVar-Upper       | P2 — `rule_T_CSub_TVar_Upper` (planned) |
| T-CSub-TVar-Lower       | P2 — `rule_T_CSub_TVar_Lower` (planned) |
| T-CSub-TVar-Flow        | P2 — `rule_T_CSub_TVar_Flow` (planned)  |
| T-CSub-Atomic           | P2 — `atomic_subtype` + `rule_T_CSub_Atomic` (planned) |
| S-Sub-CacheHit/Miss     | P2 — subtyping cache in `subst.lua` (planned) |
| T-CEq-Bind-L-Bounds     | P2 — `rule_T_CEq_Bind_L` extension (planned) |
| T-CEq-UU-Bounds         | P2 — `rule_T_CEq_UU` + `subst.union` extension (planned) |
| T-CSub-Arrow            | `rule_T_CSub_Arrow`               |
| T-CSub-Const-Var        | `rule_T_CSub_Const_Var`           |
| T-CSub-App-Var          | `rule_T_CSub_App_Var`             |
| T-CSub-App-Struct       | `rule_T_CSub_App_Struct`          |
| T-CSub-Record-Width     | `rule_T_CSub_Record_Width`        |
| T-CSub-Union-L          | `rule_T_CSub_Union_L`             |
| T-CSub-Union-R          | `rule_T_CSub_Union_R`             |
| T-CSub-Mismatch         | `rule_T_CSub_Mismatch`            |
| T-CTOpen                | `rule_T_CTOpen`                   |
| T-CTSet-Open-Fresh      | `rule_T_CTSet_Open_Fresh`         |
| T-CTSet-Open-Extend     | `rule_T_CTSet_Open_Extend`        |
| T-CTSet-Open-Equate     | `rule_T_CTSet_Open_Equate`        |
| T-CTSet-Sealed-Reject   | `rule_T_CTSet_Sealed_Reject`      |
| T-CTSeal                | `rule_T_CTSeal`                   |
| T-CMCall-Open-Stuck     | `rule_T_CMCall_Open_Stuck`        |
| T-CMCall-Sealed-Field   | `rule_T_CMCall_Sealed_Field`      |
| T-CMCall-Sealed-Missing | `rule_T_CMCall_Sealed_Missing`    |
| T-CInst                 | `rule_T_CInst`                    |
| T-CInst-Mono            | `rule_T_CInst_Mono`               |
| T-CHKT-Miller           | `rule_T_CHKT_Miller`              |
| T-CHKT-Reduce           | `rule_T_CHKT_Reduce`              |
| T-CHKT-Rigid-Mismatch   | `rule_T_CHKT_Rigid_Mismatch`      |
| T-CHKT-Park             | `rule_T_CHKT_Park`                |
| T-HOUnify-Wake          | `rule_T_HOUnify_Wake`             |
| T-HOUnify-Stuck         | `rule_T_HOUnify_Stuck`            |
| S-Wake-Head                         | `wake_head` (inside `run`)            |
| S-Step / S-Park / S-Wake / S-Quiesce | `run`                               |
| T-CRowExtend-Bind                   | `rule_T_CRowExtend_Bind`              |
| T-CRowExtend-Lookup                 | `rule_T_CRowExtend_Lookup`            |
| T-CRowExtend-Closed                 | `rule_T_CRowExtend_Closed`            |
| T-CRowLacks-Open                    | `rule_T_CRowLacks_Open`               |
| T-CRowLacks-Closed-Pass             | `rule_T_CRowLacks_Closed_Pass`        |
| T-CRowLacks-Closed-Fail             | `rule_T_CRowLacks_Closed_Fail`        |
| T-CRowClose-Bind                    | `rule_T_CRowClose_Bind`               |
| S-Quiesce-CRowLacks                 | `quiesce_errors` (inside `run`)       |
| T-CIntersection-Eq-Canonical        | `rule_T_CIntersectionEq`              |
| T-CIntersection-Sub-Decomp          | `rule_T_CIntersectionSub` (case 1)    |
| T-CIntersection-Sub-Conj            | `rule_T_CIntersectionSub` (case 2)    |
| T-CIntersection-Member-Direct       | `rule_T_CIntersectionMember`          |
| S-Quiesce-CIntersectionMember       | `quiesce_errors` (inside `run`)       |

Parity test asserts: for each fixture, the executable spec's final
`⟨σ_final, errors⟩` equals the docs-encoded rule-by-rule trace's final
`⟨σ_final, errors⟩`.
