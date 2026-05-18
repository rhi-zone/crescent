# Typechecker Solver — Distilled Fundamentals

Distillation of the 51-invariant inventory at
`docs/typechecker-solver-invariant-inventory.md`. The user's intuition
("51 makes no sense") was correct — the count was inflated by lumping
fundamental architectural contracts with implementation details,
manifestations of the same contract, and already-explicit mechanisms.

**Actual fundamental count: 6.**

## Classification of the 51

- **(F) Fundamental architectural contracts**: 6
- **(I) Implementation details** (changeable without semantic impact): ~17
- **(D) Manifestations of fundamentals**: ~20
- **(M) Already-explicit mechanisms from items 1-5+1.5**: 8

## The 6 fundamentals

1. **Dependency ordering.** A constraint that reads state X must run
   after the constraint that writes X. Mechanism: FIFO worklist + tier
   discipline. **Addressed by items 1, 2.**

2. **Quiescence-based termination.** The solver halts when a round
   produces no retirements and no binds. Mechanism: bind generation
   counter + retirement count. **Addressed by item 1.**

3. **Sleeper wakeup chokepoint.** Every TV bind must notify everyone
   awaiting it, through a single funnel. Mechanism: `wake_waiters` in
   `unify.bind_var_to_type`. **Addressed by item 4e.**

4. **GIVEN-priority / declared-beats-inferred.** When a declared bound
   and an inferred bound race on the same TV, declared wins. Mechanism:
   tier dispatch + `_bind_woke_given` flag. **Addressed at mechanism
   level by item 2.** The *contract* (declared wins) is more durable
   than the *mechanism* (tier flag) — a rewrite must preserve the
   contract, not the flag. Documenting this near the flag would prevent
   accidental removal.

5. **Sub-solve scope discipline.** Function-body solving sees params as
   free skolems; must not bind them; constraints awaiting them must
   survive solve exit. Mechanism: FLAG_SUB_SOLVE_PARAM. **Addressed
   at mechanism level by item 4e.**

6. **Fresh instantiation at use site.** Each call/use of a polymorphic
   value gets its own type variables (the let-polymorphism
   generalization boundary). **NOT mechanized as a single primitive.**
   Currently distributed across `C_INSTANTIATE_AT_CALL`,
   `solve_callable`'s ad-hoc instantiation path, and
   `env_mod.instantiate`.

## Verdict revision

**Rewrite is NOT justified.** Five of six fundamentals are already
addressed by items 1-5+1.5. The remaining gap (fundamental 6) is a
consolidation task, not an architectural rewrite.

The previous "needs a rewrite" position (commit `61802225`) was based on
the inflated 51 count and is retracted.

## What fundamental 6 actually needs

Currently each call site that produces polymorphic instantiation does it
through its own code path:
- Direct call: `solve_callable` instantiates inline.
- Method call: `solve_check_args` has a re-instantiation branch
  (solve.lua:~2841, "load-bearing for free-callee unification").
- Deferred call: `C_INSTANTIATE_AT_CALL` (currently a passthrough stub
  from Phase 1 of the prior architecture-v2 work).

Phase F's previous attempt tried to migrate the gen-time call-site
emission block (C1-C9) into the solver. The blocker was that doing the
code-motion broke implicit ordering invariants. Reframed: the goal isn't
"move blocks of code" but **"name the generalization boundary as a
primitive and consolidate the three current paths through it"**. This is
smaller and more focused than the v3 "move C1-C9" framing.

## Targeted next-session work

ONE consolidation:
- Define `M.instantiate_at_generalization_boundary(callee_tid, args,
  ret, ...)` as the single named entry point.
- All three current paths route through it.
- The "generalization boundary" name makes the contract explicit:
  fresh type vars per call, scoped to the call site, regardless of
  whether the callee is direct/method/deferred.
- H2 record dispatch lands as a byproduct because the deferred case
  goes through the same entry point.

Estimated scope: smaller than the failed Phase F-impl because the
work isn't code-motion — it's giving an existing pattern a name and a
single implementation site.

Cannot honestly promise this works without the previous Phase F failure
modes. The architectural finding (producer→consumer ordering of call
ret TVs) is real and would need to be addressed in the consolidation —
likely by ensuring the `C_INSTANTIATE_AT_CALL` constraint, when it
fires, head-inserts its emitted children OR sets up explicit await on
ret_TV for downstream consumers. Whichever, the contract is now named.

## Lesson for future audits

Counting "things that look like invariants" produces inflated numbers
that suggest rewrites are needed. Counting fundamental architectural
contracts vs. their manifestations vs. their already-mechanized
implementations produces actionable numbers.

The previous audits in this session series (105+ → verified 90, 18 → 30,
51 → 6) all had the same shape: agent identified surface patterns; user
intuition flagged the count as off; verification consolidated to a
smaller, more meaningful number. The pattern itself is the meta-lesson:
**every audit count should be challenged before being acted on.**
