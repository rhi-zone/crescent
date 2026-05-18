# Typechecker — Solver Architecture v2 (Resolution Barriers)

Architectural rework of the constraint solver. The current solver's
failure mode across v1/v2/v3 of the H2 design was structural: handlers
encode their resolution dependencies inline as per-kind deferral
predicates, and fast-paths silently accept TV-on-either-side via
`try_unify`'s permissive semantics. Adding a constraint kind required
editing every handler that might race against it. This design replaces
the per-kind deferral with a uniform **resolution-barrier** primitive.

## Invariants implicit in the current solver

| Handler                | Reads             | Writes                  | Order dependency / fast-path |
| ---------------------- | ----------------- | ----------------------- | ---------------------------- |
| `solve_unify`          | TV a, b           | `unify_mod.unify`       | Synchronous; assumes operands ready. |
| `solve_sub`            | actual, expected  | `unify_mod.unify`       | **Fast-path (588-596)**: when expected is non-TV non-closed-table, calls `try_unify`. `try_unify` returns `true` for any TV on actual side without binding (unify.lua:1031-1037). v3 P2 lost info here. |
| `solve_bound`          | tv_id, bound_id   | back-propagation        | Defers if either is TV. |
| `solve_index`          | obj, key          | binds res_tid           | Defers if obj is TV. |
| `solve_bind_generics`  | callee, args      | binds param TVs         | Synchronous. **Ad-hoc**: scans pending C_BOUND to defer when param0 is bound (2755-2792). |
| `solve_check_args`     | callee, args, ret | binds ret, args         | Defers if callee TV or any param TV. |
| `solve_arith/compare`  | operands          | meta dispatch           | Synchronous. |
| `solve_hkt_decompose`  | gen-time payload  | binds fresh TVs         | Reads `_hkt_payloads` populated gen-time — v1's channel-separation regression. |
| `solve_range`          | constraint list   | sticky `_solved`        | Caps at 4 passes; rebinds `hi = #constraints` per pass (P1.5). Source order. |

### Hidden invariants (load-bearing, undeclared)

- `try_unify` returns `true` for TV-on-either-side without binding. Any
  handler that acts on its truth value (solve_sub fast-path) silently
  loses information. **This is the v3 P2 failure mode.**
- `solve_bind_generics` must run before `solve_check_args` for the same
  callsite — guaranteed only by source-order emission today.
- `solve_bound` back-propagation must fire between `solve_bind_generics`
  (param0 binding) and `solve_check_args` (later params) — enforced by a
  per-kind peek into other constraints. **Ad-hoc.**
- `_last_multi_return*` is gen-time mutable shared state read in the same
  pass (v3's C10-C12 chain).

## Implicit dependency graph

Edges between constraints, today:

```
C_INSTANTIATE_AT_CALL  → C_BIND_GENERICS, C_CHECK_ARGS, C_BOUND, C_ESCAPE, C_HKT_DECOMPOSE
C_BIND_GENERICS        → C_BOUND          (binds the TV that C_BOUND watches)
C_BOUND                → C_CHECK_ARGS     (back-propagates param TVs)
C_CHECK_ARGS           → (binds ret_tid)
C_INDEX                → (anything reading res_tid — call ret slot projection)
C_HKT_DECOMPOSE        → C_BOUND on inner args
C_ARITH / C_COMPARE    → (operands concrete enough for meta lookup)
C_NARROW_NIL           → input TV resolved
C_SUB                  → both operands resolved (or fast-path silently fails)
```

The graph is a **DAG keyed on TV resolution events**, not on constraint
identity. Each constraint reads some set of TVs and writes some set; the
read-set must be resolved before the constraint can run soundly. The
current solver "solves" by iterating to fixpoint with hand-coded
deferrals and ad-hoc cross-kind peeking. The fundamental defect:
deferral predicates are encoded *inside the handler*, kind-specifically.

## Architecture candidates

| Shape                              | Solver Δ | Constrain Δ | Rewrites handlers? | Subsumes (X)? | Ad-hoc? | Ship?     |
| ---------------------------------- | -------- | ----------- | ------------------ | ------------- | ------- | --------- |
| α explicit dependency edges        | medium   | small       | reroute only       | yes           | no      | maybe     |
| β resolution barriers (TV-keyed)   | medium   | small       | reroute only       | yes           | no      | **yes**   |
| γ constraint-gen as fixpoint       | huge     | huge        | full               | yes           | risk    | no        |
| δ reified tentative bindings       | medium   | none        | small              | yes           | risk    | no        |
| ε pure propagators (CHR)           | huge     | full        | full               | yes           | no      | too big   |
| ζ sequenced stages                 | small    | medium      | reroute            | partially     | yes     | no        |

### Why (β) — resolution barriers

Inversion of control: handlers no longer poll. Every TV has a
**subscriber list**. When a handler reads `find(ctx, tv)` and finds it's
still TAG_VAR/TAG_ROWVAR, it doesn't `return false`; it calls a
primitive `await(ctx, tv, c)` which appends `c` to that TV's subscriber
list and the solver moves on. When *any* handler binds a TV (the
existing `bind_var_to_type` in `unify.lua` becomes the only publisher),
the solver re-enqueues every constraint that awaited that TV.

Critical: it eliminates every fast-path that silently loses information.
"Succeeded via try_unify but didn't bind" becomes "awaited the TV, will
rerun when it resolves." `solve_sub`'s fast-path becomes: try unify; if
unbound TV detected, await — don't accept.

Composes uniformly:

- `C_INSTANTIATE_AT_CALL`: handler awaits the callee TV → on resolution,
  emits children. Identical mechanism to everything else.
- HKT record dispatch: decompose handler awaits the actual TV → fires
  uniformly. Gen-time `_hkt_payloads` channel goes away.
- Multi-return correlation (Y): awaits the call's ret TV → projects
  slots. No `_last_multi_return*` override needed.
- `solve_bind_generics`'s ad-hoc `C_BOUND` peek: deleted. Bind_generics
  awaits param0; C_BOUND fires when ready; ordering happens automatically.

Does NOT require rewriting unify, adding new constraint kinds, or
reshaping constraint payloads. Only the handler return convention
extends.

## Recommendation: (β) resolution barriers

- `tv_waiters[tv_id] : { Constraint... }` map on ctx.
- `await(ctx, c, tv_id)` registers c, returns a sentinel.
- Wake-up hook in `unify.bind_var_to_type` drains `tv_waiters[var_id]`
  into the worklist.
- Handler return convention extends to
  `boolean | { solved, emit?, await? }`. The await field is a TV id or
  list; harness handles registration. P1.5's emit channel stays.
- Fast-paths in `solve_sub`, `solve_bind_generics`, `solve_check_args`
  rewritten to call a new `try_unify_strict` that returns
  `(true | false | "needs", tv_id)` — never silently accepts a TV.
- Cross-kind peeks (`solve_bind_generics`'s C_BOUND scan) are deleted:
  await on param0 + natural ordering from wake-up provides the same
  guarantee.

The 4-pass loop is replaced by a worklist drained to quiescence;
quiescence is "no awakened constraints AND no pending emits." Cycle
detection: if a wake-up wave does not bind anything new (union-find
generation counter doesn't advance), break.

## Phased implementation plan — 6 phases

Each phase passes the full test suite.

**Phase A — `try_unify_strict` (~80 LOC, 1 commit).** Add strict variant
alongside `try_unify`; returns `"needs", tv_id` when a TV would be
touched. Convert only `solve_sub`'s fast-path to call it; on `"needs"`,
fall through to the unify slow path. No behavior change today; channel
exists. Regression baseline.

**Phase B — `tv_waiters` infrastructure (~120 LOC, 1 commit).** Add the
map and the wake-up hook. Add `await` field handling in `solve_range`.
No handler yet uses it. All current `return false` deferrals still loop;
new infra is dormant. Add regression test with stub handler.

**Phase C — Migrate `solve_bound`, `solve_index`, `solve_narrow_nil` to
`await` (~100 LOC).** Simplest "defer if TV" patterns. Replace
`return false` with `await(c, tv)`. Verify pass count drops on
representative programs.

**Phase D — Delete the ad-hoc C_BOUND peek in `solve_bind_generics` and
`solve_check_args` (~150 LOC).** Replace with `await(c, param0_tv)`
after param0 partial bind, and `await(c, callee_tv)` for callee-still-
free. **Biggest semantic change**: back-propagation ordering derives
from the wake-up graph, not from a hand-coded scan. Hook-passing
requires regenerating fuzz baselines.

**Phase E — Rework `solve_sub` fast-path (~80 LOC).** Strict variant
exists; route TV-detection into `await`. Fast-path stops silently
accepting unbound TVs.

**Phase F — Re-land Option (X) (~300 LOC).** `solve_instantiate_at_call`
becomes a real handler. Migrate C1–C9 from `NODE_CALL_EXPR` per v3, but
the handler uses `await(callee) + emit(children)` uniformly. Structural-
peek for C11/C12 stays at gen-time as v3 prescribed. Re-land H2 record-
of-generics dispatch (P4 from v3) as part of this phase since the
architecture now supports it without override hunks.

A–C are mechanical and independently valuable. D is the riskiest. E and
F are the payoff.

## What folds in

- **P1.5 emit-during-solve (`c26ed415`):** kept and generalized. `emit`
  is one of the channels in the new return protocol; `await` is the
  other. The dynamic `hi = #constraints` per pass is replaced by a true
  worklist, but the spirit (children attribution by emit-time) survives.
- **Phase 1 of (X) (`56fa9694`, C_INSTANTIATE_AT_CALL stub):** kept.
  Constraint kind survives; Phase F gives it a real handler.
- **v1 channel-separation override:** already reverted (`9f025732`).
- **`solve_bind_generics`'s C_BOUND scan (solve.lua:2773-2779):** deleted
  in Phase D.
- **`solve_check_args` callee re-instantiation (2877-2880):** deleted in
  Phase F (method calls go through `C_INSTANTIATE_AT_CALL`).
- **`_last_multi_return*` gen-time channel:** kept short-term (C10/C11/
  C12 remain gen-time); future (Y) work could migrate it via await.

## What this unlocks

- **(Y) type-level multi-return flow:** natural. Slot-extracting
  `C_INDEX(call_ret, 0)` awaits `call_ret`. No
  `_last_multi_return_override` needed.
- **HKT record dispatch (H2):** uniform — `C_HKT_DECOMPOSE` awaits its
  actual TV; gen-time `_hkt_payloads` channel disappears.
- **GADT-strength flow typing:** narrowings depending on call results
  gain a place to attach; post-solve narrow pass can await TVs and
  re-fire.
- **Impredicativity / rank-N improvements:** rank-N skolem mutation (C1)
  becomes the side effect of `await(callee).then(promote_skolems)` — no
  longer entangled with call-site emission.
- **Effects (B2):** effect-row TVs in function types become another
  participant in the same await graph; no special casing.

## Open questions for Phase A

1. **`try_unify_strict` reporting both TVs.** A constraint reading
   `(actual_tv, expected_tv)` where both are free should wake on either
   resolution; waking on both may double-fire.
2. **Worklist ordering vs source order.** Today constraints fire in
   source order; matters for `rank_n_call_id` assignment. The worklist
   must preserve source-order priority among ready constraints.
3. **Sub-solve closure under `await`.** `gen_function`'s sub-solve
   assumes body constraints are quiescent on exit. If a body constraint
   awaits a TV that only the outer solver binds, sub-solve must treat
   the await as "deferred and retried by outer" or force binding. P1.5
   answered the analogous emit question; await needs the same answer.
4. **Cycle detection.** Mutual generic bounds — the wake-up graph could
   cycle. The existing fixpoint iteration absorbed this implicitly. The
   new worklist needs explicit "no progress in last full drain → break".
5. **Performance.** Verify on the perf gate (CLAUDE.md: "competitive with
   tsgo"). Plausibly faster (no redundant re-runs of already-blocked
   handlers).

## Honest assessment

This is the **right design**, not the least-bad. The TV-keyed barrier is
structurally aligned with the existing union-find: writes already go
through a single chokepoint (`bind_var_to_type`); we add one line of
bookkeeping there and remove every per-kind defer predicate. The shape
was hiding in plain sight because P1.5 introduced emit-during-solve; the
symmetric primitive (await-during-solve) closes the protocol. Risk
concentrates in Phase D, testable in isolation.
