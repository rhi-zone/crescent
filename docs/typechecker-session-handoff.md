# Typechecker Rework — Session Handoff

Handoff briefing for the next session. Captures findings, pitfalls, and
the architectural verdict that emerged across multiple iterations.

**Read this BEFORE any further typechecker rework work.**

## What's landed and durable

### Items 1-5 + 1.5 of the rework (commits chronological)

- `a017b046` test pin for rank-N gap (later flipped to pass).
- `3722dbfe` rank-N design.
- `289bc54d` **rank-N call-site subsumption landed** — the A1 from the original roadmap.
- Many docs/design commits during the audit phase.
- `bb930ab5` **FFI fixed-size-array element typing fix** — closed >1300 errors with a single missing case.
- `58d10766` + `0c2939d2` **brace-tuple positional-slot typing fix** (parser + expression side).
- `0540dc63` + `28122b24` typed payload accessors + typed constructors (cleanup).
- C2-C20 of the accessor cleanup series (15 commits, full migration of `Type.data` reads + constraint payloads).
- `bb88a5aa` **worklist-to-quiescence replaces 4-pass solver** (Item 1 of the architectural rework).
- `f5c68b29` **tier discipline (givens-before-wanteds)** (Item 2; deletes ad-hoc C_BOUND peek scans).
- `16fba213` `_hkt_payloads` migrated to C_HKT_DECOMPOSE payload (Item 3a).
- `8f472583` + `32c27491` + `dda7ead4` resolver flags as params + FLAG_SUB_SOLVE_PARAM (Item 4 series).
- `7dfb96a5` rename gen-pass scratch fields (Item 5 / 4f).
- `736b498d` + `00e3fd8d` emit-then-defer cleanup; dedup removed (Item 1.5).
- `63c55f18` **TV ownership mechanism** (`claim`/`release`/`is_owned`).
- `8b8c6bc4` `solve_index` ownership-aware.
- `4eebb1de` + `c3f59312` + `f2686228` + `e2762912` solve2.lua infrastructure P1-P4a (Outside-In/X scaffolding).

Test suite: 2809 assertions, all green. Per-file errors: types 12, env 2, constrain 31, solve 35, unify 0.

### Design docs (read these for context)

- `docs/typechecker-rank-n.md` (A1, landed)
- `docs/typechecker-hm-phase2.md` (HM Phase 2, landed pre-session)
- `docs/typechecker-architecture-from-first-principles.md` (14 decisions audited)
- `docs/typechecker-solver-architecture-v2.md` (resolution-barriers design, partial)
- `docs/typechecker-solver-bind-ordering.md` (givens-before-wanteds)
- `docs/typechecker-solver-rewrite.md` (Outside-In/X rewrite plan — see CAVEATS below)
- `docs/typechecker-solver-fundamentals.md` (51 → 6 fundamental distillation)
- `docs/typechecker-solver-invariant-inventory.md` (51-invariant audit — see CAVEAT below)
- `docs/typechecker-ad-hoc-inventory.md` + `-verification.md`
- `docs/typechecker-phase-f-blocker.md`
- `docs/typechecker-h2-correct-design-v1-superseded.md` + `-v2.md` + `-v3.md` (all H2 attempts)
- `docs/typechecker-hkt-h2.md` (H2 design)
- `docs/typechecker-hkt-broader.md` (B1)
- `docs/typechecker-variance.md` (A3, demoted to expressiveness)
- `docs/typechecker-data-accessor-cleanup.md`

## What's pinned as known gaps

- **H2 record-of-generics dispatch** is reverted (`9f025732`). Pins in `type_soundness_test.lua` at lines ~3875-3990: H2, H2a, H2b, H2e currently `has_error("Maybe%(_%)")`.
- A2 (HM Phase 2 field propagation) is done.
- A3 (variance) is demoted; structural invariance + FLAG_SKOLEM + function-param contravariance cover the soundness cases.

## CAVEATS — read carefully before trusting these docs

### Caveat 1: `typechecker-solver-rewrite.md` is incomplete

The rewrite plan says "port one constraint kind at a time, routing through solve2.dispatch_one." The session executed P1-P4a along these lines. **Finding mid-session: this is routing infrastructure, NOT actual handler rewrites.** The handlers themselves still have legacy synchronous bodies.

### Caveat 2: `typechecker-solver-invariant-inventory.md` overstates

The "51 invariants" claim was distilled to **6 fundamentals** in `typechecker-solver-fundamentals.md`. The user flagged the 51 as nonsensical; verification confirmed inflation by category-mixing. 5 of 6 fundamentals are already addressed by items 1-5+1.5; only **fresh instantiation at use site** (fundamental 6) is unaddressed.

### Caveat 3: Outside-In/X paradigm doesn't fully fit handlers

Late-session finding from attempting to rewrite `solve_unify` and `solve_callable` in OutsideIn/X paradigm:

- `solve_unify` is **already paradigm-shaped** (14 LOC, no top-level per-tag branches). The non-paradigmatic code lives in `unify_mod.unify` (700 LOC of synchronous structural recursion), not in the handler.
- `solve_callable` has top-level per-tag branches BUT they encode invariants that don't translate to OutsideIn/X emit-shape:
  - **Overload resolution (TAG_INTERSECTION)**: backtracking + first-success commit. Cannot be expressed as parallel emitted constraints.
  - **Union callable (TAG_UNION)**: synchronous aggregation of per-member outcomes into one union ret.
  - **Param loop (TAG_FUNCTION)**: mid-iteration GIVEN-deferral coupling (rank-N back-propagation).
  - **Argument widening**: synchronous context (callee_t params + ret expression simultaneously).

**Verdict**: classical OutsideIn/X emit-shape doesn't fully fit crescent's solver. Handlers that need backtracking, aggregation, or synchronous mid-iteration deferral resist the paradigm.

### Caveat 4: The pattern of audit-count-inflation

Every audit this session has inflated its count. Verified counts:
- 105+ "ad-hoc instances" → actual 90
- 18 ctx fields → actual 30
- 51 "invariants" → actual 6 fundamentals
- 5 "consumers needing is_owned" → actually solve_index only (audit missed that solve_check_args/solve_bind_generics ALSO read potentially-owned ret_TVs through their inner unify calls)

**Skeptically verify every audit count before acting on it.**

## What the next session should NOT do

1. **Don't pick up the OutsideIn/X rewrite plan as written.** Caveat 3 invalidates its core premise that "port via routing == rewrite via paradigm shift."
2. **Don't dispatch another agent to audit and find the "real target."** The pattern this session has been: dispatch → agent reports → adjust framing → repeat. Convergence has been slow because each iteration's framing was wrong about unit of work.
3. **Don't trust per-handler LOC estimates from any design doc.** They've been consistently off by 3-10x.
4. **Don't say "multi-session" or "out of scope" as a hedge.** User has banned these as defensive framing. If something is genuinely bigger than a session, say "needs N specific sub-pieces" not "multi-session."
5. **Don't revert items 1-5+1.5 or TV ownership.** They're durable progress.

## Key user-stated criteria (HOLD AS ANCHOR)

- Performant, maintainable, correct, no ad-hoc anything.
- "Ad-hoc conditions are strictly forbidden" (now in CLAUDE.md).
- "Our entire architecture is wrong" is a valid answer; saying so is part of the work.
- Audit counts should be challenged before being acted on.
- Stopping doesn't get us closer — but iterating in a non-converging pattern doesn't either.

## What's actually next (honest assessment)

The session's convergent finding is:

1. **The current solver architecture is mostly correct** at the structural level. Handlers do what they need to do; the mechanisms are explicit (post items 1-5+1.5 + TV ownership).
2. **The "non-paradigmatic" code** lives in `unify_mod.unify` (synchronous structural recursion, 700 LOC, used by `try_unify`, `is_subtype`, `types_overlap`, `widen_deep`).
3. **The "real" rewrite** would be at the unification module level, not the handler level. That's a multi-thousand-LOC refactor of foundational machinery.
4. **OutsideIn/X doesn't fit** handlers that need backtracking, aggregation, or synchronous mid-iteration deferral. A different paradigm (one that supports these natively) OR accepting these as legitimate synchronous semantics would change the framing.
5. **H2 record dispatch** remains pinned. Re-landing it requires resolving the producer→consumer ordering issue from the Phase F blocker doc, which TV ownership partially addressed but the `unify_mod.unify` synchronous-recursion machinery still complicates.

## Recommended next-session direction

Either:

**(A) Accept the current architecture as the structural shape.** Stop trying to rewrite; focus on making remaining mechanisms explicit (e.g., document why `solve_callable` is synchronous-by-necessity, name the invariants involved in `unify_mod.unify`'s recursion, prove `instantiate_at_use` IS the missing primitive in fundamental 6 and consolidate the three call paths through it as documentation work + a small refactor).

**(B) Pick a different paradigm than OutsideIn/X** for the rewrite. Candidates: continuation-passing (handles synchronous mid-iteration deferral natively), staged solving (gen-time phase + solve-time phase with explicit interface), or accepting accreted-but-documented structure.

**(C) Refactor `unify_mod.unify`** as the actual rewrite target (multi-thousand-LOC refactor of structural recursion into a different shape). Highest cost, deepest impact.

Personal lean: (A) is the most reliable under the user's criteria. The session's 15+ iterations show convergence happens at the structural/mechanism level (worklist, tier, TV ownership, terminal errors), not at the paradigm-shift level. Naming and documenting the synchronous semantics that exist is honest; trying to remove them produces the iteration pattern this session demonstrated.
