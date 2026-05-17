# Typechecker — H2 Correct Design v3 (Remaining-Work Phasing)

Supersedes v2's phasing only. v2's strategic rationale (why (X), why not
v1's channel separation) still stands. This document re-phases the work
after the Phase 1 landing zone (`56fa9694`).

## Consumer chain at `NODE_CALL_EXPR` (constrain.lua:2714-3032)

Enumerated reads of `inst_callee` / `inst_mapping` and of `callee_tid`
after gen-time instantiation:

| #   | Consumer                              | File:line | Needs                                                | Output                                        | Where consumed                                                          |
| --- | ------------------------------------- | --------- | ---------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------- |
| C1  | rank-N skolem mutation                | 2816-2841 | `callee_tid` (pre), `inst_mapping`, `rank_n_set`     | mutates `fresh_tv.flags = FLAG_SKOLEM`        | solver                                                                  |
| C2  | C_BOUND emission for inst'd bounds    | 2848-2858 | `inst_mapping`, `_forall_bounds[orig]`               | emits `C_BOUND(fresh_tv, inst_bound)`         | solver                                                                  |
| C3  | HKT fresh→bound map build             | 2853-2867 | `inst_mapping`, resolved `inst_bound`                | local `hkt_fresh_to_bound`                    | C4, C5 same pass                                                        |
| C4  | HKT decompose emit                    | 2881-2933 | `inst_callee`, `arg_tids`, `hkt_fresh_to_bound`      | populates `ctx._hkt_payloads`, emits constr.  | solver                                                                  |
| C5  | HKT eager-bind                        | 2939-2949 | `inst_callee`, `hkt_fresh_to_bound`                  | direct `unify.bind_var_to_type`               | solver                                                                  |
| C6  | `_forall_ops` re-emission             | 2958-2992 | `inst_mapping`                                       | re-emits ARITH/COMPARE/BIND_GEN/CHECK_ARGS    | solver                                                                  |
| C7  | C_BIND_GENERICS emit                  | 3001      | `inst_callee`, `arg_tids`, `ret`                     | constraint                                    | solver                                                                  |
| C8  | C_CHECK_ARGS emit                     | 3002      | `inst_callee`, `arg_tids`, `ret`                     | constraint                                    | solver                                                                  |
| C9  | C_ESCAPE emit                         | 3003-3007 | `ret`, `rank_n_call_id`                              | constraint                                    | solver                                                                  |
| C10 | `_last_multi_return = { ret }`        | 3008      | `ret` (fresh TV)                                     | mutates ctx                                   | **gen-time** — read by NODE_RETURN_STMT at 1653                         |
| C11 | `try_eager_intrinsic_return`          | 3016      | `inst_callee` resolved fn with MATCH_TYPE in spread  | sets `_last_multi_return_override`            | **gen-time** — read by LOCAL_STMT/ASSIGN_STMT same pass (3479, 3631)    |
| C12 | `peek_callee_ret_union` fallback      | 3024-3029 | `callee_n` AST (NOT `inst_callee`)                   | sets `_last_multi_return_override`            | **gen-time** — same as C11                                              |

Solver-side residue: `solve_bind_generics` (solve.lua:2737-2742) and
`solve_check_args` (solve.lua:2876-2880) each re-instantiate when
`raw_t.tag == TAG_VAR`. Dead for direct calls today (gen-time instantiates
first) but live for **method calls** (constrain.lua:3049 — `inst_method =
env.instantiate(method_var, …)` on a fresh TV, `raw_t` stays TAG_VAR). Any
phasing must preserve that path.

## Category per consumer

- **Migrate-with-inst** (into `solve_instantiate_at_call`): C1, C2, C3, C4,
  C5, C7, C8, C9. All emit solver constraints or mutate solver-side state.
  None of their outputs are read again in the same gen-time pass.
- **Stay-at-gen-time:** C10, C11, C12. All feed `_last_multi_return*`
  consumed by LOCAL_STMT/ASSIGN_STMT/RETURN_STMT in the SAME gen-time
  pass. The override has to be set before the parent statement rule reads
  it.
- **Decouple:** C6 (`_forall_ops` re-emission) needs only `inst_mapping`.
  Can move; subtle requirement: must run AFTER `inst_mapping` is
  constructed and BEFORE downstream solver work that depends on the
  re-emitted constraints. Inside the solver this is fine — emitted
  constraints join the worklist.

Honest gap: C11's `try_eager_intrinsic_return` needs a resolved
`inst_callee` at gen-time. Today that resolution happens because
`env.instantiate` runs synchronously. If we defer instantiation to the
solver, the override cannot be set gen-time — LOCAL_STMT would bind the
local to a stale TV.

## Why (A) is the only viable shape

Shape **(A) "move whole block at once"** is the only shape that keeps
intermediate commits green for C7/C8/C9 — they're tightly coupled to
C1/C3/C5 via shared local state (`inst_callee`, `hkt_fresh_to_bound`,
`rank_n_call_id`). Migrating one without the others requires duplicating
that state, which is exactly the kind of scaffolding that bit Phase 2.

(A) alone doesn't solve C10/C11/C12. They need a different mechanism: the
override channel must be solver-driven, or the LOCAL_STMT/ASSIGN_STMT
slot-extraction must itself defer.

Shape (C) "split constraint" doesn't help — splits would all consume the
same resolved callee. Shape (B) requires scaffolding equivalent to running
both code paths in parallel.

## Recommended shape: (A) + structural-peek for override channel

The override channel is preserved by adding a single gen-time helper:
`peek_intrinsic_override(ctx, callee_n, arg_tids)` that returns the
intrinsic-return override (today computed by `try_eager_intrinsic_return`)
*without* calling `env.instantiate`. It walks the *declared* callee
structurally — the eager path only fires when the discriminating arg is
concrete, so per-call freshness isn't required.

After the migration, the gen-time call-site block at 2810-3007 reduces to:

```lua
emit(ctx, M.make_instantiate_at_call(callee_tid, arg_tids, ret, ...))
ctx._last_multi_return = { ret }
local override = peek_intrinsic_override(ctx, callee_n, arg_tids)
                 or peek_callee_ret_union(ctx, callee_n)
if override then ctx._last_multi_return_override = override end
```

Plus orthogonal branches (`require()`, `ffi.cdef`, template-fn).

## Commit plan

### P2 — Move call-site emission block to solver

Size: ~300 LOC moved, ~50 LOC net delta.

Move C1–C9 from `NODE_CALL_EXPR` (constrain.lua:2810-3007) into
`solve_instantiate_at_call` (solve.lua:2703). Constraint payload extended
to carry needed gen-time-derived state (`rank_n_set` likely needs to be
carried; can re-derive solver-side as alternative — recommend carry).

`try_eager_intrinsic_return`-style structural peek for C11 moves into a
new helper `peek_intrinsic_override(ctx, callee_n, arg_tids)` operating on
the declared callee type (pre-instantiation).

`_forall_ops` re-emission (C6) moves with C1–C9 — mechanically a dependent
of `inst_mapping`.

Risk: large but coherent. Hook-passing requires the regression canary
(`string.find`) plus all generic-call-site tests.

### P3 — Method calls + delete dead solver branches

Size: ~80-120 LOC.

`NODE_METHOD_CALL` (constrain.lua:3035-3071) gets the same treatment.
Today they bypass `C_INSTANTIATE_AT_CALL` and instantiate via
`meth_mapping` directly; the `raw_t.tag == TAG_VAR` re-instantiation in
`solve_bind_generics` / `solve_check_args` is the load-bearing safety net.
Move method-call instantiation into the constraint so the solver path is
uniform; then delete the `raw_t.tag == TAG_VAR` branches in solve.lua:
2737-2742 and 2876-2880.

### P4 — Re-land H2 (record-of-generics dispatch)

Size: ~120-200 LOC.

With instantiation deferred, the override that v1 attempted is no longer
needed: the solver sees the resolved callee uniformly, so HKT decomposition
runs on the correct type without a gen-time pre-resolve. Re-apply the H2
predicate-widening hunks from the reverted commit (`213d8516`) — drop the
override hunk entirely.

## v2 open questions, answered

1. **`try_eager_intrinsic_return` TAG_MATCH_TYPE path** (pcall, PcallReturn):
   stays at gen-time, refactored to peek the declared callee structurally
   without instantiation. Only fires when the match-param's arg is
   concrete, so per-call freshness doesn't matter.
2. **`_multi_ret` consumers audit**: only two reads outside constrain.lua,
   both in `narrow.lua` (lines 577, 596), called from
   `propagate_multi_ret_narrowing`. Registration sites are LOCAL_STMT
   (3566), ASSIGN_STMT (3689). The source `call_ret_tid` is the gen-time
   `ret` fresh TV (or override), which the solver later binds. No
   instantiation-timing dependency. **No (Y) needed inside (X).**
3. **`_forall_ops` re-emission**: moves into the solver as part of P2.
   HM Phase 2 semantics are preserved because the re-emitted constraints
   join the worklist in the same relative order.

## (Y) scope

`_multi_ret` migrates cleanly because the registered `source_tid` is a
gen-time TV that the solver fills in. (X) doesn't require (Y). (Y) remains
independently valuable for eliminating `name_id`-keyed fragility but is
outside this work.

## Honest assessment

P2 is one large commit (~300 LOC moved, ~50 LOC net). It cannot be
subdivided without intermediate stale-TV reads — C1-C9 share locals
(`inst_callee`, `hkt_fresh_to_bound`, `inst_mapping`) too tightly. P3 and
P4 are independently shippable after P2 lands.

P2 fits in one focused session if the implementer has the consumer map
above in hand and accepts the structural-peek refactor for C11. P3+P4 are
a second session. Cannot honestly promise all three in one.

## Open questions for implementation session

1. **`rank_n_call_id` ownership**: today allocated gen-time
   (`next_rank_n_call_id(ctx)`). When moved solver-side, the counter still
   lives on ctx but allocation moves into `solve_instantiate_at_call`.
   Does any escape-check code path depend on call IDs being assigned in
   source order? Audit `solve_escape` and rank-N tests.
2. **C_INSTANTIATE_AT_CALL payload shape**: does it need to carry
   `rank_n_set` (gen-time computed by `env.collect_rank_n_generics`), or
   can the solver re-derive from the resolved callee? Re-derivation is
   cleaner but duplicates the walk. Recommend: carry.
3. **HM Phase 2 `_forall_ops` re-emission in sub_solve**: when the
   constraint fires inside `sub_solve` for a generic body, does emitting
   more constraints into the parent worklist vs the sub-solver's worklist
   matter? Trace which `ctx._constraints` is appended to.
4. **`peek_intrinsic_override` for TAG_MATCH_TYPE on generic-template
   callees**: confirm that walking the declared function type's param list
   to match against the concrete-arg position works without instantiation.
   The existing code (constrain.lua:2521-2542) iterates `callee_t`'s
   params searching for `match_param == param`; on the declared template,
   `match_param` is a FLAG_GENERIC TV identical to the param slot, so
   equality holds without freshening.
5. **Method-call uniformity (P3)**: are there any tests covering
   `obj:method()` where `method` is a generic field whose receiver is
   itself generic (record-of-generics method dispatch)? If yes, P3 may
   unmask H2-adjacent issues; if not, document the gap.
