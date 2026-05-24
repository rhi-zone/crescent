# Typechecker v5 — Operational Semantics (v5.0 minimal core)

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
| `CSub(a, b)`  | subtyping (v5.0: routed to CEq; variance later)    |
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

### Subtyping

**T-CSub-AsEq.** v5.0 stub: until variance lands (with CHKT), subtyping is
equality.

    ───────────────────────────────────────────  T-CSub-AsEq
    σ ⊢ CSub(a, b) ⇒ ⟨σ, [CEq(a, b)], done⟩

(v5-specific. The variance-respecting form is owed in the CHKT op-sem
extension; until then, CSub at the boundary degrades to CEq. Tracked as
spec gap in the log.)

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
| T-CSub-AsEq             | `rule_T_CSub_AsEq`                |
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
| S-Step / S-Park / S-Wake / S-Quiesce | `run`                |

Parity test asserts: for each fixture, the executable spec's final
`⟨σ_final, errors⟩` equals the docs-encoded rule-by-rule trace's final
`⟨σ_final, errors⟩`.
