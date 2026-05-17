# Typechecker — H2 Correct Design v2

Supersedes `docs/typechecker-h2-correct-design-v1-superseded.md` (formerly
`-v1`). V1's "channel separation" recommendation was implemented and proved
insufficient; this v2 diagnoses why and proposes a principled fix at the
right architectural layer.

## Critique of v1

V1 framed the regression as channel separation: keep `callee_tid` as the
C_INDEX-fresh-TV for downstream consumers (multi-return narrowing) and use
a separate `resolved_callee_tid` for instantiation/HKT. This is incorrect
because the load-bearing mechanism v1 tried to preserve does not run for
`string.find`: `peek_callee_ret_union` rejects generic functions
(`constrain.lua:2588-2591`, `FLAG_GENERIC` early return), so
`_last_multi_return_override` stays nil for it. Multi-return narrowing for
generic intrinsic-returning functions flows through a different path — the
`ret` fresh TV unified by `solve_check_args` (`solve.lua:2986-2987`) after
`resolve_deferred_intrinsic` evaluates `$FindReturn<P>`. V1's "preserve
channel A so feeder B keeps working" preserves a channel that wasn't
carrying the signal.

## Actual diagnosis

For `string.find: <P: string>(s, P, ...) -> ...($FindReturn<P>)` the
regression has one structural cause: **the same code path now runs in two
different solver states depending on whether instantiation happens at
gen-time or solve-time.**

**Pre-H2 timeline:** `gen_expr(callee_nid)` returns a fresh TV `cv` (the
C_INDEX result). `inst_callee = instantiate(cv, …)` is a no-op on TAG_VAR.
`make_bindgen/checkargs(inst_callee=cv, …)` defers in `solve_check_args` at
`callee_t.tag == TAG_VAR`. When C_INDEX fires, `cv` resolves to the real
`string.find` function. The `raw_t.tag == TAG_VAR` branches at
`solve.lua:2720` and `solve.lua:2858` *then* instantiate, producing fresh
`P_solve`. `P_solve` gets unified with the literal-pattern argument by
`solve_bind_generics`. `resolve_deferred_intrinsic` evaluates
`$FindReturn<"world">` to `(integer,integer) | nil` (concrete
union-of-tuples). `ret` is unified with that, and at narrowing time
`narrow.lua`'s `propagate_multi_ret_narrowing` runs against
`entry.source_tid = ret` whose `find()` resolves to that union-of-tuples —
correlation works.

**Post-H2 timeline:** override at `constrain.lua:2697-2717` swaps
`callee_tid` to the real TAG_FUNCTION at gen-time. `instantiate` produces
a real `inst_callee` with fresh `P_gen`, return shape
`TAG_SPREAD(TAG_TYPE_CALL($FindReturn, P_gen))`.
`make_bindgen/checkargs` is emitted on the concrete function, so
`raw_t.tag == TAG_VAR` is false in both solver entry points — gen-time
`P_gen` is used. The eager-instantiated `inst_callee`'s spread/intrinsic
return is unified with `ret` before `P_gen` is bound rather than after,
losing correlation.

**Structural cause:** instantiation timing is not a property of the
callee — it's a property of when the callee's identity is known. Gen-time
vs solve-time was implicitly carrying that distinction via "is
`callee_tid` still a TV?" The H2 override violates that invariant for a
subset of callees, producing a hybrid case (callee concrete at gen-time,
but generic parameters still need solve-time binding) that the surrounding
code doesn't uniformly handle.

## Candidates

### (X) Defer per-call instantiation entirely (single high-level constraint)

Constraint generation emits `C_INSTANTIATE_AT_CALL(callee_tid, arg_tids,
ret_tid)`. The solver, after C_INDEX resolves the callee, runs
instantiation, rank-N skolemization, HKT decomposition, eager-bind, and
emits `C_BIND_GENERICS / C_CHECK_ARGS`. Removes the gen-time/solve-time
split.

- **Lines:** hundreds (300-500).
- **Risk:** high. `_forall_ops` re-emission interacts with let-polymorphism
  phase 2.
- **Preserves H2:** yes. **Removes regression:** yes.
- **New ad-hoc:** none — both the gen-time override and the
  `raw_t.tag == TAG_VAR` re-instantiation branches disappear.
- **Honest commit answer:** yes, if the project commits to it. This is the
  right shape long-term.

### (Y) Type-level multi-return flow (delete `_multi_ret` registration)

Multi-return narrowing operates on the union-of-tuples type of the
receiving local directly. No `name_id`-keyed table. `eager_slot` already
extracts slots from such types; narrowing would re-extract from the same
source by reading the local's bound type.

- **Lines:** ~150-250.
- **Risk:** medium. Changes the binding-time type of multi-return locals.
- **Preserves H2:** orthogonal. **Fixes regression:** yes (correlation is
  in the type, immune to instantiation timing).
- **New ad-hoc:** one (TAG_MULTIRET wrapper or analogous), but eliminates
  the registration table — net principled.
- **Honest:** plausible, lower-risk than (X). Pays off only if multi-return
  correlation is the dominant fragility (it probably is).

### (Z) Constraint dependency edges

Solver runs dependent constraints in order. `C_BIND_GENERICS` /
`C_CHECK_ARGS` / `C_HKT_DECOMPOSE` for a call site wait until the callee's
C_INDEX has resolved. Keep all gen-time machinery on the *resolved*
callee — i.e., the override becomes the rule, not the exception, but only
fires *after* dependency resolution.

- **Lines:** ~100-150 + dependency-graph plumbing.
- **Risk:** medium-high.
- **Preserves H2:** yes. **Removes regression:** yes.
- **New ad-hoc:** none, but introduces a dependency-graph mechanism that
  didn't exist.
- **Honest:** principled, but partially overlaps with (X). (X) is cleaner.

### (W) Two-pass constraint generation

Pass 1: emit resolution constraints, build callee-resolution map. Pass 2:
with resolved callees in hand, emit instantiation and decompose.
Effectively offline what (Z) does online.

- **Lines:** large (500+).
- **Risk:** high.
- **Honest:** principled but expensive; (X) achieves similar without the
  AST re-walk.

### (V) Revert H2; document HKT-through-records as out-of-scope

- **Lines:** ~80 (revert constrain.lua diff; mark H2a-H2f pending).
- **Risk:** none beyond losing H2.
- **Preserves H2:** no. **Removes regression:** yes.
- **New ad-hoc:** none.
- **Honest:** "I'd ship this only as an interim while (X) or (Y) is
  designed." H2 is real user value.

### (U) Architectural reframe

The architectural mismatch: the typechecker conflates "a per-call
instantiation that produces a fresh skolem context for this call" with "a
derivation that's identical to the callee's declared type". The fix isn't
a code change — it's recognizing that *every* call site has a per-call
instantiation context, and the solver should treat instantiation as a
first-class deferred operation, not as a function-of-callee-tag. This is
the diagnosis (X) operationalizes.

## Recommendation

**Primary:** **(V) revert H2 immediately, then implement (X) deliberately.**
The bar set by the user — zero ad-hoc, architecture-can-be-wrong — is
satisfied by (X). Shipping it correctly takes a focused session; in the
meantime the regression is a real ongoing harm (9 tests, a high-traffic
narrowing pattern). Reverting H2 is a small change; documenting
HKT-through-records as a known gap (which v1 already did partially in the
H2 commit's "Residual gap" note) preserves the design intent.

**Secondary fallback if (X) won't fit in the next session:** **(Y)** alone
— type-level multi-return flow makes the regression class disappear by
removing the `name_id`-keyed registration that's sensitive to instantiation
timing. (Y) is independently valuable.

## Sizing for recommendation

- **Revert:** ~80-line patch (reverse the H2 hunks in constrain.lua),
  updates to `type_soundness_test.lua` to mark H2a-H2f pending. Walk back
  the "H2 landed" note in `docs/typechecker-hkt-broader.md`. ~1 hour.
- **(X) implementation:** 300-500 LOC, 2-3 focused sessions. New constraint
  kind, rewiring of rank-N + HKT decompose into the solver. Non-trivial
  risk to let-polymorphism phase-2 re-emit.

## Open questions for implementation session

1. For (X), does `try_eager_intrinsic_return`'s TAG_MATCH_TYPE path (used
   by `pcall`) need to stay at gen-time, or does it move to the solver
   alongside the rest? Moving it means pcall-related
   `_last_multi_return_override` becomes a solver-side operation — may
   interact with `narrow_scope` timing.
2. For (Y), do all `_multi_ret` consumers (only
   `propagate_multi_ret_narrowing` and the registration in
   LOCAL/ASSIGN_STMT) cover the full surface? Audit for any
   `ctx._multi_ret` reads not catalogued.
3. Should H2's `C_HKT_DECOMPOSE` predicate widening (the hunk-2/hunk-3
   changes that relax `if hkt_fresh_to_bound and arg_tids` to
   `if arg_tids` and add the TAG_NAMED-as-bound_alias branch) be reverted
   along with the override (hunk-1)? They're independent: the widening
   alone is sound but useless without the override; reverting both is
   cleaner.

## Honest assessment

This recommendation is the least-bad of acceptable options. (X) is what
should ship; revert-and-design-(X) is the responsible interim. V1's
design should not be shipped — it didn't trace the actual mechanism.
The H2 override as-is should not stay — it silently weakens existing
soundness (multi-return correlated narrowing). (Y) is genuinely good but
less confident it covers every regression vector than (X).
