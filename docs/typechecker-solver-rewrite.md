# Constraint Solver Rewrite — Outside-In/X

The current solver is an unfaithful instance of GHC's Outside-In/X
discipline (Vytiniotis/Peyton Jones/Schrijvers/Sulzmann 2011) —
implications-and-wanteds is implicit in the code (tier=GIVEN/WANTED,
sub-solve via `solve_range`, `wake_waiters` as touched-tyvar) but
never named or structured as the paradigm. The rewrite makes the
already-half-present structure explicit, replacing retrofitted flags
with intrinsic data shape.

## Paradigm selection

Outside-In/X selected against propagator network, CHR, e-graph,
CPS-solver, attribute grammar. Only Outside-In/X makes all 6
fundamentals intrinsic; the others retrofit at least one. CHR has
unacceptable rule-matcher overhead vs. tsgo perf gate. The current
solver being a degenerate instance of it means the rewrite *names*
rather than *imports* structure.

## Mapping the 6 fundamentals

Core data: `Implication { skolems, givens, wanteds, parent }`,
`Wanted { kind, evidence, blocked_on: tyvar | nil }`, canonical
inert set keyed by head-tyvar.

1. **Dependency ordering** — `blocked_on` graph. FIFO inside one
   level falls out naturally.
2. **Quiescence termination** — `simplify` returns when active
   queue is empty AND no bind occurred this pass. Defining contract,
   not parked invariant.
3. **Sleeper wakeup chokepoint** — `bind` → `wake(tyvar)` transfers
   blocked wanteds to active queue. Only path back to active.
4. **GIVEN-priority** — Givens saturate inside an implication before
   any wanted runs. Deletes `_bind_woke_given` flag; contract becomes
   *order of operations*, not observed post-bind.
5. **Sub-solve scope** — `Implication` owns skolems. Skolem-binding
   attempt = error by construction. Replaces FLAG_SUB_SOLVE_PARAM.
6. **Fresh instantiation at use site** — single `instantiate_at_use`
   primitive. Three current call paths collapse into one. The
   missing-primitive fundamental, named.

No fundamental is a mismatch.

## Migration approach

**Parallel implementation, bottom-up handler porting.** `solve2.lua`
coexists with `solve.lua`. Per-kind dispatch routes specific kinds
through the new core. Every commit passes the full 2765-test suite.
Old solver deleted only after parity.

Rationale: pure parallel forks drift; pure bottom-up swap risks
mixed-semantics regressions. Hybrid: new core (loop + implication
tree + wake), kinds ported one at a time.

## Phases

- **P1 (~350 LOC):** `solve2.lua` core — `Implication`, `Wanted`,
  queues, `simplify`, `wake`, skolem ownership. Smoke test for one
  `C_UNIFY`. `M.solve` still dispatches to old. Production path
  unchanged; full test suite passes.
- **P2 (~250 LOC):** Port `C_UNIFY` and `C_SUB`. Per-kind flag in
  `solve_range` routes ported kinds to `solve2`. Both share
  `bind_var_to_type`/`wake_waiters`.
- **P3 (~450 LOC):** Port `C_BOUND`, `C_NARROW_NIL`,
  `C_ESCAPE_CHECK`, `C_OR`. Canonical inert set introduced. After
  this phase: `_bind_woke_given` removed for ported kinds.
- **P4 (~600 LOC):** Port call-path family (`C_CALLABLE`,
  `C_CHECK_ARGS`, `C_INSTANTIATE_AT_CALL`, `C_BIND_GENERICS`) via
  `instantiate_at_use`. Fundamental 6 lands. FLAG_SUB_SOLVE_PARAM
  retired for these kinds.
- **P5 (~500 LOC):** Port `C_INDEX`, `C_ARITH`, `C_COMPARE`,
  `C_RETURN`, `C_OVERLAP`, `C_HKT_DECOMPOSE`. Old `solve_range`
  becomes a thin compat shim.
- **P6 (~-1500 LOC net):** Delete old loop, `_deferred`,
  `_bind_woke_given`, FLAG_SUB_SOLVE_PARAM, `solve_range` wrapper,
  tier constants. `solve2.lua` renamed to `solve.lua`. Expected to
  *remove* ~1500 LOC.

Total new code through P5: ≈2150 LOC. Net after P6: solver shrinks
vs. today (current `solve.lua` is 3990 LOC; expected end state ≈2400
LOC including all kinds).

## What gets reused vs. replaced

| Mechanism                | Disposition                                       |
| ------------------------ | ------------------------------------------------- |
| Worklist drain           | Replaced — implication-keyed `simplify` queue.    |
| Tier dispatch            | Replaced — Givens-saturate-first makes flag moot. |
| FLAG_SUB_SOLVE_PARAM     | Replaced — implication skolem ownership.          |
| `wake_waiters` chokepoint| Preserved (renamed `wake`); still at `bind_var_to_type`. |
| Terminal error handlers  | Preserved — orthogonal to scheduling.             |
| Union-find / occurs / level | Preserved unchanged.                           |
| `tv_waiters` index       | Preserved as `blocked_on` index — same data, OutsideIn/X vocabulary. |

## P1 concrete contents

`solve2.lua` (~350 LOC):
- `Implication` and `Wanted` record types (Lua tables, documented shape).
- `simplify(ctx, impl)` loop: `active`/`blocked`/`given_active` queues, quiescence termination, given-then-wanted ordering.
- `wake(ctx, tyvar)` — function `unify.bind_var_to_type` will eventually call; P1 invokes only from smoke test.
- `solve_one(ctx, c)` — entry point for tests: wraps a legacy constraint in a one-Wanted root implication, runs `simplify`, returns.

`solve.lua`: gains `require("lib.type.static.solve2")` at top. Otherwise unchanged.

`solve2_smoke_test.lua`: exercises a single `C_UNIFY` end-to-end through the new core.

All 2765 existing tests pass. New core exists, is tested, has the data shapes later phases require.

## Honest assessment

Outside-In/X is **elegant under the anchor**, not "least-bad":
- Every fundamental is a first-class concept in the paradigm.
- Current solver is already an unfaithful implementation; rewrite *names* a structure already implicit — the kind of change that ages well.
- Published 70-page spec (Vytiniotis et al. 2011) means we lean on existing literature, not re-derive.

The one risk to elegance: fundamental 6 (`instantiate_at_use`) is "elegant" only if all three current call paths really do reduce to one entry. P4 proves it. If they don't, the design revisits before continuing.

## Sources

- Vytiniotis, Peyton Jones, Schrijvers, Sulzmann (2011). "OutsideIn(X): Modular type inference with local assumptions." JFP 21(4-5): 333-412.
- GHC Tc.Solver source (the working implementation reference).
