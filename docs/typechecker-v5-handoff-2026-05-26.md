# Typechecker v5 — Session-Close Handoff (2026-05-26)

Single navigation document for the next session. The log (`docs/typechecker-v5-log.md`) is the chronological source of truth; this handoff is the snapshot.

If you read only one file, read this. For the prior session's full context, see `docs/typechecker-v5-handoff-2026-05-25.md` first, then this diff on top.

---

## What changed this cycle (2026-05-26) — three arcs (updated: 5.F closure)

### Arc 1: CRow + CIntersection-effects (closes G8, G12 at op-sem layer)

Four commits landed. Parity: 187 → 275 (+88 assertions).

| Phase | Commit | Description | Parity |
|---|---|---|---|
| Substrate | `05519c88` | TRowVar, TRecord.row, TIntersection in types.lua + subst.lua | — |
| CRow rules | `7f7d4d6c` | CRowExtend/Lacks/Close atoms + rules in both interpreters + fixtures 19-22 | 187 → 219 |
| Fixture 8 reinstated | `b1825484` | CRow narrowing suppression (Scenario A: quiescence error; Scenario B: close-then-pass) | 219 → 233 |
| Intersection + effects | `c600a446` | CIntersectionEq/Sub/Member + canonicalize + effect-type API + fixtures 23-29 | 233 → 275 |

### Arc 2: Phase 5 source pipeline (v5-source-pipeline-integration initially CLOSED, gaps #1–#4 still open at 5.E)

Four commits landed. Total assertions: 275 → 504 (+229). Op-sem parity 275/275 preserved.

| Phase | Commit | Description | Assertions |
|---|---|---|---|
| 5.A ann.lua | `52fcae6f` | Annotation parser ported to v5 substrate; effect-type syntax; ann_test.lua 156 assertions | 275 → 431 |
| 5.B constrain.lua | `0ff434aa` | Gen-pass walker: AST → v5 constraints; constrain_test.lua 27 assertions | 431 → 458 |
| 5.C effect propagation | `6da6db59` | Effect propagation through call chains; pcall/coroutine stubs; +28 assertions | 458 → 486 |
| 5.D CLI + e2e | `317acc9b` | `bin/cr check --v5` end-to-end; solver fixes; demo fixture; cli_e2e_test.lua 18 assertions | 486 → 504 |

`bin/cr check --v5 lib/type/static-v5/fixtures/demo_effects.lua` exits 0 (hand-verified by 5.D; after 5.F exits 1 — section 7 deliberate F2 violation now correctly fires).

### Arc 3: Phase 5.F — four gap closures (source pipeline genuinely enforces)

Four commits landed. Total assertions: 504 → 541 (+37). Op-sem parity 275/275 preserved throughout.

| Phase | Commit | Description | Assertions |
|---|---|---|---|
| 5.F1 dotted callee | `a32b0a74` | Resolve field-expr callees at gen time; F2 fires on `io.write` | 504 → 516 |
| 5.F2 pcall | `05fd0777` | pcall returns `(true, R...) \| (false, E)` discriminated union; consumes `!throw` | 516 → 526 |
| 5.F3 coroutine | `656c8596` | `Coroutine<Y,S,R>` parameterisation; `coroutine.create` consumes `!yield` | 526 → 534 |
| 5.F4 uvar bounds | `93311447` | Uvar bounds substrate; meet of uppers at quiescence (no more silent CEq fallback) | 534 → 541 |

Note: the 5.E entry in `docs/typechecker-v5-log.md` claimed "v5 source pipeline landed" — that framing was overstated. Gaps #1–#4 were open and made F2 enforcement cosmetic for the common dotted-callee case, pcall imprecise, coroutines unparameterised, and uvar bounds unsound. 5.F is the honest closure.

#### 5.F closure — per-gap fixture citations

- **Gap P1** (closed `a32b0a74`): dotted callee resolution at gen time. F2 now fires on `io.write`. Demonstrated by fixture `"5.F1: annotated () -> nil calling io.write (dotted) surfaces F2 error"` in `cli_e2e_test.lua` and `"5.F1: annotated () -> nil calling io.write via dotted callee emits cint_member"` in `constrain_test.lua`.
- **Gap P2** (closed `05fd0777`): pcall special-cased at gen time; returns discriminated `(true, R...) | (false, E)`; `!throw` consumed. Demonstrated by fixture `"5.F2: pcall on throwing fn in annotated pure fn is clean"` in `cli_e2e_test.lua` and `"5.F2: pcall call site emits no constraints (fully special-cased)"` in `constrain_test.lua`.
- **Gap P3** (closed `656c8596`): `coroutine.create` special-cased; `!yield` consumed; outer pure annotation satisfied. Demonstrated by fixture `"5.F3: coroutine.create consumes !yield — pure outer fn is clean"` in `cli_e2e_test.lua` and `"5.F3: coroutine.create call site emits no constraints (special-cased)"` in `constrain_test.lua`.
- **Gap P4** (closed `93311447`): uvar bounds substrate; meet of upper bounds at quiescence. Demonstrated by fixture `"5.F4: two distinct upper bounds — meet via intersection"` in `op_sem_bounds_test.lua`.

Two residual sub-gaps tracked in TODO.md:
- Resume-side `S` narrowing incomplete (5.F3): `coroutine.resume(co, s)` does not bind `S` from the send argument.
- Compatible-bound intersection reduction not implemented (5.F4): `integer & number` does not reduce to `integer` at quiescence. Orthogonal substrate gap.

---

## 1. Where v5 stands today

| Artifact | Path | Status |
|---|---|---|
| Constraints catalog | `docs/typechecker-v5-constraints.md` | Current |
| Decision log (append-only) | `docs/typechecker-v5-log.md` | Current |
| Inference rules | `docs/typechecker-v5-operational-semantics.md` | Current (CRow + CIntersection sections added) |
| Prior handoff | `docs/typechecker-v5-handoff-2026-05-25.md` | Snapshot of prior state |
| Executable spec | `lib/type/static-v5/op_sem.lua` | Active — CRow + CIntersection + solver fixes |
| Alternate interpreter | `lib/type/static-v5/op_sem_alt.lua` | Parity reference |
| Annotation parser | `lib/type/static-v5/ann.lua` | Active — v5 annotation + effect syntax |
| Gen-pass walker | `lib/type/static-v5/constrain.lua` | Active — AST → constraint emission |
| CLI entry point | `lib/type/static-v5/cli.lua` | Active — `bin/cr check --v5` |
| Stdlib types | `lib/type/static-v5/stdlib_types.lua` | Active — pcall/coroutine stubs |
| Demo fixture | `lib/type/static-v5/fixtures/demo_effects.lua` | Passes under `--v5` |
| Parity test (EXEC vs DOCS) | `lib/type/static-v5/op_sem_parity_test.lua` | 108 assertions, all pass |
| Parity test (independent encoding) | `lib/type/static-v5/op_sem_independent_parity_test.lua` | 167 assertions, all pass |
| ann_test | `lib/type/static-v5/ann_test.lua` | 156 assertions, all pass |
| constrain_test | `lib/type/static-v5/constrain_test.lua` | 55 assertions, all pass |
| cli_e2e_test | `lib/type/static-v5/cli_e2e_test.lua` | 18 assertions, all pass |
| Perf log | `docs/perf/log.md` | Updated 2026-05-26 (both arcs) |

**Total: 541 assertions, 6 test files, all pass. Op-sem parity 275/275. Zero divergence.**

(Post-5.F: +37 assertions from 5.F1–5.F4. New test file: `op_sem_bounds_test.lua` (11 assertions).

---

## 2. Gaps closed this cycle

### Spec gap G8 — CRow narrowing-suppression soundness floor: **CLOSED at op-sem layer**

CRowLacks parks while the row variable is unbound (open row). At quiescence, any
still-parked CRowLacks is an error (S-Quiesce-CRowLacks). CRowClose wakes parked
CRowLacks constraints; those finding the key absent succeed (Closed-Pass); those
finding the key present error (Closed-Fail). Fixture 8 verifies both scenarios.

Observable from user code only via direct API use in tests; the gen-pass does not
yet emit CRow constraints from source syntax. G8 is closed at the op-sem/spec layer.

### Spec gap G12 — Effect variance discipline: **CLOSED at op-sem layer**

Effects are types: `TConst` nodes with a `"!"` prefix (`!io`, `!throw`, `!yield`,
`!os`). No parallel CEffect infrastructure needed. Intersection composes effect sets
(`TIntersection`). CSub variance rules decompose intersection constraints uniformly
via CIntersectionEq / CIntersectionSub / CIntersectionMember. F2 enforcement:
CIntersectionMember stuck on an unbound uvar at quiescence errors.

Observable from user code via direct-bound callees only (see Gap P1 below).

### v5-source-pipeline-integration: **CLOSED** (with six open gaps)

`bin/cr check --v5 <file>` is runnable end-to-end. The pipeline is connected:
parse.lua → ann.lua → constrain.lua → op_sem.lua. See §3 for the six open gaps
that remain within the landed pipeline — they are open work, not landed work.

---

## 3. Open gaps within the Phase 5 source pipeline (post-5.F)

Gaps P1–P4 are **CLOSED** as of Phase 5.F (2026-05-26). See Arc 3 above for commit SHAs and fixture citations. Two open gaps remain:

**Gap P5 — Ann surface: surface syntax features not wired to gen-pass.**
ann.lua parses `&` intersection and `!Name<Args>` effect syntax in type positions.
gen-pass (constrain.lua) does not yet request or emit constraints for: type
predicates (`x is T`), match types, newtype declarations, augment declarations,
pattern types. These forms are parsed but silently ignored at gen-pass time.

**Gap P6 — Constrain surface: closure-as-value intricacies not handled.**
Complex narrowing (closures as values, method dispatch via `:`, upvalue capture
across scopes) is not modelled in constrain.lua. The walker handles straight-line
code and basic function bodies. It does not handle closures stored in tables,
`self`-style `:` method dispatch, or upvalue capture narrowing.

**Next steps:**
- P5: Extend constrain.lua to emit constraints for each skipped surface form, one at a time.
- P6: Add method-call dispatch and closure-as-value handling to the gen-pass walker.

---

## 4. Spec gap G17 (new this cycle)

Accurate typing of `pcall` and `coroutine.resume` requires variadic generics —
the function-argument pack and return-pack must be typed through the boundary.
Current v5.0: `pcall` returns `(boolean, unknown)` per corpus convention.
Full variadic generics needs a constraint-family design. **Severity: low-medium.
Not blocking v5.0 stable.**

---

## 5. Architecture (updated paragraph)

Reified constraint ADT with provenance + Wanted/Given flavour. Monotone union-find
substitution `TVarId → (Type, Phase)` is the single source of truth — no side-channels.
Worklist + inert set; pop, try progress under current substitution, extend or add to inert.
Circular `require` rejected at typecheck. Type AST splits free unification tvars (`UVar`)
from De Bruijn bound vars (`Var`). Eager shift on bind. Construction phase is constraint
variants (`CTableOpen/Set/Seal/CMethodCall`). HKT via direct type lambdas + Miller
pattern fragment + `HOUnify` residue. Record fields invariant; positional return-Record
keys covariant (multi-return dissolution). Row polymorphism: `TRowVar(id)` row
metavariables, `TRecord.row` field; `CRowExtend/Lacks/Close` constraint atoms;
`S-Quiesce-CRowLacks` soundness floor. **Effects are types**: `TConst("!name")` prefix;
`TIntersection` composes; `CIntersectionEq/Sub/Member` with canonical form (flatten+sort+dedupe);
`S-Quiesce-CIntersectionMember` F2 enforcement. No dedicated CEffect family.
**Source pipeline**: parse.lua → ann.lua → constrain.lua → op_sem.lua;
`bin/cr check --v5` wired end-to-end. Gaps P1–P4 closed by Phase 5.F; two open gaps remain (P5: ann surface forms, P6: closure/method dispatch). F2 enforcement fires correctly for dotted callees (`io.write`) and direct-bound callees. pcall returns discriminated `(true, R...) | (false, E)` and consumes `!throw`. `coroutine.create` consumes `!yield`. Uvar bounds tracked; meet of uppers at quiescence.

---

## 6. Full spec gap table (updated)

| # | Gap | Severity | Status |
|---|---|---|---|
| G1 | Restricted Miller fragment (only UVar/Const args) | Low | Open |
| G2 | No kind inference | Med | Open |
| G3 | No eta-equivalence in Miller check | Low | Open |
| G4 | No shift-aware abstraction over nested lambdas | Med | Open |
| G5 | HOUnify residue provenance chaining | Med | Open |
| G6 | μ.__index chain walk for missing field on sealed table | Med | Open |
| G7 | ~~CMultiReturn~~ **DISSOLVED 2026-05-25** — positional Record on Arrow.ret | Closed | |
| G8 | CRow narrowing suppression soundness floor | High | **CLOSED at op-sem layer 2026-05-26** |
| G9 | Bounded tvars — T-CSub-TVar routes to CEq | Med | Open |
| G10 | Variance under Lambda — registry covers named Const only | Med | Open |
| G11 | Union backtracking — T-CSub-Union-R admits exact-branch only | Low | Open |
| G12 | Effect-row variance / CEffect family | High | **CLOSED at op-sem layer 2026-05-26** |
| G13 | Intersection types — ~~no AST variant~~ now TIntersection | Low | **CLOSED 2026-05-26** |
| G14 | T-CSub dispatch priority not formally enforced | Low | Open |
| G15 | T-CTSet four-way cascade order not formally enforced | Low | Open |
| G16 | T-CHKT-Reduce chain peel depth not formally specified | Low | Open |
| G17 | Variadic generics (pcall/coroutine.resume accurate typing) | Med | **New 2026-05-26** |
| P1 | Dotted callee effect propagation broken in gen-pass | High | **CLOSED 5.F1 a32b0a74** |
| P2 | pcall return type flat `boolean \| unknown` (not discriminated) | Med | **CLOSED 5.F2 05fd0777** |
| P3 | coroutine.create returns unparameterised `thread` | Low | **CLOSED 5.F3 656c8596** |
| P4 | Arrow subtyping defaults uvar to CEq at S-Quiesce (no bounds) | Med | **CLOSED 5.F4 93311447** |
| P5 | Ann surface forms not wired to gen-pass (type predicates, match, etc.) | Med | Open |
| P6 | Closure-as-value and method dispatch not modelled in constrain.lua | Med | Open |

---

## 7. What's verified

All verifications from the 2026-05-25 handoff hold plus:

- **CRow fixtures 19-22**: both interpreters pass all assertions (219 total).
- **Fixture 8 (G8 soundness floor)**: Scenario A (quiescence error) and Scenario B
  (close-then-pass) verified in both interpreters (233 total).
- **CIntersection fixtures 23-29**: both interpreters pass all assertions (275 total).
- **CRow + CIntersection perf re-gate**: PASS (step counts 768/343, margins >200× wall, >10× heap).
- **ann_test** (156 assertions): all pass.
- **constrain_test** (69 assertions): all pass. Includes 5.F1 and 5.F2/5.F3 gen-pass fixtures.
- **cli_e2e_test** (30 assertions): all pass. Includes 5.F1/5.F2/5.F3 e2e fixtures.
- **op_sem_bounds_test** (11 assertions): all pass. Exercises 5.F4 bounds substrate.
- **demo_effects.lua**: `bin/cr check --v5` exits 1 (section 7 deliberate F2 violation correctly fires). Hand-verified post-5.F.

---

## 8. Next-session menu

### Option A: Fix Gap P5 (ann surface forms wired to gen-pass)
**Prereqs**: none.
**Cycles**: 1-2. High leverage: enables type predicate narrowing, newtype safety.

### Option B: Fix Gap P6 (closure-as-value + method dispatch in constrain.lua)
**Prereqs**: none.
**Cycles**: 1-2. Needed for real-code coverage of method-dispatch-heavy modules.

### Option C: Pre-stable follow-ups
Mining, missed-gen eval, circular require corpus check, property-based parity.

### Option D: CImpl (let-poly with implication wanteds)
**Prereqs**: op-sem foundation hardened (now is the time).
**Cycles**: 1-2.

### Recommended order (orchestrator suggestion)

1. **A** (Gap P5) — small wins; each surface form is independent
2. **B** (Gap P6) — needed before any real-code corpus validation
3. **C** (pre-stable follow-ups) — discharge debts
4. **D** (CImpl) — fills op-sem hole before gen-pass connection completes

---

## 9. Cross-cutting risks (updated post-5.F)

1. **Realistic-scale perf** is still a hypothesis. Tested at <1000 constraints; target 10⁵.
2. **Gen-pass coverage** is incomplete (P5 + P6). The pipeline handles basic patterns only.
3. **Substrate promotion** from `experiments/` to `static-v5/` is still owed.
4. **Cutover from legacy + v4** is the long tail (all 2809 tests green under v5 alone).
5. **5.F3 resume-side S narrowing**: `coroutine.resume(co, s)` does not bind `S`; tracked in TODO.md.
6. **5.F4 compatible-bound reduction**: `integer & number` does not reduce; tracked in TODO.md.
