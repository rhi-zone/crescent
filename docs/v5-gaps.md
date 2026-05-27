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

- [x] **P6** `[gen-pass]` Binary and unary operators emit fresh uvar instead of arithmetic/logical constraints — lib/type/static-v5/constrain.lua:38 — closed 56af6204 (arithmetic/comparison/concat/logical/unary all constrain operands and return typed results; arithmetic approximated to number, integer refinement deferred)
- [x] **P6** `[gen-pass]` for-in and for-num loop variables bound to `unknown` — lib/type/static-v5/constrain.lua:39 — closed 2ed0dfe1 (for-num bounds emit CSub against number; loop var bound to number; for-in pairs/ipairs special-cased to extract K/V from index signature; unknown fallback for unresolved iterators; also fixed lookup() to check active scope)
- [x] **P6** `[gen-pass]` Arithmetic operators return number unconditionally; integer refinement deferred — lib/type/static-v5/constrain.lua (gen-pass #4 residual from 56af6204) — closed df04ee9f (integer-valued $LitNum promoted to $LitInt in LIT_NUMBER handler; +/-/* of two integer-typed operands returns integer; /^%// always number)
- [x] **P6** `[gen-pass]` Multi-return tuple types use union as approximation instead of proper tuple constraints — lib/type/static-v5/constrain.lua:42 — closed f1b30d91 (return stmts push V5Type[] lists; gen_function builds positional record via build_rets_arr; gen_expr_multi spreads call returns into LHS slots; T-CSub-Record-Width truncation fixed in op_sem.lua + op_sem_alt.lua; last-position expansion deferred, see return-last-spread below)
- [x] **P5** `[gen-pass]` Return-last-spread not implemented: `return f(), 2` where `f()` returns multiple values — f's extra returns beyond field "1" are discarded rather than expanded into the caller's positional list — lib/type/static-v5/constrain.lua NODE_RETURN_STMT (rl>1 path) — closed df04ee9f (spread_last_expr helper: last-position call with known arrow spreads all positional ret fields; unknown callee falls back to single-value)
- [ ] **P6** `[gen-pass]` Method dispatch edge cases beyond simple `obj:method(...)` not modelled — lib/type/static-v5/constrain.lua:37
- [ ] **P6** `[gen-pass]` Generic function body checking: no skolemization of bound tvars — lib/type/static-v5/constrain.lua:40
- [ ] **P5** `[gen-pass]` Type predicates (`x is T`) parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Match types parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Newtype declarations parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Augment declarations parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **P5** `[gen-pass]` Pattern types parsed but not wired in gen-pass — lib/type/static-v5/ann.lua + constrain.lua; handoff §3
- [ ] **R1** `[architecture]` op_sem_alt.lua no longer implements the current spec: T-CSub-TVar (line 353-358) is pre-5.F4 simple version with no bounds accumulation; op_sem.lua has post-5.F4 bounds substrate. Parity tests pass because they don't exercise multi-bound cases (op_sem_bounds_test.lua tests op_sem only). The dual-interpreter "formal grounding" claim degrades as op_sem accrues fixes op_sem_alt doesn't. — lib/type/static-v5/op_sem_alt.lua:353-358, audit 2026-05-27
- [ ] **R2** `[substrate]` T-CRowExtend-Bind mutates `rec.fields` in place; aliased records visible across constraints; monotone but not idempotent under park/wake; "record bound exactly once before any CRowExtend fires" invariant unstated and unverified — lib/type/static-v5/op_sem.lua:1187-1196, audit 2026-05-27
- [ ] **R3** `[solver-soundness]` T-CSub-Union-R is exact-branch-only by design (`integer <: (integer | boolean)` fails). Comment admits "v5.0 limitation". Will produce false negatives on real code — lib/type/static-v5/op_sem.lua:745-747, audit 2026-05-27
- [ ] **R4** `[gen-pass]` `resolve_callee_eager` has no depth bound or cycle detection; unbounded field-access chain walk; recursive records → infinite loop — lib/type/static-v5/constrain.lua:864-924, audit 2026-05-27
- [ ] **R5** `[gen-pass]` `resolve_aliases_impl` has no cycle detection or memoization; cyclic aliases (A=B, B=A) infinite-loop — lib/type/static-v5/constrain.lua:189-294, audit 2026-05-27
- [ ] **G6** `[substrate]` `μ.__index` chain walk missing: sealed-table missing-field lookup does not traverse `__index` chain — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G17** `[effect-propagation]` Variadic generics needed for accurate `pcall` and `coroutine.resume` arg-list/return-pack typing; current 5.F2 approximation correct for known-arity callees only — docs/typechecker-v5-handoff-2026-05-26.md §4

### Medium

- [ ] **G2** `[substrate]` Kind checking exists but kind inference does not — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G4** `[substrate]` No shift-aware abstraction over nested lambdas; capture-avoiding substitution fails for nested binders — lib/type/static-v5/op_sem_alt.lua; handoff §6
- [ ] **G5** `[substrate]` HOUnify residue provenance: delayed instantiation residues lose source context for error messages — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G9** `[solver-soundness]` Bounded tvars: T-CSub-TVar routes to CEq instead of respecting bounds — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G10** `[solver-soundness]` Variance under Lambda: registry covers named TConst only; anonymous lambdas default invariant — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **record-width-invariance** `[solver-soundness]` T-CSub-Record-Width treats named fields as invariant (decomposes via CEq), blocking literal widening (`$LitInt(1) <: integer`) and other covariant cases through record subtyping. Module-export (commit 8a9bfc1e) works around this with per-field CSub; underlying limitation persists for every other record-subtyping path — lib/type/static-v5/op_sem.lua T-CSub-Record-Width rule
- [ ] **R6** `[architecture]` cli.lua M.main reaches `io.open`, `io.stdout`, `io.stderr`, `os.getenv` directly despite module header claiming "All I/O via injected caps" — lib/type/static-v5/cli.lua:254-280, audit 2026-05-27
- [ ] **R7** `[architecture]` ann.lua `_next_rowvar` is module-level mutable, never resets; two parses in the same process produce row-var ID collisions silently — lib/type/static-v5/ann.lua:225-232, audit 2026-05-27
- [ ] **R8** `[architecture]` ann.lua `effect_arities` is module-level shared state; "idempotent" comment ≠ isolation across parsers — lib/type/static-v5/ann.lua:57-64, audit 2026-05-27
- [ ] **P6** `[gen-pass]` Closure-as-value / upvalue capture narrowing across scopes not modelled — lib/type/static-v5/constrain.lua:35
- [ ] **P6** `[gen-pass]` Complex narrowing (discriminated unions, type guards) not modelled in gen-pass — lib/type/static-v5/constrain.lua:36
- [ ] **P6** `[gen-pass]` Effect propagation from unknown (uvar) callees not resolved at gen time; requires solver-time resolution — lib/type/static-v5/constrain.lua:43
- [x] **P6** `[gen-pass]` Type alias / require / module directives parsed but not scope-injected (`declare_var`, `declare_effect` stubs) — lib/type/static-v5/constrain.lua:41 — closed 385b24b4 (declare_var/declare_effect already wired; type_alias fully wired with eager body expansion + param substitution; module records ctx.module_name; require/template no-op by v4 parity)
- [ ] **P4** `[gen-pass]` `--:: require "mod"` directive is no-op in v5: v4's `load_decl_file` module-loader infrastructure not ported; cross-file type declarations unavailable without explicit opts.decls injection — lib/type/static-v5/constrain.lua directive-processing loop (require branch)
- [ ] **P3** `[gen-pass]` `--:: template` directive is no-op in v5: generic function body checking (skolemization) deferred; template markers not used — lib/type/static-v5/constrain.lua directive-processing loop (template branch); see also "Generic function body checking" item above
- [x] **P4** `[gen-pass]` `--:: module "name": T` directive only records ctx.module_name; top-level bindings are not exported as the module's type — lib/type/static-v5/constrain.lua directive-processing loop (module branch) — closed (export side) 8a9bfc1e (per-field CSub emitted post-walk; missing fields surfaced as gen errors)
- [ ] **P3** `[gen-pass]` `$Require<"name">` not implemented in v5 (export side now works; cross-file require-based resolution remains open): $Require does not exist in v5 types/ann; no resolution path when opts.modules["name"] is set — lib/type/static-v5/constrain.lua + ann.lua

### Low / polish

- [ ] **Y1** `[gen-pass]` Accumulating syntactic special-cases for pcall, coroutine.create, coroutine.resume, coroutine.yield in gen-pass — each inline `if name == "..."` branch, no registry — lib/type/static-v5/constrain.lua:1201-1338, audit 2026-05-27
- [ ] **Y2** `[gen-pass]` `extract_yield_from_scope` returns `(unknown, fresh_uvar, unknown)` if scope stack is empty; top-level `coroutine.yield` silently typechecks against unknown — lib/type/static-v5/constrain.lua:627-668, audit 2026-05-27
- [ ] **Y3** `[gen-pass]` `spread_last_expr` may treat arrow-with-uvar-return as single-value, diverging from gen_expr_multi's expectation — lib/type/static-v5/constrain.lua:1835-1909, audit 2026-05-27
- [ ] **Y4** `[gen-pass]` Module export uses per-field CSub to dodge T-CSub-Record-Width's CEq invariance; substrate workaround in gen-pass — lib/type/static-v5/constrain.lua:2543-2580, audit 2026-05-27 (cross-ref: Y6, existing record-width-invariance item)
- [ ] **Y5** `[substrate]` `structurally_subtype` makes pure structural decisions; silently misses cases the solver could refine — lib/type/static-v5/op_sem.lua:1670-1743, audit 2026-05-27
- [ ] **Y6** `[solver-soundness]` T-CSub-Record-Width uses CEq for named fields based on "Invariant: fields are mutable in v5.0" comment the rule doesn't enforce or check — lib/type/static-v5/op_sem.lua:706+, audit 2026-05-27 (cross-ref: existing record-width-invariance item; this is the same root cause from the rule side)
- [ ] **Y7** `[cli]` `expand_dotted` has no edge-case guards; `"."`, `".foo"` could collide silently — lib/type/static-v5/cli.lua:56-82, audit 2026-05-27
- [ ] **Y8** `[error-ux]` `render_prose` silent fallback for unknown ErrorDetails variants; new variants ship to users with generic prose, no compile warning — lib/type/static-v5/error_format.lua:170, audit 2026-05-27
- [ ] **Y9** `[error-ux]` v4 error formatter coupling is interface-opaque; if v4's ErrCtx shape changes, v5 produces malformed structures with no compile-time safety — lib/type/static-v5/error_format.lua:12+180-200, audit 2026-05-27
- [ ] **Y10** `[surface]` ann.lua parse_declaration missing `augment` and `unseal` directives that v4 has; silently misparses as type alias — lib/type/static-v5/ann.lua:691-792, audit 2026-05-27
- [ ] **Y11** `[surface]` `scan_number_lit` returns 0 on `tonumber` failure; defensive degradation hides scanner bugs — lib/type/static-v5/ann.lua:197-211, audit 2026-05-27
- [ ] **Y12** `[cultural]` "v4 parity" justification used for `require` + `template` no-ops; normalizes silent ignoring of directives — lib/type/static-v5/constrain.lua:2493-2507, audit 2026-05-27
- [ ] **G1** `[substrate]` Miller pattern fragment restricted to UVar/Const args only; complex argument shapes not handled — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G3** `[substrate]` No eta-equivalence in Miller check — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **G11** `[solver-soundness]` Union backtracking admits exact-branch only; no disjunction fallback — docs/typechecker-v5-handoff-2026-05-26.md §6
- [ ] **parser-int-float** `[surface]` v4 parser collapses integer and float literals (`1` vs `1.0`) into the same LIT_NUMBER node; v5 gen-pass promotes integer-valued floats to $LitInt, so `1 + 2.0` types as integer (incorrect — 2.0 is a float). Tracked in test file comments in commit df04ee9f — lib/type/static/parse.lua LIT_NUMBER handling
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
