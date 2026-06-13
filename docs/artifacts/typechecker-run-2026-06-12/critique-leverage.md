# Critique: Leverage Claim 4 — Totality as Highest-Leverage Fix on the Per-Property Axis

**Role:** adversarial pragmatics/leverage critic  
**Target claim (design thesis §4, Claim 4):** The unbound→`unknown` totality fix is
highest-leverage *on the correct per-property axis*, specifically "error-classes caught
/ sites soundly checked corpus-wide."  
**Run date:** 2026-06-14  
**Measurement tool:** `lib/type/analysis/per_property_metric.lua` (read-only; no
behavior change to the lowering)  
**Corpus:** 869 `.lua` files under `lib/`, excluding `*_test.lua` and
`lib/type/analysis/corpus/`  

---

## 1. The Per-Property Metric

**Metric: Sound-Verdict Sites (SV)**

A sound-verdict site is any expression/statement site in the corpus that receives a
typed verdict from the checker — i.e., contributes to exactly one of
`accepted_claims`, `rejected_claims`, or `unknown_claims` in the substrate's
`CheckResult`. All three are *sound*: `accepted_claims` is a positive judgement with
evidence; `rejected_claims` is a negative finding; `unknown_claims` is an inconclusive
verdict (propagated `unknown`). In all three cases, the site is *checked*, not
abandoned.

The complement is **abandoned sites**: OOS markers in `res.markers` that produce no
claim. Each marker = one site where the checker bailed instead of producing a verdict.

**Formal definition:**

```
SV = Σ_files (|accepted_claims| + |rejected_claims| + |unknown_claims|)
Total_potential = SV + Σ_files |OOS_markers|
Coverage_frac = SV / Total_potential
```

This is a stricter metric than whole-file `CLEAN%`, which is binary per file. SV is
additive across sites — gains accumulate regardless of whether a file crosses the
CHECKED-CLEAN threshold.

---

## 2. Current Measurement

| Metric | Value |
|---|--:|
| **accepted_claims (corpus)** | **82,371** |
| rejected_claims (corpus) | 373 |
| unknown_claims (corpus) | 482 |
| **Total SV (current baseline)** | **83,226** |
| Total OOS markers (abandoned sites) | 51,848 |
| — root-construct markers | 30,794 (59.4% of OOS) |
| — cascade unbound-name (upper bound) | 20,170 (38.9% of OOS) |
| — root unbound-name (lower bound) | 884 (1.7% of OOS) |
| **Total potential sites (SV + OOS)** | **135,074** |
| **Current SV coverage** | **61.6% of all potential sites** |

File class distribution: CHECKED-CLEAN 36 (4.1%), OUT-OF-SUBSET 809 (93.1%),
CHECKED-FINDINGS 7 (0.8%), NO-ANNOTATION 9 (1.0%), TIMEOUT 8 (0.9%).

---

## 3. Cascade Scope Analysis (for the Totality Fix)

The design thesis claims the totality fix (unbound→`unknown`) recovers the 20,170
cascade-unbound markers as sound-verdict sites. This requires scrutiny.

**The cascade chain has two root types:**

1. **Root-construct roots:** `local x = <dynamic-index-expr>` or
   `local band = bit.band` (when `bit` was dropped by a root-construct OOS, not a
   root-unbound-name gap). Here, the totality fix *does* recover the downstream
   cascade: the OOS expression now returns `unknown` instead of `(nil,nil)`, the
   `local x` gets bound to `unknown`, and downstream `x.f` / `x + 1` produce real
   claims (checked against `unknown`).

2. **Root-unbound-name roots:** `local bit = require("bit")` where `require` is an
   `unbound-name:require` gap (root-lower, not a cascade). The totality fix does NOT
   help here: `require` is still unbound → `bit` is still abandoned → `band`/`bxor`
   are still cascade victims. Only fixing `require` (adding stdlib modeling) recovers
   this chain.

**Measurement of pure-cascade vs. mixed-cascade:**

| Category | Cascade markers |
|---|--:|
| Pure-cascade (files with zero root-unbound-name markers) | 10,058 |
| Mixed-cascade (files with ≥1 root-unbound-name markers) | 10,112 |

So roughly **half** (10,058 / 20,170 = 49.9%) of the cascade markers are in files
where the cascade root is ambiguous — they co-exist with root-unbound-name markers,
and many of those cascade chains are rooted in `require`/`ffi`/`coroutine` gaps that
the totality fix doesn't touch.

**Totality fix gain bounds:**

| Bound | SV gain | Pct of current SV |
|---|--:|--:|
| Conservative (pure-cascade files only, ~certain to be recovered) | +10,058 | +12.1% |
| Upper (all cascade markers, assumes totality fix recovers every chain) | +20,170 | +24.2% |

The thesis's claim of "cuts the marker histogram nearly in half" is the upper bound.
The honest gain on the per-property axis lies in [+12.1%, +24.2%] of current SV.

---

## 4. Root-Construct Fix Gains (Static Estimate)

For each root-construct fix, the gain is:
- **Direct:** each root-construct marker becomes a sound-verdict site.
- **Indirect:** cascade chains rooted in that construct are recovered. Estimated
  using the pure-cascade fraction proportional to the construct's share of total
  root-construct markers (a structural estimate; actual cascade-per-construct is
  unmeasured but bounded above by pure_cascade × construct_share).

| Fix | Direct SV gain | Est. indirect gain | Total est. gain | Pct of current SV |
|---|--:|--:|--:|--:|
| **dynamic-index** | +5,065 | +1,654 | **+6,719** | **+8.1%** |
| multi-assign | +2,419 | +790 | +3,209 | +3.9% |
| multi-return | +1,775 | — | +1,775 | +2.1% |
| expr | +1,761 | — | +1,761 | +2.1% |
| **Top-4 combined** | +11,020 | +2,444 | **+13,464** | **+16.2%** |

Note: the indirect cascade estimates for multi-return and expr are not computed
separately because they are less likely to produce named-local cascade chains (a
multi-return that's OOS doesn't bind a local unless the return value is captured in
a `local a, b = f()`; those are counted under multi-assign). The estimate is
conservative.

---

## 5. Comparison: Totality Fix vs. Root-Construct Fixes

| Intervention | SV gain (conservative) | SV gain (upper) | Notes |
|---|--:|--:|---|
| **Totality fix** | +10,058 | +20,170 | Half the upper-bound gain requires stdlib fixes too (require/ffi) |
| **dynamic-index fix** | +6,719 | ~+8,000 | Direct + cascade; structural estimate |
| **top-4 root constructs** | +13,464 | ~+16,000 | di + ma + mr + expr, with cascade |

**Key comparison:**

- The **totality fix at its conservative bound (+10,058 SV)** is larger than
  **dynamic-index alone (+6,719 SV)** — totality wins on the per-property axis when
  compared against any *single* root construct.
- However, the **top-4 root constructs combined (+13,464 SV conservative estimate)**
  *exceed* the totality fix's conservative gain (+10,058) and are competitive with
  its upper bound (+20,170). If the 4 root-construct fixes each took the same
  engineering effort as the totality fix, the root-construct path dominates in
  aggregate.
- The totality fix's **upper bound (+20,170 SV)** exceeds the top-4 combined
  conservative estimate — but this upper bound requires that ALL 20,170 cascade
  markers are recovered, which requires also fixing `require`/`ffi`/`coroutine`
  stdlib modeling (not just the unbound→unknown patch). The totality fix *alone*
  achieves only [+10,058, +20,170].

**The thesis's most important claim is sustained but qualified:**

The thesis claims totality is highest-leverage on the per-property axis relative to
"a root-construct fix." Against *any single* root construct, this is true: the
conservative totality gain (+10,058) exceeds `dynamic-index` alone (+6,719) by 1.5×.

But the thesis's framing obscures a compounding asymmetry:

1. **Totality gain is a ceiling, not a floor.** The upper bound (20,170) is only
   achievable if stdlib gaps (`require`, `ffi`) are fixed simultaneously. The
   totality fix *alone* gets you at most the pure-cascade recovery (+10,058), and
   possibly less (some pure-cascade files may still have mixed cascade roots that
   the regex scan miscounts as "pure").

2. **Root-construct gains are independent and additive.** Each root-construct fix
   (dynamic-index, multi-assign, etc.) independently contributes SV gain. Three root-
   construct fixes in sequence equal or surpass the totality fix's realistic gain,
   and as a side-effect remove the cascade chains rooted in those constructs — making
   the cascade count shrink without needing the totality patch at all.

3. **dynamic-index fix also cleans up cascade.** If `dynamic-index` is fixed, the
   cascade chains rooted in `local x = t[k]` patterns disappear too. The totality
   fix does not reduce the `dynamic-index` gap; the `dynamic-index` fix eliminates
   both the direct gap and the cascades from it.

4. **The signal-quality argument is real but not a per-property argument.** The
   cascade analysis (`gap-cascade-magnitude.md §4`) argues the totality fix improves
   "signal quality" by making the demand histogram honest. This is accurate but is a
   *meta-metric* (legibility of the gap histogram), not the per-property SV metric
   the thesis retreated to. On the SV metric itself, signal quality is irrelevant.

---

## 6. Verdict on Claim 4

**PARTIAL — totality is not falsified as keystone, but the "highest-leverage on
the per-property axis" formulation overstates the case.**

More precisely:

- **SURVIVED** (against single-construct comparison): The totality fix conservative
  gain (+10,058 SV, +12.1%) exceeds dynamic-index alone (+6,719 SV, +8.1%). On the
  axis of "beats the top single root-construct fix," the claim holds.

- **FALSIFIED** (against compound comparison): The top-4 root constructs combined
  (+13,464 SV, +16.2%) exceed the totality fix's conservative gain and are
  competitive with its upper bound — without requiring the totality patch at all, and
  without the caveat that half the gain depends on also fixing stdlib gaps. A
  4-construct substrate expansion dominates totality on the per-property SV metric.

- **The thesis's framing creates a false dichotomy.** It pits "totality fix" against
  "dynamic-index fix" as if these are competing keystone choices. But the compound
  root-construct path (fix the top 4, which takes the same or similar total effort as
  totality + stdlib) returns *more SV per engineering unit* than totality, and as a
  side-effect removes cascade chains rooted in those constructs.

- **Prioritization implication:** If the goal is maximizing SV sites on the
  per-property metric, the honest priority order is:
  1. Fix dynamic-index first (highest single-construct gain, +8.1%).
  2. Then multi-assign (+3.9%), multi-return (+2.1%), expr (+2.1%).
  3. Then — or in parallel — the totality fix (+12.1% conservative), which at this
     point has a smaller *marginal* gain since dynamic-index and multi-assign are
     already fixing their cascades.
  The `gap-cascade-magnitude.md §4` recommendation ("fix substrate gaps first, totality
  fix for signal quality") is more accurate than the thesis's keystone framing.

---

## 7. Method Notes

- **Script:** `lib/type/analysis/per_property_metric.lua` (read-only analysis; no
  behavior change to the lowering or checker).
- **Corpus:** 869 `.lua` files under `lib/` (one more than the 868 in the cascade
  analysis run; consistent with normal corpus growth).
- **SV counts** are live from `A.check()` per file — not estimated.
- **OOS marker counts** are live from `L.lower()` per file — not estimated.
- **Cascade root classification** uses the same source-level regex as
  `cascade_analysis.lua` (upper/lower bound semantics apply identically).
- **Indirect cascade estimates** are structural: `pure_cascade × (construct_count /
  total_rc_markers)`. This distributes cascade proportionally to root-construct
  occurrence, which is a conservative approximation (actual cascade-per-construct
  requires deeper chain analysis not yet built).
- **Timeout:** 10s per file; 8 files excluded (TIMEOUT class).
- **No behavior change:** no OOS expression was patched to return `unknown`; the
  metric measures *current* behavior with *static counterfactual estimates* for
  post-fix gains.
