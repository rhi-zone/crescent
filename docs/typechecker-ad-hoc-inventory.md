# Typechecker Ad-Hoc Inventory

Exhaustive cataloging of ad-hoc constructs in `lib/type/static/`. Done as
empirical evidence-gathering before any further architectural design. The
session's previous design iterations were derived from a small number of
failing canaries; this inventory derives from the *complete pattern* of
existing workarounds.

## Headline

**105+ ad-hoc instances** across `lib/type/static/`. Dominant shape: **magic
`ctx._foo` mutable fields used as inter-phase message buses (26 instances,
18 distinct fields)**. None of the five architecture design docs produced
this session names this as the load-bearing problem.

## Shape distribution

| Shape | Count | Examples |
|-------|-------|----------|
| 3: Magic ctx fields | 26 | `_forall_bounds`, `_sub_solve_params`, `_ann_warn_line`, `_last_multi_return*`, `_allow_unapplied_constructors`, `_template_fns`, `_missing_signatures`, `_var_origin`, `_ann_consumed`, `_multi_ret`, `_in_match_arm`, `_last_require_*`, `_overlap_*`, `_hkt_payloads`, `_forall_ops`, `_rank_n_call_counter`, `_unseal_applied`, `_require_exports` |
| 2: Per-case carve-outs | 21 | Operator-specific error messages, index type dispatch, sub-solve param checks |
| 4: Gen-time state read by handlers | 8 | `_last_require*` threading, `_var_origin` population, `_template_fns` recording, `_multi_ret` tracking |
| 1: Cross-kind peeks | 7 | Constraint list scanning in `propagate_function_bound`, `_require_exports` reading |
| 14: Per-kind exceptions in unify/sub | 6 | Bound constraint type-kind-specific logic |
| 10: Informational return fields | 5 | `await` field acknowledged but unused by dispatcher |
| 8: Late-firing fallbacks | 4 | Open table fallback to unknown, indexer bound deferral, arith deduction deferral |
| 13: Polymorphic clones | 3 | Tag-agnostic loop iteration over aggregates |
| 6: Dedup/silence machinery | 3 | `_overlap_warned`, `_ann_consumed` |
| 12: Intentionally-weird comments | 2 | Incomplete indexer bound emission, TODO direct reads |
| 9: Optimistic-then-fix-up | 2 | Overlap byte range caching, overlap deduplication |
| 5: Hard-coded budgets | 1 | 64-iteration cycle limit in nominal `__index` lookup |
| 7: Special-case typed casts | 1 | `--[[:! T]]` inline cast comments |
| 11: String/int encoding tricks | 1 | (line, col) packing in overlap cache |

## File distribution

| File | Count |
|------|-------|
| `constrain.lua` | 58 |
| `solve.lua` | 42 |
| Other | <5 |

## What every prior design missed

The five architecture design docs from this session — `typechecker-h2-correct-design-v1-superseded.md`, `typechecker-h2-correct-design-v2.md`, `typechecker-h2-correct-design-v3.md`, `typechecker-solver-architecture-v2.md`, `typechecker-solver-bind-ordering.md`, `typechecker-architecture-from-first-principles.md` — each focus on:

- subtyping / variance (`architecture-from-first-principles` D-list)
- solver scheduling (v2 resolution barriers, v3 phasing)
- binding order (bind-ordering doc)
- HM phase structure (H2-v3 doc)

**None address constraint schema design or phase-to-phase state threading.**
The inventory shows the actual core gap is **mutable multi-phase state
coordination through ctx fields** — not subtyping, not solver scheduling,
not binding priority.

Concrete consequence: every multi-phase coordination (gen→solve,
call→assignment, body sub-solve→generalization) falls back to mutating
a ctx dictionary keyed by type IDs or line numbers. The 18 distinct
`ctx._foo` fields each exist because the constraint schema can't carry
the metadata they encode.

## What this implies

Three observations the prior designs missed:

1. **The constraint record is the actual choke point**, not the solver.
   v2's resolution-barriers, v3's tier discipline, the first-principles
   D6+D11+D14 fix — all assume the constraint record can carry whatever
   metadata is needed. The inventory shows it can't. Every ctx field is
   a constraint payload field that wasn't put in the constraint because
   the record doesn't support tagged payloads.

2. **The gen/solve split is enforced by convention, not by mechanism**.
   18 ctx fields cross the gen/solve boundary as mutable side channels.
   The first-principles doc named D11 (gen-time mutable channels) as
   one wrong decision among three — but the actual count shows D11 is
   the **dominant** issue, not one of three coequal ones.

3. **Handler dispatch is sequential if-elif on type tags**, not table
   dispatch. The 21 per-case carve-outs reflect a per-handler accretion
   of special cases rather than a uniform dispatch model. Every new tag
   added to a handler is a new ad-hoc condition.

The principled architecture for crescent's typechecker is therefore:

- **Constraint schema with tagged payloads** that can carry arbitrary
  metadata. Each constraint kind has a typed payload schema; gen-time
  populates the payload; solver reads it. No mutable ctx fields for
  inter-phase data.
- **Explicit inter-phase API** instead of ctx-mutation conventions.
  Gen-time produces a complete constraint stream; solver consumes it.
  Sub-solve produces a complete sub-constraint set; outer solve consumes
  the result.
- **Proper dispatch tables** for handler-per-tag patterns.

This is **outcome III** in the first-principles doc's framing
("paradigm change"), not outcome II ("coordinated fix of D6+D11+D14").
The first-principles doc rejected III with "no evidence the constraint
paradigm itself is wrong" — but the evidence is here, in the inventory.
The constraint paradigm is fine; the constraint *record* is what's
wrong.

## Recommendation

**Do not proceed with any of the five existing design docs**. They are
all aimed at the wrong target.

Either:

(a) Spend a session iterating on this inventory to make sure the
analysis is correct (independent re-pass; quantify the perf cost of the
ctx fields; identify which ones are removable vs. structurally
necessary). Then design from the inventory, not from the canaries.

(b) Revert all session changes back to the H2-revert state
(`9f025732`); the design docs stay as archaeology but no implementation
work proceeds until the inventory has been digested.

Either path acknowledges that **the session's prior architectural work
was misdirected** — not wrong on details, wrong on target.
