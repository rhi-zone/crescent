# Slice v2 increment 5 — the multi-return / dynamic-index statement family

Date: 2026-06-12. Design + implementation, one commit on `master`.
Design: `docs/agnostic-static-analysis-crescent-slice.md` §6.9 (derived whole);
findings §9.15; DONE entry §10.6. Survey delta: `docs/slice-survey-v1.md`
"after v2 increment 5". Map one-liner: `docs/static-analysis-map.md`.

## 1. The demand — diagnosed before designing

The e2e histogram after increment 4 topped with `dynamic-index` (589 files),
`multi-return` (482), `dynamic-index-assign` (477), `multi-assign` (466).
Increment 3 already landed *basic* assignment forms, yet these tagged the top —
because the survey records each file's FIRST/lowering markers and the tag names
collapse distinct sub-shapes. A per-construct diagnostic harness lowered every
corpus file and sampled 15 real sites per tag (`lib/mediator`, `lib/memoize`,
`lib/wire`, `lib/dns`, `lib/websocket`, `lib/ecs`, `lib/email`, …). The measured
sub-shapes:

| Tag | Real sub-shape (the residue) |
|---|---|
| `dynamic-index` | `t[expr]` READS the lowering rejected wholesale (never reached `index_result`): `handlers[fname]`, `list[i]`, `lru.map[key]`. Objects are indexer / rec-with-indexer / closed rec. |
| `multi-return` | the `return a, b` STATEMENT (`return nil, "msg"`, `return v, true`, `return mw(...)`). Single-return was handled; ≥2 values marked. |
| `multi-assign` | the METHOD-CALL / field-call as the LAST RHS value: `n, err = r:uint32_be()`, `send, close = tcp_client(...)`, `ok, err = self._db:execute(SCHEMA)`. `flatten_values` spread only a `call`-to-an-`fn`-local. |
| `dynamic-index-assign` | the CLOSED-REC dynamic write `t[e] = v` (indexer-typed writes landed in incr 3): `parts[i] = …`, `map[victim.key] = nil`. |

## 2. The design (§6.9), derived from the value universe

- **Dynamic-index reads (§6.9.2):** `t[e]` resolves via `index_result`. New RESULT
  rule: a CLOSED rec under a dynamic key ⇒ `union(field-value-types) | nil` (a
  dynamic key may hit any listed field or miss; the closed row promises no unlisted
  field, so strictly more precise than `unknown` — the dual of the open-row
  `unknown`). The `synth_index` rule gains a 2-premise dynamic-key form (the node
  grammar already declared `key?: Node`).
- **Multi-return statement (§6.9.3):** the `return a, b` builds the §6.5.5 `tuple`
  at the return site, checked `⇐ ret_ty` (the declared return threaded as the joint
  tuple, so the §6.5.5 `tuple <: tuple` / `tuple <: union-of-tuples` rule fires) or
  captured as the module value type.
- **Multi-assign (§6.9.4):** `flatten_values` recovers the producer's `Ret` from
  the synthesized fn type regardless of the call form (name-call, method-call,
  field-call), so the dominant `n, err = r:read()` spreads.
- **Dynamic-index-assign over a closed rec (§6.9.5):** a homogeneous closed rec
  (one common field type) checks `v ⇐ V` via the new `index_write_target` (the
  WRITE dual of `index_result`); heterogeneous/empty stays out-of-subset.

## 3. What was built

`lib/type/analysis/crescent_slice.lua`:
- `index_result`: closed-rec dynamic-key result rule (`union(fields) | nil`).
- `index_write_target`: the WRITE dual (homogeneous closed rec ⇒ V, else nil).
- `synth_index` hosted rule: a 2-premise dynamic-key form (object + key premises).
- `synth_tuple` hosted rule: the value-position dual of `synth_table` (N has_type
  premises ⇒ `has_type(tuple_node, G.tuple(slot-types))`); registered in
  `evidence_methods`.

`lib/type/analysis/crescent_slice_lower.lua`:
- `synth_expr` `indexdyn` arm: synthesize object + key, resolve via `index_result`,
  emit a 2-premise `synth_index` claim (or keep the marker on a non-table object).
- `return` arm: `#values > 1` builds the joint tuple via `synth_tuple`, checks
  `⇐ ret_ty` / captures the module type.
- funcdecl/localfunc body `ret_ty`: threaded as `G.tuple(fret.fixed, fret.vararg)`
  for a multi-value declared return, else `fret.fixed[1]`.
- `flatten_values`: generalized last-value spread (method-call / field-call).
- `assign` `indexdyn` target: uses `index_write_target` (homogeneous closed-rec
  write); heterogeneous/empty marks.

## 4. Per-item status

| Sub-form | Status | Evidence |
|---|---|---|
| dynamic-index READ over indexer / rec-with-indexer | **DONE** | inline test CLEAN; e2e `dynamic-index` 589 → 512 |
| dynamic-index READ over closed rec (`union\|nil`) | **DONE** | inline test CLEAN (`r[k] : integer \| nil`) |
| multi-return STATEMENT (check + capture) | **DONE** | inline tests CLEAN (declared tuple + §6.5.5 union-of-tuples member); `multi-return` 482 → 317 |
| multi-assign with CALL last value | **DONE** | inline test CLEAN |
| multi-assign with METHOD-CALL last value | **DONE** | inline test CLEAN (`n, err = r:read()`); `multi-assign` 466 → 450 |
| dynamic-index WRITE over homogeneous closed rec | **DONE** | inline test CLEAN |
| dynamic-index WRITE over heterogeneous/empty closed rec | **DEFERRED (§9.15.4)** | inline test OUT-OF-SUBSET; un-defer: rec-field-widening |
| `return f()` multi-spread | **DEFERRED (§9.15.5)** | un-defer: tuple-spread-premise mechanism |
| body-synthesized multi-return join (unannotated fn) | **DEFERRED (§9.15.6)** | un-defer: local-return-type-collection pass |

## 5. The e2e headline

`bin/cr run lib/type/analysis/slice_survey.lua --e2e` (868 files, 5s budget):

| Class | after incr 4 | after incr 5 |
|---|--:|--:|
| CHECKED-CLEAN | 22 (2.5%) | **25 (2.9%)** |
| CHECKED-FINDINGS | 6 (0.7%) | 9 (1.0%) |
| OUT-OF-SUBSET | 833 (96.1%) | 828 (95.4%) |
| TIMEOUT | 0 | **0** |

**The honest, load-bearing finding:** the whole-file CLEAN jump (22 → 25) is
smaller than increment 4's (5 → 22) because the e2e gate is the LAST out-of-subset
construct per file, and the multi-return / dynamic-index family files carry several
remaining blockers each. Closing the family moves the CONSTRUCT histogram far more
than the whole-file gate: `multi-return` 482 → 317 (−165), `dynamic-index` 589 →
512 (−77), `multi-assign` 466 → 450 (−16) (`dynamic-index-assign` +5, the deeper
reach surfacing the marker later in more files; the homogeneous closed-rec write IS
in-subset, the heterogeneous is the recorded deferral). The new front:
`call-non-function` (259), `iterate-non-table` / `general-iterator` (211 / 118),
string-method `no-such-field:sub`/`gsub`/`match` (182 / 125 / 108).

## 6. Findings count

**§9.15: 6 findings** — 1 design correction (`synth_tuple` needed, the design's
zero-method projection corrected against the substrate), 1 mechanization detail
(declared return threaded as the joint tuple), 1 real bug caught by the corpus
(closed-rec read rule reused as the write target → empty-rec regression, fixed by
`index_write_target`), and 3 deferrals (heterogeneous closed-rec write, `return f()`
multi-spread, body-synthesized multi-return join) each with an un-defer trigger.

## 7. Verification

- Full analysis suite green: **6421 assertions** (6374 + 47 new), 0 failed.
- `timeout 30 bin/cr check` clean on both touched lib files (0 new errors vs HEAD;
  HEAD was 0/0, working tree is 0/0).
- 0 TIMEOUT in the e2e survey.
- Corpus 11-fixture split: 3 CLEAN / 1 FINDINGS / 7 OUT-OF-SUBSET → **4 CLEAN /
  1 FINDINGS / 6 OUT-OF-SUBSET** (closure_param_typing → CLEAN), 0 rejections.

The fence held. Substrate (`init.lua`) **untouched**, byte-for-byte.
