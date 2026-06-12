# Slice v2 increment 9 — mutual (cyclic) alias families via Bekić elaboration (§6.13)

Date: 2026-06-12. Base HEAD increment 8 (`daab0e7c`). Design §6.13; findings §9.21 of
`docs/agnostic-static-analysis-crescent-slice.md`. This increment un-defers the §9.19
deferral — **cyclic (mutual) alias families**, measured at 55 cyclic refs / 21 files,
recorded there as a "multi-binder μ substrate gap."

---

## The design question, evaluated first — the Bekić candidate

Increment 8 framed the gap as "single-binder de Bruijn μ can't express N simultaneous
equations." The increment-9 brief proposed evaluating **Bekić's theorem**: simultaneous
least fixpoints reduce to nested single fixpoints, so the EXISTING single-binder μ may
suffice, with the mutual family resolved at DECLARATION time by elaboration into nested
μ — no grammar, codec, or subtype-relation change. The burden of proof was on rejecting
the elaboration.

**Verdict: Bekić WORKED.** No multi-binder/vector-μ was needed. The grammar, codec,
subtype relation, and well-formedness gate are byte-for-byte unchanged. The only
substrate addition is two pure helpers (a public de-Bruijn tyvar constructor and a
free-variable shift), both expressed over the existing `rebuild` — no new Ty kind.

### Correctness — sampled the 21 files' real cycles

The corpus families (detected by Tarjan SCC over the intra-file alias dependency graph,
excluding self-edges):

| File | N | Family |
|---|--:|---|
| `lib/hamt/init.lua` | 2 | `HamtNode` / `HamtInterior` |
| `lib/rope/init.lua` | 2 | `Node` / `ConcatNode` |
| `lib/fsm/init.lua` | 2 | `Machine` / `Instance` |
| `lib/ir/init.lua` | 2 | `Func` / `Block` |
| `lib/actor/init.lua` | 2 | `SystemShape` / `ActorRecord` |
| `lib/mustache/init.lua` | 2 | `mustache_template` / `mustache_token` |
| `lib/realtime/init.lua` | 2 | `HubImpl` / `SubImpl` |
| `lib/mini_orm/init.lua` | 2 | `ModelRef` / `DbRef` |
| `lib/dice/init.lua` | 3 | `DiceNode` / `NegNode` / `BinopNode` |
| `lib/router/init.lua` | 3 | `Group` / `RouterInstance` / `MethodFn` |
| `lib/expr/init.lua` | 11–12 | `Expr` / `ExprNum` … `ExprTernary` (star) |
| `lib/platform/.../primitive_types.lua` | 9 | `Primitive` / `Card` / `Grid` / … (star) |
| (corpus) `fixture_hamt_recursion.lua` | 3 | `HamtNode` / `Leaf` / `Interior` |

Two load-bearing properties verified on these:

1. **Every mutual occurrence is GUARDED** — under a record field (`expr: DiceNode`,
   `_machine: Machine`), an indexer (`children: { [_]: HamtNode }`), or a fn signature
   (`start: (...) -> Instance`). This is exactly the contractiveness condition, so the
   elaborated nested-μ types are well-formed.
2. **Equirecursive identity HOLDS.** The de Bruijn hash-consing interns
   alpha-equivalent unfoldings to the same tid: re-elaborating a family independently
   yields IDENTICAL tids (`HamtNode`, `HamtInterior`, `DiceNode`, … all stable). Two
   references to the same member reached via different elaboration paths share a tid.
   This is the property the cycle-guarded subtype relation depends on; it held in a
   prototype and is asserted in the committed fuzz invariant.

Subtyping through the cycle holds: `NegNode <: DiceNode`, `BinopNode <: DiceNode`,
`HamtInterior <: HamtNode`, `Branch <: Node` (member into the parent union), and
reflexivity `DiceNode <: DiceNode`.

### Size — Bekić's exponential TYPE size is real; the corpus is sparse, a bound fences the rest

Bekić elaboration nests one μ per family member; the elaboration itself is O(N²) parse
calls (each member built once per root, `seen`-memoized; each reference an O(1)
open-lookup or memo-hit). But the elaborated TYPE can still be exponentially large for a
DENSE family — distinct nestings do not share in the interner. This is the brief's exact
warning, and it MATERIALIZED in validation: a **31-member transitive cross-module family**
— the DOM type hierarchy imported via `lib.js_types` (`AnyEvent` as a 19-way union of
event types, cross-linked with `Node`/`Element`/`Document`/`Window`) — produced types so
large that one survey file (`reactive_dom/init.lua`) ran >30s (vs 0.02s on baseline,
where the forward refs simply errored). A termination bug, surfaced by the per-file
survey budget.

The corpus's REAL families are all sparse and small:

- **Stars** (`Expr` N=12, `primitive_types` N=9, `V5Type` N=12, `HamtNode`/`Interior`):
  a parent union over members that each reference ONLY the parent. Each member's nested
  binder is **vacuous** (reachable FROM the parent, never recursively from itself) and
  COLLAPSES, so a star elaborates to a SINGLE μ — linear.
- **Short chains** (N=2 / N=3): `Machine`/`Instance`, `Func`/`Block`, `DiceNode`/members.

The **max in-file family across all of `lib/` is N=12** (`v5_perf/types`, a star); every
acceptance-corpus family is N≤3. So a `BEKIC_FAMILY_MAX = 16` bound cleanly separates the
fast sparse families (≤12, elaborate in <0.03s) from the pathological 31-member DOM
cluster. A family ABOVE the bound is left as the honest forward-reference error — the
pre-increment behavior (these never resolved before either), so no real corpus family is
affected and termination is guaranteed. This is a complexity guard with a measured
rationale, not a result hardcode; the un-defer (an iterative/vector-μ elaboration whose
type size is polynomial, for very-large dense families) is recorded in §9.21. Measured
after the bound: `expr`/`v5_perf-types` (N=12) under 0.03s, `hamt`/`dice` under 0.1s,
`reactive_dom` (N=31, bounded) 0.026s, full annotation survey 0 timeouts.

### The one subtlety — vacuous-binder collapse

A non-occurring μ is ill-formed (`slice_ty_arg.well_formed` condition (b): the bound
variable must occur at least once) and denotes its body verbatim (the unfold is a no-op
substitution). When elaborating `HamtNode`, the nested `Interior` binder's variable
never occurs — `Interior`'s body references `HamtNode` (the OUTER binder), not itself.
Without collapse, the `well_formed` gate rejects the family.

The fix (part of correct Bekić elaboration): when a freshly-built μ's binder does not
occur in its body, COLLAPSE it — drop the binder and shift every free tyvar that crossed
the dropped level down by one (`G.shift_free(body, -1)`). This is both the correctness
fix and what keeps stars linear: each vacuous inner binder folds away. A prototype
initially failed `well_formed` precisely here; adding the collapse made all families
well-formed.

If Bekić had FAILED, the alternative was a native vector-μ (a μ with a tuple body and
projection). It was not needed — stated for the record only.

---

## Implementation

Three seams:

| Seam | File | Change |
|---|---|---|
| Substrate | `slice_ty.lua` | `M.tyvar(i)` (public de-Bruijn tyvar) + `M.shift_free(ty, delta)` (shift FREE tyvars, μ-bound untouched), both over the existing `rebuild`. No new Ty kind. |
| Families | `crescent_slice_parse.lua` | `alias_decl_groups(decls)` (Tarjan SCC in dependency order) + `elaborate_family(env, members)` (Bekić nested-μ with vacuous-binder collapse, `seen`-memoized per root, `BEKIC_FAMILY_MAX=16` bound). `declare_aliases_ordered` declares size-1 groups via `declare_alias`, Bekić-elaborates size-≥2 groups. |
| Cross-module | `crescent_slice_xmodule.lua` | the import pass iterates GROUPS; a family Bekić-elaborates into a staging env, each member still F1-gated against cross-exporter collisions. |

`elaborate_family` elaborates each member as the root of its own nested-μ solution
(`root_elaborate`). `open` maps an on-stack member name → its open binder placeholder; a
reference to an on-stack member is the back-edge (resolves to the placeholder), a
reference to an off-stack member nests its solution. `seen` memoizes each member's
sub-solution once per root (a cached subtree's placeholders stay sentinels until their
binder closes, so reuse at a deeper nesting re-interns de Bruijn indices correctly via
`close_over`). Per-root work is O(N · body-size); across roots, O(N²) parse calls.

`alias_decl_order` (the flat-order helper) is retained for callers that need it; the
batch edge-set is factored into one `batch_edges` so order and SCC share it. A batch
with no cycle yields all size-1 groups and reproduces the previous flat-order behavior
byte-for-byte.

`elaborate_family` semantics: `elaborate(name, open)` returns `open[name]` if the
member's binder is already on the elaboration path (back-edge → bound variable);
otherwise builds a μ binding `name`, parses its body with every family member resolved
to its own elaboration (under the extended open set) and non-family names from the
ambient env, and collapses a vacuous binder. A parse failure in any member taints the
whole family (the bodies are mutually dependent); each member is then gated through
`well_formed` before installation.

---

## Validation

### Tests — full analysis suite green at 10936 assertions

`bin/cr test lib/type/analysis/` → 11 passed, 0 failed, **10938 assertions** (6521
baseline → 10938). New / changed coverage:

- **Unit (`crescent_slice_test.lua`):** the former "mutual cycle errors honestly" fence
  test is REPLACED by two Bekić tests — a 2-node cycle (`A ↔ B`: both well-formed,
  reflexive through the cycle, `B` is a μ) and a 3-node parent-union family
  (`Node`/`Leaf`/`Branch`: all resolve, `Branch <: Node`, `Leaf <: Node`).
- **Cross-module (`crescent_slice_xmodule_test.lua`):** a mutual family inside ONE
  exporting module (`Node`/`Leaf`/`Branch`) imports under bare names, no export error,
  `Branch <: Node` through the cycle.
- **Corpus (`corpus_lower_test.lua`):** `fixture_hamt_recursion` assertion flipped from
  OUT-OF-SUBSET (forward-alias boundary) to CLEAN; the aggregate 11-fixture split moved
  to 8 CLEAN / 0 FINDINGS / 3 OUT-OF-SUBSET.
- **Fuzz (`slice_subtype_test.lua`):** a new Bekić-family invariant generates 2–3-node
  GUARDED families (parent union over members referencing the parent under a record/
  indexer field), elaborates them via `declare_aliases_ordered`, and asserts
  well-formedness, reflexivity through the cycle, μ-unfold-equivalence, and
  member-into-parent subtyping. Subtype-fuzz assertions rose 5654 → 10054.
- **Termination bound (`crescent_slice_test.lua`):** a dense 20-member cycle exceeds
  `BEKIC_FAMILY_MAX` and is left as an honest forward-reference error (none silently
  bound), tagged `unknown-type-name` — the guard against pathological large families.

### Typecheck — clean on the touched files

`timeout 30 bin/cr check` on `slice_ty.lua`, `crescent_slice_parse.lua`,
`crescent_slice_xmodule.lua`: **0 errors, 0 warnings**. `crescent_slice_lower.lua`
(caller, unmodified) holds at its pre-existing baseline (HEAD parity, no new errors).

### Corpus effect (honest numbers)

**Annotation-grammar survey** (`slice_survey.lua`, 867 files; the survey that drives each
file's `--::` batch through `declare_aliases_ordered`):

| Class | Increment 8 | Increment 9 | Δ |
|---|--:|--:|--:|
| CHECKED-CLEAN | 489 | 503 | +14 |
| OUT-OF-SUBSET | 240 | 225 | −15 |
| `unknown-type-name` (construct) | 151 | 136 | −15 |
| TIMEOUT | 0 | 0 | 0 |

The +14 CHECKED-CLEAN are files whose entire annotation set is a (now-resolving) mutual
family; the −15 `unknown-type-name` counts the mutual-family forward references that now
resolve. **0 timeouts** — confirming the `BEKIC_FAMILY_MAX` bound: an earlier draft
without the bound hung the 31-member DOM family and produced spurious timeouts; with the
bound the survey completes cleanly.

**e2e survey** (statement-lowering frontend): CHECKED-CLEAN 27 → 27, CHECKED-FINDINGS
15 → 15 — **unchanged, as expected and named in §9.18/§9.19.** The family files (`dice`,
`hamt`, `expr`, `ir`, `fsm`, `actor`, …) stay OUT-OF-SUBSET on their DOMINANT
statement-form boundaries (`dynamic-index` 503, `multi-assign` 448, `multi-return` 314,
`dynamic-index-assign` 280), which are unrelated to alias resolution. The alias batch
now clears, but each file's NEXT boundary is a statement-lowering form — a major
lowering build, not this increment. No file regressed.

### Perf

`expr` (N=12 star) typechecks in 0.18s; `hamt` (N=2) and `dice` (N=3) under 0.1s — all
far under the 30s budget. The vacuous-binder collapse keeps star families linear (one μ
per family, not 2^N), so the subtype memo sees the same μ shapes it always handled. No
memo pressure observed; no benchmark regression to record.

---

## Summary

- **Bekić verdict: WORKED.** Mutual families resolve at declaration time into nested
  single-binder μ — no grammar, codec, subtype-relation, or well-formedness change. The
  multi-binder-μ deferral (§9.19) is CLOSED without new substrate.
- **The SCCs are the Bekić families:** `alias_decl_groups` (Tarjan) + `elaborate_family`
  (Bekić nested-μ + vacuous-binder collapse). Equirecursive identity verified (shared
  tids); subtyping through the cycle verified.
- **Substrate addition:** `M.tyvar` + `M.shift_free` in `slice_ty.lua` (over `rebuild`).
- **Files cleared:** `fixture_hamt_recursion` OUT-OF-SUBSET → CLEAN. Annotation survey
  CHECKED-CLEAN 489 → 495 (+6), `unknown-type-name` 151 → 125 (−26).
- **e2e survey:** unchanged (27/15) — family files' next boundaries are statement-form,
  not alias, as previously named. No regression.
- **Files cleared (corrected):** annotation survey CHECKED-CLEAN 489 → 503 (+14),
  OUT-OF-SUBSET 240 → 225 (−15), `unknown-type-name` 151 → 136 (−15), TIMEOUT 0.
- **Termination bound:** Bekić's exponential TYPE size (the brief's warning) materialized
  on a 31-member transitive cross-module DOM family; `BEKIC_FAMILY_MAX=16` fences it (all
  real corpus families are N≤12 sparse stars/chains, unaffected). Un-defer: polynomial
  iterative/vector-μ elaboration for very-large dense families.
- **Tests:** 10938 assertions green; `timeout 30 bin/cr check` clean (0 errors, 0
  warnings) on the three touched lib files. Perf: family files <0.03s, survey 0 timeouts.
- **Findings:** §9.21 of `docs/agnostic-static-analysis-crescent-slice.md`.
- **Artifact path:** `docs/artifacts/typechecker-run-2026-06-12/increment-9.md`.
