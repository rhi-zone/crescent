# Ad-Hoc Inventory — Independent Verification

Independent re-pass on `docs/typechecker-ad-hoc-inventory.md` (commit
`c8348ebb`). The session has been burned three times by single-agent
analyses that turned out wrong, so the inventory itself was verified
before being acted on.

## Headline corrections

- **30 distinct `ctx._foo` fields, not 18.** Full list:
  `_ann_warn_line, _last_multi_return_override, _allow_unapplied_constructors,
  _last_require_mod, _last_multi_return, _last_require_aliases, _multi_ret,
  _last_require_exports, _in_match_arm_subst, _template_fns, _sub_solve_params,
  _resolving_func_ann_scope, _require_exports, _missing_signatures, _in_match_arm,
  _cri_table_fields, _ann_consumed, _var_origin, _unseal_applied, _template_lines,
  _rank_n_call_counter, _overlap_warned, _overlap_byte_range, _open_table_tid,
  _opaque_view, _opaque_nominals, _opaque_cache, _hkt_payloads, _forall_ops,
  _forall_bounds`. Plus `_constraints` (1).
- **~90 total ad-hoc instances, not 105+.** The inventory's own per-shape
  numbers sum to 90; "105+" was a math error.
- **The "21 per-case carve-outs" are mostly principled dispatch, not
  workarounds.** Sample of 3 (TAG_SPREAD match evaluation, TAG_INDEX_TYPE
  lookup, TAG_TABLE recursion) confirmed.
- **The 30 fields fall into three distinct categories**, not one:
  - **Inter-phase message buses (redesign-able as payloads):** e.g.,
    `_hkt_payloads`, `_last_multi_return*`, `_template_fns`,
    `_require_exports`. These could plausibly become constraint payload
    fields.
  - **Intra-phase caches (not redesign-able as payloads):**
    `_ann_warn_line`, `_overlap_warned`, `_ann_consumed`,
    `_overlap_byte_range`. These are dedup/silence state, not inter-phase
    coordination.
  - **Architectural sub-solve state needed before constraints exist:**
    `_forall_bounds`, `_sub_solve_params`, `_in_match_arm`,
    `_resolving_func_ann_scope`. These are indexed by TV/generic and
    accessed during AST-walk/sub-solve, not during constraint solving.
- **The first-principles design doc DOES mention constraint-payload
  migration** in outcome II item 3 (`docs/typechecker-architecture-from-first-principles.md`).
  Buried, not headline, but the direction is there.

## What this changes

The inventory's "the constraint record can't carry tagged payloads, so
everything falls back to ctx mutation" framing was too sweeping. The
verified picture is more nuanced:

- For the inter-phase-message-bus subset (~5-10 fields), the constraint-
  payload migration is the right fix and is exactly what first-principles
  outcome II item 3 already proposes.
- For the cache subset (~4 fields), the dedup/silence machinery is a
  symptom of D6's "constraints can re-fire" issue, partially addressed
  by first-principles outcome II item 1 (worklist-to-quiescence) which
  removes re-firing.
- For the architectural sub-solve state subset (~5-10 fields), the
  appropriate fix is NOT constraint-payload migration — it's either
  parameter passing (explicit param set on sub-solve) or generalization
  refactor (Rémy levels).

So three of the 30 fields are addressed by first-principles outcome II
items 1, 2, 3 each. The remaining ~10 fields (require threading,
template tracking, missing-signatures accumulation, var-origin tracking,
etc.) are smaller categories that the first-principles doc doesn't
specifically address.

## Honest assessment

The first-principles design is closer to right than this session's
narrative had moved to suggest. The inventory's overstatement made it
look like a paradigm-change (outcome III) was needed; the verified
picture supports the coordinated three-decision fix (outcome II), with
the caveat that:

- Item 3 (payload migration) is smaller than the inventory implied — it
  applies to the message-bus subset, not all 30 fields.
- A *fourth* item is needed for the architectural sub-solve state subset
  — either explicit parameter passing or Rémy-style level generalization.
- The cache subset gets fixed as a side effect of item 1.

The red-team's critique of the first-principles doc ("the entangled
three is curated, not derived") was partially right — D11's scope is
real but smaller than implied; D2/D8 are NOT actually load-bearing in
the verified picture (the carve-outs aren't carve-outs).

## Recommendation

**The first-principles design is the right direction, with these
clarifications:**

1. Item 3 (payload migration) applies to a specific subset (~5-10
   inter-phase message bus fields), not all ctx fields. Sizing should
   reflect that subset, not the full 30.
2. A fourth item is needed for architectural sub-solve state. Likely:
   make sub-solve accept explicit param sets rather than reading
   `ctx._sub_solve_params`.
3. The cache subset (`_overlap_warned`, etc.) is fixed by item 1
   (worklist-to-quiescence eliminates re-firing).

This is still outcome II from the first-principles doc, just with the
sizing corrected and a fourth item added.

The red-team's recommendation ("stop-and-revise") still stands in
spirit, but the revision is small: clarify the scope of item 3 and add
the fourth item.

The inventory's recommendation ("stop and revert") was based on
overstated data and is no longer justified.
