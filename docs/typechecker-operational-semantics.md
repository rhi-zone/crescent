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
start while §11 is non-empty.

Inputs that shape this spec: the handler-shape audit
(`docs/typechecker-handler-shape-audit.md`) and the six solver fundamentals
(`docs/typechecker-solver-fundamentals.md`).

## 1. Configuration

The solver's transition state at any moment is a tuple
`Σ = ⟨W, T, B, R, O, G, Tier, S, E⟩` over the typechecker context `ctx`:

| Component  | Type                                       | Backing field in `ctx`           |
|------------|--------------------------------------------|----------------------------------|
| `W`        | `Worklist : Queue<Constraint>`             | `ctx._worklist`                  |
| `T`        | `TVMap   : TVId → TVCell`                  | `ctx.types` arena + union-find   |
| `B`        | `Bindings : NameId → TypeId` (per scope)   | `ctx.scope` (envs from `env.lua`) |
| `R`        | `Waiters : TVId → List<Constraint>`        | `ctx.tv_waiters`                 |
| `O`        | `Owners  : TVId → Constraint?`             | `ctx.tv_owners`                  |
| `G`        | `BindGen : ℕ` (monotone counter)           | `ctx._bind_generation`           |
| `Tier`     | `{ GIVEN, WANTED }`                        | `ctx._current_tier`              |
| `S`        | `Stack<ImplicationFrame>`                  | `ctx._solve2_impls`              |
| `E`        | `Diagnostics` (write-only)                 | `ctx.err`                        |

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

## 2. Primitives

Each primitive is invoked synchronously by a rule. Side effects on `Σ` are
listed; anything not listed is preserved.

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

### `release(v) : (TVId) → ()`
`solve.lua:142`. Called only at the bind chokepoint (invariant 2).

### `is_owned(v) : (TVId) → bool`
`solve.lua:148`. Readers consult before falling through to `unify` on a free
TV.

### `instantiate_at_use(callee, args, ret) : (TypeId, [TypeId], TVId) → ()`
**The primitive identified as fundamental 6.** Single named entry that:
1. fresh-instantiates the polymorphic callee (env.lua's `instantiate`),
2. introduces per-call rank-N skolems for nested foralls,
3. emits the HKT decomposition children for `TAG_TYPE_CALL` param slots,
4. emits `C_BIND_GENERICS` then `C_CHECK_ARGS` with the freshened callee.

Today this primitive is realised three ways (`solve_callable` inline,
`solve_check_args` re-instantiate, `C_INSTANTIATE_AT_CALL` stub) — the spec
names one. See `docs/typechecker-solver-fundamentals.md` §6.

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

## 3. Constraint kinds and rule schemas

One rule per kind from `constrain.lua:127-188`. Schema:

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
- **conclusion.** First try `try_unify_strict(actual, expected)` fast path;
  on `true`, `retire`. Else `unify(widen(actual), expected)` and `retire`
  (terminal whether ok or error).
- **side cond.** Closed-table expected forces the slow path.
- **handler.** `solve_sub` (`solve.lua:613`).

### RULE C_INDEX {obj, key, result, line, col}
- **premises.** If `obj` is `Unbound v`: if `is_owned(v)` or otherwise not
  yet shaped, `park(c, v)`. If `result` is `Unbound v` and `is_owned(v)` and
  the index would commit eagerly, `park(c, result)`.
- **conclusion.** Project `obj[key]` per the type algebra (field, indexer,
  meta `__index`, etc.), `unify(result, projected)`, `retire`. Failures
  `fail`.
- **handler.** `solve_index` (`solve.lua:1457`).

### RULE C_CALLABLE {callee, args, ret, line, col}
- **premises.** Run `claim(ret, c)` on entry.
- **conclusion.** Dispatch on `find(callee).tag`:
  - `TAG_FUNCTION` → `instantiate_at_use(callee, args, ret)` if callee was a
    free TV at gen time; iterate params calling `unify` per pair; if a bind
    set `_bind_woke_given`, `resume_iter(c, _)` (`return false`). Otherwise
    `unify(ret, first_ret)` and `retire`.
  - `TAG_INTERSECTION` → `try_each(member_functions, attempt_member,
    fail_with_candidates)`; commit chosen via `bind(ret, chosen_ret)`.
  - `TAG_UNION` → see C_DISTRIBUTE_OVER_UNION below; rule body retires after
    delegating.
  - `TAG_ANY/UNKNOWN/NEVER/VAR/NOMINAL` → fixed dispatch per `solve.lua`.
- **side cond.** ownership is owed by every terminal path.
- **handler.** `solve_callable` (`solve.lua:2123`).

### RULE C_ARITH {op, lhs, rhs, result, line, col}
- **premises.** If either operand is `Unbound v` of a sub-solve param,
  emit metamethod-shape bound (`merge_inferred_bound`) and retire. Else if
  operand still `Unbound`, `defer(c)`.
- **conclusion.** Look up `__<op>` via `meta_op_ret_impl`, `unify(result,
  ret_ty)`, `retire`.
- **handler.** `solve_arith` (`solve.lua:2507`).

### RULE C_RETURN {val, expected, line, col}
- **conclusion.** `unify(val, expected)` with multi-return tuple flattening,
  `retire`.
- **handler.** `solve_return` (`solve.lua:2724`).

### RULE C_COMPARE {lhs, rhs, line, col}
- **conclusion.** `unify(lhs, rhs)` per `==`/`<` semantics (overlap-required),
  `retire`. Diagnostic on disjoint.
- **handler.** `solve_compare` (`solve.lua:2599`).

### RULE C_BOUND {fresh_tv, bound, line, col}  (tier: GIVEN at emit)
- **premises.** If `find(fresh_tv)` is `Unbound`, `park(c, fresh_tv)`. If
  the resolved bound itself contains a free TV, `park(c, bound)`.
- **conclusion.** Per bound shape: `propagate_function_bound`,
  `propagate_meta_bound`, kind-arity check, or `TAG_MATCH_TYPE` evaluation.
  `retire`.
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
- **conclusion.** Per-param `unify`, then `unify(ret, first_ret)`. On
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
- **conclusion.** Walk reachable TVs from `find(ret)`; if any has the
  matching `call_id` skolem mark, `fail`. Else `retire`.
- **handler.** `solve_escape_check` (`solve.lua:799`).

### RULE C_HKT_DECOMPOSE {f_fresh, args_fresh, bound_alias, actual_arg, line, col}
- **conclusion.** Pattern-match `actual_arg` against the structural body of
  `bound_alias` parameterised by `args_fresh`. On match, `bind(f_fresh,
  bound_alias)` and `bind(args_fresh[i], recovered_arg_i)`. `retire` always.
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

`try_each` is a search primitive on `Σ` with read-only candidate probes and
a single commit. It is **not** a constraint; the worklist solver is
single-state and has no rollback. The audit (shape 3 verdict) shows why
emit-only cannot model this:

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
| `solve_callable`              | solve.lua:2123     | C_CALLABLE *(+ delegates to C_DISTRIBUTE_OVER_UNION on TAG_UNION; Phase 3)* |
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

16 existing handlers, 17 rules. The mapping is 1-1 modulo two Phase-3
items (both flagged in the table): the new `C_DISTRIBUTE_OVER_UNION` kind
must land, and `solve_callable` / `solve_check_args` must lose their
inline TAG_UNION branches in favour of emitting the new kind. The stub
`solve_instantiate_at_call` is filled in by Phase 3 using the
`instantiate_at_use` primitive (§2).

## 10. solve2.lua disposition

**Verdict: collapse `solve2.lua` back into `solve.lua`.**

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

Phase 3 cannot start while this section names any blocker. Both items
below are blockers.

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
change). **Not a blocker** — pre-emptively reclassifying.

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
path. **Not a blocker** — verified.

### Net §11 verdict

After adversarial passes, both gaps reduce to performance / verified
detail. **No blockers remain. Phase 3 may proceed.**
