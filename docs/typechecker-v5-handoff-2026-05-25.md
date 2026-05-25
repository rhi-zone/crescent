# Typechecker v5 — Session-Close Handoff (2026-05-25)

Single navigation document for the next session. The log (`docs/typechecker-v5-log.md`, 1034 lines) is the chronological source of truth; this handoff is the snapshot.

If you read only one file, read this. Then dive into the log when you need detail.

---

## 1. Where v5 stands today

| Artifact | Path | LOC | Status |
|---|---|---|---|
| Constraints catalog | `~/.claude/plans/radiant-gathering-gray.md` | ~250 | **Outside repo — relocation owed** |
| Decision log (append-only) | `docs/typechecker-v5-log.md` | 1034 | Current |
| Discovery (unframed) | `docs/typechecker-v5-discovery-unframed.md` | ~700 | Reference |
| Discovery (tainted, radioactive) | `docs/typechecker-v5-discovery-tainted.md` | ~300 | Do not cite |
| Research report | `docs/typechecker-v5-research-report.md` | ~4500 words | Reference |
| Inference rules | `docs/typechecker-v5-operational-semantics.md` | ~730 | Active |
| Perf log | `docs/perf/log.md` | 1274 | Active |
| Prototype substrate | `lib/type/experiments/v5_perf/*.lua` | 1149+ | Prototype — promote later |
| Executable spec | `lib/type/static-v5/op_sem.lua` | ~850 | Active |
| Alternate interpreter | `lib/type/static-v5/op_sem_alt.lua` | ~990 | Parity reference |
| Parity test (EXEC vs DOCS) | `lib/type/static-v5/op_sem_parity_test.lua` | ~894 | 61 assertions, all pass |
| Parity test (independent encoding) | `lib/type/static-v5/op_sem_independent_parity_test.lua` | ~700 | 85 assertions, all pass |
| Backlog | `TODO.md` (root) | — | Pre-stable + post-stable items |

**Combined parity: 146/146 assertions across 32 fixtures. Zero divergence between two independently-implemented interpreters.**

---

## 2. Architecture in one paragraph

Reified constraint ADT with provenance + Wanted/Given flavour. Monotone union-find substitution `TVarId → (Type, Phase)` is the single source of truth — no side-channels. Worklist + inert set; pop, try progress under current substitution, extend or add to inert. **No cycle detection** — quiescence is worklist empty; inert constraints at quiescence are stuck errors. Circular `require` rejected at typecheck (topological module order). Type AST splits free unification tvars (`UVar(TVarId)`, gensym IDs, never shift) from De Bruijn bound vars (`Var(LvlIdx)`, shift under β). **Eager shift on bind.** Tvars never change level (Lean discipline; no Rémy lowering — soundness floor). Construction phase is constraint variants (`CTableOpen/Set/Seal/CMethodCall`); per-tvar `Phase = Open | Sealed` is part of the substitution binding. `setmetatable(t, nil)` unconditionally rejected. HKT via direct type lambdas + Miller pattern fragment + `HOUnify` residue (never commit guessed HO solutions). Record fields invariant (mutable in v5 → covariant would be TS-array unsoundness). Multi-return unified as tuple-of-unions with nil padding; narrowing strong on closed unions, **suppressed on row variables** (soundness floor).

## 3. Key invariants (load-bearing)

- **A1**: soundness non-negotiable. Soundness holes are malware vectors.
- **Monotone substitution**: never retract a binding. Phase transitions go Open → Sealed only.
- **No level lowering**: tvars get their level at creation; never change.
- **Never commit guessed HO solutions**: HOUnify residue surviving to quiescence is an "ambiguous constructor variable" error.
- **Record fields invariant**: because v5 fields are mutable per the CTableSet model. Width subtyping admits forgetting fields (read-side); field types stay invariant.
- **No cycle detection**: simpler termination story; mutual-ambiguity reports two errors, mitigated by inert-error renderer naming other stuck constraints.
- **Topological module order**: circular `require` rejected.

---

## 4. What's been verified

### Falsifiability gates passed

- **Corpus survey (revised H4 model)**: 100% fit on 20% sample of 700 `setmetatable` sites. Original model was 60%/40% — refuted; revised admits FITS-A (straight-line), FITS-B (MODULE-MT), FITS-C (self-reference), FITS-D (helper-annotation-ready).
- **Prototype perf gate**: <500ms wall, <2MB heap, <5× reactivations on synthetic constraints from `lib/test/arb.lua` and `lib/stdlib/lint.lua`. PASS with margins of ~2700× wall, ~100× heap, ~75× reactivations.
- **CHKT perf re-gate**: PASS. Heap grew 8× from baseline (~20→160 KB), wall grew 4×, still well under budget.
- **Variance-CSub perf re-gate**: PASS. Step count grew ~30% from added CSub load.
- **Independent-encoding parity**: 85/85 assertions across 17 fixtures. Two interpreters (`op_sem.lua` and `op_sem_alt.lua`) implemented from different agents reading the same doc; zero divergences.
- **A11 (2809 test baseline)**: 540 pass / 45 fail / 10 skip baseline preserved. Caveat: full suite alternates 540/45 ↔ 539/46 from runner-side flaky timing, not real regression.

### What this does NOT verify

- **Realistic scale**: tested at 200-500 constraints; architecture targets ~10⁵. Linear extrapolation projects ~40ms at 10⁵; non-linear factors (GC pauses, cache pressure, LuaJIT trace bailouts) not captured.
- **Gen-pass output ordering**: synthetic extractor uses pattern-grep; real gen may stress different paths.
- **Hard constraint families not in scope yet**: CEffect, CRow, CImpl, CMultiReturn. Each needs its own perf re-gate.

---

## 5. All named spec gaps (sourced)

Per F12, these are gaps the agents flagged honestly rather than filling silently. Numbered for cross-reference.

| # | Gap | Source | Severity | Owed to |
|---|---|---|---|---|
| G1 | Restricted Miller fragment — only UVar/Const args admitted, not full rigid trees | CHKT agent | Low | Future CHKT refinement |
| G2 | No kind inference; `Lambda.k` is documentation only | CHKT agent | Med | Future HKT polish |
| G3 | No eta-equivalence; `λx. F x` ≢ `F` during Miller check | CHKT agent | Low | Future HKT polish |
| G4 | No shift-aware abstraction over nested lambdas — `abstract_body` bails via guard | CHKT agent | Med | Future HKT extension |
| G5 | HOUnify residue provenance chaining for CImpl→CHKT→HOUnify | CHKT agent | Med | CImpl landing |
| G6 | μ.__index chain walk for missing field on sealed table; HKT-shaped metatables need orchestrator decision | op-sem core agent | Med | Future op-sem extension |
| G7 | CMultiReturn union-arity not formalised (fixture 6 encoded as scalar stand-in) | op-sem core agent | High | CMultiReturn family |
| G8 | CRow narrowing suppression on row variables (item 7 soundness floor); not exercised by any fixture yet | op-sem core agent | High | CRow family |
| G9 | Bounded tvars — T-CSub-TVar routes to CEq; full bounded substrate is v5.x | Variance agent | Med | v5.x bounds work |
| G10 | Variance under Lambda — registry covers named Const only | Variance agent | Med | HKT variance polish |
| G11 | Union backtracking — T-CSub-Union-R admits exact-branch only | Variance agent | Low | Union refinement |
| G12 | Effect-row variance — owed to CEffect | Variance agent | High | CEffect family |
| G13 | Intersection types — no AST variant yet | Variance agent | Low | Future feature |
| G14 | T-CSub dispatch priority not formally enforced; chose TVar-before-Refl interpretation | Independent-parity agent | Low | Doc clarification |
| G15 | T-CTSet four-way cascade order not formally enforced | Independent-parity agent | Low | Doc clarification |
| G16 | T-CHKT-Reduce chain peel depth not formally specified | Independent-parity agent | Low | Doc clarification |

**G7, G8, G12 are high-severity** — they block specific constraint family landings.

---

## 6. Backlog (TODO.md + log)

### Pre-stable (must close before declaring v5.0 stable)

- **Exhaustive prior-session mining**: sampled pass found 5 multi-session arcs; exhaustive pass owed. Particular value: scheduler-shaped problems, mechanisms previous attempts found load-bearing.
- **Adversarial missed-generalisation eval** (item 6 follow-up): generate Lua snippets that the no-level-lowering discipline rejects but Rémy lowering would accept. Classify by idiomatic/rare/pathological. Revisit lowering if idiomatic patterns are common.
- **Circular `require` corpus check**: grep `lib/` for circular patterns. If any are load-bearing (not incidental), revisit before declaring v5 stable.
- **Constraints catalog relocation**: `~/.claude/plans/radiant-gathering-gray.md` → `docs/typechecker-v5-constraints.md`. Outside-repo location is durability risk.

### Post-stable (low/medium prio)

- **Lazy De Bruijn shift experiment** (item 2 follow-up): benchmark lazy-shift (Lean/Coq sliding-window cache) vs eager-shift baseline. Low prio.
- **`setmetatable(t, nil)` investigation** (item 5 follow-up): sandboxing's strongest use case is served by fresh-table pattern (`local clean = {}; for k,v in pairs(env) do clean[k] = v end`). Medium prio. v5.x may simply document the fresh-table idiom as canonical.
- **Property-based parity** (independent-parity follow-up): generate random constraint sequences and run both interpreters. Catches rule-priority divergence that fixed fixtures miss.

---

## 7. Open H-questions

| H | Question | Status |
|---|---|---|
| H1 | HKT in scope? | Closed YES. Implemented through CHKT extension. |
| H2 | Effects in scope? | Closed YES. Implementation deferred to CEffect family. |
| H3 | Migration shape? | Closed: parallel build at `lib/type/static-v5/`. |
| H4 | Sound setmetatable model? | Closed: construction-phase constraints + per-tvar Phase. |
| H5 | Refinement/GADT/impredicativity? | Closed: out of scope for v5. |
| H6 | LSP port-vs-rewrite? | Struck. LSP unreliable, not a v5 constraint. |
| H7 | Op-sem representation? | Closed: parallel impl + docs with parity tests. Done; 146 assertions pass. |
| H8 | Scope/timeline? | Struck. Quality matters, not pacing. |
| H9 | Sibling-repo discovery? | Closed. Discovery pass landed. |
| H10 | `any` escape hatch for community release? | **Still open.** Default v5 posture: no `any`. Revisit if community ergonomics force. Not blocking. |

H10 is the only open H-question; not blocking.

---

## 8. Cross-cutting risks

1. **Realistic-scale perf** is a hypothesis, not a measurement. Architecture targets 10⁵ constraints; tested at <500. Re-gate at scale during each constraint-family landing.
2. **CEffect interaction with effect-row variance** is the next big unknown. CSub variance is half-discharged; row-tail variance for effects is shared with CRow. May be larger than estimated.
3. **Gen-pass connection** to real Lua AST hasn't started. The op-sem currently runs on hand-emitted constraints. Connecting to the existing parser + extracting constraints from real source is a separate phase, probably 2-3 cycles.
4. **Promotion from `experiments/` to `static-v5/`** of the substrate is owed. Currently the prototype lives under `experiments/`; production code under `static-v5/` requires the substrate.
5. **Cutover from legacy + v4** is the final phase. Requires all 2809 tests green under v5 alone. Likely the longest tail.

---

## 9. Methodology rules established this session

The F-series in CLAUDE.md gained several entries through this session's failures:

- **F9**: Maintain an append-only discovery/exploration/decision log. Catches tactical-for-strategic substitution.
- **F10**: Experiments are first-class. Commit before discard.
- **F11**: H-closures need log entries with evidence, not chat alone.
- **F12**: Subagent prompts must NOT pre-load the answer. Three discovery reports earlier this session were tainted by D6/D11/D14 framing.
- **F13**: Tainted output preserved separately (`docs/typechecker-v5-discovery-tainted.md`). Radioactive but kept for posterity.
- **F14**: Slacking off during design is the primary failure mode. "As wide as possible" beats "smart cherry-pick."

Also new in CLAUDE.md G-series:

- **G12**: No pre-loaded subagent prompts. Frame on target, not on hypothesis.
- **G13**: No accepting unsoundness for backward-compat. If v5's sound model rejects existing code, refactor the code (or admit the model needs to admit the pattern — corpus-driven, not principle-driven).

---

## 10. Next-session menu

Each option's prerequisites and rough cycle count.

### Option A: Continue extending op-sem (CRow + CEffect unified)
**Prereqs**: nothing blocking; G8 + G12 will be addressed by this work.
**Cycles**: 1-2. Builds substrate row machinery + constraint variants. Perf re-gate at end.
**Next after**: CImpl, then CMultiReturn (G7), then minimal core complete.

### Option B: CMultiReturn (G7)
**Prereqs**: nothing blocking. Smaller than CEffect.
**Cycles**: 1. Builds union-arity rule + fixtures. Closes a high-severity gap.
**Next after**: still need CRow/CEffect.

### Option C: Gen-pass — connect op-sem to real Lua AST
**Prereqs**: substrate promotion from `experiments/` to `static-v5/` (a sub-cycle of its own).
**Cycles**: 2-3. Bigger than constraint-family work because it touches the existing parser + bridges to op-sem.
**Next after**: realistic-scale perf re-gate becomes possible.

### Option D: Pre-stable follow-ups (mining, missed-gen eval, circular require corpus, catalog relocation)
**Prereqs**: nothing blocking.
**Cycles**: 1-2. Discharges pre-stable debts. Lowers risk for next architectural work.

### Option E: Constraint catalog relocation
**Prereqs**: nothing.
**Cycles**: <1. Move `~/.claude/plans/radiant-gathering-gray.md` to `docs/typechecker-v5-constraints.md`. Update references in log + handoff. Small but durable.

### Recommended order (orchestrator suggestion, not binding)

1. **E** (catalog relocation) — tiny, removes a durability risk
2. **B** (CMultiReturn) — closes a high-severity gap, smallest cycle
3. **A** (CRow + CEffect unified) — closes G8 + G12, largest unresolved family
4. **D** (pre-stable follow-ups) — discharge before declaring stable
5. **C** (gen-pass) — productionisation; bigger work, comes after architecture is settled

This order favours **closing high-severity gaps first**, then **discharging debts**, then **productionising**. It's not the only sensible order; the user (or next-session orchestrator) may reasonably choose differently.

---

## 11. Pointers into the log

For chronological detail, the log has:

- **Session 1 (2026-05-22)**: framing, discovery, research, first design wave, first adversarial wave, triage, second adversarial wave, 8-item walkthrough.
- **Walkthrough closures**: each item closed inline with reasoning. Items 1, 2, 6, 8, 3+4+8, 5, 7, then "all 8 severe items closed" summary.
- **2026-05-24**: prototype perf gate PASS.
- **2026-05-24**: op-sem minimal core (3 commits, 31 assertions).
- **2026-05-24**: CHKT extension (6 commits, +18 assertions, perf re-gate PASS).
- **2026-05-24**: variance-respecting CSub (6 commits, +12 assertions, perf re-gate PASS).
- **2026-05-24**: independent-encoding parity (3 commits, 85 assertions, PASS, no divergences).
- **2026-05-25**: this handoff entry.

Commits this session (chronological):
```
f5a3041c docs(type): v5 discovery + research
2ce3b29d docs(type): v5 adversarial design wave (4 picks)
b3a8d04e docs(type): v5 adversarial coherence wave (picks refuted, triaged)
2c4a827e docs(type): v5 adversarial round 2 (corpus resolved, 8 severe patches)
f9593354 docs(type): v5 severe-item walkthrough complete (8/8 closed)
6bbe20a4 feat(type): v5 perf-experiment scaffold
ebc41ada feat(type): v5 perf-experiment corpus extractor + bench
fb4576e3 feat(type): pool tvars by name; stress mode
74d224a9 docs(perf): v5 substrate falsifiability gate — PASS
8e22f979 docs(type): v5 op-sem inference rules
150d0dcd feat(type): v5 op-sem executable spec
cfa0112f test(type): v5 op-sem parity test + log
e9a06c3e feat(type): v5 substrate — head-shape parked-map
b3259fd0 docs(type): v5 op-sem CHKT + HOUnify rules
0550959f feat(type): v5 op-sem CHKT + HOUnify executable
0d8434e2 test(type): v5 op-sem CHKT + HOUnify fixtures
04e73324 perf(type): v5 CHKT + HOUnify re-gate — PASS
ef03f5dd docs(type): v5 op-sem CHKT log entry
(variance commits)
(independent-parity commits 14813b87 / bad20722 / 1811e6da)
```

---

## 12. What this handoff intentionally does NOT do

- Re-derive any decision. Decisions live in the log with their evidence.
- Recommend a design. Recommendations live in option E above as orchestrator suggestion, not directive.
- Hide caveats. Every gap, every "still owed," every "tested only at small scale" is named.
- Spawn agents. The next session orchestrator + user pick what to dispatch.

If the next session reads this handoff and feels nothing is missing — the handoff worked. If they have to read the log to find something this handoff didn't surface, the handoff failed and should be updated mid-session.
