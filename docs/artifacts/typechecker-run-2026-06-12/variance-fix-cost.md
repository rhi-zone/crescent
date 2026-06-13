# Variance-fix cost measurement — STOPPED: readonly/mutable split needed first

Date: 2026-06-14. Subject: the §4b "Known soundness defect" of
`docs/typechecker-design-thesis.md` (mutable-field covariant write-through), the
live false negative confirmed in `critique-soundness.md` claim 5.

**Verdict: STOPPED. The blanket-invariant fix is not viable as-is.** The
soundness bug stays OPEN-but-documented (§4b unchanged) rather than traded for a
wave of false positives on sound code. The next step is the readonly/mutable
variance split (or a fresh-construction covariance rule), recorded below as the
required substrate.

## What was implemented (and reverted)

The textbook sound rule for mutable references, applied in
`lib/type/analysis/slice_subtype.lua`:

- **Record depth (`_rec_sub`):** a field `k` present in both `A` and `B` must
  have **equivalent** types (`equiv = a.tid==b.tid or (sub(a,b) and sub(b,a))`),
  not merely `A.k <: B.k`. Width stays covariant (extra A fields still fine —
  only the loop over B's fields runs).
- **Indexer value (`indexer`/`indexer`, `rec→indexer`, rwi indexer part,
  `_indexer_obligation`):** the indexer is read-write (`t[k]=v`), so the value
  type goes invariant too; the key stays contravariant.

This is correct and minimal. It closes the hole.

## The repro now rejects (the fix works)

| Probe | Baseline | With fix |
|---|---|---|
| `FN_widen_alias_write` (write `1` through widened `NumBox` alias of `IntBox`) | CLEAN (false neg) | **REJECT** (type-mismatch) |
| `FN_widen_alias_write_numvar` (write `number` param through alias) | CLEAN (false neg) | **REJECT** (type-mismatch) |
| `CtrlA_direct_bad_write` (direct `b.f = x`) | REJECT | REJECT (unchanged) |
| `Ctrl_annotated_local_rejects_nonsub` | REJECT | REJECT (unchanged) |
| `Ctrl_equiv_field_ok` (width + equivalent shared field) | CLEAN | CLEAN (still accepted) |

So the fix is real and the controls behave. The problem is what *else* it rejects.

## The cost — measured

### Corpus-wide e2e survey (`slice_survey.lua --e2e`, 869 files)

| Verdict | Baseline (covariant) | With fix (invariant) | Δ |
|---|---|---|---|
| CHECKED-CLEAN | 28 (3.2%) | 27 (3.1%) | **−1** |
| CHECKED-FINDINGS | 15 (1.7%) | 16 (1.8%) | +1 |
| OUT-OF-SUBSET | 803 (92.4%) | 804 (92.5%) | +1 |

The corpus number looks like a rounding error — **but it is misleading**, because
92% of the corpus is OUT-OF-SUBSET for *unrelated* reasons (dynamic-index,
multi-assign, …) and never reaches a record-subtype check. The corpus cannot
exhibit the regression because it barely reaches the rule. The honest cost shows
up on the *curated fully-in-subset* programs — the fixture suite.

### Fixture suite (the in-subset population — this is the load-bearing signal)

Running `bin/cr test lib/type/analysis/` after the fix, the regressions:

**Unit assertions that asserted the OLD covariant-depth behavior (these *should*
change — they encode the unsound rule):**
- `slice_subtype_test.lua:195` — `{a:int,b:str} <: {a:num}` (depth covariance)
- `slice_subtype_test.lua:219` — `{[str]:int} <: {[str]:num}` (indexer value covariance)
- `slice_subtype_test.lua:233` — rwi value-covariant indexer refinement
- `crescent_slice_test.lua:1430` — `dag(30) lit_int(1) <: dag(30) integer` (a
  perf/termination test that happens to assert covariant depth at every leaf)

**End-to-end fixtures that flip CLEAN→FINDINGS — and EVERY ONE is a sound
covariant-construction pattern, NOT the aliased write-through the fix targets:**
- `fixture_local_return_narrowing` — returns `{ id="root", done=false }` against
  `TaskNode = {id:string, done:boolean}`. The literal field `done=false` infers
  `lit_bool(false)`; invariance demands it *equal* `boolean`. Fresh literal, no
  aliasing, no write-through — 100% sound, now rejected.
- `fixture_union_alias_over_named_types` — same shape: record literals into named
  member types of a union alias.
- `fixture_coinductive_recursive_types` — `MaybeInt`/`TreeNode` literals.
- `fixture_closure_param_typing` — `{ kind="a" }` into `Node = {kind:string}`.
- `fixture_table_construction_widening` (corpus_test:283) — its *entire point*:
  `{ op="add", dst=0, pos=1 }` must widen to `Insn = {op:string, dst:integer|nil,
  pos:integer}`. Invariance rejects `op:"add"` vs `op:string`.

That is **5 of ~13 fixtures** — the in-subset population — regressing, and all
five are sound. A targeted probe confirms the root: a bare record literal does
**not** typecheck against its own declared named record type once depth is
invariant —

```
--:: TaskNode = { id: string, done: boolean }
--: () -> TaskNode
local function mk() return { id = "root", done = false } end   -- now REJECTED
```

while the same with non-literal params (`mk(i,d)` with `i:string,d:boolean`) is
CLEAN. So blanket invariance breaks the single most common idiom in the language:
**record literal → named record type**, because literal-typed fields (`"root"`,
`false`, `0`) are subtypes of but not *equal to* their base types.

## The judgment

The fix trades one soundness hole — which requires a *deliberate* alias of one
record through two different static types followed by a write — for false
positives on **fresh record construction**, which is everywhere and entirely
sound (a freshly-built literal has no second aliased view to corrupt). The
corpus's −1 CLEAN undercounts because the corpus is mostly out-of-subset; the
fixture suite (the curated in-subset set) shows the true ergonomic cost, and it
is large and uniformly on legitimate covariant *construction/read* patterns.

This meets the STOP condition: a large fraction of the in-subset population
regresses on sound covariant patterns. Committing blanket invariance would
replace a rare, deliberate false negative with pervasive false positives on
idiomatic code.

## What is needed before this is viable (the substrate gap)

The principled fix is **not** "make the fields equal." It is to distinguish the
two situations invariance conflates:

1. **Fresh / read-only use** (covariant-safe): a literal being constructed, or a
   field only ever read through the wider alias. `{op:"add"} <: {op:string}` is
   sound here.
2. **Mutable aliased write-through** (must be invariant): the same record reached
   through two static types, one of which is then written.

Two substrate routes, neither built:

- **Readonly/mutable variance split** (slice §3.2/§9.2, thesis §4b option 2):
  thread the per-field `readonly` bit — currently vestigial in `slice_ty.lua`
  (parsed but hardcoded `false`, never set true) — through parse and the depth
  rule; covariant for readonly, invariant for mutable. Requires the bit to be
  *inferred* (a field written nowhere reachable is readonly) or annotated. This
  is the category-2 variance-marked structural constructor §3 of the thesis
  names; it must be built de-special-cased, not field-keyed.
- **Fresh-construction covariance**: treat a record-*literal* value
  (construction site) covariantly against its target, and only enforce invariance
  on *named-to-named* widening through a binding that is later aliased+written.
  This needs the lowering to carry a "freshly-constructed, not-yet-aliased"
  provenance bit on record values — also unbuilt substrate.

Either way: **substrate before the fix.** The blanket-invariant change is a
result-level patch that manufactures false positives; the real closure needs the
mutability/provenance distinction first.

## Status of the bug

`docs/typechecker-design-thesis.md` §4b stays **OPEN**. The `readonly`/mutable
split (or fresh-construction provenance) is the prerequisite. No `lib/` change was
committed; the implemented-then-reverted patch is recorded here so the exact rule
and its measured cost are reproducible.
