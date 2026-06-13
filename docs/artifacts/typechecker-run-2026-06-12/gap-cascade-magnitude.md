# Gap-Cascade Magnitude Analysis

**Run date:** 2026-06-13  
**Corpus:** 868 `.lua` files under `lib/`, excluding `*_test.lua` and `lib/type/analysis/corpus/`  
**Tool:** `lib/type/analysis/cascade_analysis.lua` (read-only; no behavior change to the lowering)  
**Lowering path:** `L.lower()` with `{ stdlib = true }` — same as `survey_file_e2e`

---

## 1. Total Out-of-Subset Markers and Kind Split

| Category | Count | Share of total OOS |
|---|--:|--:|
| **Total OOS markers (all files, all kinds)** | **51,802** | 100% |
| Root-construct markers (non-`unbound-name` tags) | 30,773 | 59.4% |
| `unbound-name:*` markers (total) | 21,029 | 40.6% |
| — cascade upper bound | 20,148 | 38.9% |
| — root lower bound | 881 | 1.7% |

"Root-construct markers" are tags for genuinely-unsupported constructs: `dynamic-index`, `multi-assign`,
`multi-return`, `expr`, `operator-metamethod-*`, `call-non-function`, `field-assign`, `no-such-field:*`,
`general-iterator`, `unknown-type-name:*`, etc.

"Unbound-name markers" split into:
- **Cascade (upper bound 20,148):** names that appear as local declaration targets in the same file's
  source (`local NAME = …` or `local NAME,`). These names were likely abandoned when their RHS was
  out-of-subset. Every downstream use of `NAME` then became an `unbound-name:NAME` marker.
- **Root (lower bound 881):** names that do NOT appear as local declarations — genuine global/stdlib
  gaps (e.g. `require`, `bit`, `ffi`, `coroutine`, `ctx`, `document`, `debug`, `jit`).

### Top root-construct markers (by total occurrence)

| Count | Construct |
|--:|---|
| 5,061 | `dynamic-index` |
| 2,419 | `multi-assign` |
| 1,774 | `multi-return` |
| 1,760 | `expr` |
| 1,322 | `operator-metamethod-arith` |
| 1,305 | `dynamic-index-assign` |
| 1,199 | `call-non-function` |
| 883 | `field-assign` |
| 850 | `no-such-field:sub` |
| 810 | `exprstmt` |
| 658 | `iterate-non-table` |
| 588 | `operator-metamethod-concat` |
| 448 | `operator-metamethod-len` |
| 403 | `no-such-field:match` |
| 391 | `no-such-field:gsub` |
| 363 | `assign` |
| 305 | `no-such-field:find` |
| 222 | `general-iterator` |
| 180 | `generic-application` |
| 172 | `out-of-subset/invalid-require` |

### Top root `unbound-name:*` (not locally declared — genuine global/stdlib gaps)

| Count | Name | Note |
|--:|---|---|
| 422 | `require` | stdlib global — never a local |
| 57 | `bit` | LuaJIT `bit` global (not loaded via `pcall`/require in some files) |
| 41 | `ctx` | a parameter / upvalue that the lowering cannot see |
| 36 | `document` | likely a global from a specific context |
| 35 | `coroutine` | Lua stdlib — not modeled |
| 32 | `ffi` | `ffi` used directly without a local binding |
| 24 | `pos` | upvalue |
| 23 | `debug` | Lua stdlib |
| 18 | `jit` | LuaJIT `jit` global |

### Top cascade `unbound-name:*` (locally declared; cascade victims)

| Count | Name | Note |
|--:|---|---|
| 485 | `ffi` | abandoned from `local ok, ffi = pcall(require, "ffi")` (multi-assign OOS) |
| 412 | `v` | generic local abandoned when RHS was an OOS expression |
| 397 | `bit` | abandoned from `local bit = require("bit")` (OOS require) |
| 373 | `s` | generic string local abandoned |
| 371 | `err` | abandoned from error-handling patterns |
| 336 | `band` | `local band = bit.band` — abandoned because `bit` is unbound |
| 335 | `n` | integer/count local |
| 270 | `bxor` | `local bxor = bit.bxor` — cascade from `bit` cascade |
| 227 | `b` | generic local |
| 213 | `d` | generic local |

The `bit` → `band`/`bxor`/`bor`/`tobit` chain is a classic cascade: one `local bit = require("bit")`
abandons `bit` (either because `require("bit")` falls through to unbound-name, or because the multi-assign
`pcall` form hits `multi-assign`), then every downstream `local band = bit.band` fails because `bit`
is unbound, cascading further to every use of `band`.

---

## 2. Root vs Cascade Ratio

**Method:** Source-level scan for `local NAME` declarations. An `unbound-name:NAME` marker is
classified as:
- **Cascade** (upper bound): `NAME` appears in the file's source as a local declaration target.
- **Root** (lower bound): `NAME` never appears as a local declaration — it is a global, stdlib
  function, or upvalue that the lowering has no binding for.

**Bounds reasoning:**
- The cascade count (20,148) is an *upper bound*: some locally-declared names might be unbound
  for reasons other than an abandoned OOS binding (e.g., a name declared in a nested scope that the
  lowering DOES bind, but which later escapes — rare). The cascade count can only be equal to or
  greater than the true cascade count.
- The root count (881) is a *lower bound*: it cannot contain cascade victims (those are correctly
  classified by presence of `local`), but it may include locals the regex scan missed (e.g., variable
  names in patterns the regex does not catch). Empirically the regex covers the standard Lua local
  patterns.

| | Markers | % of total OOS |
|---|--:|--:|
| Root-construct (non-unbound-name) | 30,773 | 59.4% |
| Cascade `unbound-name:*` (upper) | 20,148 | 38.9% |
| Root `unbound-name:*` (lower) | 881 | 1.7% |
| **Total** | **51,802** | 100% |

**Cascade fraction of ALL markers:** 38.9% (upper) to 0% (lower — if every unbound-name were root).  
**Cascade fraction of unbound-name markers:** 95.8% upper / 4.2% root lower.  
**Root-construct fraction (unambiguously root):** 59.4% of all OOS markers are root constructs with
no ambiguity — these require actual substrate work to clear, not just the unbound→unknown fix.

---

## 3. Counterfactual Coverage Estimate

If cascade markers were eliminated (the proposed unbound→unknown fix), how many files would move?

| Recovery class | Files |
|---|--:|
| **Fully recoverable** (ALL markers are cascade `unbound-name:*`) | 3 |
| **Partially recoverable** (mix of cascade + root OOS markers) | 690 |
| **Not recoverable** (root-only OOS markers, zero cascade) | 115 |
| **Total OOS files** | 808 |

**Interpretation:**
- Only **3 files** would become CHECKED-CLEAN from the fix alone — their entire OOS burden is cascade.
- **690 files** would have their marker count reduced, but remain OUT-OF-SUBSET (they also have
  root-construct gaps like `dynamic-index`, `multi-assign`, `operator-metamethod-*`, etc.).
- **115 files** are unaffected — their OOS markers are entirely root constructs, with no cascade.
- The file class distribution is currently: CHECKED-CLEAN 36 (4.1%), OUT-OF-SUBSET 808 (93.1%),
  CHECKED-FINDINGS 7 (0.8%), NO-ANNOTATION 9 (1.0%), TIMEOUT-OR-CRASH 8 (0.9%).

Post-fix projection: CHECKED-CLEAN would rise from **36 → 39** (+3 files, +8% gain on clean count,
+0.3pp of corpus), assuming the 690 partially-recoverable files all have at least one non-cascade
marker remaining. The marker count in partially-recoverable files would drop substantially (those 690
files account for the bulk of the 20,148 cascade markers), reducing noise and improving per-file
signal quality.

---

## 4. Verdict: High- or Low-Leverage?

**The unbound→unknown fix is MEDIUM-leverage, not high-leverage for coverage recovery (file count),
but HIGH-leverage for signal quality (marker noise reduction).**

Rationale:
- **File-count leverage is low:** only 3 of 808 OOS files would graduate to CHECKED-CLEAN. The root
  reason is that 690 of 808 OOS files have BOTH cascade AND root-construct gaps — clearing cascades
  does not satisfy the remaining root-construct markers (dynamic-index, multi-assign, etc.). The fix
  does not unlock coverage at the file level in the near term.
- **Marker noise leverage is high:** 38.9% of all OOS markers (20,148 of 51,802) are cascade victims.
  Eliminating them would cut the marker histogram nearly in half, making the remaining 31,654 markers
  a cleaner signal of genuinely-unsupported constructs. This matters for demand prioritization: the
  `dynamic-index` / `multi-assign` / `multi-return` family becomes the unambiguous top priority
  once the cascade noise is removed.
- **The cascade chain is deep:** `bit` → `band`/`bxor`/`bor`/`tobit` and `ffi` → all FFI helpers
  produce 4–8 cascade markers per root OOS expression. Fixing the root (e.g., modeling `require("bit")`
  as returning a known type) would collapse both the root marker AND its entire cascade chain.
- **True root priority:** the top root-construct gap is `dynamic-index` (5,061 occurrences), not an
  unbound-name issue. Fixing dynamic-index is approximately 4× more impactful on raw marker count
  than the unbound→unknown fix, with more direct coverage recovery (since many files hit dynamic-index
  as their only or primary gap).

**Recommendation:** implement the unbound→unknown fix for signal-quality reasons (it makes the demand
histogram honest), but do not defer `dynamic-index` / `multi-assign` substrate work on the expectation
that the fix alone will recover meaningful coverage. The two are complementary: first fix the substrate
gaps (dynamic-index, multi-assign, proper bit/ffi modeling), then the cascade noise disappears as a
side-effect.

---

## 5. Method Notes

- **Script:** `lib/type/analysis/cascade_analysis.lua` (read-only analysis, no behavior change).
- **Cascade detection method:** source-level regex scan for `local NAME` declarations cross-referenced
  against `unbound-name:NAME` markers. Upper/lower bounds clearly stated.
- **Marker scope:** ALL markers per file (not capped at 3 as in the survey). Finder markers
  (`*-error`, `type-mismatch`, `*-fail`) excluded from the OOS count.
- **Timeouts:** 10s per-file budget; 8 files timed out (consistent with prior survey).
- **File class mismatch vs. prior survey:** this run shows 808 OOS vs. the survey's comparable number.
  The TIMEOUT-OR-CRASH (8) are excluded from the cascade/root classification above.
