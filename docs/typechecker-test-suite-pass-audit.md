# Test Suite Audit — Pass-Count Assumptions

Open question 1 from `docs/typechecker-architecture-from-first-principles.md`
(commit `def6b132`), flagged as a blocker for the worklist-to-quiescence
rework (item 1).

## Method

Exhaustive grep across `lib/type/static/*_test.lua` for direct
introspection of solver internals: `_solved`, `_deferred`,
`_constraints`, `pass`, `n_passes`, `silent_err`, `ctx._foo` access.
Sample-verification of 20 behavioral tests against the worklist-to-
quiescence model. Specific audit of error-count assertions, multi-pass
named tests (Phase 2, deferred, polymorph), sub-solve boundary tests,
and dedup-machinery dependencies.

## Findings

### Direct introspection: 3 tests

All in `type_test.lua` lines 11269-11327, the suite
`"solver: tv_waiters + await infrastructure (Phase B)"`. They
explicitly test the Phase B infrastructure (`tv_waiters`, `await`,
`_deferred`). Architecture-aware by design — they're meant to evolve
alongside the solver. Minor updates needed when the worklist replaces
the 4-pass loop: remove `_deferred` assertions, keep `tv_waiters`
assertions.

### Error-count assertions: 1 test, verified safe

`type_test.lua:7621` — `assert.eq(#ec.errors, 2)` in "body violating
both overloads reports two errors." The two errors come from two
distinct overload-body constraints firing once each, NOT from a
constraint re-firing across passes. Worklist-to-quiescence preserves
the count.

### Multi-pass / Phase 2 tests: none scheduling-dependent

All Phase 2 tests (10 tests, type_test.lua:4718-4770) check
behavior (error presence/absence), not pass count or re-emission
order.

### Or-expression deferred tests: none scheduling-dependent

7 tests at type_test.lua:2369-2433. All use `no_errors`/`has_error`,
no error count, no pass-N assumptions.

### Sub-solve boundary tests: none direct

No test directly validates sub-solve closure transfer. Behavior is
tested implicitly via overload checks. The rework (transferring
awaited-but-unresolved constraints to outer worklist on sub-solve
exit) will be validated implicitly through existing tests.

### Dedup machinery: no tests depend on it

The dedup at solve.lua:3866-3883 suppresses re-firing duplicates
across passes. Worklist replaces passes with a single drain loop, so
no re-firing means no duplicates to suppress. No test asserts that a
duplicate is suppressed.

## Verdict

**(a) Trivial.** 3 tests need minor updates (the architecture-aware
Phase B infrastructure tests); all other tests survive worklist-to-
quiescence unchanged. No test-suite redesign needed.

The blocker open question 1 named is resolved.

## Implications for the first-principles rework

- Item 1 (worklist-to-quiescence) can proceed without rewriting tests.
  The 3 architecture-aware tests need minor edits as part of item 1's
  commit.
- Items 2, 3, 4 (tier discipline, payload migration for message-bus
  subset, sub-solve parameter passing) have no test-side blockers per
  this audit; their blockers (if any) live in code, not in tests.
