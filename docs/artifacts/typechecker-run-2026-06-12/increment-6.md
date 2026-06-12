# Slice v2 increment 6 — the empty-fresh-table dynamic write + the diagnose-first re-ranking

Date: 2026-06-12. Design + implementation, one commit on `master`.
Design: `docs/agnostic-static-analysis-crescent-slice.md` §6.10 (derived whole);
findings §9.16; DONE entry §10.7. Survey delta: `docs/slice-survey-v1.md`
"after v2 increment 6". Map one-liner: `docs/static-analysis-map.md`.

## 1. The demand — diagnosed before designing (the load-bearing result)

The e2e histogram after increment 5 topped with `dynamic-index` (512 files),
`dynamic-index-assign` (482), `multi-assign` (450), `multi-return` (317). The
prompt named these as gated by the three §9.15 deferrals (§9.15.4
heterogeneous/empty closed-rec write, §9.15.5 `return f()` multi-spread, §9.15.6
body-synthesized multi-return join) and instructed: **verify rather than assume,
and let the samples rank the work.**

A per-MARKER diagnostic harness (the increment-5 pattern, extended to report each
marker's FIRING REASON — not just its collapsed tag) lowered all 867 corpus files
and bucketed every top-tag marker. The reasons (total marker counts):

| Tag | Dominant sub-shape (the measured residue) | Count |
|---|---|--:|
| `dynamic-index-assign` (3869) | **EMPTY closed-rec write `out = {}; out[k] = v`** (the fresh-table build idiom) | **2548** |
| | heterogeneous closed-rec write (the §9.15.4 named shape) | **≈1** |
| `multi-assign` (2440) | `local x,y = f(args)` — producer fn recovered, CALL synth-fails on an ARGUMENT (924) or `unknown`/unannotated callee (636) | ~1560 |
| `multi-return` (1815) | `return a, b` where a VALUE expr (`name` 719, `binop` 605, `call` 187, `nil` 174) is out-of-subset | 1685 |
| | `return f()` SPREAD (the §9.15.5 named shape) | **0** |
| `dynamic-index` read (5058) | obj-oos name/index (1737); indexer keyed by `union{integer,number}` (1332); obj `unknown` (877); key-oos (745) | — |

**The diagnosis contradicted the deferrals' framing — this IS the increment:**

- §9.15.4 is dominated by the EMPTY case (2548), not the heterogeneous case (≈1).
- §9.15.5 (`return f()` spread) has **zero corpus demand**.
- The `multi-assign` / `multi-return` tags are **downstream coverage symptoms** —
  the assignment/return MECHANISMS landed in increment 5; the markers fire because
  an *argument expression* or a *value expression* is out-of-subset.
- The `dynamic-index` indexer-union-key residue is `union{integer, number}` — a
  soundly-rejected `number` key into an `[integer]` array; an UPSTREAM
  arithmetic-precision gap, not an index rule.

## 2. The design (§6.10), derived from the measured shapes

The one sound, in-fence, family-relevant item: the **empty-fresh-table dynamic
write**. `t[e] = v` where `t : rec{}` (an empty closed rec) lists NO field, so
there is no declared element type a write could violate. The sound write target is
`unknown`: `v ⇐ unknown` rejects no correct program, and it is SOUND (not merely
permissive) because the empty-rec READ rule (`index_result`, §6.9.2) returns `nil`
for every read — so accepting the write can never license an unsound read. This is
the **WRITE dual of the open-row rule** (open row ⇒ `unknown` because the element
type is hidden): no fields ⇒ no constraint, exactly as an open row hides its
element type. No special case.

## 3. What was built

`lib/type/analysis/crescent_slice.lua` — `index_write_target`, `rec` branch: when
`#fields == 0` (after the open-row check), return `G.unknown()` instead of `nil`.
ONE branch in ONE function. The §9.15.3 split (the write target is its OWN function,
distinct from `index_result`) is what makes this sound and local — the READ rule
still returns `nil` for the empty rec (no false reads). No new evidence method, no
subtype change, no lowering change, no substrate change.

## 4. Per-item status (the three named deferrals)

| Deferral | Status | Evidence |
|---|---|---|
| §9.15.4 EMPTY closed-rec write | **DONE** (the dominant real shape) | inline test CLEAN; `dynamic-index-assign` markers 3869 → 1321 (−2548) |
| §9.15.4 HETEROGENEOUS closed-rec write | **RE-DEFERRED** (§9.16) — ≈1 corpus site, essentially dead; un-defer: rec-field-widening | inline test OUT-OF-SUBSET (retained) |
| §9.15.5 `return f()` multi-spread | **RE-DEFERRED as DEAD** — 0 corpus sites | instrumented spread marker: 0 occurrences across 867 files |
| §9.15.6 body-synthesized multi-return join | **RE-DEFERRED** unchanged — behind the shared local-return-type-collection pass | not a top-tag blocker (tags are downstream coverage) |

## 5. The e2e headline + construct delta

`bin/cr run lib/type/analysis/slice_survey.lua --e2e` (867 files, 5s budget):

| Class | after incr 5 | after incr 6 |
|---|--:|--:|
| CHECKED-CLEAN | 25 (2.9%) | **26 (3.0%)** |
| CHECKED-FINDINGS | 9 (1.0%) | 13 (1.5%) |
| OUT-OF-SUBSET | 827 (95.4%) | **822 (94.8%)** |
| TIMEOUT | 0 | **0** |

**The construct-histogram delta is the honest progress measure** (the whole-file
gate is the LAST out-of-subset construct per file; the empty-rec write is rarely a
file's last blocker, so the gate moves +1 while the histogram moves far more):

| Construct | after incr 5 (files) | after incr 6 (files) | delta |
|---|--:|--:|--:|
| `dynamic-index-assign` | 482 (#2) | **282 (#4)** | **−200 files** |

The per-MARKER count for `dynamic-index-assign` fell **3869 → 1321 (−2548)** —
exactly the empty-rec writes, now in-subset.

The CHECKED-FINDINGS rise (9 → 13) is **reach, not regression**: four files whose
last out-of-subset construct was the empty-rec write now lower past it and surface
their PRE-EXISTING downstream findings (recursive-type / field-path-narrowing
type-mismatches, the §9.8 deferral family). The one file with a rejection
(`lib/unified/rehype_meta/init.lua`) ALREADY had `rej=1, unk=1` at HEAD — verified
by re-running it against the stashed working tree; the empty-rec change did not
introduce it, it only stopped masking it earlier. No soundness regression.

## 6. Findings count

**§9.16: 5 findings** — 1 sharpest finding (the §9.15.4 deferral's real shape is
EMPTY 2548 / heterogeneous ≈1, and the empty case needs `unknown`, not the named
rec-field-widening trigger), 1 dead-deferral finding (§9.15.5 has 0 corpus sites),
1 re-framing finding (the `multi-assign`/`multi-return` tags are downstream
argument/value-expression coverage, not the landed mechanism), 1 substrate-framing
finding (the indexer-union-key residue is an arithmetic-precision gap, refused as
unsound special-casing), and 1 reach-not-regression finding (the CHECKED-FINDINGS
rise, with the one rejection verified pre-existing at HEAD).

## 7. Verification

- Full analysis suite green: **6427 assertions** (6421 + 6 net), 0 failed.
- `timeout 30 bin/cr check lib/type/analysis/crescent_slice.lua`: 0 errors, 4
  warnings — IDENTICAL to HEAD (verified by stash; the line-527 warning pre-existed).
- 0 TIMEOUT in the e2e survey.
- Corpus 11-fixture split: 4 CLEAN / 1 FINDINGS / 6 OUT-OF-SUBSET → **6 CLEAN /
  1 FINDINGS / 4 OUT-OF-SUBSET** (pairs_return_leak + table_construction_widening →
  CLEAN, both their last boundary), **0 rejections anywhere**.
- 0-rejection discipline on fixtures: both reclassified fixtures' own headers
  require "Accepts with 0 errors" — CLEAN is the correct verdict, not a relaxation.

The fence held. Substrate (`init.lua`) **untouched**, byte-for-byte. The diagnostic
harnesses (`slice_diag6*.lua`) were temporary measurement scaffolds, removed before
commit; the production survey (`slice_survey.lua`) is unchanged.
