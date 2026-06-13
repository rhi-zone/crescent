# Adversarial re-verification of the variance soundness fix

Date: 2026-06-14. Target: commit `cdc5b2a6` ("close covariant write-through
unsoundness via check-mode construction + invariant mutable-field subtyping").
Design under attack: `docs/agnostic-static-analysis-crescent-slice.md` §6.14;
original repro: `docs/artifacts/typechecker-run-2026-06-12/critique-soundness.md`
claim 5. Execution-led: every verdict below is a real run of
`crescent_slice_lower.lower → A.check` over scratch source (the identical
reduction to `corpus_lower_test.lua`). Nothing in `lib/` was modified. Driver:
`/tmp/reverify.lua`, `/tmp/reverify2.lua` (run with `bin/cr run`).

## Verdict: INVARIANT RESTORED. No hole found.

Every write-through attack class rejects; every sound construction stays CLEAN;
the full `lib/type/analysis/` suite is green (11 files, 10952 assertions, 0
failed). The §6.14 soundness argument's load-bearing premise — construction is
fresh ⇒ covariant per field is sound — holds because an *embedded existing
reference* is never treated as fresh: it falls to the invariant subtype path.

## The §6.14 argument, and the exact hole it had to avoid

The fix decouples construction (check-mode, covariant per field — sound because
the literal is fresh, single-reference) from aliasing (subtype, invariant in
every mutable field). The soundness rests on: a fresh literal has no prior alias.
The sharpest attack (the prompt's prime suspect) is that a fresh literal can
*embed a pre-existing alias* as a field value, re-creating the write-through one
level up — `local outer: {g: NumBox} = { g = ib }` with `ib : IntBox`, then
`outer.g.f = x`, then read `ib.f`.

**Mechanism (read from `crescent_slice_lower.lua`):** `check_table_expr`
(`:2058`) checks each field value by recursing through `check_expr` (`:2101`).
`check_expr` (`:2158`) routes a **`table`-node** value to covariant
`check_table_expr` (`:2168`), but **everything else — including a bare `var`
node — falls to the `else` branch (`:2181`): `synth_expr` + `emit_check_against`
= the invariant subtype path.** So covariant construction applies only to a
field value that is *itself a literal*; an embedded *variable* is synthesized to
its own type and checked by `subtype(synth, expected_field_ty)`, where mutable
fields are now invariant. The embedded alias never enters the fresh/covariant
regime. The freshness premise is preserved syntactically: only `table` nodes
are fresh.

## Attack 1 — embedded alias in construction (THE prime suspect)

| Probe | Shape | Verdict | Marker |
|---|---|---|---|
| `A1a_embed_existing_alias` | `local outer:{g:NumBox} = { g = ib }`; `outer.g.f = x`; `return ib.f` | **FINDINGS (REJECT)** | type-mismatch |
| `A1b_embed_fresh_nested` | `{ g = { f = someint } }` (genuinely fresh nested literal) | **CLEAN** | — |
| `A1c_embed_alias_same_type` | `{ g = ib }` against `{g: IntBox}` (no widen) | **CLEAN** | — |
| `A1d_embed_alias_no_outer_write` | `{ g = ib }` against `{g: NumBox}`, no write | **FINDINGS (REJECT)** | type-mismatch |

`A1a` is the suspected hole. It **REJECTS**. `A1d` proves *why*: the rejection
fires at the construction site (embedding `ib:IntBox` into a `{g:NumBox}`
literal), independent of any later write — exactly the invariant subtype path
catching the embedded existing reference. `A1b` proves the genuinely-fresh case
is correctly distinguished and stays CLEAN. `A1c` proves a same-type embed is
fine. **The distinction between "fresh nested literal" (CLEAN) and "embedded
existing variable" (REJECT) — the whole question — is drawn correctly.**

### Mechanism-confirming controls (`/tmp/reverify2.lua`)

| Probe | Shape | Verdict |
|---|---|---|
| `B1_embed_alias_equal_type` | embed `nb:NumBox` into `{g:NumBox}` (mutually-sub) | **CLEAN** |
| `B2_fresh_nested_widen_value` | `{ g = { f = someint } }`, `integer <: number` value | **CLEAN** |
| `B3_deep_fresh_literal_inner_alias` | `{ g = { h = ib } }` against `{g:{h:NumBox}}` | **FINDINGS (REJECT)** |
| `B4_field_read_then_alias_write` | `local nb:NumBox = h.b`; `nb.f = x`; `h.b.f` | **FINDINGS (REJECT)** |

`B1` proves `A1a` rejects for *variance*, not because any embedded var rejects.
`B2` proves covariant construction with a widening value (`integer<:number`)
is preserved (sound — fresh literal). `B3` is the decisive depth probe: the
outer and the middle are both fresh literals (covariant), but the `ib` variable
at the bottom still hits the invariant subtype path — covariant construction
does **not** leak through nested literals to relax an embedded variable. `B4`
closes the field-read-alias form (`h.b` aliased and written).

## Attack 2 — original direct repros still closed

| Probe | Verdict | Marker |
|---|---|---|
| `A2_FN_widen_alias_write` (`nb.f = 1`) | **FINDINGS (REJECT)** | type-mismatch |
| `A2_FN_widen_alias_write_numvar` (`nb.f = x`) | **FINDINGS (REJECT)** | type-mismatch |

Both critic repros that were CLEAN false negatives at the critique commit now
REJECT. (Also pinned as permanent regression tests in
`corpus_lower_test.lua:1261,1276`.)

## Attack 3 — other missed write-through paths

| Probe | Path | Verdict | Marker |
|---|---|---|---|
| `A3a_indexer_alias_write` | `{[string]:IntBox}` widened to `{[string]:NumBox}`, `nm[k].f = x` | **FINDINGS (REJECT)** | type-mismatch |
| `A3b_nested_alias_write` | record-in-record alias `mn.b.f = x` | **FINDINGS (REJECT)** | type-mismatch |
| `A3c_param_alias_write` | pass `IntBox` where `NumBox` param expected, write through param | **FINDINGS (REJECT)** | type-mismatch |
| `A3d_return_embed_alias` | `return { g = ib }` against `{g:NumBox}` return | **FINDINGS (REJECT)** | type-mismatch |
| `A3e_callarg_embed_alias` | `sink({ g = ib }, x)` then read `ib.f` | **FINDINGS (REJECT)** | type-mismatch |

Indexer-value invariance (`A3a`), multi-level depth (`A3b`), parameter aliasing
(`A3c`), and return-position + call-arg construction embedding an alias
(`A3d`/`A3e`) are all closed. Invariance propagates at every depth.

## Attack 4 — no over-correction (sound construction stays CLEAN)

| Probe | Shape | Verdict |
|---|---|---|
| `A4a_literal_widening` | `{ id = "root", done = false }` against `{id:string, done:boolean}` | **CLEAN** |
| `A4b_nested_literal_widen` | `{ g = { f = 1 } }` against `{g:{f:number}}` | **CLEAN** |

Plus the 5 named construction fixtures (`local_return_narrowing`,
`union_alias_over_named_types`, `coinductive_recursive_types`,
`closure_param_typing`, `table_construction_widening`) — all exercised by
`corpus_lower_test.lua` (321 passed), independently confirmed CLEAN. Direct
literal widening (`"root" <: string`, `false <: boolean`, `1 <: number`) is
preserved: construction is covariant, as designed.

## Suite

```
$ bin/cr test lib/type/analysis/
  pass corpus_lower_test.lua (321)   corpus_test.lua (40)
  pass crescent_slice_test.lua (269) crescent_slice_xmodule_test.lua (78)
  pass dataflow_test.lua (36)        lambda_test.lua (20)
  pass prop_test.lua (24)            slice_narrow_test.lua (32)
  pass slice_subtype_test.lua (10059) stlc_test.lua (45) substrate_test.lua (28)
  11 passed, 0 failed, 11 total  (10952 assertions)
```

## Conclusion

The bug class is **closed**. The fix's soundness argument survives the prime
attack: the embedded-existing-alias-in-construction case **rejects** because an
embedded variable is routed to the invariant subtype path, never the covariant
construction path — the freshness premise (only `table` nodes are fresh) is a
real syntactic invariant, not an assumption. All write-through paths probed
(direct alias, indexer alias, nested/multi-level, parameter alias, return-
position and call-arg construction embedding an alias) reject. Sound covariant
construction (direct literal widening, fresh nested literals) is preserved with
no over-correction. **INVARIANT RESTORED.**
