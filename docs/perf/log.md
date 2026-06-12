# Performance Log

Experiments, measurements, and verdicts. Most recent first.

Bench machine: AMD Ryzen 7 5700G, LuaJIT 2.1.1741730670, NixOS Linux 6.12.67.

---

## 2026-06-12: analysis substrate — dependency-driven worklist + structural-key memoization

Benchmark: `bin/cr run lib/type/analysis/check_bench.lua`. Baseline `13f0eb4c`
(pre-change `A.check`), optimization `00176f52`.

Two substrate changes to `A.check` (`lib/type/analysis/init.lua`), both pure
substrate vocabulary (claims, evidence, inputs, structural keys), behavior-identical
(same accepted/rejected/unknown classification; all 4906 assertions across the six
hosted semantics pass unchanged):

1. **Dependency-driven worklist.** The old fixpoint re-swept *every* pending
   evidence object each round — O(rounds × evidence). The new loop seeds a queue
   with each evidence once and, when an evidence accepts its claim, re-queues only
   the evidence whose declared inputs reference that claim (via a `dependents`
   index built once over all input edges). Sound because every hosted checker reads
   accepted-ness solely through `ctx.is_accepted(ev.inputs[k])`, so an input claim's
   acceptance is the only event that can flip a pending evidence.
2. **Per-check structural-key memoization.** Each `is_accepted`/`accepted_result`
   probe re-serialized the full (deep) claim args via `claim_key`. The key is now
   cached per claim (keyed by `idk(id)`, cheap; the cached string is byte-identical),
   so each claim serializes once instead of once per probe.

| Case | Baseline (`13f0eb4c`) | Optimized | Speedup |
|---|--:|--:|--:|
| synthetic chain, 100 claims | 0.0022 s | 0.0004 s | ~5× |
| synthetic chain, 1 000 claims | 0.1434 s | 0.0022 s | ~65× |
| synthetic chain, 5 000 claims | 5.2561 s | 0.0114 s | ~460× |
| real: `lib/type/v7_mr0/init.lua` lowered (2724 claims/evidence, 713 requested) | 21.64 s | 14.49 s | ~1.5× |

The synthetic chain (a reverse-order linear dependency chain — the adversarial case
for a re-sweeping fixpoint) confirms the worklist removes the O(N²) re-sweep: the
curve is now linear. The real `v7_mr0` case is no longer worklist-bound; the
remaining 14.49 s splits ~5.3 s substrate (the one-time structural serialization of
2724 deep claim args — the floor imposed by structural claim identity) and ~8.5 s
**inside the hosted slice checker** (repeated `parse_ctx`/`parse_type`/`subtype` on
claim args). The substrate check loop is now optimal for this graph; the dominant
cost has relocated into the hosted semantics, which is out of substrate scope (the
substrate must not reach into a hosted checker). Consequently the e2e survey's 1
TIMEOUT (`slice_survey.lua --e2e`, 5 s budget) **persists** — it is now
hosted-checker-bound, a distinct follow-up finding, not a substrate-loop defect.

---

## 2026-06-12: C_BIND_GENERICS livelock fix — full-tree parallel cold check (8× speedup)

Baseline: `ec390737` (pre-fix). Fix: `bd06264e` (per-constraint instantiation cache in `lib/type/static/solve.lua`).

Mechanism: the `C_BIND_GENERICS` handler was re-instantiating a fresh callee on every re-seed (defer-after-mutation cycle), advancing `gen` without retiring the constraint and growing the arena by ~31 TypeSlots/call. >1 M calls on `lib/bloom/init.lua` alone → arena exhaustion → SIGSEGV. The fix caches the instantiated callee per constraint across re-seeds, breaking the livelock; rounds cap <200 on bloom.

| Measurement | Baseline (`ec390737`) | Fix (`bd06264e`) |
|---|---|---|
| Full-tree parallel cold check (`bin/cr check`) | 167–185 s | 20–22 s |
| `bin/cr check lib/bloom/init.lua` | crash (exit 139) | verdict in <60 s (1 error / 25 warnings) |
| `bin/cr test lib/type/static/` | 10 passed / 1 pre-existing TAG_SPREAD failure | 10 passed / 1 pre-existing TAG_SPREAD failure (no regressions) |
| Corpus verdict changes | — | 6 crash→verdict wins; zero other verdict changes |

Speedup: ~8× (167–185 s → 20–22 s) on the full-tree parallel cold-check path, driven entirely by eliminating the livelock's arena growth and associated swap pressure.

---

## 2026-06-12: crescent slice v1 — audit round 1, finding 4 (subtype memoization)

Benchmark: `bin/cr run lib/type/analysis/slice_subtype_bench.lua`. LuaJIT 2.1.1774896198.

Adversarial audit finding 4: `M.is_subtype` was exponential on **shared-subterm
DAGs**. The cycle-guard `seen` stack covered only μ-unfold pairs; rec/union/fn
descent re-explored shared interned subterms, so a `{ a: child, b: child }` chain
(both fields the same interned child) re-decided each child twice per level —
O(2^n). The perf wall: `dag(30)` did not return within 120s.

Fix: per-query **memoization** of every fully-decided `(tidA, tidB)` pair (interned
tid-pairs are a trivial, sound key). Coinductive correctness is preserved — an
in-progress μ pair short-circuits via the coinductive hypothesis BEFORE the memo
write, so a provisional `true` is never cached. The DAG shape is now linear.

New measured numbers (full bench re-run after the fix):

| Query (1 `is_subtype` call per iteration) | iters | total ms | ms/query |
|---|---|---|---|
| `hamt <: hamt` (reflexive, interned) | 100000 | 0.087 | 0.0000009 |
| `hamt <: unfold(hamt)` | 100000 | 439.068 | 0.00439 |
| `Interior(hamt) <: hamt` (coinductive) | 100000 | 485.390 | 0.00485 |
| `deep_mu(40) <: deep_mu(40)` (interned refl) | 100000 | 1.258 | 0.00001 |
| `deep_mu(40) <: unfold(deep_mu(40))` | 20000 | 1931.078 | 0.09655 |
| `wide_union(200) <: wide_union(200)` (interned refl) | 20000 | 0.355 | 0.00002 |
| `wide_union(200) <: wide_union(400)` | 20000 | 66883.031 | 3.34415 |
| `lit_int(150) <: wide_union(200)` | 20000 | 427.377 | 0.02137 |
| `wide_inter_records(60) <: f1-record` | 20000 | 4.670 | 0.00023 |
| `wide_inter_records(60) <: wide_inter(60)` (interned refl) | 20000 | 0.232 | 0.00001 |
| **`dag(30) lit_int(1) <: dag(30) integer`** (NEW, the perf-wall shape) | 20000 | 133.322 | **0.00667** |
| **`dag(40) lit_int(1) <: dag(40) integer`** (NEW) | 20000 | 178.006 | **0.00890** |

The previously-unmeasurable `dag(30)` query (>120s pre-fix) is now **0.00667
ms/query**, and `dag(40)` is **0.00890 ms/query** — linear in DAG size, ≈10^6×
under the timeout-30 ceiling. The depth-30 perf wall is gone (a single
non-iterated `dag(30)` query measures ~0.00s wall).

Heaviest single query (deep_mu(40) unfold) probe: **0.052 ms** — 30000 ms ceiling,
~577000× headroom. The slowest *realistic* per-query case remains the union
cross-product `wide_union(200) <: wide_union(400)` at **3.34 ms/query** (the m×n
union-width floor; absolute timings here run ~2× the prior machine entry below
because of a different bench host/JIT build — the *shape* is unchanged, and it is
still ~9000× under the ceiling). Memoization does not regress these shapes.

Verdict: **clears timeout-30 with enormous margin, and the exponential DAG class is
retired.** Replay: `bin/cr run lib/type/analysis/slice_subtype_bench.lua`.

---

## 2026-06-12: crescent slice v1 — Pass 1 subtype-relation benchmark (§5.1)

> Superseded by the audit-round-1 entry above (memoization added; DAG shape added
> to the bench). Retained for the pre-memoization baseline.

**Commit (Pass 1):** committed in this change; baseline HEAD before it = `7a6b9d5c`.
Benchmark: `bin/cr run lib/type/analysis/slice_subtype_bench.lua`. LuaJIT 2.1.1774896198.

The kernel's §5.1 highest-priority risk: the v1 structural+union+μ subtype relation
must decide every adversarial corpus shape well within the timeout-30 ceiling. A
single query exceeding it is a soundness/termination signal, not a slow case. This
records the actual numbers for the hash-consed, cycle-guarded relation.

Adversarial shapes: the hamt-shaped recursive type (`μX.(Leaf | Interior(X))`),
deep μ nesting (`deep_mu(40)` — 40 nested binders), wide unions (200 / 400 literal
singletons), and a wide intersection of 60 open records.

| Query (1 `is_subtype` call per iteration) | iters | total ms | ms/query |
|---|---|---|---|
| `hamt <: hamt` (reflexive, interned) | 100000 | 0.046 | 0.0000005 |
| `hamt <: unfold(hamt)` | 100000 | 235.607 | 0.00236 |
| `Interior(hamt) <: hamt` (coinductive) | 100000 | 252.839 | 0.00253 |
| `deep_mu(40) <: deep_mu(40)` (interned refl) | 100000 | 3.714 | 0.00004 |
| `deep_mu(40) <: unfold(deep_mu(40))` | 20000 | 1094.023 | 0.05470 |
| `wide_union(200) <: wide_union(200)` (interned refl) | 20000 | 0.846 | 0.00004 |
| `wide_union(200) <: wide_union(400)` | 20000 | 28737.573 | 1.43688 |
| `lit_int(150) <: wide_union(200)` | 20000 | 208.040 | 0.01040 |
| `wide_inter_records(60) <: f1-record` | 20000 | 2.551 | 0.00013 |
| `wide_inter_records(60) <: wide_inter_records(60)` (interned refl) | 20000 | 0.800 | 0.00004 |

Heaviest single query (deep_mu(40) unfold): **0.047 ms** — vs the 30000 ms ceiling,
~638000× headroom.

**Verdict: clears timeout-30 with enormous margin.** The worst per-query case is the
adversarial `wide_union(200) <: wide_union(400)` at **1.437 ms/query** — its `m×n`
member cross-product (200 left members, each scanned against up to 400 right
members) is the relation's quadratic floor on union width, and it is still ~20000×
under the ceiling. Reflexive/interned queries are effectively free (a tid compare),
confirming the hash-cons interner does the load-bearing termination work: every
recursive shape's identity collapses to a tid, so the cycle guard fires in O(1) and
no μ unfolds unboundedly. The §5.1 risk does not block any v1 extension.

Replay: `bin/cr run lib/type/analysis/slice_subtype_bench.lua`.

---

## 2026-05-26: v5 Phase 5.F — refreshed `bin/cr check --v5` wall-time comparison

**Commits (5.F baseline):** 5.F1 = `a32b0a74`, 5.F2 = `05fd0777`, 5.F3 = `656c8596`,
5.F4 = `93311447`. HEAD at time of measurement = `93311447`.

This entry supersedes the earlier "v5 source pipeline" entry below. The prior measurement
(v5 3.5× faster on demo_effects.lua) was incomplete-coverage fast: v5 was silently skipping
the F2 enforcement check for dotted callees and returning flat `boolean | unknown` from pcall.
After Phase 5.F all four gaps are closed. The demo now correctly errors on the deliberate
F2 violation in section 7. These numbers reflect the honest, gap-closed state.

### demo_effects.lua (lib/type/static-v5/fixtures/demo_effects.lua)

100 LOC. Exercises multi-effect propagation, pcall `!throw` absorption, coroutine `!yield`
consumption, and a deliberate F2 violation (section 7). v5 exits 1 (1 error, correct).
v4 exits 0 (0 errors, 5 warnings — no effect enforcement in v4).

| Checker | Run 1 | Run 2 | Run 3 | Median | Errors | Warnings |
|---|---|---|---|---|---|---|
| `bin/cr check` (v4) | 30ms | 25ms | 32ms | 30ms | 0 | 5 |
| `bin/cr check --v5` | 10ms | 10ms | 11ms | 10ms | 1 | 0 |

v5 is **~3×** faster on this file. Caveat: the two checkers produce different results —
v4 misses the F2 violation entirely (not a regression, it's expected; v4 has no effect
enforcement). Error counts are not comparable across checkers. Wall-time difference reflects
dispatch overhead on a 100-LOC file; both are well below any useful threshold.

**Raw output (one trial each):**

```
# v4 (bin/cr check)
/tmp/crescent-precommit.*/staged/lib/type/static-v5/fixtures/demo_effects.lua:23:1: warning: `greet` has no signature — add a `--: (...) -> ...` annotation above the function definition
... (5 warnings total)
Checked 1 file(s): 0 error(s), 5 warning(s)
real 0m0.030s

# v5 (bin/cr check --v5)
lib/type/static-v5/fixtures/demo_effects.lua: [T-CIntersectionMember-Direct] ty is neither intersection nor equal to part (tag=const)
real 0m0.010s
```

### lib/stdlib/lint.lua (341 LOC, real production file)

| Checker | Run 1 | Run 2 | Run 3 | Median | Errors |
|---|---|---|---|---|---|
| `bin/cr check` (v4) | 42ms | 30ms | 27ms | 30ms | 13 |
| `bin/cr check --v5` | 16ms | 17ms | 27ms | 17ms | many |

v5 wall time ~1.8× faster on this file. Error counts NOT comparable: v4 reports 13 known
type errors; v5 reports many `[S-Quiesce] stuck constraint (tag=crow_extend)` diagnostics
reflecting that gen-pass coverage for this file's patterns (Gap P6: method dispatch, closed
records) is incomplete. v5 error output is diagnostic noise, not real type errors — same
caveat as the prior entry.

### Interpretation

Prior "3.5×" number (from the entry below) was measured when v5 was silently skipping
work. Post-5.F: v5 is ~3× faster on demo_effects.lua and ~1.8× faster on lint.lua.
The speed advantage is still real but narrower than before — 5.F added genuine
enforcement work (dotted-callee resolution, pcall special-casing, bounds accumulation).
Both files remain well under 50ms for either checker. A fair comparison on solver work
requires v5 gen-pass coverage parity with v4, which is future work (Gaps P5 + P6).

---

## 2026-05-26: v5 source pipeline — `bin/cr check --v5` wall-time comparison

**Commits:** ann.lua = `52fcae6f`, constrain.lua = `0ff434aa`, effect propagation = `6da6db59`,
cli = `317acc9b`. HEAD = `317acc9b` (used for both --v4 and --v5 baselines; same tree).

This entry measures end-to-end wall time for `bin/cr check --v5` vs `bin/cr check` (v4)
on two files. The v5 CLI is newly wired (Phase 5.D); this is its first perf measurement.

**Note on metrics:** The v5 CLI does not yet emit constraint count or step count to stdout.
Wall time only. Error counts are included where visible in output. A per-run constraint
count flag is owed as a future improvement.

### demo_effects.lua (lib/type/static-v5/fixtures/demo_effects.lua)

Small file (~50 LOC). Purpose: end-to-end demo for multi-effect propagation.

| Checker | Run 1 | Run 2 | Run 3 | Median | Errors | Warnings |
|---|---|---|---|---|---|---|
| `bin/cr check` (v4) | 38ms | 35ms | 35ms | 35ms | 0 | 5 |
| `bin/cr check --v5` | 10ms | 10ms | 9ms | 10ms | 0 | 0 |

v5 is **~3.5× faster** on this file. Caveat: the files are different programs to the
two checkers. v4 emits 5 warnings (unannotated functions); v5 emits 0 (no unannotated-
function warning in v5 yet). The comparison measures end-to-end dispatch overhead, not
solver work — both are well below any useful threshold on a 50-LOC file.

**Constraint count:** not measured (v5 CLI does not expose). Gap: add `--stats` flag.

### Raw output

```
# v4 (bin/cr check)
Checked 1 file(s): 0 error(s), 5 warning(s)
real 0m0.038s / 0m0.035s / 0m0.035s  →  median 35ms

# v5 (bin/cr check --v5)
[no output — exits 0]
real 0m0.010s / 0m0.010s / 0m0.009s  →  median 10ms
```

### lib/stdlib/lint.lua (real production file, ~300 LOC)

| Checker | Run 1 | Run 2 | Run 3 | Median | Errors |
|---|---|---|---|---|---|
| `bin/cr check` (v4) | 43ms | 36ms | 32ms | 36ms | 13 |
| `bin/cr check --v5` | 18ms | 18ms | 18ms | 18ms | many (expected) |

v5 wall time ~2× faster on this file. However, error counts are NOT comparable:
v4 reports 13 type errors on known issues in lint.lua; v5 reports many constraint
errors (CRowExtend mismatch, S-Quiesce stuck, CSub mismatch) reflecting that the
gen-pass is not yet complete for this file's patterns (Gap P6: method dispatch,
closed records not correctly modelled). v5 error output is diagnostic noise, not
real type errors.

**Constraint count:** not measured. Gap: same as above.

### Interpretation

v5 is consistently faster than v4 on wall time for both files (~2–3.5× faster).
This is expected: v5 processes less of the AST (gen-pass coverage is incomplete)
and the solver handles fewer constraints per file than the v4 solver does.
The numbers are NOT evidence of algorithmic improvement — they reflect reduced
coverage. A fair comparison requires v5 gen-pass coverage parity with v4,
which is future work (Gaps P5 + P6). These measurements establish a baseline
for tracking regression as coverage expands.

**No catastrophic slowdown** (>10× v5 vs v4) observed. Stop condition from task
spec not triggered; commit proceeds.

---

## 2026-05-26: v5 typechecker — CRow + CIntersection-effects re-gate

**Commits:** substrate = `05519c88`, CRow rules = `7f7d4d6c`, fixture 8 = `b1825484`,
intersection+effects = `c600a446`.

Re-gate after CRow (CRowExtend/Lacks/Close) and CIntersection (CIntersectionEq/Sub/Member
+ effect types as TConst("!") prefix) land. Effects dissolved into TIntersection with no
parallel infrastructure. Parity count: 187 → 275 (+88 assertions). Both interpreters pass.

Same harness as prior re-gates: `lib/type/experiments/v5_perf/bench_chkt.lua`. Invoked via
direct LuaJIT (the `bin/cr run` dispatch does not call `M.main`; file returns the module
table without invoking it — known harness quirk):

```
bin/ld-musl-x86_64.so.1 bin/luajit-bin -e \
  "package.path='./?/init.lua;./?.lua;'..package.path
   require('lib.type.experiments.v5_perf.bench_chkt').main({})"
```

### Gate verdict

| File | wall median | heap median | react/emit | Verdict |
|---|---|---|---|---|
| `lib/test/arb.lua` (498 total constraints, 44 CHKT) | 0.74 ms | 180.9 KB | 0.027 | **PASS** |
| `lib/stdlib/lint.lua` (228 total, 20 CHKT) | 0.53 ms | 113.1 KB | 0.044 | **PASS** |

All three gates pass (<500 ms / <2 MB / <5×) with >200× wall margin and >10× heap
margin on both files.

### Raw runs

```
v5 CHKT+HOUnify re-gate (5 runs/file, op_sem solver)

=== lib/test/arb.lua (CHKT+HOUnify re-gate) ===
base constraints: 454 ; synth CHKT receivers: 22
  run 1: wall=1.18ms heap=240.0KB step=634 react=17 err=44 chkt=44 total=498
  run 2: wall=0.75ms heap=180.9KB step=634 react=17 err=44 chkt=44 total=498
  run 3: wall=0.74ms heap=187.8KB step=634 react=17 err=44 chkt=44 total=498
  run 4: wall=0.53ms heap=161.5KB step=634 react=17 err=44 chkt=44 total=498
  run 5: wall=0.59ms heap=154.8KB step=634 react=17 err=44 chkt=44 total=498
MEDIAN: wall=0.74ms heap=180.9KB step=634 react=17 ratio=0.027
GATES: wall<500ms=true heap<2MB=true ratio<5x=true -- PASS

=== lib/stdlib/lint.lua (CHKT+HOUnify re-gate) ===
base constraints: 208 ; synth CHKT receivers: 10
  run 1: wall=0.44ms heap=103.0KB step=295 react=13 err=46 chkt=20 total=228
  run 2: wall=0.53ms heap=113.1KB step=295 react=13 err=46 chkt=20 total=228
  run 3: wall=0.54ms heap=113.8KB step=295 react=13 err=46 chkt=20 total=228
  run 4: wall=0.85ms heap=147.8KB step=295 react=13 err=46 chkt=20 total=228
  run 5: wall=0.40ms heap=100.9KB step=295 react=13 err=46 chkt=20 total=228
MEDIAN: wall=0.53ms heap=113.1KB step=295 react=13 ratio=0.044
GATES: wall<500ms=true heap<2MB=true ratio<5x=true -- PASS
```

### Interpretation

Step counts (634 / 295) match the prior CSub re-gate exactly. The bench harness
does not yet emit synthetic CRow or CIntersection constraints — it uses the same
CHKT + CSub synthetic load as the prior re-gate. The base-corpus constraint counts
(454 / 208) are unchanged. The gate therefore confirms that adding the CRow and
CIntersection dispatch paths to op_sem does NOT regress the existing load's
performance profile. A dedicated CRow+CIntersection synthetic load (analogous to
the CHKT synthetic load) is owed for the next re-gate cycle.

### Caveats

1. The synthetic load is identical to the prior CSub re-gate; no CRow or
   CIntersection constraints are exercised in the bench. Performance of the new
   rule paths is not yet measured under load.
2. Constraint counts remain ~500 max, vs the 10⁵ architecture target.
3. `err=44` / `err=46` counts are unchanged — T-HOUnify-Stuck errors from the
   synthetic CHKT-park half, not from CRow or CIntersection.

---

## 2026-05-24: v5 typechecker — variance-respecting CSub re-gate

**Commits:** variance sidecar = `0d58a06e`, docs op-sem = `d14b769e`, exec op-sem = `836985d1`, fixtures = `4ebc10ad`, bench extension = HEAD.

Re-gate after the variance-respecting CSub family lands.  CSub previously
routed to CEq (T-CSub-AsEq stub); now dispatches by shape into Refl /
TVar / Arrow / Const-Var / App-Var (declaration-site variance) / App-
Struct / Record-Width / Union-L / Union-R / Mismatch.

The bench harness `bench_chkt.lua` was extended to emit two extra CSub
constraints per receiver: an Arrow CSub (exercises T-CSub-Arrow + T-CSub-
Refl on the body) and a record-width CSub (T-CSub-Record-Width + T-CSub-
Refl).  These add a ~30% step count over the prior CHKT-only re-gate,
keeping the gate honest about CSub overhead.

### Gate verdict

| File | wall median | heap median | react/emit | Verdict |
|---|---|---|---|---|
| `lib/test/arb.lua` (498 total constraints, 44 CHKT) | 1.88 ms | 201.8 KB | 0.027 | **PASS** |
| `lib/stdlib/lint.lua` (228 total, 20 CHKT) | 0.63 ms | 104.1 KB | 0.044 | **PASS** |

All three gates pass (<500 ms / <2 MB / <5×) with ~250× wall margin and
~10× heap margin on both files.  Step count grew from 498→634 on arb.lua
and 228→295 on lint.lua, reflecting the additional CSub-driven CEq
subgoals (record-width emits per-common-field CEqs; arrow emits contra-
arg + co-ret subgoals).

### Raw runs

```
v5 CHKT+HOUnify re-gate (5 runs/file, op_sem solver)

=== lib/test/arb.lua (CHKT+HOUnify re-gate) ===
base constraints: 454 ; synth CHKT receivers: 22
  run 1: wall=1.88ms heap=276.8KB step=634 react=17 err=44 chkt=44 total=498
  run 2: wall=2.74ms heap=224.0KB step=634 react=17 err=44 chkt=44 total=498
  run 3: wall=3.20ms heap=201.8KB step=634 react=17 err=44 chkt=44 total=498
  run 4: wall=0.89ms heap=176.9KB step=634 react=17 err=44 chkt=44 total=498
  run 5: wall=0.61ms heap=157.8KB step=634 react=17 err=44 chkt=44 total=498
MEDIAN: wall=1.88ms heap=201.8KB step=634 react=17 ratio=0.027
GATES: wall<500ms=true heap<2MB=true ratio<5x=true -- PASS

=== lib/stdlib/lint.lua (CHKT+HOUnify re-gate) ===
base constraints: 208 ; synth CHKT receivers: 10
  run 1: wall=0.50ms heap=94.0KB step=295 err=46 ...  -- PASS
  ...
MEDIAN: wall=0.63ms heap=104.1KB step=295 react=13 ratio=0.044
GATES: wall<500ms=true heap<2MB=true ratio<5x=true -- PASS
```

### Caveats (same as CHKT re-gate, plus CSub-specific)

1. CSub load is synthetic: 2 CSubs per receiver, fixed Arrow + record-
   width shapes.  Real gen-pass CSub frequency and shape distribution
   are unknown until the gen pass actually emits CSub.
2. Union backtracking (T-CSub-Union-R) is not in the synthetic load —
   v5.0 admits exact-branch match only; the unbounded-cost path won't
   surface in a bench until backtracking is added.
3. The `err=44` and `err=46` counts include T-HOUnify-Stuck errors from
   the synthetic CHKT-park half; CSub adds zero new errors (the Arrow
   and record-width CSubs are reflexive, succeed cleanly).

---

## 2026-05-24: v5 typechecker — CHKT+HOUnify re-gate

**Commits:** substrate = `e9a06c3e`, docs op-sem = `b3259fd0`, exec op-sem = `0550959f`, parity fixtures = `0d8434e2`, bench = HEAD.

Re-gate after the second op-sem extension (CHKT + HOUnify) per the re-gate
schedule. New harness at `lib/type/experiments/v5_perf/bench_chkt.lua`:
extends the base bench by emitting a synthetic CHKT/HOUnify load on top of
the base-corpus constraint stream — for each k receivers (scaled to
constraints/20), one CHKT in Miller fragment (binds ?F_k) plus one CHKT
outside the fragment (parks as HOUnify); half of the outside-fragment
cases get a downstream rigidifying CEq that wakes the parked HOUnify.

Runs against op_sem.lua's full dispatch (CEq / CSub / CTOpen / CTSet /
CTSeal / CMethodCall / CInst / CHKT / HOUnify), not the legacy
solver.lua (which doesn't know CHKT/HOUnify).

### Gate verdict

| File | wall median | heap median | react/emit | Verdict |
|---|---|---|---|---|
| `lib/test/arb.lua` (498 total constraints, 44 CHKT) | 0.81 ms | 159.9 KB | 0.030 | **PASS** |
| `lib/stdlib/lint.lua` (228 total, 20 CHKT) | 0.36 ms | 89.7 KB | 0.049 | **PASS** |

All three gates (<500ms wall, <2MB heap, <5x ratio) PASS on both files.

### Raw runs

```
=== lib/test/arb.lua (CHKT+HOUnify re-gate) ===
base constraints: 454 ; synth CHKT receivers: 22
  run 1: wall=1.20ms heap=202.3KB step=568 react=17 err=44 chkt=44 total=498
  run 2: wall=0.81ms heap=159.9KB step=568 react=17 err=44 chkt=44 total=498
  run 3: wall=1.14ms heap=179.3KB step=568 react=17 err=44 chkt=44 total=498
  run 4: wall=0.61ms heap=144.4KB step=568 react=17 err=44 chkt=44 total=498
  run 5: wall=0.48ms heap=132.6KB step=568 react=17 err=44 chkt=44 total=498
MEDIAN: wall=0.81ms heap=159.9KB step=568 react=17 ratio=0.030

=== lib/stdlib/lint.lua (CHKT+HOUnify re-gate) ===
base constraints: 208 ; synth CHKT receivers: 10
  run 1: wall=0.44ms heap=98.7KB step=265 react=13 err=46 chkt=20 total=228
  run 2: wall=0.35ms heap=88.7KB step=265 react=13 err=46 chkt=20 total=228
  run 3: wall=0.36ms heap=89.7KB step=265 react=13 err=46 chkt=20 total=228
  run 4: wall=0.40ms heap=94.1KB step=265 react=13 err=46 chkt=20 total=228
  run 5: wall=0.34ms heap=89.3KB step=265 react=13 err=46 chkt=20 total=228
MEDIAN: wall=0.36ms heap=89.7KB step=265 react=13 ratio=0.049
```

### Interpretation

- Wall time grew from baseline (~0.18 ms median worst) to ~0.8 ms median
  worst — about 4×. Within budget (~600× margin to gate).
- Heap delta grew from ~21 KB baseline to ~160 KB worst — about 8×.
  Within budget (~12× margin to gate). Driven by synthetic CHKT/HOUnify
  reified constraints + abstract_body's allocation of fresh Lambda chains.
- Reactivation ratio essentially unchanged (0.03–0.05) — the head-watch
  parked-map fires only when a constructor variable rigidifies, not on
  every binding event.

### Caveats (same as the baseline re-gate, plus CHKT-specific)

1. Synthetic CHKT load is workload-driven, not corpus-derived. Real
   surface area depends on how often gen emits CHKT in practice — TBD
   when the gen pass actually targets CHKT.
2. Errors counted include the pre-existing inert constraints from base
   corpus (now reported under op_sem rather than solver.lua) plus the
   intentional T-HOUnify-Stuck "ambiguous constructor variable" errors
   from the half-rigidified synthetic load.
3. The op_sem path is roughly 2-4× slower than solver.lua on the same
   base corpus, likely from extra trace/error bookkeeping. Acceptable
   for the spec form; the production solver would inherit the substrate
   pattern but not the trace overhead.
4. Constraint counts (~500 max) are still 100-200× below the 10⁵
   architecture target. Re-gate at realistic scale owed.

### Spec gaps surfaced during the re-gate (per F12)

None new vs the op-sem rule writing (which already named: restricted
Miller fragment, no kind inference, no eta, no shift-aware abstract over
nested lambdas, no HOUnify residue provenance chaining).

---

## 2026-05-24: v5 typechecker substrate — falsifiability gate

**Commits:** scaffold = `6bbe20a4`, corpus+bench = `ebc41ada`, pooling = `fb4576e3` (HEAD).

Prototype of the v5 typechecker substrate + scheduler (per
`docs/typechecker-v5-log.md` 2026-05-23 "All 8 severe items closed"). Pure
Lua, no FFI, no JIT-specific tricks. Layout: `lib/type/experiments/v5_perf/`
(types.lua, subst.lua, constraint.lua, solver.lua, corpus_extract.lua,
bench.lua). ~860 LOC total.

The architecture's perf claims are three falsifiability gates (per perf
attacker round 2):

1. wall time < 500 ms per file
2. live heap at quiescence < 2 MB
3. reactivations / emissions < 5×

If all three hold on a realistic constraint set: architecture proceeds to
operational-semantics writing. If any gate fails: allocation strategy /
scheduler discipline work must come first.

### Methodology

`bin/cr run` over `lib/type/experiments/v5_perf/bench.lua`. Per file:
constraints synthesised by `corpus_extract.lua` (pattern-grep over Lua
source — `--:` and `--::` annotations → CEq; `local M = {}` →
CTableOpen; `X.field = ...` → CTableSet; `obj:method(...)` →
CMethodCall; `setmetatable(M, mt)` → CTableSeal; `local x = expr` and
function-defs and call sites → additional CEqs). Receivers are pooled
by name across the file so the solver actually does union-find +
wake-up work (without pooling reactivations were structurally 0). One
warm-up run, then 5 timed runs; median of 5 reported. Heap measured
via `collectgarbage("count")` bracketed by `collectgarbage("collect")`.
Two orderings exercised per file:

- **natural-order**: constraints in source order (gen-pass output shape).
- **stress-consumers-first**: all `CMethodCall` + `CTableSeal` emitted
  before any `CTableSet` for the same receivers — forces every consumer
  through the inert set, then through the wake-up path.

### Reference corpus

The task spec named `lib/std/init.lua` and `lib/test/init.lua`. Neither
exists in the current tree; substituted with closest matches:

- `lib/test/arb.lua` (739 LOC; annotation-heavy; substitute for test/init).
- `lib/stdlib/lint.lua` (341 LOC; module-table pattern; substitute for std/init).

### Raw runs (5/file, both orders)

```
=== lib/test/arb.lua (454 constraints, 949 tvars touched) ===
--- natural-order ---
  run 1: wall=0.43ms heap=35.8KB emit=454 react=14 inert=19
  run 2: wall=0.27ms heap=27.2KB emit=454 react=14 inert=19
  run 3: wall=0.15ms heap=17.5KB emit=454 react=14 inert=19
  run 4: wall=0.18ms heap=21.1KB emit=454 react=14 inert=19
  run 5: wall=0.17ms heap=19.8KB emit=454 react=14 inert=19
MEDIAN: wall=0.18ms heap=21.1KB react/emit=0.031
--- stress-consumers-first ---
  run 1: wall=0.14ms heap=18.9KB emit=454 react=18 inert=19
  run 2: wall=0.13ms heap=18.2KB emit=454 react=18 inert=19
  run 3: wall=0.19ms heap=21.9KB emit=454 react=18 inert=19
  run 4: wall=0.22ms heap=20.3KB emit=454 react=18 inert=19
  run 5: wall=0.18ms heap=16.6KB emit=454 react=18 inert=19
MEDIAN: wall=0.18ms heap=18.9KB react/emit=0.040

=== lib/stdlib/lint.lua (208 constraints, 371 tvars touched) ===
--- natural-order ---
  run 1: wall=0.07ms heap=11.0KB emit=208 react=5 inert=33
  run 2: wall=0.13ms heap=15.6KB emit=208 react=5 inert=33
  run 3: wall=0.09ms heap=13.6KB emit=208 react=5 inert=33
  run 4: wall=0.15ms heap=19.1KB emit=208 react=5 inert=33
  run 5: wall=0.07ms heap=12.2KB emit=208 react=5 inert=33
MEDIAN: wall=0.09ms heap=13.6KB react/emit=0.024
--- stress-consumers-first ---
  run 1: wall=0.05ms heap=10.5KB emit=208 react=14 inert=33
  run 2: wall=0.06ms heap=11.5KB emit=208 react=14 inert=33
  run 3: wall=0.18ms heap=19.9KB emit=208 react=14 inert=33
  run 4: wall=0.05ms heap=10.5KB emit=208 react=14 inert=33
  run 5: wall=0.04ms heap=10.5KB emit=208 react=14 inert=33
MEDIAN: wall=0.05ms heap=10.5KB react/emit=0.067
```

### Verdict per gate

| File / order | wall<500ms | heap<2MB | react/emit<5× | Verdict |
|---|---:|---:|---:|---|
| arb.lua natural | 0.18 ms | 21.1 KB | 0.031 | **PASS** |
| arb.lua stress  | 0.18 ms | 18.9 KB | 0.040 | **PASS** |
| lint.lua natural | 0.09 ms | 13.6 KB | 0.024 | **PASS** |
| lint.lua stress  | 0.05 ms | 10.5 KB | 0.067 | **PASS** |

All four scenarios pass all three gates by 3–4 orders of magnitude on
wall time, 2 orders on heap, and 2 orders on react/emit ratio.

### Honesty notes / caveats

- **Substrate is minimal.** The prototype implements `CEq`, `CSub` (as
  alias for `CEq`), `CTableOpen`, `CTableSet`, `CTableSeal`, `CMethodCall`.
  Full ADT (`CInst`, `CHKT`, `CEffect`, `CRow`, `CImpl`, `HOUnify`,
  `CMultiReturn`) is not implemented. Those constraints have different
  step costs; the prototype only validates the scheduler skeleton.
- **Constraint counts (208/454) are below the 500–2000/file the task
  cited.** This reflects the synthetic extractor's coverage, not a
  thinned-out solver; results would scale linearly to higher counts
  unless the scheduler has unexpected superlinearity (we see none).
- **Reference files differ from the spec.** `lib/std/init.lua` and
  `lib/test/init.lua` don't exist in the tree. Closest analogues
  substituted (see above). The qualitative result — passing every gate
  by orders of magnitude — should be robust to the swap.
- **FIFO worklist, not LIFO.** Initial implementation used LIFO; the
  smoke test caught it: `table_seal` fired before its `table_set`
  predecessors, breaking source-order causality and producing false
  "set on sealed unbound tv" errors. Switched to FIFO with head/tail
  indices. The architecture log called for "worklist + inert" without
  specifying ordering; this is a discipline point worth recording.
- **Inert remaining at quiescence is the stuck-error count.** 19 in
  arb.lua, 33 in lint.lua. Synthetic gen-pass over-generates (every
  `local x = expr` makes a `CEq ?l = ?r` between two fresh tvars,
  most of which never bind because the synthetic gen has no
  source-of-truth for the RHS). In a real gen pass these would
  bind to actual types and clear. Stuck-error count is therefore not
  comparable to a real run.

### Next step

Architecture's perf claims survive the falsifiability gate by wide
margins on the minimal substrate. **Operational-semantics writing is
unblocked** (per the architecture log's "Next entry point"). Risks
ahead: the full constraint ADT (esp. `CHKT` higher-kinded unification
and `CRow` row-variable scoping) may have different per-constraint
step costs and reactivation profiles; re-run the gate after each
constraint family is added rather than waiting for a full
implementation.

---

## 2026-05-15: typechecker — HM Phase 2 baseline + post-change comparison

**Commits:** pre-Phase-2 = `772fb7dd` (parent of `9260751e`); post-Phase-2 = `391bde98` (HEAD)

HM Phase 2 (`9260751e`, `92f866b2`, `391bde98`) added a
`record_polymorphic_ops_post` pass plus per-call-site re-emission of recorded
body ops (field-value-type propagation, then extension to `C_COMPARE`). The
architectural cost is up to `(call_sites × body_ops)` extra constraint
emissions per generic helper — at realistic scale (~50 call sites × ~10 body
ops ≈ ~500 extra constraints per helper) this should be tolerable for a
solver that already handles 10⁵+ constraints, but the design risk per
`docs/typechecker-hm-phase2.md` is quadratic blowup, so verify.

Bench: cold-cache `time timeout 120 bin/cr check <files>` (`.crescentcache`
removed before each run). Best of three runs reported.

### Results

| Workload | Pre-Phase-2 (772fb7dd) | HEAD (391bde98) | Δ |
|---|---|---|---|
| `lib/type/static/*.lua` (typechecker self-check, ~30 files) | 5.509s | 5.907s | **+7.2%** |
| `lib/iter/init.lua` (generics-heavy, 17 generic call sites) | 0.046s | 0.043s | -6.5% |
| `lib/hex_dump/init.lua` (non-generic control) | 0.060s | 0.058s | -3.3% |

Raw runs (all three, in order):

```
HEAD lib/type/static/*.lua:   6.090s 6.270s 5.907s
PRE  lib/type/static/*.lua:   5.509s 5.796s 8.068s
HEAD lib/iter/init.lua:       0.048s 0.047s 0.043s
PRE  lib/iter/init.lua:       0.050s 0.050s 0.046s
HEAD lib/hex_dump/init.lua:   0.063s 0.072s 0.058s
PRE  lib/hex_dump/init.lua:   0.060s 0.064s 0.068s
```

### Notes

- Single-file workloads (`iter`, `hex_dump`) check only the file itself —
  their dependency closure is satisfied from the disk cache *for files other
  than the target*, so they exercise the per-file solver but not a wide
  re-emission surface. Both are noise-level (within ±10%).
- The self-check workload is the meaningful signal: 30 files including
  `infer.lua`, `solver.lua`, etc., which are the heaviest typechecker
  modules and exercise `_forall_ops` recording extensively. +7.2% wallclock
  overhead is well within the 20% gate.
- Pre-Phase-2 run 3 (8.068s) is an outlier; using best-of-three to discount
  it. Even using mean (6.46s pre vs 6.09s post) the change is within noise.
- No quadratic blowup observed at current scale. The (call_sites × body_ops)
  budget is being spent, but the constants are small enough that the solver
  absorbs it.

### Verdict

Phase 2 ships within the perf budget. Re-measure after Phase 3
(`_inferred_params` removal) to confirm direction of travel.

---

## 2026-04-17: library index — FTS5 + app_tags at 20k apps

**Commits:** d25e174 (schema), 98316cd (wire-up), follow-up (query shape fix)

Benchmark: `luajit docs/perf/library_index.lua`

Validates the claim (library-app-design.md) that tag filter + substring
search stay sub-5ms at ~20k apps. 20,000 synthetic apps, in-memory SQLite,
all seeded inside one transaction.

### Results

```
Seeding 20000 apps... seeded in 0.67s (29720 installs/s)

list() first page (no filter)           52.98 ms/op   (200 rows, full materialize)
search('alice') FTS trigram              6.32 ms/op  (2666 rows materialized)
search('calc-dun') phrase                0.03 ms/op     (0 rows — no trigram)
list({tag='ai'}) tag join                4.78 ms/op  (2333 rows materialized)
list({tag='fantasy'}) tag join           2.37 ms/op  (1143 rows materialized)
server-style page (LIMIT 200, no filter) 0.05 ms/op    (200 rows)
server-style count (no filter)           0.00 ms/op
server-style FTS+tag page                1.43 ms/op    (200 rows)
```

### Notes

- **FTS MATCH must go in a subquery, not a JOIN.** First attempt joined
  `apps_fts` directly: 94ms for the FTS+tag query. SQLite picks a plan
  that re-evaluates MATCH per outer-loop row. Putting MATCH in
  `WHERE a.id IN (SELECT rowid FROM apps_fts WHERE apps_fts MATCH ?)`
  evaluates it once → 0.83ms. 100x difference.
  Fix applied to both `server.lua` (FROM_Q, FROM_Q_TAG) and
  `index.lua` search().
- The server-side paginated query shape (one `SELECT ... LIMIT 200` +
  one `SELECT COUNT(*)`) is the hot path; `idx:list()` materializes all
  rows and is not used by the library API.
- `search('alice')` returns 2666 rows because the synthetic name
  generator reuses a 10-word pool. A realistic card library produces
  fewer matches; 6ms is a loose upper bound.

### Verdict

Tag filter + FTS search meet the ST-disaster-avoidance bar at 20k apps
with plenty of headroom. No work to do before library-at-scale.

---

## 2026-03-26: base64 — three-tier rewrite (pure + ffi)

**Commit:** (see feat(base64) commit)

Benchmark: `luajit lib/encode/base64/bench.lua`

Rewrite adds `pure.lua` and `ffi.lua` tiers. Main fix: decode no longer calls
`b64:gsub("%s", "")` unconditionally — whitespace is now skipped inline during
the decode loop, eliminating an allocation on every decode call.

The ffi tier uses `ffi.cast("const uint8_t*", s)` for zero-copy byte access and
a 256-entry pre-built decode table (0xFF = invalid, 0xFE = skip whitespace).

### Results

```
base64 benchmark — encode and decode throughput
active tier: ffi

tier    size       encode MB/s     decode MB/s
------------------------------------------------
pure    64B            54.5 MB/s         36.0 MB/s
pure    1KB            98.4 MB/s         70.9 MB/s
pure    64KB           89.4 MB/s         48.7 MB/s
pure    1MB            87.7 MB/s         44.7 MB/s
ffi     64B            55.1 MB/s         39.1 MB/s
ffi     1KB           101.3 MB/s         73.6 MB/s
ffi     64KB          102.0 MB/s         52.5 MB/s
ffi     1MB            91.0 MB/s         44.8 MB/s

variant   size       encode MB/s     decode MB/s
--------------------------------------------------
std       64B            54.7 MB/s         38.1 MB/s
std       1KB           102.0 MB/s         73.3 MB/s
std       64KB           93.6 MB/s         48.9 MB/s
std       1MB            90.8 MB/s         44.6 MB/s
url       64B            54.8 MB/s         38.5 MB/s
url       1KB           102.1 MB/s         73.3 MB/s
url       64KB          110.7 MB/s         58.2 MB/s
url       1MB            91.0 MB/s         44.1 MB/s
```

### Verdict

ffi tier is ~2–14% faster than pure on encode; ~8–16% faster on decode for
larger inputs where pointer arithmetic and the 256-entry decode table pay off.
Both tiers are at parity: 290 test assertions pass including 250 parity checks
across 50 random inputs. The decode gsub bottleneck is eliminated in both tiers.

---

## 2026-03-26: utf8 — baseline

**Commit:** 07ae970

Benchmark: `luajit lib/encode/utf8/bench.lua`

### Results

```
utf8 benchmark
warmup: 3  reps: 10

operation         input             size       ms/op          MB/s
------------------------------------------------------------------
is_valid          ascii              1KB       0.003         305.2 MB/s
is_valid          ascii             64KB       0.055        1144.7 MB/s
is_valid          ascii              1MB       0.478        2091.2 MB/s
is_valid          mixed              1KB       0.003         361.7 MB/s
is_valid          mixed             64KB       0.166         377.4 MB/s
is_valid          mixed              1MB       2.658         376.2 MB/s
is_valid          cjk                1KB       0.006         168.2 MB/s
is_valid          cjk               64KB       0.363         172.4 MB/s
is_valid          cjk                1MB       5.843         171.2 MB/s

len               ascii              1KB       0.004         244.1 MB/s
len               ascii             64KB       0.052        1197.3 MB/s
len               ascii              1MB       0.851        1174.8 MB/s
len               mixed              1KB       0.002         488.3 MB/s
len               mixed             64KB       0.128         487.9 MB/s
len               mixed              1MB       1.987         503.3 MB/s
len               cjk                1KB       0.004         243.9 MB/s
len               cjk               64KB       0.125         499.2 MB/s
len               cjk                1MB       1.978         505.6 MB/s

codes (iter)      ascii              1KB       0.009         112.2 MB/s
codes (iter)      ascii             64KB       0.347         180.3 MB/s
codes (iter)      ascii              1MB       5.515         181.3 MB/s
codes (iter)      mixed              1KB       0.005         195.3 MB/s
codes (iter)      mixed             64KB       0.320         195.5 MB/s
codes (iter)      mixed              1MB       5.142         194.5 MB/s
codes (iter)      cjk                1KB       0.003         295.6 MB/s
codes (iter)      cjk               64KB       0.193         324.0 MB/s
codes (iter)      cjk                1MB       3.281         304.8 MB/s

codepoint         ascii              1KB       0.010          96.7 MB/s
codepoint         ascii             64KB       0.480         130.3 MB/s
codepoint         ascii              1MB       6.958         143.7 MB/s
codepoint         mixed              1KB       0.038          25.4 MB/s
codepoint         mixed             64KB       1.563          40.0 MB/s
codepoint         mixed              1MB      24.718          40.5 MB/s
codepoint         cjk                1KB       0.029          33.1 MB/s
codepoint         cjk               64KB       1.345          46.5 MB/s
codepoint         cjk                1MB      21.142          47.3 MB/s
```

### Notes

**`is_valid` is the fastest path** — pure byte-scan with early return, no output
allocation. ASCII gets a JIT-friendly tight loop and reaches ~2 GB/s at 1MB. Mixed
and CJK hover around 170–390 MB/s; CJK is slower because every byte triggers
continuation-byte accounting (remain counter).

**`len` and `codes` run at similar throughput (~180–530 MB/s)** — both walk every
character. `len` has a tight ASCII inner loop that gives it an edge on ASCII-heavy
inputs (1.2 GB/s at 64KB). `codes` pays extra per iteration because the iterator
protocol returns two values and the loop body executes in the caller's frame.

**`codepoint` (256-byte chunks) is 3–5× slower than `codes` on multibyte inputs.**
The bottleneck is the intermediate `cs` table: every call to `codepoint` allocates
a fresh table, appends codepoints, and calls `unpack`. The chunk-boundary overhead
(256 extra `math.min` + loop overhead per 256 bytes) is visible but secondary.
On ASCII the gap narrows because the ASCII inner loop avoids the table writes.

**JIT traces compile well for `is_valid` and `len`** — the inner ASCII loop is a
tight counted loop with no function calls. `codes` and `codepoint` involve more
branching per character but still trace. The 1KB → 64KB jump on `is_valid` (ASCII:
300 → 1145 MB/s) shows the JIT warming up across the warmup iterations.

---

## 2026-03-26: iter combinators — overhead baseline

**Commit:** ff9659d

Benchmark: `luajit lib/iter/bench.lua`

### Results

```
iter combinator benchmark — 1M elements, 10 reps (after 3 warmup)

case                      total (ms)    ns/element
----------------------------------------------------
map (loop)                      0.85           0.8
map (iter)                      1.17           1.2
filter (loop)                   2.93           2.9
filter (iter)                   1.25           1.2
fold (loop)                     0.70           0.7
fold (iter)                     1.04           1.0
map+filter (loop)               6.79           6.8
map+filter (iter)              12.38          12.4
map+filt+fold (loop)            6.78           6.8
map+filt+fold (iter)           10.72          10.7

overhead (iter/loop)      ratio
--------------------------------------
map (iter)                1.38x
filter (iter)             0.43x
fold (iter)               1.49x
map+filter (iter)         1.82x
map+filt+fold (iter)      1.58x
```

### Notes

- Closures are hoisted to module-level variables in the bench so the same closure
  object is reused across all cases. This is required for correct measurement: LuaJIT
  compiles the fold/filter/map inner loops as traces guarded on a specific closure
  identity. If two syntactically identical but object-distinct closures run the same
  loop, the second misses the guard every iteration and falls back to interpreter
  (~8–10x slower). The original bench (agent-written) had this bug — fold appeared
  7.33x slower than it actually is.

- Real overhead: **1.4–1.8x** for all cases including chained pipelines. Single
  combinators (map, fold) are ~1.4x; chains are ~1.6–1.8x. All JIT-compile cleanly
  with shared closures.

- `filter (iter)` at 0.43x (faster than hand loop) is a JIT artefact: the iterator
  state machine creates a more JIT-friendly branch pattern than an explicit `if`.

- Takeaway: iter combinators are JIT-friendly and cheap (~1.5x overhead) as long as
  the same closure object is reused across calls. Defining a fresh closure per call
  site (e.g. inline lambdas in a tight benchmark loop) defeats JIT specialisation and
  produces worst-case 8–11x overhead. Practical use (module-level or upvalue closures
  called in a loop) is fine.

---

## 2026-03-26: base64 encode/decode — baseline

**Commit:** (this change)

Benchmark: `luajit lib/encode/base64/bench.lua`

### Results

```
base64 benchmark — encode and decode throughput

variant   size       encode MB/s     decode MB/s
--------------------------------------------------
std       64B            55.2 MB/s         36.1 MB/s
std       1KB            91.7 MB/s         54.9 MB/s
std       64KB           85.8 MB/s         54.9 MB/s
std       1MB            86.5 MB/s         50.7 MB/s
url       64B            55.3 MB/s         39.6 MB/s
url       1KB            96.4 MB/s         58.6 MB/s
url       64KB           87.1 MB/s         55.1 MB/s
url       1MB            86.2 MB/s         51.3 MB/s
```

### Notes

- Encode plateaus at ~86–96 MB/s above 1KB; JIT traces stabilise once the main
  loop is hot. The 64B case is ~40% slower due to per-call overhead dominating.
- Decode is consistently ~35–40% slower than encode. The bottleneck is the
  `gsub("%s", "")` whitespace-strip at the top of every decode call — it
  allocates a new string even when there is no whitespace to remove. The
  `string.char` calls inside the decode loop are also larger (4 → 3 bytes) and
  involve more nil-checks per character.
- `base64url` is a thin wrapper (one extra table lookup for opts) and performs
  identically to `std` within measurement noise.
- Decode hot path: `b64:byte(i, i+3)` + 4 table lookups + `string.char` of
  3 bytes. The `not da or not db` guard prevents LICM across the loop body,
  limiting JIT trace quality.

---

## 2026-03-26: JSON API variants — schema+reuse beats Node.js

**Benchmark scripts:** `docs/perf/json_api.lua` (single decode), `docs/perf/json_collect.lua` (1000-item loop), `docs/perf/json_node.js` (Node.js comparison).

### Single-decode, 90B 5-field object

| API | ns | MB/s |
|---|---|---|
| `pure.decode` (baseline) | 869 | 72 |
| SAX + callbacks (no table) | 247 | 254 |
| SAX zerocopy (positions only) | 155 | 405 |
| schema + fresh table | 524 | 120 |
| schema + table reuse | 270 | 233 |
| **Node.js `JSON.parse` warm** | **323** | **198** |
| Node.js `JSON.parse` cold | 3752 | 17 |

### 1000-object collect loop → array of tables

| API | µs/batch | MB/s |
|---|---|---|
| `pure.decode` (baseline) | 814.8 | 81 |
| schema + fresh table | 503.1 | 131 |
| SAX → columnar arrays | 355.0 | 186 |
| schema + reuse + copy | **321.7** | **205** |
| **Node.js `JSON.parse`** | **334.9** | **197** |
| SAX → array of tables | 860.4 | 76 |

Schema+reuse+copy wins the collect loop at **205 MB/s vs Node's 197 MB/s**.

### Key findings

**SAX → array of tables is slower than baseline.** Callback overhead (5 calls/object
× 1000 objects = 5000 extra function calls) erases the scanning gain. SAX is only
faster when output is columnar (no per-item table) or most fields are skipped.

**Schema+reuse+copy is the right default for collect loops.** The "wasted" copy step
(`res[i] = {name=_rt.name, ...}`) is cheap: 5 literal-key writes to a fresh table
that JIT treats as a table constructor. The reuse table's hash slots are pre-allocated
after the first decode, so subsequent writes are updates, not insertions.

**Node.js shape cache explained.** Node warm (323 ns) vs cold (3752 ns) = 10.5x
internal speedup from V8 hidden classes. In a collect loop, Node is always warm
(same shape repeated). LuaJIT has no hidden class equivalent, but schema+reuse
achieves the same effect manually: pre-allocated hash slots + known constant keys.

**The schema API belongs in `lib/format/json/`.** It is a faster path for
`decode → table`, not a different interface. A separate `lib/format/json_sax/`
is justified only for columnar/partial-field use cases.

---

## 2026-03-26: JSON pure decoder — de-recursify, eliminate NYI trace aborts

**Commit:** (this change)

### Problem

The previous decoder was mutually recursive: `decode_value` → `decode_array`/
`decode_object` → `decode_value`. LuaJIT cannot trace across recursive call
boundaries and emits `NYI: return to lower frame` trace aborts for almost every
container parse. This forced near-total interpreter fallback on array and object
decoding.

`luajit -jv` on the old decoder showed repeated:
```
[TRACE --- pure.lua:NNN -- NYI: return to lower frame at pure.lua:543]
```

### Fix

Replaced the recursive call graph with a single iterative `decode_raw` function
using an explicit context stack (512 pre-allocated frames) and `goto`-based
state transitions (`PARSE_VALUE` / `ASSIGN_VALUE`). The entire parse path is one
function with one loop — JIT traces it end-to-end.

Also inlined `decode_number` into `decode_raw` to eliminate its cross-frame
return. `decode_string` remains a separate function; it has no recursive calls
and JIT handles leaf-function returns fine.

After the fix, `luajit -jv` on `_decode_raw` (bypassing the `pcall` wrapper)
shows 0 NYI aborts. The 4 remaining NYIs when calling through `M.decode` are
from the `pcall` boundary itself, which is unavoidable.

### Benchmark (before / after)

Benchmark script: inline `bench()` calls, 200-iter warmup, 2000 iterations.

| scenario | before | after | speedup |
|---|---|---|---|
| decode array 1000 nums (17 KB) | 114 MB/s | 106 MB/s | 0.93x |
| decode object 100 fields (2.7 KB) | 61 MB/s | 217 MB/s | 3.6x |
| decode nested depth 50 (1 KB) | 31 MB/s | 58 MB/s | 1.9x |

The array case measures similarly because its hot path is `tonumber()` on float
strings (unavoidable), and it was already partially JIT-compiled via the
integer-scanning inner loop. Objects and nested structures benefit most — these
are the NYI-dominated cases.

### NYI verification

```
luajit -jv -e "... for i=1,200 do pure._decode_raw(j) end" 2>&1 | grep -c "NYI"
# output: 0
```

---

## 2026-03-26: JSON FFI tier — fix IS_WS loop and ffi.string() overhead

**Commit:** (this change)

### Problem

The previous FFI tier had two performance issues:

1. **IS_WS byte loop**: `skip_ws()` used a `while _pos < _len and IS_WS[ptr[_pos]] == 1`
   loop. The JIT compiled this as a root trace, blocking `decode_string`'s byte
   scan from compiling — "inner loop in root trace" was the reported abort.

2. **`ffi.string()` overhead**: String segment extraction used `ffi.string(ptr+start, len)`.
   This is slower than `str_sub(s, start, end)` for the short strings (2-20 bytes)
   typical in JSON object keys and string values.

### Fix

1. Replaced `skip_ws` byte loop with `string.find("[^ \t\n\r]", _pos + 1)` — a single
   C call, no loop to compete with `decode_string` for JIT root-trace budget.

2. Replaced all `ffi.string(ptr + start, len)` calls in `decode_string` with
   `str_sub(_src, start + 1, _pos)` (0→1-indexed conversion: 1-indexed end of
   content = 0-indexed position of closing `"`).

3. Verified: de-recursification was also tried (goto-based iterative form matching
   pure.lua). It was SLOWER for FFI because the recursive form uses upvalue-based
   state and LuaJIT traces through the calls without `NYI: return to lower frame`.
   Frame-table access overhead exceeded the recursion cost.

### Benchmark (before / after)

`before`: old FFI with IS_WS loop + ffi.string()
`after`: new FFI with string.find + str_sub

| scenario | pure | ffi before | ffi after |
|---|---|---|---|
| decode small obj (103B) | 122 MB/s | 99 MB/s | 106 MB/s |
| decode medium obj (583B) | 148 MB/s | 127 MB/s | 130 MB/s |
| decode large obj (1185B) | 156 MB/s | 130 MB/s | 134 MB/s |
| decode nested depth 25 (153B) | 63 MB/s | 59 MB/s | 60 MB/s |
| decode nested depth 50 (1KB) | 37 MB/s | n/a | 42 MB/s |
| decode small obj (109B) | 69 MB/s | n/a | 83 MB/s |

FFI tier is now faster than pure on small objects (+20%) and deep nesting (+12%).
Pure is faster on large flat objects (+12-14%) where decode_string loop overhead
dominates over pointer dispatch benefits.

### JIT trace structure

After fix:
```
[TRACE 1  ffi.lua:NN loop]   -- module init loop (ESC_TABLE)
[TRACE 2  ffi.lua:NN loop]   -- decode_string while loop (root)
[TRACE 3  ffi.lua:NN return] -- decode_string return
[TRACE 4+ side traces from decode_string]
[no NYI aborts from decoder itself]
```

### Key findings

**`ffi.string()` vs `str_sub`**: For JSON-typical strings (2-20 bytes), `ffi.string()`
involves a C call with pointer arithmetic and length parameter. `str_sub` on the
original Lua string is cheaper because LuaJIT's string indexing has already been
optimized for this access pattern.

**Upvalue-based recursion vs goto-based iteration**: FFI's recursive decoder stores
all parse state in upvalues (`_ptr8`, `_pos`, `_len`, `_null`). LuaJIT can trace
through these recursive calls because there is no cross-frame return of values —
the state lives in the outer scope. Pure.lua needed de-recursification because its
recursive form returned values through the call stack (`return decode_string()`),
triggering `NYI: return to lower frame` on every container parse. FFI avoids this
because the "return" is implicit (state mutation) rather than explicit (return value).

This is the key architectural difference: upvalue-based mutable state enables
recursive FFI decoders to JIT cleanly without de-recursification.

---

## 2026-03-26: JSON decode — why C is ~10x faster (diagnosis)

**Commit:** (analysis only, no code change)

### The question

After optimising both decoders, throughput is ~120–170 MB/s. simdjson reports
~2–3 GB/s. Why the ~10–20x gap?

### Measurements

Benchmark script: `/tmp/jit_cost2.lua`. Input: 90-byte 5-field JSON object
(`{"name":"Alice","age":30,"city":"NY","zip":10001,"active":true}`).

| operation | cost |
|---|---|
| 5 hash table inserts (pre-interned string keys, int values) | 235.9 ns |
| 5 hash table inserts (pre-interned key+val strings) | 230.8 ns |
| str_byte loop scan (4-char string, 4 iterations) | 13.7 ns → 3.4 ns/byte |
| string.find skip_ws pattern call | 48.0 ns |
| full decode, 90B, pure tier | 633.3 ns |
| full decode, 90B, ffi tier | 749.6 ns |
| str_byte scan all 63 non-bracket chars | 373.1 ns |

Derived:
- Per-insert cost: 47 ns
- Per-byte scan cost: 3.4 ns → ~294 MB/s raw throughput
- Hash table cost as share of total (pure): 235 / 633 = **37%**
- Scan cost as share of total (pure): 373 / 633 = **59%** (upper bound; includes brackets, commas, etc.)

### Why C is faster: three distinct reasons

#### 1. SIMD byte scanning (the visible gap)

Lua scans one byte per loop iteration. LuaJIT compiles this to a small native
loop, but it is still scalar. At 3.4 ns/byte on a 4 GHz machine, that is ~13.6
cycles per byte — including the `str_byte` call overhead amortised over the
loop.

simdjson uses AVX2 to process 32 bytes per cycle in its structural stage:
classify whitespace, quotes, backslashes, and braces in a single SIMD pass.
Raw throughput is ~1–2 ns/byte → 500 MB/s–1 GB/s just for scanning, before
doing anything with the result.

Lua cannot express SIMD. `string.find` dispatches to C but the pattern engine
is not SIMD-accelerated. The only way to get SIMD scanning from Lua is to call
a C function that does it internally.

**Gap from scanning alone: ~3x.**

#### 2. Hash table construction (the non-obvious gap)

Every JSON key-value pair that lands in a Lua table costs ~47 ns for the hash
insert alone (measured above with pre-interned strings — no allocation, just
writes). For a 5-field object that is 235 ns of irreducible hash overhead.

The full decode of 90 bytes is 633 ns. Even if scanning were instantaneous,
the minimum decode time is ≥235 ns just to populate the result table. The
theoretical maximum throughput for a 5-field object, assuming zero-cost
scanning, is 90 / 235e-9 ≈ **383 MB/s**. We currently achieve 142 MB/s — so
roughly 40% of the gap from table construction is already visible, and it
cannot be optimised away in Lua.

simdjson does not build a hash table. It constructs a flat "tape" of 64-bit
tokens (type + offset pairs) using a pre-allocated arena. Token recording costs
roughly one 64-bit store per structural character — no hashing, no collision
chains, no GC. After parsing, field lookup is O(n) tape scan, not O(1) hash —
but the tape is cache-hot and the allocator is bump-pointer.

**Gap from table construction: ~2x of the remaining gap after scanning.**

#### 3. String allocation and interning (the per-key cost)

Every JSON string value that reaches a Lua table must be an allocated, interned
Lua string. Lua strings are immutable, heap-allocated, and hash-compared. When
the decoder extracts a key like `"name"`, it calls `str_sub(src, i, j)`, which:
1. Copies 4 bytes into a new Lua string object (~16-byte header + content)
2. Computes a hash over those 4 bytes
3. Checks the string interning table for deduplication
4. Returns the interned pointer (or inserts the new string)

For 5 keys + 3 string values = 8 string allocations per object. Even if each
costs only 20 ns (optimistic for a new interned string), that is 160 ns.

simdjson returns `string_view` — a (pointer, length) pair into the input buffer.
No copy, no hash, no allocation. The input buffer stays alive for the lifetime
of the document. Callers who want a `std::string` pay for the copy; those who
just need to compare or transmit the string pay nothing.

**Gap from string allocation: ~1.5x of remaining gap.**

### Compound effect

The three factors multiply. For a 5-field 90-byte object:

| | Lua (current) | simdjson (estimate) |
|---|---|---|
| Byte scanning | ~300 ns (scalar) | ~30 ns (AVX2) |
| Table/tape construction | ~235 ns (hash) | ~15 ns (bump-alloc tape) |
| String extraction | ~100 ns (alloc+intern) | ~0 ns (string_view) |
| **Total** | **~635 ns** | **~45 ns** |
| **Throughput** | **~142 MB/s** | **~2 GB/s** |

The multipliers compound: 10x scanning × 15x table × ∞x strings ≈ overall
10–20x gap depending on input characteristics.

### Correction: the Node.js comparison

The simdjson comparison is apples-to-oranges (C struct vs Lua table). The fair
comparison is Node.js `JSON.parse`, which also returns a language-native object.

Measured on the same 90B input (Node.js 24, LuaJIT 2.1):

| scenario | Lua pure | Node.js V8 |
|---|---|---|
| same structure repeated (warm shape cache) | 1052 ns → 86 MB/s | 355 ns → 253 MB/s |
| different structure each call (cold) | 1981 ns → 46 MB/s | 3752 ns → 24 MB/s |

**V8 is 3x faster on warm shapes. Lua is 1.9x faster on cold shapes.**

V8's advantage comes entirely from **hidden classes** (also called "shapes" or
"maps"). After parsing `{"name":…,"age":…,"city":…}` once, V8 records the
property sequence as a transition chain. Subsequent parses with the same
property order assign values by fixed slot offset — equivalent to
`obj->slot[0]=v0; obj->slot[1]=v1` in C, not hash table inserts. That is the
10.5x internal speedup (355 ns warm vs 3752 ns cold).

Lua has no equivalent. Every `t[key] = val` is always a hash insert regardless
of parse history. LuaJIT traces the loop body but cannot specialise the hash
table layout across calls the way V8's hidden class system does.

The practical upshot: benchmarks that warm V8's shape cache (same JSON
structure in a tight loop) make Node.js look much faster than it is for
production workloads with varied JSON shapes. For one-shot or heterogeneous
JSON decoding, Lua is faster.

### What a `simd.lua` tier can and cannot do

A `simd.lua` tier that calls simdjson and then builds a Lua table would
eliminate the scanning gap (~3x) and the string_view extraction (~1.5x) but
keep the hash table construction cost (~2x). Net improvement: roughly 2.5x
faster than the current pure/FFI tier, reaching ~350–400 MB/s.

To approach simdjson-level throughput from Lua, the tier would need to return a
lazy userdata (opaque C DOM) rather than a Lua table. Field access would use C
comparisons against the tape without ever allocating Lua strings. This breaks
the `decode → Lua table` contract.

**Verdict:** the current pure+FFI tier is close to the optimum for implementations
that return Lua tables. The remaining gap is an architectural constraint of the
Lua VM (hash tables + string interning), not an implementation flaw. A simd.lua
tier is worth implementing only if it returns a lazy DOM userdata, not a Lua
table. The Node.js gap is 3x for same-structure workloads and does not exist for
varied-structure workloads.

---

## 2026-03-26: JSON tier optimisation — pre-optimisation baseline

**Commit:** (baseline before optimisation, same as `122d8ca` code)

Measured before any optimisation work. Pure and FFI tiers run at nearly
identical throughput — FFI is 0–10% slower than pure on most workloads because
the `ffi.string` call overhead on safe-run extraction cancels the pointer
advantage. The decoder's string scanning is byte-by-byte in both tiers.

### Baseline raw output

```
=== JSON benchmark (ffi tier selected) ===
selected tier: ffi

encode:
  small object (10 fields), 10000 iters       pure:     2.6 µs  ffi:     2.6 µs  speedup: 1.00x
  large array (1000 numbers), 1000 iters      pure:    84.7 µs  ffi:    85.8 µs  speedup: 0.99x
  deeply nested (depth 50), 1000 iters        pure:    20.1 µs  ffi:    21.1 µs  speedup: 0.95x
  large string (10 KB with escapes), 1000 iters  pure:    42.8 µs  ffi:    43.2 µs  speedup: 0.99x

decode:
  small object (10 fields), 10000 iters       pure:     0.8 µs  ffi:     1.0 µs  speedup: 0.89x
  large array (1000 numbers), 1000 iters      pure:   202.3 µs  ffi:   211.6 µs  speedup: 0.96x
  deeply nested (depth 50), 1000 iters        pure:     5.3 µs  ffi:     6.3 µs  speedup: 0.85x
  large string (10 KB with escapes), 1000 iters  pure:    57.9 µs  ffi:    63.9 µs  speedup: 0.90x

input sizes: small_obj=109 bytes  large_arr=17498 bytes  deep=1053 bytes  large_str=7011 bytes
```

---

## 2026-03-26: three-tier JSON library (lib/format/json)

**Commit:** `122d8ca`

Replaces vendored lunajson with a crescent-native three-tier JSON library:
pure Lua (Tier 1), LuaJIT FFI scalar (Tier 2), simdjson stub (Tier 3, not
yet implemented — falls through to Tier 2). Tier selected at module load time.

Benchmark: `luajit docs/perf/json.lua`
Baseline (lunajson): `luajit docs/perf/json_baseline.lua`

### encode throughput

| scenario | lunajson (µs) | pure (µs) | ffi (µs) | vs lunajson |
|----------|--------------|-----------|----------|-------------|
| small object (10 fields) | 2.8 | 2.5 | 2.3 | ~1.1–1.2x faster |
| large array (1000 numbers) | 94.4 | 86.0 | 87.0 | ~1.1x faster |
| deeply nested (depth 50) | 21.3 | 19.8 | 20.5 | ~1.05x faster |
| large string (10 KB, escapes) | 73.3 | 43.7 | 46.0 | **~1.7x faster** |

### decode throughput

| scenario | lunajson (µs) | pure (µs) | ffi (µs) | vs lunajson |
|----------|--------------|-----------|----------|-------------|
| small object (10 fields) | 1.0 | 0.9 | 1.0 | comparable |
| large array (1000 numbers) | 228.2 | 207.6 | 215.8 | ~1.1x faster |
| deeply nested (depth 50) | 9.2 | 5.5 | 6.5 | **~1.4–1.7x faster** |
| large string (10 KB, escapes) | 160.3 | 67.7 | 69.7 | **~2.3x faster** |

### Observations

Both tiers run at comparable speed — LuaJIT JIT-compiles both paths. The FFI
tier's byte-pointer advantage is partially offset by `ffi.string` call overhead
on safe-run extraction. On most workloads the two tiers are within 5–10% of
each other; neither is consistently faster.

The largest improvement over lunajson is on string-heavy workloads (2.3x faster
decode, 1.7x faster encode on 10 KB string with escapes). The new encoder uses a
pre-built 256-entry escape table and emits safe byte runs directly rather than
per-byte gsub substitution; the new decoder avoids the gsub + surrogate-pair
state machine overhead of lunajson.

The simdjson tier (Tier 3) is a stub pending C shim build infrastructure. When
available it should achieve 2–5x over the FFI tier on large payloads.

### Input sizes

```
small_obj = 109 bytes   large_arr = 17498 bytes
deep      = 1053 bytes  large_str = 7011 bytes
```

### Raw benchmark output (new tiers)

```
=== JSON benchmark (ffi tier selected) ===
selected tier: ffi

encode:
  small object (10 fields), 10000 iters       pure:     2.5 µs  ffi:     2.3 µs  speedup: 1.09x
  large array (1000 numbers), 1000 iters      pure:    86.0 µs  ffi:    87.0 µs  speedup: 0.99x
  deeply nested (depth 50), 1000 iters        pure:    19.8 µs  ffi:    20.5 µs  speedup: 0.97x
  large string (10 KB with escapes), 1000 iters  pure:    43.7 µs  ffi:    46.0 µs  speedup: 0.95x

decode:
  small object (10 fields), 10000 iters       pure:     0.9 µs  ffi:     1.0 µs  speedup: 0.85x
  large array (1000 numbers), 1000 iters      pure:   207.6 µs  ffi:   215.8 µs  speedup: 0.96x
  deeply nested (depth 50), 1000 iters        pure:     5.5 µs  ffi:     6.5 µs  speedup: 0.84x
  large string (10 KB with escapes), 1000 iters  pure:    67.7 µs  ffi:    69.7 µs  speedup: 0.97x
```

### Raw benchmark output (lunajson baseline, measured before replacement)

```
=== lunajson baseline ===
encode:
  small object (10 fields)                      2.8 µs/iter
  large array (1000 numbers)                   94.4 µs/iter
  deeply nested (depth 50)                     21.3 µs/iter
  large string (escapes)                       73.3 µs/iter
decode:
  small object (10 fields)                      1.0 µs/iter
  large array (1000 numbers)                  228.2 µs/iter
  deeply nested (depth 50)                      9.2 µs/iter
  large string (escapes)                      160.3 µs/iter
```

---

## 2026-03-26: pure Lua Myers diff and three-way merge (lib/merge3)

**Commit:** `ada0caf`

Replaces `diff3` shell invocation in `lib/pkg/install.lua` with a pure Lua
implementation. No external dependency — works on Alpine, Windows, macOS,
anywhere LuaJIT runs.

Benchmark: `luajit docs/perf/merge.lua 200`

### diff throughput by file size (5% of lines changed)

| scenario | lines | µs/call | Klines/s | KB/s |
|----------|-------|---------|----------|------|
| diff 100 lines  | 100  | 12.7  | 7,892  | 53,331 |
| diff 500 lines  | 500  | 105.9 | 4,720  | 35,881 |
| diff 1000 lines | 1000 | 348.2 | 2,872  | 22,136 |
| diff 5000 lines | 5000 | 6,637 | 753    | 6,459  |

Targets: < 5 ms for 1000-line file. **0.35 ms — 14x under target.**

### merge3 throughput by conflict density

| scenario | lines | µs/call | Klines/s | conflicts |
|----------|-------|---------|----------|-----------|
| 0% conflict, 5% ours-only edit | 1000 | ~0     | fast-path¹ | 0  |
| 5% conflict                    | 1000 | 738    | 1,355    | 50        |
| 20% conflict                   | 1000 | 7,521  | 133      | 200       |
| 500 lines, 10% conflict        | 500  | 638    | 783      | 50        |
| 5000 lines, 2% conflict        | 5000 | 8,701  | 575      | 97        |

¹ Fast path: when theirs == base, returns ours immediately (string equality).

Targets: < 10 ms for 1000-line file with 10 conflict regions. **0.74 ms at 5%
conflict density (50 conflicts) — 13x under target.**

### Raw benchmark output

```
=== diff throughput by file size ===
scenario                                   lines   µs/call    Klines/s        KB/s
----------------------------------------------------------------------------------
diff (100 lines, 5% changed)                 100       12.7      7891.7     53330.8
diff (500 lines, 5% changed)                 500      105.9      4720.2     35881.0
diff (1000 lines, 5% changed)               1000      348.2      2871.8     22136.1
diff (5000 lines, 5% changed)               5000     6636.8       753.4      6458.5

=== merge3 throughput by conflict density ===
scenario                                           lines   µs/call    Klines/s        KB/s  conflicts
--------------------------------------------------------------------------------------------------
merge3 0% conflict, 5% ours-only edit               1000        0.0  33333333.3  256933593.8         0
merge3 5% conflict                                  1000      738.0      1355.1     10445.0        50
merge3 20% conflict                                 1000     7521.3       133.0      1024.8       200
merge3 500 lines, 10% conflict, 5% mod               500      638.4       783.2      5953.6        50
merge3 5000 lines, 2% conflict                      5000     8701.2       574.6      4926.2        97

=== correctness spot-check ===
  ok: diff(10 lines) reconstructs correctly
  ok: diff(100 lines) reconstructs correctly
  ok: diff(500 lines) reconstructs correctly
  ok: all round-trip invariants hold
```

### Comparison to diff3 shell call

The previous `diff3 -m` invocation required:
- diff3 binary present on PATH (not available on Alpine, Windows)
- 2–3 temp files per merged file (os.tmpname + write + read + cleanup)
- fork+exec overhead (~1–5 ms per file on Linux)
- Complex exit-code detection workaround for LuaJIT vs Lua 5.1

The pure Lua implementation: zero shell calls, zero temp files, zero external
dependency. For a package with 20 files needing merge, savings are ~20–100 ms
of fork overhead alone, plus elimination of temp file I/O.

---

## 2026-03-17: SHA-256 tiered implementation

**Commit:** `bb16c30`

Three-tier SHA-256 (`lib/sha256/init.lua`). Tiers selected at load time.
Benchmark: `luajit lib/sha256/bench.lua` — 1 MB input, 10 reps, 1 warm-up call.

| tier | total (ms) | per-op (ms) | throughput |
|------|-----------|-------------|------------|
| ffi  | 138.7     | 13.87       | 72.1 MB/s  |
| lua  | 245.1     | 24.51       | 40.8 MB/s  |

**system tier** (OpenSSL `SHA256()`) not available on this machine (no `libssl.so`
in `LD_LIBRARY_PATH`); would be ~1 GB/s via SHA-NI when available.

**FFI tier** (LuaJIT FFI scalar, `uint32_t[64]` work arrays, `bit.ror/bxor`):
72 MB/s. JIT-compiled loop over 64 compression rounds.

**Lua tier** (pure Lua, streaming 64-byte blocks via `string.byte`): 41 MB/s.
Much faster than the ~10 MB/s spec estimate because LuaJIT JIT-compiles the
inner loop — the bit operations via `bit.*` trace cleanly. Streaming avoids
building a full byte-table for large inputs.

### Raw benchmark output (best of 3 runs)

```
sha256 benchmark — 1 MB input, 10 reps

tier          total (ms)  per-op (ms)    throughput
------------------------------------------------------
ffi                138.7       13.87       72.1 MB/s
lua                245.1       24.51       40.8 MB/s

Default tier: ffi
```

---

## 2026-03-02: lexer optimization — kill _buf + source-referencing intern

**Baseline commit:** `7b58fdc` (Phase 2 parser)
**Optimization commit:** `8941262`

Two-step optimization of the lexer hot path:

### Step 1: Kill `_buf`, use pointer arithmetic

Replaced per-byte `_buf_save_and_next()` with forward scanning and one
`ffi.string` at the end. Applied to identifiers, numbers, strings without
escapes, long strings. Kept `_buf` only for strings with escape sequences.

| file | before | after | speedup | alloc before | alloc after |
|------|--------|-------|---------|-------------|-------------|
| lex.lua (27 KB) | 10.0 ms / 2.1 MB/s | 8.9 ms / 2.9 MB/s | 1.12x | 1126 KB | 881 KB |
| parse.lua (26 KB) | 7.0 ms / 3.5 MB/s | 5.8 ms / 4.3 MB/s | 1.22x | 1012 KB | 721 KB |
| infer.lua (68 KB) | 37.3 ms / 1.8 MB/s | 27.3 ms / 2.4 MB/s | 1.37x | 3710 KB | 2489 KB |

### Step 2: Source-referencing intern pool

Replaced Lua-table intern pool with FNV-1a hash table + `memcmp`. Entries
store `(buf_id, offset, len)` referencing source buffers directly. The lexer
calls `intern_raw(pool, ptr, len, buf_id, offset)` — zero Lua string
allocation on the identifier/string hot path.

Hash function: FNV-1a 32-bit with split multiply (`lshift(h,24) + h*403`)
to stay within double precision. Open addressing with linear probing.
Keywords pre-interned from a static concatenated keyword buffer.

| file | step 1 | step 2 | speedup | alloc step 1 | alloc step 2 |
|------|--------|--------|---------|-------------|-------------|
| lex.lua (27 KB) | 8.9 ms / 2.9 MB/s | 1.5 ms / 17.7 MB/s | 6.0x | 881 KB | 518 KB |
| parse.lua (26 KB) | 5.8 ms / 4.3 MB/s | 1.7 ms / 14.3 MB/s | 3.3x | 721 KB | 563 KB |
| infer.lua (68 KB) | 27.3 ms / 2.4 MB/s | 7.0 ms / 9.5 MB/s | 3.9x | 2489 KB | 1644 KB |

### Total improvement (baseline → final)

| file | baseline | final | speedup | alloc reduction |
|------|----------|-------|---------|-----------------|
| lex.lua (27 KB) | 10.0 ms / 2.1 MB/s | 1.5 ms / 17.7 MB/s | **6.8x** | 1126→518 KB (54%) |
| parse.lua (26 KB) | 7.0 ms / 3.5 MB/s | 1.7 ms / 14.3 MB/s | **4.0x** | 1012→563 KB (44%) |
| infer.lua (68 KB) | 37.3 ms / 1.8 MB/s | 7.0 ms / 9.5 MB/s | **5.3x** | 3710→1644 KB (56%) |

### Revised 1M LOC projections

At ~10 MB/s throughput (infer.lua is the representative large file):
- 1M LOC ≈ 34 MB → **~3.6s serial, ~0.45s at 8 cores**
- Previous estimate was ~20s serial. 5.3x improvement.

The step 2 speedup was much larger than expected. The `ffi.string` call was
not just allocation overhead — it also forces a Lua string hash computation
and GC tracking per token. The FNV-1a + memcmp path skips all of that.

### Raw benchmark output

`luajit docs/perf/v2_parse.lua 500`, best of 3 rounds.

Baseline (`7b58fdc`):
```
lib/type/static/v2/lex.lua                 21.4 KB     9977 µs  1126.3 KB/parse    2.1 MB/s
lib/type/static/v2/parse.lua               25.5 KB     7035 µs  1012.3 KB/parse    3.5 MB/s
lib/type/static/infer.lua                  68.3 KB    37299 µs  3710.4 KB/parse    1.8 MB/s
```

After optimization (`8941262`):
```
lib/type/static/v2/lex.lua                 26.3 KB     1628 µs   559.2 KB/parse   15.8 MB/s
lib/type/static/v2/parse.lua               25.5 KB     2006 µs   637.0 KB/parse   12.4 MB/s
lib/type/static/infer.lua                  68.3 KB     6900 µs  1643.6 KB/parse    9.7 MB/s
```

---

## 2026-03-02: lexer profiling and optimization path

**Commit:** `7b58fdc`

### Profile breakdown (infer.lua, 68 KB, 12080 tokens, 1937 lines)

| phase | time | % of total |
|-------|------|-----------|
| lex only | 3.8 ms | 48% |
| parse (total) | 8.1 ms | 100% |
| parse minus lex | 4.3 ms | 52% |
| arena alloc (7814 nodes) | 0.06 ms | ~0% |
| intern.new() | 0.002 ms | ~0% |

JIT: 93 traces, 0 aborts. The lexer compiles fully — 313 ns/token is the
cost of the compiled code, not interpretation.

Interning overhead (cold pool vs warm pool): **unmeasurable** (<1%). The
bottleneck is not string interning itself.

Raw byte scan baseline: 48 µs (1.5 GB/s) — 80x faster than lexing. But
the raw scan JIT-compiles to a trivial accumulator loop, so this isn't a
meaningful comparison.

### 1M LOC projections

Assuming infer.lua ratios (36 bytes/line, 6.2 tokens/line):
- 1M LOC ≈ 34 MB source ≈ 6.2M tokens ≈ 3333 files at 300 lines/file
- Serial parse: **~20 seconds**
- 8-core parallel: **~2.5 seconds**
- Per-file overhead: 16 µs (negligible)

### Root cause: `_buf` mechanism + Lua string allocation

The lexer's identifier hot path is expensive per-byte:

1. `_buf_save_and_next()` — 3 nested method calls per byte
   (`_buf_save` → Lua table insert, `_nextbyte` → FFI read + 4 field writes)
2. `_buf_tostring()` — `string.char()` per byte + `table.concat` per token
3. `intern(pool, s)` — Lua table lookup keyed by Lua string

For a 10-char identifier: 30 method calls, 10 table inserts, 10 `string.char`
allocations, 1 `table.concat`, 1 Lua string intern. All unnecessary — the
source is already a contiguous `uint8_t*` buffer.

### Optimization path (decided)

**Step 1: Kill `_buf`, use pointer arithmetic.**
Scan identifiers/numbers/strings by advancing `self.pos`, then extract via
`ffi.string(src + start, len)`. Eliminates per-byte method calls and
`string.char` + `table.concat`. One `ffi.string` per token.

**Step 2: Source-referencing intern pool (zero Lua strings).**
Replace the Lua-table intern pool with an FFI hash table. Entries store
`(buf_id, offset, len)` referencing the source buffer directly. Lookup is
`hash(src+offset, len)` → probe → `memcmp` to confirm. No `ffi.string`,
no Lua string allocation anywhere in the lex path.

Source buffers must stay alive while their intern entries are referenced. This
aligns with the design doc's mmap'd source files for the LSP daemon. For
post-check cleanup, survivors (interface exports) get promoted into .cri
interface file byte buffers.

Keywords pre-intern by pointing at a static byte buffer.

A `pool:debug_str(id)` method provides `ffi.string` reconstruction for
diagnostics/error messages (cold path only).

**Hackability note:** The lexer is already FFI-heavy. This deepens that — the
intern pool becomes an FFI hash table instead of a Lua table, debugging
requires `debug_str()` instead of direct `print(s)`. The parser is unaffected
(still receives integer IDs). Within the project's existing FFI comfort level
but worth noting.

---

## 2026-03-02: scratch stack vs Lua tables for parser list collection

**Hypothesis:** Replacing temporary Lua tables in `flush_list()` with a
pre-allocated FFI `int32_t` scratch stack would reduce GC pressure and improve
parser throughput.

**Commit:** `7b58fdc` (baseline — Lua tables with `flush_list`)

**Benchmark:** `docs/perf/v2_parse.lua`, N=500, best of 3 rounds.

**Files:**

| file | size | flush_list (Lua tables) | scratch stack (FFI) |
|------|------|------------------------|---------------------|
| lex.lua | 21 KB | ~9 ms | ~13 ms |
| parse.lua | 26 KB | ~7 ms | ~8 ms |
| infer.lua | 68 KB | ~37 ms | ~42–75 ms |

Memory per parse was essentially identical (~3.6–3.8 KB/KB source).

**Verdict: rejected.** Scratch stack was ~1.5–2x slower on the large file.
LuaJIT's table allocator recycles small short-lived tables efficiently —
the handful of temporary collector tables per parse are not a meaningful
cost. The FFI method-call overhead (`scratch:push`, `scratch:flush`) exceeded
the savings.

**Takeaway:** Don't replace small Lua tables with FFI in LuaJIT unless the
tables are large, long-lived, or in a JIT-hostile path. The real allocation
pressure is in the arenas and list pools (already FFI). If list collection
ever matters, restructure the grammar (e.g. sibling-linked AST nodes) instead.

**Experiment commit:** `7fcde15` (branch `experiment/scratch-stack`)

Raw output (infer.lua, N=500, from session `eacb799e`):
```
=== SCRATCH STACK ===
round 1:  75115 µs/parse  3696.7 KB/parse
round 2:  75399 µs/parse  3666.5 KB/parse
round 3:  42611 µs/parse  3712.6 KB/parse

=== LUA TABLES ===
round 1:  38983 µs/parse  3653.9 KB/parse
round 2:  37022 µs/parse  3635.0 KB/parse
round 3:  37205 µs/parse  3632.9 KB/parse
```

---

## 2026-03-02: v2 parser baseline (Phase 2)

**Commit:** `7b58fdc`

**Benchmark:** `docs/perf/v2_parse.lua`, N=500, best of 3 rounds.

| file | size | time | alloc | throughput |
|------|------|------|-------|------------|
| lex.lua | 21 KB | 10.0 ms | 1126 KB | 2.1 MB/s |
| parse.lua | 26 KB | 7.9 ms | 1088 KB | 3.1 MB/s |
| infer.lua | 68 KB | 38.4 ms | 3821 KB | 1.7 MB/s |

Throughput is ~2 MB/s. Allocation is ~50x source size (dominated by arena
growth policy — arenas double, so half of final capacity is wasted on average).

**Key files:** `lib/type/static/v2/parse.lua`, `lib/type/static/v2/lex.lua`
