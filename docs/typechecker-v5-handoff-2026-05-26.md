# Typechecker v5 — Session-Close Handoff (2026-05-26)

Single navigation document for the next session. The log (`docs/typechecker-v5-log.md`) is the chronological source of truth; this handoff is the snapshot.

If you read only one file, read this. For the prior session's full context, see `docs/typechecker-v5-handoff-2026-05-25.md` first, then this diff on top.

---

## What changed this cycle (2026-05-26)

Four commits landed. Parity: 187 → 275 (+88 assertions).

| Phase | Commit | Description | Parity |
|---|---|---|---|
| Substrate | `05519c88` | TRowVar, TRecord.row, TIntersection in types.lua + subst.lua | — |
| CRow rules | `7f7d4d6c` | CRowExtend/Lacks/Close atoms + rules in both interpreters + fixtures 19-22 | 187 → 219 |
| Fixture 8 reinstated | `b1825484` | CRow narrowing suppression (Scenario A: quiescence error; Scenario B: close-then-pass) | 219 → 233 |
| Intersection + effects | `c600a446` | CIntersectionEq/Sub/Member + canonicalize + effect-type API + fixtures 23-29 | 233 → 275 |

---

## 1. Where v5 stands today

| Artifact | Path | Status |
|---|---|---|
| Constraints catalog | `docs/typechecker-v5-constraints.md` | Current |
| Decision log (append-only) | `docs/typechecker-v5-log.md` | Current |
| Inference rules | `docs/typechecker-v5-operational-semantics.md` | Current (CRow + CIntersection sections added) |
| Prior handoff | `docs/typechecker-v5-handoff-2026-05-25.md` | Snapshot of prior state |
| Executable spec | `lib/type/static-v5/op_sem.lua` | Active — CRow + CIntersection rules added |
| Alternate interpreter | `lib/type/static-v5/op_sem_alt.lua` | Parity reference |
| Parity test (EXEC vs DOCS) | `lib/type/static-v5/op_sem_parity_test.lua` | 108 assertions, all pass |
| Parity test (independent encoding) | `lib/type/static-v5/op_sem_independent_parity_test.lua` | 167 assertions, all pass |
| Perf log | `docs/perf/log.md` | Updated 2026-05-26 |

**Combined parity: 275/275 assertions across fixtures 1-29. Zero divergence between two independently-implemented interpreters.**

---

## 2. Gaps closed this cycle

### Spec gap G8 — CRow narrowing-suppression soundness floor: **CLOSED at op-sem layer**

CRowLacks parks while the row variable is unbound (open row). At quiescence, any
still-parked CRowLacks is an error (S-Quiesce-CRowLacks). CRowClose wakes parked
CRowLacks constraints; those finding the key absent succeed (Closed-Pass); those
finding the key present error (Closed-Fail). Fixture 8 verifies both scenarios.

**NOT yet observable from user code.** Source-pipeline integration (parser + gen-pass)
not implemented. This gap is closed at the op-sem/spec layer only.

### Spec gap G12 — Effect variance discipline: **CLOSED at op-sem layer**

Effects are types: `TConst` nodes with a `"!"` prefix (`!io`, `!throw`, `!yield`,
`!os`). No parallel CEffect infrastructure needed. Intersection composes effect sets
(`TIntersection`). CSub variance rules decompose intersection constraints uniformly
via CIntersectionEq / CIntersectionSub / CIntersectionMember. F2 enforcement:
CIntersectionMember stuck on an unbound uvar at quiescence errors.

**NOT yet observable from user code.** Same source-pipeline deferral as G8.

---

## 3. New gaps this cycle

### Spec gap G17 — Variadic generics

Accurate typing of `pcall` and `coroutine.resume` requires variadic generics —
the function-argument pack and return-pack must be typed through the pcall/resume
boundary. Current v5.0: `pcall` returns `(boolean, unknown)` per corpus convention.
Full variadic generics needs a constraint-family design. **Severity: low-medium.
Not blocking v5.0 stable.**

### v5-source-pipeline-integration gap

Parser + gen-pass wiring for `&` (intersection syntax) and `!Name<Args>` (effect
syntax) must land before G8 and G12 are observable from user-written code. This is
a 2-3 cycle effort (same estimate as the 2026-05-25 handoff §8 risk 3 "gen-pass
connection"). The op-sem constraints are correct; the pipeline is not connected.

---

## 4. Architecture (updated paragraph)

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

---

## 5. Full spec gap table (updated)

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
| v5-source-pipeline | Parser + gen-pass for effects/intersections | High | **New 2026-05-26** |

**G8, G12, G13: closed at op-sem layer.** Not yet observable from user code until
source-pipeline-integration lands.

---

## 6. What's verified

All verifications from the 2026-05-25 handoff hold plus:

- **CRow fixtures 19-22**: both interpreters pass all assertions (219 total).
- **Fixture 8 (G8 soundness floor)**: Scenario A (quiescence error) and Scenario B
  (close-then-pass) verified in both interpreters (233 total).
- **CIntersection fixtures 23-29**: both interpreters pass all assertions (275 total).
- **Perf re-gate**: PASS. Step counts grew from 634/295 to 768/343 (~21%); wall
  and heap within gate by >200× and >10× margins respectively. See `docs/perf/log.md`.

---

## 7. Next-session menu

### Option A: v5-source-pipeline-integration
**Prereqs**: substrate promotion from `experiments/` to `static-v5/` (sub-cycle).
**Cycles**: 2-3. Parser support for `&` and `!Name<Args>` + gen-pass effect propagation.
**Next after**: G8 + G12 become observable from user-written code.

### Option B: G17 design (variadic generics)
**Prereqs**: orchestrator design decision before implementation.
**Cycles**: 1-2 for design; implementation separate.
**Note**: blocks accurate `pcall` / `coroutine.resume` typing.

### Option C: Pre-stable follow-ups (D)
Same as 2026-05-25 handoff Option D. Unchanged prereqs and cycle estimates.

### Option D: CImpl (let-poly with implication wanteds)
**Prereqs**: op-sem foundation hardened (now is the time).
**Cycles**: 1-2.

### Recommended order (orchestrator suggestion)

1. **A** (source-pipeline-integration) — makes G8/G12 user-observable; largest leverage
2. **B** (G17 design) — don't implement without a design; can overlap with A
3. **C** (pre-stable follow-ups) — discharge debts before cutover
4. **D** (CImpl) — fills the final op-sem hole before gen-pass connection

---

## 8. Cross-cutting risks (updated)

1. **Realistic-scale perf** is still a hypothesis. Tested at <1000 constraints; target 10⁵.
2. **CRow + CIntersection source-pipeline** is the new biggest unknown. Rules are correct;
   the pipeline is not connected.
3. **Gen-pass connection** to real Lua AST hasn't started. Same estimate as prior: 2-3 cycles.
4. **Substrate promotion** from `experiments/` to `static-v5/` is still owed.
5. **Cutover from legacy + v4** is the long tail (all 2809 tests green under v5 alone).
