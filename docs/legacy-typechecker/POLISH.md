# Polish State

Created: 109fec38 (2026-05-18)
Last run: 2026-05-19
Round: 3
Project type: typechecker operational-semantics specification + supporting code

## Lenses
- (A) primitive-set closure
- (B) C_CALLABLE per-tag dispatch — ad-hoc or legitimate?
- (C) rank-N polymorphism + skolemization coverage
- (D) literature comparison (HM / System F / OutsideIn/X / bidirectional / local inference)
- (E) adversarial verification of quantitative + structural claims

## Scope
- `docs/typechecker-operational-semantics.md` (primary target)
- `lib/type/static/*.lua` (cross-reference)
- Design docs: `typechecker-rank-n.md`, `typechecker-hm-phase2.md`, `type-system.md`, `typechecker-solver-fundamentals.md`, `typechecker-handler-shape-audit.md`, `typechecker-phase-f-blocker.md`

## Findings — Round 1

### Cross-cutting verdict (consensus across all 5 lenses)

The spec is **largely a re-narration of existing handler code in nicer prose, not a load-bearing specification.** Specific defects in three categories:

1. **Primitive set is not closed** (Lens A): rules invoke ~17 operations that aren't §2 primitives.
2. **Paradigm is internally inconsistent** (Lens D, Lens B): OutsideIn vocabulary mixed with bidirectional/local-inference shape; per-tag dispatch in C_CALLABLE is the user's original ad-hoc objection.
3. **Rank-N machinery is largely hand-waved** (Lens C): no skolemize/subsume/generalize primitives; C_SUB silently passes polytypes through monomorphic unify.

### Lens A — primitive-set closure

- [PENDING] `docs/typechecker-operational-semantics.md:181` — `try_unify_strict` invoked in C_SUB not in §2 (distinct primitive at `unify.lua:1373`) — fix: add to §2 _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:181` — `widen` invoked in C_SUB not in §2 (dispatches to 3 variants: widen_for_sub/widen_literal/widen_deep) — fix: add to §2 with variant taxonomy _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:192` — "Project obj[key] per the type algebra" in C_INDEX is hundreds of lines of multi-tag dispatch in `solve_index` — fix: add `project(obj, key)` primitive _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:196-209` — C_CALLABLE body is "dispatch on tag" with non-composable per-branch behavior — fix: split into per-tag rules OR define per-tag operations as §2 primitives _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:215` — `merge_inferred_bound` not in §2; writes to `ctx.tv_bounds` which §1's Σ tuple omits entirely — fix: add primitive + add `B` (bounds) to Σ _(high — also §1 omission)_
- [PENDING] `docs/typechecker-operational-semantics.md:217` — `meta_op_ret_impl` not in §2 (50-line shared algorithm) — fix: add `meta_op_ret(op, tid)` primitive _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:222` — "multi-return tuple flattening" hand-waved — fix: spec out `flatten_multi_return` or inline _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:226` — C_COMPARE "overlap-required unify" is actually bidirectional `is_subtype`, not §2 unify — fix: add `overlap_check(a, b)` (also used by C_OVERLAP) _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:232-233` — C_BOUND dispatches on bound shape via `propagate_function_bound` (53 lines), `propagate_meta_bound` (168 lines), kind-arity, TAG_MATCH_TYPE — fix: either four §2 primitives or split into 4 rules _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:243` — `subtract` (used by C_OR + C_NARROW_NIL) not in §2 — fix: add primitive _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:275` — "Walk reachable TVs with skolem mark" not specified — fix: add `escape_check(t, call_id)` or `reachable_skolems(t)` _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:280-281` — C_HKT_DECOMPOSE "pattern-match against structural body" hand-waved + factually misleading ("bind args_fresh[i] to recovered_arg_i") — fix: rewrite as substitute-then-unify _(high — also misleading)_
- [PENDING] `docs/typechecker-operational-semantics.md:300` — C_DISTRIBUTE_OVER_UNION needs multi-TV await; §2's park is single-TV — fix: spec `park_multi` or describe iterated re-park invariants _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:140` — `instantiate_at_use` itself smuggles "env.lua's instantiate" + HKT decomp as sub-steps — fix: split + name `env_instantiate` as primitive _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:23-35` — §1 Σ tuple omits `ctx.tv_bounds` entirely — fix: add `B : TVId → InferredBound?` component _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:172` — `find` used pervasively but not declared in §2 — fix: declare as read-only primitive or as notation _(low)_

### Lens B — C_CALLABLE per-tag dispatch

- [PENDING] `docs/typechecker-operational-semantics.md:204` — TAG_INTERSECTION branch needs `try_each` (search primitive incompatible with worklist); same argument that promoted union to C_DISTRIBUTE_OVER_UNION — fix: split into `C_RESOLVE_OVERLOAD {candidates, args, ret}` _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:207` — TAG_VAR sub-branch (FLAG_SUB_SOLVE_PARAM path) emits `merge_inferred_bound` — fundamentally different operation than "call a function" — fix: split into `C_INFER_CALLABLE_BOUND {callee_tv, args, ret}` _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:207` — TAG_VAR non-sub-solve-param branch silently binds ret to T_ANY at `solve.lua:2157+` — this is a BUG, not a branch; correct behavior is `park(c, callee)` _(high — bug, not design)_
- [PENDING] `docs/typechecker-operational-semantics.md:196-209` — overall verdict: C_CALLABLE should split into **C_CALL_FUNCTION** (TAG_FUNCTION + lattice absorbers + nominal unwrap + error), **C_RESOLVE_OVERLOAD**, **C_DISTRIBUTE_OVER_UNION** (already), **C_INFER_CALLABLE_BOUND**. Audit's inconsistency: shape 4 (union) promoted, shape 3 (intersection) left inside, but same argument applies _(high)_

### Lens C — rank-N + skolemization coverage

- [PENDING] `docs/typechecker-operational-semantics.md:72-159` — **no skolemize primitive** in §2; `env.skolemize_return_for_rank_n` and `constrain.skolemize_fn` are unnamed — fix: add `skolemize(σ) → (body, [skolem_tvs])` _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:134-143` — `instantiate_at_use` conflates instantiate/skolemize/subsume into one bullet (OutsideIn/X has 3 distinct primitives) — fix: split into `instantiate`, `skolemize`, `subsume` _(high — structural)_
- [PENDING] `docs/typechecker-operational-semantics.md:179-185` — C_SUB has no rank-N case; `unify.lua` has no TAG_FORALL arm; `C_SUB(∀a.T, U)` silently passes today — fix: add subsumption premise for TAG_FORALL operands _(high — soundness)_
- [PENDING] `docs/typechecker-operational-semantics.md:196-209` — C_CALLABLE TAG_FUNCTION param loop uses monomorphic `unify`, no TAG_FORALL branch (rank-N landing patched solve_check_args, spec doesn't reflect) — fix: add polytype subsumption case _(high — soundness)_
- [PENDING] `docs/typechecker-operational-semantics.md:39-40` — `FLAG_SUB_SOLVE_PARAM` named, never specified — fix: paragraph stating it as state with HM sub-solve contract _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md` (whole) — no let-generalization rule and no statement that crescent doesn't generalize implicitly — fix: explicit non-generalization note _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:272-276` — C_ESCAPE_CHECK omits reachability root (b) "outer binding's type" per rank-N doc — fix: enumerate both roots OR document as known soundness gap with test pin _(soundness)_
- [PENDING] `docs/typechecker-operational-semantics.md:525-547` — Gap B "verified" only covers cross-statement C_SUB ordering, not H2 record-of-generics (the actual Phase F blocker per `typechecker-phase-f-blocker.md`) — fix: add Gap C for H2 OR add premise for TAG_INDEX-of-TAG_FORALL callee _(high — claimed blocker is not actually closed)_
- [PENDING] `docs/typechecker-operational-semantics.md:160-304` — no rule for definition-site polytype entry (skolemize_fn fires gen-time, spec is silent on gen/solve boundary) — fix: scope statement or pre-solve normalization §0 paragraph _(clarification)_

### Lens D — literature comparison + paradigm coherence

- [PENDING] `docs/typechecker-operational-semantics.md:34` — Σ carries `S : Stack<ImplicationFrame>` but §10 verdicts the implication machinery as dead; no rule reads/writes S — fix: drop S from Σ _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:33` — `{GIVEN, WANTED}` tier values use OutsideIn vocabulary with non-OutsideIn semantics (priority, not axioms-vs-goals) — fix: rename to `{DECLARED, INFERRED}` _(high)_
- [PENDING] `docs/typechecker-operational-semantics.md:29` — TVCell carries `level` field but no rule reads/writes it; suggests Rémy-style HM that doesn't exist — fix: drop `level` OR specify the level discipline _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:0` — **§0 should commit to paradigm**: "Crescent uses local type inference with bidirectional propagation. It is not OutsideIn/X. It is not full HM. Vocabulary overlaps with those systems but meanings are crescent's." — fix: add this paragraph _(high — meta finding)_
- [PENDING] `docs/typechecker-operational-semantics.md:362-391` — §6 frames `try_each` defensively ("emit-only cannot model this"); in bidirectional/local-inference it's the *recommended* shape — fix: reframe as principled choice _(low)_
- [PENDING] `docs/typechecker-operational-semantics.md:127-130` — no canonicalize/interact/topreact analog (OutsideIn-style normalization); each handler reimplements head-unwrap — fix: either add `canonicalize(c)` primitive OR document that crescent has no canonical form and each handler is responsible _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:178-185` — bidirectional check vs infer modes never named even though C_UNIFY/C_SUB are textbook examples — fix: add one-paragraph constraint-modality section _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:260-264` — C_OVERLAP exists but `type-system.md:109` says force-cast is "planned, not implemented" — fix: cross-doc reconciliation _(medium)_

### Lens E — claim verification

- [VERIFIED] Handler/rule counts (16/17), every spot-checked line ref accurate.
- [PENDING] `docs/typechecker-operational-semantics.md:479` — §10 "collapse is safe" verdict leans on unstated equivalence under expanded PORTED set (now includes parking kinds C_CALLABLE/C_CHECK_ARGS/C_INSTANTIATE_AT_CALL/C_BIND_GENERICS); not proved — fix: prove equivalence OR weaken to "pending equivalence test" _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:13-14 vs 549-552` — §0 says "Phase 3 cannot start while §11 is non-empty" but §11 has two non-empty entries and concludes "no blockers" — fix: pick one framing _(medium — internal contradiction)_
- [PENDING] `docs/typechecker-operational-semantics.md:519-523` — Gap A resolution hand-waves multi-TV await; single-TV park can lose wakes if two member_ret bind in same round — fix: spec multi-TV await OR prove re-park ordering invariant _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:540-547` — Gap B "verified" misleading: ownership is released on terminal-*success* paths only; defer paths leave O[ret_tid] in place — fix: amend wording _(medium)_
- [PENDING] `docs/typechecker-operational-semantics.md:127-128` — `release` listed as rule-callable primitive but no rule calls it (called only by chokepoint) — fix: move to invariant-discipline appendix _(low)_
- [PENDING] `docs/typechecker-operational-semantics.md:97-98, 127-128` — implicit "every primitive used by ≥2 rules" claim fails for `release` (0), `try_each` (1), `try_unify` (1) — fix: surface honestly or restructure _(low)_

### Conflicts
None across lenses. All five point in the same direction: the spec is under-specified and needs a Round-2 rewrite, not a series of small edits.

## Findings — Round 2 (commit 1b59852b)

Applied all four required structural changes from Round 1 synthesis + corrected the §0 factual error Lens E surfaced.

Re-ran A/B/C/E (skipped D — paradigm-commitment landed in Round 1):

### Lens A (round 2): 17 → 6 smuggled ops
Remaining: `propagate_function_bound`, `propagate_meta_bound` (HIGH), `check_kind_arity` (MED), `substitute` newly smuggled by Round 1 (MED), wording paraphrases for `project`/`escape_check`/`eval_match_type`/`meta_op_ret` (LOW).

### Lens B (round 2): split now in spec
Verdict: structural note insufficient. Drafted concrete schemas for C_CALL_FUNCTION / C_RESOLVE_OVERLOAD / C_INFER_CALLABLE_BOUND. TAG_VAR non-sub-solve-param bug folds into C_CALL_FUNCTION as `park` premise.

### Lens C (round 2): 4 gaps
1 HIGH (soundness): `subsume` only covers both-forall case. 2 MED: gen-time skolemization not in spec frame; C_ESCAPE_CHECK single reachability root. 1 LOW: Gap B/C relationship clarification.

### Lens E (round 2): 2 new defects from Round 1
1 HIGH: §0 paradigm claim "no implicit let-generalization" factually wrong (`constrain.lua:2372` calls `env_mod.generalize`). 1 MED: `instantiate_at_use` framed as present but is a stub.

All Round-2 findings applied as commit `1b59852b` (13 edits).

## Findings — Round 3 (commit e4438a19)

Re-ran A/E only (B's structural change landed; C's gaps were closed in Round 2).

### Lens A (round 3): 6 → 3 smuggled ops
- [APPLIED] MED — `dispatch_param(actual, formal)` named in §2; C_CALL_FUNCTION + C_CHECK_ARGS reference it.
- [APPLIED] MED — `callable_shape(args, ret)` named as constructor primitive.
- [APPLIED] LOW — C_RESOLVE_OVERLOAD callbacks made concrete (`try_unify_strict_args` + explicit exhaustion).

### Lens E (round 3): 1 MED defect from Round 2 + 1 LOW info
- [APPLIED] MED — C_BOUND metamethod-shape branch overstates current handler surface; annotated as Phase-3-only dispatch addition (primitive exists at `solve.lua:950` but `solve_bound` doesn't yet dispatch).
- [APPLIED] LOW — `subsume`'s four-case enumeration vs rank-n.md's three-case form: added clarifying note (semantic-preserving expansion).

All Round-3 findings applied as commit `e4438a19` (6 edits).

## Status

Spec is **substantially closed** under criterion 3 (every operation invoked in §3 is a §2 primitive or a composition of §2 primitives). Remaining items at end of Round 3 are either:
- Phase-3 reconciliation tasks documented in §11 (Gap A, B, C, D) — Gap C is the only BLOCKER (H2 record-of-generics dispatch).
- Code-level work the spec correctly describes but the handlers don't yet implement (C_BOUND metamethod dispatch; C_ESCAPE_CHECK outer-binding reachability; C_CALLABLE → 3 new handlers).

The polish loop has converged. Phase 3 may begin once Gap C is resolved (either by extending C_INSTANTIATE_AT_CALL to cover H2, or by explicitly documenting H2 as a pinned known-bad case).

## Synthesis

The findings cluster into **four required structural changes**:

1. **Close the primitive set** (Lens A): add ~10 primitives (project, widen, try_unify_strict, merge_inferred_bound, meta_op_ret, subtract, escape_check, skolemize, subsume, env_instantiate) and add `B : tv_bounds` to Σ. Drop dead Σ components (`S`, `level`).

2. **Split C_CALLABLE** (Lens B + Lens C): into C_CALL_FUNCTION, C_RESOLVE_OVERLOAD, C_DISTRIBUTE_OVER_UNION (already), C_INFER_CALLABLE_BOUND. Each has one rule, one primitive shape, no per-tag branching with disjoint primitive sets.

3. **Commit to paradigm** (Lens D): "local type inference + bidirectional propagation." Drop OutsideIn vocabulary that pays no rent. Rename tiers to `{DECLARED, INFERRED}`. Explicit non-generalization statement. Name bidirectional check/infer modes.

4. **Specify rank-N properly** (Lens C): skolemize and subsume as named primitives; C_SUB and C_CALL_FUNCTION param loop reference them at TAG_FORALL; FLAG_SUB_SOLVE_PARAM spec'd as state with a contract; H2 record-of-generics surfaced as Gap C or addressed explicitly.

Plus **two correctness-quality fixes**:
- Resolve §0 ↔ §11 contradiction.
- Prove (or downgrade) the §10 solve2.lua collapse claim.
- Fix the TAG_VAR non-sub-solve-param silent T_ANY bind (real code bug surfaced by Lens B).
