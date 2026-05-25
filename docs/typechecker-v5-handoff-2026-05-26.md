# Typechecker v5 — Session-Close Handoff (2026-05-26)

Single navigation document for the next session. The log (`docs/typechecker-v5-log.md`) is the chronological source of truth; this handoff is the snapshot.

If you read only one file, read this. For the prior session's full context, see `docs/typechecker-v5-handoff-2026-05-25.md` first, then this diff on top.

---

## What changed this cycle (2026-05-26) — two arcs

### Arc 1: CRow + CIntersection-effects (closes G8, G12 at op-sem layer)

Four commits landed. Parity: 187 → 275 (+88 assertions).

| Phase | Commit | Description | Parity |
|---|---|---|---|
| Substrate | `05519c88` | TRowVar, TRecord.row, TIntersection in types.lua + subst.lua | — |
| CRow rules | `7f7d4d6c` | CRowExtend/Lacks/Close atoms + rules in both interpreters + fixtures 19-22 | 187 → 219 |
| Fixture 8 reinstated | `b1825484` | CRow narrowing suppression (Scenario A: quiescence error; Scenario B: close-then-pass) | 219 → 233 |
| Intersection + effects | `c600a446` | CIntersectionEq/Sub/Member + canonicalize + effect-type API + fixtures 23-29 | 233 → 275 |

### Arc 2: Phase 5 source pipeline (v5-source-pipeline-integration CLOSED)

Four commits landed. Total assertions: 275 → 504 (+229). Op-sem parity 275/275 preserved.

| Phase | Commit | Description | Assertions |
|---|---|---|---|
| 5.A ann.lua | `52fcae6f` | Annotation parser ported to v5 substrate; effect-type syntax; ann_test.lua 156 assertions | 275 → 431 |
| 5.B constrain.lua | `0ff434aa` | Gen-pass walker: AST → v5 constraints; constrain_test.lua 27 assertions | 431 → 458 |
| 5.C effect propagation | `6da6db59` | Effect propagation through call chains; pcall/coroutine stubs; +28 assertions | 458 → 486 |
| 5.D CLI + e2e | `317acc9b` | `bin/cr check --v5` end-to-end; solver fixes; demo fixture; cli_e2e_test.lua 18 assertions | 486 → 504 |

`bin/cr check --v5 lib/type/static-v5/fixtures/demo_effects.lua` exits 0 (hand-verified).

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

**Total: 504 assertions, 5 test files, all pass. Op-sem parity 275/275. Zero divergence.**

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

## 3. Six open gaps within the Phase 5 source pipeline

These are open gaps in the code that landed. They are NOT closed. They represent
material work remaining before the pipeline can be relied upon for real code.

**Gap P1 — Effect propagation from field-access callees is broken.**
`io.write(...)` has a uvar callee at gen-pass time, so `!io` is never extracted
into the propagation chain. Only direct-bound names (`print`, `error`) propagate
effects. F2 enforcement does NOT actually fire for dotted stdlib calls (e.g.,
`io.write`, `os.execute`), even though the e2e test suite passes (the e2e tests
exercise only direct-bound callees). This is the highest-priority source pipeline fix.

**Gap P2 — pcall return type is flat `boolean | unknown`.**
The correct type is a discriminated tuple-union `(true, R...) | (false, E)`.
Current stdlib_types.lua returns `boolean | unknown`, losing the success/failure
type distinction. Fixing this requires variadic generics (G17). Not unsound (flat
is conservative), but loses precision that makes pcall narrowing useful.

**Gap P3 — `coroutine.create` returns `thread`, not `Coroutine<Y,S,R>`.**
Full parameterisation (yield type, send type, return type) is deferred. Current
stub returns the unparameterised `thread` constant. Requires G17 or a specialised
constraint family to parameterise.

**Gap P4 — Arrow subtyping converts `sub(uvar, concrete)` to CEq at S-Quiesce.**
Proper upper/lower bounds tracking (spec gap G9, "bounded tvars") is deferred.
At S-Quiesce, a still-unbound uvar under an Arrow CSub defaults via CEq, which is
overly restrictive and may reject valid programs.

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

**Next steps for each gap:**
- P1: Fix dotted-callee effect extraction in constrain.lua before committing to
  any gen-pass extension; it affects all real stdlib usage.
- P2 + P3: Design G17 (variadic generics) first; then rewrite pcall/coroutine stubs.
- P4: Design bounded-tvar substrate (G9) first; then revise S-Quiesce default-binding.
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
**Source pipeline** (this cycle): parse.lua → ann.lua → constrain.lua → op_sem.lua;
`bin/cr check --v5` wired end-to-end. Six open gaps in pipeline coverage (P1–P6 above).

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
| P1 | Dotted callee effect propagation broken in gen-pass | High | **New 2026-05-26** |
| P2 | pcall return type flat `boolean | unknown` (not discriminated) | Med | **New 2026-05-26** |
| P3 | coroutine.create returns unparameterised `thread` | Low | **New 2026-05-26** |
| P4 | Arrow subtyping defaults uvar to CEq at S-Quiesce (no bounds) | Med | **New 2026-05-26** |
| P5 | Ann surface forms not wired to gen-pass (type predicates, match, etc.) | Med | **New 2026-05-26** |
| P6 | Closure-as-value and method dispatch not modelled in constrain.lua | Med | **New 2026-05-26** |

---

## 7. What's verified

All verifications from the 2026-05-25 handoff hold plus:

- **CRow fixtures 19-22**: both interpreters pass all assertions (219 total).
- **Fixture 8 (G8 soundness floor)**: Scenario A (quiescence error) and Scenario B
  (close-then-pass) verified in both interpreters (233 total).
- **CIntersection fixtures 23-29**: both interpreters pass all assertions (275 total).
- **CRow + CIntersection perf re-gate**: PASS (step counts 768/343, margins >200× wall, >10× heap).
- **ann_test** (156 assertions): annotation parser handles all v5 type forms including
  effect syntax and intersection. All pass.
- **constrain_test** (55 assertions): gen-pass emits correct constraints for basic patterns.
  All pass. Note: only exercises direct-bound callee patterns; Gap P1 not exercised.
- **cli_e2e_test** (18 assertions): `bin/cr check --v5` exits correctly on fixtures
  covering multi-effect propagation. All pass.
- **demo_effects.lua**: `bin/cr check --v5` exits 0. Hand-verified.

---

## 8. Next-session menu

### Option A: Fix Gap P1 (dotted callee effect propagation)
**Prereqs**: none. Single file change in constrain.lua.
**Cycles**: <1. Highest leverage: enables F2 enforcement for the real `io.*`/`os.*`
call patterns that dominate real source code.

### Option B: G17 design (variadic generics)
**Prereqs**: orchestrator design decision before implementation.
**Cycles**: 1-2 for design; implementation separate.
**Unblocks**: Gap P2 (pcall discriminated return) and Gap P3 (coroutine typing).

### Option C: Pre-stable follow-ups
Same as 2026-05-25 handoff Option D. Unchanged prereqs and cycle estimates.
Mining, missed-gen eval, circular require corpus check, property-based parity.

### Option D: CImpl (let-poly with implication wanteds)
**Prereqs**: op-sem foundation hardened (now is the time).
**Cycles**: 1-2.

### Recommended order (orchestrator suggestion)

1. **A** (Gap P1 fix) — one cycle, highest leverage for real-code coverage
2. **B** (G17 design) — don't implement without a design; can overlap with A
3. **C** (pre-stable follow-ups) — discharge debts
4. **D** (CImpl) — fills op-sem hole before gen-pass connection completes

---

## 9. Cross-cutting risks (updated)

1. **Realistic-scale perf** is still a hypothesis. Tested at <1000 constraints; target 10⁵.
2. **Gap P1** is the most visible current hole: effect enforcement doesn't fire for dotted stdlib calls.
3. **Gen-pass coverage** is incomplete (P5 + P6). The pipeline handles basic patterns only.
4. **Substrate promotion** from `experiments/` to `static-v5/` is still owed.
5. **Cutover from legacy + v4** is the long tail (all 2809 tests green under v5 alone).
