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

**T-CSub-TVar.** Either side is an unbound `UVar`.  v5.0 discipline: route to
`CEq` (no per-tvar bounds).  This trade matches the substrate decision in
log item 6 (tvars don't change level) and item 2 (gensym ids with no bound
field).  Bounded inference is a v5.x extension.

    σ⟦τ_a⟧ = UVar(_)  ∨  σ⟦τ_b⟧ = UVar(_)
    ──────────────────────────────────────────────────────  T-CSub-TVar
              σ ⊢ CSub(τ_a, τ_b) ⇒ ⟨σ, [CEq(τ_a, τ_b)], done⟩

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

1. **Bounded tvars** (no per-tvar lower/upper bound).  T-CSub-TVar routes
   to CEq.  A real bounded substrate (simple-sub / MLstruct style) is a
   v5.x extension.  Trade is recorded in log item 2/6.
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
| T-CSub-TVar             | `rule_T_CSub_TVar`                |
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
| S-Wake-Head             | `wake_head` (inside `run`)        |
| S-Step / S-Park / S-Wake / S-Quiesce | `run`                |

Parity test asserts: for each fixture, the executable spec's final
`⟨σ_final, errors⟩` equals the docs-encoded rule-by-rule trace's final
`⟨σ_final, errors⟩`.
