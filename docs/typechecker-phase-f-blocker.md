# Phase F Blocker — Producer→Consumer Ordering Invariant

Phase F-impl was attempted on top of items 1-5 + 1.5 and reverted cleanly.
The migration of consumers C1-C9 from `NODE_CALL_EXPR` into
`solve_instantiate_at_call` (per `docs/typechecker-h2-correct-design-v3.md`)
works in isolation — H2/H2a/H2b/H2e all flip from `has_error` to
`no_errors` — but ships unshippable regressions in other parts of the
test suite.

## Hidden invariant surfaced

The entire constraint-generation pipeline has been built on a hidden
assumption: **gen-time emission order in `constrain.lua` produces a
constraint sequence where call-site instantiation children always
appear before statement-level checks on those call results.**

When `C_BIND_GENERICS` and `C_CHECK_ARGS` emit at gen-time directly
inside `NODE_CALL_EXPR`, they land in `ctx._constraints` ahead of the
subsequent statement's `C_SUB(ret_TV, ann_T)`. The 4-pass solver and
worklist alike process them in that order, so the call's binding fires
before the annotation check.

Deferring instantiation to the solver breaks this: when
`solve_instantiate_at_call` emits its children, they land at the END of
the worklist. The next statement's `C_SUB(ret_TV, ann_T)` has already
been processed, free `ret_TV` against concrete `ann_T` is unified
synchronously (binding rather than checking), and the diagnostic is
lost.

## Attempted local fix and why it fails

Deferring `solve_sub` / `solve_return` / `solve_check_args` when the
actual side is a free TV and expected is concrete:
- Recovers ~7 of 10 regressions.
- **Introduces ~20+ NEW regressions** because:
  - HM Phase 2 (`t.x()` rejecting wrong type) relies on
    `solve_check_args` binding free actuals.
  - Multi-return narrowing breaks because `C_INDEX` cascade is blocked
    behind the deferred check.
  - `ffi.C` cascade chains (`ffi.C.add` → `v2 → v1 → ffi_TV`) fail to
    propagate because the open-table unify path doesn't bind the chain
    root that `C_INSTANTIATE_AT_CALL` is awaiting.

The synchronous-bind behavior is itself load-bearing across many
patterns; deferring it uniformly breaks more than it fixes.

## Principled fix sketches

Two architectural changes that would resolve this, each outside Phase
F's 600-LOC budget:

### (P1) Await-on-producer for every consumer of a call's ret TV

Every constraint that reads `ret_TV` (where `ret_TV` is the return
slot of some pending `C_INSTANTIATE_AT_CALL`) must explicitly await
on `ret_TV`. This requires:
- Tracking which TVs are "produced by" a pending `C_INSTANTIATE_AT_CALL`.
- Modifying `solve_sub`, `solve_return`, `solve_check_args`,
  `solve_index`, possibly more to check this and await.
- Likely ~200 LOC, touches every read-call-result handler.

The classification "produced by a pending instantiate" needs to be
maintained as TVs bind — tedious but uniform.

### (P2) Worklist head-insert primitive

Add a solver primitive that inserts emitted children at the HEAD of
the worklist rather than the TAIL. `solve_instantiate_at_call` uses
this so its children process before the next statement's checks.

Mechanism: not currently in the worklist. Adding it requires:
- Distinguishing head-emit from tail-emit at the handler-return
  protocol level.
- Verifying it doesn't break other invariants (e.g., emit-during-
  draining safety).
- Possibly ~150 LOC, more contained but introduces a new solver
  primitive.

Both are principled (no ad-hoc per-kind branches). Either resolves
the blocker.

## Recommendation

This is the FOURTH design iteration on H2 (v1/v2/v3 + Phase F-impl)
that has discovered a previously-unnamed architectural assumption.
The pattern is convergent — each finding is sharper — but the cost
of session-by-session discovery is high.

Before the next iteration, name the broader invariant explicitly:
"any rework that changes WHEN call-site instantiation runs must
preserve OR replace the implicit ordering guarantee with explicit
await-on-producer."

The next session's option:
- (P1) Implement await-on-producer broadly. Most principled. ~200 LOC.
- (P2) Implement worklist head-insert and use it from
  `solve_instantiate_at_call`. Smaller, but introduces a new solver
  primitive. ~150 LOC.

Either succeeds Phase F-impl. Neither is in scope for the current
session given the budget.

## State

- Phase F-tests landed (`29b6688f`) — pins are flip-targets.
- Phase F-impl reverted; no commit beyond the test pins.
- Items 1-5 + 1.5 remain clean and landed.
- H2 record-of-generics dispatch remains a known gap, pinned in the
  test suite.
