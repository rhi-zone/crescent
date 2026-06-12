# Slice v2 increment 8 — dependency-ordered alias declaration (the §9.8/§9.11 deferral)

Date: 2026-06-12. Base HEAD `9f396092` (increment 7, field-path narrowing). Design
§6.12; findings §9.19 of `docs/agnostic-static-analysis-crescent-slice.md`. This
increment un-defers the §9.8 / §9.11 two-phase-alias deferral ("forward/mutual alias
references require two-phase name-installation-then-parse") for its ACYCLIC case,
whose trigger has now fired with measured demand.

---

## Diagnose-first — what ranked first, and why

Both frontiers re-measured against HEAD `9f396092`.

**Precision frontier (the 16 e2e CHECKED-FINDINGS files).** Two of the 16 first
diagnostics are concrete, deterministic alias-resolution errors:
`lib/socket/init.lua` — `xmodule-alias-error` (`server_socket`'s body names
`server_client`, declared on a LATER line); `lib/tcp/client.lua` — `xmodule-alias-error`
via `lib/ljsocket`. Probing the corpus for the FORM — an alias whose body names a
SIBLING declared later in the same batch — found:

| Form | Refs | Files |
|---|--:|--:|
| Forward-sibling references (total) | 154 | 29 |
| — PURE-FORWARD (acyclic) | 63 | 16 |
| — CYCLIC (mutual) | 55 | 21 |

The acyclic 63/16 is a real, named, deterministic precision gap (aliases declared out
of dependency order with no cycle: `server_socket → server_client`; the
`Expr = ExprCall | ExprNeg | …` parent-union families; `DiceNode`/`NegNode`,
`HamtNode`/`HamtInterior`, `Block`/`Func`, …).

**Coverage frontier (the 819 OUT-OF-SUBSET files' top e2e tags).** `dynamic-index`
510, `multi-assign` 452, `multi-return` 317, `dynamic-index-assign` 284 — each a major
statement-lowering undertaking whose residue increments 5/6 already traced to upstream
precision (the integer-vs-number key gap on loop vars).

**The ranking.** Dependency-ordered alias declaration ranked FIRST on the
soundness-value × measured-demand product: it is a PRECISION fix that converts an
honest forward-reference ERROR into the CORRECT resolved type (never a wrong type), it
is the literal §9.8/§9.11 named deferral, and it clears the largest *named* precision
form measured (63 refs / 16 files). A competing precision candidate — the tuple type
`{ A, B }` (`ljsocket`'s `timeout_connected`) — has ≈1 corpus site and is deferred.
The coverage-frontier top forms are larger by raw file count but each is a major
lowering build with residue already known to be upstream-precision-bound, a worse
soundness-value-per-effort trade than closing a named precision deferral.

---

## The design (§6.12, derived whole)

**Source order is just ONE valid order.** It resolves a BACKWARD reference but not a
FORWARD one. The strictly-correct generalization is to declare each alias AFTER the
siblings it references — a **topological order over the intra-batch dependency
graph**. Pure graph topology, not a name-keyed handler:

1. **Edge set** = each decl's body's standalone-identifier tokens naming another decl
   in the same batch, EXCLUDING self (a self-reference is already μ-bound by
   `declare_alias`, §6.11/§9.7, so it is not a batch edge).
2. **Order** = DFS post-order with on-stack cycle detection. A back-edge (dependency
   currently on the DFS stack) is NOT recursed through, so a cycle member keeps its
   source position. Independent aliases tie-break on source order → a no-forward-ref
   batch reproduces today's order byte-for-byte.
3. **Declaration** = the unchanged per-alias `declare_alias` in that order; failures
   attributed to the SOURCE LINE via an input-index ↔ line map.

`declare_alias` is **byte-for-byte unchanged** — the change is the ORDER aliases are
fed to it, the same load-bearing pattern as §6.11.

**The soundness boundary (the fence).** A genuine mutual cycle (`A ↔ B`) cannot be
ordered into resolution: whichever member declares first names a not-yet-present
sibling and errors, exactly as today. The pass therefore NEVER silently binds a cyclic
family to a wrong type — it produces the SAME honest forward-reference error. The
principled fix for cyclic families is a multi-binder μ (a system of simultaneous
recursive type equations), a slice_ty substrate gap recorded as a deferral with the
now-measured trigger (55 refs / 21 files), never hardcoded.

---

## Implementation

Three seams, mirroring the import/scan split:

| Seam | File | Change |
|---|---|---|
| Order + batch-declare | `crescent_slice_parse.lua` | `alias_decl_order(decls)` (pure DFS topo) + `declare_aliases_ordered(env, decls)` (declare in that order, per-input-index results) |
| In-file aliases | `crescent_slice_lower.lua` | `scan_source` COLLECTS alias decls (with source line), then batch-declares in dependency order; failure markers attributed by line |
| Cross-module aliases | `crescent_slice_xmodule.lua` | `import_top_level_aliases` collects this module's batch and installs in `alias_decl_order`; the F1 cross-exporter collision check is unaffected by intra-module reordering |

---

## Validation

### Tests — full analysis suite green at 6501 assertions (6489 + 12 new)

`bin/cr test lib/type/analysis/` → 11 passed, 0 failed, **6501 assertions**. New tests
(`crescent_slice_test.lua`, `crescent_slice_xmodule_test.lua`):

- **Positive:** forward-sibling reference (`server_socket → server_client`);
  parent-union forward reference (`Expr = ExprCall | ExprNeg` with members below);
  cross-module forward-sibling import (`#errors == 0`).
- **Invariant:** an independent/backward-ref batch reproduces source order;
  `alias_decl_order` places a dependency before its dependent.
- **The fence (the soundness boundary made executable):** a genuine mutual cycle
  (`A ↔ B`) errors honestly — `T.fail(res[1].ok and res[2].ok)` — NOT silently
  resolved.

### Typecheck — clean on the three touched files

`timeout 30 bin/cr check` on `crescent_slice_parse.lua`, `crescent_slice_lower.lua`,
`crescent_slice_xmodule.lua`: **0 errors** (lower's 20 warnings are pre-existing
nested-closure missing-signature notes, unchanged from HEAD).

### Corpus effect (e2e survey, 867 files, honest numbers)

| Class | Increment 7 | Increment 8 | Δ |
|---|--:|--:|--:|
| CHECKED-CLEAN | 26 | 27 | +1 |
| CHECKED-FINDINGS | 16 | 15 | −1 |
| OUT-OF-SUBSET | 819 | 817 | −2 |
| NO-ANNOTATION | 6 | 8 | +2 |

- **`lib/socket/init.lua` moved FINDINGS → CLEAN** (rej=0, unk=0, 0 markers): it
  imports `lib/socket/server.lua`, whose `server_socket → server_client` forward
  reference now resolves under dependency ordering, clearing the only finding. The +1
  CHECKED-CLEAN and −1 CHECKED-FINDINGS.
- **Two files moved OUT-OF-SUBSET → NO-ANNOTATION** (+2 / −2): their own alias batch
  now resolves cleanly; the markers that blocked them are gone and no requested claim
  remains. Forward progress — alias resolution no longer blocks.
- **Annotation-grammar survey** (`docs/slice-survey-v1.md`, regenerated):
  CHECKED-CLEAN 489 (unchanged — that survey parses each annotation against a FLAT
  env, so the batch-ordering benefit surfaces in the e2e path), `unknown-type-name`
  collapsed bucket 152 → 151, OUT-OF-SUBSET 241 → 240.

**The non-clearing findings files are unchanged in cause.** Their next boundaries
(cross-module `HastNode`/`FrontierNode` value-type resolution, `el()`/`text()`
unannotated-function returns, `pairs`-key typing, capability-closure synthesis,
module-value-type abstention) are all unrelated to forward-sibling alias ordering, as
§9.18 already named. `lib/tcp/client.lua` still errors via `lib/ljsocket`'s
`LjSocket` — but the cause is the **tuple type `{ A, B }`** (`timeout_connected`), a
SEPARATE deferral (`LjSocket`'s `alias-error` is `{ T } list shorthand must be a
single type`, not a forward reference).

---

## Deferrals recorded (§9.19)

- **Cyclic (mutual) alias families — multi-binder μ.** Measured trigger fired (55
  cyclic refs / 21 files). slice_ty's μ is single-binder; a family of N
  mutually-recursive equations is a substrate gap. Un-defer: a multi-binder μ (a
  system of simultaneous recursive type equations). The cyclic case keeps the honest
  error until the substrate exists — never hardcoded.
- **Tuple type `{ A, B }` (fixed positional/heterogeneous list).** ≈1 corpus site
  (`ljsocket`'s `timeout_connected`), blocking `LjSocket` and transitively
  `tcp/client`. Un-defer: admit the `tuple` Ty kind (already in slice_ty for
  function params/returns) as a standalone table type at the annotation-grammar seam.

---

## Summary

- **Diagnosis ranked dependency-ordered alias declaration first** — 63 acyclic
  forward-sibling refs / 16 files, the §9.8/§9.11 named deferral, a precision fix
  converting an honest error into the correct type.
- **Derived whole:** topological declaration order (pure graph topology, `declare_alias`
  unchanged); genuine cycles stay an honest error behind the multi-binder-μ deferral.
- **Per-item status:** forward-sibling acyclic case — DONE (in-file + cross-module);
  cyclic-family case — deferred (substrate gap, 55/21 trigger recorded); tuple type —
  deferred (≈1 site).
- **Survey movements:** e2e CHECKED-CLEAN 26 → 27, CHECKED-FINDINGS 16 → 15,
  OUT-OF-SUBSET 819 → 817 (`lib/socket/init.lua` cleared). Annotation survey
  `unknown-type-name` 152 → 151, OUT-OF-SUBSET 241 → 240.
- **Findings:** §9.19 of `docs/agnostic-static-analysis-crescent-slice.md`.
- **Tests:** 6501 assertions green; `timeout 30 bin/cr check` clean on the three
  touched files.
- **Artifact path:** `docs/artifacts/typechecker-run-2026-06-12/increment-8.md`.
