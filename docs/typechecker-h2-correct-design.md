# Typechecker — H2 Correct Design

The principled fix for H2's interaction with multi-return correlated
narrowing. Replaces the override-and-bandaid approach with a separate-channel
design.

## Problem

H2 (HKT record dispatch) was implemented at commit `213d8516` with two
pieces:

1. **`C_HKT_DECOMPOSE` emission predicate widening** — the design's
   recommended approach. Sound on its own.
2. **NODE_CALL_EXPR field-callee resolution override** (~20 lines, NOT in
   the design) — added by the implementing agent as an emergent necessity.
   This is the hack.

The override at `constrain.lua:2697-2717` swaps `callee_tid` from "fresh
TV that will be resolved by C_INDEX later" to "the field's actual function
tid" so that per-call `instantiate` can see the inner forall.

This broke 9 multi-return correlated narrowing tests (`string.find`,
`io.open`). The override perturbs what flows into bindings post-
instantiation: the instantiated copy of the return type diverges from the
un-instantiated `_last_multi_return_override` that multi-return
registration was keyed against.

## Diagnosis

`solve_index` (`solve.lua:1342+`) **does** resolve string-key indexing to
the field's actual tid (line 1384: `unify_mod.unify(ctx, res_tid, ft)`).
The information *is* preserved. The problem is **timing**: C_INDEX runs
in the solver, AFTER constraint generation. By then
`env_mod.instantiate(ctx, callee_tid, ...)` at line 2820 has already
fired on the unresolved fresh TV — instantiating a `TAG_VAR` is a no-op,
so no per-call generic mapping is created. Downstream `solve_check_args`
has a fallback that re-instantiates if `raw_t.tag == TAG_VAR`, but by
then the rank-N skolemization and HKT decomposition have already been
skipped.

The override's lookup (`table_field` via `_var_origin`) is the same
mechanism `peek_callee_ret_union` (`constrain.lua:2538-2581`) uses to
synthesize multi-return shapes. The override duplicates the lookup
instead of reusing the existing helper.

## Why each option is or isn't principled

- **(A) Sequence constraint resolution / WAIT for C_INDEX.** Adds a
  sequencing dependency in the solver: `NODE_CALL_EXPR` would have to
  delay emitting `make_bindgen`/`make_checkargs` until the callee TV is
  resolved. The solver is designed for out-of-order solving via
  deferral; making constraint *generation* wait would require a new
  "deferred emit" mechanism — substantial restructuring, orthogonal to
  the actual problem.

- **(B) C_INDEX delivers the full forall.** Already does. The information
  is in `fe.type_id`. The problem is consumers run *before* C_INDEX has
  fired.

- **(C) Move per-call instantiation later (post-resolution pass).** Almost
  what existing `solve_check_args` lines 2858-2861 do (`if raw_t.tag ==
  TAG_VAR then instantiate`). But rank-N skolemization, HKT decomposition,
  and forall-bound emission all need the instantiation map — they live
  at constraint-gen time. Moving them all to post-resolution means
  restructuring all of them. ~200+ lines moved; fragile.

- **(D) Multi-return registration travels with the type.** Already partly
  true. `_multi_ret` is keyed by `name_id` (a stable binding identifier),
  not TV ids. The override doesn't lose the registration itself, it
  perturbs what flows into the bindings *post*-instantiation.

- **(E) RESOLVE FIELD-CALLEE AT GEN TIME WITHOUT SWAPPING `callee_tid`.**
  The principled fix.

## Recommended design (E)

**Resolve the field's real fn tid at gen-time and pass it as a SEPARATE
channel to the instantiation / rank-N / HKT-decompose codepaths, while
leaving `callee_tid` as the C_INDEX-bound fresh TV.**

Concretely:

1. Compute `resolved_callee_tid` once via the same lookup the override
   does (`table_field` on `_var_origin` source). Move this into a small
   helper `peek_field_callee_tid(ctx, callee_nid)` — there is already
   `peek_callee_ret_union` doing the same shape of lookup at line 2534,
   and `_var_origin` is the canonical mechanism (line 1797).

2. Use `resolved_callee_tid` as the input to:
   - `collect_rank_n_generics` (line 2815)
   - `env_mod.instantiate` (line 2820) — produces `inst_callee` and
     `inst_mapping`
   - The `C_HKT_DECOMPOSE` walk (line 2880+)
   - `try_eager_intrinsic_return` (line 3029) — already takes
     `inst_callee`

3. Leave `callee_tid` (the fresh TV) untouched for:
   - `M.make_bindgen(callee_raw_for_solver, ...)` and
     `M.make_checkargs(callee_raw_for_solver, ...)` — but pass
     `inst_callee` (the instantiated copy) rather than the fresh TV. The
     current code already does this: `emit(ctx, M.make_bindgen(inst_callee,
     ...))` at line 3014. The solver branches at `raw_t.tag == TAG_VAR`
     (lines 2720, 2858) become unnecessary for field-callee — they remain
     for genuine "callee is a local TV" cases (method dispatch).
   - The C_INDEX constraint that `NODE_FIELD_EXPR` already emitted (line
     1794) — this still fires, still binds the fresh TV to the real fn
     tid, but is now redundant for type checking. It can remain as a
     no-op consistency emission, or be elided when the field is concrete
     (small cleanup, not required for correctness).

4. `peek_callee_ret_union` (line 2538-2581) and the field-callee
   `_var_origin` plumbing already exist — the recommended design
   **reuses these mechanisms**, removing the special case the override
   introduced.

### Why this is principled

- **No new constraint kind, no sequencing change, no special-case in
  solver.** All changes are local to constraint generation.
- **`callee_tid` retains its original semantics:** the TV that flows
  through C_INDEX, which is what consumers downstream of `_var_origin`
  (e.g. `peek_callee_ret_union`'s TAG_VAR fallback at line 2543-2551) and
  the multi-return narrowing registration all expect.
- **The forall structure is exposed only where it's needed**
  (instantiation, rank-N, HKT decompose). The fresh-TV channel that
  feeds multi-return narrowing is undisturbed.
- **Removes a duplicated lookup**, not adds one. The H2 override and the
  existing `peek_callee_ret_union` do the same `table_field` lookup;
  consolidating them into one named helper is a net simplification.
- **Generalizes naturally** to method-call shape (`NODE_METHOD_CALL` has
  its own copy of similar logic at line 3048+; same helper applies).

## Dispatch sites that change

- `lib/type/static/constrain.lua:2697-2717` — the H2 override block:
  replace `callee_tid = fe_tid` with
  `local resolved_callee_tid = fe_tid` (compute once, don't swap).
- `lib/type/static/constrain.lua:2815, 2820` — `collect_rank_n_generics`
  and `instantiate` take `resolved_callee_tid` (or `callee_tid` if no
  override applied).
- `lib/type/static/constrain.lua:2880+` — HKT decompose walk uses
  `ic = ctx.types:get(inst_callee)` which is already correct (it walks
  the instantiated copy).
- `lib/type/static/constrain.lua:3014-3015` — `make_bindgen`/
  `make_checkargs` already pass `inst_callee`. The `callee_raw` argument
  inside solver (`solve.lua:2704, 2807`) currently reads back to detect
  "was a TV at gen time". With the principled fix, the solver's
  `if raw_t.tag == TAG_VAR then re-instantiate` branch
  (`solve.lua:2720-2723, 2858-2861`) becomes dead for field-callee — safe
  to leave for non-field cases.

## Test-pinning strategy

1. Run `bin/cr test lib/type/static/type_test.lua` and
   `type_soundness_test.lua` — expect all 1683 + H2's 6 new pins to pass.
2. Add a regression pin in `type_test.lua` mirroring the multi-return
   correlated narrowing case under a new describe
   `"H2 + multi-return correlation interaction"`.
3. Pin the existing H2a-H2f tests (already in `type_soundness_test.lua`)
   unchanged.

## Implementation order

1. Extract `peek_field_callee_tid(ctx, callee_nid)` helper — pure
   refactor, consolidates the duplicated `table_field` lookups in
   `NODE_CALL_EXPR` override and `peek_callee_ret_union`.
2. Replace the H2 override block (`constrain.lua:2697-2717`) with:
   `local resolved_callee_tid = peek_field_callee_tid(ctx, callee_nid) or callee_tid`.
3. Update `collect_rank_n_generics` and `instantiate` call sites to use
   `resolved_callee_tid`.
4. Verify the `C_HKT_DECOMPOSE` relaxation at line 2880 (`if arg_tids
   then`) still functions — it operates on `inst_callee`, which is now
   produced from `resolved_callee_tid`. Should be unchanged.
5. Run test suites; verify H2a-H2f pins + multi-return pins both pass.
6. (Optional cleanup) Elide redundant C_INDEX emission in
   `NODE_FIELD_EXPR` when the field is statically resolvable and the
   result is used only as a call callee.

## Sizing

~30 lines net change. The override block (20 lines) is replaced by a
helper call (1 line); call-site argument plumbing (~5 sites, 1 line
each); new helper (~15 lines extracted from existing duplicated code).

## Open questions

1. Should `peek_field_callee_tid` also handle `NODE_METHOD_CALL`
   (currently has its own field lookup at `constrain.lua:3084-3114`)?
   Consolidating may simplify, but methods bind receiver as arg 0 —
   different shape.
2. When `_var_origin`'s `obj_tid` is itself an unresolved `require()`'d
   module (`_require_exports` fallback at line 2448-2455), does the
   helper need the same fallback?
3. Does the cleanup of redundant C_INDEX emission belong in this change
   or as follow-up? (Recommend: follow-up — keep the principled fix
   minimal.)
4. How does this interact with intersection callees (overload dispatch —
   `solve_check_args` line 2998+)? Field of overloaded fn type. Likely
   orthogonal; the override didn't address it either.
5. Are there other call shapes where `gen_expr(callee_nid)` returns a
   fresh-TV-awaiting-C_INDEX that hides a forall? (`NODE_INDEX_EXPR` with
   literal key path: `t["find"]` — `constrain.lua:1865-1873` also emits
   C_INDEX with fresh res. Same fix may apply.)

## Status

Designed 2026-05-17. Replaces the override-and-bandaid options (a/b/c
listed in the cross-file regression investigation). Can land incrementally
on top of `213d8516`; no revert required. Preserves H2's functionality.
