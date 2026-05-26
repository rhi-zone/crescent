# v5 typechecker gaps

Tracking file for v5. Goal: drive unchecked items to zero. The file grows as
new gaps surface; closed items stay as history with their commit SHA. Never
consolidate or vague-up items to lower the count.

Each item: severity tag, one-line description specific enough that closure
requires real work (not "improve X"), source pointer (file:line, doc section,
or commit SHA where surfaced), category.

## Rules

1. Items are added when discovered. Never deleted.
2. An item is closed only by a commit that lands code/tests/docs enforcing the fix. The closing line includes that SHA.
3. Items do not get consolidated to reduce count. If two items overlap, keep both and cross-reference.
4. Severity is best-effort and can change; don't game it.
5. Source pointer is required (file:line, doc section, or commit SHA). Items without sources are not real.

---

## Open

### High impact

- [ ] **P6** `[gen-pass]` Binary and unary operators emit fresh uvar instead of arithmetic/logical constraints — lib/type/static-v5/constrain.lua:38
- [ ] **P6** `[gen-pass]` for-in and for-num loop variables bound to `unknown` — lib/type/static-v5/constrain.lua:39
- [ ] **P6** `[gen-pass]` Multi-return tuple types use union as approximation instead of proper tuple constraints — lib/type/static-v5/constrain.lua:42
- [ ] **P6** `[gen-pass]` Method dispatch edge cases beyond simple `obj:method(...)` not modelled — lib/type/static-v5/constrain.lua:37
- [ ] **P6** `[gen-pass]` Generic function body checking: no skolemization of bound tvars — lib/type/static-v5/constrain.lua:40
- [ ] **P5** `[gen-pass]` Type predicates (`x is T`) parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Match types parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Newtype declarations parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Augment declarations parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Pattern types parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **G6** `[substrate]` `μ.__index` chain walk missing: sealed-table missing-field lookup does not traverse `__index` chain — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G17** `[effect-propagation]` Variadic generics needed for accurate `pcall` and `coroutine.resume` arg-list/return-pack typing; current 5.F2 approximation correct for known-arity callees only — docs/typechecker-v5-handoff-2026-05-26.md §4

### Medium

- [ ] **G2** `[substrate]` Kind checking exists but kind inference does not — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G4** `[substrate]` No shift-aware abstraction over nested lambdas; capture-avoiding substitution fails for nested binders — lib/type/static-v5/op_sem_alt.lua; handoff §6
- [ ] **G5** `[substrate]` HOUnify residue provenance: delayed instantiation residues lose source context for error messages — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G9** `[solver-soundness]` Bounded tvars: T-CSub-TVar routes to CEq instead of respecting bounds — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G10** `[solver-soundness]` Variance under Lambda: registry covers named TConst only; anonymous lambdas default invariant — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **P6** `[gen-pass]` Closure-as-value / upvalue capture narrowing across scopes not modelled — lib/type/static-v5/constrain.lua:35
- [ ] **P6** `[gen-pass]` Complex narrowing (discriminated unions, type guards) not modelled in gen-pass — lib/type/static-v5/constrain.lua:36
- [ ] **P6** `[gen-pass]` Effect propagation from unknown (uvar) callees not resolved at gen time; requires solver-time resolution — lib/type/static-v5/constrain.lua:43
- [ ] **P6** `[gen-pass]` Type alias / require / module directives parsed but not scope-injected (`declare_var`, `declare_effect` stubs) — lib/type/static-v5/constrain.lua:41

### Low / polish

- [ ] **G1** `[substrate]` Miller pattern fragment restricted to UVar/Const args only; complex argument shapes not handled — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G3** `[substrate]` No eta-equivalence in Miller check — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G11** `[solver-soundness]` Union backtracking admits exact-branch only; no disjunction fallback — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **5.F3-residual** `[effect-propagation]` Resume-side `S` narrowing incomplete: `coroutine.resume(co, s)` does not bind `S` from the send argument — docs/typechecker-v5-log.md Phase 5.F; handoff §9
- [x] **5.F4-residual** `[substrate]` Compatible-bound intersection reduction not implemented: `integer & number` does not reduce to `integer` at quiescence — docs/typechecker-v5-log.md Phase 5.F; handoff §9 — closed 5108ceae (structurally_subtype + reduce_intersection at S-Quiesce meet site; T-CSub-Const-Var integer <: number lattice rule)

---

## Closed

- [x] **G14** `[solver-soundness]` T-CSub dispatch priority not formally enforced — closed bad931a6 (12-step priority order documented in docs/type-system.md §Operational Semantics Dispatch; cites step_csub op_sem.lua:771)
- [x] **G15** `[substrate]` T-CTSet four-way cascade order not formally enforced — closed bad931a6 (5-branch cascade documented in docs/type-system.md §Operational Semantics Dispatch; cites step_tset op_sem.lua:1053)
- [x] **G16** `[substrate]` T-CHKT-Reduce chain peel depth not formally specified — closed bad931a6 (exact `#args` peel depth + 3-way step_chkt dispatch documented in docs/type-system.md §Operational Semantics Dispatch; cites op_sem.lua:1510, 1575)
- [x] **bench-col** `[tooling]` Column threading in bench_chkt.lua and corpus_extract.lua — closed c411c827 (bench_chkt: fully synthetic constraints, no source position exists; corpus_extract: heuristic gmatch extractor with no byte-offset tracking, col=0 is correct in both cases)
- [x] **G8** `[soundness]` CRow narrowing soundness floor — closed 7f7d4d6c, b1825484 (S-Quiesce-CRowLacks prevents silent field-existence errors; CRowClose wakes parked CRowLacks; Scenario A quiescence error and Scenario B close-then-pass both verified)
- [x] **G9-P4** `[substrate]` Arrow subtyping CSub→CEq fallback (uvar bounds substrate) — closed 5.F4 93311447 (uvar upper bounds tracked; meet of uppers at quiescence; no more silent CEq fallback). Note: G9 T-CSub-TVar dispatch gap remains open above; P4 was the quiescence-path specific fix.
- [x] **G12** `[effect-propagation]` Effect-row variance / CEffect family — closed c600a446 (effects are TConst with "!" prefix; TIntersection composes; CIntersectionEq/Sub/Member with canonical form; S-Quiesce-CIntersectionMember enforces F2)
- [x] **G13** `[substrate]` Intersection types AST variant missing — closed 05519c88 (TIntersection added to types.lua + subst.lua)
- [x] **P1** `[gen-pass]` Dotted callee F2 propagation broken: field-expr callees not resolved at gen time — closed 5.F1 a32b0a74 (field-expr callees resolved at gen time; F2 fires on `io.write`)
- [x] **P2** `[gen-pass]` pcall return type flat `boolean | unknown` instead of discriminated union — closed 5.F2 05fd0777 (pcall returns `(true, R...) | (false, E)`; consumes `!throw`)
- [x] **P3** `[effect-propagation]` Coroutine parameterisation missing: `coroutine.create` returns unparameterised `thread` — closed 5.F3 656c8596 (`Coroutine<Y,S,R>` parameterisation; `coroutine.create` consumes `!yield`)
- [x] **P4** `[substrate]` Arrow subtyping CSub→CEq fallback: uvar defaults to CEq at quiescence with no bounds — closed 5.F4 93311447 (see G9-P4 above)
- [x] **Error message quality below v4 bar** `[error-ux]` v5 errors lacked `path:line:col: error: prose` + source snippet with caret + ANSI — closed Phase G: G1 71c56f56 (column threading through Provenance), G2 00d109e9 (structured details ADT + error_format.lua), G3 e000ca93 (21 snapshot fixtures; 10 additional rules converted; deterministic show() sort; unified effect_not_permitted prose)
