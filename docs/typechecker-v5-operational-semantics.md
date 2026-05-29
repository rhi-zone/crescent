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
| `B.edge_down : Root → Set<Root>` | **bound-graph in-edges** (the dual of `edge_up`, referenced by **T-CEq-UU-Bounds** "and dually edge_down"): `r ∈ B.edge_down[r']` iff edge `α → β` recorded (α∈r, β∈r'). Maintained alongside `edge_up` so lower-bound propagation can walk predecessors without a graph search. |
| `C : Set<Hash>` | the **subtyping termination cache** (§"Bound-add with cache"). A hash is in `C` iff that `CSub(L,U)` obligation has been discharged-or-assumed. |

**Bound-flow polarity — CORRECTION (P2.1 implementation, 2026-05-29).** The
prose above and in **T-CSub-TVar-Flow** states "α's uppers flow to β; β's lowers
flow to α" for an edge `α → β` (`α <: β`). That polarity is **inverted** and is
unsound: it never propagates a *lower* of α forward to β, so the transitive
obligation `L <: α <: β ⇒ L <: β` is silently dropped (observed concretely: a
multi-return value flowing through an intermediate tvar lost its conflict with a
later annotation, producing a missed error). The **normative, sound** direction
— the standard simple-sub / MLstruct §3.2 closure this section explicitly
derives from — is the opposite:

> For an edge `α → β` (`α <: β`): a **lower** `L` of α flows **forward** to β
> (`L <: α <: β ⇒ L <: β`); an **upper** `U` of β flows **backward** to α
> (`α <: β <: U ⇒ α <: U`).

Both P2.1 interpreters implement this sound direction (op_sem `add_upper`/
`add_lower`; op_sem_alt `push_upper`/`push_lower`). The prose's "α's uppers flow
to β; β's lowers flow to α" should be read as the inverted statement of the same
two transitive closures and is superseded by the block-quoted rule above.

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

### Match types and variadic packs (CMatchEval + TPack)

**Added 2026-05-29 (Spec B of the spec-first program; DOCS-ONLY).** This section
is the normative substrate that makes `pcall` / `coroutine.*` / `pairs` /
`ipairs` and the `ReturnType` / `Parameters` / `Tail` family **declarable**
(stdlib `--::` declarations consumed by ordinary constraint solving) rather than
hardcoded handlers. It introduces:

- a first-class **`match` type-AST node** with v4-faithful pattern evaluation
  (oracle: `lib/type/static/match.lua`),
- a **`CMatchEval` constraint** that reuses the CHKT park/wake-head plumbing
  (`op_sem.lua` `wake_head`): park when the scrutinee's head is an unbound uvar,
  reduce eagerly when it is rigid,
- a first-class **`TPack` node** subsuming multi-return, `(...%P)` capture, and
  tuple types — retiring the `is_positional` predicate and the `"1".."n"`
  record-key encoding of arrow returns (`types.lua` `M.arrow`).

The spec is written to be encodable **independently** by `op_sem.lua` and
`op_sem_alt.lua` (the dual-interpreter premise). Where it cites current
`types.lua` / `op_sem.lua` behavior, that is the **divergence removed in the
implementation phase**, not the target.

**Substrate-before-consumers.** No rule below is keyed by an effect name, a
stdlib function name, or any specific `$`-intrinsic name. Effect extraction
(`!throw`, `!yield`) is specified purely as the **App-spine / intersection
cases of `match`** (§"Effect-pattern matching"). If a natural declaration of
`pcall` / `coroutine` still required a name-keyed solver step after this spec,
that would signal the substrate is insufficient; §"Substrate-sufficiency check"
records that no such residue remains.

#### TPack node (B owns this; Spec C consumes it)

A new type-AST node represents an **ordered sequence of types with at most one
open tail**:

    TPack = { tag = "pack", items: V5Type[], rest: TPackVar | nil }
    TPackVar = { tag = "packvar", id: integer }

- `items` is the fixed positional prefix (possibly empty).
- `rest` is a **single optional open-pack position** — `nil` (closed pack, exact
  arity `#items`) or a `TPackVar` (open: matches `#items` positions followed by
  zero or more further positions bound to the pack var).

The single-`rest` slot **structurally enforces** the surface rule "at most one
open pack per sequence." A sequence with two open segments
(`(...%P, number, ...%Q)`) is **unrepresentable**: there is exactly one `rest`
field and it is terminal. This is the intended consequence — the
one-open-pack invariant is an invariant of the data type, not a parser check.

`TPack` **subsumes** three previously-distinct encodings:

1. **Multi-return.** `arrow.ret` becomes a `TPack`, not a positional `Record`
   with `"1".."n"` keys. `(string) -> (number, string)` has
   `ret = pack([number, string], nil)`.
2. **`(...%P)` capture.** A pattern arg `(...%P)` is a `TPack` with empty
   `items` and `rest` bound to the capture's pack var; the captured middle args
   bind a pack (a `TPack`), not a v4 `TAG_TUPLE`.
3. **Tuple types.** `{ number, string }` (tuple, per `type-system.md`
   §Tuples) is `pack([number, string], nil)` — a closed pack. The bare
   `"1".."n"` record-key encoding and the `is_positional` predicate
   (`op_sem.lua`) are **retired**: positional sequences are no longer records.

**Arrow representation change.**

    TArrow = { tag = "arrow", args: TPack, ret: TPack }

`args` is a `TPack` (its `rest`, when present, is the `(...%P)` / vararg tail);
`ret` is a `TPack`. The fixed-arity `args: V5Type[]` and the `ret`-as-record
shape in `types.lua` are replaced. `M.arrow(args_list, rets_list)` constructs
`pack(args_list, nil)` and `pack(rets_list, nil)`; an explicit open form
`M.arrow_open` supplies a `rest`.

**Substrate operations on TPack** (mirroring `shift` / `instantiate` / `equal`
/ `collect_uvars` in `types.lua`):

- **`shift(pack, d, c)`**: shift each `items[i]` and (if present) the `rest`'s
  bound contents under the same cutoff. `TPackVar` ids are gensym (like `UVar`):
  never shifted. A `Var(i)` appearing inside an item shifts normally.
- **`instantiate(pack, arg, depth)`**: instantiate each `items[i]` and the
  `rest` contents. Capture bindings discovered by match (`%P`, `%R`) are
  **pattern-local De Bruijn binders** (see §"Pattern captures") and are
  substituted by `instantiate` under the arm's binder scope.
- **`equal(p, q)`**: `#p.items = #q.items`, items pairwise `equal`, and `rest`
  agreement — both `nil`, or both `TPackVar` with equal id (after deref).
- **`collect_uvars(pack, acc)`**: union of `collect_uvars` over items and over
  the `rest`'s bound contents (a `TPackVar` itself contributes no `UVar`; its
  binding may).

A `TPackVar` is a **pack metavariable**, stored in a separate `pack_bindings`
map in the substitution (keyed by pack-var id), exactly as `TRowVar` is stored
in `row_bindings` (per §"Row polymorphism"). It is **not** a `UVar`; `CEq` /
`CSub` on packs (below) bind it. Unbound = open tail of unknown length; bound to
a `TPack` = that tail spliced in.

#### TPack CEq / CSub rules (arity-aware, length-polymorphic, splice)

Let `deref_pack(p)` walk `p`, replacing a bound `rest` `TPackVar` by its binding
and **flattening** (splicing) the binding's items into `p.items`, recursively,
until `rest` is `nil` or an unbound `TPackVar`. This is the **substitution-time
splice**: when a `TPackVar` resolving to a `TPack` appears as a `rest`, its
items extend the positional slots (so `(true, ...R)` with `R ↦ pack([int,str])`
becomes `pack([true, int, str], nil)`, and `R ↦ never` / empty pack becomes
`pack([true], nil)` — the v4 `(true, ...R)` splice semantics, now first-class).

**T-CEq-Pack-Closed.** Both packs closed, equal arity.

    σ⟦p_a⟧ = pack(A_1..A_n, nil)    σ⟦p_b⟧ = pack(B_1..B_n, nil)
    ─────────────────────────────────────────────────────────────────  T-CEq-Pack-Closed
    σ ⊢ CEq(p_a, p_b) ⇒ ⟨σ, [CEq(A_i, B_i)]_i, done⟩

Arity mismatch (`n ≠ m`, both closed) ⇒ rejection ("pack arity mismatch").

**T-CEq-Pack-OpenL.** LHS has an unbound open `rest` `ρ`; RHS closed (or longer).
Match the shared prefix positionally; bind `ρ` to the **remaining tail** of the
RHS as a pack.

    σ⟦p_a⟧ = pack(A_1..A_n, ρ)    ρ unbound TPackVar
    σ⟦p_b⟧ = pack(B_1..B_m, nil)    m ≥ n
    ───────────────────────────────────────────────────────────────────────────  T-CEq-Pack-OpenL
    σ ⊢ CEq(p_a, p_b) ⇒
      ⟨σ[ρ ↦ pack(B_{n+1}..B_m, nil)], [CEq(A_i, B_i)]_{i≤n}, done⟩

If `m < n` ⇒ rejection (LHS demands more fixed positions than RHS supplies).

**T-CEq-Pack-OpenR.** Mirror: RHS open, LHS closed/longer.

**T-CEq-Pack-OpenBoth.** Both open. Equate the shared prefix; equate the two
`rest` pack-vars (`CEq` on the `TPackVar`s — union in `pack_bindings`), after
prefix-aligning by padding the shorter prefix's surplus into the other's tail.
(Both interpreters align by `min(n,m)`; the surplus prefix items of the longer
side are equated against fresh items prepended to the shorter side's `rest`
binding. Stated precisely: bind the shorter `rest` to
`pack(surplus_items, longer_rest)`.)

**T-CSub-Pack.** Subtyping on packs is **positional and length-polymorphic**,
with the variance of the *enclosing position* (arrow args are contravariant;
arrow ret covariant — supplied by the caller via the arrow rule, not re-derived
here). Given a target variance `v ∈ {co, contra}` carried from the arrow site:

    σ⟦p_a⟧ = pack(A_1..A_n, ρ_a)    σ⟦p_b⟧ = pack(B_1..B_m, ρ_b)    k = min(n,m)
    ──────────────────────────────────────────────────────────────────────────────  T-CSub-Pack
    σ ⊢ CSub_v(p_a, p_b) ⇒ ⟨σ, [subgoal(v, A_i, B_i)]_{i≤k} ++ tail-obligations, done⟩

where `subgoal(co, x, y) = CSub(x, y)`, `subgoal(contra, x, y) = CSub(y, x)`,
and `tail-obligations` reconcile the surplus prefix and the `rest`s by the same
prefix-alignment as **T-CEq-Pack-OpenBoth** but emitting `CSub_v` (not `CEq`)
on aligned positions. A closed pack is a subtype of an open pack of no greater
fixed arity (the open tail absorbs the surplus).

**Closed-vs-closed arity by variance (NORMATIVE CORRECTION, Phase 2.2).** The
prose above originally stated, unqualified, that "a closed pack is **not** a
subtype of a closed pack of different arity (rejection)." That reading is sound
**only for the contravariant (arrow-args) position** — a function of `n`
parameters is not one of `m ≠ n` parameters. For the **covariant (arrow-ret)**
position it contradicts the cited authority: Lua multi-return adjustment (the v4
`T-CSub-Record-Width` positional nil-pad / truncate, the documented soundness
floor). A callee returning `(A_1..A_n)` is usable where the caller requests
`(B_1..B_m)`: surplus callee returns (`n > m`) are **truncated**, and missing
callee returns (`n < m`) **adjust to `nil`**. The implementation therefore
splits the closed-closed case on variance:

- `v = contra` (args): arity must match exactly; `n ≠ m` ⇒ rejection
  (`arrow_arity_mismatch`).
- `v = co` (ret): iterate `i ∈ 1..m`; emit `CSub(A_i or nil, B_i)` (nil-pad the
  short side, truncate the long side beyond `m`). No arity rejection.

Both interpreters encode this identically. (Following the cited authority over
the unqualified prose, per the Phase-2.1 precedent that the spec prose has
carried soundness errors vs. its sources.)

**Arrow rules updated.** **T-CEq-Arrow** / **T-CSub-Arrow** now read `args` and
`ret` as packs: emit `CEq`/`CSub_contra` on `args` packs and `CEq`/`CSub_co` on
`ret` packs, via the pack rules above. The old positional `[CEq(A_i,B_i)]`
enumeration is subsumed by **T-CEq-Pack-Closed**.

**Interaction with Spec A (pack-typed bounds).** A generic `pcall`'s bound
`<F: (...P) -> R>` is a constraint whose RHS is an arrow over packs. Spec A's
bounds machinery (§"Simple-sub bounds") stores `B.upper[r] = (...P) -> R`
unchanged — the bound value is just a type, and `CSub(L, U)` re-emission on a
pack-typed upper bound dispatches to **T-CSub-Arrow** → **T-CSub-Pack**. No
new bounds machinery is required; the atomic/structural rejection that closes
the `∪lowers ⊆ ∩uppers` invariant (Spec A) now includes pack-arity rejection.
The cache key (Spec A §"Bound-add with cache") extends to packs by hashing
`head = ⟨"pack", #items, rest-id-or-nil⟩` plus the per-item head hashes.

#### match type-AST node

    TMatch = { tag = "match", param: V5Type, arms: Arm[] }
    Arm    = { pattern: V5Type, result: V5Type }

`param` is the scrutinee. Each `Arm` is tried **in order**; the first whose
`pattern` matches `param` (under the evaluation semantics below) fires, and the
match reduces to that arm's `result` with the arm's captures substituted.
Fallthrough (no arm matches) reduces to **`Const("never")`** (v4
`match.lua:evaluate` final `return T_NEVER`).

**Substrate operations on TMatch** (mirroring `shift`/`instantiate`/`equal`/
`collect_uvars`):

- **`shift(m, d, c)`**: shift `param` at cutoff `c`; for each arm, shift its
  `pattern` and `result` at cutoff `c + (arm binder count)` — because the arm's
  pattern captures introduce a binder scope (next section).
- **`instantiate(m, arg, depth)`**: instantiate `param`; instantiate each arm's
  `pattern`/`result` at `depth + (arm binder count)`. (Evaluation, not
  `instantiate`, performs capture binding; `instantiate` only relocates outer
  De Bruijn references through the arm scope.)
- **`equal(m, n)`**: `equal(m.param, n.param)`, same arm count, pairwise
  `equal` on `pattern` and `result`.
- **`collect_uvars(m, acc)`**: union over `param` and every arm's `pattern` and
  `result`.

#### Pattern captures as pattern-local De Bruijn binders

A pattern capture (`%P`, `%R`, the `[%K]`/`%V` of `{ ...[%K]: %V }`, the
`...%Rest` of `{ f: T, ...%Rest }`, the `#...%M` meta-spread) is a
**pattern-local binder** scoped to its arm. Each arm introduces a binder scope;
captures are represented as `Var(i)` De Bruijn indices into that scope,
composing with v5's existing `shift`/`instantiate`. This replaces v4's
name-keyed `bindings` map (`{ [name_id] -> type_id }`) at the *representation*
level, while **preserving v4's evaluation behavior**: evaluation still discovers
which input subterm binds each capture by **first-order pattern unification**,
builds a bindings map, then substitutes.

The two-phase port (faithful to `match.lua`):

1. **Discovery (build the bindings map).** Run `match_pattern(param, pattern)`
   (the v4 algorithm, §"Pattern evaluation"). On success it yields a map
   `binder-index ↦ V5Type`: each arm-scope `Var(i)` is associated with the input
   subterm that unified against capture position `i`.
2. **Substitution.** `result` is evaluated with each `Var(i)` replaced by its
   bound type — i.e. `instantiate` the arm's `result` with the discovered pack
   of bindings (innermost binder first, eager shift). A capture bound to a
   *pack* (e.g. `(...%P)` or a multi-return `%R`) substitutes a `TPack`;
   `(true, ...R)` in a result splices it (§"TPack CEq/CSub").

This is the **De Bruijn ⊕ match composition**: discovery is the v4 unification
(producing values), De Bruijn scoping is how those values are *named and
substituted* through `instantiate` — no separate name environment, no
`name_id`-keyed substitution pass. Nested matches compose because each arm's
scope shifts the outer scope by its binder count (the `shift` rule above).

#### Pattern evaluation (`match_pattern`, ported from v4)

`match_pattern(σ, ty, pat, seen)` returns `(fires?, bindings)`. Ported
faithfully from `lib/type/static/match.lua` (`M.match_pattern`); the cases
below are normative. All `ty` reads are after `deref`/`walk`.

- **Wildcard / capture.** `pat = _` (the desugared complement arm) ⇒ fires, no
  binding. `pat = %C` (a capture) ⇒ fires, binds capture `C`'s binder-index to
  `ty`.
- **Bare named pattern (no args).** Resolve in scope; fires iff
  `ty <: resolved` (a `CSub` query, not equality — v4 uses `try_unify`). Not in
  scope ⇒ arm fails (no implicit capture). `_` is the wildcard above.
- **Primitive / literal.** Exact tag match for `nil`/`boolean`/`number`/
  `integer`/`string`; literal equality for `TLiteral` (Spec C owns the literal
  node — forward reference). **Subtype widening**: `integer` matches `number`
  pattern; a literal matches its base atom's pattern (`"GET"` matches `string`).
  These widening facts are the **`atomic_subtype` lattice** of Spec A
  consulted abstractly — *not* re-implemented here and *not* string-matched on
  `$Lit*` names.
- **Table / record pattern.** Structural: every named pattern field must be
  present in `ty` (recurse `match_pattern` on each field). `{ f: T, ...%Rest }`
  binds `%Rest` to a **closed record of the unmatched fields**. `{ [K]: V }`
  matches `ty`'s indexers positionally, binding `K`/`V`. `{ ...[%K]: %V }` is
  **per-field distribution** (next bullet). `{ #...%M }` binds the meta slots.
- **All-fields distribution `{ ...[%K]: %V }`.** This is the **sole iteration
  mechanism** in match syntax (the `...` here means *iterate*, not *spread*).
  For each field of `ty`: bind `K` to the key (string/integer literal) and `V`
  to the **widened** value, evaluate `result`, and **union** the per-field
  results. Empty closed table ⇒ `never`; `any`/`unknown` ⇒ one
  `K=unknown,V=unknown` iteration; `never` ⇒ zero iterations. (v4
  `evaluate` `TAG_PAT_ALL_FIELDS` block.)
- **Function / arrow pattern.** `ty` must be an arrow. Match `args` pack against
  the pattern's `args` pack and `ret` pack against the pattern's `ret` pack via
  the **pack rules** — the `(...%P)` capture binds the middle positions as a
  `TPackVar` (T-CEq-Pack-OpenL discovers the tail), and `() -> %R` binds `%R`
  to the **ret pack** (single type if arity 1, a `TPack` if arity > 1, `never`
  if arity 0). This is the v4 rest-capture-as-tuple logic, now
  rest-capture-as-**pack**: the v4 `make_tuple` of the middle/return becomes a
  `TPack`.
- **Union scrutinee distribution.** If `param` is a `Union(M_1..M_k)`,
  evaluate the match against each `M_i` independently and **union the per-member
  results** (v4 `evaluate` union fast-path). Captures bind per-member; the union
  is of the substituted results.
- **Intersection scrutinee.** Coinductive field-merging structural match for
  table patterns (look the field up in every member, intersect contributions;
  a closed member lacking the field ⇒ fail; open member lacking it ⇒ neutral).
  For non-table patterns, **intersection elimination**: `A & B <: A`, so the arm
  fires if any member matches. This is the case effect-extraction relies on
  (next section).
- **Named / match scrutinee.** Expand a named alias one level (coinductively,
  via `seen`) and retry; evaluate a nested `TMatch` scrutinee and retry. The
  `seen` set is the coinductive cycle guard (next section).

**Conflicting capture bindings** (a capture bound to two non-equal types across
sub-positions) ⇒ the arm fails (v4 `merge_bindings` returns `nil`).

#### CMatchEval constraint (reuses CHKT park/wake-head)

A new constraint family drives match evaluation inside the solver:

    CMatchEval = { tag = "cmatch", param, arms, result, prov }

asserting `eval(match param { arms }) = result`. Reduction reuses the CHKT
**head-watcher** plumbing (`op_sem.lua` `wake_head`) — the same machinery that
parks `HOUnify` on `?F`'s head-rigidity:

**T-CMatchEval-Park.** `param`'s head (after `walk`) is an unbound `UVar`.
Park: the scrutinee is not yet rigid enough to decide which arm fires
(per rewrite-design §5.3 "suspension preserves principal types"). The
constraint moves to `I` on the **head-watcher** of `param`'s root (NOT the
ordinary watcher — like `T-CHKT-Park`), so it wakes only when `param` gets a
rigid head, not on a uvar↔uvar union.

    walk(param) = UVar(α)
    ─────────────────────────────────────────────────────  T-CMatchEval-Park
    σ ⊢ CMatchEval(param, arms, result) ⇒ stuck-on-head(α)

**T-CMatchEval-Reduce.** `param` is rigid (head is a non-uvar). Run
`match_pattern` arm-by-arm (the evaluation above). Let `R` be the substituted
result of the first firing arm (or `Const("never")` on fallthrough). Emit
`CEq(R, result)`.

    walk(param) = τ    τ.tag ≠ uvar    R = eval(match τ { arms })
    ───────────────────────────────────────────────────────────────────  T-CMatchEval-Reduce
    σ ⊢ CMatchEval(param, arms, result) ⇒ ⟨σ, [CEq(R, result)], done⟩

**Constraint-always with an eager fast-path.** `CMatchEval` is the *general*
form (constraints are always emitted for a `TMatch` node). When
`walk(param)` is **already rigid** at emission time, the generator/solver may
take the eager fast-path: run **T-CMatchEval-Reduce** immediately without ever
placing the constraint on `I`. Both interpreters must agree on the observable
result (the eager path is an optimization, not a different semantics).

**T-CMatchEval-Wake.** `param`'s root rigidified (`S-Wake-Head` fired). Retry as
`CMatchEval` (re-enter `W`); **T-CMatchEval-Reduce** now applies. (Mirror of
`T-HOUnify-Wake`.)

    walk(param) = τ    τ.tag ≠ uvar
    ─────────────────────────────────────────────────────  T-CMatchEval-Wake
    σ ⊢ CMatchEval(param, arms, result) ⇒ [CMatchEval(param, arms, result)], done

**Coinductive seen-set for recursive match.** Evaluation threads a `seen` set
keyed by `(deref param, match-node identity)` (v4 `match.lua:745` `evaluate`
`seen[mt_id]`, and `match.lua:393/505/718` cycle-keys `ty_id .. ":" .. pat_id`).
Re-entering an already-in-progress `(param, node)` pair returns the coinductive
hypothesis: `never` for `evaluate` re-entry (v4 `match.lua:750`), "assume the
arm matches with no new bindings" for `match_pattern` re-entry (v4
`match.lua:396`). This bounds recursive match over recursive scrutinees.

**T-CMatchEval-Stuck.** At quiescence, any `CMatchEval` still in `I` is an
error: the scrutinee's head never rigidified.

    quiescent    CMatchEval(param, arms, result) ∈ I    walk(param) = UVar(_)
    ────────────────────────────────────────────────────────────────────────  T-CMatchEval-Stuck
    error("match scrutinee never rigidified: cannot decide which arm fires")

(Per rewrite-design §5.3, *splitting* — taking the union over all
possibly-firing arms when a variable's bounds are sealed at a generalization
boundary — is a permitted last resort. v5 defers splitting: the conservative
disposition is the stuck error above. Flagged as a spec gap below.)

#### Effect-pattern matching as match App/intersection cases

Effect extraction is **not** a separate mechanism — it is the **App-spine and
intersection cases of `match`** applied to effect-typed values. Per
§"Intersection types and effect composition", an effect is a `Const("!name")`
and a higher-arity effect (`!throw<E>`, `!yield<Y,R>`) is an App-chain over the
effect head.

- **Effect App-spine pattern.** A pattern `!yield<%Y, %R>` is an `App`-spine
  whose head is the effect `Const("!yield")` and whose arguments are captures.
  `match_pattern` matches it head-first against an input effect application
  (the existing **T-CEq-App** / structural App decomposition): unify the head
  `Const`s, then bind `%Y`, `%R` to the argument positions. No effect-name
  string comparison beyond the ordinary `Const` name equality that **T-CEq-Const**
  already performs.
- **Effect in a return intersection.** A return type `nil & !throw<E>` is a
  `TIntersection`. Destructuring it is the **intersection scrutinee** case: the
  pattern `!throw<%E>` fires against the intersection by intersection
  elimination (`A & B <: A`), binding `%E` from the `!throw` member. This is
  exactly the v4 intersection-input handling in `match_pattern`.

Because effect extraction is now just these match cases, the ad-hoc `!throw` /
`!yield` **string-matches** (the adhoc-cluster) become deletable: their behavior
is reproduced by stdlib `--::` declarations of `pcall` / `coroutine.*` /
`error` written as `match` types over arrow/effect/intersection patterns. The
deletion itself is a later consumer phase (Spec C and the intrinsic
re-expression); this spec is the substrate that licenses it.

#### Substrate-sufficiency check (handler ≠ closure)

The planning rule "this spec must not describe any feature as a name-keyed
handler" is satisfied by construction:

- No rule dispatches on a stdlib function name. `pcall` / `coroutine` /
  `pairs` are types built from `TMatch` + `TPack` + arrow + intersection, solved
  by the rules above.
- No rule dispatches on an effect name beyond `Const`-name equality (which is
  the same generic mechanism every `Const` uses).
- No new `$`-intrinsic is required by this spec. The `match` patterns named in
  `lib/type/static/CLAUDE.md` (`() -> %R`, `(...%P) -> T`, `(true, ...R)`,
  `{ ...[%K]: %V }`, `{ f: T, ...%Rest }`, `{ #...%M }`) are all expressed by
  the pack + match cases above.

No residual name-keyed step was found. (Were one found, it would be flagged here
as evidence the substrate is insufficient — none is.)

#### Termination argument (match reduction)

1. **Parks until rigid.** `CMatchEval` over an unbound scrutinee is `stuck`, not
   reduced. It re-enters `W` at most once per head-rigidification of `param`'s
   root (S-Wake-Head), and σ is monotone (a root rigidifies at most once). So
   the number of `CMatchEval` reactivations is bounded by the number of distinct
   match nodes × the number of tvars — the same bound as the existing
   reactivation argument.
2. **Coinductive seen-set bounds recursive evaluation.** Within a single
   `T-CMatchEval-Reduce`, `evaluate` / `match_pattern` recurse through nested
   matches, named-alias expansions, and recursive scrutinees. Each recursive
   descent is guarded by the `seen` set keyed by `(deref param, node identity)`
   (and the per-`match_pattern` `(ty, pat)` cycle key). Because crescent types
   are **regular** (finite under μ-folding) and the type/pattern arena is
   finite, the set of distinct keys is finite; re-entry returns the coinductive
   hypothesis (`never` / assume-match) instead of recursing. Total evaluation
   work per reduction is therefore `O(K)` in the number of distinct
   `(scrutinee, pattern)` subterm pairs — finite. This is the v4
   `match.lua` cycle-key discipline transcribed to the op-sem.
3. **Emitted constraints are not larger.** `T-CMatchEval-Reduce` emits a single
   `CEq(R, result)`; `R` is a substituted subterm of the arms (or `never`), and
   the pack rules emit `CEq`/`CSub` on strict positional subterms. The
   decomposition lemma of the base termination argument extends unchanged.

#### Spec gaps surfaced (per F12; not silently filled)

1. **Match splitting at sealed bounds.** rewrite-design §5.3 permits splitting
   (union of all possibly-firing arm results) when a scrutinee variable's bounds
   are sealed at a generalization boundary. v5 defers this; the stuck-at-
   quiescence error (**T-CMatchEval-Stuck**) is the conservative disposition.
   Owed when a corpus example requires a match result through a still-polymorphic
   scrutinee.
2. **Pack subtyping under nested variance.** **T-CSub-Pack** carries the arrow's
   variance into positions, but a pack nested inside another pack (a tuple of
   tuples) re-derives variance per the enclosing position. The composition is
   defined; an adversarial deeply-nested pack-in-pack-in-arrow case has not been
   exercised. Flagged.
3. **Open-pack alignment determinism.** **T-CEq-Pack-OpenBoth** /
   **T-CSub-Pack** align surplus prefixes by `min(n,m)` and push surplus into the
   shorter `rest`. Both interpreters must choose the *same* alignment; the rule
   pins it (prefix-align by `min`, surplus → shorter rest), but a fuzz parity
   test across the two encoders is owed to confirm no divergence.
4. **Literal node ownership.** Literal patterns (`"GET"`, `42`) and the
   widening lattice are consumed here but **owned by Spec C** (`TLiteral`,
   `TRecord`). This spec references `atomic_subtype` (Spec A) abstractly and
   does not pin the literal encoding — forward reference to Spec C.

### Principled literals and records (TLiteral + TRecord)

**Added 2026-05-29 (Spec C of the spec-first program; DOCS-ONLY).** This is the
last of the spec-first trio (A: atomic_subtype bounds, B: TPack/match). It is the
normative substrate that **eliminates every `$`-prefix string-match in the
interpretation path**: the literal-encoding `Const`-names (`$Lit`, `$LitInt`,
`$LitNum`, `$LitBool`) and the record key-mangling encodings (`$opt_`, `$ro_`,
`$idx_N`, `$opaque_K`, `$computed_N`, `$pos_N`, `$spread_`) are replaced by two
structured type-AST nodes — `TLiteral` and `TRecord` — whose attributes are
**real fields**, dispatched on `tag`, never on a name prefix. This is the
project's "No special-casing" hard constraint applied to the type representation
itself.

The spec is written to be encodable **independently** by `op_sem.lua` and
`op_sem_alt.lua` (the dual-interpreter premise). Where it cites current
`types.lua` / `op_sem.lua` behavior (the `$`-name dispatch in `step_csub`
op_sem.lua ~:797–831, the `is_positional` record-key encoding, the
`$idx`/`$opt`/`$ro` key-mangle), that is the **divergence removed in the
implementation phase**, not the target. v4's mature record/literal/tuple
representation (`lib/type/static/types.lua` `TAG_LITERAL`, `TAG_TABLE` with
separate fields/indexers/row and per-field `FLAG_OPTIONAL`/`FLAG_READONLY`
flags) is the **oracle for the principled shape** — but v4's table *subtyping* is
itself ad-hoc (it routes table fields through `struct_equal`, i.e. invariant
everywhere, with `readonly` carried as a flag that subtyping ignores; see
`lib/type/static/unify.lua` and `types.lua` `struct_equal` TAG_TABLE arm). Spec C
does **not** copy that: it makes `readonly` *mean* covariance.

#### TLiteral node (retires `$Lit`/`$LitInt`/`$LitNum`/`$LitBool`)

    TLiteral = { tag = "literal", base, value }
      base  ∈ { "integer", "number", "string", "boolean" }
      value : the singleton inhabitant (Lua integer / number / string / boolean)

A `TLiteral` is a **leaf** type (a singleton atom), exactly like `Const`. The
prior encoding — `App(Const("$LitInt"), …)`, `App(Const("$Lit"), …)`,
`Const("true")`/`Const("false")` — is gone. `true` is
`{ tag="literal", base="boolean", value=true }`; `42` is
`{ tag="literal", base="integer", value=42 }`; `"GET"` is
`{ tag="literal", base="string", value="GET" }`.

**Walker treatment (leaf, like `const`).** In `types.lua`, `shift`,
`instantiate`, `equal`, and `collect_uvars` treat `literal` exactly as they treat
`const`:

- **`shift(lit, d, c) = lit`** — a literal contains no `Var`, returns itself.
- **`instantiate(lit, arg, depth) = lit`** — no bound vars to substitute.
- **`equal(a, b)`** for two literals: `a.base == b.base ∧ a.value == b.value`
  (value compared by Lua `==`; `number` vs `integer` base distinguishes
  `1` the integer literal from `1.0` the number literal).
- **`collect_uvars(lit, acc)`** — contributes nothing (a literal has no `UVar`).

#### TLiteral widening as a tag-dispatched atomic_subtype edge (composes with Spec A)

Spec A (§"atomic_subtype — the single primitive lattice") deliberately left the
literal encoding as a **forward reference to Spec C** and required the lattice to
expose literal-widening **abstractly**, "NOT by string-matching specific
`$`-prefixed names." Spec C now pins that abstraction: literal widening is a
**tag-dispatched** edge inside `atomic_subtype`, with **zero** `$`-name matching.

`atomic_subtype(a, b)` gains exactly these literal edges (dispatched on
`a.tag == "literal"` and/or `b.tag == "literal"`, never on any name):

1. **literal <: literal** — holds iff `a.base == b.base ∧ a.value == b.value`
   (same singleton). Otherwise the two distinct singletons are unrelated.
2. **literal <: const** — `a` a literal, `b` a `Const(n)` base atom. Holds iff
   `base_widens(a.base, n)`, where `base_widens` is the **same primitive widening
   relation** Spec A already defines for the `integer <: number` edge:
     - `base_widens(base, base)` — a literal widens to its own base atom
       (`"GET" <: string`, `42 <: integer`, `true <: boolean`, `1.0 <: number`);
     - `base_widens("integer", "number")` — reusing the `integer <: number`
       lattice edge, so `42 <: number` holds transitively (an `integer`-based
       literal widens to `number`).
3. **const <: literal** — never (a base atom is not a singleton); falls to the
   generic `¬atomic_subtype ⇒ error` disposition unless `a = never` /
   `b = unknown` (the bottom/top edges Spec A already owns).

The crucial point for the "no special-casing" criterion: rule (2) is
`base_widens(a.base, b.name)` — it reads `a.base` (a structured field) and reuses
the **integer<:number lattice edge** Spec A already has. It does **not** match
`a.f.name == "$LitInt"`. The `step_csub` literal-widening block (op_sem.lua
~:797–831) — the `$Lit`/`$LitInt`/`$LitNum`/`Const("true")` cascade — **collapses
entirely** into this: that block is deleted in the implementation phase, and the
`a, b atomic ⇒ atomic_subtype(a,b)` route (Spec A **T-CSub-Atomic**) decides
literal widening with a literal pair or a literal/const pair as the atoms.

The boolean-literal-as-`Const` hack folds in here: `Const("true") <: boolean`
(op_sem.lua ~:826–831) becomes `literal(boolean,true) <: Const("boolean")` decided
by `base_widens("boolean","boolean")` — same edge, no `name == "true"` check.

**T-CEq-Literal.** Two concrete literals under `CEq`.

    σ⟦τ_a⟧ = literal(base_a, val_a)    σ⟦τ_b⟧ = literal(base_b, val_b)
    ──────────────────────────────────────────────────────────────────  T-CEq-Literal
       σ ⊢ CEq(τ_a, τ_b) ⇒ ⟨σ, ε, done⟩   if base_a=base_b ∧ val_a=val_b
                                            else error("literal mismatch")

A literal vs a non-literal concrete head is **T-CEq-Mismatch** (the literal tag
differs from `const`/`record`/etc.). Widening is a *subtyping* fact only; `CEq`
between a literal and its base atom is a mismatch (a literal is not equal to its
base — only a subtype of it), exactly as v4 `try_unify` admits `42 <: integer`
but `unify` rejects `42 = integer`.

#### TRecord node (retires `$idx_N`/`$opt_`/`$ro_`/`$opaque_K`/`$computed_N`)

    TRecord = { tag = "record", fields, indexes, row }
      fields  : { [string]: TField }        -- named fields, keyed by bare name
      indexes : TIndex[]                     -- index signatures, first-class
      row     : TRowVar | nil                -- open (row var) vs closed (nil)

    TField  = { type, optional, readonly }   -- attributes are real booleans
      type     : V5Type
      optional : boolean                     -- was the `$opt_x` key prefix
      readonly : boolean                     -- was the `$ro_x` key prefix

    TIndex  = { key, value }                 -- was `$idx_N = $Idx(K)(V)`
      key      : V5Type                      -- the index key type (e.g. string)
      value    : V5Type                      -- the indexed value type

The `fields` map is keyed by the **bare field name** — no `$opt_`/`$ro_` prefix.
The optional/readonly attributes live on the `TField`. This is the v4 oracle's
shape (named fields with per-field `FLAG_OPTIONAL`/`FLAG_READONLY`, separate
indexer list, separate row var) lifted into the v5 AST, minus v4's flag-byte
packing — booleans, because the v5 substrate is plain Lua tables, not arena
slots.

**Mapping each retired `$`-encoding into the principled shape.** The
implementation phase rewrites the producer (`stdlib_types.lua` / the constraint
generator) to emit this shape directly; the table below is the normative
correspondence both interpreters must honor:

| Retired encoding                | Principled location                                  |
|---------------------------------|------------------------------------------------------|
| `$opt_x` (key prefix)           | `fields.x.optional = true`                           |
| `$ro_x` (key prefix)            | `fields.x.readonly = true`                           |
| `$idx_N = $Idx(K)(V)`           | one `indexes[]` entry `{ key = K, value = V }`       |
| `$opaque_K` (opaque-key field)  | an `indexes[]` entry with `key = Const(K)` (a single-key index signature; was v4 `FLAG_OPAQUE_KEY`) |
| `$computed_N`                   | a named `fields` entry (literal-key) or an `indexes[]` entry — **no key-mangle**; the computed key's resolved type decides which region |
| `$pos_N`, bare `"1".."n"` keys  | **NOT a record** → `TPack` (Spec B). Positional records are retired. |
| `$spread_` (record spread)      | lowers to Spec B's `TPack` `rest` — see Spec B; not redefined here. |

**Walker treatment.** `shift`/`instantiate`/`equal`/`collect_uvars` recurse into
the three regions:

- **`shift(rec, d, c)`**: shift every `fields[k].type` and every
  `indexes[i].key`/`indexes[i].value` at cutoff `c` (attributes `optional`/
  `readonly` are scalars — copied unchanged). `row` is a `TRowVar`, never shifted
  (gensym id, like `UVar`). The current `types.lua` `shift` record arm
  (which walks a flat `fields` map and copies `row`) extends to also walk
  `indexes` and to descend through `TField.type` rather than the bare field
  value.
- **`instantiate(rec, arg, depth)`**: same recursion; substitute `Var(depth)` in
  every field type and index key/value.
- **`equal(a, b)`**: `dom(a.fields) = dom(b.fields)` and for each `k`,
  `a.fields[k].optional = b.fields[k].optional`,
  `a.fields[k].readonly = b.fields[k].readonly`, and
  `equal(a.fields[k].type, b.fields[k].type)`; `#a.indexes = #b.indexes` with
  index entries pairwise `equal` on `key` and `value`; `row` agreement (both
  `nil`, or both `TRowVar` of equal id) — mirroring the current record `equal`
  arm, extended with the attribute comparison and the index list. (v4's
  `struct_equal` compares `fa.flags == fb.flags` for the same reason: attributes
  are part of identity.)
- **`collect_uvars(rec, acc)`**: union over every field type and every index
  key/value. (`row` is a `TRowVar`, not a `UVar`; contributes nothing.)

**Positional branches are dropped.** The `is_positional` predicate (op_sem.lua
~:390–402) and the `"1".."n"` record-key encoding are **retired by Spec B**
(TPack owns positional sequences). The field-walkers above carry **no positional
branch**, and the record CEq/CSub rules below **delete** the `a_pos && b_pos`
arms in `rule_T_CEq_Record` (op_sem.lua ~:413–434) and `rule_T_CSub_Record_Width`
(op_sem.lua ~:673–696). A positional sequence reaching a record rule in the new
substrate is a generator bug, not a record shape.

#### Record CEq — attributes part of identity

**T-CEq-Record (revised).** Two concrete records. The domains, the per-field
attributes, the index lists, and the rows must all agree; field types and index
key/value pairs are equated.

    σ⟦τ_a⟧ = Record(F_a, X_a, ρ_a)    σ⟦τ_b⟧ = Record(F_b, X_b, ρ_b)
    dom(F_a) = dom(F_b)
    ∀k ∈ dom(F_a). F_a[k].optional = F_b[k].optional ∧ F_a[k].readonly = F_b[k].readonly
    #X_a = #X_b    ρ-agreement(ρ_a, ρ_b)
    ──────────────────────────────────────────────────────────────────────────────────  T-CEq-Record
    σ ⊢ CEq(τ_a, τ_b) ⇒
      ⟨σ, [CEq(F_a[k].type, F_b[k].type)]_k
          ++ [CEq(X_a[i].key, X_b[i].key), CEq(X_a[i].value, X_b[i].value)]_i, done⟩

Domain mismatch, attribute mismatch, index-count mismatch, or row disagreement ⇒
rejection. (`ρ-agreement`: both `nil`, or both `TRowVar` with equal id, per the
existing `equal` row check.)

#### Record CSub — one variance rule for named fields AND index signatures

The single discipline, applied **identically** to named fields and to index
signatures (no special-casing the index sigs):

> **`readonly` ⇒ COVARIANT** (emit `CSub(v_a, v_b)`); **mutable** (the default,
> no modifier) **⇒ INVARIANT** (emit `CEq(v_a, v_b)`).

This is the principled correction of v4 (which treats *all* table-field
subtyping as invariant and ignores `readonly` in `struct_equal`). The soundness
basis is Spec A's "soundness floor": a mutable (writable) field/index is a
read-and-write position, so covariance is the TypeScript-array unsoundness;
`readonly` opts out of writes, so it is safe to be covariant. Consequences pinned
by the rule:

- `{ [string]: integer }` is **NOT** `<: { [string]: number }` (mutable index,
  invariant; would require `integer = number`, rejected).
- `{ readonly [string]: integer }` **IS** `<: { readonly [string]: number }`
  (readonly index, covariant; `CSub(integer, number)` holds).
- `{ x: integer }` is **NOT** `<: { x: number }`; `{ readonly x: integer }`
  **IS** `<: { readonly x: number }`. Same rule, named field.

Define the per-position variance subgoal (shared by fields and indexes):

    field_subgoal(fld_a, fld_b) =
        fld_b.readonly ? CSub(fld_a.type, fld_b.type)   -- covariant
                       : CEq (fld_a.type, fld_b.type)    -- invariant (mutable)

The **supertype's** modifier governs (you may supply a `readonly`-or-mutable
field where a `readonly` field is expected; you may **only** supply a mutable
field where a mutable field is expected — a `readonly` subtype field cannot
satisfy a mutable supertype field, because the supertype permits writes the
subtype forbids). Formally: if `fld_b.readonly` then `fld_a` may be readonly or
mutable; if `¬fld_b.readonly` then `fld_a` must be mutable (a readonly `fld_a`
against a mutable `fld_b` is rejected). Mirror for indexes with the index's own
`readonly` — Spec C does **not** carry a `readonly` flag on `TIndex` separately
unless the surface admits `readonly [K]: V`; per `type-system.md` it does, so
`TIndex` carries `readonly` as the same attribute. (If a producer never emits
`readonly` index sigs, the field defaults to mutable/invariant.)

**T-CSub-Record (revised T-CSub-Record-Width).** Width subtyping with the
one variance rule, optional-presence, and index-signature subtyping.

    σ⟦τ_a⟧ = Record(F_a, X_a, ρ_a)    σ⟦τ_b⟧ = Record(F_b, X_b, ρ_b)
    ──────────────────────────────────────────────────────────────────────────────  T-CSub-Record
    σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, named-obligations ++ index-obligations, done⟩

where:

**(1) Named-field obligations** (per supertype field `k`):

- `k ∈ dom(F_a)` (present in subtype): emit `field_subgoal(F_a[k], F_b[k])`.
  Additionally, if `F_b[k]` is required (`¬optional`) but `F_a[k]` is optional,
  **reject** (a possibly-absent field cannot satisfy a required one).
- `k ∉ dom(F_a)` (absent in subtype):
  - `F_b[k].optional` ⇒ **OK** (a supertype optional field may be absent from
    the subtype — the v4 `band(bfe.flags, FLAG_OPTIONAL) == 0` guard, inverted
    into the present rule);
  - `¬F_b[k].optional` ⇒ but the subtype has an index `X_a` whose `key` admits
    the string-literal `k` (`CSub(literal(string,k), X_a[j].key)` holds) ⇒ emit
    the field/index obligation against that index value (per (2) below);
  - else ⇒ **reject** with `missing_field` (the v4 missing-field error,
    op_sem.lua ~:703–705).

Subtype-only fields (`k ∈ dom(F_a) ∖ dom(F_b)`) are **forgotten** (width
subtyping: extra fields are fine), provided `ρ_b` is closed or absorbs them — see
(3).

**(2) Index-signature obligations** (per supertype index `X_b[i] = {key=K,value=V}`):
every subtype **named field** whose name-type is `<: K` must have its value
satisfy the index variance, and every subtype **index** must match the supertype
index:

- For each `k ∈ dom(F_a)` with `CSub(literal(string,k), K)` holding (the field's
  name, as a string literal, is admitted by the index key): emit
  `index_subgoal(X_b[i], F_a[k])` = `CSub(F_a[k].type, V)` if `X_b[i].readonly`
  else `CEq(F_a[k].type, V)`. (Same variance rule, index value vs. field value —
  no special-casing.)
- For each subtype index `X_a[j]` with `CSub(X_a[j].key, K)` (or key-equal,
  depending on key variance — keys are **contravariant** consumers of the lookup
  argument, so `CSub(K, X_a[j].key)`): emit the value obligation
  `CSub(X_a[j].value, V)` if `X_b[i].readonly` else `CEq(X_a[j].value, V)`.
- If the supertype index is required to be covered and neither a named field nor
  a subtype index covers `K`, the obligation is vacuously satisfied only when the
  subtype is **open** on that key region; otherwise it is an index-coverage
  rejection. (v5.0 conservative form: emit the obligations that *do* match; a
  supertype index with no subtype witness and a closed subtype row is a
  `missing_index` error. Backtracking over which witness covers which index is a
  later extension, flagged below.)

**(3) Row obligations.** If `ρ_b` is closed (`nil`), the subtype must not carry
extra fields the supertype forbids — but width subtyping **admits** forgetting
extra subtype fields, so a closed supertype row only constrains that every
supertype-required field/index is covered by (1)/(2); extra subtype fields are
dropped. If `ρ_b` is open (a `TRowVar`), it absorbs the surplus subtype fields
(row unification, per §"Row polymorphism" — `CRowExtend`/`CRowClose` machinery,
unchanged). Spec C adds no new row mechanism; it only routes the surplus through
the existing row var.

**Key contravariance note.** Index *keys* are consumer positions (the argument
you index with): a subtype index may admit **more** keys (a wider key type), so
keys are contravariant — `X_b[i].key <: X_a[j].key` is the obligation, matching
arrow-arg contravariance. Index *values* follow the readonly/mutable variance
rule above. Both interpreters must agree on this split (key contra, value per
readonly).

#### `unit` primitive (retires `$Unit`)

`$Unit` (the empty tuple / void / "no value") becomes a **real primitive**
`Const("unit")` with a lattice entry, not a magic `$`-name. It is added to the
base lattice consulted by `atomic_subtype` (Spec A):

- `never <: unit` (bottom subtypes it, by the generic bottom edge),
- `unit <: unknown` (top, generic),
- `unit <: unit` (reflexivity, generic),
- `unit` is otherwise **unrelated** to other base atoms (it is not `nil`; `nil`
  is a value, `unit` is the absence of a value / the empty return pack). A
  zero-arity return is the empty `TPack` (Spec B) at the pack level; `unit` is the
  *atom* a context demands when it wants "no value" as a first-class type. The
  two coincide in meaning but live at different levels — `TPack([], nil)` for
  arrow returns, `Const("unit")` where an atom is required. Both interpreters
  treat `Const("unit")` as an ordinary nullary `Const` for CEq/CSub (it falls
  into **T-CEq-Const** / **T-CSub-Const-Var** / **T-CSub-Atomic** with no special
  case — the name is just `"unit"`, dispatched like any other `Const` name).

The dead encodings `$Typeof` / `$IndexAccess` (removed, commit 2e69fee1) are
**not** respecified here. `$Spread` / `$spread_` (record spread) lowers to Spec
B's `TPack` `rest` — see Spec B; not redefined.

#### Interaction map

- **literal ↔ Spec A.** Literal widening is an `atomic_subtype` edge dispatched
  on `tag == "literal"` (and the reused `integer<:number` `base_widens` edge),
  not on a `$`-name. Spec A's forward reference to Spec C ("the lattice exposes
  *is `a` a literal whose base is `b`* as a lattice operation") is discharged by
  the `base_widens(a.base, b.name)` formulation above.
- **tuple / spread ↔ Spec B.** Positional sequences (tuples, multi-return,
  `(...%P)`, record spread) are `TPack` (Spec B), not records. Spec C references
  TPack; it does not redefine it. The positional branches in the record
  walkers/CEq/CSub are **deleted** (they moved to Spec B's pack rules). A literal
  pattern (`"GET"`, `42`) in a `match` arm (Spec B) is a `TLiteral`, matched by
  `match_pattern`'s primitive/literal case consulting `atomic_subtype` abstractly
  — Spec B's §"Literal node ownership" gap (item 4) is closed by this section.

#### No-`$`-string-match success criterion

After Spec C is implemented (the producer rewrite + the rule revisions above), a
search of the **interpretation path** (`op_sem.lua`, `op_sem_alt.lua`,
`types.lua` walkers, and the subtype/equal dispatchers) must find **zero**
occurrences of either:

- a comparison `name == "$X"` for any literal/record/unit encoding name
  (`$Lit`, `$LitInt`, `$LitNum`, `$LitBool`, `$idx*`, `$opt_*`, `$ro_*`,
  `$opaque_*`, `$computed_*`, `$pos_*`, `$spread_*`, `$Unit`), nor
- a prefix test `name:sub(1, n) == "$…"` for any of the above.

The only surviving `$`-names are the **permanent type-level intrinsics** named in
`lib/type/static/CLAUDE.md` (`$Require`, `$Opaque`, `$FfiC`, `$GlobalScope`,
`$Throw`/`$Catch`, `$EachField`, `$PatternReturn`, `$FindReturn`), and even those
are not part of the literal/record *interpretation* path — they are consumed by
the annotation/intrinsic layer, not by `atomic_subtype` or the record CEq/CSub
rules. A residual literal/record/unit `$`-match found after implementation is
evidence the producer rewrite is incomplete, not a license to keep the match.

#### Spec gaps surfaced (per F12; not silently filled)

1. **Index-coverage backtracking.** **T-CSub-Record** (2) emits obligations for
   the named fields / subtype indexes that *match* a supertype index; it does not
   backtrack over which witness covers which supertype index when several could.
   The conservative form (`missing_index` when no witness and closed row) is
   sound but incomplete. Owed when a corpus example needs a record with multiple
   overlapping index signatures.
2. **`readonly` on `TIndex` surface.** Spec C carries `readonly` as a `TIndex`
   attribute to keep the one-variance-rule uniform. If the surface syntax never
   admits `readonly [K]: V`, the attribute defaults to `false` (mutable/invariant)
   and the covariant index path is dead code until the surface adds it. Flagged,
   not pre-built beyond the attribute slot.
3. **`number`-vs-`integer` literal base.** `base = "number"` distinguishes a
   `number` literal (`1.0`) from an `integer` literal (`1`). The `value`
   comparison in `equal` uses Lua `==`, under which `1 == 1.0` is true in Lua
   5.1 / LuaJIT — so two literals with **different bases** but equal numeric
   value are kept distinct by the `base` comparison, not the value. Both
   interpreters must compare `base` first. Flagged as the one place value
   equality alone is insufficient.

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
| T-CEq-Pack-Closed                   | impl phase — `rule_T_CEq_Pack` (planned) |
| T-CEq-Pack-OpenL / -OpenR / -OpenBoth | impl phase — `rule_T_CEq_Pack` (planned) |
| T-CSub-Pack                         | impl phase — `rule_T_CSub_Pack` (planned) |
| T-CMatchEval-Park                   | `step_cmatch` (uvar head) → `park` head-watcher on scrutinee root (Phase 2.4) |
| T-CMatchEval-Reduce                 | `rule_T_CMatchEval_Reduce` → `eval_match` / `match_pattern` (Phase 2.4) |
| T-CMatchEval-Wake                   | `wake_head` re-entry of the parked `cmatch` (Phase 2.4) |
| T-CMatchEval-Stuck                  | `run` quiescence inert-loop `cmatch` branch (Phase 2.4) |
| match_pattern (all cases)           | `match_pattern_impl` (op_sem) / `pat_match` (op_sem_alt), ported from v4 `lib/type/static/match.lua` (Phase 2.4) |
| T-CEq-Literal                       | impl phase — `rule_T_CEq_Literal` (planned); folds into `step_csub`/`atomic_subtype` literal edge |
| T-CEq-Record (revised)              | impl phase — `rule_T_CEq_Record` minus positional arm (planned) |
| T-CSub-Record (revised)             | impl phase — `rule_T_CSub_Record_Width` → variance-respecting (planned) |
| literal widening (atomic_subtype edge) | impl phase — `atomic_subtype` literal/`base_widens` edge, replaces `step_csub` `$`-cascade (planned) |

Parity test asserts: for each fixture, the executable spec's final
`⟨σ_final, errors⟩` equals the docs-encoded rule-by-rule trace's final
`⟨σ_final, errors⟩`.
