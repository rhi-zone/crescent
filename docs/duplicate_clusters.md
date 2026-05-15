# Duplicate library clusters — triage

Source: `docs/inventory.md` "Known duplicate clusters" callout. Each section gathers metadata and a recommendation. **Pure analysis — no code changed, nothing deleted, nothing moved.**

LOC = sum of `.lua` lines under the dir excluding `*_test.lua`. "tests" = number of `*_test.lua` files. All entries had exactly one test file as of 2026-04-28 unless noted.

---

## FSM family — five impls

### Cluster: finite/hierarchical state machines
- `lib/fsm/` — 238 LOC, tests: yes, last-touched: `24abd62 2026-04-11`, status: stable.
  API: minimal `M.new` constructor, single Machine prototype.
- `lib/state/` — 212 LOC, tests: yes, last-touched: `8a7792d 2026-04-11`, status: stable.
  API: `M.machine`. Header claims FSM **and** HSM with guards/callbacks/listeners.
- `lib/state_machine/` — 225 LOC, tests: yes, last-touched: `d8e44db 2026-04-12`, status: stable.
  API: `M.new`, `M.restore`, `sm:send`, `sm:can`. Flat FSM with snapshot restore.
- `lib/statemachine/` — 379 LOC, tests: yes, last-touched: `e251cbb 2026-04-11`, status: stable.
  API: `M.create`. Harel statecharts, nested compound states, XState-inspired service API.
- `lib/state_machine_hsm/` — 385 LOC, tests: yes, last-touched: `4e65b85 2026-04-12`, status: stable.
  API: `M.chart`. HSM with shallow/deep history, LCA path entry/exit, dot-notation.

**Diff in approach:** Two distinct concerns: flat FSM (`fsm`, `state_machine`, `state`) and hierarchical/Harel (`statemachine`, `state_machine_hsm`). Among the flat impls the APIs differ in surface area (`new` vs `machine`) and feature set (snapshot/restore only in `state_machine`). The two HSM impls overlap heavily in feature claims.

**Recommendation:** Pick one flat (lean toward `state_machine` — has snapshot/restore and clean docstring) and one hierarchical (lean toward `state_machine_hsm` — slightly larger, more recent). Drop `fsm`, `state`, `statemachine`. Needs decision on which HSM to keep, but the 3-flat → 1 reduction is uncontroversial.

---

## Validation / schema — five impls

### Cluster: validation libraries
- `lib/json_schema/` — 618 LOC, tests: yes, last-touched: `b95fb8d 2026-04-11`, status: stable.
  API: `M.compile`, `M.validate`. JSON Schema draft-7.
- `lib/jsonschema/` — 498 LOC, tests: yes, last-touched: `77d6951 2026-04-12`, status: stable.
  API: `M.compile`, `M.validate`, `M.is_valid`, `M.null`. JSON Schema draft-07; uses Lua patterns not ECMA-262.
- `lib/schema_validator/` — 737 LOC, tests: yes, last-touched: `a887fbb 2026-04-12`, status: stable.
  API: combinator-style `M.string`, `M.number`, `M.array`, `M.object`, `M.union`, `M.literal`, `M.enum`, `M.coerce`, `M.merge`. Builder DSL, not JSON Schema.
- `lib/validate/` — 264 LOC, tests: yes, last-touched: `642a48f 2026-04-11`, status: stable.
  API: `M.string`, `M.number`, `M.array`, `M.record`, `M.map`, `M.one_of`, `M.all_of`, `M.optional`, `M.custom`. Combinator DSL.
- `lib/validation/` — 1258 LOC, tests: yes, last-touched: `975fb7f 2026-04-12`, status: stable.
  API: combinators with `M.intersection`, `M.not_`, `M.format_errors`. Largest of the five.

**Diff in approach:** Two families. (a) JSON Schema validators — `json_schema`, `jsonschema` — same spec, ~same API, different impls. (b) Combinator/DSL validators — `schema_validator`, `validate`, `validation` — same family, increasing scope (validate < schema_validator < validation).

**Recommendation:**
- JSON Schema: pick one. Lean `json_schema` (larger, has `compile/validate`); `jsonschema` adds `is_valid`/`null` but is smaller and uses Lua patterns. Needs decision on which to keep.
- Combinator: lean `validation` (largest, most complete, includes structured errors and `intersection`/`not_`). Drop `validate` and `schema_validator`.

---

## Caches — four impls

### Cluster: cache / LRU
- `lib/cache/` — 246 LOC, tests: yes, last-touched: `f90dd8f 2026-04-16`, status: stable.
  API: `M.new` with TTL/`on_evict`/clock. Generic cache, not strictly LRU.
- `lib/lru/` — 791 LOC, tests: yes, last-touched: `f90dd8f 2026-04-16`, status: stable.
  API: `M.new`, `M.lfu_new`, `M.twoq_new`. LRU **plus** LFU and 2Q variants — broadest impl.
- `lib/lru_cache/` — 140 LOC, tests: yes, last-touched: `0d37168 2026-04-12`, status: stable.
  API: `M.new`. Minimal O(1) LRU, doubly-linked list + map.
- `lib/lru_ttl/` — 449 LOC, tests: yes, last-touched: `f90dd8f 2026-04-16`, status: stable.
  API: `M.new` with TTL, per-entry metadata, stats, events.

**Diff in approach:** `lru` is the umbrella with LRU+LFU+2Q. `lru_cache` is a minimal LRU. `lru_ttl` adds TTL+metadata+events. `cache` is a generic TTL cache (not necessarily LRU).

**Recommendation:** Lean toward keeping `lru` as canonical (broadest, has multiple eviction policies). Fold `lru_cache` and `lru_ttl` into `lru` as additional policies. `cache` is arguably a separate concern (general-purpose TTL store) — needs decision whether to keep it standalone or merge.

---

## Bloom filters — four impls

### Cluster: bloom variants
- `lib/bloom/` — 446 LOC, tests: yes, last-touched: `a4f3820 2026-04-12`, status: stable.
  API: `M.new`, `M.counting_new`, `M.from_string`, `M.deserialize`, `M.optimal_params`, `M.counting`. Standard + counting in one module.
- `lib/bloom_count/` — 447 LOC, tests: yes, last-touched: `5f952b9 2026-04-12`, status: stable.
  API: `M.counting`, `M.cuckoo`, `M.scalable`. Counting + Cuckoo + Scalable Bloom.
- `lib/bloom_filter/` — 325 LOC, tests: yes, last-touched: `35e21cc 2026-04-12`, status: stable.
  API: `M.new`, `M.counting`, `M.scalable`. Standard + counting + scalable.
- `lib/bloom_clock/` — 238 LOC, tests: yes, last-touched: `7fe0ce7 2026-04-12`, status: stable.
  API: `M.new`, `M.concurrent`, `M.happened_before`, `M.deserialize`. **Different concern** — Bloom-clock causal ordering, not set membership.

**Diff in approach:** `bloom_clock` is a separate concept (causality/happens-before) and should be kept. The other three overlap on standard/counting/scalable Bloom. `bloom_count` is the only one with Cuckoo filter. `bloom` and `bloom_filter` are near-duplicates on standard+counting+scalable.

**Recommendation:** Keep `bloom_clock` (different concern). Among the rest, lean toward keeping a merged module — pick `bloom` (largest with serialization + optimal_params) as canonical, fold `bloom_count`'s Cuckoo into it, drop `bloom_filter`. Needs decision on whether Cuckoo belongs in a Bloom module or its own.

---

## Merkle trees

### Cluster: merkle
- `lib/merkle/` — 276 LOC, tests: yes, last-touched: `c5cb168 2026-04-12`, status: stable.
  API: `M.build`, `M.build_from_hashes`, `M.verify`, `M.deserialize`. Plain Merkle tree.
- `lib/merkle_tree/` — 508 LOC, tests: yes, last-touched: `30c739c 2026-04-12`, status: stable.
  API: `M.new`, `M.new_from_leaf_hashes`, `M.concat`, `M.diff`, `M.verify`, `M.sparse`, `M.verify_sparse`. Adds proofs/diff/concat/sparse Merkle.

**Diff in approach:** `merkle_tree` is a strict superset (sparse Merkle, diff, concat). `merkle` is a smaller "build a tree, verify a proof" API.

**Recommendation:** `merkle_tree` is canonical. Drop `merkle`.

**Resolved 2026-05-15:** merkle dropped; merkle_tree is canonical.

---

## Geohash

### Cluster: geo_hash / geohash
- `lib/geo_hash/` — 328 LOC, tests: yes, last-touched: `4439a69 2026-04-12`, status: stable.
  API: `M.encode`, `M.decode`, `M.decode_center`, `M.neighbor`, `M.neighbors`, `M.parent`, `M.distance`, `M.haversine`, `M.is_valid`, `M.bboxes`, `M.within_radius`, `M.common_prefix`, `M.precision_info`.
- `lib/geohash/` — 319 LOC, tests: yes, last-touched: `052949e 2026-04-12`, status: stable.
  API: `M.encode`, `M.decode`, `M.decode_bbox`, `M.neighbor`, `M.neighbors`, `M.are_neighbors`, `M.within`. Smaller surface.

**Diff in approach:** Same concept; `geo_hash` has a wider surface (haversine, within_radius, parent, bboxes). `geohash` is the leaner version.

**Recommendation:** `geo_hash` is canonical. Drop `geohash`.

**Resolved 2026-05-15:** geohash dropped; geo_hash is canonical. `decode_bbox` is `decode` (same data, nested shape); `are_neighbors` / `within` are trivial compositions of `neighbors` / `bboxes` + `haversine`.

---

## Cron

### Cluster: cron / cron_parser
- `lib/cron/` — 631 LOC, tests: yes, last-touched: `f90dd8f 2026-04-16`, status: stable.
  API: `M.parse`, `M.Expr`. Parser **and** scheduler.
- `lib/cron_parser/` — 577 LOC, tests: yes, last-touched: `f90dd8f 2026-04-16`, status: stable.
  API: `M.parse`, `M.parse_field`, `M.validate`. Parser only; supports 5- and 6-field; named months/weekdays; `@aliases`.

**Diff in approach:** `cron` is parser+scheduler; `cron_parser` is parser-only with finer-grained field-level helpers.

**Recommendation:** Needs decision — `cron` is canonical if scheduler is wanted; `cron_parser` if only parsing. Could also merge: keep `cron` with `parse_field`/`validate` from `cron_parser`.

---

## Protocol Buffers

### Cluster: proto / protocol_buffer
- `lib/proto/` — 546 LOC, tests: yes, last-touched: `f557dd2 2026-04-11`, status: stable.
  API: `M.message`, `M.repeated`, `M.ENUM`, `M.encode`, `M.decode`, `M.string_to_msg`/`M.msg_to_string`, type constants.
- `lib/protocol_buffer/` — 665 LOC, tests: yes, last-touched: `bcd3c2d 2026-04-12`, status: stable.
  API: `M.encode`, `M.decode`, `M.encode_varint`, `M.decode_varint`, `M.encode_zigzag`, `M.decode_zigzag`, `M.field_tag`, `M.encode_raw`, `M.decode_raw`, `M.validate`, wire-type constants.

**Diff in approach:** `proto` is higher-level (schema builder DSL, `string_to_msg`/`msg_to_string` per crescent codec convention). `protocol_buffer` exposes raw varint/zigzag/field-tag primitives — lower-level.

**Recommendation:** Lean `proto` (follows codec convention). Could fold `protocol_buffer`'s raw helpers into it as an internal/exposed lower API. Needs decision on whether raw primitives stay public.

---

## Neural networks

### Cluster: neural / neural_net
- `lib/neural/` — 452 LOC, tests: yes, last-touched: `4c870dc 2026-04-12`, status: stable.
  API: `M.network`, `M.train`, `M.load`, `M.loss`, `M.activations`. Compact "build a net, train it" API.
- `lib/neural_net/` — 466 LOC, tests: yes, last-touched: `81a034f 2026-04-12`, status: stable.
  API: `M.layer`, `M.layer_random`, `M.network`, `M.trainer`, `M.linear`, `M.relu`, `M.sigmoid`, `M.tanh`, `M.softmax`, `M.mse`, `M.cross_entropy`, `M.binary_cross_entropy`, `M.deserialize`. Compositional layer/activation/loss API.

**Diff in approach:** Same concept (feedforward MLP + backprop). `neural_net` is more compositional with explicit layer/activation/loss primitives. `neural` is a single-call training API.

**Recommendation:** Lean `neural_net` (more flexible API, named layer primitives). Drop `neural`.

---

## Noise

### Cluster: noise / noise_gen
- `lib/noise/` — 390 LOC, tests: yes, last-touched: `2df5575 2026-04-12`, status: stable.
  API: `perlin2/3`, `simplex2`, `fBm`. `M.normalize`, `M.seeded`.
- `lib/noise_gen/` — 628 LOC, tests: yes, last-touched: `ff0a3f6 2026-04-12`, status: stable.
  API: Value, Perlin, Simplex, Worley + fBm/turbulence/domain-warping/ridged variants.

**Diff in approach:** `noise_gen` is a strict superset (adds Value, Worley, ridged, domain-warping).

**Recommendation:** `noise_gen` is canonical. Drop `noise`.

**Resolved 2026-05-15:** noise dropped; noise_gen is canonical.

---

## Rate limiting

### Cluster: ratelimit / rate_limiter
- `lib/ratelimit/` — 298 LOC, tests: yes, last-touched: `08182e5 2026-04-11`, status: stable.
  API: `M.token_bucket`, `M.leaky_bucket`, `M.fixed_window`, `M.sliding_window`, `M.keyed`.
- `lib/rate_limiter/` — 428 LOC, tests: yes, last-touched: `a4d5f8f 2026-04-12`, status: stable.
  API: `M.token_bucket`, `M.leaky_bucket`, `M.fixed_window`, `M.sliding_window_counter`, `M.sliding_window_log`, `M.concurrent`, `M.multi`.

**Diff in approach:** `rate_limiter` is broader (counter vs log sliding-window split, concurrent semaphore-style limiter, multi-limiter composition). `ratelimit` adds keyed wrapper.

**Recommendation:** Lean `rate_limiter` (more algorithm coverage). Port `keyed` from `ratelimit` if not present. Drop `ratelimit`.

---

## Observable / observer

### Cluster: push observable streams
- `lib/observable/` — 679 LOC, tests: yes, last-touched: `08182e5 2026-04-11`, status: stable.
  API: `M.create`, `M.of`, `M.from_array`, `M.empty`, `M.never`, `M.merge`, `M.concat`, `M.zip`, `M.combine_latest`, `M.subject`, `M.replay_subject`. Has replay subject.
- `lib/observer/` — 872 LOC, tests: yes, last-touched: `55f080a 2026-04-16`, status: stable.
  API: `M.create`, `M.of`, `M.from`, `M.range`, `M.empty`, `M.never`, `M.error`, `M.defer`, `M.merge`, `M.concat`, `M.zip`, `M.combine_latest`, `M.subject`, `M.behavior_subject`. Larger.

**Diff in approach:** Both cold-sync push observables. `observer` is larger (has `defer`, `range`, `error`, `behavior_subject`). `observable` has `replay_subject` and `from_array`.

**Recommendation:** Lean `observer` (larger, more recent, more operators); port `replay_subject` over. Drop `observable`. Note: distinct from `lib/reactive/` and `lib/signals/` per inventory.

**Resolved 2026-05-15:** observable dropped; replay_subject ported to observer.

---

## Event emitter

### Cluster: event / event_emitter
- `lib/event/` — 266 LOC, tests: yes, last-touched: `8601eba 2026-04-11`, status: stable.
  API: `M.new`, `M.mixin`. Wildcards, once, priority, propagation control.
- `lib/event_emitter/` — 204 LOC, tests: yes, last-touched: `8fd598d 2026-04-12`, status: stable.
  API: `M.new`, `M.mixin`. Has DEFAULT_MAX_LISTENERS (Node.js style).

**Diff in approach:** Both pub/sub. `event` claims wildcard support and priority ordering. `event_emitter` follows Node.js idiom (max-listeners cap).

**Recommendation:** Lean `event` (more features per docstring, larger). Drop `event_emitter`. Needs decision if Node.js parity matters for any caller.

---

## Automata

### Cluster: NFA/DFA — automata / finite_automata
- `lib/automata/` — 839 LOC, tests: yes, last-touched: `9260cc0 2026-04-11`, status: stable.
  API: `M.nfa_new`, `M.dfa_new`, `M.nfa_to_dfa` (subset construction), `M.minimize` (Hopcroft), `M.from_regex`, `M.union`, `M.intersection`, `M.complement`.
- `lib/finite_automata/` — 577 LOC, tests: yes, last-touched: `c93496f 2026-04-12`, status: stable.
  API: `M.nfa`, `M.dfa`, `M.equivalent`. Smaller surface.

**Diff in approach:** `automata` is a strict superset (regex compile, Hopcroft minimization, set ops). `finite_automata` adds `equivalent` (DFA equivalence check) which `automata` may not have.

**Recommendation:** `automata` is canonical. Port `equivalent` if not present. Drop `finite_automata`.

**Resolved 2026-05-15:** finite_automata dropped; equivalent ported to automata.

---

## Cellular automata

### Cluster: automata_2d / cellular_automata
- `lib/automata_2d/` — 524 LOC, tests: yes, last-touched: `f2151d0 2026-04-12`, status: stable.
  API: `M.dense`, `M.sparse`, `M.parse_rule`, `M.rle_encode`, `M.rle_decode`, `M.patterns`, `M.rules`. 2D only; sparse + dense; RLE pattern format.
- `lib/cellular_automata/` — 435 LOC, tests: yes, last-touched: `a85d618 2026-04-12`, status: stable.
  API: `M.grid`, `M.rule`, `M.patterns`. **1D Wolfram + 2D totalistic.**

**Diff in approach:** Different scope. `cellular_automata` covers 1D (elementary Wolfram) + 2D. `automata_2d` is 2D-only but more advanced (sparse grids, RLE I/O).

**Recommendation:** Needs decision — they cover different concerns. Either keep both (rename for clarity), or merge into one with explicit 1D/2D modules.

---

## Expression evaluators

### Cluster: expr / expression_evaluator
- `lib/expr/` — 734 LOC, tests: yes, last-touched: `83bd19f 2026-04-12`, status: stable.
  API: `M.parse`, `M.compile`, `M.eval`, `M.eval_ast`, `M.simplify`, `M.diff`, `M.to_string`, `M.vars`. **Includes symbolic differentiation.**
- `lib/expression_evaluator/` — 504 LOC, tests: yes, last-touched: `a1ef320 2026-04-12`, status: stable.
  API: `M.parse`, `M.compile`, `M.eval`. Built-in functions, evaluator only.

**Diff in approach:** `expr` is a superset (adds simplify/diff/AST inspection). `expression_evaluator` is just parse+eval.

**Recommendation:** `expr` is canonical. Drop `expression_evaluator`.

**Resolved 2026-05-15:** expression_evaluator dropped; expr is canonical.

---

## Roman numerals

### Cluster: roman / roman_numeral
- `lib/roman/` — 150 LOC, tests: yes, last-touched: `1aafc47 2026-04-12`, status: stable.
  API: `M.encode`, `M.decode`, `M.to_roman`, `M.from_roman`, `M.is_valid`, `M.normalize`, `MIN`/`MAX`.
- `lib/roman_numeral/` — 499 LOC, tests: yes, last-touched: `5e21ef8 2026-04-12`, status: stable.
  API: superset — adds `to_roman_additive`, `to_roman_large`, `from_roman_large` (vinculum), `to_unicode`, `from_unicode`, `to_ordinal`, `format`.

**Diff in approach:** `roman_numeral` is a strict superset (Unicode, vinculum, ordinals, additive notation).

**Recommendation:** `roman_numeral` is canonical. Drop `roman`.

**Resolved 2026-05-15:** roman dropped; roman_numeral is canonical.

---

## L-systems

### Cluster: lindenmayer / lsystem
- `lib/lindenmayer/` — 497 LOC, tests: yes, last-touched: `dc15d7b 2026-04-12`, status: stable.
  API: `M.new` plus presets (`KOCH_SNOWFLAKE`, `DRAGON_CURVE`, `SIERPINSKI_TRIANGLE`, `BINARY_TREE`, `FERN`). Header claims turtle graphics support.
- `lib/lsystem/` — 280 LOC, tests: yes, last-touched: `3b5eac1 2026-04-12`, status: stable.
  API: `M.new`, `M.presets`. Smaller; no explicit turtle integration.

**Diff in approach:** `lindenmayer` is the larger/newer impl with turtle graphics and named presets at module level.

**Recommendation:** `lindenmayer` is canonical. Drop `lsystem`.

**Resolved 2026-05-15:** lsystem dropped; hilbert/pentigree/plant presets ported to lindenmayer.

---

## Option / Maybe / Either — four impls

### Cluster: ADT for nullable & sum types
- `lib/option/` — 232 LOC, tests: yes, last-touched: `c03986a 2026-04-12`, status: stable.
  API: `M.some`, `M.none`, `M.of`, `M.from_fn`, `M.from_result`, `M.all`, `M.any`. Standalone Option only.
- `lib/either/` — 318 LOC, tests: yes, last-touched: `63eae46 2026-04-11`, status: stable.
  API: `M.Left`, `M.Right`, `M.Some`, `M.None`, `M.maybe_from`, `M.from_pair`. Either + Maybe in one.
- `lib/fp/either/` — 307 LOC, tests: yes, last-touched: `839610f 2026-03-29`, status: wip (parent `lib/fp/` flagged in-flux).
  API: typeclass-conformant Either (Mappable/Applicable/Chainable/Foldable/Semigroup).
- `lib/fp/maybe/` — 272 LOC, tests: yes, last-touched: `a008276 2026-04-17`, status: wip.
  API: typeclass-conformant Maybe (Mappable/Applicable/Chainable/Foldable/Traversable/Semigroup/Monoid).

**Diff in approach:** Two design philosophies. (a) Standalone, ad-hoc API: `option`, `either`. (b) `lib/fp/` typeclass hierarchy with consistent interface across types: `fp/either`, `fp/maybe`. The `fp/` versions cohere with the rest of the typeclass hierarchy.

**Recommendation:** Needs decision — depends on whether crescent commits to the `lib/fp/` typeclass design (currently wip, in flux per `lib/fp/CLAUDE.md`). If `fp/` is endorsed, drop `option` and `either`. If not, `either` (covers both) is canonical and `option` should be dropped. Don't keep both styles.

---

## JSON

### Cluster: top-level json / format/json
- `lib/json/` — 460 LOC, tests: yes, last-touched: `8a7792d 2026-04-11`, status: stable.
  API: `M.encode`, `M.decode`, `M.parse`, `M.stringify`, `M.json_to_string`, `M.string_to_json`, `M.null`. Pure-Lua only.
- `lib/format/json/` — 1483 LOC across `init.lua` + `pure.lua` + `ffi.lua` + `simd.lua` + `schema.lua`, tests: 2, last-touched: `10e7d40 2026-03-26`, status: stable.
  API: same `M.encode`/`M.decode`. Tiered (simd > ffi > pure) selected at load time.

**Diff in approach:** `format/json` is the tiered impl per crescent's tier convention; `lib/json/` is a single pure-Lua impl. The summary explicitly recommends the tiered version.

**Recommendation:** `lib/format/json/` is canonical. Drop `lib/json/` (or fold into the pure tier of `format/json` if the impls differ in correctness).

---

## JSON Patch

### Cluster: patch / json_patch
- `lib/patch/` — 417 LOC, tests: yes, last-touched: `a228525 2026-04-11`, status: stable.
  API: `M.apply`, `M.diff`, `M.get`, `M.set`, `M.remove`, `M.pointer_encode`, `M.pointer_parse`, `M.deep_copy`. Pointer + Patch combined.
- `lib/json_patch/` — 549 LOC, tests: yes, last-touched: `17286ba 2026-04-12`, status: stable.
  API: `M.apply`, `M.diff`, `M.build`, `M.parse`, `M.escape`, `M.unescape`, `M.pointer_get`, `M.pointer_set`, `M.pointer_del`, `M.validate_patch`, `M.deep_copy`, `M.deep_equal`.

**Diff in approach:** `json_patch` is larger and more complete (validate_patch, build, escape/unescape). Both implement RFC 6901+6902.

**Recommendation:** `json_patch` is canonical. Drop `patch`. Naming is also more discoverable.

**Resolved 2026-05-15:** patch dropped; json_patch is canonical.

---

## Unified pipeline shells

### Cluster: top-level hast/mdast/remark*/rehype* shells
- `lib/hast/` — empty (no init.lua), last-touched: `c69ccea 2026-04-10`, status: stub.
- `lib/mdast/` — empty (no init.lua), last-touched: `c69ccea 2026-04-10`, status: stub.
- `lib/remark/`, `lib/remark_frontmatter/`, `lib/remark_gfm/`, `lib/remark_rehype/`, `lib/remark_toc/` — empty, last-touched: `c69ccea 2026-04-10`, status: stub.
- `lib/rehype/`, `lib/rehype_autolink_headings/`, `lib/rehype_external_links/`, `lib/rehype_highlight/`, `lib/rehype_sanitize/`, `lib/rehype_slug/` — empty, last-touched: `c69ccea 2026-04-10`, status: stub.
- `lib/unified/` — 11678 LOC, 61 tests, last-touched: `07231c0 2026-04-12`, status: wip (per `lib/unified/STATUS.md`). Contains real impls: `unified/hast`, `unified/mdast`, `unified/remark*`, `unified/rehype*`, `unified/nlcst`, `unified/xast`, `unified/retext*`, `unified/unist_util_*`.

**Diff in approach:** Top-level shells are empty squatters; `lib/unified/` holds the real implementations.

**Recommendation:** Drop all top-level stub shells (hast, mdast, remark*, rehype*). `lib/unified/` is canonical. This is the clearest cut in the entire triage.

**Resolved 2026-05-15:** stubs deleted; `lib/unified/` is canonical.
