# Slice v2 increment 7 — field-path narrowing (the §9.8 deferral)

Date: 2026-06-12. Base HEAD `b4559472` (audit round 4 fixes). Design §6.11; findings
§9.18 of `docs/agnostic-static-analysis-crescent-slice.md`. This increment un-defers
the §9.8 field-path-narrowing deferral whose un-defer trigger fired three times: the
coinductive fixture's FINDINGS verdict, increment-4's cross-module boundary, and all
11 of audit round 4's false-positive files.

---

## The design problem and the derivation

Narrowing `x.f` (a path, not a variable) is sound only while nothing can have mutated
the path. The design (§6.11, derived whole) reaches three conclusions:

1. **A field path is an opaque refinement-target NAME.** `slice_narrow.lua`'s pure
   `refine(guard, x, T)` matches its target `x` by string equality — it never
   inspects `x`'s structure. So a path `"x.f"` is a valid refinement target with the
   narrowing core, the `Guard` grammar, and the `narrow_guard` evidence method
   **byte-for-byte unchanged**. The path's pre-guard type is `index_result(typeof x,
   f)`; the refinement binds `"x.f" : T_true` as an ordinary (synthetic-named) Γ
   entry; a downstream read `x.f` consults Γ for the path binding first.

2. **Depth bound = 1 (`x.f`), justified by the corpus.** The round-4 false-positive
   samples are uniformly depth-1 (`opts_t.title`, `node.left`, `node.children`). The
   two depth-2 reads in the corpus (`root.data.title`, `ast.data.title`) are
   unconditional writes through casts, not guarded narrowing sites. Depth-2 is a
   §9.18 deferral (strictly additive: a longer path string, the same machinery).

3. **The invalidation rule is the soundness boundary** (below).

## The invalidation rule (the soundness boundary, chosen)

> **A path refinement `x.f` dies — the binding is dropped, the read falls back to the
> declared field type — after any statement that can mutate the path or alias the
> base. Without escape/effect analysis (v1 has neither), the sound-conservative rule
> invalidates after: (1) ANY function/method call — a callee may hold the base and
> mutate `x.f` through an argument or upvalue; (2) ANY assignment — base reassign,
> write-through any field of the base, dynamic write, AND a write through ANY lvalue
> (aliasing is undecidable in v1, §6.11.3).**

Justifications, derived from the value universe:

- **No narrower rule is justifiable without escape analysis.** A "only calls that
  reach `x` invalidate" rule needs a call's argument/upvalue reach (escape analysis
  the slice lacks); a "writes only to the named base" rule is unsound under aliasing.
  The honest position: conservative rule now, un-defer toward a purity/effects
  substrate (`docs/effects.md`) — recorded §9.18 with that trigger.
- **Readonly fields survive calls and writes.** The grammar's `readonly` marker means
  "no write can occur to this field," so no call and no write through any alias can
  change it — a readonly path refinement survives the whole block. The direct
  value-universe reading of the marker, not a special case (the same reading that
  makes readonly fields covariant where mutable fields are invariant, §9.2). The
  corpus's narrowed paths are all mutable, so this is a soundness-completeness
  statement; the readonly-survival branch's acceptance test is a future readonly
  narrowed path.
- **Granularity: statement-level, invalidate-AFTER.** The refinement is dropped AFTER
  an invalidating statement's claims are lowered. In `if node.left then s = s +
  tree_sum(node.left) end`, the path read `node.left` is the call argument,
  synthesized as the refined `TreeNode` BEFORE the call's invalidation reaches the
  next statement. Sound (the call cannot have run when the argument is typed) and
  precise enough for the dominant idiom (guard, then immediately use in a call).

### The aliasing worked example (§6.11.3) — why "any write-through-any-lvalue"

```lua
--:: Node = { f: integer | nil }
local function g(x)
  local y = x      -- y aliases x (same table)
  if x.f then
    y.f = nil      -- writes x.f THROUGH the alias y — x.f is now nil
    return x.f     -- UNSOUND if x.f still read as integer
  end
  return 0
end
```

`y.f = nil` is a write through an lvalue; v1 cannot decide `y == x`, so the
conservative rule drops the `x.f` refinement and `return x.f` re-reads `integer |
nil`, correctly rejecting `-> integer`. The alias case is subsumed by the call/write
rule, no alias analysis required. This is one of the three executable invalidation
tests.

## Interaction with μ / unions (the coinductive fixture)

`node : TreeNode = μX. { value: integer, left: X | nil, right: X | nil }`. The path
`node.left` synthesizes via `index_result(TreeNode, "left")`, which unfolds the μ
once (equirecursive) → `TreeNode | nil`. The guard `if node.left then` refines the
path by the existing truthy decomposition (drop the `nil` member) → `TreeNode`. No
μ-specific machinery; the path-refinement applies to the unfolded field view,
consistent with the tag-discriminant μ-unfold (§6.2). `tree_sum(node.left)` then
reads `TreeNode` and `TreeNode <: TreeNode` accepts.

---

## Implementation

The narrowing CORE (`slice_narrow.lua`), the `Guard` grammar, the `narrow_guard`
evidence method (`crescent_slice.lua`), and the substrate (`init.lua`) are
**unchanged**. Three seams changed:

| Seam | File | Change |
|---|---|---|
| Recognition | `crescent_slice_parse.lua` | `path_of(node)` (depth-1 `x.f` → `"x.f"`); bare-truthy path in `recognize_guard`; path nil-eq in `recognize_cmp` (a nil literal is unambiguous — never a tag discriminant) |
| Lowering | `crescent_slice_lower.lua` | `path_split`/`path_pre_type` (path pre-type via `index_result`); the `if`-handler binds `"x.f"` as a synthetic Γ entry under a guard-ctx and refines the body ctx; `synth_index_expr` consults the path binding before the declared field read |
| Invalidation | `crescent_slice_lower.lua` | `node_has_call`/`stmt_invalidates_paths`/`invalidate_paths`; `lower_block` drops path bindings AFTER any invalidating statement |

Refinements stay derived claims — a path narrowing is a `narrows` claim with
`narrow_guard` evidence, identical to a variable narrowing, because the path is an
opaque name. The invalidation points are emitted by the lowering as the design
specifies.

---

## Validation

### Tests — full analysis suite green at 6489 assertions (6467 + 22 net)

`bin/cr test lib/type/analysis/` → 11 passed, 0 failed, **6489 assertions**. New
tests:

- **Positive cases** (`corpus_lower_test.lua` v2.7): bare-truthy path, and-guard path
  (the rehype_meta idiom), path read inside a call argument (the coinductive shape) —
  all CLEAN.
- **The invalidation fence (the soundness boundary made executable):**
  - refinement DIES after a call → the post-call read is correctly rejected (FINDINGS);
  - refinement DIES after a write-through (`o.g = nil`) → post-write read rejected;
  - refinement DIES after an alias write (`local y = o; y.f = nil`, §6.11.3) → the
    unsound read is rejected.
- **The coinductive fixture** (`corpus_lower_test.lua`): FINDINGS → CLEAN (0 markers,
  0 rejections). The 11-fixture honest split updated to 7 CLEAN / 0 FINDINGS / 4
  OUT-OF-SUBSET (was 6 / 1 / 4).

### Typecheck — clean on implementation files

`timeout 30 bin/cr check` on `crescent_slice_parse.lua` and `crescent_slice_lower.lua`:
**0 errors** (warnings are pre-existing missing-signature notes on nested closures,
unchanged from HEAD). The unchanged core files (`crescent_slice.lua`,
`slice_narrow.lua`) remain 0 errors.

### The acceptance corpus — the 11 round-4 false-positive files

Re-ran the e2e survey (`slice_survey.lua --e2e`, 867 files).

| Class | Baseline (HEAD `b4559472`) | Increment 7 | Δ |
|---|--:|--:|--:|
| CHECKED-CLEAN | 26 (3.0%) | 26 (3.0%) | — |
| CHECKED-FINDINGS | 13 (1.5%) | 16 (1.8%) | +3 |
| OUT-OF-SUBSET | 822 (94.8%) | 819 (94.5%) | −3 |
| NO-ANNOTATION | 6 | 6 | — |
| TIMEOUT | 0 | 0 | — |

**Files cleared: 1 — the coinductive fixture (FINDINGS → CLEAN), the §9.8 trigger
fixture.** It is in `lib/type/analysis/corpus/`, excluded from the 867-file survey,
so it is the headline acceptance result, not a row in the table.

**Three files moved OUT-OF-SUBSET → CHECKED-FINDINGS** (`agent/preset.lua`,
`unified/rehype_shift_heading/init.lua`, `unified/rehype_urls/init.lua`): field-path
narrowing unblocked their lowering past a prior out-of-subset marker, so they now
lower far enough to reach their NEXT boundary (cross-module `HastNode` alias /
visitor-callback `unknown` return), surfaced as a `type-mismatch`. Forward progress,
not a regression: the marker is a sound refusal (`emit_check_against` marks only when
`is_subtype` genuinely fails; 0 substrate rejections), and the narrowing itself
produces correct types (a direct probe — `if n.children then ipairs(n.children)` —
is CLEAN).

**The 11 round-4 files do NOT all clear: field-path narrowing was ONE of several
compounding root causes.** Each non-clearing file's next boundary, named honestly:

| File | Field-path narrowing helps? | Next boundary |
|---|---|---|
| `rehype_meta` | yes (idiom CLEAN in isolation) | cross-module `HastNode` alias + `el()`/`text()` unannotated-module-function returns (§6.8) |
| `rehype_document` | yes | same cross-module / unannotated-function family |
| `rehype_infer_title` | yes (`node.children`/`node.value` narrow) | same family + cross-module |
| `taskgraph/frontier` | n/a | cross-module `FrontierNode` value-type resolution (§9.10) |
| `type/v7_mr0/fixtures` | n/a | deeply-optional record literals / value-type resolution |
| `agent/render` | no (guards are `if v ~= nil` over a `pairs` loop var, not a path) | `pairs`-key typing + cross-module `val_to_str` |
| `base64url` | no | cross-module value-type abstention (§9.13) |
| `math/init` | no | closure check-mode synthesis abstention |
| `caps/kv`, `caps/time` | no | capability-closure / multi-return value-type abstention |
| `socket/init` | no | cross-module sibling-alias import (§9.11) |

The verified-in-isolation result is the honest evidence the narrowing is correct: the
rehype `if opts_t.title and …` idiom and the `if node.children then ipairs(…)` idiom
both check CLEAN when their cross-module dependencies are inlined; the residual
rejection is the cross-module / closure boundary, a separate un-defer.

---

## Deferrals recorded (§9.18)

- **Depth-2 paths (`x.f.g`)** — un-defer on a real guarded `x.f.g` read; strictly
  additive.
- **Call-invalidation relaxation** — un-defer on a purity/effects substrate
  (`docs/effects.md`) that proves a callee pure / a base un-escaped.
- **Readonly-field survival** — implemented in principle (the value-universe reading
  of the readonly marker); the acceptance test is a future readonly narrowed path.

## Summary

- **Invalidation rule chosen:** sound-conservative — a path refinement dies after any
  call (no escape analysis) and any write through any lvalue (aliasing undecidable),
  statement-level invalidate-after; readonly fields survive. The soundness boundary is
  made executable as three invalidation tests.
- **Files cleared:** 1 (the coinductive fixture, the §9.8 trigger fixture, FINDINGS →
  CLEAN). The 11 round-4 corpus files do not all clear — field-path narrowing was one
  of several compounding causes; each non-clearing file's next boundary is named.
- **New survey numbers:** CHECKED-CLEAN 26, CHECKED-FINDINGS 16 (was 13: +3 forward
  progress, files now lowering far enough to reach their true boundary), OUT-OF-SUBSET
  819 (was 822).
- **Findings count:** §9.18 of `docs/agnostic-static-analysis-crescent-slice.md`.
- **Artifact path:** `docs/artifacts/typechecker-run-2026-06-12/increment-7.md` (this
  file).
- **Tests:** 6489 assertions green; `timeout 30 bin/cr check` clean on implementation
  files. The narrowing core and substrate are unchanged.
