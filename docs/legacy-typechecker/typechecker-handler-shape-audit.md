# Typechecker — handler shape audit

Phase 1 of the rework-direction work. This audit re-examines the previous
session's verdict in `docs/typechecker-session-handoff.md` Caveat 3 ("classical
OutsideIn/X emit-shape doesn't fully fit") by classifying each observed
handler shape as fundamental (cannot be eliminated by re-factoring constraint
kinds / primitives) or accidental (an artifact of how the handler is currently
written), with an adversarial falsification pass on each "fundamental" verdict.

## Methodology

Sources read in full: `docs/typechecker-session-handoff.md`,
`docs/typechecker-solver-fundamentals.md`, `lib/type/static/solve.lua`
(4109 LOC, all handlers + dispatch + worklist), `lib/type/static/constrain.lua`
constraint-kind enumeration (lines 127-207), `lib/type/static/unify.lua`
`M.unify` entry and the bind/wake_waiters chokepoints (lines 225-455).

Classification rubric: a shape is **fundamental** iff there is a property the
solver must observe that no plausible constraint-kind + emit-only reformulation
can express. A shape is **accidental** iff the only obstacle to a pure-emit
reformulation is the absence of a named constraint kind or primitive that the
existing infrastructure already supports. Each fundamental verdict must
adversarially propose at least one elimination and show concretely why it
fails. Verdicts would flip if (a) the falsification turns out wrong, or (b) a
new primitive (disjunctive constraint, await-on-TV-with-emission, etc.) is
introduced that handles the case natively.

Baseline error counts (Phase 0): solve 35, constrain 31, types 12, env 2,
unify 0 — exact match against the handoff.

## Shape 1: Pure emit

**Representative**: `solve_instantiate_at_call` (lib/type/static/solve.lua:2809).
Also the trivial fall-throughs in `solve_hkt_decompose` (3852) delegating to
`solve_hkt_decompose_impl`.

**Need**: take a constraint with composite semantics, decompose into child
constraints whose individual handlers carry the actual work. The shape is the
OutsideIn/X canonical form: produce children, return solved.

**Verdict**: accidental — but only in the sense that the current implementation
is a passthrough stub. The shape itself is the *target* of the rewrite, not a
defect. `solve_instantiate_at_call` is documented (lines 2809-2818) as a
placeholder that will emit `C_BIND_GENERICS` + `C_CHECK_ARGS` children at
solve-time once the consolidation of fundamental 6 lands.

**Elimination sketch**: there is nothing to eliminate. The shape is the
prescribed paradigm shape; the current handler is incomplete, not wrong. What
*is* accidental is that `claim(ctx, ret_tid, c)` happens here while the body
is empty — the claim/release contract is being held open across a no-op,
relying on the eager gen-time emission in `constrain.lua` to do the actual
work. When P4 lands the emit body, the claim becomes a non-degenerate part of
the producer-commitment protocol.

## Shape 2: Sync unify

**Representatives**: `solve_unify` (596, 14 LOC), `solve_sub` (613), `solve_return`
(2724), `solve_compare` (2599), `solve_index` (1457), `solve_hkt_decompose_impl`
(3771). All share the same skeleton: resolve TVs, call `unify_mod.unify` (or
`try_unify_strict`/`try_unify`), emit terminal diagnostic on failure, return
true.

**Need**: enforce structural equality / subtyping over arbitrarily-nested types
in a single atomic step. Failure to enforce atomically would let mid-recursion
TV binds escape into surrounding constraints before the unification commits
or rolls back.

**Verdict**: fundamental at the *current* type algebra; accidental at the level
of "could a different algebra eliminate it?". This is the most important entry
in the audit because the handoff (Caveat 3, point 1) names `unify_mod.unify`
itself — not the handlers calling it — as the deep non-paradigmatic code. The
1585-LOC `unify.lua` body (entry at 363) is synchronous structural recursion
over every tag pair. Re-expressing it as constraint emission would create one
child constraint per recursive step (~10-100 per top-level call on realistic
types).

**Adversarial elimination attempt #1: `unify_mod.unify` → constraint emission.**
Replace the recursive body with: for each pair of subterms, emit a new
`C_UNIFY` child. The worklist drains them. Termination: each emission decreases
type-tree depth. Why this fails:

1. **Coinductive cycle detection** (unify.lua:377-380, `seen` table). The
   `seen` table is threaded down the recursion and detects (a,b) re-entry to
   handle recursive table types (typeclasses). Emit-only loses the call-stack
   carrier for `seen`; you'd need either a per-emission threaded "seen-set
   constraint payload" (growing without bound across deferrals) or a
   ctx-global one (which conflates unrelated unifications and either
   over-approximates termination or under-approximates correctness).
2. **All-or-nothing failure**. unify.lua returns `false, err` when any subterm
   fails, and the caller (`solve_sub`, `solve_callable` arg loop) treats that
   as a *single* call-site error with one location. If subterm unifications
   are separate constraints, each emits its own diagnostic against the same
   line/col — the deduplication that "terminal-once" gives today disappears,
   and worse, the error sites point at structural subterms the user didn't
   write.
3. **Bind-during-unify and `_bind_woke_given`**. `unify_mod.unify` writes
   binds via `bind_var_to_type` which sets `_bind_woke_given` (used by
   `solve_callable`/`solve_bind_generics` at lines 2312, 2891 to defer the
   param loop). If unify is emit-only, the bind happens on a *child*
   constraint's turn — the parent param-loop has already finished iterating
   when the wake fires, and the givens-before-wanteds discipline collapses.

**What would enable elimination**: a different type algebra (e.g. row-types
factored as judgements, or a CHR-style propagation graph where subterm
constraints carry their own provenance for diagnostic coalescing). Not on the
table without a multi-thousand-LOC ground-up rewrite of `unify.lua` plus
diagnostic infrastructure. **Fundamental under the current foundation.**

**Adversarial elimination attempt #2: keep `unify_mod.unify` but make the
handler emit `C_UNIFY` and let the dispatcher invoke unify directly.** This
is a rename, not an elimination — `C_UNIFY` is what `solve_unify` already
dispatches. It buys nothing.

## Shape 3: Backtracking (overload)

**Representative**: `solve_callable` on `TAG_INTERSECTION`
(lib/type/static/solve.lua:2377-2449). Build the list of `TAG_FUNCTION` members,
try each one with `try_unify` (read-only — no binds escape), commit (`bind_to`)
to the first whose every param accepts. On total failure, emit a multi-candidate
diagnostic.

**Need**: select one branch of an intersection where "selection" is observable
to the rest of the solver — the chosen overload's return type is the only one
that flows out to consumers; the rejected branches' would-be-bindings must not
escape.

**Verdict**: fundamental. The handoff's verdict was correct, but for a sharper
reason than "OutsideIn/X doesn't have disjunction": it's that *the worklist
solver has no rollback*, and overload resolution semantically requires either
rollback or read-only tentative unification.

**Adversarial elimination attempt #1: emit a disjunctive constraint
`C_TRY_ANY(member1, member2, ...)`.** A new constraint kind whose handler
the dispatcher knows to try in parallel. Why this fails: "in parallel" is
not a thing the worklist supports. Either (a) you serialize by trying member1
first via emission, and if it fails, re-emitting with member2 — which is
exactly what the current code does inline, just spread over more constraints;
or (b) you genuinely fork the constraint set, which is a fundamentally
different solver (search-based, like Prolog or HM-with-overloading via type
classes). Crescent's solver is single-state-worklist by design (item 1 of the
rework, `bb88a5aa`). Forking is incompatible with the
quiescence-based-termination contract — quiescence is observed on *one* state.

**Adversarial elimination attempt #2: factor the intersection up-front into
N independent constraints, one per overload, each tagged "best-effort".**
Fails because the consumers downstream (the `ret_tid` reader) need *one*
type, not N. Aggregating N tentative results back to one is the same problem
as Shape 4 below, plus you've now broken the call-site's atomicity.

**What would enable elimination**: a search/rollback layer underneath the
worklist, OR a type-class-style resolution where the overload selection is
deferred as a type-class constraint that resolves at use site. The second is
genuinely closer to what crescent does — function intersection IS a
poor-man's type class — but unifying them is the same multi-thousand-LOC
rewrite category. **Fundamental.**

## Shape 4: Aggregation (union callable)

**Representatives**: `solve_callable` on `TAG_UNION` (2452-2495);
`solve_check_args` on `TAG_UNION` (3190+, same skeleton). For each union
member: must be `TAG_FUNCTION`, must accept all args. Collect each member's
return type, union them, bind that to `ret_tid`.

**Need**: distribute a constraint over a union's members and aggregate the
per-member outcomes into a single result. Soundness requires *all* members
pass; result is the union of returns.

**Verdict**: **accidental**. This is the strongest accidental verdict in the
audit. The pattern "for each member m of TAG_UNION X, apply constraint Q
parameterized by m; aggregate" is a higher-kinded constraint operation that
deserves to be named.

**Elimination sketch**: introduce `C_DISTRIBUTE_OVER_UNION` (or, in the more
general formulation, give every relevant constraint kind a "union member to
process" cursor field and let the dispatcher iterate). Concrete shape:

- New kind: `C_DISTRIBUTE_OVER_UNION { underlying_kind, payload, ret_tid }`.
- Handler: if the relevant operand is `TAG_UNION`, emit one
  `underlying_kind` child per member with a fresh `member_ret_tid`. Park
  awaiting all the member_ret_tids. When all bind, build the union (or
  `T_NEVER` if all parked failed) and bind `ret_tid`.
- Callers (`solve_callable`, `solve_check_args`) drop their union branches
  entirely.

**Handlers that change**: `solve_callable` and `solve_check_args` lose their
`TAG_UNION` blocks. `solve_arith`, `solve_compare`, `solve_index` (which all
have their own ad-hoc union-distribute scattered through `meta_op_ret_impl`
and similar helpers) can also route through the new kind. Net LOC reduction
is real; the diagnostic shape "argument rejected by union members" becomes
the new kind's responsibility.

**Caveat**: the implementation needs a multi-TV await primitive (await on all
of {m1_ret_tid, m2_ret_tid, ...} simultaneously). The current `await(ctx, c,
tv_id)` only takes one TV; the worklist re-runs the constraint when any waiter
wakes, which would handle multi-TV by re-checking at each wake. Cost is
re-running aggregation N times; not a correctness issue.

## Shape 5: Mid-iteration deferral

**Representatives**: `solve_callable`'s rank-N param loop (2219-2314 — the
`_bind_woke_given` check at 2312, the `return false` to defer the rest of the
loop); `solve_bound` (1182, awaits on actual or resolved_bound);
`solve_or` (846, defers while left is free); `solve_narrow_nil` (748, awaits
on input); `solve_escape_check` (799, defers while ret is free non-skolem);
`solve_index` (await on obj_tid, on owned res_tid); the ret-TV ownership
awaits in `solve_sub`.

**Need**: a handler that has begun work — possibly with side effects already
committed (TV binds on prior iterations of a loop, claim() established) —
needs to pause and resume when an event occurs (a TV binds; a GIVEN waiter
fires; another handler releases ownership).

**Verdict**: **mixed**. Two sub-cases that are actually different:

- **5a. "Await on TV" deferrals** (solve_bound, solve_narrow_nil,
  solve_escape_check, solve_index's obj/res awaits, solve_or, solve_sub's
  owner-aware await). These are *not* mid-iteration — they happen at the top
  of the handler, before any work. They are identical in shape to "Shape 1
  pure emit" except the handler emits nothing and just parks. **Accidental
  relative to Shape 1**: the dispatcher contract already has `await` as a
  return shape (constrain.lua line 3867 documents `{ solved, await, emit }`).
  These handlers are pure-emit handlers whose emission set happens to be
  empty and whose return is "await this TV". Unifying with Shape 1 is purely
  notational.

- **5b. Mid-loop deferrals with side effects already committed**
  (`solve_callable`'s param loop returning `false` after some params bound;
  `solve_bind_generics`'s same shape at 2891; `solve_check_args`'s vararg
  deferral at 3058). These *are* fundamental under the current model. The
  handler has bound TV X via unify on iteration i, then needs to pause
  before iteration i+1, then resume the same loop on a later worklist round
  with iteration index reset to 0 (re-checking already-bound params is
  idempotent: their fast-path `try_unify` short-circuits).

**Adversarial elimination attempt for 5b: split the loop into N constraints,
one per param.** Each param becomes a `C_CALLABLE_PARAM(callee, i, arg,
ret_tid)`. Why this fails:

1. **Diagnostic locality.** Today the param loop emits a single "argument i:
   cannot pass …" with the right line/col and access to `param_name` from
   `callee_t`. Per-param constraints lose the contextual access to
   `callee_t` after gen — you'd need to re-resolve it on every child, and
   the call-site error becomes N errors instead of one.
2. **The `_bind_woke_given` discipline is per-loop, not per-param.** When
   param 0's bind wakes a `C_BOUND` GIVEN, we defer the *rest* of the loop
   so the GIVEN can rewrite still-free A/B/R before we touch them. Per-param
   constraints would each independently observe `_bind_woke_given` and
   defer themselves, but the worklist would then run *all* of them after
   the GIVEN fires — the discipline depends on observing the woke flag
   between iterations of the *same* handler instance, not across separate
   handler firings.
3. **Re-running idempotency depends on a single coherent param list.** The
   resume-from-0 re-iteration works because `try_unify` fast-paths already-
   bound params. With separate constraints, re-running means re-emission of
   N constraints — but each was already retired (`_solved` set). The
   worklist machinery doesn't un-retire constraints. You'd need a separate
   un-retire primitive.

**What would enable 5b elimination**: explicit iterators-as-constraints with
mutable state (a continuation-passing transformation of the loop). This is
what handoff Recommendation (B) gestures at — "continuation-passing handles
synchronous mid-iteration deferral natively". Not currently present and not
small to add. **Fundamental.**

**5a, however, is accidental** and points at a small concrete consolidation:
make `await(...)` the canonical way for any handler to express "I cannot
proceed yet; wake me when TV X binds" and document it as the same primitive
as Shape 1's empty-emission case.

## Cross-cutting findings

**The deep non-paradigmatic code is `unify_mod.unify`, not any handler.**
This is the handoff's finding (Caveat 3 point 1) and the audit confirms it.
Every "Shape 2 sync unify" handler is a 5-20-LOC adapter around a 700-LOC
recursive function in unify.lua. If a paradigm shift were on the table, it
would be at the unification level — the handlers would shrink to obvious
emit-shapes the moment unify is decomposed.

**The `claim`/`release`/`is_owned` TV-ownership protocol crosscuts Shapes 2,
3, 4, 5b.** Every producer that commits to a future bind on a ret_tid claims
it; every reader that sees a free TV checks ownership before falling through
to eager unify; release fires at the bind chokepoint. This is the
materialization of "producer→consumer ordering of call ret TVs" that the
handoff calls out as load-bearing for H2 record-of-generics dispatch. The
protocol is not a handler shape — it's a layer underneath them — but it
makes the await-on-TV pattern (Shape 5a) and the ret-bind discipline (Shapes
3, 4, 5b) implementable. Operational-semantics work in Phase 2 must name
this protocol explicitly; today it lives in 100 lines of comment prose at
solve.lua:105-152.

**Audit-count discipline (Caveat 4) matters here too.** The handoff named
"5 handler shapes." Strictly, the audit finds 4: Shape 5a folds into Shape 1
(both are "park-or-emit"), and the remaining residue (Shape 5b) is the only
genuinely distinct mid-iteration case. The "5" count was inflated by
treating "await happens at handler top" and "await happens mid-loop" as the
same shape when they have different fundamentalness verdicts. Phase 2 should
adopt the 4-shape taxonomy.

## Verdict summary

| Shape | Representative | Verdict |
|------|---------------|---------|
| 1 Pure emit | `solve_instantiate_at_call` | target shape (stub) |
| 2 Sync unify | `solve_unify` + 5 others | fundamental (unify.lua is the root) |
| 3 Backtracking | `solve_callable` TAG_INTERSECTION | fundamental (no rollback layer) |
| 4 Aggregation | `solve_callable` TAG_UNION | **accidental** (C_DISTRIBUTE_OVER_UNION) |
| 5a Await-on-TV | `solve_bound` etc. | accidental (= Shape 1 with empty emit) |
| 5b Mid-loop defer | `solve_callable` param loop | fundamental (no iterator-as-constraint) |

## What this implies for the operational semantics (Phase 2)

Concrete inputs Phase 2 inherits from this audit:

1. **Adopt a 4-shape taxonomy**: emit (including await-on-TV with empty
   emission), sync-unify, backtracking-select, mid-loop-with-state.
   Document each as a distinct operational rule.

2. **Name three primitives explicitly** that today live in prose:
   - `claim`/`release`/`is_owned` ret-TV ownership (currently solve.lua:105-152).
   - `_bind_woke_given` (currently a ctx flag set in unify.bind_var_to_type
     and consulted in solve_callable/solve_bind_generics).
   - `await` (return shape `{ solved = false, await = tv_id }`, currently
     in constrain.lua:3867's type signature only).

3. **Add one constraint kind** to remove an accidental shape:
   `C_DISTRIBUTE_OVER_UNION` (Shape 4 → Shape 1). This is a real
   reconciliation, not a renaming — net LOC reduction in `solve_callable`,
   `solve_check_args`, `solve_arith`'s union path.

4. **Do not propose to eliminate Shapes 2, 3, or 5b** without addressing the
   underlying foundations: `unify.lua`'s structural recursion (Shape 2),
   absence of a rollback / search layer (Shape 3), absence of
   iterators-as-constraints (Shape 5b). All three are multi-thousand-LOC
   changes against load-bearing machinery. They are valid Phase 3+ targets
   but explicitly outside the operational-semantics-writing scope.

5. **Reconcile fundamental 6** (fresh instantiation at use site) by routing
   the three current paths — `solve_callable`'s inline instantiate,
   `solve_check_args`'s re-instantiate branch, `C_INSTANTIATE_AT_CALL` stub
   — through one named entry. Phase 2 should describe this entry as the
   operational rule for "use of a polymorphic value" and Phase 3 implements
   the consolidation. The audit confirms the handoff's framing: this is
   consolidation work, not a rewrite.
