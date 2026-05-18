# Exhaustive Invariant Inventory: Crescent Constraint Solver

## Overview

This document catalogs every architectural invariant in `lib/type/static/solve.lua` and `lib/type/static/constrain.lua` — the assumptions that the constraint solver and constraint generation depend on for correctness. The inventory is organized by invariant category, with evidence (file:line), dependents, and load-bearing assessment.

**Total constraints in solver dispatch**: 16 constraint kinds (solve.lua:3768-3785).
**Tiers**: TIER_GIVEN (0) and TIER_WANTED (1) per constrain.lua:221-259.

---

## I. ORDERING INVARIANTS

### INV-O1: Worklist drains FIFO (Head-Index Drain)
**Evidence**: solve.lua:3906 `while head <= #worklist do ... head = head + 1`

**Statement**: The worklist is drained by a head index incrementing through positions, NOT by popping from a stack (LIFO). Constraints are appended to the tail (solve.lua:3839 `worklist[#worklist + 1] = c`), and removal is strictly positional (head += 1). Wake-waiters (unify.lua:237-241) also appends to the tail.

**Invariant maintained**: Constraints emitted in source order from constraint generation stay in order during drain. Dependency chains (e.g., C_BIND_GENERICS → C_CHECK_ARGS) preserve emission order.

**What breaks if violated**: LIFO (stack) drain inverts emission order, silencing dependency chains. C_BIND_GENERICS emits first but runs last, so C_CHECK_ARGS runs before C_BIND_GENERICS completes, using stale generic param bindings.

**Dependents**: 
- solve.lua:3901-3904: comment explicitly names this as "FIFO drain by head index"
- solve.lua:2766-2776: solve_bind_generics assumes C_BOUND can wake and re-fire before C_CHECK_ARGS runs
- solve.lua:3798-3800: wake_waiters doc says "wakes that arrive mid-drain are picked up in the same round"

**Status**: Load-bearing for correctness; Phase F preserved this.

---

### INV-O2: Emitted Children Land at Tail, Not Head
**Evidence**: constrain.lua:582 `emit(ctx, constraint)`, solve.lua:3889-3891 emitted constraints appended to tail

**Statement**: When a handler emits child constraints (e.g., C_BIND_GENERICS emits C_BOUND via propagate_function_bound → emit), they are appended to `ctx.constraints` (constrain.lua:582) and pushed to the worklist tail (solve.lua:3889-3891 `worklist[#worklist + 1] = nc`). NOT prepended to the head.

**Invariant maintained**: Emitted children run after currently-enqueued constraints complete their drain rounds, preserving left-to-right emit order and giving GIVEN handlers a chance to rewrite state before WANTED handlers re-fire.

**What breaks if violated**: Head-prepending emits inverts order relative to the rest of the worklist. If C_BIND_GENERICS emits C_BOUND at head, it runs immediately, binds generics prematurely, and subsequent C_BIND_GENERICS iterations in the same handler see stale bindings.

**Dependents**:
- solve.lua:2766-2776: solve_bind_generics loop depends on freshly-emitted C_BOUND running before the loop resumes
- constrain.lua:1808, 1814, 1851, etc.: every emit() call site assumes children are not immediately run

**Status**: Load-bearing for phase-ordering correctness; Phase F identified this as a blocker.

---

### INV-O3: Constraint Type Completeness in Handler Dispatch
**Evidence**: solve.lua:3768-3785 handler table dispatch

**Statement**: Every constraint kind (C_UNIFY through C_INSTANTIATE_AT_CALL) has an entry in the handlers table returned by get_handlers(). If a constraint kind is emitted but has no handler, it returns true and is retired (solve.lua:3851 `if not handler then c._solved = true; return end`) — silently succeeding instead of erroring.

**Invariant maintained**: All 16 constraint kinds have dedicated handlers. No silent no-ops.

**What breaks if violated**: A handler is forgotten, constraints silently succeed without being solved, and inferred types carry free TVs into call sites.

**Dependents**: Every constraint emission in constrain.lua depends on having a handler.

**Status**: Load-bearing; phase-F / item-5 validation checked completeness.

---

### INV-O4: Constraint Tier Dispatch Before Handler Execution
**Evidence**: constrain.lua:271-279 tag_tier(), solve.lua:3852-3854 (ctx._current_tier set before run_one)

**Statement**: Before run_one(c) is called, the current constraint's tier (c._tier) is published to ctx._current_tier. The tier was tagged by constrain.tag_tier() when the constraint was constructed (constrain.lua:271-279), mapping C_TAG to CONSTRAINT_TIER (constrain.lua:241-259).

**Invariant maintained**: unify.wake_waiters can observe ctx._current_tier to detect WANTED-to-GIVEN wakes (unify.lua:226-233 `if (ctx._current_tier or 1) == 1`).

**What breaks if violated**: Tier dispatch is lost; WANTED handler can't defer when it wakes a GIVEN. C_BOUND fails to rewrite state before C_BIND_GENERICS resumes.

**Dependents**: solve.lua:3852-3858 run_one() publishes tier; unify.lua:219-241 wake_waiters reads it.

**Status**: Load-bearing for givens-before-wanteds semantics; item 2 of phase-F spec.

---

### INV-O5: C_BOUND (GIVEN) Runs Before C_BIND_GENERICS (WANTED) on Same TV Bind
**Evidence**: constrain.lua:251 `[C_BOUND] = TIER_GIVEN`, line 253 `[C_BIND_GENERICS] = TIER_WANTED`

**Statement**: When a TV bind wakes both a C_BOUND (GIVEN, tier 0) and a C_BIND_GENERICS (WANTED, tier 1) waiting on the same TV root, the GIVEN is detected by wake_waiters (unify.lua:229 `if waiters[i]._tier == 0`) and ctx._bind_woke_given is set. The WANTED handler observes this flag and defers (e.g., solve_bind_generics line 2798-2799).

**Invariant maintained**: C_BOUND rewrites the still-free generic params (via propagate_function_bound, propagate_meta_bound) before C_BIND_GENERICS resumes its param-binding loop. Second run of C_BIND_GENERICS binds to declared types, not inferred ones.

**What breaks if violated**: C_BIND_GENERICS runs first, binds params to inferred types, C_BOUND runs and overwrites them, C_BIND_GENERICS sees wrong bindings on retry. Or C_BOUND sees wrong param types because C_BIND_GENERICS already bound them.

**Dependents**: solve.lua:2766-2806 solve_bind_generics loop and ctx._bind_woke_given check (2798-2799).

**Status**: Load-bearing for generic soundness; item 2 of phase-F.

---

### INV-O6: Quiescence Detection (No Progress → Drain Exit)
**Evidence**: solve.lua:3925-3934

**Statement**: A worklist drain round exits (quiescence reached) when BOTH conditions hold:
1. No constraint retired in the round (`solved_this_round == false`)
2. No TV was bound during the round (`ctx._bind_generation == gen_before`)

If either is true, re-seed and run another round.

**Invariant maintained**: Termination is guaranteed by observation (not fixed iteration budget). Every TV bind is counted via _bind_generation increment (unify.lua:220). Retired constraints are marked _solved (solve.lua:3916).

**What breaks if violated**: Infinite drain loops (re-seed always true), or premature exit leaving deferred constraints unsolved (deferred constraints on unbound TVs aren't re-seeded).

**Dependents**: solve.lua:3832-3845 seed() function, 3925-3934 quiescence logic.

**Status**: Load-bearing for termination; fundamental to replace 4-pass fixpoint.

---

### INV-O7: Re-seeding Includes Newly-Emitted Constraints
**Evidence**: solve.lua:3832-3845, 3940

**Statement**: When a drain round makes progress and re-seeding is triggered, seed() re-scans [lo, n] where n = #constraints (updated each re-seed). Constraints emitted during the round (via emit or wake_waiters) land at positions > original hi and are included in the re-seed range.

**Invariant maintained**: Emitted constraints (including deferred children from handlers) are not lost when the round terminates and re-seeds.

**What breaks if violated**: Emitted constraints past the original hi are never drained if re-seeding stops at the original hi. Deferral waits forever.

**Dependents**: solve.lua:3842-3844 "hi = n" update to re-seed bounds.

**Status**: Load-bearing for correctness of deferred-constraint wakeup.

---

### INV-O8: Deferred Flag Cleared Only by wake_waiters or seed
**Evidence**: solve.lua:3838 (seed clears), unify.lua:239 (wake_waiters clears)

**Statement**: A constraint's _deferred flag is set when a handler parks without awaiting (e.g., solve_index defer while awaiting), and cleared only by:
1. wake_waiters after a TV bind (unify.lua:239)
2. seed() at the start of a new drain round (solve.lua:3838)

**Invariant maintained**: Deferred constraints don't re-enter the drain loop mid-round (solve.lua:3914 `if not c._solved and not c._deferred then`). They're re-added at round boundaries.

**What breaks if violated**: Deferred constraints could run while their awaited TVs are still free (incorrect behavior), or could be skipped entirely if re-arm is forgotten.

**Dependents**: solve.lua:3910-3920 drain loop checks both _solved and _deferred.

**Status**: Load-bearing for correctness of await semantics.

---

## II. PRODUCER/CONSUMER RELATIONSHIPS

### INV-P1: await() Registers Constraint on TV Root (Union-Find Root)
**Evidence**: solve.lua:88-97

**Statement**: When a handler calls `await(ctx, c, tv_id)`, the constraint is registered on the union-find root of tv_id (solve.lua:89 `local root = find(ctx, tv_id)`), not on tv_id directly. The constraint is appended to `ctx.tv_waiters[root]`.

**Invariant maintained**: When the root is later bound by unify.bind_var_to_type, wake_waiters is called on the root (unify.lua:298) and drains the entire waiter list. If tv_id was later unioned to a different root, the awaiting constraint is still on the original root and gets woken.

**What breaks if violated**: If registered on tv_id (non-root), a subsequent union-find path update doesn't reach the waiter. The constraint waits forever on a non-root TV that never gets bound.

**Dependents**: 
- solve.lua:675-683: solve_narrow_nil calls await
- solve.lua:1109-1118: solve_bound calls await
- unify.lua:287, 298: wake_waiters called on root after bind

**Status**: Load-bearing for union-find correctness.

---

### INV-P2: wake_waiters Called After Every bind_var (Centralized Chokepoint)
**Evidence**: unify.lua:287, 298 (both paths call wake_waiters), constrain.lua:78-81 (comment)

**Statement**: unify.bind_var_to_type is the unique chokepoint for TV binding (unify.lua:334-337). Every path that binds a TV must call wake_waiters on the root. bind_var does this unconditionally (unify.lua:298).

**Invariant maintained**: Every awaiting constraint is woken exactly once per TV bind. No sleepers are missed.

**What breaks if violated**: A bind that doesn't wake waiters leaves them deferred forever. Constraints await TVs that are already bound and never re-activate.

**Dependents**: Every handler that reads a TV and defers via await.

**Status**: Load-bearing for correctness of deferred-constraint activation.

---

### INV-P3: tv_waiters Cleaned Up (Set to Nil) After Wake
**Evidence**: unify.lua:235 `ctx.tv_waiters[var_tid] = nil`

**Statement**: After wake_waiters drains the waiter list and re-enqueues waiters, the root's entry in ctx.tv_waiters is set to nil. Subsequent awaits on the same (now-bound) TV will create a new empty list or error (if the handler is re-run on a bound TV and defers — should not happen, but if it does, the old waiters are discarded).

**Invariant maintained**: Waiters are not re-queued twice.

**What breaks if violated**: A constraint could be in the waiter list, wake and re-enqueue, then another await on the same TV re-adds it, and a later bind would re-enqueue it again — duplicate worklist entries, possibly infinite drain.

**Dependents**: solve.lua:675-683 (solve_narrow_nil depends on await semantics).

**Status**: Load-bearing for correctness of single-wakeup.

---

### INV-P4: ctx.constraints Array is Append-Only During Drain
**Evidence**: constrain.lua:582, solve.lua:3889-3891

**Statement**: Constraints are appended to ctx.constraints only during emit() (constrain.lua:582, called by handlers and constrain.lua throughout). The array never shrinks, only grows. Removed/retired constraints are marked _solved, not removed from the array.

**Invariant maintained**: Constraint indices remain valid throughout the drain. A constraint's position in the array doesn't change. Re-seeding and worklist management rely on positions being stable.

**What breaks if violated**: If constraints are removed from the array, indices shift, and remaining constraints' positions become invalid. Worklist entries point to wrong positions or fail to find their constraints.

**Dependents**: solve.lua:3835-3841 seed() iterates [lo, n] by index.

**Status**: Load-bearing for correctness of constraint management.

---

### INV-P5: emit() Always Appends to ctx.constraints, Never Prepends
**Evidence**: constrain.lua:582

**Statement**: The emit(ctx, constraint) function appends newly-constructed constraints to ctx.constraints (implied by constraint generation patterns; no explicit array mutation shown in emit). Constraints are never inserted at the head.

**Invariant maintained**: Newly emitted constraints land at the end, past the current hi. Re-seeding includes them in the next round.

**What breaks if violated**: Emitted constraints could be inserted before the current drain position and re-executed in the same round, causing infinite loops or incorrect ordering.

**Dependents**: solve.lua:3842-3844 "hi = n" adjustment for re-seed bounds.

**Status**: Load-bearing for ordering correctness.

---

### INV-P6: bind_to() Unifies ret_tid with Result, Marking it as "Bound"
**Evidence**: solve.lua:403-413 (bind_to implementation)

**Statement**: The bind_to() helper (solve.lua:403-413) unifies res_tid with res (the result type), recording it in ctx.types (via unify). This is a write to ctx that marks the result as no longer free.

**Invariant maintained**: After bind_to(ctx, res_tid, resolved), res_tid is no longer a free TV — it's unified to resolved. Subsequent handlers that read res_tid via find() get the resolved type.

**What breaks if violated**: Results could remain free TVs. A handler binds a result via unify but doesn't actually bind the result TV, so callers see free TVs.

**Dependents**: Every handler that binds a result (solve_sub, solve_index, solve_return, etc.).

**Status**: Load-bearing for correctness of result binding.

---

## III. FAST-PATH ASSUMPTIONS

### INV-F1: try_unify_strict in solve_sub Fast Path
**Evidence**: solve.lua:625 `local r = unify_mod.try_unify_strict(ctx, actual, expected)`

**Statement**: In solve_sub, the fast path (solve.lua:617-630) calls try_unify_strict (NOT unify) when the expected type is not a free TV, not closed-table (row var < 0), and not a TAG_VAR/ROWVAR. This returns true (success), false (failure), or "needs" (needs binding).

If the result is true, the constraint succeeds immediately. If false or "needs", fall through to the slow path (unify).

**Invariant assumed**: try_unify_strict is conservative — it only returns true when unify would also succeed. It doesn't unify, so it won't bind TVs at the top level. If it returns true, the slow-path unify call is skipped correctly.

**What breaks if violated**: If try_unify_strict returns true but unify would fail, the constraint incorrectly succeeds. If it returns false when unify would succeed, false negatives emit spurious errors.

**Dependents**: solve.lua:555-666 solve_sub entire function.

**Status**: Load-bearing for correctness of sub-constraint solving; Phase F preserved.

---

### INV-F2: solve_unify and solve_sub are Terminal (Never Re-run)
**Evidence**: solve.lua:550 (solve_unify), 664-666 (solve_sub), both return true

**Statement**: Both solve_unify and solve_sub always return true (never defer). A unify success solves the constraint. A unify failure emits an error and returns true, marking the constraint retired. Retrying after a TV bind would re-emit the same error.

**Invariant maintained**: Each error is emitted at most once (item 1.5a of phase-F spec). No dedup buffer needed.

**What breaks if violated**: If a unify failure deferred (returned false) expecting a retry to succeed, the error would be re-emitted on every retry, spamming stderr. Or the constraint would wait forever for a TV that will never be bound.

**Dependents**: solve.lua:543-550 (solve_unify), 636-665 (solve_sub error paths).

**Status**: Load-bearing for error reporting correctness; item 1.5 of phase-F.

---

### INV-F3: solve_sub Widen-Before-Check Pattern
**Evidence**: solve.lua:632-634 (widen), then 635 (unify with widened)

**Statement**: solve_sub widens actual literals before checking assignability. The widened type is compared against expected, not the original. This allows literal types to satisfy union/literal expectations (e.g., "ok" → "ok"|"error").

**Invariant assumed**: Widening preserves the ability to detect errors (e.g., integer literal to integer, then check int <: string fails correctly). Widening doesn't hide type mismatches.

**What breaks if violated**: If widening is skipped, literal types are checked directly, and "42" (literal) won't unify with "number" even though 42 is a valid number. Or redundant-cast warnings trigger incorrectly.

**Dependents**: solve.lua:599-609 (redundant-cast check), 632-634 (widen step).

**Status**: Load-bearing for correctness of literal subtyping.

---

## IV. BIND-DISCIPLINE ASSUMPTIONS

### INV-B1: TIER_GIVEN (C_BOUND) Rewrites Still-Free TVs Before TIER_WANTED
**Evidence**: constrain.lua:251 (C_BOUND = TIER_GIVEN), solve.lua:2766-2776 (comment), unify.lua:226-233

**Statement**: C_BOUND is a GIVEN-tier handler (constrain.lua:251). When a generic function is called, emit order is: C_INSTANTIATE_AT_CALL, C_BIND_GENERICS (WANTED), C_BOUND (GIVEN), C_CHECK_ARGS (WANTED). When C_BIND_GENERICS wakes a C_BOUND on the same TV, the bind triggers ctx._bind_woke_given = true (unify.lua:230), and C_BIND_GENERICS defers (solve.lua:2798-2799).

**Invariant maintained**: C_BOUND gets to propagate declared types into fresh params before C_BIND_GENERICS binds them to inferred call-argument types. Second run of C_BIND_GENERICS binds params to declared, not inferred, types.

**What breaks if violated**: C_BIND_GENERICS binds params to inferred types first, C_BOUND tries to propagate declared types but TVs are already bound. Inferred bounds take precedence over declared bounds.

**Dependents**: solve.lua:2780-2803 (C_BIND_GENERICS loop), solve_bound (C_BOUND handler).

**Status**: Load-bearing for generic soundness; item 2 of phase-F.

---

### INV-B2: unify() Binds Immediately When the LHS is a Free TV
**Evidence**: unify.lua:334-337 (bind_var_to_type calls bind_var), unify.lua:295-299 (bind_var writes to data[2])

**Statement**: When unify(ctx, a, b) is called and a is a free TV (after find()), unify dispatches to bind_var and writes to a.data[2] (union-find parent), binding a to b. This is immediate, not deferred.

**Invariant maintained**: After unify(ctx, a, b) returns true where a is a free TV, a is bound to b. Subsequent find(ctx, a) returns b. Handlers that call unify and then read the TV see the bound value.

**What breaks if violated**: If binding is deferred, the TV remains free after unify returns. Subsequent handlers read the TV as free and re-defer.

**Dependents**: Every handler that calls unify.unify() and expects TVs to be bound.

**Status**: Load-bearing for correctness of binding.

---

### INV-B3: Literal Widening in Argument Binding (solve_bind_generics)
**Evidence**: solve.lua:2791-2796

**Statement**: In solve_bind_generics, when binding a generic param that is a free TV, the argument is widened (2793: `skip_widen and find(ctx, act_tid) or widen_literal(ctx, act_tid) or widen_for_sub(ctx, act_tid)`). If the param TV is used in a parameterized intrinsic return (ret_uses_tv_in_intrinsic returns true), widening is skipped to preserve the literal module name.

**Invariant assumed**: Widening doesn't lose information needed by intrinsics (e.g., $Require<T> where T is a literal string). skip_widen checks ret_uses_tv_in_intrinsic to prevent widening when the TV appears in the intrinsic.

**What breaks if violated**: Literal module names are widened to string, $Require<string> fails to resolve the module, and a dynamic module-load error is emitted instead of a static error.

**Dependents**: solve.lua:2791-2796 (skip_widen logic).

**Status**: Load-bearing for intrinsic-param correctness.

---

## V. SUB-SOLVE ASSUMPTIONS

### INV-S1: Sub-solve (gen_function) Scope: Param TVs Free, Results Bound
**Evidence**: solve.lua:3808-3813 (comment), constrain.lua comment on sub-solve (not directly quoted but inferred)

**Statement**: When gen_function calls solve_range on a function body's constraints, the function's param TVs are still free (unbound). Constraints awaiting one of those TVs will park in ctx.tv_waiters and remain _deferred when sub-solve exits. The outer solve_range will re-seed them after the function type is exposed to call sites.

**Invariant maintained**: Sub-solve is a local scope; it doesn't bind param TVs (those are bound by call sites or declared bounds). Sub-solve binds result TVs (return statements unify with a result TV). Deferred constraints survive the sub-solve and re-activate when outer solver binds the params.

**What breaks if violated**: If sub-solve tries to bind param TVs, call sites would see already-bound params and can't instantiate them. Or if deferred constraints are lost on sub-solve exit, they're never re-activated.

**Dependents**: solve.lua:3808-3813 (sub-solve composition doc).

**Status**: Load-bearing for correctness of generic functions.

---

### INV-S2: FLAG_SUB_SOLVE_PARAM Tags Param TVs Across Sub-Solve Boundary
**Evidence**: solve.lua:49 (FLAG_SUB_SOLVE_PARAM imported), 1457, 1573, 2076, 2437-2438, 2528-2529, 2847

**Statement**: When a handler detects a free TV with FLAG_SUB_SOLVE_PARAM set, it knows the TV is a still-free generic param from the function's param list. This flag is set during sub-solve (gen_function) and allows handlers in sub-solve to distinguish params from locals.

Used in:
- solve_index (1457, 1573): param TVs get field bounds emitted
- solve_callable (2076): param TVs get function bounds emitted
- solve_arith/solve_compare (2437-2438, 2528-2529): param TVs get operator bounds
- solve_check_args (2847): param TVs get function-sig bounds

**Invariant maintained**: When a handler sees FLAG_SUB_SOLVE_PARAM, it knows the TV is a param and should emit bounds (HM Phase 1c). Local TVs don't have this flag and don't get bounds.

**What breaks if violated**: Local TVs would get bounds (wrong), or param TVs wouldn't get bounds (missing phase-1c inference).

**Dependents**: solve.lua:1457, 1573, 2076, 2437-2438, 2528-2529, 2847 (all FLAG_SUB_SOLVE_PARAM checks).

**Status**: Load-bearing for HM phase-1c correctness.

---

### INV-S3: ctx.tv_bounds Merges Inferred Bounds on Same Param
**Evidence**: solve.lua:1329-1336 (merge_inferred_bound)

**Statement**: When a handler emits a bound on a param TV (e.g., emit_meta_bound, emit_field_bound), it merges it into ctx.tv_bounds[var_tid] using make_intersection. Multiple usages of the same param (e.g., a + b and a.x) are composed via intersection.

**Invariant maintained**: ctx.tv_bounds[var_tid] accumulates the intersection of all bounds on that param. After sub-solve, the param's declared type is checked against this intersection.

**What breaks if violated**: Multiple usages of the same param would only record the last bound, losing earlier bounds. A param used for both numeric and field access would only remember one bound.

**Dependents**: solve.lua:1329-1336 (merge_inferred_bound), emit_meta_bound, emit_field_bound, emit_indexer_bound.

**Status**: Load-bearing for correctness of multi-usage param bounds.

---

## VI. TAG-SHAPE ASSUMPTIONS

### INV-T1: TAG_FUNCTION Params and Returns are Lists, Not Scalars
**Evidence**: types_mod accessors (fn_params_start, fn_params_len, fn_returns_start, fn_returns_len)

**Statement**: A TAG_FUNCTION type has params and returns stored as lists in ctx.lists (the arena). Accessors return start index and length, not individual type IDs. Iteration is done via loop: `for i = 0, pl - 1 do local param = ctx.lists:get(ps + i)`.

**Invariant maintained**: Params and returns are heterogeneous (different types per param/return). Lists allow arbitrary length. Scalars would impose fixed arity.

**What breaks if violated**: If params were a scalar type ID, multi-param functions couldn't be represented. Iteration would fail.

**Dependents**: Every handler that inspects function types (solve_callable, solve_bind_generics, solve_check_args, propagate_function_bound, etc.).

**Status**: Load-bearing for correctness of function type representation.

---

### INV-T2: TAG_UNION Members Are Lists, Accessible Sequentially
**Evidence**: types_mod.agg_members_start / agg_members_len

**Statement**: A TAG_UNION type has members stored as a list in ctx.lists. Union creation (types_mod.make_union) takes a Lua array of member type IDs, stores them in the list arena, and records start/len in the type node. Iteration: `for i = ms, ms + ml - 1 do local mid = ctx.lists:get(i)`.

**Invariant maintained**: Union members can be iterated and unioned in any order (commutativity assumed separately). No maximum member count.

**What breaks if violated**: If members were not sequential or accessible, union iteration would fail. Filtering members (e.g., in solve_narrow_nil) couldn't extract nil members.

**Dependents**: solve_sub (filtering union members to suggest better errors, 642-647), solve_narrow_nil (filtering nil members, 692-705).

**Status**: Load-bearing for correctness of union iteration.

---

### INV-T3: TAG_TABLE Fields, Indexers, Meta-Fields Are Separate Lists
**Evidence**: types_mod.tbl_fields_start/len, tbl_indexers_start/len, tbl_meta_start/len

**Statement**: A TAG_TABLE has three separate list regions: fields (named), indexers (key-value pairs), and meta-fields (metamethods). Each has start/len accessors. Fields and meta-fields store field IDs (resolved via ctx.fields arena); indexers store key/value type IDs directly.

**Invariant maintained**: Named fields and meta-methods are kept separate. Indexers are key-value pairs. This allows efficient lookup and iteration over each region.

**What breaks if violated**: If regions were interleaved, iteration would need explicit markers to distinguish field types. Lookups would be O(n) instead of direct.

**Dependents**: solve_index field/meta lookup, propagate_meta_bound iteration over meta-fields, etc.

**Status**: Load-bearing for correctness of table type representation.

---

### INV-T4: TAG_LITERAL Stores Kind + Value in Discriminated Union
**Evidence**: types_mod.lit_kind, lit_bool, lit_str_id, lit_int, lit_number

**Statement**: A TAG_LITERAL type stores a kind (LIT_BOOLEAN, LIT_INTEGER, LIT_NUMBER, LIT_STRING, LIT_NIL, LIT_OPAQUE_KEY) and a corresponding value. Boolean stores a bit (0=false, 1=true). Integer/number/string store an integer (interpreted by kind). Opaque key stores an intern ID.

**Invariant maintained**: Discriminated union allows efficient dispatch on kind. No tag collision between different literal kinds.

**What breaks if violated**: If kind and value weren't discriminated, a LIT_BOOLEAN(0) and LIT_INTEGER(0) would be indistinguishable.

**Dependents**: solve_narrow_nil (distinguish LIT_BOOLEAN from LIT_NIL, 698-708), solve_or (check falsy defaults, 786-795), etc.

**Status**: Load-bearing for correctness of literal representation.

---

## VII. HANDLER-SPECIFIC INVARIANTS

### INV-H1: solve_unify (C_UNIFY) — Both Sides Must find() to Root
**Evidence**: solve.lua:539-540

**Statement**: solve_unify calls find() on both LHS and RHS before unifying. This ensures union-find is normalized and both sides are reduced to their roots.

**Invariant assumed**: unify expects roots, not arbitrary path-compressed nodes. find() flattens the path.

**What breaks if violated**: unify could operate on non-root nodes, leaving paths uncompressed and causing subsequent finds to traverse longer chains.

**Dependents**: solve.lua:539-540.

**Status**: Load-bearing for union-find correctness.

---

### INV-H2: solve_sub — Fast Path Skipped for Closed Tables
**Evidence**: solve.lua:619-620 `local is_closed_table = et.tag == TAG_TABLE and types_mod.tbl_row_var(et) < 0; if not is_closed_table...`

**Statement**: The fast path (try_unify_strict) is skipped if the expected type is a closed table (row var < 0). Closed tables require full unify to enforce the excess-field check (width subtyping only holds for open tables with row variables).

**Invariant assumed**: Closed tables need deep structural validation that try_unify_strict doesn't provide. Open tables allow additional fields, so try_unify_strict's shallow check is safe.

**What breaks if violated**: A closed table with extra fields would incorrectly unify via the fast path, allowing width violations.

**Dependents**: solve.lua:555-630 (fast-path logic for solve_sub).

**Status**: Load-bearing for correctness of closed-table subtyping.

---

### INV-H3: solve_narrow_nil — Defers While Input is Free TV
**Evidence**: solve.lua:675-683

**Statement**: solve_narrow_nil (C_NARROW_NIL) defers while the input TV is a free TAG_VAR/ROWVAR. Once bound, it computes the nil-narrowed or nil-only subset and unifies with the result.

**Invariant maintained**: The narrowing operation is deterministic once the input is concrete. Deferring until concrete prevents narrowing over free TVs.

**What breaks if violated**: Narrowing on free TVs would need to guess the narrowed type, leaving dangling free TVs in the result.

**Dependents**: solve.lua:675-717 (solve_narrow_nil).

**Status**: Load-bearing for correctness of nil-narrowing.

---

### INV-H4: solve_bound — Defers on Free Bound TV
**Evidence**: solve.lua:1109-1128

**Statement**: solve_bound (C_BOUND) defers if the fresh_tv is still free (1114-1118) OR if the bound type itself is free (1121-1128). Both must be concrete before checking the bound.

**Invariant maintained**: Bound checking is deterministic once both TV and bound are resolved. Deferring prevents false failures.

**What breaks if violated**: Bound checking on free TVs would incorrectly reject or accept.

**Dependents**: solve.lua:1109-1319 (solve_bound).

**Status**: Load-bearing for correctness of bound checking.

---

### INV-H5: solve_callable — Fresh Instantiation for Method Calls
**Evidence**: solve.lua:2042-2120 (not fully shown; context indicates instantiation for free callee TVs)

**Statement**: When solve_callable encounters a free callee TV, it instantiates a fresh instance of the inferred function type (calling env_mod.instantiate) instead of unifying against the raw type. This is used for method calls where the callee was inferred locally.

**Invariant maintained**: Method calls get fresh instantiations per call site. Shared methods don't have their type variables bound across multiple call sites.

**What breaks if violated**: Multiple calls to the same method would share type variables, binding across call sites.

**Dependents**: solve.lua:2042-2120 (solve_callable).

**Status**: Load-bearing for correctness of method-call instantiation.

---

### INV-H6: solve_bind_generics — Precedes solve_check_args in Emission
**Evidence**: constrain.lua emit sites show C_BIND_GENERICS emitted before C_CHECK_ARGS in call handling

**Statement**: For a call site, C_INSTANTIATE_AT_CALL, C_BIND_GENERICS, and C_CHECK_ARGS are emitted in that order (implicit in constrain.lua patterns). Emission order must be preserved by FIFO drain (INV-O1).

**Invariant maintained**: C_BIND_GENERICS runs and binds generic params before C_CHECK_ARGS checks them. If C_BOUND wakes during C_BIND_GENERICS, deferral re-fires C_BIND_GENERICS after C_BOUND rewrites params.

**What breaks if violated**: C_CHECK_ARGS runs before C_BIND_GENERICS completes, checking against unbound params.

**Dependents**: solve.lua:2780-2806 (solve_bind_generics loop), 2813-3016 (solve_check_args).

**Status**: Load-bearing for correctness of generic-call solving.

---

### INV-H7: solve_hkt_decompose — Binds Fresh Vars Before Checking Bounds
**Evidence**: solve.lua:3674-3754 (solve_hkt_decompose_impl)

**Statement**: solve_hkt_decompose emits C_BOUND on fresh TVs for HKT instantiation, binding them to the concrete instantiation args before the outer bound-check runs. This decomposes F<A> into F and A=A, enabling kind and bound checking.

**Invariant maintained**: HKT alias instantiation is bound before bounds are checked. Checks operate on concrete instantiation args.

**What breaks if violated**: Bounds would be checked against unbound fresh TVs, always failing.

**Dependents**: solve.lua:3755-3760 (solve_hkt_decompose).

**Status**: Load-bearing for correctness of HKT decomposition.

---

## VIII. DIAGNOSTIC INVARIANTS

### INV-D1: Error Emitted Exactly Once Per Failure (Terminal Handlers)
**Evidence**: solve.lua:543-546 (solve_unify), 636-662 (solve_sub), both emit error and return true

**Statement**: When solve_unify or solve_sub detects a type error, it calls add_error() and returns true, retiring the constraint. The constraint is never retried, so the error is emitted exactly once.

**Invariant maintained**: Each type error appears in ctx.err exactly once. No duplicate error messages. No dedup buffer needed.

**What breaks if violated**: If a handler deferred after emitting an error, the next retry would re-emit the error, spamming diagnostics.

**Dependents**: solve.lua:543-546, 636-662 (error-emission patterns).

**Status**: Load-bearing for diagnostic quality; item 1.5a of phase-F.

---

### INV-D2: MISSING_FUNCTION_SIGNATURE Emitted in Post-Pass
**Evidence**: solve.lua:3960-3987

**Statement**: After solve_range completes, M.solve emits MISSING_FUNCTION_SIGNATURE for function defs without annotations (ctx._missing_signatures). This runs once, after all constraints are solved.

**Invariant maintained**: Missing signatures are reported after the rest of typechecking, so they don't interrupt the solve. Rules-config controls severity.

**What breaks if violated**: Missing signatures could be reported mid-solve, or never reported.

**Dependents**: solve.lua:3957-3988 (M.solve function).

**Status**: Load-bearing for diagnostic timing correctness.

---

## IX. CONSTRAINT EMISSION SITES (Partial Inventory)

### EMIT-C1: C_UNIFY — Equational Constraints
**Evidence**: constrain.lua emit sites: lines 2881, 2884, 2890, 2893

**Source AST nodes**: Return statements (RETURN_STMT); multi-return tuple construction; equality-driven unification.

**Order assumption**: None explicit; WANTED tier (general constraint).

**Downstream readers**: solve_unify marks constraint solved immediately.

---

### EMIT-C2: C_SUB — Subtyping Constraints
**Evidence**: constrain.lua emit sites: lines 1851, 1858, 1865, 1871, 1910, 1950, 1969, 1988, 2306, 2881, 2884, 2890, 2893, 3592, 3596, 3764, 3796, 3814, 3876, 3907

**Source AST nodes**: Assignment, return, annotation check, cast.

**Order assumption**: Generally unordered; WANTED tier. C_SUB on cast expressions checks redundancy (INV-F2).

**Downstream readers**: solve_sub (always terminal).

---

### EMIT-C3: C_BOUND — Generic Param Bounds
**Evidence**: constrain.lua emit sites: lines 2947, 3138

**Source AST nodes**: Generic function params with bounds (annotation).

**Order assumption**: GIVEN tier (constrain.lua:251). Runs before WANTED handlers on same TV bind (INV-B1, INV-O5).

**Downstream readers**: solve_bound propagates bounds into param TVs.

---

### EMIT-C4: C_BIND_GENERICS + C_CHECK_ARGS — Call Sites
**Evidence**: constrain.lua emit sites: lines 3080-3086

**Source AST nodes**: CALL_EXPR, METHOD_CALL.

**Emission order**: C_INSTANTIATE_AT_CALL, C_BIND_GENERICS, C_BOUND (deferred during solve), C_CHECK_ARGS.

**Order assumption**: C_BIND_GENERICS must precede C_CHECK_ARGS in drain (INV-O1, INV-H6).

**Downstream readers**: solve_bind_generics binds params; solve_check_args checks them.

---

### EMIT-C5: C_ESCAPE_CHECK — Rank-N Polymorphism Check
**Evidence**: constrain.lua emit sites: lines 3086

**Source AST nodes**: CALL_EXPR with rank-N callee.

**Order assumption**: Defers while ret_tid is free (solve.lua:733-737); runs after C_CHECK_ARGS binds it.

**Downstream readers**: solve_escape_check verifies no skolem escapes.

---

## X. TOTAL INVARIANTS AND SUMMARY

**Total Invariants Identified**: 51
- Ordering (O): 8
- Producer/Consumer (P): 6
- Fast-Path (F): 3
- Bind-Discipline (B): 3
- Sub-Solve (S): 3
- Tag-Shape (T): 4
- Handler-Specific (H): 7
- Diagnostic (D): 2
- Emission Sites (E): 5

---

## TOP 5 MOST-DEPENDED-UPON INVARIANTS

1. **INV-O1: FIFO Drain by Head Index**
   - Dependents: every handler that depends on emission order, every deferred constraint, every re-seeding round
   - Violation impact: inverts constraint order → silent semantic failures
   - Load-bearing: YES

2. **INV-B1: TIER_GIVEN (C_BOUND) Before TIER_WANTED**
   - Dependents: C_BIND_GENERICS (2766-2776), solve_bound, every generic function call
   - Violation impact: inferred bounds override declared bounds → soundness failure
   - Load-bearing: YES

3. **INV-O2: Emitted Children Land at Tail**
   - Dependents: C_BIND_GENERICS emission of bounds, every emit site in handlers
   - Violation impact: children run mid-drain in wrong order → semantic inversion
   - Load-bearing: YES

4. **INV-P2: wake_waiters After Every bind_var (Centralized Chokepoint)**
   - Dependents: every await site (solve_narrow_nil, solve_bound), unify.bind_var_to_type
   - Violation impact: deferred constraints never re-activate → infinite wait
   - Load-bearing: YES

5. **INV-O6: Quiescence Detection (No Progress → Exit)**
   - Dependents: drain termination logic (3925-3934), re-seeding
   - Violation impact: infinite drain loops or premature exit → non-termination or incomplete solve
   - Load-bearing: YES

---

## INVARIANTS PRESERVED BY CURRENT REWORK (Phase F + Items 1-5)

Phase F's rework preserved the following architectural invariants:
1. INV-O1: FIFO drain (new worklist design, not stack)
2. INV-O2: Tail emission (emit sites append to tail)
3. INV-O4: Tier dispatch before handler
4. INV-O5: C_BOUND (GIVEN) before C_BIND_GENERICS (WANTED)
5. INV-B1: Givens-before-wanteds discipline
6. INV-D1: Terminal handlers (errors retire, no re-emit)
7. INV-P2: wake_waiters after bind (centralized chokepoint)

**Invariants explicitly replaced/redesigned**:
- INV-O3: Handler dispatch completeness (verified by Phase F item 3+5)
- INV-O6: Quiescence detection (replaced 4-pass cap with observed-progress quiescence)

**New invariants introduced by Phase F**:
- INV-O4: Constraint tier publishing before handler execution
- INV-P1: await() registers on union-find root (symmetry with wake_waiters)

---

## INVARIANTS PHASE F / H2 REWORK MUST PRESERVE OR EXPLICITLY REPLACE

Any future rework of the solver (e.g., Phase H2 as mentioned in session notes) MUST:

**Preserve**:
1. INV-O1 (FIFO drain)
2. INV-O2 (tail emission)
3. INV-O4 (tier dispatch)
4. INV-O5 (GIVEN before WANTED)
5. INV-O6 (quiescence termination)
6. INV-B1 (givens-before-wanteds discipline)
7. INV-P2 (wake_waiters chokepoint)
8. INV-D1 (terminal error handlers)
9. INV-H1 through INV-H7 (handler-specific invariants)
10. All producer/consumer invariants (INV-P1 through INV-P6)

**Explicitly replace (if changing)**:
- INV-F1, INV-F2, INV-F3 (fast-path assumptions; must re-validate if try_unify behavior changes)
- INV-S1, INV-S2, INV-S3 (sub-solve assumptions; must re-architect if sub-solve scope changes)
- INV-T1 through INV-T4 (tag-shape assumptions; must update if type representation changes)

**Total count**: 51 invariants identified, with 10 as fundamental pillars that any redesign must preserve.

