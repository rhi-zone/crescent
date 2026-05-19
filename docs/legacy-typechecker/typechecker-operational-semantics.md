# Typechecker — operational semantics

## 0. Frame

This document is the **authoritative operational specification** of crescent's
static constraint solver. It defines the configuration the solver carries,
the primitives a rule may invoke, and a single inference rule per constraint
kind. Where the spec and the code disagree, the code is wrong and Phase 3
will reconcile the code to this spec — not the other way around.

It is **not** a design proposal, a roadmap, or an aspirational vision; every
construct here is grounded in an existing handler, primitive, or invariant in
`lib/type/static/`. Two open questions are flagged in §11. Phase 3 cannot
start while §11 names any item tagged BLOCKER.

Inputs that shape this spec: the handler-shape audit
(`docs/typechecker-handler-shape-audit.md`) and the six solver fundamentals
(`docs/typechecker-solver-fundamentals.md`).

**Paradigm.** Crescent uses **local type inference with bidirectional propagation**. It is not OutsideIn/X. It is not full Hindley-Milner. Where vocabulary overlaps with those systems (e.g. "given" / "wanted", "implication"), the meaning is crescent's — typically a priority annotation or a structural marker, not a logical axiom or scope. Polymorphism is introduced two ways: (1) explicit `<T>` annotations parsed as `TAG_FORALL`, and (2) implicit Hindley-Milner generalization at unannotated function definitions (HM Phase 1b; `constrain.lua:2372–2378` calls `env_mod.generalize`, with `record_polymorphic_ops_post` capturing nested bound TVs per `docs/typechecker-hm-phase2.md`). What crescent does NOT do is let-generalization on arbitrary `local x = e` bindings — those remain monomorphic unless `e` is itself a function definition that triggers (2). Where this spec borrows literature notation, it does so for legibility; the operational meaning is grounded in `lib/type/static/`, not in the cited paper.

## 0.1 Gen-time invariants (constraint generation phase)

The spec describes the solver's transitions on a constraint stream already
produced by `lib/type/static/constrain.lua`. Several operations run at
*generation time* and are inputs to the solver, not solver primitives:

- **`skolemize_fn`** (`constrain.lua:2048`) — when a function body whose
  signature has explicit `<T>` quantifiers is generated, the body sees
  skolem TVs in place of the quantifiers. The spec's `skolemize` primitive
  (§2) is the same operation invoked from a solve-time site
  (`env.skolemize_return_for_rank_n`); both write into `T` with
  `FLAG_SKOLEM` set, and both rely on invariant 6 to prevent binding.
- **`env_mod.generalize`** (called from `constrain.lua:2372`) — implicit
  HM generalization at unannotated function definitions. The output is
  a `TAG_FORALL` type that flows into the solver via the function's
  binding in `Env`.
- **`record_polymorphic_ops_post`** (HM Phase 2) — records template-rooted
  operations on inferred generic functions for later re-solve, populating
  `_forall_bounds` / `_forall_ops` (see `docs/typechecker-hm-phase2.md`).

The solver receives the post-generation `W`, `Env`, and `T` and operates
on them per §1–§3. Generation-time code is referenced where rules depend
on its output, but its semantics are not part of this spec.

## 1. Configuration

The solver's transition state at any moment is a tuple
`Σ = ⟨W, T, Env, R, O, IB, G, Tier, E⟩` over the typechecker context `ctx`:

| Component  | Type                                       | Backing field in `ctx`           |
|------------|--------------------------------------------|----------------------------------|
| `W`        | `Worklist : Queue<Constraint>`             | `ctx._worklist`                  |
| `T`        | `TVMap   : TVId → TVCell`                  | `ctx.types` arena + union-find   |
| `Env`      | `Bindings : NameId → TypeId` (per scope)   | `ctx.scope` (envs from `env.lua`) |
| `R`        | `Waiters : TVId → List<Constraint>`        | `ctx.tv_waiters`                 |
| `O`        | `Owners  : TVId → Constraint?`             | `ctx.tv_owners`                  |
| `IB`       | `InferredBounds : TVId → Bound?`           | `ctx.tv_bounds`                  |
| `G`        | `BindGen : ℕ` (monotone counter)           | `ctx._bind_generation`           |
| `Tier`     | `{ GIVEN, WANTED }`                        | `ctx._current_tier`              |
| `E`        | `Diagnostics` (write-only)                 | `ctx.err`                        |

The `level` field on `Unbound` TVCells (§1) is set at TV creation and read by `env.instantiate` but is not consulted by any rule in §3. It is preserved here for code-state fidelity, not because the spec uses it.

A `TVCell` is one of:

- `Unbound { id, level, flags }` — a free type variable; flags include
  `FLAG_SKOLEM` and `FLAG_SUB_SOLVE_PARAM`.
- `Bound   { ty : TypeId }` — union-find chain leading to a concrete type.

(In the current arena both forms inhabit the same physical `TAG_VAR` node;
`Bound` corresponds to `data[2] ≠ self`. The semantics distinguishes them.)

Every constraint `c` carries hidden bookkeeping the dispatcher manages:
`c._solved : bool`, `c._deferred : bool`, `c._tier : {GIVEN=0, WANTED=1}`.

### Invariants (carried across every transition)

1. **Waiter coverage.** If a constraint `c` returned with `c._deferred = true`
   and named a TV `v` via `await`, then `c ∈ R[find(v)]` until either (a) the
   bind chokepoint fires on `find(v)`, or (b) `c` is re-run and retires.
   `lib/type/static/solve.lua:93-102`.
2. **Ownership monotonicity.** If `O[find(v)] = c`, then `c` has a
   terminal-success path that ends in a `bind(v, _)` call. Release is
   performed only by the bind chokepoint (`unify.lua:355`,
   `bind_to` in `solve.lua:471`). No handler clears `O[v]` directly.
3. **Bind chokepoint.** Every transition from `Unbound v` to `Bound v=ty` in
   `T` flows through `unify.bind_var_to_type` (`unify.lua:340`). On every
   such transition: `G` increments by 1 via `wake_waiters`, `R[v]` is drained
   into `W` (with `_deferred = false`), and `O[v]` is cleared.
4. **Tier inheritance.** When a handler emits a child constraint without
   setting `_tier`, the child inherits the parent's tier (`solve.lua:4007`).
5. **Terminal diagnostics.** Any handler that calls `add_error` (or
   `add_warning_code` at error severity) returns "solved" on the same step;
   the constraint is retired, never retried. Each user-visible diagnostic
   reaches `E` at most once per constraint.
6. **Scope and skolem.** Skolems (`FLAG_SKOLEM`) are never bound. Any attempt
   is a terminal error from `bind_var` (`unify.lua:258-263`).
7. **Sub-solve param marker (`FLAG_SUB_SOLVE_PARAM`).** A TV with this flag is a function-body parameter being inferred during a sub-solve pass (HM Phase 1c, `docs/typechecker-hm-phase2.md`). When a constraint encounters such a TV in a position where it would normally `defer` waiting for resolution, it MUST instead emit `merge_inferred_bound(v, shape)` to record the inferred bound, then retire. This is the contract that distinguishes "this TV is being inferred by another sub-solve and we should contribute a bound" from "this TV is unresolved and we should park." Sites include `solve.lua:1538, 1654, 2163, 2524, 2615, 2944` (consult sites for `FLAG_SUB_SOLVE_PARAM`).

## 2. Primitives

Each primitive is invoked synchronously by a rule. Side effects on `Σ` are
listed; anything not listed is preserved.

Not every primitive is rule-callable from multiple sites: `try_each` is invoked only by C_RESOLVE_OVERLOAD; `release` is invoked only by the bind chokepoint (and is therefore moved to the Discipline section at the end of §2). Singletons are honest when the primitive's contract genuinely applies to one situation only.

### `emit(c) : Constraint → ()`
Appends `c` to the parent's constraint list and to `W`. `c._tier` defaults
to the parent's tier (`solve.lua:4004-4012`).
- **Pre.** Currently inside the dispatcher running some parent constraint.
- **Post.** `W' = W ⊕ [c]`. No bindings change.

### `bind(v, ty) : (TVId, TypeId) → (ok, err?)`
**Chokepoint** — the only primitive that may change `T`.
Equivalent to `unify.bind_var_to_type` (`unify.lua:340`).
- **Pre.** `find(v)` is `Unbound` and not `FLAG_SKOLEM` (else error).
- **Post.** `T[find(v)] := Bound ty`; `G := G + 1`; for each `c ∈ R[find(v)]`
  set `c._deferred := false` and push to `W`; `R[find(v)] := ∅`;
  `O[find(v)] := nil`. If `ctx._current_tier = WANTED` and any waiter has
  `_tier = GIVEN`, also sets `ctx._bind_woke_given := true`.

### `unify(t1, t2) : (TypeId, TypeId) → (ok, err?)`
Structural-recursive relation. Recurses through the type algebra, calling
`bind` at leaves where one side is a free TV. **Synchronous primitive, not
a constraint** — see §5.

### `try_unify(t1, t2) : (TypeId, TypeId) → bool`
Read-only probe (`unify.lua:1075`). No effect on `T` even on success.

### `park(c, on=v) : (Constraint, TVId) → ()` (`await`)
Registers `c` as a waiter on `find(v)`.
- **Pre.** `c` is currently running.
- **Post.** `R[find(v)] := R[find(v)] ⊕ [c]`. The handler must return
  `{ solved = false, await = find(v) }` so the dispatcher marks
  `c._deferred = true`.

### `retire(c) : ()`
Mark the running constraint solved. Implemented as handler return-true.
- **Post.** `c._solved := true`.

### `defer(c) : ()`
Mark deferred without binding to any specific TV (handler return-false).
Equivalent to `park` only when paired with explicit re-wake mechanics
(round re-seed at quiescence boundary; `solve.lua:4054-4059`). Used by
handlers like `solve_or`, mid-loop deferrals, and `solve_escape_check`.
- **Post.** `c._deferred := true`. `c` will be re-run on the next round if
  any TV bound during this round (re-seed) or never (if no progress).

### `fail(c, msg) : ()`
Emit `msg` to `E` at `c`'s line/col, then `retire(c)`. Terminal — see
invariant 5.

### `claim(v, c) : (TVId, Constraint) → ()`
`solve.lua:136`. Asserts a future writer commitment.
- **Post.** `O[find(v)] := c`. Idempotent.

### `is_owned(v) : (TVId) → bool`
`solve.lua:148`. Readers consult before falling through to `unify` on a free
TV.

### `find(v) : TVId → TVId`
Read-only union-find representative chase. Pure read on `T`. (Notation throughout the spec.)

### `try_unify_strict(t1, t2) : (TypeId, TypeId) → bool`
Non-widening probe (`unify.lua:1373`). Distinct from `try_unify` because it forbids widening adjustments. Read-only.

### `widen(t, mode) : (TypeId, {SUB, LITERAL, DEEP}) → TypeId`
Type-widening primitive. Three modes: `widen_for_sub` (`solve.lua:194`), `widen_literal` (`solve.lua:361`), `widen_deep` (`solve.lua:381`). Callers pick mode by context.

### `subtract(t, exclude) : (TypeId, TypeId) → TypeId`
Type-algebra subtraction, primarily for nil/false removal in C_OR and C_NARROW_NIL (`types.lua:1114`).

### `meta_op_ret(op, tid) : (string, TypeId) → TypeId?`
Recursive metamethod return-type lookup; walks unions/intersections (`solve.lua:538`). Shared by C_ARITH and C_COMPARE.

### `merge_inferred_bound(v, bound) : (TVId, Bound) → ()`
Appends to `IB[find(v)]`. Used by sub-solve param paths (per invariant 7). `solve.lua:1402`.

### `project(obj, key) : (TypeId, TypeId | string) → TypeId?`
Type-level indexing. Multi-tag dispatch (TAG_TABLE field, TAG_NOMINAL meta-__index, TAG_UNION distributed, TAG_INTERSECTION joined). Implementation across `solve_index` body (`solve.lua:1457+`).

### `escape_check(t, call_id) : (TypeId, ℕ) → bool`
Graph walk from `find(t)` AND the call frame's outer `Env` bindings
checking for any reachable TV bearing the matching call-id skolem mark.
Used by C_ESCAPE_CHECK and by `subsume` cases 1–3. `solve.lua:799`.

### `env_instantiate(σ, level) : (TypeId, ℕ) → TypeId`
Fresh-instantiate a polytype's outer binders with new unification vars at the given level. Distinct from skolemization. `env.lua:547`.

### `skolemize(σ) : TypeId → (TypeId, [TVId])`
Introduce per-quantifier skolem TVs for `σ`'s outer binders; returns the body and the skolem list. Skolems have `FLAG_SKOLEM` set; `bind` on them is a terminal error per invariant 6. Sites: `env.skolemize_return_for_rank_n` (`env.lua:631`), `constrain.skolemize_fn` (`constrain.lua:2048`).

### `subsume(σ_actual, σ_expected) : (TypeId, TypeId) → (ok, err?)`
Polytype-vs-polytype subsumption (rank-N). Enumerates four cases per the
canonical rule in `docs/typechecker-rank-n.md`:

1. **Both `TAG_FORALL`**: deep-skolemize `σ_expected` to get `(ρ_e, skolems)`;
   fresh-instantiate `σ_actual` via `env_instantiate` to get `ρ_a`; recurse
   on `subsume(ρ_a, ρ_e)`. The skolems must not escape (enforce via
   `escape_check`).
2. **RHS-only `TAG_FORALL`** (`σ_expected` is `∀a. τ`): deep-skolemize
   `σ_expected` to get `(τ, skolems)`; recurse on `subsume(σ_actual, τ)`.
3. **LHS-only `TAG_FORALL`** (`σ_actual` is `∀a. τ`): fresh-instantiate
   `σ_actual` via `env_instantiate` to get `τ'`; recurse on
   `subsume(τ', σ_expected)`.
4. **Neither `TAG_FORALL`**: structural fallback — `unify(σ_actual,
   σ_expected)` (the rule degenerates to monotype unification).

Cases 1–3 escape-check the introduced skolems against the call-site outer
bindings before retiring (per §3 C_ESCAPE_CHECK semantics).

The four-case enumeration is a semantic-preserving expansion of `docs/typechecker-rank-n.md`'s three-case form: rank-n.md fuses cases 1+2 (both-forall) into a single composed rule; this spec splits them for handler clarity. Soundness is equivalent.

### `eval_match_type(tid) : TypeId → TypeId`
Type-level evaluation of `TAG_MATCH_TYPE` (conditional types). Delegates to env/match.lua. Used by C_BOUND.

### `propagate_function_bound(v, fn_shape) : (TVId, FnShape) → ()`
Specialises a function-shape inferred bound through to the TV's eventual
binding. 53-line operation at `solve.lua:1119`. Used by C_BOUND when the
bound's representation is a function type.

### `propagate_meta_bound(v, meta_shape) : (TVId, MetaShape) → ()`
Specialises a metamethod-shape inferred bound. 168-line operation at
`solve.lua:950`. Used by C_BOUND when the bound is a metamethod
requirement (e.g. arithmetic operand inference).

### `dispatch_param(actual, formal) : (TypeId, TypeId) → ()`
Per-parameter dispatcher used by C_CALL_FUNCTION's TAG_FUNCTION branch
and C_CHECK_ARGS: if `find(formal)` or `find(actual)` is `TAG_FORALL`,
invoke `subsume(actual, formal)`; otherwise `unify(actual, formal)`.
Returns nothing; failures propagate as the called primitive's failure.
This is the explicit rank-N vs monomorphic discriminator.

### `callable_shape(args, ret) : ([TypeId], TVId) → InferredBound`
Constructs a function-shape inferred bound from a list of argument
TypeIds and a return TVId. Used by C_INFER_CALLABLE_BOUND to construct
the bound passed to `merge_inferred_bound`. The construction is a record
literal of the form `{ kind = "callable", params = args, ret = ret }`;
no freshening, no wrapping in `TAG_FUNCTION`. The resulting bound is
matched against `v`'s eventual binding when `v` resolves through
sub-solve.

### `check_kind_arity(v, expected_arity) : (TVId, ℕ) → (ok, err?)`
Verifies that a TV's bound matches the expected type-constructor arity
(for HKT-style bounds). Inline in `solve_bound`; named here for spec
closure.

### `substitute(template, params, args) : (TypeId, [TVId], [TypeId]) → TypeId`
Type-level capture-avoiding substitution: replaces each `params[i]` with
`args[i]` throughout `template`. Used by C_HKT_DECOMPOSE to construct
the unification template from a `bound_alias` body. Implementation in
`env_mod`.

### `overlap_check(a, b) : (TypeId, TypeId) → bool`
Bidirectional overlap test: returns true iff `is_subtype(a, b) ∨
is_subtype(b, a)`. Used by C_OVERLAP and C_COMPARE. Not the same as
`unify` — it never binds.

### `instantiate_at_use(callee, args, ret) : (TypeId, [TypeId], TVId) → ()`
Composite primitive — calls `env_instantiate` for the LHS forall (fresh unification vars), `skolemize` for any RHS forall introduced by rank-N param positions, emits HKT decomposition children for `TAG_TYPE_CALL` param slots, then emits `C_BIND_GENERICS` and `C_CHECK_ARGS` against the freshened callee. Composes the simpler primitives above; named separately because the composition is the call-site instantiation contract from `docs/typechecker-solver-fundamentals.md` fundamental 6. **Status:** the spec describes the target composition. The current handler at `solve.lua:2809` is a 10-line stub that only calls `claim(ret, c)`. Phase 3 implements the full composition by routing through the three split rules above (C_CALL_FUNCTION's TAG_FUNCTION branch, plus the inline `env_instantiate` + `skolemize` calls), retiring the C_INSTANTIATE_AT_CALL routing kind once the split lands.

### `try_each(candidates, attempt, on_all_fail) : ([Cand], Cand → bool, () → ()) → ()`
**Search primitive** — see §6. Iterates candidates left-to-right; each
`attempt` is run under `try_unify` (read-only), the first that returns true
is committed via `bind` / `unify`. On exhaustion `on_all_fail` runs (emits
diagnostic + binds the result TV to `T_ANY`). Not expressible as `emit`
alone — see §6 for the falsification.

### `resume_iter(c, i) : (Constraint, ℕ) → ()`
**Mid-loop deferral primitive.** Yields control mid-iteration with iteration
counter implicit at zero (re-runs from iteration 0 on resume, relying on
`try_unify` to no-op already-bound params). The handler returns
`{ solved = false }` and the dispatcher's re-seed picks it up. Already
implicit in `solve_callable` (line 2312) and `solve_bind_generics` (2891) —
the spec gives it a name; see §7.

### Discipline primitives (not rule-callable)

### `release(v) : (TVId) → ()`
`solve.lua:142`. Called only at the bind chokepoint (invariant 2). Not callable from rules.

## 3. Constraint kinds and rule schemas

One rule per kind. Constrain.lua:127-183 today emits 16 kinds including C_CALLABLE; the spec retires C_CALLABLE and adds C_CALL_FUNCTION / C_RESOLVE_OVERLOAD / C_INFER_CALLABLE_BOUND / C_DISTRIBUTE_OVER_UNION, for 19 rules total in §3. Schema:

```
RULE C_<KIND>(payload)
  premises  : <read effects on Σ>
  conclusion: <write effects via §2 primitives>
  side cond : <tier/ownership preconditions>
```

`v = find(x)` is used implicitly throughout.

### RULE C_UNIFY {t1, t2, line, col}
- **conclusion.** `unify(find(t1), find(t2))` then `retire`. On failure,
  `fail(c, "type mismatch …")`.
- **side cond.** none.
- **handler.** `solve_unify` (`solve.lua:596`).

### RULE C_SUB {actual, expected, line, col, is_cast}
- **premises.** If `actual` is `Unbound v` and `is_owned(v)`, `park(c, v)`.
- **conclusion.**
  - If `actual` or `expected` is `TAG_FORALL`: `subsume(actual, expected)`; `retire` (terminal whether ok or error).
  - Else: first try `try_unify_strict(actual, expected)` fast path; on `true`, `retire`. Else `unify(widen(actual, SUB), expected)` and `retire`.
- **side cond.** Closed-table expected forces the slow path.
- **handler.** `solve_sub` (`solve.lua:613`).

### RULE C_INDEX {obj, key, result, line, col}
- **premises.** If `obj` is `Unbound v`: if `is_owned(v)` or otherwise not
  yet shaped, `park(c, v)`. If `result` is `Unbound v` and `is_owned(v)` and
  the index would commit eagerly, `park(c, result)`.
- **conclusion.** `unify(result, project(obj, key))` (the `project` primitive dispatches on `obj.tag` per its §2 definition), `retire`. Failures
  `fail`.
- **handler.** `solve_index` (`solve.lua:1457`).

### RULE C_CALL_FUNCTION {callee, args, ret, line, col}
- **premises.** `claim(ret, c)`. If `find(callee)` is `Unbound v`,
  `park(c, v)` (was a silent T_ANY bind bug at `solve.lua:2157+` in the
  pre-split handler). If `find(callee).tag == TAG_INTERSECTION`,
  TAG_UNION, or `TAG_VAR` with `FLAG_SUB_SOLVE_PARAM`, this rule is the
  wrong kind — emission site should have routed to C_RESOLVE_OVERLOAD,
  C_DISTRIBUTE_OVER_UNION, or C_INFER_CALLABLE_BOUND respectively;
  `fail(c, "internal: wrong constraint kind for callee tag")`.
- **conclusion.** Per `find(callee).tag`:
  - `TAG_FUNCTION` → `instantiate_at_use(callee, args, ret)` if callee
    was a free TV at gen time; iterate params, calling
    `dispatch_param(actual_i, formal_i)` per pair. If a bind set
    `_bind_woke_given`, `resume_iter(c, _)`.
    Otherwise `unify(ret, first_ret)` and `retire`.
  - `TAG_NOMINAL` → unwrap to the representation type; recursively
    dispatch this rule on the unwrapped form (one level of normalization,
    same as `find()` for type-level aliases).
  - `TAG_ANY` → `bind(ret, T_ANY)`, `retire`.
  - `TAG_UNKNOWN` → `fail(c, "call on unknown")`.
  - `TAG_NEVER` → `bind(ret, T_NEVER)`, `retire`.
  - Anything else → `fail(c, "not callable")`.
- **side cond.** ownership owed on every terminal path.
- **handler.** `solve_call_function` (Phase 3; replaces the TAG_FUNCTION /
  nominal / lattice / error branches of `solve_callable` at `solve.lua:2123`).

### RULE C_RESOLVE_OVERLOAD {callee, args, ret, line, col}
- **premises.** `claim(ret, c)`. `find(callee)` must be `TAG_INTERSECTION`
  (else internal-error `fail`).
- **conclusion.** `try_each(members, attempt, fail)`, where `members` is
  `find(callee).members` (each a `TAG_FUNCTION`),
  `attempt(m) := try_unify_strict_args(args, m.params)` (returns true iff
  every argument unifies with the corresponding member parameter without
  binding), and `fail` is the exhaustion handler that emits a
  multi-candidate diagnostic citing all member signatures and calls
  `bind(ret, T_ANY)`. On `attempt`'s first true, the chosen member
  commits via `bind(ret, chosen.ret)`. `retire` in both cases.
- **side cond.** ownership owed.
- **handler.** `solve_resolve_overload` (Phase 3; replaces the
  TAG_INTERSECTION branch of `solve_callable` at `solve.lua:2377+`).

### RULE C_INFER_CALLABLE_BOUND {callee, args, ret, line, col}
- **premises.** `find(callee)` must be `Unbound v` with
  `FLAG_SUB_SOLVE_PARAM` set (else internal-error `fail`; see invariant 7).
- **conclusion.** `merge_inferred_bound(v, callable_shape(args, ret))`,
  `retire`. The callable-shape bound is recorded on `v` so that when `v`
  later binds via sub-solve, the inferred callable signature constrains
  the binding. `ret` is bound transitively when `v` binds and the
  callable shape's return slot resolves.
- **side cond.** emits no direct `ret` binding; ownership convention is
  that `claim(ret, c)` is NOT taken here because the binding is deferred
  to sub-solve completion.
- **handler.** `solve_infer_callable_bound` (Phase 3; replaces the
  TAG_VAR-with-FLAG_SUB_SOLVE_PARAM branch of `solve_callable` at
  `solve.lua:2163+`).

### RULE C_ARITH {op, lhs, rhs, result, line, col}
- **premises.** If either operand is `Unbound v` of a sub-solve param,
  emit metamethod-shape bound (`merge_inferred_bound`) and retire. Else if
  operand still `Unbound`, `defer(c)`.
- **conclusion.** Look up `__<op>` via `meta_op_ret`, `unify(result,
  ret_ty)`, `retire`.
- **handler.** `solve_arith` (`solve.lua:2507`).

### RULE C_RETURN {val, expected, line, col}
- **conclusion.** `unify(val, expected)` with multi-return tuple flattening,
  `retire`.
- **handler.** `solve_return` (`solve.lua:2724`).

### RULE C_COMPARE {lhs, rhs, line, col}
- **conclusion.** Invoke `meta_op_ret(op, lhs)` and `meta_op_ret(op, rhs)`; require either `is_subtype(lhs, rhs) ∨ is_subtype(rhs, lhs)` via `overlap_check` (§2). On disjoint, emit diagnostic; `retire`.
- **handler.** `solve_compare` (`solve.lua:2599`).

### RULE C_BOUND {fresh_tv, bound, line, col}  (tier: GIVEN at emit)
- **premises.** If `find(fresh_tv)` is `Unbound`, `park(c, fresh_tv)`. If
  the resolved bound itself contains a free TV, `park(c, bound)`.
- **conclusion.** Per bound shape:
  - function shape → `propagate_function_bound(v, bound)`, `retire`.
  - metamethod shape → `propagate_meta_bound(v, bound)`, `retire`. **(Phase 3.** `propagate_meta_bound` exists as a primitive at `solve.lua:950` but `solve_bound` does not currently dispatch to it; metamethod-shape bounds are inferred elsewhere today. Phase 3 lands the dispatch here so C_BOUND owns all bound-shape propagation.)
  - kind-arity bound → `check_kind_arity(v, arity)`; on mismatch `fail`,
    else `retire`.
  - `TAG_MATCH_TYPE` bound → `eval_match_type(bound)` and `unify(v,
    evaluated)`, `retire`.
- **side cond.** Emitted as GIVEN so back-propagation runs before any wanted
  binds the same TVs (fundamental 4).
- **handler.** `solve_bound` (`solve.lua:1182`).

### RULE C_OR {left, right, result, line, col}
- **premises.** If `find(left)` is `Unbound`, `defer(c)`.
- **conclusion.** `unify(result, subtract(left, nil|false) ∪ right)`,
  `retire`.
- **handler.** `solve_or` (`solve.lua:846`).

### RULE C_BIND_GENERICS {callee, args, ret, line, col}
- **premises.** `find(callee)` must be `TAG_FUNCTION` (else `retire` no-op).
- **conclusion.** For each free-TV param slot, `unify(widen(arg_i),
  param_i)`. If `_bind_woke_given` becomes true, `resume_iter(c, _)`.
  Else `retire`.
- **handler.** `solve_bind_generics` (`solve.lua:2834`).

### RULE C_CHECK_ARGS {callee, args, ret, line, col}
- **premises.** `claim(ret, c)`. If any param slot is still `Unbound`,
  `defer(c)`. If callee is a sub-solve param TV, emit
  `merge_inferred_bound` and retire.
- **conclusion.** Per-param `dispatch_param(actual_i, formal_i)`, then `unify(ret, first_ret)`. On
  arg-count mismatch / per-arg failure, `fail(c, …)` (terminal).
- **handler.** `solve_check_args` (`solve.lua:2906`).

### RULE C_OVERLAP {actual, expected, line, col}
- **conclusion.** Bidirectional check: succeed iff `is_subtype(actual,
  expected) ∨ is_subtype(expected, actual)`. On failure `fail`. `retire`
  either way.
- **handler.** `solve_overlap` (`solve.lua:3253`).

### RULE C_NARROW_NIL {input, result, keep_nil, line, col}
- **premises.** If `find(input)` is `Unbound v`, `park(c, v)`.
- **conclusion.** Compute the keep-nil or drop-nil subset, `unify(result,
  computed)`, `retire`.
- **handler.** `solve_narrow_nil` (`solve.lua:748`).

### RULE C_ESCAPE_CHECK {ret, call_id, line, col}
- **premises.** If `find(ret)` is a non-skolem `Unbound v`, `defer(c)`.
- **conclusion.** Invoke `escape_check(ret, call_id)`. The primitive walks
  TVs reachable from BOTH (a) `find(ret)` AND (b) the call frame's outer
  bindings (i.e. any `Env` entry whose value is bound at a scope outside
  the call). If any reachable TV bears the matching `call_id` skolem
  mark, `fail`. Else `retire`.
- **handler.** `solve_escape_check` (`solve.lua:799`). Note: today's
  handler walks (a) only; covering (b) per `docs/typechecker-rank-n.md`
  is a Phase-3 reconciliation item (see §11 Gap D below).

### RULE C_HKT_DECOMPOSE {f_fresh, args_fresh, bound_alias, actual_arg, line, col}
- **conclusion.** Let `template = substitute(bound_alias.body,
  bound_alias.params, args_fresh)`. Invoke `unify(template, actual_arg)`;
  successful unification binds the entries of `args_fresh` to the
  recovered arguments as a side effect of `unify` reaching their leaf
  positions. `bind(f_fresh, bound_alias)` records the recovered head.
  `retire` always (failure produces a diagnostic but does not block the
  rest of the worklist).
- **handler.** `solve_hkt_decompose` (`solve.lua:3852`, impl at 3771).

### RULE C_INSTANTIATE_AT_CALL {callee, args, ret, line, col}
- **premises.** `claim(ret, c)`.
- **conclusion.** Invoke the `instantiate_at_use(callee, args, ret)`
  primitive (§2), which emits `C_BIND_GENERICS(callee', args, ret)` and
  `C_CHECK_ARGS(callee', args, ret)` plus any `C_HKT_DECOMPOSE` /
  `C_ESCAPE_CHECK` children. `retire`.
- **note.** Today's handler is a stub (`solve.lua:2809`); the rule is the
  target. Phase 3 implements it.

### RULE C_DISTRIBUTE_OVER_UNION {underlying_kind, payload, ret, line, col}
**New kind** (per audit shape 4). The spec promotes union-callable
distribution into its own kind; `solve_callable` / `solve_check_args` lose
their inline `TAG_UNION` branches.

- **premises.** Let `U = payload.union_operand`. For each member `m_i`,
  emit a child constraint of `underlying_kind` with operand replaced by
  `m_i` and a fresh `member_ret_i`. `claim(ret, c)`. `park(c, member_ret_*)`
  (multi-TV park; re-run on each wake).
- **conclusion.** When all `member_ret_i` are bound, `bind(ret, ∪ {
  member_ret_i })`; on any child `fail`, this rule `fail`s once. `retire`.
- **handler.** Not yet implemented in `solve.lua`. Phase 3.

## 4. Tier discipline

Tier is a side condition on transition selection, not a separate solver
phase. `_tier ∈ {GIVEN=0, WANTED=1}` is set at emit time (default WANTED
inherited from parent; `solve.lua:4007`). Constraints with tier GIVEN are
not given a privileged queue; instead, the chokepoint enforces the
contract:

> When a WANTED bind would write to a TV that has a GIVEN waiter parked on
> it, the WANTED handler defers its remaining work so the GIVEN can run
> first.

Mechanism: `wake_waiters` sets `ctx._bind_woke_given = true` when the
in-flight bind is WANTED and a waiter is GIVEN (`unify.lua:232-240`).
Handlers consult the flag at safe yield points (`solve.lua:2312, 2891`)
and `resume_iter`. The chokepoint's atomicity guarantees the flag is
observed before any further wanted iteration runs.

The legacy `solve2.simplify` saturation loop over `impl.givens` then
`impl.wanteds` (`solve2.lua:191-229`) is a separate, defunct implementation
of the same contract. The spec collapses it: the single worklist plus the
woke-given flag is sufficient. See §10.

**Vocabulary note.** The names `GIVEN`/`WANTED` are inherited from OutsideIn/X but the semantics here are not OutsideIn's. In OutsideIn, "given" means a locally-true axiom inside an implication scope; "wanted" means a goal to prove. In crescent, both are priority annotations on constraints — `GIVEN` = "user-declared bound, runs first," `WANTED` = "inferred, defers to GIVEN when they race the same TV." There is no implication scope. The names are kept to minimize code churn; the meanings are crescent's. A future code rename to `DECLARED`/`INFERRED` would improve clarity.

## 5. Unify (synchronous relation)

`unify : (Σ, TypeId, TypeId) → (ok, err?, Σ')` is a **primitive**, not a
constraint. The audit (shape 2 verdict, fundamental on current type algebra)
records that decomposing it into emitted children breaks the seen-set, the
all-or-nothing failure contract, and the `_bind_woke_given` window
(`docs/typechecker-handler-shape-audit.md:74-107`). The spec adopts this
verdict.

### Signature
- Inputs: `ctx`, `a : TypeId`, `b : TypeId`, optional `seen : TypePairSet`.
- Output: `(ok : bool, err : string?, detail?)`.
- Side effects: invokes `bind` at any TV leaf; otherwise pure read on `T`.

### Recursion shape (coinductive)
A `seen : { TypeId × TypeId → bool }` set is threaded through every
structural step (`unify.lua:325-333, 363+`). On re-entry of a pair already
in `seen`, returns `true` without descending — the cycle closes
coinductively. Required for equi-recursive table types.

This shape is intentionally non-paradigmatic (it does not fit the worklist
emit/park/retire vocabulary). The spec acknowledges it as a primitive
acting on `Σ` rather than as a constraint, so handlers can invoke it
synchronously.

### Relation to §2's `bind`
Every TV-leaf case in `unify` calls `bind_var_to_type` (the chokepoint).
The wake-waiters effect therefore fires during a top-level handler's
synchronous unify call. Handlers that need to react to woke-givens during
their own body check `ctx._bind_woke_given` at safe yield points; the spec
forbids checking it between unrelated atomic steps (it is reset by the
dispatcher only at top-of-handler).

## 6. Backtracking (overload resolution)

`try_each` is a search primitive on `Σ` with read-only candidate probes and a single commit. It is **not** a constraint; the worklist solver is single-state and has no rollback by design. In bidirectional / local type inference (the paradigm crescent serves per §0), in-handler search with read-only probes is the *recommended* shape for overload resolution — not a fallback for missing machinery. The audit's "fundamental" verdict on shape 3 records this. Emit-only cannot model `try_each` because:

- A disjunctive constraint `C_TRY_ANY(c1, c2, …)` either serialises (which
  is what `try_each` does, in-handler) or genuinely forks `Σ`. Forking is
  incompatible with the quiescence-on-one-state termination contract.
- Aggregating N tentative outcomes back to one ret type is the same problem
  as union-callable distribution but with the additional requirement that
  only one branch's binds survive — which the worklist has no mechanism
  for.

### Semantics of `try_each(candidates, attempt, on_fail)`
Let candidates be ordered. For each candidate `m`:
- Run `attempt(m)` under `try_unify` (`unify.lua:1075`): reads `T` but never
  binds.
- If `attempt(m)` returns `true`, **commit**: call the user-supplied commit
  hook (typically `bind(ret, m.first_ret)`), `retire(c)`.

On exhaustion, `on_fail()` runs (emit diagnostic + `bind(ret, T_ANY)`,
`retire(c)`).

### Checkpoint scope (none, by construction)
`try_each` never enters the slow-path `unify` until commit; therefore no TV
bind is rolled back. `Bindings` (`B`), waiters (`R`), owners (`O`),
worklist (`W`), and diagnostics (`E`) all see exactly the effects of the
chosen candidate plus the read-only probe budget.

## 7. Mid-loop deferral (`resume_iter`)

`resume_iter(c, _)` captures the audit's shape 5b. A handler that has
already committed binds via `bind` on prior iterations may, mid-loop,
return `{ solved = false }` to defer.

### Committed effects at park time
When `resume_iter` is invoked at iteration `i > 0`:
- Binds 0..i-1 have already gone through the chokepoint (`G`, `R`, `O`
  updates are permanent).
- `claim(ret, c)` on entry is still in effect — `O[ret] = c`.
- `_bind_woke_given` was set by the chokepoint during iteration `i`'s
  unify, which is what triggered the deferral.

### Resume contract
On re-run (after a TV bind elsewhere re-seeds the worklist, or after a
parked GIVEN waiter fires):
- The handler re-iterates from iteration 0.
- Each prior `unify` is now a no-op fast-path because the param TVs are
  already bound (`try_unify` returns true; `solve.lua:2225-2235`).
- Idempotency depends on the per-loop param identity being preserved
  across re-runs (same `callee_t`, same `arg_tids`), which the constraint
  payload guarantees.

This is the explicit, named mid-iteration deferral primitive the audit
identified as fundamental.

## 8. Quiescence

The solver returns when, for the current slice:

1. `W` is empty (the FIFO drain completed).
2. The round completed with `solved_this_round = false` AND
   `G_after = G_before`.

These two conditions together mean: no constraint retired and no TV bound
during the most recent round. Any remaining constraint with
`c._deferred = true` is parked on a TV in `R`; since no bind occurred this
round, no parked constraint could have been re-enqueued. The fixed point
is `Σ`.

### Success vs error termination
- **Success.** `E` is empty AND every `c` is `_solved`. The function
  returns with all type variables resolved (subject to `T_ANY` fallbacks
  at error sites).
- **Error.** `E` is non-empty. The solver still runs to quiescence so all
  independent errors surface in one pass. Each `fail` is terminal
  (invariant 5), so error count = number of distinct failed terminal
  transitions.
- **Deadlock-as-success.** A parked constraint at quiescence is treated as
  no-op: the awaited TV never bound, but no rule could have produced
  progress, so the constraint imposes no further obligation. (Skolems
  legitimately leave their TVs free at function exit; sub-solve picks them
  up later.) `solve.lua:4045-4053`.

## 9. Mapping table: handler ↔ rule

| Handler                       | File line          | Rule (§3)                  |
|-------------------------------|--------------------|----------------------------|
| `solve_unify`                 | solve.lua:596      | C_UNIFY                    |
| `solve_sub`                   | solve.lua:613      | C_SUB                      |
| `solve_index`                 | solve.lua:1457     | C_INDEX                    |
| `solve_call_function`         | *(Phase 3; today's branches of `solve_callable` at solve.lua:2123)* | C_CALL_FUNCTION            |
| `solve_resolve_overload`      | *(Phase 3; today's branches of `solve_callable` at solve.lua:2123)* | C_RESOLVE_OVERLOAD         |
| `solve_infer_callable_bound`  | *(Phase 3; today's branches of `solve_callable` at solve.lua:2123)* | C_INFER_CALLABLE_BOUND     |
| `solve_arith`                 | solve.lua:2507     | C_ARITH                    |
| `solve_compare`               | solve.lua:2599     | C_COMPARE                  |
| `solve_return`                | solve.lua:2724     | C_RETURN                   |
| `solve_bound`                 | solve.lua:1182     | C_BOUND                    |
| `solve_or`                    | solve.lua:846      | C_OR                       |
| `solve_bind_generics`         | solve.lua:2834     | C_BIND_GENERICS            |
| `solve_check_args`            | solve.lua:2906     | C_CHECK_ARGS *(+ delegates to C_DISTRIBUTE_OVER_UNION on TAG_UNION; Phase 3)* |
| `solve_overlap`               | solve.lua:3253     | C_OVERLAP                  |
| `solve_narrow_nil`            | solve.lua:748      | C_NARROW_NIL               |
| `solve_escape_check`          | solve.lua:799      | C_ESCAPE_CHECK             |
| `solve_hkt_decompose`         | solve.lua:3852     | C_HKT_DECOMPOSE            |
| `solve_instantiate_at_call`   | solve.lua:2809     | C_INSTANTIATE_AT_CALL *(stub today; spec calls `instantiate_at_use`)* |
| *(not yet implemented)*       | —                  | C_DISTRIBUTE_OVER_UNION    |

16 existing handlers in solve.lua's dispatch table. Spec defines 19 rules (the 16 existing + C_DISTRIBUTE_OVER_UNION + C_CALL_FUNCTION + C_RESOLVE_OVERLOAD + C_INFER_CALLABLE_BOUND minus the retired C_CALLABLE). Phase 3 splits `solve_callable` into three handlers per the new rules; C_CALLABLE constraint emission is removed in favour of emitting the specific kind based on callee tag at constraint-generation time.

## 10. solve2.lua disposition

**Verdict: collapse `solve2.lua` back into `solve.lua`.**

**Caveat.** The collapse argument assumes equivalence between solve2's `dispatch_one` → `simplify` → `wake_ctx` path and the legacy `ctx._worklist` + outer `solve_range` re-seed path, under the *expanded* `PORTED` set that now includes parking kinds (`solve2.lua:356-359`: C_CALLABLE/C_CHECK_ARGS/C_INSTANTIATE_AT_CALL/C_BIND_GENERICS). Equivalence is plausible by inspection but not proved here. Phase 3 must verify on at least one CALLABLE/CHECK_ARGS workload (the rank-N test fixture is sufficient) before deleting the solve2 path. Until verified, treat §10 as a directional verdict, not a guarantee.

Reasoning grounded in the spec:

- The Implication/Wanted vocabulary (`solve2.lua:65-107`) duplicates what
  this spec already encodes in `Σ`: an implication frame is the
  `(skolems, givens, wanteds)` triple, but the spec's tier discipline
  (§4) is enforced by the single worklist plus `_bind_woke_given` — no
  separate `givens` saturation loop is required.
- `simplify`'s givens-first loop (`solve2.lua:191-205`) is dead weight in
  P1: nothing populates `impl.givens` because the spec doesn't need that
  segregation. The audit confirms tier discipline already lives at the
  chokepoint (`docs/typechecker-handler-shape-audit.md:271-289`).
- `dispatch_one` (`solve2.lua:311`) wraps every ported kind in a fresh
  implication, runs `simplify`, and returns. Since ported kinds (per
  `PORTED`) all emit only into the same `impl.wanteds`, this is a
  per-constraint cost equivalent to one extra function call layer over
  the legacy handler.
- `wake_ctx` (`solve2.lua:268`) is co-resident with `wake_waiters` at
  the chokepoint. With Implication collapsed, the single `wake_waiters`
  in `unify.lua:225` is sufficient.

Phase 3 therefore: delete `solve2.lua`, delete `M.solve2_*` references in
`solve.lua` and `unify.lua`, remove the `solve2.PORTED` predicate from
`solve_range.run_one`. The existing per-kind dispatch table
(`solve.lua:3871`) is the spec implementation.

## 11. Known gaps and adversarial notes

Items tagged BLOCKER prevent Phase 3 from starting. Items tagged NON-BLOCKER are documented gaps that do not gate Phase 3.

### Gap A: `C_DISTRIBUTE_OVER_UNION` aggregation contract

The audit (shape 4) prescribes the new kind and a multi-TV await. The
current `await` (`solve.lua:93`) takes one TV; aggregation requires
`await` to fire whenever any of N TVs binds, with re-check semantics.

Adversarial pass: could the rule be expressed using N separate single-TV
`park` calls per re-run? Yes — the handler re-runs on each wake; each
re-run checks "are all member_ret_i bound yet?" and parks again on the
first still-unbound. This is correct but quadratic in member count for
deep unions. The spec accepts this cost; if Phase 3 measures it as a
problem, a multi-TV await variant is a pure extension (no semantic
change). Tagged **NON-BLOCKER**: the iterated single-TV `park` approach is correct (handler re-runs on each wake, parks on first remaining unbound member_ret). Quadratic cost is the implementation tradeoff. Multi-TV await is a pure extension if measured as a problem. Caveat: in the iterated form, between handler re-runs two member_rets binding in the same dispatcher pass do not double-wake — the second bind hits an already-unparked constraint that will re-evaluate on next round. Verify on the first C_DISTRIBUTE_OVER_UNION test before relying on this.

### Gap B: `instantiate_at_use` and the producer/consumer ordering

Fundamental 6 names the primitive. The Phase F blocker
(`docs/typechecker-phase-f-blocker.md`) showed that simply moving the
gen-time C1-C9 emission into the solver broke implicit ordering
invariants — cross-statement `C_SUB(call_ret_TV, ann_T)` raced the
deferred children.

The spec's resolution: `C_INSTANTIATE_AT_CALL` calls `claim(ret, c)` on
entry (§3 rule, line in solve.lua:2817 already), and the children it
emits are tier-WANTED with the chokepoint enforcing release at their
terminal binds. The cross-statement C_SUB rule (§3 C_SUB premise)
explicitly parks on owned ret_TVs. The ordering is therefore preserved
by construction.

Adversarial pass: could a child `C_BIND_GENERICS` retire (via the
tier discipline's woke-given deferral) without ever binding the ret_TV?
Yes — if the function has no return-binding step (e.g. callee is
`TAG_NEVER`). In that case `C_CHECK_ARGS` still runs to terminal and
`bind(ret, _)` happens on its terminal-success path (every branch of
`solve_check_args` for TAG_FUNCTION/TAG_NEVER ends in
`bind_to(ret_tid, _)`). So the ownership is released on every terminal
path. Tagged **NON-BLOCKER for cross-statement C_SUB ordering**: every TAG_FUNCTION/TAG_NEVER terminal-success branch of `solve_check_args` calls `bind_to(ret_tid, _)` (verified at `solve.lua:2918-2931`). Caveat: defer-branch paths (`solve.lua:2953-2956`, `solve.lua:2972-2977`) leave `O[ret_tid] = c` indefinitely if the callee TV never resolves. Per §8 deadlock-as-success this is intended behaviour, but the ownership is released only on terminal-*success* paths, not all terminal paths. This gap addresses ordering only.

### Gap C: H2 record-of-generics dispatch (BLOCKER)

*Relation to Gap B.* Gap B addresses the *general* producer/consumer ordering invariant (cross-statement `C_SUB(call_ret_TV, ann)` parks on the owned ret_TV until the producer terminal-succeeds). Gap C addresses the *specific motivating workload* — H2 record-of-generics — that requires dispatch through a polytype field accessed via `TAG_INDEX`. Resolving Gap B alone does not resolve H2; the dispatch step itself must extend to park-on-callee.

The actual Phase F blocker per `docs/typechecker-phase-f-blocker.md` and `docs/typechecker-solver-fundamentals.md` §6 is the pattern `record.field(x)` where `record.field` resolves to a polytype field `<T>(T) → T`. Instantiation must happen when the field-read resolves, not at parse time, because the callee is a free TV at gen time. Test pins in `lib/type/static/type_soundness_test.lua` lines ~3875-3990 (H2, H2a, H2b, H2e) currently assert `has_error("Maybe%(_%)")` — that is the regression-pin protecting against incorrect dispatch.

Spec gap: `C_INSTANTIATE_AT_CALL` and `C_CALL_FUNCTION` premises do not cover the case where `find(callee)` is `Unbound` but will resolve to a `TAG_FORALL` via a TAG_INDEX projection on a polytype-bearing record (C_CALL_FUNCTION's premise parks on Unbound callee, but does not chain through TAG_INDEX resolution that yields a polytype). The current spec only addresses cross-statement ordering (Gap B). H2 is a different problem.

Tagged **BLOCKER**: Phase 3 cannot land H2 dispatch until either (a) the spec extends `C_INSTANTIATE_AT_CALL` to park-on-callee when callee is Unbound and re-dispatch through `instantiate_at_use` on resolution, OR (b) H2 is explicitly documented as a known-bad case with the test pins preserved as the regression boundary.

### Gap D: C_ESCAPE_CHECK covers only one reachability root (NON-BLOCKER)

`docs/typechecker-rank-n.md` §"The escape check" specifies walking both
(a) the inferred return type and (b) any outer binding's type for skolems
at the call-site level. `solve.lua:799`'s implementation today walks
(a) only. Test pins N7 (forall-in-return) and N8 (rank-3 nested) currently
pass because the test fixtures don't exercise leakage through outer
bindings.

Tagged **NON-BLOCKER**: the spec rule (§3 C_ESCAPE_CHECK, post-Round-2)
prescribes both walks; Phase 3 reconciles the handler. Until then, a
test that captures a skolem in a closure variable and returns the
closure could leak. Add such a test in Phase 3 to demonstrate the gap
before reconciliation, then fix the handler to match the spec.

### Net §11 verdict

Gap C is a BLOCKER; Phase 3 cannot start until it is resolved (either by extending C_INSTANTIATE_AT_CALL to cover H2 record-of-generics, or by explicitly documenting H2 as a pinned known-bad case).
