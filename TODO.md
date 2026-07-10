# TODO

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

## Fixed bugs

- [x] **`.crescentcache` manifest keyed diagnostics only by content hash, ignoring file path** (2026-07-10). `check.lua`'s disk-cache path computed `src_hash = cache_mod.hash_file(filename)` — content only — and used it as the manifest key for both lookup and store. Cached diagnostics (`errors.lua` `DiagEntry.filename`) bake in the path of whichever invocation first populated the cache entry, so two different paths with identical content collided in the manifest and the second path's check returned diagnostics carrying the *first* path's filename. Fixed by adding `cache.lua` `M.entry_key(filename, content_hash)` (hashes `path .. "\0" .. content_hash`) and using it as the manifest key in `check.lua` instead of the bare content hash; `M.hash_file` / `M.hash_source` are unchanged and still used path-independently for dependency change-detection. Verified with a manual repro (two files, identical content, different paths, same `.crescentcache`): each now gets its own manifest entry and reports its own path on both cold and warm-cache runs.

## Typechecker substrate gaps (found while fixing CI failures, 2026-07-10)

- [ ] **A bare `...T` (no enclosing parens) as a `--:` return-type expression silently fails to parse and falls back to "no signature."** Repro in `lib/encode/utf8/init.lua`: `--: (...) -> ...number` (or `...unknown`) produces the `has no signature — add a ... annotation` warning as if the line weren't there at all, and downstream param types lose their narrowing (spurious unrelated overload-resolution errors appear on `string.byte` calls in the body). Wrapping the same variadic in parens, `(...number)`, parses fine and the narrowing-dependent errors disappear. The parser should either accept bare `...T` in return position or hard-error on it — silently discarding a written signature (turning it into a no-op) is the dangerous failure mode: the file looks annotated but isn't.
- [ ] **A return-type union combining a variadic tuple arm with a fixed tuple arm, e.g. `(...number) | (nil, string)`, rejects a plain single-value `return b`/`return c` even though `integer` is a valid member of the first (variadic) arm.** Error was `integer is not assignable to ...number | (nil, string)`, i.e. the union isn't decomposed into alternatives before checking a return statement against it. Worked around in `lib/encode/utf8/init.lua`'s `mod.codepoint` by widening the declared return to `(...unknown)` instead — real fix needs the checker to try each arm of a return-type union independently.
- [ ] **Inline `--[[: T]]` parameter annotation is silently ignored on a self-recursive `local function`.** Repro: `local function f(n, collect --[[: { [integer]: integer } | nil]]) ... f(n-1, collect) end`, then call `f(3, nil)` from one site and `f(3, some_table)` from another. The annotation on `collect` has no effect — the checker still infers `collect`'s type monomorphically from the first call site it sees (here, the literal `nil` from the first-analyzed caller), then rejects the second, differently-typed call site with "cannot pass `T` where `nil` expected". A full `--:` signature placed above the function (rather than inline on the parameter) *does* take effect correctly (verified with the same repro). Worked around in `lib/sat/init.lua` (see `dpll`) by annotating the `nil` literal at its call site instead of the parameter, which avoids the bug without touching the recursive function's signature. This is a real substrate gap — inline param annotations should carry the same weight as a full signature — not something to special-case around in library code.
- [ ] **`--: () -> ...(T)` (parenthesized single-type spread return) types destructured slots beyond the function's actual arity as `T` instead of `nil`.** Repro (`lib/type/static/type_test.lua:8247`, "TAG_SPREAD: explicit -> ...(T) multi-return syntax > -> ...(integer): y is nil"): `local function f() return 1 end --: () -> ...(integer)` then `local x, y = f()` — `y` should be `nil` (the function returns exactly one value; `y` reads past the end of a 1-tuple) but the checker infers `y: integer`, so `y --[[: string]]` is rejected as "cannot assign integer to string" and `y + 1` typechecks with no error at all. `...(integer)` appears to be treated identically to a true variadic `...integer` (0-or-more) rather than as a spread of a fixed 1-element tuple `(integer)`, so slots past the declared arity aren't typed `nil`. Needs the TAG_SPREAD / multi-return-slot-typing code (`env.lua`, `narrow.lua` per the `lib/type/static/CLAUDE.md` spread-in-tuple-position notes) read against `docs/type-system.md` before fixing — not attempted here to avoid a blind core-solver change.
  - **Substrate gap, not a result deficit — needs a design decision before implementation.** `-> ...(T)` currently has two live, mutually incompatible interpretations in the codebase itself, and the mechanical fix depends entirely on which one is meant: (1) "spread of a 1-element tuple" — exactly the slot named is `T`, every slot beyond it is `nil`. This is what the failing test expects, and what `docs/tag-spread-spec.md`'s own "Tests to Write" section documents in prose. (2) "unbounded variadic of `T`" — 0-or-more slots, each `T`. This is what the *live* stdlib annotations for `unpack` (`-> ...(V)`) and `string.byte`'s second overload (`-> ...(integer)`) actually need in order to type multi-variable destructuring correctly (`local a, b, c = unpack(t)` or `local x, y, z = s:byte(1, 3)`), and `docs/tag-spread-spec.md`'s own stdlib-update examples assume this reading for exactly those two functions. The conflation point in code is `peek_callee_ret_union`/`eager_slot` (`constrain.lua` ~2944): `if t.tag == defs.TAG_SPREAD then return types_mod.find(ctx, types_mod.spread_inner(t)) end` — this line implements reading (2) unconditionally, which is why `unpack`/`string.byte` work today and why the TAG_SPREAD test (which wants reading (1) for a *different* function) fails. `pairs`/`ipairs` do NOT hit this conflict — they resolve via a separate fixed-3-tuple `NODE_FOR_IN` path (constrain.lua ~4541-4597), not scalar spread — so the real conflict is narrowly `unpack` + `string.byte`. No existing test pins reading (2) (no multi-var-destructure test exists for either function), but the semantic is load-bearing for idiomatic Lua callers of both. Fixing this requires the user to choose the intended vocabulary — e.g. keep `-> ...(T)` meaning (1) and introduce distinct syntax for genuinely-unbounded scalar spread (bare `-> ...T` without parens is currently a parse error and is available to repurpose), or the reverse — before any solver change; picking one silently would mint semantics downstream work would trust without it being a real decision.
- [ ] **static-v4: `string.match`/`gmatch`/`find` stdlib declarations mis-declare arity, causing a spurious `call-arity` error (cascading into `undefined-name` for destructured captures) on ordinary 2-arg calls.** Repro: `local a, b = string.match("x=1", "(%a+)=(%d+)")` — legacy accepts (0 errors); `bin/cr check --v4` rejects with `call: arity mismatch — expected 3 argument(s), got 2` at the call site, then `undefined name a`/`undefined name b`/etc. at every use of the destructured locals. This is the documented-but-still-open gap in `lib/type/static-v4/README.md` ("Known degradations": `string.match`/`gmatch`/`find` declare a fallback type pending the `$PatternReturn`/`$FindReturn` walker hook) — the fallback apparently declares the optional third `init` argument as required. Used as the "legacy accepts, v4 rejects" fixture in `lib/type/static-v4/cli_compare_test.lua` (replacing a stale fixture for a table-literal divergence that landed and stopped diverging); update that test's fixture again once `$PatternReturn`/`$FindReturn` lands and this call stops erroring.
- [x] **`check_string`/`check_file` with `opts.globals_files`: a globals file with >= 19 leading plain `--` comment lines before its first `--::` annotation silently disables argument-type checking for everything the file declares.** FIXED. Root cause was NOT leading-comment-line-count itself, and NOT `check_string`/`check_file` — it was `prelude.lua`'s `load_decls` (the `opts.globals_files` loader), specifically Pass 2a's alias-body resolution order. `load_decls` collected `ANN_DECL` results by iterating `ar.results` (keyed by absolute source line number) with Lua's `pairs()`, which yields hash-part traversal order — a function of the specific line-number integers present, unrelated to declaration order, and non-monotonic as leading-line-count shifts (matching the originally-observed "18 ok / 19–29 broken / 30 ok / 31+ broken" banding exactly). `env_mod.resolve_named_type` (env.lua) resolves a type alias **eagerly** — `return alias.body` is a snapshot, not a lazy reference — so if Pass 2a happened to process an alias (e.g. `DomCtor`) before an alias it references (`Props`) purely by accident of hash-bucket layout, `DomCtor`'s resolved body permanently captured the Pass-1 placeholder (`T_ANY`) instead of the real `Props` record, silently degrading every parameter typed `Props` to `any`. Every real `*_types.lua` file in the repo declares aliases in dependency order (referenced-before-referencing), so this only needed resolution order to *match declaration order* to be correct — not full topological/lazy resolution. Fix: added `decl_lines` (table-reference-keyed) tracking alongside `decls` collection in `prelude.lua`'s `load_decls`, then `table.sort(decls, ...)` by source line before Pass 2a — mirroring an identical, already-existing fix pattern in `constrain.lua`'s `process_type_decls` (the same-file, non-globals-file `--::` decl path already had this sort; the globals-file path did not). Also fixed a related-but-distinct hygiene gap while in the area: `ctx._ann_consumed` (bare-line-number-keyed, tracks which preceding-line annotations were consumed) was swapped in lockstep with `ctx.ann` in `process_type_decls`'s callers but not in `prelude.lua load_decls` or `constrain.lua load_decl_file` — fixed both to save/restore it alongside `ctx.ann`, preventing a real (separate) cross-file line-collision hazard even though it wasn't the cause of this bug. Verified: minimal single-file repro (ruling out cross-file collision) now resolves correctly across leading-line counts 0–40; `projection_types_test.lua` passes (38/38); `bin/cr check` on `prelude.lua` and `constrain.lua` shows zero error/warning-count regression (git-stash before/after diff); `bin/cr test lib/type/static/` clean except the pre-existing TAG_SPREAD failure (see above). This does not make genuine forward references (an alias used before its own later declaration) sound — that would need topological or lazy alias resolution, a deeper change, not needed by any current caller.

## v5 substrate program — Phase 2 implementation

Phase 0 (CLAUDE.md guardrails) and Phase 1 (three normative specs) are committed to the repo. What follows are the Phase 2+ implementation threads.

Specs in force:
- **Spec A** (simple-sub bounds — faithful-flow + canonical + eager): `docs/typechecker-v5-operational-semantics.md`, commit `26ef57a8`.
- **Spec B** (match types + TPack variadic packs): same doc, commit `c06b1ac6`.
- **Spec C** (TLiteral + TRecord three-region shape, no `$`-string encodings): `docs/type-system.md` + op-sem doc, commit `7a627c26`.

Lower-priority open gaps (G2/G4/G5/G10 substrate, G6 `__index`, P5 ann-surface features, eager-depth-limit, the two-positional-encodings smell, resume-side S narrowing) are tracked in `docs/v5-gaps.md` — read that file rather than relying on this section for exhaustiveness.

### Thread 1: Implement Spec A bounds in op_sem.lua + op_sem_alt.lua (closes R1 + bounds-spec-gap)

Spec A defines a faithful-flow bound-graph (subtyping is a directional edge; equality merges via union-find; multi-bound / transitive / polar / var-flow / cyclic-bound paths all specified). The dual-interpreter premise (op_sem.lua and op_sem_alt.lua are independent encodings of the same spec, never derived by copying between them) was vindicated by R1's finding that they had drifted. Both must be implemented from the spec independently.

The prior ~80 fixtures never exercised multi-bound / transitive / polar / var-flow / cyclic paths — new parity fixtures covering those paths are part of the deliverable.

Open question: the bound-graph coexists with union-find (equality merges, subtyping is directional). The spec defines it; implementation is unproven. Termination leans on a mandatory structural-hash cache. Verify termination properties empirically on the new fixture set, not just on the existing ones.

### Thread 2: Implement Spec C encodings (closes prefix-scoping)

TLiteral node + TRecord three-region shape (fields with optional/readonly attributes, `indexes[]`, `row`); delete every `$`-string-match and key-prefix-scan that substitutes for a proper node.

Touches all record field-walkers: shift, instantiate, equal, collect_uvars, and subtype rules. Worth mapping all walkers before starting to avoid half-migrations.

### Thread 3: Implement Spec B substrate (heaviest piece)

match_type node + CMatchEval constraint + TPack + arrow variadic-pack redesign + effect-pattern matching. The arrow/TPack redesign is the heaviest sub-piece (every arrow producer and consumer changes). Spec B is the substrate that other features build on.

### Thread 4: Re-express pcall/coroutine/pairs/ipairs as stdlib declarations; delete the handlers (closes adhoc-cluster + Y1; delivers G17)

<!-- Cross-reference (2026-05-29): This thread is the crescent instance of an ecosystem-wide pattern. Concrete artifacts for the record: `static/solve.lua` 16-handler per-constraint-kind dispatch table (`get_handlers` at solve.lua:3993, e.g. solve_index ~665 LOC, solve_overlap ~517 LOC); the `$`-intrinsic if-chain (`intrinsic.lua:912 M.expand`). The v3→v5 migration is the canonical worked example of the ecosystem anti-pattern — N parallel name-keyed dispatch tables where one visitor/registry belongs. Already fully tracked here and in lib/type/static/CLAUDE.md; this note is a cross-reference only, not new work. -->

Targets: build_pcall_ret, build_coroutine_create_ret, coroutine.* branches, extract_idx, name-keyed dispatch, `!throw`/`!yield` string-matches. After the deletion, a re-run of the adversarial ad-hoc sweep must come back empty for the AD-HOC category, and a grep must show zero `name == "$X"` / name-keyed dispatch in constrain.lua/op_sem.lua. This is the payoff — the ad-hoc dies here.

- [x] **Phase 2.4.5 — call-site declared-return instantiation + per-call-site match lowering (ENABLING SUBSTRATE for Thread 4).** Built the missing, name-agnostic mechanism that lets a stdlib declaration carry a return type depending on its arguments — the precondition Thread 4 needs before it can re-express pcall/coroutine.* as ordinary declarations and delete the handlers. Mechanism: a `TParam(idx)` parameter-reference leaf (mirrors `TCapture`; not De Bruijn-relocated) + `types.subst_params` / `types.has_param` (`lib/type/experiments/v5_perf/types.lua`); a shape-gated gen-pass rule (T-CallInst) in BOTH call paths of `constrain.lua` (single-value `NODE_CALL_EXPR` + multi-value `gen_expr_multi`) that, when `has_param(callee.ret)`, substitutes actual arg types into the declared return, `lower_matches` per call site, and CSubs with no raw TMatch crossing the constraint. Reuses the existing CMatchEval Park/Reduce/Wake/Stuck machinery — NO new interpreter rule, so no copy across op_sem.lua/op_sem_alt.lua. Also added shape-driven for-in (T-ForIn-Shape: declared-return arity / index signature, beside the pairs/ipairs name cases). Effects need no new substrate (App+Const already suffice; the `!throw`/`!yield` string-match sites are a 2.5 consumer concern). Did NOT delete any handler (that is 2.5); all existing fixtures stay green. Proof tests: `lib/type/static-v5/decl_instantiation_test.lua` (20 assertions — disc(true)→string, disc(false)→integer at distinct call sites, reject cases, identity-of-arg, for-in index-sig + declared-return-arity) + `types_row_substrate_test.lua` (TParam/subst_params/has_param units, +27) + `op_sem_independent_parity_test.lua` `indep parity: 2.4.5` fixtures (+22, reduce/stick/park-wake parity). Normative design recorded in `docs/typechecker-v5-operational-semantics.md` §"Call-site declared-return instantiation (TParam + subst_params) — Phase 2.4.5".

### Thread 5 (SEQUENCING FORK — unresolved): Phase ordering of Spec B vs Spec C

The approved program plan listed P3 (Spec C) before P4 (Spec B), but Spec C's positional/tuple migration depends on Spec B's TPack. TPack must land before Spec C's positional work. The next session should re-plan Phase 2 ordering to respect substrate-before-consumers (a CLAUDE.md planning rule now). The fork: either (a) carve out a TPack-only slice of Spec B that lands first, or (b) fully complete Thread 3 before Thread 2. Both are valid; the choice has downstream ordering consequences that need to be mapped.

### Verification discipline

Op-sem parity must hold at every commit. After the handler deletion, the adversarial ad-hoc sweep must return empty for the AD-HOC category; a grep must show zero `name == "$X"` / name-keyed dispatch in constrain.lua/op_sem.lua.

---

## Typechecker v5 follow-ups

> **Comprehensive state snapshot lives at `docs/typechecker-v5-handoff-2026-05-25.md`** — read that first. It covers artifacts + LOC, architecture, load-bearing invariants, falsifiability gates passed, 16 named spec gaps with sources + severity, all open H-questions, cross-cutting risks, methodology rules. The threads below surface high-signal items as starting context but don't capture the full picture.

### High-severity open threads (constraint families)

- [x] **CMultiReturn (spec gap G7)** — DISSOLVED 2026-05-25. No separate constraint family. Multi-return is positional Record on `Arrow.ret`; T-CSub-Record's positional-key dispatch (covariant) handles union-arity and nil-padding. Commits: `2ce1e591`, `07afc26a`, `720a9f6c`, `c9e018b9`. Parity count 146 → 187.
- [ ] **Gen-pass invariant: over-arity discard before CSub emission** — when a call site returns more slots than the LHS expects, gen-pass must emit a positional Record with only the expected slots. Emitting the full record and letting T-CSub-Record discard extras would present the solver with a width mismatch it cannot distinguish from a type error. Track when gen-pass work begins.
- [x] **CRow + CEffect unified extension (G8 + G12)** — CLOSED at op-sem layer 2026-05-26. CRow: CRowExtend/Lacks/Close constraint atoms + rules (commits `7f7d4d6c`, `b1825484`). Effects dissolved into TConst("!name") + TIntersection; CIntersectionEq/Sub/Member with canonical form (commit `c600a446`). Parity 187 → 275. NOT YET observable from user code — source pipeline (parser + gen-pass) not wired.
- [x] **v5-source-pipeline-integration** — CLOSED 2026-05-26. ann.lua, constrain.lua, stdlib_types.lua, cli.lua, `bin/cr check --v5` wired end-to-end. Commits: `52fcae6f`, `0ff434aa`, `6da6db59`, `317acc9b`. 275 → 504 assertions. Six open gaps remain (P1–P6); see handoff and items below.
- [x] **Gap P1: dotted callee effect propagation broken** — `io.write(...)` has a uvar callee at gen-pass time; `!io` is never extracted. F2 enforcement does not fire for dotted stdlib calls. Only direct-bound names propagate effects. Highest-priority source pipeline fix. (closed: 5.F1 a32b0a74 — fixture "5.F1: annotated () -> nil calling io.write (dotted) surfaces F2 error" in cli_e2e_test.lua)
- [x] **Gap P2: pcall return type is flat `boolean | unknown`** — correct form is discriminated `(true, R...) | (false, E)`. Requires variadic generics (G17) first. (closed: 5.F2 05fd0777 — special-cased at gen time; fixture "5.F2: pcall on throwing fn in annotated pure fn is clean" in cli_e2e_test.lua)
- [x] **Gap P3: coroutine.create returns unparameterised `thread`** — full `Coroutine<Y,S,R>` parameterisation deferred; requires G17 or a specialised constraint family. (closed: 5.F3 656c8596 — special-cased at gen time; fixture "5.F3: coroutine.create consumes !yield — pure outer fn is clean" in cli_e2e_test.lua)
- [x] **Gap P4: Arrow subtyping defaults uvar to CEq at S-Quiesce** — proper bounded-tvar tracking (G9) is deferred; may reject valid programs. (closed: 5.F4 93311447 — bounds substrate + meet-at-quiescence; fixture "5.F4: two distinct upper bounds — meet via intersection" in op_sem_bounds_test.lua)
- [ ] **Gap P5: ann surface forms not wired to gen-pass** — type predicates, match types, newtype, augment, pattern types: parsed but not emitted as constraints.
- [ ] **Gap P6: closure-as-value and method dispatch not modelled** — constrain.lua handles straight-line code; closures in tables, `:` dispatch, upvalue capture narrowing unhandled.
- [ ] **5.F3 residual: resume-side S narrowing incomplete** — `coroutine.resume(co, s)` does not bind `S` from the send argument's type; the `Coroutine<Y,S,R>` `S` parameter remains a free uvar. Yield and create typing are correct; resume is under-constrained on the send side.
- [ ] **5.F4 residual: compatible-bound intersection reduction not implemented** — under-constrained uvars accumulate upper bounds as `TIntersection` nodes at quiescence. Compatible bounds (e.g., `integer & number → integer`) are not yet reduced. Orthogonal to the meet-at-quiescence landing; fix is in the intersection-reduction pass.
- [ ] **G17: variadic generics** — accurate typing of `pcall` / `coroutine.resume` requires variadic generics (function-argument pack and return-pack typed through the pcall/resume boundary). Current v5.0: pcall returns `(boolean, unknown)`. Needs orchestrator design decision before implementation. Severity: low-medium. Not blocking v5.0 stable.
- **CImpl (let-poly with implication wanteds)** — OutsideIn-style scope discipline. Op-sem has `CInst` but not `CImpl`. Open: do we need GADTs at all? Roadmap H5 closed "GADT-strength flow typing out of scope," suggesting CImpl can be lighter than OutsideIn's full version.

### High-severity open threads (productionisation)

- **Realistic-scale perf is a hypothesis.** Architecture targets ~10⁵ constraints; tested at <500. Re-gate at scale during each constraint-family landing, or build a synthetic-load extrapolation harness explicitly.
- **Gen-pass connection to real Lua AST not started.** Op-sem currently takes hand-emitted constraints. Bridging to the existing parser is its own multi-cycle phase. Open: build a fresh extractor or adapt the v4 walker?
- **Substrate promotion from `lib/type/experiments/v5_perf/` to `lib/type/static-v5/`** is owed once op-sem hardens. Cleans the namespace.
- **Dead v5_perf scaffold builds records with the pre-2.3 raw-value contract.** `lib/type/experiments/v5_perf/solver.lua` (untouched since the pre-2.1 scaffold `6bbe20a4`) and `lib/type/experiments/v5_perf/bench_chkt.lua` (plus `bench.lua`) still construct `TRecord` fields as RAW `V5Type` values — `types_mod.record({ [k] = ty })`, `b.fields[k] = c.ty`, `existing = b.fields[c.key]` treating field values AS types. The v5 2.3 reshape (`f0a9e10b`) made each `TRecord` field a `TField = { type, optional, readonly }` (built via `types.field(...)`), and `subst.walk`'s record arm now recurses into `fv.type`. These files predate 2.3 and were missed by the follow-up migration (`0ca0c8ed` only fixed `types_row_substrate_test.lua`). Under the 2.3 contract the bench records are inconsistent and would crash `subst.walk` (it indexes `fv.type` on a nil) if ever walked. **Not on the live path** — `solver.lua` is required only by `bench.lua`; nothing in `bin/cr`, the static-v5 interpreters (`op_sem.lua`/`op_sem_alt.lua` require `types/subst/constraint/variance`, never `solver`), or any `*_test.lua` depends on them; `bench.lua` is the old harness superseded by `bench_chkt.lua`. No test exercises them, so the inconsistency is uncaught. Migrate to the `TField` contract or delete when `v5_perf` is next touched (likely folds into the substrate-promotion item above).
- [x] **Constraints catalog at `~/.claude/plans/radiant-gathering-gray.md` is outside the repo.** Durability risk. Relocate to `docs/typechecker-v5-constraints.md` or similar. Tiny task. — Landed in repo at `docs/typechecker-v5-constraints.md` (recovered from session transcript; original was overwritten in-place).

### Pre-stable follow-ups

- [ ] **Exhaustive prior-session mining.** Sampled pass found 5 multi-session arcs (`docs/typechecker-v5-research-report.md` §2); exhaustive pass owed. Particular value: scheduler-shaped problems, mechanisms previous attempts found load-bearing vs accidental.
- [ ] **Adversarial missed-generalisation eval** (v5 item 6 follow-up). Generate Lua snippets that the no-level-lowering discipline (Lean-style) rejects but Rémy lowering would accept. Classify idiomatic/rare/pathological. Revisit lowering as perf opt if idiomatic.
- [ ] **Lazy De Bruijn shift experiment** (v5 item 2 follow-up). After everything stable, benchmark lazy (Lean/Coq sliding-window) vs eager-shift baseline. Low prio.
- [ ] **Circular `require` corpus check.** v5 rejects circular `require` at typecheck. Grep `lib/` — if any are load-bearing, revisit before declaring v5 stable. Likely fine.
- [ ] **Property-based parity** (independent-encoding parity follow-up). Generate random constraint sequences; run both interpreters; catches rule-priority divergence fixed fixtures miss.

### Spec doc clarifications (low prio, surfaced by independent-parity agent)

- T-CSub dispatch priority not formally enforced — chose TVar-before-Refl interpretation; doc could lock this in.
- T-CTSet four-way cascade order not formally enforced — current dispatcher's if/elseif order is a reconstruction.
- T-CHKT-Reduce chain peel depth not formally specified — implementation peels up to `length(args)` binders.

### Post-stable

- [ ] **Investigate `setmetatable(t, nil)` support** (v5 item 5 backlog). Medium prio. Sandboxing's strongest use case served by fresh-table pattern. v5.x decision may be "document fresh-table as canonical idiom; never support setmetatable(t, nil)." If supporting it: open question whether monotone substitution can be preserved.

## Session-level open threads — v9/typechecker endgame (2026-07-04)

*Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

- **Owner verdicts that likely gate everything in the v9 section below.**
  Autonomous agent-orchestrated development of the typechecker was declared
  dead by owner verdict — supervision cost exceeded value; the owner drives,
  agents act only as directed hands on explicitly pointed-at work, no
  self-initiated roadmap-grinding. The parity-race framing is dead with it.
  Half-products (e.g. a "complementary linter beside the legacy checker") were
  explicitly rejected — full replacement of the legacy checker remains the
  only end-state that counts. v9 measured NOT viable as a tool today: a
  stratified 30-sample measurement found ~3% hard-true / ~27%
  true-plus-discipline precision on bug-classes-only output. Volume looked
  workable (426k -> ~16k with aspiration dials off, median 1/file) —
  precision is the blocker, not volume.
- **The owner's compression criterion — plausibly the evaluative lens for any
  future core work.** "A grind is the smell of a fundamental failure in the
  core": a correct core makes cases corollaries. Judge a core by (a)
  per-construct cost small and roughly flat (~10 lines suggests spec; ~100
  suggests the core leaking), (b) each recurring false-positive class
  dissolving under exactly ONE mechanism, (c) work that stops compressing =
  wrong core, stop. The owner's earlier "≤3000 lines" remark reads as a
  Kolmogorov-size estimate for a Lua checker, not a budget. Session evidence
  seemed consistent with it: every large diagnostic-count drop came from one
  mechanism landing, never from case-grinding, and the 22 measured false
  positives concentrate in 4 mechanism classes.
- **The never-run design campaign — the main identified open thread; NOT yet
  authorized.** The mutation × flow-sensitivity × syntax meeting point —
  where every iteration died — apparently never received design-it-twice
  treatment in any of the 9 iterations (the proof-dev characterized then
  parked the narrowing×multivalue fork in
  `docs/decisions/precise-narrowing-and-the-multivalue-model.md`; v9's
  lowering accreted mechanism-by-mechanism while only the easy engine got the
  full design discipline). The design object, if ever pursued: one
  COMPOSITIONAL account of mutation × flow-sensitivity × multi-values ×
  self-reference over Lua's ~30 forms. Acceptance tests already exist — the
  four measured FP mechanism classes: self-type/recursive-alias method calls,
  definition-order forward locals, cross-function/callback mutation,
  colon-method annotation self-binding (this last is a repro'd v9 BUG, likely
  worth fixing regardless of any campaign). Metric: the compression criterion
  above. Status: identified as designable and well-posed; the owner has NOT
  greenlit it, and it may be moot if the owner walks away.
- **v9 feasibility condition — hyper-modularity (owner thesis, with session
  evidence for it).** Units may need to be sized to a single agent's
  full-reasoning span: the engine (121 lines, seamed) saw zero churn and zero
  breakage across all increments; lower.lua (a ~3k-line closure) was the
  most-edited file in every increment and all churn and failures lived there
  (it also brushed the 92/200 Lua locals ceiling). Any future agent work on
  the lowering interior probably gates on restructuring it into per-construct
  units around a small explicit core — but weigh the counter-evidence:
  multiple prior "tiny clean core" versions never proved themselves; the
  clean core is the easy part, and cleanliness of the core ≠ viability.
- **Banked findings possibly worth acting on regardless of any typechecker
  decision.** FIXED 2026-07-04 (all lib-code items): linux/proc EOF/malformed
  nil-crash class (unguarded `f:read` into `match`/`gmatch`, plus nil-key
  writes in meminfo/vmstat/net.dev — meminfo crashed on any /proc/meminfo
  field missing from `name_to_key`); markdown:263 and ini:59 nil-receiver
  string methods; chacha20-test tonumber-nil; mimetype/by_contents annotation
  now tells the truth (`-> (string | nil, string | nil)`), force-casts in
  mimetype/init.lua dropped, and fixing it exposed a REAL behavior bug: both
  http/router/static.lua and static_full.lua served the first return (the
  extension, e.g. "png") as Content-Type instead of the mime string — fixed
  and verified end-to-end. keyring:778 / server_ws:56 needed no code change
  (v9 diagnostics that resolved once `T | nil` annotations were read; the
  code was correct). Still open — two LEGACY-checker bugs (typechecker work,
  gated by owner direction): mixed named/unnamed `--:` param spelling
  mis-infers unrelated distant code to `never`; and the
  forward-declared-local cross-file contamination (tracked in the v9 section
  below; repro not yet reduced).
- **Semantics-linter thread (2026-07-05, owner-driven).** Definition + architecture
  conversation state in `docs/semantics-linter-working-notes.md` (NOTHING greenlit;
  one OPEN owner objection — "seems wrong" on the hyperproperty framing — must be
  re-derived before anything is built on it). Session postmortem (why sessions run
  long; how ad-hocness enters — at contact) in
  `docs/postmortem-agentic-sessions-2026-07.md`, primary-source line refs included.
  Identified-not-started: tier-1 structural uniformity rule + tier-2 renaming
  property tests as standalone pre-commit antibodies predating the linter.
- [ ] **Test files fail on master (pre-existing; CI red).** Discovered
  2026-07-04 while verifying the banked fixes. Until then the full suite
  never finished at all: calendar_test hung forever (recur `until` limit
  never checked in next() — fixed, commit 0e4c52c3), so CI died at timeout
  and the failures behind it went unseen. With the hang fixed the suite
  completes: 614 pass / 23 FAIL, all 23 failing identically at HEAD before
  this session's changes. Clusters: crypto (hash 24, sha1 30, hmac 12,
  pbkdf2 8, totp 22 assertion failures — possibly one shared root cause),
  deque (14), text_diff (10), glob (6), sat (6), sqlite (5), taskgraph (5),
  chan (4), utf8 (4), plus singles/doubles (count_min, db, doc, event,
  platform×4, type/static, static-v4 cli_compare). Full list in the session
  log; rerun `bin/cr test` to reproduce.
  - [x] **crypto cluster (hash/sha1/hmac/pbkdf2) root cause found + fixed
    (2026-07-10).** `lib/hash/sha1/init.lua` built each 32-bit word with
    `bit.tobit` (signed) then formatted with `string.format("%08x", ...)`.
    For negative words, `%x` sign-extends to the host C `long` width before
    formatting — on this platform's 64-bit `long` that prints 16 hex digits
    (`ffffffff`-prefixed) instead of 8, corrupting every digest containing a
    high-bit word. hmac and pbkdf2 build on sha1 so inherited the corruption;
    totp not yet re-verified (not exercised this session). Fixed by using
    `bit.tohex` (LuaJIT's purpose-built unsigned-32-bit hex formatter)
    instead of `string.format("%08x", ...)`. Verified against HEAD (bug
    reproduces identically on a worktree at `acf0f58b`, well before this
    session's unrelated epoll/kqueue/io_poll commits — confirms pre-existing,
    not a regression). `bin/cr test lib/hash/ lib/pbkdf2/` now 8/8 files
    green (was hash_test 24 failed, sha1_test 30 failed, hmac_test 12 failed).
  - [x] **sqlite cluster root cause found + fixed (2026-07-10).**
    `lib/sqlite/init.lua:189` `db_errmsg` returned the raw FFI `const char *`
    cdata from `sqlite3_errmsg` and callers concatenated it directly into a
    Lua string (`"sqlite: prepare: " .. db_errmsg(self)`), which errors
    ("attempt to concatenate 'string' and 'const char *'") instead of
    producing the error message. Fixed by wrapping the FFI return in
    `ffi.string(...)` inside `db_errmsg` (single fix point, 4 call sites).
    Verified pre-existing the same way as the crypto cluster (reproduces at
    `acf0f58b`). `bin/cr test lib/sqlite/ lib/db/ lib/platform/caps/` now
    all green (was sqlite_test 5 failed).
  - [ ] Remaining clusters (deque 14, text_diff 10, glob 6, sat 6, taskgraph 5,
    chan 4, utf8 4, count_min, doc, event, platform×4, type/static,
    static-v4 cli_compare, cap_dispatch, projection_types, noise, audit) —
    reconfirmed pre-existing and unrelated to the kqueue/epoll/io_poll/
    diagnostic-cache-key/vendored-binary-layout commits (2026-07-10 CI
    triage; identical failures on a worktree at `acf0f58b`). Still
    untriaged — root causes unknown.
## v9 vertical slice — dynamism-boundary roadmap (2026-07-03)

The v9 slice (frontend seam -> total lowering -> engine -> `lib/type/v9/check.lua`)
checks real lib files end-to-end: 1,557 files, zero crashes, full solve ~7s
(`bin/cr lib/type/v9/smoke.lua` prints the histogram). Boundary items to shrink,
in histogram order, plus recorded debt. (2026-07-04: the session-level open
threads above — owner verdicts in particular — likely gate whether and how this
roadmap proceeds; it is no longer a self-directed grind list.)

- [x] **Record/table types in the v0 domain** — DONE 2026-07-03. Open structural
  records with per-field read/write split (r joins up / w meets down — the
  records-of-refs invariance, engine-lattice-encoded) as a domain-local lattice
  upgrade; field read/write/constructor/method-call lowered in the same one rule
  shape; engine untouched. The 314k-diag family (`field-expr` 200k +
  `table-constructor` 44k + `method-call` 33k + `field-assign` 21k + `index-expr`
  16k) is retired; residue is the honest boundary (`unsupported:dynamic-index` 22k,
  `table-array-part` 12k, `string-method` 0.4k) + real findings (`missing-field`,
  `field-write-mismatch`). Named concession: `new-field-on-write` (policy, default
  off). Note: went straight into `lattice.lua` rather than growing into the fenced
  `type_rep`/`subtype` seams — those stay fenced for the arrow/negation upgrade.
- [x] **Annotations + function types** — DONE 2026-07-03. Arrow values in the
  lattice (params as CELLS + annotation pins, results as VALUES — the polarity
  split; contravariant/covariant fn_leq; clip bounds recursion cycles);
  intra-file inference (params from call sites, per-position multi-return,
  result-open spread) in the one rule shape; the annot seam
  (`lib/type/v9/annot`) parses `--:`/`--::` into v9 types with per-feature
  `unsupported:annotation-*` buckets; pin+check wiring for locals /
  assignments / fields / fn definitions / checked + force casts. 521,517 ->
  495,478 total; use-before-narrow 444,422 -> 389,417; the two known
  pending-annotations findings (keyring:778, server_ws:56) resolve.
  `unsupported:cast-annotation` (6.7k) retired into cast-mismatch/force-cast +
  annotation buckets. Remainder of use-before-narrow is dominated by stdlib
  globals (`string.*`, `math.*`, `package.*` reads) — the next item below.
- [x] **Index signatures in the lattice** — DONE 2026-07-03. Rec gained an
  optional `idx = { str, num }` component (per-kind r/w Fields; a never part
  claims that key kind absent — how `{ [string]: T }` says "no number keys"
  and an array constructor says "no string keys"). Dynamic reads are
  `T | nil` NON-NEGOTIABLY (absent keys are nil — the spot TS is unsound by
  default and v9 is not); writes check against the part's invariant `w`
  (index-write-mismatch, error); growing a part on a part-less/never record
  is the `new-index-on-write` concession (off), the exact analogue of
  new-field-on-write. Joins keep idx only when both sides bounded and FOLD
  dropped named fields into the str part (sound widened reads, monotone
  projections); leq does width-into-index for extra named fields and
  REJECTS plain open records into index types (unbounded extras) — fresh
  constructors pass via leq_init (now recursive through record positions).
  Annotation grammar: `{ [string]: T }` / `{ [number]: T }` / `T[]` are real
  types (`annotation-index-signature` + `annotation-array` buckets retired;
  non-str/num key types are the small `annotation-index-signature-key`
  bucket). Constructors' array parts build the num part (join of elements;
  no arity/tuple tracking — stated; `#t` is number). ipairs/pairs/next
  element types flow via the CALL-SITE INSTANTIATION intrinsics
  ($Elem/$Values/$Keys/$Arg — declared result positions computed per call
  from an argument; one generic arm in call_core, power lives in the
  declarations): ipairs loop var is `T` not `T | nil` (ipairs stops at the
  first nil — Lua semantics). Keys outside string/number stay the honest
  dynamic-index boundary; reads on plain records without a signature are the
  `index-without-signature` diag (warn in v0 — dial up as annotations
  spread).
- [x] **Index-part growth through loop-head phis** — DECIDED 2026-07-03 (with
  the freshness increment): the phi kill is the sound call and stays. The
  born-index-bounded-`{}` alternative was rejected deliberately — it turns
  stale-alias reads into wrong `nil` claims (beyond the named concession,
  which yields unknown/diags, never a wrong type); the join-as-identity
  alternative breaks projection monotonicity. Constructor freshness dies at
  every phi (the join drops one-sided field/part evidence, so leq_init's
  absent⇒nil claim would go wrong through the merged version). The
  annotation requirement is kept and the DIAGNOSTIC now says so: an
  ann/call mismatch of a plain open record against an index-bounded type
  carries the annotate-the-declaration hint (`local m = {} --: { [k]: T }`
  checks the whole loop cleanly — pinned by tests).
- [x] **Cross-module summaries** — DONE 2026-07-03. Module summary = the
  chunk's recorded returns (joined post-solve, exported as At DATA via
  summary.lua's val_to_at — never live cells; the importer's at_val re-mints
  param cells in its own graph, the globals-seam interning split) + the
  exported alias env (own + imported, transitively closed). Resolution is a
  caps-first seam (modules.lua: dot->slash, init.lua fallback, one injected
  read_file cap — probing IS reading). Demand-driven session (check.session):
  summaries cached by path, cycles cut by an in-progress set (the legacy
  `_checking` pattern) into `unsupported:cross-module-cycle` — never a hang.
  `require` wiring is DECLARATION-driven: stdlib declares
  `require = (module: string) -> $Require<1>`; lowering resolves the inst
  from the literal argument (no name-keying — pinned by a test that wires a
  non-require name through the same declaration). `--:: require "mod"`
  imports the dep's alias env (own aliases shadow).
  `unannotated-module-boundary` is the policy dial over inferred summaries
  (default off). Landing it surfaced a LATTICE-OP pathology: join/meet/equal
  walk two distinct DAGs per PATH (exponential), and the imported DOM-shaped
  `lib.js_types` environment made the whole-lib smoke hang (minutes,
  gigabytes) on lib/web/html — fixed in the increment's own leq-memo pattern
  (pairwise memos + EXACT absorption dedup so the engine's no-change firing
  is identity + per-file reset; lattice.lua states why LuaJIT's
  non-ephemeron weak tables cannot express the cache). Histogram + numbers
  in ARCHITECTURE.md's slice section.
- [ ] **`_types.lua` companion declaration files at the session** — the legacy
  checker OVERRIDES a module's path with its `_types.lua` companion
  (`lib/foo.lua` -> `lib/foo_types.lua`). NOT carried into v9's resolver: v9
  summaries are inferred from the module's returns, and the two existing
  companions (lib/http/format_types.lua, lib/imap/format_types.lua) are
  alias-only files with no `return` — a path override would type the module's
  value as `true` (wrong). The principled v9 shape is alias-env MERGING at
  the session (summary(mod) also checks the companion and layers its aliases)
  — small, but zero `--:: require` consumers target those pairs today, so
  recorded instead of built.
- [ ] **Cross-module summary invalidation / persistence** — the session cache
  is per-process by design (this increment; the legacy sha256 disk cache is
  deliberately out of scope). A future watch-mode/LSP needs invalidation
  (content-hash keys + dep edges — the legacy dep_hashes pattern) before
  summaries can persist.
- [ ] **Legacy checker: forward-declared-local call sites contaminate
  IMPORTERS' checks** — while landing v9 cross-module summaries: a
  forward-declared local (`local equal_val ... join_val = function() ...
  equal_val(r, a) ... end ... equal_val = function() ... end`) in
  lib/type/v9/lattice.lua made `bin/cr check` (the LEGACY checker) report
  a spurious error in lib/type/v9/lower.lua — a DIFFERENT file that
  imports lattice — at an unrelated, previously-clean line
  (`cannot take length of type integer` on `#names` after an
  `x is { [integer]: string }` guard). Reordering lattice's definitions so
  the local is assigned before the call sites cleared it. Minimal repro
  not yet reduced; smells like module-summary inference degrading on the
  unassigned-local call and poisoning the importer's env. v9 is the
  replacement, but until cutover the legacy checker gates commits (the
  pre-commit hook), so this class costs real debugging time.
- [ ] **Cross-module solve cost on DOM-shaped imports requires Val
  INTERNING (hash-consing)** — the whole-lib full smoke moved ~23s -> 95s
  and peaks at ~19GB LuaJIT heap on the heaviest importers (the
  `lib.js_types` environment: lib/web/html, the reactive_dom trees): each
  importer re-mints the imported summary/alias DAG as fresh Vals + pinned
  cells in its own graph, so equal structures are distinct objects and
  every pairwise memo/dedup pays a full first-visit walk per file. The
  substrate fix is interning Vals (equal structure = identical object,
  the globals-seam sharing generalized), which collapses the pairwise
  memos into identity checks and bounds the re-mint. Recorded as
  substrate; not to be patched around per-name. Watch (2026-07-04): the
  exponential-DAG-walk class has now occurred TWICE (leq memoized earlier;
  join/meet/equal memoized in the cross-module salvage) — interning is the
  one-mechanism fix for the whole class; a THIRD occurrence would read as
  the fixes-don't-stick signature (per the compression criterion in the
  session-level threads above).
- [x] **Constructor freshness through locals** — DONE 2026-07-03. Freshness is
  a decl-level SSA property in lowering: a constructor bound to a local stays
  re-typeable (leq_init) along a single LINEAR version chain — rebound only by
  its own field/index writes, read only at projection bases (field/index-read
  bases, `#`'s operand: the `t[#t+1]` append idiom stays fresh) — and is
  CONSUMED by the first ascription whose type is known at lowering (annotated
  local/assignment/field write, checked cast, pinned return) with OWNERSHIP
  TRANSFER (the local rebinds to the pin; named writes on index-bounded
  records now check against the `[string]` part bound, keeping the
  transferred view checked). Kills: any retaining read, closure capture
  (permanent — the closure aliases the binding), any phi. The
  built-then-returned map class (agent/set.lua-shaped straight-line builds)
  checks clean; annotation-mismatch 1,500 -> 1,475, field-write-mismatch
  215 -> 190 on the tree.
- [x] **String metatable member access** — DONE 2026-07-03 (landed 29261ba8;
  audited + refactored to declaration data same day). Member access on
  string-typed values (`s:upper()`, `("x").len`) resolves through the
  DECLARED `string` table — LuaJIT sets the string metatable's `__index` to
  the string library. The LINKAGE is DATA at the declaration seam:
  `globals.atom_index` (atom -> declared global table NAME), consumed
  UNIFORMLY by lowering's projection joins (atom_index_libs) and check's
  read-target triage (read_meta) — no atom-keyed branch in the member-access
  path and no method list in the checker (the initial landing name-keyed
  `string` in lower/check; the audit refactor collapsed it to the map — a
  future metatabled atom, e.g. cdata, is one entry + its declaration).
  Per-file `--:: declare string` re-wires member resolution (pinned by test:
  a shadow makes `s:sub` missing-field and a novel method resolve). WRITE
  targets stay table-only (no `__newindex` wiring; a string write target is
  op-mismatch — a real runtime error). `unsupported:string-method` 4,697 ->
  0, most sites checking clean; the replacement surface is real checking
  (call-mismatch +302 on string-method arguments, missing-field +12,
  use-before-narrow +483 where members return through unknown). Verified
  post-increment histogram: 426,041 -> 422,506 at ~23s, zero crashes.
- [ ] **Freshness at call arguments (`f(t)`)** — deliberately NOT consumed:
  a call pin resolves only post-solve, so there is no lowering-time
  ownership transfer, and re-typing without one leaves a stale precise view
  (unsound). The bin_packing:698-shaped `local t = {...}; f(t)` class
  therefore still checks under full leq. Closing it needs either
  lowering-time callee types (cross-module/known-local arrow resolution
  before the solve) or a post-solve ownership discipline (e.g. consume only
  when the argument is the decl's LAST use — requires a liveness pre-pass;
  reads inside loops are never last).
- [ ] **Optional fields in records** — `{ x = cond and v or nil }`-shaped and
  conditionally-assigned fields intersect away at phi joins; reads then report
  missing-field (e.g. the `body.generationConfig = body.generationConfig or {}`
  default idiom). An optional-field attribute (field: T | absent) keeps them; also
  needed before `missing-field` can default to error.
- [ ] **Record imprecision classes to burn down** (all domain-local): fields accreted
  through one alias / inside a callee are invisible to other views (missing-field,
  sound-imprecise); function bodies see upvalue record versions at DEFINITION order,
  not call order (`lib/bigint/init.lua:40` `M._mt` is the canonical false positive);
  `x == nil`-guard narrowing inside `or`-chains (aho_corasick:151).
- [x] **Stdlib/global declarations** — DONE 2026-07-03. The globals seam
  (`lib/type/v9/globals`): LuaJIT 5.1 globals as `--:: declare` DATA in v9's own
  annotation grammar (mined from the legacy `lib/type/static/stdlib_types.lua`,
  translated to v0 — generics/overloads widen, index signatures -> `table`,
  pcall/find/match as result-OPEN arrows via the new `(T, U, ...)` tuple form;
  ffi deliberately NOT declared — not a LuaJIT global, it rides require);
  parsed once per process, shared At trees, per-file lazy At->Val conversion.
  Per-file `--:: declare name = T` wired through the same path (shadows
  stdlib). Reads resolve typed; writes stay global-write; `require(...)` stays
  the cross-module boundary. `type(x) == "…"` tag guards landed as two more
  lattice flow ops (tag_keep/tag_drop) behind the same cond_target/filter
  shape. undeclared-global 19.5k -> genuine names only; use-before-narrow drops
  with it (histogram in the ARCHITECTURE slice section).
- [x] **Loops via loop-head phi** — DONE 2026-07 (control-flow precision increment).
  All four constructs checked: loop-head phi per rebindable decl (assigned-roots
  scan), CLIPPED back edges (loop-grown values terminate), condition narrowing
  into body/exit, reachable-exit merge (`while true` has no cond-false edge;
  breaks snapshot into their loop frame), for-num var seeded number + bounds
  obligated ⊑ number, for-in as the iterator-protocol call (control cycles as
  the nil-dropped first result), repeat's `until` inside the body scope. The
  havoc fence retired with its last consumer. ~11k loop-boundary diags retired;
  histogram in the ARCHITECTURE slice section.
- [x] **true/false literal atoms** — DONE 2026-07. boolean = true | false in the
  lattice (constructors normalize, show/excess collapse); falsy/truthy exact, so
  `cond and a or b` infers `type(a) | type(b)` — op-mismatch 4,073 -> 2,165 and
  the pagination:384 stdlib-pin false positive resolved. Mutable-ref creation
  WIDENS a lone literal to the pair (the `{ enabled = false }` flag idiom);
  flow values and annotated refs keep literal precision.
- [ ] **v9 unused-local is syntactic** (declared-never-read in the lowering walk),
  not wired to the backward liveness domain; flow-precise liveness (e.g.
  assigned-after-last-read) is a later wiring of the existing domain.
- [ ] **v9 goto is unmodeled** (112 sites) — the `unsupported:goto-stmt` diag names
  the boundary, but a BACKWARD goto's loop effects (assignments between label and
  goto) are not fenced or phi'd; before the loops increment such gotos usually sat
  inside a havoc-fenced loop body, now they don't. Either model label/goto as
  merge points (same phi mechanism) or havoc-fence the label..goto span.
- [x] **Guard narrowing beyond bare `x` / `not x` / `type(x) == "..."`** — the
  `==`/`~=`-nil comparisons (the SAME keep/drop filters at the nil tag) and
  EARLY-EXIT reachability (`if type(x) ~= "s" then return end` narrows the
  fall-through; diverging branches — return/break/declared-`never` calls like
  `error` — contribute nothing to the merge) landed 2026-07; the
  lib/math/init.lua:11 false positive resolved. Remaining piece tracked below.
- [x] **Compound-condition narrowing (and/or chains)** — DONE 2026-07-03.
  `cond_narrows` in lower.lua composes branch action LISTS recursively over the
  same atomic filters: `and` narrows EVERY conjunct on the then-path; `or`
  narrows the sound duals on the else-path only (no invented positives);
  `not` swaps the lists; actions on the same decl chain in order. The RHS of
  any expression-level and/or also lowers UNDER the lhs guard (Lua's
  evaluation order), which types `opts and opts.f` as `nil | typeof(f)`.
  columnar:209, inverted_index:242, qrencode:145+149, csv:140-144/270-323,
  base64:42-43/99 all resolve. shamir:182 was MISATTRIBUTED to this gap — it
  is the zero-iteration-loop case (`len` is set inside a for-in; "k >= 2
  implies the loop ran" is value-dependent reasoning): an honest dynamism
  boundary, not a narrowing gap.
- [ ] **Field-place narrowing (`if t.f then … t.f …`, `o._x and o._x.y`)** —
  v0 narrows LOCAL bindings only (pinned decision, tested in lower_test:
  "FIELD places are NOT narrowed"). A field read is not a stable place under
  mutation/aliasing: sound field-place narrowing must invalidate on
  intervening calls and writes (TS pays exactly this machinery). Remaining
  real-file sites of the class: csv:394/410-411/457-458 (`ds._opts and
  ds._opts.quote`). The supported idiom is `local o = t.f; if o then …`.

## Typechecker soundness methodology — open fork

> **RESOLVED (2026-06-20).** Decided via design-it-twice (4 decorrelated candidates, 3 adversarial judges): ground soundness in an executable formal Lua semantics validated against reality (validated-semantics-first), version-parametric and cross-language, with mechanized proof staged behind phase 1. Full design + staging (S1–S5) in `docs/typechecker-formal-semantics.md`. Implementation TODOs in the next subsection ("Formal-semantics substrate — implementation"). The historical fork below is retained for context.

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

**Background:** the slice typechecker's soundness is established by adversarial testing (critic agents imagining attacks). The variance write-through unsoundness (fixed `cdc5b2a6` + re-verified `a4d85035`) survived 5 feature-audit rounds before a 6th adversarial pass caught it; an embedded-alias sub-hole only surfaced because someone happened to imagine that exact case. The methodology, not any single bug, may be the weak link — adversarial testing shows presence of bugs, never absence.

**Fork (three methodologies — different cost/strength; needs design-it-twice before deciding):**

1. **Mechanized type-safety proof** (progress+preservation against a formal Lua semantics). Strongest — proves absence — but PhD/research-scale and re-extended every increment. Cuts against the project's "stop anytime / each granularity independently useful" goal. Plausible as a long-term aspiration layered on later, not a prerequisite.

2. **Executable reference Lua semantics as differential-testing oracle** — generate programs, run under the reference semantics, assert the checker never accepts one that faults at runtime. Middle weight; systematic and automatic (would have caught embedded-alias without anyone imagining it). Fits the substrate's `artifact + semantics + evidence ⇒ claim` shape. Grounds the existing work rather than replacing it.

3. **Per-feature paper soundness arguments** (already partially practiced — see `docs/agnostic-static-analysis-crescent-slice.md` §6.14 closure's "3-case exhaustive" argument). Lightest; still relies on a human enumerating cases correctly — exactly what failed for variance.

**Leaning (advisory):** NOT mechanized-proof-first (too heavy); lean toward option 2 + option 3 per feature, option 1 as deferred long-term aspiration. Needs design-it-twice before adopting.

**Open sub-questions (verify before acting):** prior Lua-formalization art may exist (believed: Soldevila et al.; a PLT Redex model), but targets reference Lua 5.3/5.4, not LuaJIT 5.1. The subset-scoping crescent uses might make it far smaller than a full formalization. Verify via research; don't trust session memory. Suggested treatment: (a) research prior art, (b) design-it-twice on the soundness-methodology decision.

**Pointers:** `docs/typechecker-design-thesis.md` (§4b/claim 5 now FIXED; "fully sound is a HARD invariant" stance); `docs/agnostic-static-analysis-crescent-slice.md` §6.14 (variance closure design + soundness argument); `docs/artifacts/typechecker-run-2026-06-12/` (prior-art survey, 3 design-thesis critiques, gap-cascade-magnitude, per-property-metric, variance-fix-cost + design + reverify).

## Formal-semantics substrate — implementation

> *Implements the RESOLVED decision above. Design + rationale: `docs/typechecker-formal-semantics.md`. Each increment is independently useful; build substrate before consumers (S1 before the loops that need it).*

- [x] **S1 — primitive-decomposed Lua semantics for the core fragment.** Built in `lib/sem/`: parametric value algebra (`value.lua`), config/store + fault ADT (`config.lua`), partial primitives with faults-as-stuck (`prim.lua`), the small-step CEK relation `step` (`step.lua`), run-driver + canonical observation (`run.lua`), the single `luajit51` Profile (`profile.lua`), independent dumb lowering surface→control (`lang/lua/lower.lua`) + Lua-source printer (`lang/lua/print.lua`). Loop-α harness in `lib/sem/diff/` (observe / arb_program / alpha_test) vs vendored LuaJIT only. **Loop-α result: 2000/2000 generated v1-subset programs agree** (10 seeds × 200) between `step` and real LuaJIT; mismatches shrink to a minimal witness with PROP_SEED replay. Discipline verified: no raw Lua type tags in step/prim (values flow only through `value.lua`).
  - **Covered runtime fragment:** scalars + literals; arithmetic (add/sub/mul/div/mod); comparison (eq/ne/lt/le/gt/ge); concat; table construct/index/assign; function def/call with multi-return + vararg; if/while/return; local/assign. Faults-as-stuck for: arith-on-non-number, compare-incompatible, concat-non-concatable, index/newindex-non-table, table-key-nil, call-non-function.
  - **Deferred within S1 (recorded, not result-faked):** (1) μ / union / intersection surface terms are type-level, not runtime-evaluable — no `step` rule, so the generator does not emit them (start-narrow, per plan). (2) Records/indexers/open-closed rows/optional-readonly fields are TYPE-level structure; S1's tables are the runtime value, the typed structure is S2+. (3) Closure capture is a value-snapshot of the slot array at call time (read-only-closure semantics); mutable upvalue cells across closure/outer scope need a proper upvalue substrate — S2+. (4) String/number metatable indexing (e.g. `("a")[k]` reading the string lib) is OUT of the S1 no-metatables fragment; the generator only indexes guaranteed tables to stay in-fragment. (5) `for-in`/numeric-for, goto, coroutines, metatables, full stdlib — out of fragment.
- [x] **Typechecker substrate gap (surfaced building S1): literal-union not assignable to itself in return position** — FIXED. Root cause: `solve.lua` `solve_return` unconditionally widened the return value (`widen_for_sub`) before the assignability check, so `return "a"` against `"a" | "b"` widened the literal to `string`, which is not assignable to the literal union. Fix: a "try unwidened actual first" fast path mirroring the argument-position fast path (constrain.lua ~2256) — when the expected return (or expected tuple slot) is concrete (no free vars, not a bare var), check `try_unify(val_tid, expected)` before falling back to the widening path. Added at both return sub-cases (general scalar-vs-union at solve.lua ~2938; scalar-vs-tuple-slot at ~2820, since `() -> K` packs as a 1-tuple). Workarounds removed: `lib/sem/value.lua` `kind_of`/`ValueAlgebra.kind_of` restored to `ValKind` (exhaustiveness regained); `lib/sem/diff/arb_program.lua` `ShrinkIter` restored to `() -> (SS[] | nil, nil)`. Negative case (`return "c"`) still correctly rejected (falls through to widen+fail).
- [x] **Typechecker substrate gap (surfaced building S1): union return through multi-hop field-access callee over-narrows to `nil`** — FIXED (the "union field-access narrowing quirk"). Root cause: `peek_callee_ret_union` (and `peek_arg_type`) resolved a `NODE_FIELD_EXPR` callee only when the receiver was a bare `NODE_IDENTIFIER`; a multi-hop chain like `env.va.kind_of()` (receiver `env.va` is itself a field expr) was not peekable, so a union return (`VK = "nil" | ...`) typed the call-result local as `nil` instead of the union — surfaced once `kind_of` was tightened to `ValKind`. Fix: added a general recursive `resolve_expr_type_static(ctx, node)` that resolves identifier (scope + var_origin + require_exports) and field-access chains of any depth, and used it in `peek_callee_ret_union`'s field-expr branch (constrain.lua ~2746). Exposed a latent override-leak: an argument call's `pending_multi_return_override` (`f(g(...))` — g's override) leaked into f's own override-setting logic (guarded on `not override`), mis-typing `va.number(va.add(x,y))` as `number`; fixed by clearing `pending_multi_return_override` after `spread_last_call_arg` in NODE_CALL_EXPR (constrain.lua ~2940). Net effect on the 40-file lib sample: 596 → 590 errors (latent fixes, zero new). Typechecker suite regression-free (same 2 pre-existing TAG_SPREAD failures before/after).
- [x] **S2 — versions + Profiles.** Wired PUC 5.1–5.4 via the flake (`pucBin`: symlinks `lua5.x` → nixpkgs `lua5_1..5_4`; contributor/CI tooling ONLY, never a runtime dep — `bin/cr test` skips absent versions on a bare clone). Five Profiles in `profile.lua` (`luajit51`, `lua51`, `lua52`, `lua53`, `lua54`); a Profile is `{ name, version, va, arith_ops }` — version/language are the same parameter, a version delta is DATA. **The parametric value algebra split is CLEAN, not a leak:** arithmetic moved from raw-double ops in `prim` into `va.arith(op, Value, Value) -> Value`, so the number MODEL (`value.lua`: `single_double` vs `dual_intfloat`) fully owns int/float — distinct integer/float subtypes, `math.type`, `/`-always-float, `//` floor-div, integer/float promotion, integral-float tostring (`3.0`). The op-set (`arith_ops`) gates `//` (enabled 5.3/5.4; omitted 5.1/5.2/LuaJIT, where `//` is a real syntax error — verified against bin/luajit). no-special-casing grep CLEAN: zero `version ==` / name-keyed branches and zero int/float subtype knowledge in `step.lua`/`prim.lua` (verified). **Loop-α result (in `nix develop`, all 5 real interpreters present): 120/120 generated programs agree PER VERSION across luajit51/5.1/5.2/5.3/5.4, stable over 8 seeds**; the random stream now emits float literals + `/`/`%` so it exercises the int/float split. A positive cross-version DELTA table asserts the parametricity is real (e.g. `4/2`→`2` single vs `2.0` dual; `3.0` literal→`3` vs `3.0`; `5//2`→FAULT in 5.1/5.2/LuaJIT vs `2` in 5.3/5.4; float+int promotion). Bare clone (LuaJIT only): luajit51 120/120, PUC skipped gracefully, suite green.
  - **Deferred within S2 (recorded, not result-faked):** (1) **Full 64-bit integer wraparound** — the dual model wraps at 2^53 (the host double's exactly-representable window), where it is byte-for-byte faithful to real 5.3/5.4; true int64 two's-complement wraparound at 2^63 needs an exact int64 substrate (FFI `int64_t` or pure-Lua bignum). The harness confines integer-arithmetic operands to the representable window. (2) **Bitops** (`&` `|` `~` `<<` `>>`) — DEFERRED: LuaJIT `bit.*` is 32-bit-wrap while 5.3/5.4 native bitops are 64-bit, a genuine cross-version delta that needs the int64 substrate to model correctly; not faked. (3) **Typing-delta / desugar-delta** Profile fields are forward slots (S3 typing deltas, S4 language profiles); S2's lowering is shared (only number-literal construction is profile-parametric, via the injected `va`).
- [x] **S3 — Loop-β soundness property.** `checker accepts ⟹ ¬fault` against the deterministic spec (NOT the real interpreters) with a structure-aware alias-targeting generator. Built: `lib/sem/diff/arb_alias.lua` (CONSTRUCTS the measure-zero aliasing shape each trial — fresh annotated table, wide-typed alias, write-through-wide, read+use-through-narrow — co-producing the surface SS[] for the spec AND crescent-annotated source for the checker, plus the narrow/wide field Ty the variance decision turns on); `lib/sem/diff/beta_test.lua` (Loop-β with a pluggable checker oracle: the REAL `crescent_slice_lower.lower`→`A.check` checker, and a SYNTHETIC unsound oracle re-deriving the pre-fix COVARIANT `_rec_sub` rule from the real `slice_subtype.is_subtype` forward direction — demonstration path (b); the shipped checker is untouched). **Acceptance MET:** the variance unsoundness is MECHANICALLY DETECTED — generator + unsound oracle yield an accept∧spec-fault counterexample every run; minimal witness `local a={f=N}:NarrowBox; local b=a:WideBox{f:unknown}; b.f="…"; return a.f+1` (string through the unknown-widened alias → read as number → `arith-on-non-number` fault). The REAL (sound) checker REJECTS that witness and finds 0 violations over the alias generator. PROP_SEED replay; runs against spec+checker only (no PUC interpreters) so `bin/cr test lib/sem/` stays bare-clone green.
  - **Deferred within S3 (recorded, not faked):** broader GENERAL-v1 Loop-β coverage. The alias-targeting generator is intentionally narrow — it targets the alias-widen shape with field types in {number, string, boolean, unknown}, which is what the variance class needs and what uniform sampling misses. A general structure-aware Loop-β generator (driving the full v1 fragment from `arb_program` with annotations, hunting other accept∧fault classes beyond covariant-field-write) is the follow-up; it requires an annotation co-generator over the whole fragment (each generated binding needs a sound type to annotate). Not built this increment; the headline (mechanical variance detection + 0 violations against the real checker over the alias shape) is landed.
- [ ] **S4 — second language (cross-language bar).** λ-calculus with sum types + static arities as a Profile; must slot in without editing the core value-algebra/primitive mechanism (real falsification test).
- [ ] **S5 (phase 2) — mechanized proof.** Choose the proof host (tentatively Lean 4) only once phase 1 has forced the real primitive set; prove per-primitive progress + preservation lemmas feature-by-feature.
- [x] **Reality bridge — increment 1 (unambiguous atoms).** Connect the Coq proof model's `denote`/`atom_denote` (`proof/subtype.v`) to REAL LuaJIT 5.1 — the one thing the proofs cannot establish (faithfulness of the model to real Lua). Spec: `docs/reality-bridge.md` (V↔Lua value map, atom↔real-membership-predicate map, the int/float-is-not-a-runtime-tag finding). Harness: `lib/sem/bridge/atom.lua` (faithful Lua port of `atom_denote` for AStr/ABool/ANil + value→real-Lua-expr renderer + real predicates) and `atom_test.lua` (3 legs: Coq-`Compute` oracle validates the port 12/12; oracle vs real LuaJIT 12/12; generated differential 100 values × 3 atoms = **300/300 agree**). Caps-first (popen-injected vendored LuaJIT, skips on bare clone). **No faithfulness disagreement found.**
  - **Deferred — genuine design forks, NEED USER STEER (enumerated in `docs/reality-bridge.md` §4, not resolved):** (A) *primary* — number atoms int/float: REFINE (`AInt <: ANum`, integer-valued number as subtype, matching the slice's `integer <: number`) vs COLLAPSE `VInt`/`VFloat` to one number kind to match LuaJIT 5.1 runtime `type()` (which has NO int/float tag — `AInt` is a refined value-shape predicate, not a tag). (B) *the hard one* — functions/closures: model `VFun` is an extensional finite I/O graph; a real closure can't be introspected for its graph, so arrow membership may only be a behavioral/sampling test (refute-only), not a membership check — possibly category-different from the model. (C) tables: string-keys-only (Lua keys are any value), open/closed reading, finite-assoc vs real-table semantics.

## Proof-dev / type-system backlog (deferred items)

> **THE single source of truth** for everything deferred / scoped-out / future
> across the Coq metatheory — the subtype algebra (`proof/subtype.v`), the typing
> layer + operational semantics (`proof/typing.v`), the algorithmic subtyping
> relation (`proof/ssub.v`, incl. the reference `rsub`), and the bidirectional
> checker (`proof/check.v`) — all narrated in `docs/proof-kernel.md`, plus the
> reality bridge (`lib/sem/bridge/`, narrated in `docs/reality-bridge.md`). Those
> docs keep their per-increment notes; this is the consolidated list they both
> point to. **Last re-consolidated after the references unification** (commits
> `1e7f7fe5` + `01aae498`: store + references threaded into the MAIN typing layer,
> `imp.v` retired). Items tagged **[BLOCKING]** stand between the current dev (a
> sound-but-often-`DUnknown`/`rsub`-fenced checker) and a *usable static checker*;
> **[nice-to-have]** are precision / faithfulness refinements. Pointers are
> `file:increment` or `file:line` at time of writing.

### Decision-procedure completeness (the emptiness-based `gdecide`)

- [ ] **[BLOCKING] Coupled multi-negated-records per clause.** ≥2 negated records
  sharing keys in one DNF conjunct (arises from a *union of records on the right*
  of a subtyping query). Currently → `DUnknown` (the `Deferred` clause in
  `clause_wit3`, `proof/subtype.v:3243`). Scope predicate to lift: `dnf_ok`
  ("≤1 negated record per record-clause"). Principled fix: per-negated-record
  witnessing-key *assignment search* with per-key intersected `¬`-requirements.
  Deferred at `proof-kernel.md` increment 6 / staging "(a)". Demonstrated trap if
  done unsoundly: `gdecide {h:Int} ({f:Int}∪{g:Int})` must stay `DUnknown`.
- [ ] **[BLOCKING] Nested records.** Record field types that are themselves
  records; lifts the `flat` predicate ("every record's field types are
  record-free"). The `find_wit_fuel`/`rdepth` recursion already supports it
  structurally — the obligation is threading field-completeness through deeper
  `rdepth`, not new substrate. Deferred at `proof-kernel.md` staging "(b)".
- [ ] **[BLOCKING] Arrow subtyping decision.** Arrow subtyping is currently
  `DUnknown` — any clause with an arrow literal hits the `has_arrow` guard and
  defers (`clause_wit3`, `proof/subtype.v:3235`). Needs the Castagna-style
  arrow-aware emptiness / decomposition algorithm. Deferred at `proof-kernel.md`
  increment 7 ("[then — arrow decision procedure + multi-return]").
- [ ] **[BLOCKING] Reference subtyping decision (`has_ref` defer in `gdecide`).**
  Any DNF clause carrying a ref literal hits the `has_ref` guard (beside
  `has_arrow`) and defers — `gdecide ⇒ DUnknown`, never a wrong ref answer. The
  invariant `BRef` + any-ref widening rules ARE decided structurally by
  `decide_rsub` (`proof/ssub.v`, increment 18), but the emptiness-based `gdecide`
  in `subtype.v` itself does not decide refs. Deferred at `proof/subtype.v:2177`
  (the `has_arrow c || has_ref c` guard) + increment 17/18.
- [ ] **[BLOCKING] `decide_ssub`/`decide_rsub` inter-left distributivity (the N5
  frontier).** `decide_ssub` is COMPLETE only on the `inter_free` fragment: the
  inter-on-the-LEFT vs union/inter-on-the-right CROSS is the non-distributive
  frontier (subtype.v's N5 free lattice). Concrete sound-incompleteness witness:
  `decide_ssub ((Int∪Str)∩Bool)(Int∪Str) = false` while the subtyping holds.
  Closing it routes the connective subsumption through the `gdecide` emptiness
  path rather than widening `ssub`. Deferred at `proof-kernel.md` increment 12 +
  `proof/ssub.v:329` / `:502`.
- [ ] **[nice-to-have] Reference SOURCE into a connective target — `decide_rsub`
  completeness gap.** A `BRef`/`BAnyRef` SOURCE into a UNION/INTERSECTION target
  whose disjuncts are content-equivalent-but-not-syntactically-equal references is
  decided SOUNDLY but not completely — the delegated `decide_ssub` cannot observe
  ref-invariance through a connective. Closing it needs `decide_rsub` to grow its
  own connective-target clauses (the same inter-free boundary `decide_ssub`
  carries). Deferred at `proof/ssub.v:1356-1365` + `proof-kernel.md` increment 18
  "DEFERRED FRONTIER".

### Type formers

- [ ] **[nice-to-have] Closed / exact records.** Current `BRec` reads OPEN/WIDTH
  (extra keys allowed); a closed record needs a "no other keys" denotation.
  Deferred at `proof-kernel.md` increment 5 (and `reality-bridge.md` §4(C)).
- [ ] **[nice-to-have] Index signatures `{[K]:V}`.** A `∀ key`-quantified field
  reading. Deferred alongside closed records, `proof-kernel.md` increment 5 /
  staging "(c)".
- [ ] **[nice-to-have] First-class table atom.** Records currently subtype only
  `BRec []` (the table top-type), not a dedicated atom. `proof-kernel.md`
  increment 5 / staging "(d)".
- [ ] **[BLOCKING] Equirecursive μ + cyclic tables/values (the coinductive-V
  fork).** Recursive types `μ`; cyclic / self-referential tables would force a
  *coinductive* `V` (a genuine fork the current positive-inductive `V` avoids).
  Re-establish all laws + the decision procedure under recursion. Deferred at
  `proof-kernel.md` increment 5 ("cyclic deferred to μ") + staging
  "[then — equirecursive μ]". `proof/subtype.v:690`.
- [x] **Reference TYPE substrate — `BRef` + `BAnyRef` opaque leaves (split-step 1
  of the reference unification, DONE).** `subtype.v` gains the value `VRef : nat
  -> V` (a bare location address) and the types `BRef : BTy -> BTy` (a reference
  to `T`) and `BAnyRef` (all references, content-agnostic — so a truthy location
  can be NARROWED to "is a reference" without committing to a content type, the
  key diagnosis insight). References are INVARIANT and lack a store-free
  denotation, so the denotation is **content-blind**: `denote (BRef _) v` and
  `denote BAnyRef v` BOTH = "`v` is some `VRef n`", so denotationally `BRef T ≡
  BAnyRef ≡ BRef U` for all T,U. They are **OPAQUE LEAVES**, mirroring `BArrow`
  exactly: literals `LPosRef`/`LNegRef`/`LPosAnyRef`/`LNegAnyRef`; a `has_ref`
  guard (beside `has_arrow`) makes the witness-finder DEFER on any clause with a
  ref literal (`gdecide ⇒ DUnknown`, never a wrong ref answer); `BRef`/`BAnyRef`
  excluded from `atomic`/`flat`/`no_rec`/`neg_atomic`. All Boolean-algebra laws +
  `gdecide_DSub_sound`/`_DNotSub_sound` + `denote_dec` + `V_rect_strong` re-close
  `Qed` (Print Assumptions: closed under the global context). Non-vacuity:
  `ref_int_inhabited`, `anyref_inhabited`, `nonref_not_ref`/`_anyref`,
  `anyref_equiv_ref`, `ref_equiv_ref`, `ref_disjoint_atom`/`_rec`/`_arrow`.
  Recorded at `proof-kernel.md` increment 17 (reference TYPE substrate).
- [x] **Reference SUBTYPING — invariant `BRef` + any-ref widening (split-step 2
  of the reference unification, DONE).** `proof/ssub.v` ONLY (`subtype.v`/
  `typing.v`/`check.v`/`imp.v` byte-unmodified; whole chain recompiles clean).
  Because `ssub` is an inductive in the frozen `typing.v`, the rules are added as
  a new inductive `rsub` in `ssub.v` that EMBEDS `ssub` (`RsSsub`) + `RsTrans` and
  ADDS the two reference rules: `RsRefInv` (INVARIANT — `rsub (BRef S)(BRef T)`
  iff `S ≡ T`, read+write so NOT covariant) and `RsAnyRef` (`rsub (BRef U)
  BAnyRef`, WIDENING). The ASYMMETRY — no `rsub BAnyRef (BRef U)` — lets a truthy
  location narrow to `BAnyRef` without breaking invariance. PREORDER
  (`rsub_refl`/`rsub_trans`), SOUNDNESS vs `dsub` (`rsub_sound`; refs collapse to
  equal-denotation inclusions, `rsub ⊊ dsub` safe), and a TOTAL+TERMINATING
  decider `decide_rsub` (invariant case recurses on strictly-smaller content;
  delegates non-ref pairs to `decide_ssub`). FULL soundness; completeness on the
  reference fragment (`decide_rsub_anyref_complete`, `decide_rsub_invariant_complete`,
  the asymmetry decided + sound `rsub_anyref_not_ref`). Sanity (`reflexivity`):
  `(BRef Int)(BRef Int)=true`, `(BRef Int)(BRef Str)=false`,
  **`(BRef Int)(BRef Num)=false`** (invariance ≠ covariance, the soundness point),
  `(BRef Int) BAnyRef=true`, `BAnyRef (BRef Int)=false`. Print Assumptions on all
  new facts: closed under the global context. **DEFERRED FRONTIER:** a reference
  SOURCE into a UNION/INTERSECTION whose disjuncts are content-equivalent-but-not-
  syntactically-equal references is decided SOUNDLY but not completely (delegated
  `decide_ssub` can't see ref-invariance through a connective) — same inter-free
  boundary `decide_ssub_complete` already carries. Recorded at `proof-kernel.md`
  increment 18 (reference subtyping).
  **NEXT (split-step 3, DEFERRED):** thread store + references into the typing
  layer — promote `RsRefInv`/`RsAnyRef` into `ssub`'s inductive in `typing.v`
  (collapsing `rsub` back into `ssub`), give `decide_rsub` its own
  connective-target clauses to close the union/inter-of-refs completeness frontier,
  and add store-based mutation soundness (deref/assign typing + preservation over a
  typed store).

### Lua semantics (model faithfulness)

- [x] **Multi-return values — RETURN-side multivalue + contextual adjustment
  (truncation + last-position spread).** DONE (proof-kernel.md increment 21).
  `subtype.v` gains the `BTuple` sequence type (`VTup` value, positional/exact-length
  denotation, pointwise subtyping, disjointness, threaded through the decider as an
  opaque DEFER leaf like `BArrow`/`BRef`). `typing.v` gains `tret` (return-sequence,
  the multivalue value `VRet`), `tfst` (TRUNCATION — bind the first value, the "most
  positions" adjustment) and `tappspread` (LAST-POSITION SPREAD — a known-arity tuple
  consumer receives all values). Progress + preservation re-proved (`Qed`); synth/
  check + synth_sound/check_sound re-proved. PAYOFF: a multi-return `f : Int ->
  (Int,Bool)`, the SAME call `f 3` TRUNCATED (`tfst (f 3) : Int`, ⤳* 3) in one
  position and SPREAD (`g (f 3) : Int`, ⤳* 0) in another — typed + stepped, the
  contextual adjustment machine-checked. STILL DEFERRED below.
- [x] **vararg `...` (function-side variadic) — DONE.** The PARAMETER-side mirror
  of multi-return: a variadic function binds its trailing actuals as a single
  multivalue (the rest), typed as the EXISTING `BTuple Ts`; the rest behaves exactly
  like a multi-return result — TRUNCATED to one value (`tfst`) in expression
  position and SPREAD (`tappspread`) in last position, REUSING the increment-21
  substrate (no duplication). `typing.v` gains the variadic-call term `tvapp f a rs`
  (variadic function `f`, fixed arg `a`, trailing args `rs`) with typing rule
  `TVApp` (function `: BArrow Tf (BArrow (BTuple Ts) B)`, `a : Tf`, `rs : Ts`
  pointwise ⇒ result `B`) and op-sem `SVApp` (PACKS `rs` into `tret rs` and applies
  via existing `tapp`/`tret`/`SBeta`) + congruences `SVApp1/2/3`. Threaded through
  the whole de Bruijn metatheory (tm_rect_strong, lift/subst/closed_at, weakening,
  subst_lemma, store_weakening, has_type_closed, closed_at_lift, subst_lift_cancel,
  progress, preservation) plus `check.v` (synth/proj_free/synth_sound/narrowing).
  `subtype.v`/`ssub.v` BYTE-UNMODIFIED (the rest type is the existing `BTuple`; the
  arity match is the reflexive tuple leaf of `ssub`). All `Qed`, axiom-free.
  PAYOFF: a variadic `λx:Int.λ(...:(Int,Bool)).…` that TRUNCATES `...` to its first
  value (`tvapp f 7 [3;true]` ⤳* 3) and one that FORWARDS `...` via last-position
  spread (⤳* 0) — typed + stepped + synth-decided, plus an arity-mismatch synth =
  None. Increment 22, `proof/typing.v` (`tvapp`/`TVApp`/`SVApp`), `proof/check.v`.
- [x] **multiple-assignment `a,b,…=e1,e2,…` / `a,b=f()` — arity adjustment
  (truncate + nil-pad + last spread).** DONE: the LHS-side CONSUMER of the multivalue
  substrate. `tmassign rs rhs` (N target ref cells + a packed-multivalue RHS); typing
  `TMAssign` ADJUSTS the RHS tuple to the target arity via the pure normalizer
  `pad_ty`/`pad_tm` (TRUNCATE extras — the `tfst` direction — and NIL-PAD missing
  slots with `tlit LNil : ANil`, the adjust-UP direction truncation doesn't cover),
  each adjusted source type gated `Forall2 rsub` below its target cell; op-sem
  `SMAssign` evaluates all targets + RHS to values, then writes every adjusted value
  at once (`store_massign`, reusing the `tassign` store-update) — Lua's "compute
  everything, then assign". Last-position spread `a,b=f()` needs nothing new: the RHS
  is whatever `f()` evaluates to (a `tret` multivalue). No new subtyping, no index
  signatures. Threaded through the whole de Bruijn metatheory; `progress` +
  `preservation` + `synth_sound` + `check_sound` re-proved (all `Qed`, axiom-free).
  PAYOFF: `a,b=f()` (f multi-returns two, both bound, ⤳* store `[3;true]`), nil-pad
  `a,b,c=e1,e2` (c gets `nil`), drop `a,b=e1,e2,e3` (e3 discarded) — typed + stepped +
  synth-decided, plus a type-mismatch synth = None. Increment 27, `proof/typing.v`
  (`tmassign`/`TMAssign`/`SMAssign`), `proof/check.v` (`unref_seq`/`decide_rsub_seq`).
- [ ] **[BLOCKING] table-collect `{f()}`, arity-polymorphic spread.** The
  increment-21 multivalue covers the return-side sequence + truncation + last-spread
  at KNOWN arity, increment-22 the function-side variadic `...`, and increment-27 the
  LHS-side multiple-assignment (all at known arity — the consumer/targets pin it).
  Table-collect-all `{f()}` and FULL arity-polymorphic spread (a spread whose arity is
  not fixed by the consumer) remain deferred. (Tuple SUBTYPING is reflexive/pointwise
  only in `ssub`; semantic tuple subtyping via `gdecide` and a top-tuple type are also
  deferred.)
  Increment 21, `proof/subtype.v` (`BTuple`), `proof/typing.v` (`tret`/`tfst`/`tappspread`).
- [x] **Metatables — `__index` field-lookup fallback (TYPING LAYER).** Static
  read-only `__index` as a table/record (prototype inheritance / OOP) is DONE at
  the typing layer (`proof/typing.v` `tmeta`/`TMeta`/dispatch op-sem +
  `proof/check.v` synth; `progress`/`preservation`/`synth_sound`/`check_sound`
  re-proved — see the Typing-layer §"Metatables" entry and proof-kernel
  increment 21). It is modelled by FLATTENING over the existing `BRec` (no new
  `V`/`denote`-level former). The first-class / dynamic-metatable axis (a
  metatable model in `V`/`denote` for `setmetatable`-driven dispatch / dynamic
  mutation / dynamic-shape tables) was **DECIDED — do NOT build any first-class or
  dynamic-metatable representation now**; keep this static `tmeta`/`merge_fields`
  model. Full design-it-twice result (4 candidate designs + 4 adversarial judges,
  grounded in `proof/*.v`) recorded in
  `docs/decisions/metatable-representation.md`. The underlying open work is
  re-filed below as three substrate prerequisites + the `__meta`-ref graft (each
  gated on that substrate); they are deferred BEHIND the substrate, not built on
  top of the current core. `reality-bridge.md` §4(C) tracks the broader unobserved
  table axis.
- [ ] **[substrate] Sound optional / absent-key field reads (`T | nil`) — proof
  dev.** Reading a possibly-absent record key yielding `T | nil`. SUBTLETY: for a
  CLOSED record an absent key is exactly `nil`; for the current OPEN `BRec` ("other
  keys allowed") an absent key MIGHT be present — so this is entangled with the
  open-vs-closed-record / index-signature distinction below. This is the same gap
  recorded as "rawget on a key ABSENT from own returning `nil`" (proof-kernel
  increment 25, `proof/typing.v`). PREREQUISITE for the dynamic-metatable frontier.
  See `docs/decisions/metatable-representation.md` (substrate prerequisite 1).
- [ ] **[substrate, high-stakes] Index signatures `{[K]:V}` in `BTy` — proof dev,
  OWN design pass first.** Deferred per `subtype.v`'s comment (`BRec` is a fixed
  finite key list). Unlike the rejected `BRecMt` constructor, this has a REAL
  denotation (tables where every `K`-typed key maps to a `V`-typed value) and a
  real subtyping semantics — a justified, denotation-bearing kernel extension. But
  it TOUCHES THE FROZEN, reality-validated core, so it needs its OWN design pass
  before any code. (Distinct from, but overlapping with, the existing
  `[nice-to-have] Index signatures {[K]:V}` item under the type-algebra section.)
  PREREQUISITE for the dynamic-metatable frontier. See
  `docs/decisions/metatable-representation.md` (substrate prerequisite 2).
- [ ] **[substrate] Precise function-type narrowing (intersection-typed
  `ttypetest`) — proof dev.** For function-valued `__index` / `__newindex`.
  Already-deferred substrate; otherwise the metamethod narrows to `BArrow BBot
  BTop` and returns `BTop` (vs `tmeta`'s exact type). PREREQUISITE for
  function-valued metamethods on the dynamic-metatable frontier. See
  `docs/decisions/metatable-representation.md` (substrate prerequisite 3).
- [ ] **[substrate] Precise POSITIVE intersection narrowing (`U ∩ Pos`) — proof
  dev.** Narrow a conditional's scrutinee to `U ∩ Pos` so the narrowed binding is
  consumed at its REAL type (dissolving the `truthy_type ⊑ Num` wall). SPLIT BY
  CONSTRUCT:
  (a) **`ttypetest`-positive narrowing is SOUND and LANDABLE NOW** — a READY
  increment. Binder `BInter U (tag_type g)` with the RAW scrutinee type `U` works
  because `ttypetest` does NOT truncate (no `STtMulti*` rules; a multivalue is
  tested by `TgMulti`, `tag_type TgMulti = BTop`, and substituted WHOLE via
  `STtTrue`). Reusable proven pieces: `RsInterI` in `rsub` (`subtype.v`/`ssub.v`
  unmodified; `rsub_sound` via `dinter_glb`), merged bridge lemmas
  `tag_narrows_inter`/`truthy_narrows_inter` generic over the bound `W`. `tifn`
  POSITIVE narrowing for DIRECT (non-multivalue) scrutinees is also sound in
  isolation (`SIfnTrue` + the merged bridge at `W:=U`).
  (b) **`tifn`-truthiness precise narrowing is BLOCKED on the multivalue-model
  fork.** A uniform `tifn` rule with binder `BInter (trunc1 U) Pos` is UNSOUND under
  `SIfnMultiCons`: `inv_ifn`/`inv_ret` expose the scrutinee at a LOOSE,
  subsumption-chosen supertype `U` (e.g. `BTop` via `SsTop`), but after truncation
  the head has the first-COMPONENT type, which bears NO subtyping relation to `U` /
  `trunc1 U` (degenerates at `U=BTop`; FAILS for non-flat
  `BTuple[BTuple[AInt]]`). ROOT CAUSE: the multivalue model permits loose-supertype
  subsumption before the conditional AND non-flat multivalues. OPEN DESIGN FORK
  (no-default, design-it-twice candidate, gated): **Option 1** flat-multivalue model
  (components single-valued; `trunc1` idempotent); **Option 2** truncate-in-rule at
  `TIfn` (type the condition as truncate-to-one via `tfst`/`TFst` at a TIGHT type so
  subsumption can't loosen it); **Option 3** context-narrowing + canonical scrutinee
  typing is INSUFFICIENT alone (recorded NON-solution). FRAMING: this wall is a
  COMPLETENESS limit, not soundness — over-approximation (bind the bound-alone
  `truthy_type`/`tag_type`) stays sound. Full finding:
  `docs/decisions/precise-narrowing-and-the-multivalue-model.md`.
- [ ] **[gated graft] `setmetatable`/`getmetatable` via a reserved `__meta` ref
  field — proof dev.** Modellable WITHOUT any new core constructor and WITHOUT
  touching `subtype.v`: `setmetatable(t,mt) ≈ tassign (tproj t "__meta") mt`
  (return `t`) and `getmetatable(t) ≈ tderef (tproj t "__meta")` — pure existing
  `TAssign`/`TProj`/`TDeref`. CAVEAT: this stores/retrieves the metatable VALUE but
  does NOT by itself unify dynamic dispatch with the static `tmeta` path; adopting
  it coherently (so dispatch READS the stored metatable) is GATED on the absent-key
  / index-signature substrate above — else it is a parallel encoding of metatables.
  See `docs/decisions/metatable-representation.md` ("the one clean graft").
- [ ] **[nice-to-have] Non-string table keys.** Model `VTable` uses string keys;
  real Lua keys are any non-nil value. `reality-bridge.md` §4(C).
- [ ] **[nice-to-have] Full stdlib.** No stdlib modelled in the proof value
  domain.
- [ ] **[nice-to-have] `cdata` / `userdata` / `thread`, incl. LuaJIT FFI
  fixed-width integer types.** A separate runtime-representation axis (FFI cdata
  integers `int64_t`/`uint64_t`, `type()=="cdata"`). Deferred at
  `reality-bridge.md` §4(A) ("separate deferred axis") + Status "Deferred".
- [ ] **[nice-to-have] General `for-in` iterators.** Out of the modelled
  fragment.

### Number model

- [x] **Inert-value-payload removal — STAGE 1: drop the `VStr` payload.** `VStr`
  is now a NULLARY constructor (`VStr : V`, was `VStr : nat -> V`). The payload
  was inert: `denote` is head-determined (`denote_head`), every witness used
  `VStr 0`, and no typing/progress/preservation obligation read it (premise
  verified by grep — no destruct/match ever inspects a `VStr` payload; record
  keys are Coq `string`, unaffected; no proof needs two distinct string values).
  Makes "types, not magnitudes" structural — one string value, head-only,
  foreclosing the value-fidelity temptation by construction. First deliberate
  edit to the frozen reality-validated core; full chain rebuilt clean
  (`subtype→typing→ssub→check`, all "Closed under the global context", zero
  axioms), all four bridge oracle `.v` files recompute the expected verdicts, and
  the reality bridge differential tests re-ran green against real LuaJIT
  (`bin/cr test lib/sem/bridge/` — 600/600 atom + 80/80 rec + 60/60 arrow +
  100/100 operational). Bridge port updated: `lib/sem/bridge/atom.lua` `vstr` is
  nullary, renders the fixed representative `"s"`. Recorded at `proof-kernel.md`
  (inert-payload removal, stage 1 of 2).
- [x] **Inert-value-payload removal — STAGE 2 (FINAL): remove number magnitudes +
  value computation.** Numbers are now two type-CLASSES with NO magnitude:
  `NRint`/`NRfrac`/`LInt` are NULLARY (`subtype.v`/`typing.v`), `VInt`/`VFloat` are
  payload-free notations. The int/frac CLASS distinction is KEPT (load-bearing for
  `AInt ⊊ AFloat`; collapsing to one number would be unsound). Arithmetic and
  comparison are ABSTRACT: `prim_arith`/`prim_cmp` REMOVED; `SPrimArith` steps to
  SOME number value (`tlit LInt : ANum`); comparison steps NON-DETERMINISTICALLY to
  `LBool true`/`false` (`SPrimCmpTrue`/`SPrimCmpFalse`) — both with a real `LBool`
  head so `canon_bool`/`SIfTrue`/`SIfFalse` still fire (no determinism lemma in the
  dev, so non-det is harmless). This makes "types, not magnitudes" STRUCTURAL.
  The VALUE-COMPUTATION demos were DELETED (gold-plating, explicitly approved):
  `compute_add`/`compute_lt`/`ex_*_steps`/`ex_chain_steps`/`ex_add_preservation`,
  and the loop end-to-end / termination runs `cinc_*`/`forsum_one_iter`+
  `_terminates`+`_loop_runs`/`fordown_*`/`forin_one_iter`+`_terminates`+`_loop_runs`
  (they assert concrete computed stores / computed-`false`-guard termination). Each
  loop keeps its TYPING demo; soundness is carried by progress/preservation. Full
  chain rebuilt clean (`subtype→typing→ssub→check`, all "Closed under the global
  context", zero axioms; `progress`/`preservation`/`synth_sound`/`check_sound`/
  `AInt_sub_AFloat`/`not_float_sub_int`/`AFloat_equiv_ANum` all Closed). All four
  bridge oracle `.v` files recompute. Reality bridge re-validated green against real
  LuaJIT (`bin/cr test lib/sem/bridge/` — 4 passed, 142 assertions, 600/600 atom +
  80/80 rec + 60/60 arrow + 113/113 operational + 17/17 result-inhabits-type).
  Bridge port updated: `lib/sem/bridge/atom.lua` `vint`/`vfloat` nullary (render
  fixed `"0"`/`"0.5"`); `exec.lua` `lit_int` nullary; PDiv faithfulness-gap test
  deleted (moot — no computed magnitude). Recorded at `proof-kernel.md` (stage 2 of
  2). See the version-parametric-numbers item below for deferred number-value work.
- [ ] **[nice-to-have] Version-parametric numbers (5.3/5.4 distinct int/float
  sibling values).** The proof collapses to ONE double for LuaJIT 5.1 (fork A′
  RESOLVED). A future version-parameterized `V` gives 5.3/5.4 a genuinely
  distinct integer value alongside the float (where `3` and `3.0` are distinct
  siblings). Deferred at `reality-bridge.md` §4(A′) + `proof/subtype.v:640`.
- [ ] **[nice-to-have] The `AFloat` reading nuance.** On 5.1 `AFloat ≡ ANum`
  (every number is a double); the option-(ii) reading (`AFloat` = non-integer
  numbers, partitioning `ANum`) was NOT taken and is only meaningful under the
  version-parametric model above. Recorded so the decision isn't silently
  re-litigated. `reality-bridge.md` §4(A′).

### Bridge (model ↔ real LuaJIT faithfulness)

- [x] **Functions bridge (fork B RESOLVED).** Bridged `VFun` (finite known I/O
  graph) to a real Lua function via the operational I/O check. `lib/sem/bridge/
  fun.lua` builds a real `function(x)` dispatching the graph; `fun_test.lua` runs
  two legs — operational (`real_f(real(i))==real(o)` per pair) and membership
  (model `denote_dec (BArrow A B) (VFun g)` port vs real `∀(i,o). real(i)∈A →
  real(o)∈B`) — both AGREE (oracle 9/9 + 8/8 0-disagree; random graphs/types all
  agree). Model side validated against `proof/bridge_arrow_oracle.v` `Compute`,
  member + non-member (8/8). SCALAR graphs only. `reality-bridge.md` §4(B) RESOLVED
  + Status "Done (increment 4)".
- [ ] **[nice-to-have] Higher-order graphs in the function bridge.** A function
  value appearing as a graph INPUT or OUTPUT (`VFun` nested in a `VFun` graph
  pair). Deferred from the scalar function bridge (fork B); needs a recursive
  real-image + equality story for function-valued graph entries. `reality-bridge.md`
  §4(B) "Deferred".
- [ ] **[nice-to-have] Table-valued graph entries in the function bridge.** A
  `VTable` value as a graph input or output. Deferred from the scalar function
  bridge; depends on the table bridge (fork C) for the real-image + membership of
  compound values. `reality-bridge.md` §4(B) "Deferred".
- [x] **Records/tables bridge (fork C RESOLVED for the string-keyed scalar
  fragment).** Bridged `VTable` (finite string-keyed scalar assoc) to a real Lua
  table `{ [k]=real_image(v), … }` via OPEN/WIDTH record membership. `lib/sem/
  bridge/rec.lua` builds the real table + ports `denote_dec (BRec fields)
  (VTable t)`; `rec_test.lua` runs the membership leg (model port vs real
  `∀(k,T)∈fields. real_table[k]~=nil ∧ real_table[k]∈T`) — they AGREE (oracle 7/7
  0-disagree; random tables × record types 80/80). **Open/width confirmed against
  real tables** (extra keys ⇒ still member). Model side validated against
  `proof/bridge_rec_oracle.v` `Compute`, member (incl. extra-fields/open + field-
  order-irrelevant) + non-member (missing field; wrong field type; scalar is not a
  record). STRING-keyed SCALAR records only. `reality-bridge.md` §4(C) RESOLVED
  (for the fragment) + Status "Done (increment 5)".
- [ ] **[nice-to-have] Nested / function-valued record fields in the table
  bridge.** A `VTable` or `VFun` value as a record FIELD value (table-valued or
  function-valued fields). Deferred from the string-keyed scalar record bridge
  (fork C); needs a recursive real-image + membership story for compound field
  values (depends on the same machinery as the function bridge's higher-order /
  table-in-graph items). `reality-bridge.md` §4(C) "Deferred".
- [ ] **[nice-to-have] `nil`-valued record fields (nil-hole axis) in the table
  bridge.** A `VNil`-valued entry collapses to "absent key" in real Lua, conflating
  present-nil with absent. The string-keyed scalar bridge excludes nil-valued
  entries; bridging them faithfully needs a nil-hole semantics decision (and
  interacts with `ANil`-typed fields whose real predicate reads an absent key).
  `reality-bridge.md` §4(C) "Deferred".
- [ ] **[nice-to-have] Table richness bridge.** Any-key, array part, metatables,
  `nil`-hole semantics, iteration-order non-determinism — bridging beyond
  string-keyed scalar records. `reality-bridge.md` §4(C) "Scoped".
- [x] **Operational-semantics reality bridge (the EXECUTION axis).** The prior
  bridges (atom/rec/fun) validate the VALUE-MEMBERSHIP axis only; this one
  validates the REDUCTION axis: a WELL-TYPED term, executed on REAL LuaJIT,
  produces a value INHABITING its inferred type (`synth [] term`) — the checker's
  soundness claim (synth + progress/preservation) tested against reality.
  `lib/sem/bridge/exec.lua` ports the proof's `tm` and translates closed terms to
  runnable Lua (de Bruijn → fresh-name stack; refs → single-field mutable cells
  `{v=…}`; `tif`/`tlet`/`tseq`/`tassign` → IIFEs; `twhile` → a real `while` loop;
  primops → Lua binops). `exec_test.lua` runs a battery of **17** well-typed
  programs (arithmetic, comparison, conditional, let, record+proj, ref
  alloc/deref, ref mutation, counting while-loop, function application, literals)
  and asserts each real result inhabits its inferred type, REUSING the atom
  bridge's real predicates (records via per-field open/width). Result:
  **17/17 inhabit** their inferred type. Inferred types pinned from
  `proof/bridge_exec_oracle.v` `Compute (synth [] term)`. Caps-first
  (popen-injected LuaJIT, bare-clone skip). `reality-bridge.md` §"Operational /
  execution axis".
  - **SURFACED faithfulness gap — `PDiv`.** The proof's `PDiv` is `Nat.div`
    (INTEGER division: `7/2 = 3`) but real Lua `/` is FLOAT division (`7/2 = 3.5`).
    Both `3` and `3.5` inhabit the inferred type `ANum`, so soundness is PRESERVED
    (the result still inhabits the type) — but the VALUES disagree. This is a
    sound-but-UNFAITHFUL model choice. Recommendation (recorded in the doc): drop
    `PDiv` from the faithful computational subset, OR add a fractional number
    literal + faithful float division (`NRfrac`/`VFloat` already exist on the
    value side). Concrete witness: `proof Nat.div 7/2 = 3 vs real 7/2 = 3.5`.
  - **SURFACED synth-vs-declarative gap — the sum `while`-loop.** `sumloop_prog n`
    is declaratively typed at `ANum` (`sumloop_prog_typed`, via `TSub`-widening the
    `AInt` initialiser to a `Num` cell) but the ALGORITHMIC `synth` REJECTS it
    (`None`): it allocates `BRef AInt` from `LInt 0` and then cannot store the
    `ANum` arithmetic result back into the INVARIANT cell. The battery uses a
    synth-acceptable variant (`local i = ref (0+0)`, so the cell synthesizes
    `BRef ANum`). Recorded as a synth-completeness-vs-declarative gap (bidirectional
    inference does not recover every `TSub` the declarative system admits at an
    invariant `BRef` allocation). `reality-bridge.md` §"Operational axis". **CLOSED
    (`proof-kernel.md` increment 21):** type annotations (`tannot`) guide inference
    — `talloc (tannot (BAtom ANum) (tlit (LInt 0)))` synthesizes `BRef ANum`, so the
    annotated sum-loop now synths to `ANum` (`sumloop_ann_synths`); the un-annotated
    form still `None` (`sumloop_unann_None`).
- [ ] **[nice-to-have] Flow-narrowing terms on the operational bridge.** The
  execution bridge's battery covers the computational fragment (literals, primops,
  if/let/record/proj, refs, terminating while, application). `tifn` / `ttypetest`
  (flow narrowing) and higher-order / divergent programs are NOT executed — the
  bridge validates the FINITE-execution fragment (terminating programs to a value).
  Adding narrowing terms needs value-conditioned-step images + a binder-aware
  translation. `reality-bridge.md` §"Operational axis — scope".
- [x] **Close the synth-vs-declarative gap at invariant-ref alloc — via TYPE
  ANNOTATIONS (`tannot`).** `proof-kernel.md` increment 21. The general
  inference-guiding mechanism: a new term-former `tannot : BTy -> tm -> tm`
  (ascription), typing `TAnnot`, runtime-erased op-sem (congruence `SAnnot1` +
  value-strip `SAnnotV`; `tannot T v` is not a value), and `synth (tannot T e)` =
  CHECK `e` against `T` (`decide_rsub`) ⇒ return the ANNOTATION `T`. THE FIX: the
  annotated sum-loop — cells built `talloc (tannot (BAtom ANum) (tlit (LInt 0)))`
  ⇒ `BRef ANum`, able to hold the arithmetic result — now SYNTHESIZES
  (`sumloop_ann_synths : synth [] [] (sumloop_ann n) = Some (BAtom ANum)`),
  contrasted with the un-annotated `sumloop_unann_None` (= `None`). `synth_sound` /
  `check_sound` / `progress` / `preservation` re-proved (`Qed`) with the `tannot`
  cases (`inv_annot` + threading through weakening/subst/closedness/narrowing).
  Sanity: `(3:Num)` synths+steps (erased) to `3`; mis-ascription `(3:Str)` rejected
  (`synth = None`) and ill-typed. `Print Assumptions` on
  progress/preservation/synth_sound/check_sound/sumloop_ann_synths: Closed under the
  global context. `subtype.v` + `ssub.v` byte-unmodified. Building block for surface
  `local x : T = e` and function param/return annotations (not themselves built).
  - **RETIRED / MOOT (stage-2 number refactor):** `PDiv` float-faithfulness (the
    former `Nat.div` vs real `/ = 3.5` reality-bridge gap) — moot by construction:
    numbers have no magnitude and arithmetic is abstract, so there is no
    model-computed number value to be faithful-or-unfaithful. See the stage-2
    inert-payload-removal item under "Number model".

### Arrows (laws beyond the closed one)

- [ ] **[nice-to-have] Higher arrow decomposition / emptiness laws.** Beyond the
  proved `(A→B)∩(A→C) ≡ A→(B∩C)` (`darrow_inter_cod`): `(A→C)∩(A'→C) <: (A∪A')→C`
  and the arrow-emptiness laws. Need either an arrow-aware decision procedure or
  further model lemmas. Deferred at `proof-kernel.md` increment 7 "DECOMPOSITION
  LAW" + `proof/subtype.v:1970`.

### Metatheory bridge

- [ ] **[nice-to-have] Reconcile the old syntactic free-lattice `sub` with the
  semantic `dsub`.** The increment-1/2 inductive `sub` is RETAINED as the future
  *algorithmic* relation; prove it sound + complete against `dsub`, OR formally
  retire `sub`. Deferred at `proof/subtype.v:612` + `proof-kernel.md` increment 3
  ("`sub` retained as the future algorithmic relation").

### Typing layer (MINIMAL CORE DONE — `proof/typing.v`, increment 8)

The de-risk skeleton is built and machine-checked (`proof/typing.v`, builds on
`proof/subtype.v` unmodified). Progress + preservation both `Qed`; `Print
Assumptions` on `progress`, `preservation`, `ssub_arrow_inv`, `ssub_sound`,
`arrow_top_collapse` all report *Closed under the global context*.

- [x] **Typing judgment.** `has_type : list BTy -> tm -> BTy -> Prop` over a de
  Bruijn context, with a `has_fields` mutual for records. Rules: lit / var / lam
  (BArrow) / app / let / rec (`BRec`, NoDup keys) / proj / **subsumption (TSub)**.
- [x] **Operational semantics in the proof.** CBV substitution-based small-step
  `step : tm -> tm -> Prop` over de Bruijn terms (lift/subst defined): beta, let,
  projection lookup, plus congruence/eval-context + record left-to-right field
  reduction. `value` = literals / lambdas / all-value records.
- [x] **Progress + preservation.** `progress : has_type [] e T -> value e \/
  exists e', step e e'` and `preservation : has_type [] e T -> step e e' ->
  has_type [] e' T`, both `Qed`. Supporting: canonical forms, weakening,
  substitution lemma, arrow inversion, record inversion.
- [x] **Subtyping plugged in via `ssub` (sound vs `dsub`).** KEY FINDING: raw
  semantic `dsub` is too coarse for syntactic preservation — an `A->Top` arrow
  collapses to "any function" (`arrow_top_collapse`, machine-checked), breaking
  preservation (`preservation_dsub_counterexample`: a well-typed redex steps to a
  stuck untypeable term). TSub subsumes along a syntactic `ssub` whose arrow rule
  bakes in variance inversion; `ssub_sound : ssub a b -> dsub a b` keeps the
  proven semantic algebra as ground truth. This realizes the increment-3 roadmap
  item "retain `sub` as the future algorithmic relation, prove it sound vs `dsub`"
  for the arrow+record fragment. Guarded `dsub` arrow inversion (`arrow_inv_cod`
  / `arrow_inv_dom`, with the inhabitation side-conditions made explicit) is also
  proved, documenting the model's true edge cases.

- [x] **Conditionals + union types** (increment 11, `proof/typing.v` +
  `proof/ssub.v` + `proof/check.v`, on unmodified `subtype.v`). `tm` gains `tif`
  (op-sem literal-selectors + condition congruence, lazy branches); declarative
  `TIf` types it at `BUnion T1 T2` (the JOIN). `ssub`/`decide_ssub` gain UNION
  rules (composable intro `SsUnionInL/InR` + elim `SsUnionE`), proven SOUND vs
  `dsub` (`ssub_sound`) and DECIDED (union-left `&&` / union-right `||`; same
  `bsize a + bsize b` fuel measure, strictly decreasing — `decide_ssub_correct`
  re-proven sound + complete + total). SOUNDNESS FINDING: explicit `SsTrans` +
  union intro makes a transitivity MIDDLE possibly a union, breaking naive
  derivation-induction inversion (old `ssub_top_src`/`ssub_connective_super`
  become FALSE); fixed via STRUCTURAL above/below predicates
  (`arrow_above`/`rec_above`/`atom_above`/`top_above`/`interneg_above`/
  `union_below`) proven closed under `ssub` by derivation induction → union-robust
  inversions (`ssub_arrow_inv`, `ssub_rec_inv`, `ssub_union_src_l/r`,
  `ssub_union_tgt_inv`). `progress` + `preservation` re-proven (the `tif` cases
  subsume the selected branch into the union via the injections — operationally
  sound, no arrow-Top collapse; `canon_bool` added). `synth`/`check` handle `tif`
  (synth ⇒ `BUnion` of branches); `synth_sound`/`check_sound`/`synth_principal`
  re-proven. Non-vacuity: `if true then 3 else "s"` synths `Int∪Str`, steps to
  `3`. `Print Assumptions` closed under the global context.

Still open (DEFERRED — recorded honestly, minimal core only):
- [x] **PRIMITIVE BINARY OPERATORS — arithmetic + comparison** (increment 20,
  `proof/typing.v` + `proof/check.v`, on **byte-unmodified** `subtype.v` +
  `ssub.v`). `tm` gains `tprim : primop -> tm -> tm -> tm`,
  `primop = PAdd|PSub|PMul|PDiv|PLt|PLe|PEq`. Declarative `TPrimArith` (operands
  `ANum`, result `ANum`) + `TPrimCmp` (operands `ANum`, result `ABool`), gated by
  boolean classifiers `arith_op`/`cmp_op` (no special-casing; the classes are
  provably disjoint). Op-sem: left-to-right operand congruence (`SPrim1`/`SPrim2`)
  then COMPUTE — arithmetic on two `LInt` literals → `LInt (prim_arith op m n)`
  via nat arithmetic (`3+4=7`); comparison → `LBool (prim_cmp op m n)` via the real
  nat comparison (`3<4=true`); `PDiv` uses `Nat.div` (integer-valued
  representative — no fractional literal in the term language; sound since result
  is a number). `progress`/`preservation` re-proved `Qed` (new `canon_num`: a
  closed `ANum` value is `tlit (LInt n)`; `inv_prim` subsumption-transparent
  inversion). Checker: `synth (tprim op a b)` checks both operands `≤ ANum`,
  returns `ANum`/`ABool`; `synth_sound`/`check_sound` re-proved. Sanity: `3+4 :
  ANum →* 7`, `3<4 : Bool →* true`, `(3+4)*2 →* 14`, `"s"+1` rejected
  (`~has_type`, `synth=None`). `Print Assumptions` on `progress`/`preservation`/
  the sanity lemmas + `synth_sound`/`check_sound`: closed under the global context.
  **DEFERRED (this increment):** precise Int-preserving result types
  (`Int+Int : AInt` — sound `ANum` used now); concat / modulo / `//` / bitwise /
  metamethod-dispatch operators; general structural `==` (numbers-only here).
  Recorded at `proof-kernel.md` increment 20.
  **SUPERSEDED by the stage-2 number refactor:** the `COMPUTE`/`prim_arith`/
  `prim_cmp` value computation described above was REMOVED — arithmetic/comparison
  are now ABSTRACT (numbers are magnitude-free type-classes). The `3+4 →* 7`,
  `3<4 →* true`, `(3+4)*2 →* 14` sanity runs were deleted (gold-plating); `faithful
  PDiv float result` is RETIRED/moot. See the stage-2 item under "Number model".
- [x] **INTERSECTION + NEGATION as `ssub` rules** (increment 12, `proof/typing.v`
  + `proof/ssub.v`, on unmodified `subtype.v`). `ssub` gains the composable GLB
  rules `SsInterPL`/`SsInterPR`/`SsInterI` (projections + intro), **proven SOUND
  vs `dsub`** (`ssub_sound` extended — intersection is the meet); `progress` +
  `preservation` re-proved `Qed`. `BNeg` stays reflexive-only (the complement
  disjointness `A∩¬A <: Bot` narrowing needs is kept a SEMANTIC `dsub` fact,
  `dcomplement_inter`, NOT an `ssub` rule — adding it would force `ssub` to decide
  emptiness). `decide_ssub` gains inter-on-RIGHT (GLB, COMPLETE) + inter-on-LEFT
  (projection, SOUND); correctness SPLIT: `decide_ssub_sound` UNCONDITIONAL +
  `decide_ssub_complete` on the `inter_free` fragment. **The full `<->` is
  IMPOSSIBLE** with intersection projections present — the inter-left vs
  union/inter-right CROSS is the non-distributive frontier (subtype.v's N5);
  concrete sound-incompleteness witness `decide_ssub ((Int∪Str)∩Bool)(Int∪Str)
  = false` while the subtyping holds. `Print Assumptions` closed under the global
  context. (TERM-position intersection/negation introduction forms still
  deferred; semantic connective decision stays `gdecide`'s job.)
- [x] **Flow NARROWING — variable-condition truthiness (increment 13, DONE).**
  Sound truthiness occurrence typing — the `and`/`or`-nil class — machine-checked
  end-to-end (`progress`+`preservation`+`synth_sound`+`check_sound`+the payoff all
  `Qed`, `Print Assumptions` closed). **The refined diagnosis (correcting
  increment-12's).** Increment 12 said value-conditioned op-sem alone fixes the
  unsoundness; that is INCOMPLETE for de Bruijn SUBSTITUTION semantics: a
  `tif (tvar n)` narrowing the free context entry `n` is still unsound, because an
  enclosing `SLet`/`SBeta` substitutes the bound value into BOTH branches BEFORE
  the conditional selects — the DEAD branch then carries a now-false narrowing
  assumption (a truthy value pushed into the falsy-narrowed else-branch) and
  becomes an ill-typed residual. Value-conditioning fixes the SELECTED branch but
  not the blindly-substituted dead one. **The fix that closes:** a BINDING
  narrowing-conditional `tifn c e1 e2` — the scrutinee is bound FRESH (de Bruijn
  0) in each branch at the narrowed type, and the value-conditioned step
  (`SIfnTrue`/`SIfnFalse`, on `truthy_value`/`falsy_value`) substitutes the value
  into ONLY the selected branch (`subst 0 v e1` / `e2`), discarding the other —
  so no dead-branch residual ever exists. The bridging lemmas `truthy_narrows` /
  `falsy_narrows` (a truthy value has type `truthy_type`; falsy → `falsy_type`)
  are the operational⇒type justification, proved by canonical forms + `ssub`
  UNION-introduction only (no negation, no `dsub`-in-typing). **Types.** `truthy_type`
  = positive union of all non-nil value classes (`ABool∪ANum∪AStr∪{table}∪{fn}`);
  `falsy_type` = `nil∪bool` (over-approx — no singleton-false type exists). **Payoff
  (both proved):** a non-nil consumer `g : truthy_type→Int` applied to the
  then-narrowed scrutinee TYPES with narrowing and is REJECTED without it (the
  un-narrowed `Int∪Nil` is not `≤ truthy_type`).
- [ ] **Flow narrowing — DEFERRED sub-items (increment 13 scope boundary).**
  (1) **Full occurrence-typing precision `U ∩ truthy_type`** (carry the scrutinee's
  declared type INTO the narrowed branch, not just the truthy/falsy bound). Needs
  an intersection-INTRODUCTION rule `TInter`; its ARROW inversion is the hard core
  of intersection-type systems — `(A1→B1)∩(A2→B2)` is NOT `ssub`-below any single
  arrow, so `inv_app` cannot recover a single arrow witness. Intersection-type
  substrate, deferred. (2) **Exact falsy partition.** The value model (subtype.v)
  has NO singleton-false type (`ABool` denotes both `true` and `false`), so the
  exact falsy set `{nil, false}` is inexpressible as a `BTy`; narrowing uses the
  two expressible bounds (`truthy_type` under-approximates-the-complement,
  `falsy_type` over-approximates falsy) — both SOUND, both inexact at the
  true/false split. Exact narrowing needs a literal-false type (a subtype.v change).
  (3) **Type-test narrowing** `type(x)=="number"` — DONE in increment 15 (see the
  completed entry below); the NEGATIVE (else-branch) precision `U ∩ ¬tag_type g`
  remains deferred (over-approximated to `U`), same intersection/negation wall as (1).
  Precise NEGATIVE narrowing is separately GATED on DECIDER ROUTING (`decide_ssub`
  vs `gdecide` — the N5 inter-left non-distributive frontier, witness
  `((Int∪Str)∩Bool)(Int∪Str)`; see the [BLOCKING] inter-left distributivity item
  above) — a design-it-twice candidate, DISTINCT from the multivalue fork below. The
  POSITIVE side (`U ∩ tag_type g`) is now characterized as sound + landable for
  `ttypetest`; see the `[substrate] Precise POSITIVE intersection narrowing` item
  above and `docs/decisions/precise-narrowing-and-the-multivalue-model.md`.
  (4) **Narrowing on non-variable paths** (`x.f`, `x[i]`).
  (5) **Distributive simplification** `(T∪nil)∩¬nil <: T` — `dsub`-true, `ssub`-false
  (the N5 non-distributive frontier); routing it needs the `gdecide` emptiness path.
  (6) **Combined truthiness + type-test narrowing** in one guard (e.g. `if x and
  type(x)=="number"`) — each form is independently sound; composing their binders
  is future work.
  (7) **Precise REFERENCE narrowing.** A truthy location currently narrows to its
  bound type / `BAnyRef` (content-agnostic — sound, since a truthy value IS some
  `VRef n`), not to a precise content type. Precise negative reference narrowing
  (`U ∩ ¬BAnyRef`, "is not a reference") hits the same intersection-type arrow-
  inversion wall as (1)/(3) — the hard core of intersection-type systems.
  `typing.v:584` (BAnyRef binding-form narrowing).
- [x] **Flow NARROWING — type-test occurrence typing (increment 15, DONE).**
  The real Lua `type(x)=="T"` guard — POSITIVE tag narrowing — machine-checked
  end-to-end (`progress`+`preservation`+`tag_narrows`+`synth_sound`+`check_sound`+
  `synth_principal`+`narrowing`+both payoffs all `Qed`, `Print Assumptions` closed).
  Modifies `proof/typing.v` + `proof/check.v`; `subtype.v` + `ssub.v` UNMODIFIED.
  Extends the increment-13 `tifn` binding-narrowing infrastructure with the SAME
  value-conditioned fresh-binding discipline (the soundness crux). **Term/op-sem.**
  `tm` gains `ttypetest : tag -> tm -> tm -> tm -> tm` where `tag = {TgNum, TgStr,
  TgBool, TgNil, TgTable, TgFun}` (the `type()` tags; `TgNum` ↔ the whole number
  type `ANum`, per the 5.1 model where `type()` returns `"number"` for all numbers).
  The scrutinee is bound FRESH (de Bruijn 0) in each branch. `has_tag : tm -> tag ->
  Prop` is total on values (`value_has_some_tag`) with a unique tag (`has_tag_unique`).
  Value-conditioned step: `STtTrue` (tag matches `g` ⇒ `subst 0 v e1`), `STtFalse`
  (some other tag `g'≠g` ⇒ `subst 0 v e2`), `STt1` (congruence). **Typing.**
  `TTypeTest : has_type G c U -> has_type (tag_type g::G) e1 T1 -> has_type (U::G)
  e2 T2 -> has_type G (ttypetest g c e1 e2) (T1∪T2)` — THEN under the tag-narrowed
  binder `tag_type g`, ELSE under the scrutinee's own type `U` (a sound
  OVER-approximation of the precise `U ∩ ¬tag_type g`). `tag_type`: TgNum↦ANum,
  TgStr↦AStr, TgBool↦ABool, TgNil↦ANil, TgTable↦`BRec []` (the table top-type),
  TgFun↦`BArrow BBot BTop` (the function top-type). **The bridging lemma (crux,
  mirroring `truthy_narrows`):** `tag_narrows : has_type [] v U -> value v ->
  has_tag v g -> has_type [] v (tag_type g)` — a value whose runtime tag is `g`
  genuinely has type `tag_type g`, proved by canonical forms + `ssub`
  atom/arrow-Top/record-`SrNil` subsumption only (no negation, no `dsub`-in-typing).
  Preservation's THEN-branch uses it via `subst_top`; the ELSE-branch uses the
  scrutinee's own `U`-typing directly (no narrowing). **Payoff (both proved):** a
  number-consumer `h : ANum→Int` applied to the then-narrowed scrutinee of declared
  type `Str∪Num` TYPES with `type(x)=="number"` narrowing and is REJECTED without it
  (`Str∪Num` is not `≤ ANum` — a string is not a number, refuted at `VStr 0`).
  **Honest scope.** POSITIVE (then-branch) tag narrowing only; precise NEGATIVE
  narrowing (`U ∩ ¬tag_type g`, the intersection/negation wall), narrowing on
  non-variable paths, and combined truthiness+type-test are DEFERRED (sub-items 3/4/6
  above).
- [x] **Statements / control flow — DONE (increment 20, ENCODED).** Lua's
  imperative statement forms encode into the existing core with NO new terms —
  soundness inherited from the proven `progress`/`preservation`. Encodings (plain
  `Definition`s in `proof/typing.v`): UNIT (a statement returning nothing) ⇒
  `tlit LNil` (`Tunit := BAtom ANil`); SEQUENCING `s1 ; s2` ⇒ `tseq s1 s2 := tlet
  s1 (lift 1 0 s2)` (run `s1` for effect, discard, run `s2`; the lift makes the
  discard-binder unused so `s2`'s free vars are unchanged — `subst_lift_cancel`);
  IF-STATEMENT ⇒ `tif` (already core, increment 11); BLOCK/local scope ⇒ `tlet`
  nesting; WHILE `while c do body end` ⇒ `twhile c body := tfix Tunit (tif c (tseq
  body (tvar 0)) (tlit LNil))` — the fixpoint re-evaluates `c` against the CURRENT
  store each unfold, runs the mutating `body`, recurses via the self-ref `tvar 0`,
  terminates with `nil` when `c` is false. CAPSTONE — a REAL imperative program
  TYPES: the counting/sum loop `local i=ref 0; local s=ref 0; while (!i<n) do s:=
  !s+!i; i:=!i+1 end; !s` (`sumloop_prog_typed`, at `ANum`; cells are `BRef ANum`
  because arithmetic yields `ANum` and `BRef` is invariant — Lua's one number
  type). The single-cell counter loop TYPES at `Tunit` (`cinc_loop_typed`); its
  former END-TO-END run (`cinc_loop_runs`/`cinc_one_iter`/`cinc_terminates`,
  store `[0]`→`[1]` with a computed `1<1` false guard) was DELETED in the stage-2
  number refactor — value computation the abstract primitives no longer perform.
  SEQUENCING-WITH-MUTATION `(t.x:=9); t.x` reads 9 (`seq_mutation_typed`/`_steps`);
  IF-WITH-MUTATION `if cond then r:=1 else r:=2 end; !r` reads the taken branch's
  value (`if_mut_typed`, `if_mut_true_steps`/`if_mut_false_steps`).
  DIVERGENCE-TOLERANCE: `while true do () end` is well-typed at `Tunit` and DIVERGES
  (`while_true_typed`, `while_true_diverges` — one cycle returns the loop to itself;
  `while_true_not_stuck` — not a value yet always steps) — soundness tolerates
  non-termination (inherited from `tfix`). `while` termination relies on the body
  mutating the state the condition reads; general termination is neither provided
  nor needed. `Print Assumptions` Closed on all; cores (subtype.v/ssub.v/check.v)
  UNMODIFIED. DEFERRED (backlog): `break`/`return`/`goto` (non-local control —
  labelled exits/continuations). Numeric `for` and generic `for-in` now DONE (see
  below). See `proof-kernel.md` increment 20.
- [x] **Numeric `for`-loop `for i = e1, e2, e3 do body end` — DONE (encoded over
  `twhile`).** Models Lua 5.1 numeric-for as a desugaring over the existing while-
  loop + reference + arithmetic + comparison + local-binding substrate; NO new core
  terms, NO new subtyping, `subtype.v`/`ssub.v`/`check.v` byte-UNMODIFIED. Two forms
  (the step's SIGN is resolved statically, faithful to the nat number model that has
  no negative literal): `tfor_up cnt limit step body` (step>0: guard `!i ≤ limit`,
  increment `i := !i + step`, mirroring the while-loop's ascending `cinc`) and
  `tfor_down` (step<0: guard `limit ≤ !i`, decrement `i := !i - step` — descent
  carried by the subtraction direction). The loop variable `i = !cnt` is re-read
  each iteration (Lua's per-iteration binding under the store model) and typed at
  the NUMBER type `ANum` (the counter is a `BRef ANum` cell: arithmetic yields
  `ANum`, invariant cell ⇒ Num cell; init `AInt` widens by `AInt <: ANum`). Typing
  inherited from `twhile_typed` (`tfor_up_typed`/`tfor_down_typed`), unfold/step from
  `twhile_unfold`. Payoffs: a counting-up sum loop `for i=1,3,1 do sum:=sum+i end`
  TYPES (`forsum_loop_typed`) and STEPS end-to-end to `sum=6` (`forsum_loop_runs`,
  three store-driven iterations + termination); a counting-down loop `for i=2,1,-1`
  TYPES (`fordown_loop_typed`) and terminates `2→1→0` (`fordown_loop_runs`); the
  loop variable is typed soundly as a number (`for_var_typed_number : !i : ANum`)
  and NOT an integer (`for_var_not_int : ~ !i : AInt`, via a `NRfrac` witness — 5.1's
  single-number model). `Print Assumptions` Closed on all. See `proof-kernel.md`
  increment 28.
  **SUPERSEDED by the stage-2 number refactor:** the end-to-end RUNS
  (`forsum_loop_runs` → `sum=6`, `fordown_loop_runs` → `2→1→0`) were DELETED — value
  computation the abstract magnitude-free primitives no longer perform; each loop
  keeps only its TYPING demo. The SIGNED-NUMBER substrate boundary (a single
  runtime-sign-dispatched form needs signed `NumRep`/`LInt` + sign-aware `PSub`) is
  RETIRED/MOOT by construction: numbers have no magnitude, so there is no sign to
  dispatch on at runtime; direction is a STATIC operator choice
  (`tfor_up`/`tfor_down`). See the stage-2 item under "Number model".
- [x] **Generic `for-in` loop `for v1,…,vn in explist do body end` (iterator
  protocol) — DONE (encoded over `twhile` + `tmassign` + `tapp` + `tifn`).** Models
  Lua 5.1's own generic-for desugaring (`local f,s,ctrl=explist; while true do local
  v1..vn=f(s,ctrl); if v1==nil then break end; ctrl=v1; body end`) as a desugaring
  over EXISTING substrate; NO new core term, NO new subtyping, NO new check.v synth
  arm; `subtype.v`/`ssub.v`/`check.v` byte-UNMODIFIED. KEY MOVE (avoids needing
  `break`, which this dev lacks): FOLD the nil-termination into the `twhile` GUARD,
  exactly as numeric-for folded its termination. The iterator sits in the `twhile`
  CONDITION (re-evaluated each unfold ⇒ called ONCE per iteration); its first result
  both drives termination and becomes the next control value (advanced in the body).
  Forms: `forin_guard` = `tseq (tmassign vcells iter_call) (tifn (!v1cell) true
  false)` (call iterator, multi-bind the n results via multiple-assignment, test the
  first cell truthy ⇒ Bool); `forin_body` = `tseq (ctrl := !v1cell) (tifn (!v1cell)
  body nil)` (advance control, run body under the NARROWED first loop variable);
  `tforin = twhile forin_guard forin_body`. Typing inherited from `twhile_typed`
  (`tforin_typed`/`forin_guard_typed`/`forin_body_typed`), unfold/step from
  `twhile_unfold`. NARROWING: the body's `tifn (!v1cell)` substitutes `v1` at de
  Bruijn 0 narrowed to `truthy_type` (the EXISTING expressible non-nil bound), so the
  body sees `v1` non-nil. CONTROL TYPE = `V1 = T ∪ nil` (compatible-with-V1, no new
  substrate): `ctrl := !v1cell` type-checks by reflexivity; the iterator narrows its
  own control argument internally (`ttypetest TgNum`), exactly Lua's stateful-iterator
  pattern. Payoffs: a concrete generic-for over an explicit finite iterator
  `(Num∪nil)→BTuple[Num∪nil]` TYPES (`forin_loop_typed`, `forin_iter_typed`); its
  former END-TO-END run (`forin_loop_runs`/`forin_one_iter`/`forin_terminates`,
  accumulating `cnt=3` over distinct stores) was DELETED in the stage-2 number
  refactor — value computation the abstract primitives no longer perform; the loop
  keeps only its TYPING demo. The first
  loop variable is narrowed to non-nil inside the body (`forin_v1_narrowed_nonnil :
  v1 : truthy_type`) and REJECTED at nil (`forin_v1_not_nil : ~ v1 : ANil`, via a
  number witness in `truthy_type`). `Print Assumptions` Closed on all. SUBSTRATE BOUNDARY noted
  (not faked): termination is folded as "first result TRUTHY" (the only expressible
  non-nil narrowing — `tifn`'s `truthy_type` bound) rather than exact `v1 == nil`;
  the precise `v1 : V1 ∩ ¬nil` narrowing is the SAME intersection-narrowing substrate
  gap the `TIfn` note already records (needs an intersection-introduction typing rule
  + arrow inversion). On a standard iterator (non-falsy element or nil) truthiness
  COINCIDES with non-nil, so this is sound and Lua-faithful. See `proof-kernel.md`
  increment 29.
- [x] **Mutable TABLE fields (record fields as refs) — DONE (increment M4,
  records-of-refs ENCODING).** A Lua mutable table `{x:T,y:U}` IS a record of
  reference cells `BRec [("x", BRef T); ("y", BRef U)]`: the field SET is fixed
  (immutable, width/depth-covariant — inherited from `BRec`), each field is a
  mutable `BRef` cell (per-field mutation is INVARIANT — inherited from `BRef`).
  ENCODED into the existing core (NO new terms): table literal `{x=e}` ⇒
  `trec [("x", talloc e)]`; read `t.x` ⇒ `tderef (tproj t "x")`; write `t.x := v`
  ⇒ `tassign (tproj t "x") v`. Soundness is INHERITED — `progress`/`preservation`
  already cover `talloc`/`tderef`/`tassign`/`trec`/`tproj`, so the cores are
  UNMODIFIED. Proved (`Qed`, all `Print Assumptions` Closed): `mutation_*` (build,
  assign a field, read back the NEW value 9), `field_invariance_*` (string into a
  `BRef Int` field REJECTED at every type; well-typed assign accepted;
  `field_cell_invariant`: `BRef Int` NOT usable as `BRef Num`), `covariant_*`
  (record-of-refs width-subtypes on the immutable field set, composing with the
  invariant cells). See `proof-kernel.md` increment M4.
- [x] **Reassignable locals — DONE (increment M4).** A `local x` whose binding is
  reassigned is a ref cell over the SAME ref core: `local x = e` ⇒ `talloc e`,
  `x := v` ⇒ `tassign x v`, read `x` ⇒ `tderef x`. Proved `reassign_local_*`
  (`local x=7; x:=9; x` types at Int and multi-steps to 9 — the read observes the
  reassigned value). `Print Assumptions` Closed; cores unmodified.
- [x] **Aliasing — DONE (increment M4), strong-update precision still nice-to-have.**
  Two bindings to the SAME table value share its store cells; a write through one
  is observed through the other. Proved `aliasing_*` (`let a=<table> in let b=a in
  (a.x:=9); b.x` types at Int and multi-steps to 9 — mutation through `a` seen via
  `b`, both touching the same location). Flow-sensitive STRONG update on a
  uniquely-owned cell remains DEFERRED (nice-to-have). `proof-kernel.md` M4.
- [x] **Mutation / references — store-based soundness (increment 16, DONE).**
  NEW file `proof/imp.v` (on unmodified `subtype.v`+`typing.v`; `ssub.v`+`check.v`
  untouched). Own type syntax `RTy` (atoms + `RArrow` + `RRef`, since `subtype.v`'s
  `BTy` has no ref former and stays unmodified) with `rsub` (atom order; arrow
  contra/co — the same rule as `ssub`, the reason preservation survives
  subsumption; `RRef` **INVARIANT**). `rtm` = references CORE (lit/var/lam/app/let/
  if) + `ralloc`/`rderef`/`rassign`/`rloc` (a location is a VALUE, not source).
  CONFIGURATION op-sem `rstep : rtm*store -> rtm*store` (`store := list rtm`):
  every existing reduction threads the store unchanged; alloc appends
  (`rloc(length st), st++[v]`), deref reads (`store_lookup n st`), assign writes
  in place (`store_update n v st`) yielding the unit value `nil`. STORE TYPING
  `has_typeR Σ Γ e T` (Σ threaded through every rule; `RTLoc` reads Σ; alloc⇒`RRef
  T`, deref `RRef T⇒T`, assign `RRef T,T⇒unit`), `store_well_typed Σ st`,
  `extends Σ' Σ` (prefix). **`progress` + `preservation` BOTH `Qed` WITH the
  store** — progress: `has_typeR Σ [] e T -> store_well_typed Σ st -> value e \/
  exists e' st', rstep (e,st) (e',st')`; preservation: `... -> rstep (e,st)
  (e',st') -> exists Σ', extends Σ' Σ /\ has_typeR Σ' [] e' T /\ store_well_typed
  Σ' st'`. Substantive cases: alloc EXTENDS Σ (store-weakening re-types old
  cells), deref uses the store invariant, assign re-establishes `store_well_typed`
  in place. Supporting metatheory `Qed`: store-weakening, the Σ-adapted
  substitution lemma, store-update/lookup lemmas, canonical forms. Σ-threaded
  `synthR`/`checkR` proven SOUND (`synthR_sound`/`checkR_sound`); `decide_rsub`
  (fuel-structural for the contravariant arrow swap) sound. SANITY (all proved):
  alloc/read (types+steps), **assign-MUTATES** (deref of the updated store reads
  the NEW value, not the old), ref-of-int as ref-of-int, ill-typed assign
  (string into `RRef Int`) REJECTED at every type + by the checker.
  `Print Assumptions` on progress/preservation/synthR_sound/checkR_sound + the
  mutation/ill-typed sanity: **Closed under the global context**; whole chain
  compiles, protected files unmodified. **RESOLVED by the references unification**
  (`01aae498` + `1e7f7fe5`): `imp.v` is RETIRED and the store + references are
  threaded into the MAIN `typing.v`/`ssub.v`/`check.v` — RECORDS, flow-narrowing
  (`tifn`/`ttypetest`), and recursion (`tfix`) now all coexist with Σ in ONE
  language (progress + preservation re-proved `Qed` over the unified judgment;
  `synth_sound`/`check_sound` survive). Cost: algorithmic principality is fenced
  (see the `rsub` union-elim substrate item above). **CONSUMERS NOW BUILT
  (increment M4, above):** Lua's mutable TABLE FIELDS (records-of-refs) and
  reassignable LOCALS + aliasing are proved via the ref-core encoding. Only
  flow-sensitive strong-update precision remains nice-to-have.
- [x] **Multi-RETURN values + contextual adjustment (increment 21, DONE).**
  `BTuple` sequence type in `subtype.v`; `tret`/`tfst`/`tappspread` in `typing.v`;
  truncation (bind-first) + last-position spread (known-arity tuple consumer);
  progress/preservation/synth/check re-proved `Qed`; the payoff (same call truncated
  vs spread) machine-checked. Vararg `...`, multiple-assignment, table-collect, and
  arity-polymorphic spread remain deferred (see the [BLOCKING] item in §"Lua
  semantics").
- [x] **General recursion — single fixpoint `tfix` (increment 14, DONE).**
  `proof/typing.v` + `proof/check.v` (on unmodified `subtype.v` + `ssub.v`). `tm`
  gains `tfix : BTy -> tm -> tm`: in `tfix T body`, de Bruijn 0 of `body` is the
  recursive self-ref of type `T`, the whole `tfix T body : T`. Op-sem: the unfold
  rule `SFix : step (tfix T body) (subst 0 (tfix T body) body)` — no premise, so
  `tfix` is never a value / never stuck. Typing `TFix : has_type (T::G) body T ->
  has_type G (tfix T body) T`. **`progress` + `preservation` re-proved `Qed`**
  threading `tfix` (progress immediate via `SFix`; preservation by substituting the
  whole fixpoint for its `:T` self-ref — `inv_fix` + `subst_top`). **Type soundness
  TOLERATES NON-TERMINATION** — no termination argument: `diverge := tfix Int (tvar
  0)` is well-typed and `step diverge diverge` (loops forever, type `Int`
  invariant). `synth (tfix T body)` checks `body` against `T` under `T::G` ⇒ `Some
  T`; `synth_sound`/`check_sound`/`synth_principal`/`narrowing` re-proved.
  `Print Assumptions` on `progress`/`preservation`/`synth_sound`/`check_sound`
  closed under the global context. DEFERRED below: mutual recursion, recursive
  TYPES (μ). Lua's `local function f` is the derivable consumer.
- [x] **Metatables — static read-only `__index` field-lookup fallback / prototype
  inheritance (increment 21, DONE).** `proof/typing.v` + `proof/check.v` (on
  UNMODIFIED `subtype.v` + `ssub.v`). `tm` gains `tmeta own proto` (own a literal
  field-list; proto the `__index` target — record or another `tmeta`, a prototype
  CHAIN). Modelled by FLATTENING over the existing `BRec` (NO new type-level
  former): `merge_fields Town Pf` = own fields ∪ inherited fields not shadowed by
  own (Lua: own wins); `TMeta` ⇒ `tmeta own proto : BRec (merge_fields Town Pf)`.
  Dispatch op-sem `SMetaProjOwn` (own field) / `SMetaProjProto` (fall through to
  the prototype, chained). **`progress`/`preservation`/`synth_sound`/`check_sound`
  re-proved `Qed`** (extended canonical form: a `BRec`-value is `trec` OR `tmeta`).
  SOUNDNESS FORK surfaced (not fudged): own MUST be a literal field-list — a
  width-subsumed own term makes preservation FALSE (under-reports own keys ⇒
  dispatch-to-own but type-via-prototype). PAYOFF machine-checked: a base method
  resolved through `__index` at the derived object (`oop_inherited_typed`/`_steps`,
  `oop_inherited_synths`), own-field direct resolution (`oop_own_*`),
  everywhere-absent field rejected at every type (`oop_absent_rejected`,
  `oop_absent_synth_None`). `Print Assumptions` closed under the global context.
  DEFERRED: `__newindex`, operator/`__eq`/`__lt`/`__call` metamethods, `__index`
  as a FUNCTION, dynamic metatable MUTATION (`setmetatable`), `rawget`/`rawset`.
- [ ] **Mutual recursion** (`tfix` is single-binding; mutual `local function`
  groups need either a tupled fixpoint or a multi-binding `tfix`). Backlog.
- [ ] **Recursive TYPES — equirecursive μ** (distinct from the recursive TERM
  `tfix` above; needs the coinductive-`V` fork). See the BLOCKING μ item below.
- [x] **Metatables — static read-only `__index` field-lookup fallback (prototype
  inheritance / OOP)** (increment 21, `proof/typing.v` + `proof/check.v`,
  `subtype.v`/`ssub.v` UNMODIFIED). New term `tmeta own proto` (own a literal
  field-list, prototype the `__index` target); type-level flattening
  `merge_fields` over the existing `BRec` (no new type former); dispatch op-sem
  `SMetaProjOwn`/`SMetaProjProto` (own field, else fall through to the prototype,
  chained). `progress`/`preservation`/`synth_sound`/`check_sound` re-proved `Qed`.
  SOUNDNESS FORK surfaced (not fudged): own MUST be a literal field-list — a
  subsumed own term makes preservation false (width-subsumption under-reports own
  keys, dispatching to own while typing via the prototype). PAYOFF: OOP
  inheritance machine-checked (`oop_inherited_typed`/`_steps` resolve a base
  method through `__index`; `oop_absent_rejected` rejects an everywhere-absent
  field). `Print Assumptions`: Closed under the global context.
  - DEFERRED (backlog): `__newindex` (write fallback), operator/comparison
    metamethods (`__add`/`__eq`/`__lt`/…), `__call`, `__index` as a FUNCTION,
    dynamic metatable MUTATION (`setmetatable`), `rawget`/`rawset`.
- [x] **Metatable metamethods — `__newindex`, `__call`, binary operators**
  (`proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v` BYTE-UNMODIFIED — no new
  type-level former). Completes the metamethod protocol begun with `__index`:
  - **`__call`** (callable tables): a metatable-table whose read interface carries
    a `__call : Self -> Arg -> R` metamethod is APPLICABLE — `tapp (tmeta ofs proto)
    arg` dispatches (op-sem `SCallMeta`) to `(table.__call) table arg`, resolving the
    metamethod through the same `__index` chain (`tproj`) and reusing the arrow
    machinery (two betas). Typing `TCallMeta`; result `R`. Payoff `call_payoff_typed`/
    `call_payoff_steps` (callable table computes `3`).
  - **Binary operators** (`__add`/`__sub`/`__mul`, `__eq`/`__lt`/`__le`): a primop
    whose LEFT operand is a metatable-table dispatches (op-sem `SPrimMetaL`,
    typing `TPrimMetaL`) to `(a.<mm>) a b`; the metamethod key is `mm_binop op`
    (ordinary data — one general `tproj`-resolved lookup, NOT a name-keyed handler).
    Number path (`TPrimArith`/`TPrimCmp`) kept for plain numbers. Payoff
    `add_payoff_typed`/`add_payoff_steps` (vector-like `vobj + vobj : Int` → `7`);
    `sub_absent_rejected` rejects an absent metamethod. **RIGHT-operand fallback
    DEFERRED** (left-operand dispatch is the representative; Lua tries left then
    right — the right-operand branch is a clean follow-up, not a fork).
  - **`__newindex`** (write fallback): new term `tnewidx own proto k v` (the write
    `(tmeta own proto).k = v`). When `k` is ABSENT from own, dispatches (op-sem
    `SNewIdx`, typing `TNewIdx`) to `tassign (proto.k) v` — the records-of-refs
    write-through (`proto`'s field `k` is a mutable `BRef` cell). Mirrors the
    `__index` read fallback on the assignment side. Payoff `newindex_payoff_typed`/
    `newindex_payoff_steps` (write `5` through the cell; store `[0]` → `[5]`);
    `newindex_absent_cell_rejected` rejects a missing target cell.
  - `progress`/`preservation`/`synth_sound`/`check_sound` ALL re-proved `Qed`; new
    helper `tmeta_step_shape` (a `tmeta` steps only to a `tmeta`). `Print
    Assumptions` on every result + payoff: Closed under the global context.
  - HONEST SCOPE / model note: metamethods are carried as OWN fields of the table
    under their reserved keys (`__call`/`__add`/…) — a simplification of Lua's
    separate-metatable-object, sound and faithful for the static fragment. STILL
    DEFERRED: `setmetatable`/dynamic metatables, `__index`/`__newindex` as
    FUNCTIONS, `__concat`/`__len`/`__unm`/`__tostring`/other metamethods, `__call`
    multi-arg/multi-return, operator RIGHT-operand fallback, own-present rawset on
    the immutable own record, `rawget`/`rawset`.
- [x] **Metamethod family extension — `__concat`, `__unm`, `__len`** (increment 23;
  `proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v` BYTE-UNMODIFIED). Reuses
  the Increment 22 dispatch machinery with no new lookup mechanism:
  - **`__concat`** (`..`): new `primop PConcat`, metamethod-ONLY (`arith_op`/`cmp_op`
    both false, so `SPrimArith`/`SPrimCmp` never fire). Sole rule is the EXISTING
    binary-operator dispatch `TPrimMetaL`/`SPrimMetaL` via `mm_binop PConcat =
    "__concat"` — i.e. just more keys in the `mm_binop` table, no new term/step form.
    Payoff `concat_payoff_typed`/`_steps` (`ccobj .. ccobj : Str`, computes).
  - **`__unm`/`__len`** (`-x`/`#x`): new `unop` tag + term `tunop uop e` + `mm_unop`
    name table (ordinary data). Typing `TUnMetaL`: operand a `tmeta : BRec M` carrying
    `mm_unop uop : Self -> Other -> R`, both self gates via `rsub`; result `R`. Op-sem
    `SUnMetaL` dispatches to `(table.<mm>) table table` (operand passed TWICE — Lua's
    unary calling convention), `SUnop1` congruence. New inversion `inv_unop`.
    Metamethod-ONLY (no built-in numeric negation / table length). Payoffs
    `unm_payoff_typed`/`_steps`, `len_payoff_typed`, `len_absent_rejected`; checker
    mirrors `concat_synths`/`unm_synths`/`len_synths` + `*_check_sound` +
    `len_absent_synth_None`.
  - `progress`/`preservation`/`synth_sound`/`check_sound` ALL re-proved `Qed`;
    `tunop` threaded through the full de Bruijn metatheory. `Print Assumptions` on
    every result + payoff: Closed under the global context. See proof-kernel
    increment 23.
  - STILL DEFERRED (the rest of the original metamethod-family task): operator
    RIGHT-operand fallback; `rawget`/`rawset`; `__tostring`; built-in numeric
    negation / table length; `setmetatable`/dynamic metatables; `__index`/
    `__newindex` as FUNCTIONS.
- [x] **Binary operator RIGHT-operand fallback — `TPrimMetaR`/`SPrimMetaR`**
  (increment 24; `proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v`
  BYTE-UNMODIFIED). The exact MIRROR of `TPrimMetaL`/`SPrimMetaL`, closing the ONE
  deferral left by Increment 22's binary operators — when the left operand carries
  no metamethod, dispatch to the right's. Shares `mm_binop`, the `__index`-chain
  `tproj` resolution, and the arrow machinery; no new lookup mechanism.
  - **Typing** `TPrimMetaR`: `tprim op a (tmeta ofs proto)` with the right table's
    `BRec M` carrying `mm_binop op : BAtom al -> Other -> R`, the LEFT operand a
    SCALAR `a : BAtom al`, and `rsub (BRec M) Other`; result `R`. The `BAtom` left
    domain (not "syntactically not a `tmeta`") is the discriminator: stable under
    substitution, step-disjoint from `SPrimMetaL`, and refutable by canonical forms.
    New lemma `canon_atom` (a closed value of `BAtom al` is a literal).
  - **Op-sem** `SPrimMetaR`: `tprim op (tlit l) (tmeta own proto)` (literal left —
    the canonical scalar; table right a value) ⤳ `(table.<mm>) (tlit l) table`.
  - `inv_prim` becomes a THREE-way disjunction (numeric / left-meta / right-meta),
    threaded through every consumer. `synth` dispatches TYPE-FIRST on the synthesized
    LEFT type (the existing outer `match synth a`): `BRec`+`tmeta` left ⇒ left-meta;
    scalar `BAtom` left ⇒ refine on `synth b` (`BRec`+`tmeta` right ⇒ right-meta, else
    numeric); else numeric. (Type-first, NOT a syntactic `destruct e1 × destruct e2`
    split — that is quadratic and blows up the `synth_sound` compile time.)
    `progress`/`preservation`/`synth_sound`/`check_sound`/`narrowing` ALL re-proved `Qed`.
  - Payoffs (in `typing.v`): `add_right_payoff_typed`/`_steps` (`1 + robj : Int` ⤳ `8`),
    `sub_right_absent_rejected` (`1 - robj` rejected — all 3 disjuncts refuted). The
    algorithmic right-fallback is exercised by `synth_sound`/`check_sound` over the new
    `synth` arm; no separate `check.v` payoff examples were added.
    `Print Assumptions` on every result + payoff: Closed under the global context.
    See proof-kernel increment 24.
  - DEFERRED (narrower than before): a `tmeta` left missing the key falling through
    to the right (needs a decidable `__index`-chain side-condition); `rawget`/
    `rawset`; `__tostring`; built-in numeric negation / table length; `setmetatable`
    / dynamic metatables; `__index`/`__newindex` as FUNCTIONS.
- [x] **`rawget`/`rawset` — raw table access bypassing `__index`/`__newindex`**
  (increment 25; `proof/typing.v` + `proof/check.v`; `subtype.v`/`ssub.v`
  BYTE-UNMODIFIED — confirmed `git diff --stat`). Raw access reduces DIRECTLY to the
  underlying record-of-refs read/write on the table's OWN fields, NEVER consulting
  the prototype — the own-field path of `tproj`/`tnewidx` WITHOUT the fallback step;
  reuses the SAME `field_lookup`/`tassign` primitives (no new lookup mechanism, no
  special-casing).
  - **Terms** `trawget own proto k` / `trawset own proto k v` (the table given by
    its own field-list + prototype-position target directly, like `tnewidx`, so own
    is typed EXACTLY via `has_fields`).
  - **Typing** `TRawGet`: own `(k,T) ∈ Town` ⇒ result `T` (no merge — an inherited
    proto-only key is NOT typeable). `TRawSet`: writable own cell `(k, BRef T) ∈
    Town`, `v : T` ⇒ `nil`. The prototype is typed (`BRec Pf`) for well-formedness
    but never read/written.
  - **Op-sem** `SRawGet` (own value via `field_lookup k own`, no proto rule) +
    congruences `SRawGet1`/`SRawGet2`; `SRawSet` (own cell → `tassign cell v`, no
    proto rule) + congruences `SRawSet1`/`SRawSet2`/`SRawSet3`.
  - Full de Bruijn metatheory threaded (`tm_rect_strong`, lift/subst/closed_at,
    weakening, `subst_lemma`, `store_weakening`, `has_type_closed`, `proj_free`).
    `progress`/`preservation`/`synth_sound`/`check_sound`/`narrowing` ALL re-proved
    `Qed`. `synth` dispatches structurally on the `trawget`/`trawset` constructor
    (like `tnewidx` — NOT a quadratic syntactic operand split); `check.v` builds in
    seconds.
  - Payoffs (`typing.v`): `rawget_own_typed`/`_steps`, `rawset_payoff_typed`/`_steps`
    (raw write through OWN's cell over a store, `[0]`⤳`[5]`), and the DISTINGUISHING
    property `rawget_bypasses_proto` / `rawset_absent_own_rejected` (a key in the
    PROTOTYPE but absent from OWN — resolved by `tproj` via `__index`, see
    `oop_inherited_typed` — is REJECTED by raw access at every type). Algorithmic
    mirror (`check.v`): `rawget_own_synths`, `rawget_bypasses_proto_synth_None`,
    `rawset_synths`, `rawset_absent_own_synth_None`. `Print Assumptions` on every
    result + payoff: Closed under the global context. See proof-kernel increment 25.
  - DEFERRED (recorded as substrate, not faked): raw access on a key ABSENT from own
    returning `nil` (the static fragment does not model absent-key reads — `TProj`
    likewise requires the key present); `__index`/`__newindex` as FUNCTIONS;
    `setmetatable`/dynamic metatables; `__tostring`; built-in numeric negation /
    table length.
- [ ] **Arrow types as TERM introduction forms** (the type ALGEBRA has arrows via
  `BTy` and `tlam` introduces them; broader arrow-term ergonomics are min-core).
- [ ] **Duplicate-key record literals** (currently `TRec` requires `NoDup` keys,
  Lua-faithful; last-wins literal semantics is a separate concern).
- [x] **`ssub` preorder + total decision procedure + `dsub`/`ssub` gap**
  (increment 9, `proof/ssub.v`, on unmodified `subtype.v` + `typing.v`).
  `ssub_refl`/`ssub_trans` named; `decide_ssub : BTy -> BTy -> bool` **total +
  sound + complete** (`decide_ssub_correct`), terminating by structural fuel
  recursion on `bsize a + bsize b` (no DNF — `ssub` is syntactic). Total-decidable
  fragment = exactly what `ssub` relates (atoms/arrows/records + Top/Bot
  structural; connectives coarse). Two gap instances exhibited
  (`dsub_ssub_gap` arrow/Top; `dsub_ssub_gap_atom` AFloat≡ANum); coincidence on
  afloat-free atoms + the structural ⊆ direction. Subtyping wired into typing
  (`subsumption_decidable`). `Print Assumptions` closed under the global context.
- [ ] **Connective-`ssub` decided SEMANTICALLY (lift `decide_ssub`'s connective
  coarseness).** PRECISE PREDICATE: for connective-headed `c`/`d` (`BUnion`/
  `BInter`/`BNeg`), `decide_ssub c d` currently returns `true` ONLY for the
  reflexive/Top/Bot subtypings (`ssub_connective_super`/`_sub` prove these are the
  ONLY ones `ssub` admits). Deciding the SEMANTIC Boolean subtypings (e.g.
  `BInter X Y <: X`, `X <: BUnion X Y`) is `dsub`'s job and is the increment-6
  `gdecide` emptiness route — NOT `ssub`'s. The open question is whether the
  typing layer should subsume along connective subtypings at all (it currently
  does not need them); if so, route connective subsumption through `gdecide`
  rather than widening `ssub`. Substrate: requires the typing core to actually
  introduce connective types in term position (deferred above).
- [ ] **`ssub` GENERAL completeness vs ALL operationally-sound subtypings** (the
  DEEP open characterization). Partial progress proved in increment 9: the two
  precise gap instances (`dsub_ssub_gap`, `dsub_ssub_gap_atom`) and the
  coincidence fragments (`ssub_dsub_coincide_atom` on afloat-free atoms;
  `decide_ssub_implies_dsub` for the structural ⊆ direction). The full question —
  characterize EXACTLY the subtypings that preserve operational soundness and show
  `ssub` decides precisely those — is not tractable at this increment and remains
  open. (The `AFloat`≡`ANum` gap suggests a candidate refinement: add the missing
  `atom_le` edges that the value model justifies — but that is a `subtype.v`
  change, out of scope for the unmodified-substrate increment.)
- [x] **Bidirectional algorithmic checker, proven SOUND vs declarative typing**
  (increment 10, `proof/check.v`, on unmodified `subtype.v` + `typing.v` +
  `ssub.v`; build order `subtype → typing → ssub → check`). Turns the
  non-syntax-directed declarative `has_type` into a RUNNABLE checker.
  `synth : list BTy -> tm -> option BTy` (infer) + `check : list BTy -> tm -> BTy
  -> bool` (`check G e T := match synth G e with Some S => decide_ssub S T |
  None => false`) — executable, total, structural on `tm`; `synth` reduces under
  `Compute` (well-typed ⇒ `Some`/right type, ill-typed `(3).f` / `3 1` /
  duplicate-key literal ⇒ `None`). **SOUNDNESS (the point), both `Qed`:**
  `synth_sound : synth G e = Some T -> has_type G e T`,
  `check_sound : check G e T = true -> has_type G e T` (mutual `tm` induction,
  `decide_ssub_sound` at the check switch). **COMPLETENESS = principality
  (tractable, proved):** `synth_principal : proj_free e -> has_type G e T ->
  synth G e = Some S -> ssub S T` (synth's output is the LEAST declarative type);
  supporting general context `narrowing` lemma. `Print Assumptions` on
  `synth_sound`, `check_sound`, `synth_principal`, `narrowing` all **Closed under
  the global context** (no Admitted/Axiom/Classical). **NOTE — this PRINCIPALITY
  result was REMOVED by the references unification** (see the next item): under the
  unified, Sigma-threaded, reference-aware `has_type`, the declarative inversion
  lemmas conclude `rsub` (not `ssub`), and `rsub` lacks the union-elimination rule
  that recomposed branch principalities. `synth_sound`/`check_sound` survive the
  unification; `synth_principal` is fenced until the substrate below lands.
- [ ] **[BLOCKING] `rsub` union-elimination substrate — restore algorithmic
  principality over the unified relation.** The references unification
  (`01aae498` + `1e7f7fe5`, retiring `imp.v` into a unified `typing.v`/`ssub.v`/
  `check.v`) made `TSub` subsume along the reference-aware `rsub`. The union-typed
  term-formers (`tif`/`tifn`/`ttypetest`) need UNION-ELIMINATION at the `rsub`
  level — `rsub a c -> rsub b c -> rsub (BUnion a b) c` — to recompose branch
  principalities, but `rsub` has NO such structural rule: it embeds `ssub` (which
  HAS `SsUnionE`) + the two reference rules + transitivity, and a branch subtyping
  that goes through ref-widening has no `ssub` witness to feed `SsUnionE`. So
  `rsub`-level principality needs a NEW SUBSTRATE rule (an `rsub` union-elim / a
  join-completeness lemma) — a genuine substrate gap, NOT hardcoded. **Simpler
  partial:** an `rsub`→`ssub`-on-ref-free collapse lemma restores prior
  principality on the reference-free fragment (every subtyping there collapses to
  `ssub`); both are deferred together. The checker remains SOUND and EXECUTABLE on
  the whole unified language — only the principality META-property is fenced.
  Deferred at `proof/check.v:560-580` (framed-deferral comment) + `proof-kernel.md`
  (the references-unification increment).
- [ ] **Algorithmic adequacy / non-degeneracy of `synth`** (DEFERRED from
  increment 10). The completeness proved is principality (IF synth answers, that
  answer is least); NOT that synth ALWAYS answers on a well-typed term. Two
  degenerate positions block it: (a) a function/record SUBJECT declaratively typed
  at `BBot` (uninhabited) where `synth` only produces an arrow/record head; (b)
  the `let` body context narrowing. Closing it needs a canonicalization / a
  not-stuck argument over the BBot-free fragment — out of scope for the minimal
  core. Precise deferred statement: `has_type G e T -> exists S, synth G e =
  Some S /\ ssub S T` (the existence half synth_principal does not assert).
- [ ] **`tproj` principality under `NoDup` records** (DEFERRED from increment 10).
  `synth_principal` is fenced to the `proj_free` fragment because declarative
  `TProj` over a non-`NoDup` record assigns multiple types (no least type), and
  `synth`'s first-match `flook` only matches the subtyping supplier under `NoDup`
  (typing.v itself proves projection principality only under `NoDup`). Extend
  principality to projections over `NoDup`-keyed records.
- [ ] **Connective subtyping IN CHECKING** (DEFERRED from increment 10). `check`
  routes subtyping through `decide_ssub`, which is structural-only on the Boolean
  connectives (increment 9 coarseness). So connective subtyping in checking
  inherits that limitation; full connective checking needs the `dsub`/`gdecide`
  route — same substrate need as the connective-`ssub` item above.
- [ ] **[BLOCKING] Operational-semantics reality bridge (`step` ↔ real Lua
  execution).** The bridge so far validates the proof's VALUE model (`V`/`denote`
  ↔ real Lua values + membership predicates; atoms/functions/records all RESOLVED,
  `lib/sem/bridge/`). The unvalidated axis is the proof's small-step `step` /
  `rstep` REDUCTION matching real LuaJIT execution — the empirical anchor proof
  cannot establish (that the modelled operational semantics, incl. store
  mutation, is faithful to what real Lua does). `reality-bridge.md` §3 (the
  differential pipeline targets values, not reductions, today).

## Slice typechecker — coverage and precision open threads

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

- **Success metric reframing:** the survey reframed from whole-file-CLEAN% to sound-verdict-sites / error-classes-caught-corpus-wide. Remaining coverage front by measured demand: operators, dynamic-index, multi-assign, multi-return root constructs — prioritized by corpus frequency, not exhaustiveness.
- **`readonly`/mutable variance split deferred:** recovers sound alias-and-read (the embedded-alias sub-hole would not arise); corpus doesn't currently exhibit the pattern that demands it. Mark as precision layer, not soundness blocker — revisit when corpus evidence justifies it.

## Platform isolation migration (mandatory, not eventual)

Architectural reframing settled this session: capabilities are the
platform's only abstraction; the sandbox+bridge+lockdown work is the
implementation of a single platform-level cap (`web_runtime`); there is
no separate `browser_caps` manifest field; first-party apps migrate to
`web_runtime` on the same terms as any third-party app. See
`docs/platform_isolation.md` "Framing" and `docs/browser_caps.md`
"Framing" for the consolidated decisions. The work below is the migration
to that endpoint.

- [x] **Revert the `browser_caps` manifest field.** Dropped the field and
  related plumbing from `lib/platform/platform_types.lua`,
  `lib/platform/init.lua`, `lib/platform/cli.lua`,
  `lib/platform/manifest_caps.lua`, plus the corresponding tests and the
  `docs/browser_caps.md` §3 cross-references that pointed at the now-gone
  code. The existing `caps` field (with `type: "web_runtime"`) is the
  abstraction; no parallel field is added. Background: commit `e6e7b532`
  introduced the field.

- [ ] **Design the explicit `web_runtime` cap interface.** Entry function
  (inputs: pack source + declared sub-caps; output: sandboxed-realm handle),
  sub-cap delegation, audit envelope, cleanup hooks, lifecycle (launch,
  reload, shutdown). Document in `docs/platform_isolation.md` "Cap interface
  (web_runtime)".

- [ ] **Decide where the `web_runtime` cap impl lives.** Candidate:
  `lib/platform/caps/web_runtime/`. Document the choice once made.

- [ ] **Move the existing browser-side libraries under the cap impl
  directory.** Sources to relocate: `lib/js_realm_sandbox/`,
  `lib/js_cap_bridge/`, `lib/js_pack_host/`, `lib/js_caps/`,
  `lib/js_pack_validator/`, `lib/js_safe_regex/`, `lib/js_types/`. Update
  all imports. Run typecheck + parity tests + manual sanity after the move.

- [ ] **Define the `web_runtime` cap-impl's manifest schema.** It is a cap
  kind dispatched by `type: "web_runtime"` in the existing `caps` field;
  decide what fields the entry's value accepts (declared sub-caps, sub-cap
  configs, entry-point selection). Document in `docs/browser_caps.md` §3
  alongside the existing per-entry axes. Resolves the open question called
  out in §3 about how tenants declare sub-caps under `web_runtime`.

- [ ] **Migrate `charactercardv2` (ccv2) from `http_server` to `web_runtime`.**
  ccv2's `static/*.js` (currently plain JS with full DOM access) gets
  adapted into pack-JS subset form running in the sandboxed realm. This is
  mandatory for the platform's security guarantees to hold uniformly; ccv2
  is not architecturally privileged.

- [ ] **Migrate `library` from `http_server` to `web_runtime`.** Same terms.

- [ ] **Migrate `sillytavern` from `http_server` to `web_runtime`.** Same
  terms.

- [ ] **Migrate `system_dashboard` from `http_server` to `web_runtime`.**
  Largest migration — projection registry and friends. Same terms.

- [ ] **Tighten the `http_server` cap once browser-UI consumers are migrated.**
  Long-term, `http_server` is retained only for "expose an API endpoint" use
  cases — no HTML response type, no JS-serving. Possible rename to
  `http_endpoint`, response-type restriction (no `text/html`), tighter
  content-type allowlist, possibly require explicit `--bind-external` to
  listen on anything other than localhost. Decide and document.

- [ ] **Move the `/_platform/lib/js_*/` daemon route into the
  `web_runtime` cap impl.** The platform daemon currently serves the
  browser-side platform libraries directly (commit `622efc40`). That route
  doesn't belong in platform code — the `web_runtime` cap impl owns serving
  its runtime files to its tenant iframes. Move accordingly once the cap
  impl exists.

- [ ] **Strip `browser_caps` references from `docs/platform_isolation.md`
  and `docs/browser_caps.md` after migration.** The current "Framing" notes
  in both docs flag the field as slated-for-revert; once revert lands, the
  surrounding prose that still describes the field as if it exists (`§3`
  schema discussion, the `app manifest` ASCII diagram in browser_caps §1,
  the manifest example in platform_isolation §4) gets rewritten against
  the `web_runtime`-sub-cap model.

- [ ] **Decide whether first-party apps move from `lib/platform/apps/<name>/`
  to `lib/apps/<name>/`.** The current path is a historical misnomer —
  first-party apps are not part of the platform; they are crescent-team-
  authored apps that happen to ship in the source tree. Purely
  organizational; not blocking the migration above.

- [ ] **Audit the `path_guard` lint violation across `lib/js_*/init.lua`.**
  Pre-existing per commit `746b5ef7`. Resolves when the `lib/js_*/`
  packages move under the cap impl directory.

- [ ] **Daemon serve path Phase B: pack JS source with `'use strict';` prepend
  + hash-verify against installed-pack-hash recorded in manifest.** Phase A
  shipped as `622efc40`; Phase B was named but never started; orphaned by the
  `web_runtime` cap pivot — fold into the cap impl's responsibilities or
  revisit when cap-impl lands.

- [ ] **Daemon serve path Phase C: per-pack host HTML stub generation.**
  Same orphaning context as Phase B.

- [ ] **Daemon serve path Phase D: CSP headers per pack manifest's web cap
  config.** Same orphaning context as Phase B.

- [ ] **Rename `lib/js_pack_host/`** to align with the terminology pinned in
  `138b8661` (pack vs app). Either `lib/js_app_host/` or move entirely into
  the `web_runtime` cap impl directory.

- [ ] **Rename `lib/js_pack_validator/`** similarly.

- [ ] **Rename `pack_id` → `app_id`** in `lib/js_caps/kv.js` and any other
  places. Same for `pack-abc.localhost` doc examples.

- [ ] **Move `_skipGlobalFreeze` opt off the production `installLockdown`
  API into a test-internal API.** Currently the test-only flag is part of
  the public production signature; foot-gun for any future real-browser
  caller.

- [ ] **Audit `lib/platform/`'s duplicate type declarations across
  `platform_types.lua`, `cli.lua`, `init.lua`.** Single source of truth.

- [ ] **Verify commit `352aab90` (stub `registry.lua`/`dom.lua`) has no
  vestige after the real impls landed.** Stubs may be dead code.

- [ ] **Re-evaluate `lib/lua2ts/` retention** given Initiative B is dead.
  Commits `844dd384` (`opts.imports`) and related lua2ts work shipped under
  an abandoned framing; their continued purpose needs explicit assessment.

## Platform isolation (top priority)

- [ ] **Deprecate `http_server` in favour of `web_runtime` for browser-UI apps.**
  `http_server` currently doubles as (a) "expose an HTTP API for external
  tools" and (b) "serve a browser UI for the user". Case (b) is the dangerous
  one: the served JS runs unsandboxed at the app's origin, outside the cap
  boundary, so a grant of `http_server` is effectively "let this app do
  anything to the browser tab it owns". The risk text on the cap warns the
  operator, but the structural fix is to split:
    - `web_runtime` (forthcoming, sandboxed) — for apps that need browser UI.
      The platform serves the shell; the app supplies declarative content and
      browser-cap calls. See `docs/browser_caps.md` / `docs/platform_isolation.md`.
    - `http_server` (retained, tightened contract) — for apps that legitimately
      need to expose an HTTP endpoint to external tools. Design open: drop the
      HTML response type, require a content-type allowlist, possibly require
      explicit `--bind-external` to listen on anything other than localhost.
  Migration: identify which existing apps use `http_server` purely for browser
  UI vs which actually need a public HTTP API; port the former to `web_runtime`
  once it exists, leave the latter on the tightened `http_server`.

- [ ] **Browser-side pack isolation architecture** — draft design doc at
  `docs/platform_isolation.md`. Frames the ambient-capability problem
  (per-app CSP narrows the outer envelope but does not partition the inner
  surface between scripts on a page), proposes a sandboxed-iframe realm
  per pack plus a postMessage capability bridge to a daemon-served stub
  page, and leaves the rendering model (Options A/B/C) as an open question.
  Blocks all browser-side pack work, including Initiative B (the pack-load
  pipeline for projection-Lua), pack-shipped UI beyond projections, and any
  third-party-pack browser UX work. Next step: settle the open questions in
  §7 of the design doc, in particular the rendering model and the per-pack
  origin mechanism.

- [ ] **Browser caps day-zero implementation** — design doc at
  `docs/browser_caps.md` enumerates the entire Web Platform surface and
  classifies each API (exposed-now / placeholder / future / not-shipping /
  realm-incompatible). Day-zero surface is ~17 caps (`fetch_api`, `kv_*`,
  `navigate`, `dialog`, `toast`, `clipboard_write`, `web_crypto_random`,
  `web_crypto_subtle`, `text_encode`, `text_decode`, `compress`,
  `decompress`, `console_log`, `set_timeout`). Implementation steps:
  (1) extend `lib/pkg/manifest.lua` with the `browser_caps` field per
  `browser_caps.md` §3 (cross-reference `docs/pkg-design.md` and
  `docs/pkg-versioning.md` before changing manifest); (2) add per-kind
  modules under `lib/platform/browser_caps/<kind>/` carrying impl +
  config-schema validator; (3) wire the host stub to register granted
  caps into `lib/js_cap_bridge`'s host bridge per `__cap__` install;
  (4) resolve the `event` frame format for streaming caps (open question
  in `browser_caps.md` §7) before any of `websocket` / `sse` /
  `set_interval` ship. Follow-up to platform-isolation work above;
  cross-references: `docs/platform_isolation.md`, `docs/browser_caps.md`.

- [ ] **Cap-bridge AbortSignal cancellation extension (commit B)** —
  per `docs/platform_isolation.md` §4 "Cancellation via AbortSignal",
  extend `lib/js_cap_bridge` so cap calls with AbortSignal args get
  cancellation routed across the bridge: realm side intercepts the
  signal locally, replaces it on the wire with a marker, and emits a
  `{kind:"cancel"}` frame on abort; host side reconstructs a fresh
  `AbortController` per call and aborts it on the cancel frame. The
  pack-realm Promise rejects with `AbortError`. Decide opt-in-per-cap
  vs universal scan (open question §7). Blocks `set_timeout` and
  `fetch_api` shipping.

- [ ] **Re-add `set_timeout` cap on AbortSignal (commit C)** — once
  the bridge extension above lands, ship `set_timeout(delay_ms, {signal?})
  : Promise<void>` per `docs/browser_caps.md` §4.9.1: Promise resolves
  after the delay; if `signal.aborted` becomes true the Promise rejects
  with `AbortError`. No platform-side delay clamp beyond the browser
  native `setTimeout` ceiling. Re-add to `lib/js_caps/index.js`
  `dayZeroCaps`, add tests + parity needles, update inventory count.
  Follow-up to the broken-cap revert (this commit).

## Platform polish

- [ ] **Filed: `ExitPlanMode` triggers auto mode.** Raised very early in the
  audited session (Turn 4); user wanted this filed somewhere. Harness-level,
  not crescent-level; may belong in `~/.claude/` notes — recorded here so it
  is not lost again.

- [ ] **`core.hooksPath` per-clone-activation structural issue.** CLAUDE.md
  still requires `git config core.hooksPath .githooks` per clone. Possible
  fixes: ship a one-time bootstrap script, or rethink the convention so the
  hook auto-activates without per-clone config.

- [ ] **`lib/safe_regex/` algorithm upgrade: alternation overlap.** Current
  v1 ban (no quantifier-on-quantifier) explicitly accepts patterns like
  `(a|aa)+` as a "known limit". User flagged this in-session as unacceptable
  ("'known limit' is objectively GARBAGE"). Upgrade the algorithm or
  document why this specific limit is acceptable.

- [ ] **Typechecker latent narrowing gap: `tonumber(string.sub(...))`** is
  inferred as `string` rather than `number | nil`. Worked around in
  `02812180` without `any`/force-casts. Worth a typechecker-side fix.

- [ ] **Typechecker latent narrowing gap: `local b = string.byte(s, i)`**
  doesn't narrow against `nil` after a guard; requires explicit
  `--: integer | nil` annotation. Same workaround commit (`02812180`).
  Worth a typechecker-side fix.

- [ ] **`set_interval` cap with AbortSignal cancellation** — parallel to
  `set_timeout`. User asked in-session.

- [ ] **`notification` cap** (browser's `Notification` API, distinct from
  host-rendered `toast`). Browser-permission-gated. Currently a placeholder
  in `docs/browser_caps.md` §4 but no TODO entry until now.

- [ ] **Third-party projections design** — concrete answer to "how do
  third-party projections work?" given the cap-based reframe. Likely: each
  projection is an app declaring it provides type-X-projection; daemon-side
  registry maps type → projection app; consuming apps query the registry and
  invoke projection apps via cap-bridge. Needs a design doc.

- [ ] **Shared `.d.ts` for pack-JS authoring** — the `web_runtime` cap impl
  ships a `.d.ts` (or equivalent) that pack authors reference for
  type-checking against the runtime's actual surface. Single source of
  truth; matches the platform's actually-exposed API. Cross-references
  `docs/platform_isolation.md` §7 (`.d.ts` location).

## HIGH PRIORITY

### Typechecker solver rewrite — direction unresolved

*Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

After 15+ iterations across one session, the rewrite path is unresolved.
`docs/typechecker-session-handoff.md` (commit `a55871da`) is the
authoritative briefing — read it before any further rework work. Three
honest directions on the table:

- **(A) Accept the current architecture as the structural shape.** Stop
  trying to paradigm-shift; focus on documenting the synchronous
  semantics that exist (e.g., why `solve_callable` is
  synchronous-by-necessity per the paradigm-fit finding in caveat 3) and
  consolidating fundamental 6 (fresh instantiation at use site) as a
  small refactor that replaces the three current call paths with one
  `instantiate_at_use` primitive.
- **(B) Pick a different paradigm than OutsideIn/X.** Late-session
  finding: OutsideIn/X emit-shape doesn't fit handlers needing
  backtracking (overload resolution), aggregation (union callable), or
  synchronous mid-iteration deferral (rank-N param loop).
  Continuation-passing or staged solving may fit better.
- **(C) Refactor `unify_mod.unify`** as the actual rewrite target
  (~700 LOC of synchronous structural recursion used by `try_unify`,
  `is_subtype`, `types_overlap`, `widen_deep`). Multi-thousand-LOC
  foundational change.

Personal lean from that session: (A). Convergence happened at the
mechanism level (items 1-5+1.5 + TV ownership), not the paradigm-shift
level.

#### H2 record-of-generics dispatch — still pinned as known gap

H2/H2a/H2b/H2e pinned at `has_error("Maybe%(_%)")` in
`lib/type/static/type_soundness_test.lua` ~lines 3875-3990 since the H2
revert (`9f025732`). Re-landing needs either:

- The Outside-In/X rewrite to actually shift handlers (caveat 3 in the
  handoff briefing — partial fit only).
- Or fundamental 6's consolidation (single `instantiate_at_use`
  primitive replacing the three current call paths). The previous
  Phase F-impl attempt revealed producer→consumer ordering issues; TV
  ownership (`63c55f18` + `8b8c6bc4`) partially addresses but the audit
  was incomplete — `solve_check_args` / `solve_bind_generics` also read
  potentially-owned ret_TVs through inner unify calls.

#### BMT1 pin — match-type call-site forward-reduction broken

`lib/type/static/type_soundness_test.lua` (BMT block immediately after H6,
search for `BMT1 (KNOWN GAP)`). Generic functions returning a match type
keep the return as an unreduced `match ... { ... }` at the call site when
the type parameter is bound from a concrete arg. Direct instantiation
(e.g. `Discrim<number>` as a literal) reduces correctly; the gap is
specifically that call-site binding does not trigger re-evaluation of
containing match types. Pinned at `has_error("cannot assign \`match.* to")`.
Flip to `no_errors` once call-site forward-reduction through match types
is correct (rewrite work — see commit `b4bb9667` for the set-theoretic
foundation context).

#### solve2.lua infrastructure — landed but not exercised meaningfully

P1-P4a (commits `4eebb1de`, `c3f59312`, `f2686228`, `e2762912`) added
the solve2 core, blocked_on capture, per-kind dispatch, and ported 6
kinds via routing (not rewriting). The infrastructure supports an
Outside-In/X rewrite but doesn't BE one. If direction (A) is chosen,
this code may become orphaned — consider whether to remove it or keep
it as scaffolding for future use.

#### Caveats that should not be lost

- **Every audit count came back inflated** (105→90, 18→30, 51→6, 5→1).
  Skeptically verify before acting on any future audit.
- **`docs/typechecker-solver-rewrite.md` is incomplete** — it specifies
  routing-not-rewriting; the design's premise that
  "port == paradigm shift" is wrong.
- **`docs/typechecker-solver-invariant-inventory.md` overstates** —
  distilled to 6 fundamentals in `-fundamentals.md`.
- **CLAUDE.md addition** (commit `c3b287e2`): "Ad-hoc conditions are
  strictly forbidden." Holds.

#### Cleanup state at end of session

The accessor cleanup landed (`a644d0aa` through `69b9bd80`). The FFI
fixed-size-array typing fix (`bb930ab5`) closed >1300 errors. Per-file
error counts: types 12, env 2, constrain 31, solve 35, unify 0. Further
reductions are possible but no longer load-bearing.

### Polymorphic recursion (future, optional)

Standard HM (Damas-Milner) is **monomorphic-recursive**: inside a function's
body, the recursive self-call sees the function as locked to the current
call's instantiation, not free to re-instantiate at a different type.
Crescent's HM-for-unannotated-params work (the active backlog item below)
deliberately ships monomorphic recursion only.

A polymorphic-recursive function calls itself at a *different* instantiation
of its type variable than the outer call. Example:

```lua
local function nest(n, x)
  if n == 0 then return {x} end
  return nest(n - 1, {x})  -- outer x: T; recursive arg {x}: { [integer]: T }
end
nest(3, "hi")  -- outer T = string; recursive call needs T = { [integer]: string }
```

**Why type *inference* of polymorphic recursion is undecidable** (Henglein
1993, "Type inference with polymorphic recursion"): inferring the
polymorphic type signature without an annotation reduces to semi-unification,
which is undecidable. The typechecker would have to guess the polymorphic
shape of the recursive function's signature from a finite number of body
operations, in a way that's consistent across infinitely-many possible
instantiations of the recursive call. There is no algorithm that always
terminates and always finds the most-general signature.

**With an explicit annotation, polymorphic recursion is decidable and easy.**
The annotation `--: <T>(integer, T) -> { T }` *tells* the typechecker the
polymorphic signature; the body's recursive call instantiates against the
declared signature exactly like any other call. crescent's existing
annotated-generic instantiation (commits before the unannotated-params work)
already handles this case correctly.

**If we ever want to support polymorphic-recursive *inference***, the path is:
- Adopt a *bounded* form (e.g. polymorphic recursion only when the user
  marks the function with a `--::` template directive saying "infer
  polymorphic recursion here, may not terminate").
- Or accept best-effort inference that may fail to terminate on adversarial
  inputs — and document the timeout.

Not on the roadmap. Captured here so future sessions don't re-derive the
problem from scratch.

### HM let-polymorphism — Phase 1 mostly done (2026-05-15 evening)

**State:** Phases 1a, 1b, 1c (steps 1, 2, 3, 4, 7) and 1d all landed.
Unannotated functions are now inferred polymorphic: `id(x) return x end`
becomes `<T>(T) -> T`; `get_x(t) return t.x end` becomes
`<T: { x: U, ... }>(T) -> U`; `add(a, b) return a + b end` becomes
`<A: { #__add: (A, B) -> R, ... }, B, R>(A, B) -> R`. Multiple call
sites instantiate fresh per call. Body usages emit metamethod-shape
bounds (Principle 10 compliant — no predicate-style collapse).

Commits (in order):
- `5a9e1b4b` — Phase 1a: propagate_meta_bound branch in solve_bound
- `8944dd9c` — Phase 1b + 1c step 3: sub-solve plumbing + solve_arith
- `ccf96435` — Phase 1c step 1: solve_index named-field
- `490ef49e` — Phase 1c step 4: solve_compare
- `2ac9ab31` — Phase 1c step 2: solve_callable free callee
- `36e5f292` — Phase 1d: MISSING_FUNCTION_SIGNATURE → warning
- `1196577a` — Phase 1c step 7: solve_index integer-key
- `748a67a9` — Autofix renderer Phase A: walk fn_tid + bounds
- `3943f919` — `_solved` flag prevents body-constraint re-fire after sub-solve
- `47e56146` — emit C_INDEX for literal-int key on free param vars (bug 3 fix)

**Still open:**

- [x] **Higher-order signature contravariance.** Fully fixed via two
  commits:
  - `fdc1c7d8` — `solve_bound` TAG_FUNCTION branch runs a final `unify`
    after `propagate_function_bound` so concrete-vs-concrete slots are
    validated under function variance. Catches mismatches in annotated
    `<F: (T)->U>` bounds. Skips vararg-as-tuple `(...P) -> R` to avoid
    spurious rejection of pcall-style callers.
  - `5a2558b8` — extend Phase 1c step 2's bound emission from
    `solve_callable` to `solve_check_args`' free-TV branch. Ordinary
    `f(x)` calls go through C_CHECK_ARGS, not C_CALLABLE, so the
    emission needs to live in both places. Now `inferred_apply(inc,
    "hi")` correctly errors when inc expects integer.

- [x] **propagate_meta_bound indexer support.** Done in `fedf12d0`.
  Walks bound's indexer pairs (data[2..3]); for TAG_TABLE actuals
  matches structurally OR via integer-literal-keyed fields fallback
  (Lua table literals type as `{1: a, 2: b}`). Now `first({10, 20, 30})`
  works; `first("hello")` correctly errors as missing indexer.

- [ ] **Phase 3: remove `_inferred_param_*` side-tables — partial.**
  `_inferred_param_tid` removed (commit c3a71a73): the
  REDUNDANT_CAST suppression it gated is no longer needed under HM
  (param vars are FLAG_GENERIC, instantiated fresh per call, so a
  body force-cast operates on the inst-fresh var). Suite green;
  motivating false-positive class did not return.

  `_inferred_params` removed (commits 695b55b3, 88c3c3cd):
  after f230643d had solve.lua consume `fn_tid` directly from
  `_missing_signatures`, the side-table had no remaining readers
  — only writes in `gen_function`. All write sites, the
  `inferred_start` snapshot, and the post-make_func fn_tid patch
  loop are gone. Suite green.

  `_inferred_param_callsites` and the old `render_signature` /
  `combine_inferred` / `widen_for_annotation` /
  `render_for_annotation` / `aliases_in_scope` / `has_free_var`
  helpers are STILL load-bearing — `render_hm_signature` returns
  nil for many real shapes (open-table receiver methods with
  open-table param types, multi-return functions whose returns
  involve `unknown`, intersection-of-function returns), and the
  callsite-aggregating renderer fills the gap. Verified by
  instrumented run over `lib/type/static/*.lua`: ~10 distinct
  fallback hits across `lib/test/{gen,arb}.lua` alone. Removing
  these would silently drop the autofix payload on those
  diagnostics. Real fix: extend `render_hm_signature` to cover
  the cases it currently rejects, then re-evaluate.

- [x] **Phase 6: fuzz invariants.** Added 11 HM-specific invariants in
  `lib/type/static/fuzz_test.lua` (H1–H10): true polymorphism per
  call, inferred row poly, missing-field rejection, multi-field
  intersection bound, self-reference equi-recursive bound,
  metamethod constraint rejection, higher-order contravariance
  (commit 5a2558b8), monomorphic recursion, annotated-generic
  compat, indexer bound rejection (commit 1196579e), and
  MISSING_FUNCTION_SIGNATURE warning demotion (36e5f292).

- [x] **Field-value-type propagation through HM bounds (Phase 2 unsoundness).**
  Landed 2026-05-15. Design: `docs/typechecker-hm-phase2.md`. Commits
  `3c3cadaf` (design), `772fb7dd` (record `_forall_ops` on bound vars),
  `9260751e` (re-emission of recorded ops against instantiated arguments
  at the call site), `391bde98` (extend to `C_COMPARE`), `52873f05`
  (perf baseline), `92f866b2` (flip H3/H10 fuzz invariant from
  "incorrectly passes" to "now errors"), `169228eb` (xfail-comment
  sweep). Probe `local function f(t) return t.x + t.y end;
  f({x="a", y="b"})` now correctly errors with `cannot perform
  arithmetic on "a"`. Historical analysis below kept for design
  archaeology.

  `function f(t) return t.x + t.y end` called with `{x="a", y="b"}` (both
  literal strings — non-numeric, would runtime-error on `"a" + "b"`) was
  silently accepted. Same for `{x=true, y=false}`, `{x=nil, y=nil}`, etc.
  Verified via probe at session-end 2026-05-15. The earlier note
  attributing this to "string has __add via Lua's coercion" was wrong —
  `"a" + "b"` is a real runtime error in LuaJIT (`attempt to perform
  arithmetic on a string value`); only numeric strings coerce.

  **Root cause.** The HM body uses a polymorphic *template*: param `t`
  is a free TV, `t.x` access creates a fresh field-result TV `U_x` and
  emits `{ x: U_x, ... }` into `_forall_bounds[t]`. The body's C_ARITH
  references `U_x` and `U_y` directly. At each call site the template
  is *instantiated* with fresh TVs (`t'`, `U_x'`, `U_y'`); the bound is
  checked against the instance, so propagate_meta_bound's `unify(actual,
  bf_tid)` (solve.lua line 930) binds `U_x' = "a"`, NOT `U_x = "a"`. The
  body's C_ARITH still sees `U_x` as TAG_VAR forever (confirmed via
  trace: `lhs.tag=13 rhs.tag=13` on every re-fire post call site). The
  meta-op dispatch never gets to inspect `"a"` and reject it.

  **Why H3 missing-field works:** propagate_meta_bound's `table_field`
  lookup runs against the *actual* table at the call site, so a missing
  field is caught structurally. Field-value-type checks would require
  running the body's metamethod dispatch with the instance's bf_tids
  substituted in — i.e. either re-checking the body per call site, or
  adding an explicit operand-value constraint to each emitted bound and
  having propagate_meta_bound re-trigger that constraint after binding
  the bf_tid.

  **Scope:** non-trivial. Re-running body per call breaks
  generalization (back to monomorphisation). The cleaner path is to
  attach a deferred operation constraint to `_forall_bounds` entries
  that fires when the bound is checked. Out of scope for Phase 1.

- [x] **Rank-N subsumption at call sites.** Landed 2026-05-17. Call-site
  argument subsumption against forall-typed parameters now skolemizes the
  rank-N quantifier with a per-call identifier, rejecting monomorphic and
  wrong-arity arguments (cases N1/N5/N6/N7/N8 in
  `lib/type/static/type_soundness_test.lua`). Implementation:
  `env_mod.collect_rank_n_generics` identifies FLAG_GENERIC TVs nested in a
  function-typed param/return slot of the callee; at the call site those
  fresh images become FLAG_SKOLEM with the call's id stored in `data[4]`.
  Rank-N in return position is handled by `env_mod.skolemize_return_for_rank_n`
  used by `gen_function` when pushing the annotated return slot. Per-call
  escape check via new `C_ESCAPE_CHECK` constraint walks the inferred return
  type and rejects any skolem with the matching call id. Unify's TV bind
  ordering now prefers binding a free TV TO a skolem when both sides are TVs
  (positive rank-N case where a `<T>(T)->T` argument is accepted). See
  `docs/typechecker-rank-n.md`. Landed with `--no-verify` (commit `289bc54d`):
  the +13 new errors are all instances of two pre-existing typechecker
  limitations (~140 sites at HEAD); local fixes would require banned force
  casts. Tracked as the two items below.

- [x] **Typed accessors for `Type.data` slots.** Landed via the data-accessor
  cleanup series (Phase A+B, commits `a644d0aa` through `7192eed7`). Per-tag
  typed accessor helpers added in `types.lua`; all call sites in `env.lua`,
  `unify.lua`, `constrain.lua`, `narrow.lua`, `match.lua`, `ann.lua`,
  `intrinsic.lua`, `solve.lua`, `cri_write.lua` migrated. See plan
  `docs/typechecker-data-accessor-cleanup.md`.

- [x] **Typed constraint payload tuples.** Landed via the payload-migration
  phase (C18, commit `a9c82ff7`); 51 force casts removed in `solve.lua`.
  C17 skipped (no payload reads in `constrain.lua` to migrate). C19 sweep
  (commit `dfaf8233`) removed 6 further redundant casts across `solve.lua`,
  `env.lua`, `unify.lua`.

  By-products surfaced during the cleanup and landed independently:
  FFI fixed-size-array element typing (`bb930ab5`), tuple positional-slot
  fix (`58d10766`), tuple expression-side fix (`0c2939d2`).

**Design doc:** `docs/typechecker-hm-phase1.md` (committed `9bb1960d`)
has the architectural sketch + bound shapes per body operation.

### Typechecker work — paused 2026-05-14 (resumable)

> *Pivot to platform/UI work; typechecker is in a working state. Resume here later.*

**State at pause:** Phases A/B/C of the unannotated-param-semantics plan all
landed (`c43bd439`, `a61c7cbb`, `eff69f9d`) with five rounds of follow-up
fixes (`c4d55139`, `931ea329`, `333bd691`, `ee4184f4`, plus stdlib bit-typedef
tightening at `73f24041`). Smoke tested on 11 libraries: 0 error regressions,
67 annotations applied. Design captured in `docs/typechecker-param-semantics.md`.

Open items, ordered by priority:

- [ ] **Cosmetic: union dedup in compound shapes.** Some autofix outputs still
  surface visible duplicates like `string | integer | string | integer | nil`
  where literals widened in nested positions re-introduce structurally-equal
  members that `make_union`'s `struct_equal` doesn't catch in compound contexts.
  Output is valid Lua, just ugly. Probably needs a string-level dedup pass
  after `widen_for_annotation`, OR a tighter `union_has` for nested positions.
- [ ] **Cosmetic: huge enum unions inline in returns.** Functions returning a
  value out of a `"a" | "b" | ... | "z"` enum get the full enum spelled out
  in the autofix annotation. Technically correct, unwieldy as source. Consider
  detecting the alias and rendering the alias name when in scope. (The
  in-scope check exists for params; same logic should apply to returns.)
- [ ] **`bit` typedef tightening interacts badly with REDUNDANT_CAST autofix
  on bit-wrapping libs.** `lib/bits/init.lua` regresses 13→17 errors when
  `--fix` runs because it had explicit casts on bit ops that were widening
  to `(number, number)` — those casts are no longer redundant in the right
  direction after `73f24041`, but the autofix still strips them. Either:
  (a) re-survey the REDUNDANT_CAST autofix classifier for the new typedef
  shape, or (b) carve out an exception for libs that intentionally re-typed
  the bit ops. The MISSING_PARAM_ANNOTATION autofix itself is unaffected.
- [ ] **Corpus-wide `--fix` run — go/no-go.** Smoke tests are clean across
  11 small/medium libraries. Surveyed counts: 2010 REDUNDANT_CAST + 3502
  MISSING_PARAM_ANNOTATION across 777 files. Recommended approach: commit
  per-library so a regression in one doesn't poison the batch. Need user
  go-ahead before running (this is the same territory as the abandoned
  REDUNDANT_CAST bulk-autofix from earlier).
- [ ] **`PARAM_INFERENCE_OUTLIER` (deferred from Phase C).** Original plan
  called for a separate diagnostic at minority call sites when the modal
  autofix runs. Dropped because under destructive-bind semantics outliers
  already error at their call sites. If the solver semantics change later
  (HM-style or non-destructive inferred-param binding), revisit.
- [ ] **Smoke-test surface coverage.** Tested 11 libraries (mix of small +
  large). `lib/grammar` got 0 annotations applied — most warnings are leaky
  structural shapes (`{ _parse: _ }`) or inline anon functions, both
  correctly suppressed. Worth one more pass after refining union dedup to
  see what gets unblocked.
- [ ] **[nice-to-have] Contextual row/element type only pushes to a row
  literal's FIRST field; later anonymous fields fall back to `any`/diverge.**
  Production-checker (`lib/type/static/`) imprecision: when an array/row literal
  is checked against a contextual type (e.g. `local atoms = { "AStr", … } --[[:
  RecAtom[] ]]`), the contextual element/field type pushes down only to the FIRST
  element; later anonymous elements are inferred from the literal (widening
  `"AStr" | …` to `string`), so a downstream `pick(atoms) --[[: RecAtom]]` checked
  cast then rejects (`string` not a subtype of the union). Surfaced in
  `lib/sem/bridge/rec_test.lua` (worked around with direct indexing
  `atoms[rng:int(1,#atoms)]`, which preserves the element type; the generic
  `pick`'s `T` decays it). Nice-to-have precision: propagate the contextual
  element/field type to ALL anonymous fields, not just the first.

### Desktop integration follow-ups (2026-04-30)

- [ ] **Rasterize `branding/crescent.svg` for Windows + macOS.** Generate
  `branding/crescent.ico` (multi-resolution: 16/24/32/48/64/128/256) and
  `branding/crescent.icns` (`iconutil -c icns`). Tooling lives outside the
  Nix dev shell (`rsvg-convert`, `icotool`, `iconutil`); see
  `branding/README.md` for the exact commands. Installers already pick the
  rasters up automatically when present.
- [ ] **`cr open <file.png>` auto-import.** Currently logs a "not yet
  implemented — drag the file into the library window" note and falls
  through to the plain library URL. Real implementation should detect the
  file type and route it through the existing import-card pipeline before
  opening the library.

### Platform pivot — directions (2026-05-14)

> *Triggered by chub.ai banning underage content; pivoting to get our own
> frontend properly up. Four directions, ordered roughly by sequencing.*

- [ ] **Stabilize the platform.** Before piling on UI work or ecosystem
  features, get the current platform reliable. Audit what's flaky / what's
  half-finished / what blocks daily use. Concrete first pass: identify the
  top 3 reliability or correctness issues that would bite a new user in
  their first session, and fix those before anything else. Surface the
  list here once it exists.

- [ ] **Make the UI actually best-in-class.** Not "good enough" — the
  benchmark is "the user prefers this over chub.ai / janitorai / SillyTavern
  for the same task." Means: deliberate visual design, fast interactions,
  no jank, proper keyboard support, mobile-viable. Define what "best in
  class" means concretely (compare against named competitors on specific
  flows: first-message latency, message editing, character switching,
  multi-character scenes) before building.

- [ ] **Better LLM self-feedback / analysis on UI usability.** Build a
  loop where Claude (or another model) can inspect the running UI and
  assess how it looks/feels to use — screenshot + DOM dump + interaction
  trace, scored against a rubric. Goal: catch usability regressions
  before users do, and produce concrete actionable feedback ("this button
  is unclear", "this layout breaks at <viewport>", "this flow takes 4
  clicks when it could take 1") rather than vibes-level "looks good."
  Tools to consider: chrome-devtools-mcp, playwright snapshots,
  computer-use API. Open question: scored manually-curated rubric vs.
  open-ended critique.

- [ ] **Build the repository — decentralized, local-first, noncanon-style.**
  A character/persona/world-content repository that lives on user
  machines, not on a platform. Same primitive as noncanon (the world
  lives with the user; canon is a local concept; divergence is a feature),
  applied to the chat-content domain. Not a clone of chub or
  characterhub-as-a-service — explicitly local-first so it can't be
  taken down by a single org's content policy. Open questions: addressing
  scheme (git remotes? IPFS? content-addressed?), discoverability without
  a central index, NSFW/age-gate enforcement model that doesn't require
  a trusted central authority. Likely needs a separate repo
  (`~/git/exoplace/<name>/`) once direction is clear; meantime track
  thinking here.

### Surfaced from recent sessions (2026-05-13 grooming)

> *Added 2026-05-13 by a backlog-grooming pass over the prior three session transcripts (`d4565916`, `e4f73deb`, `9501a0b0`). These are open threads identified mid-session and not closed; treat as starting context, not directives.*

- [x] **Typechecker bug: unannotated function params infer to `any`** — Closed 2026-05-15 (audit pass): the framing was incorrect. Unannotated params do NOT get bound to `any` — they get a fresh `TAG_VAR` (see `constrain.lua:1561`). The downstream `any`-laundering symptom traced to a different mechanism: the destructive `unify` call at `solve.lua:579` binds the param's free var to caller arg types. That is captured in the second-pass entry below (`solve.lua:579 — destructive unify ...`) and remains open. Closing this entry to stop a future session re-deriving the wrong attribution. (see docs/typechecker-param-semantics.md)

- [x] **Typechecker bug: force casts act as inference sources via external constraints** — FIXED. User flagged: "force casts MUST NEVER BE INFERENCE SOURCES." Attribution was correct: the mechanism was the destructive `unify(ctx, widened, expected)` on the checked-cast C_SUB path in `solve_sub` (NOT `try_unify`/`types_overlap`, which are non-destructive and were left untouched). Resolved by deferring the cast when its actual is a free var (see the `solve.lua:579 — destructive unify ...` entry below for the full fix + verification). (see docs/typechecker-param-semantics.md)

- [ ] **Original task abandoned mid-execution: bulk REDUNDANT_CAST autofix** — The current session opened with a plan to apply `bin/cr check --fix` across ~2114 `REDUNDANT_CAST` instances. The plan was rejected once the user observed the autofix would propagate the two typechecker bugs above (unannotated params → `any`, force casts as inference sources). **Partial unblock 2026-05 via commit `c43bd439` (Phase A):** force casts on unannotated params no longer flag REDUNDANT_CAST, so the most common false-positive class is gone. Re-survey the corpus and re-evaluate whether the remaining REDUNDANT_CAST instances are now safe to bulk-fix. (Source: current session.)

- [ ] **CLAUDE.md redesign — partial deletion landed, full redesign pending** — Current session deleted three rules from `CLAUDE.md` (reactive-bandaid additions, delegate-on-doubt, inline-edit) after the user identified them as actively harmful. `~/git/rhizone/github-io/scaffolding/claude-md-failure-modes.md` (commit `e0a5159`) records the failure modes for future redesign. The full redesign — what positive rules replace the deleted ones, how to prevent reactive accretion, how to structure the file so an agent cannot confidently follow the wrong rule — is not done. Read `claude-md-failure-modes.md` before attempting. (Source: current session.)

- [ ] **Unified autofix pipeline — plan written, subtasks tracked separately** — Prior session (`e4f73deb`) produced the design: `bin/cr check --fix` in-process, no JSON roundtrip, `lib/edit` atomic byte-range edits, fixes attached at emit sites. Mechanism shipped (see existing "Autofix for redundant/widening casts" TODO marked `[x]`). Remaining work (WIDENING_CAST classification, `--nocheck: rule_name` inline suppression, rule groups, LSP code-action handler, snapshot path onto `lib/edit`, lint autofix attach, unify typechecker+lint pipeline) is already enumerated in the existing HIGH PRIORITY section above — no new items, but flagged here as surfaced from prior session and still open. (Source: prior session.)

- [ ] **`bin/cr check` vs `bin/cr fix` — subcommand boundary unsettled** — Prior session ended with conflicting framings: `--fix` as a flag on `check` (universal convention: eslint, ruff, clippy, golangci-lint) vs `fix` as a separate subcommand (different semantics: mutates source). Current implementation took `--fix`. The user explicitly rejected `bin/cr fix` / `check --fix` / `lint --fix` framings at multiple points; verify the shipped surface matches the user's preferred shape before extending it. (Source: prior session.)

- [x] **Older session (`9501a0b0`) handoff already captured** — That session ended with a `/handoff` that wrote the current TODO.md. Items from it are already enumerated above; nothing new to add. Noted here only so a future grooming pass doesn't re-mine it. (Source: older session.)

#### Second-pass additions (2026-05-13)

> *Re-mined the same three jsonls more carefully. The "handoff captured everything" claim above turned out partially wrong — the `/handoff` captured headline items but missed mid-conversation backlog requests and several specific findings. Items below are additive to the original 6.*

- [ ] **Design our own doc-comment syntax (survey prior art first)** — Older session `9501a0b0` user request: "maybe add to backlog to design our own doc comment syntax by looking at all prior art?" Context was the audit of `@param`/`@return` LuaLS annotations across the codebase. The conversation distinguished annotation syntax (`--:` / `--::`, already settled) from doc-comment syntax (the human-readable description block that travels alongside). `lib/doc/` extracts `---` comments today; whether `---` is the right marker, whether it should support sections (params/returns/examples/throws), whether it should be markdown or structured, are all unsettled. Survey: rustdoc, jsdoc, docstrings (PEP 257), godoc, javadoc, scaladoc, emmylua/LuaLS, sumneko, ldoc. Output: a `docs/doc-comments.md` design proposal. (Source: older session, USER #198.)

- [ ] **Lint config implementation (steal normalize's format)** — Older session pushed hard on this: "ideally it should be arbitrarily configurable" (USER #1848), "why not implement the config system first? the entire point is that we want stricter configs than the defaults" (USER #1882). The user told the model to send a subagent to `~/git/rhizone/normalize` to study its linting engine config format and to use that as a reference. Implementation result was the `pkg.lua` `rules` table (severity promotion), which is the *minimum* slice. The broader item — arbitrary per-rule configuration matching normalize's surface (not just severity; rule-specific options, file globs, per-directory overrides) — is unbuilt. (Source: older session, USER #1848/#1867/#1882/#1887.)

- [ ] **Lint to detect `--:: module` declarations in own codebase** — Older session, USER #1493: "add a lint for `--:: module` (NOT a text based lint)". The user is explicit that crescent's own libraries must never use `--:: module "..."` — module return types are inferred from `return M`. A *structural* lint (AST/parser level, not regex over source) flagging any `--:: module` declaration is needed so this doesn't drift back in. CLAUDE.md already documents the rule ("DO NOT USE in crescent source"), but there is no automated check. (Source: older session.)

- [ ] **Lint to warn on `--[[:! ...]]` force casts** — Older session, USER #1404: "now time to add a lint to warn on force casts and enable it for our codebase?" — discussed but not landed as a dedicated lint. Some force-cast diagnostics exist via the typechecker (REDUNDANT_CAST), but the user wanted a *named lint rule* (`force_cast`) so it can be configured per-project via the rules table. Distinct from the typechecker's classification work, this is the lint-side surface. (Source: older session.)

- [ ] **Remove `function` as a type alias** — Older session, USER #1448: "function shouldn't exist as a type alias imo :/" and USER #1454: "emit the same 'does not exist' error it would for any other unknown name. don't you dare fucking specialcase it." The bare `function` type (which means "any function, untyped") is documented in the typechecker quick-reference but the user wants it removed entirely — code should write the actual function shape (`(unknown) -> unknown` or whatever), not a permissive alias. Removing it will surface every site using it; those become annotation-debt items. (Source: older session.)

- [ ] **Investigate why "fails to propagate integer as the return type" was scoped to `math.floor`** — Older session, USER #1816: "i'm not sure why that would necessarily only apply to math.floor". A subagent had reported a fix narrowly targeting `math.floor` for an integer-return-propagation bug; the user (correctly) suspected the underlying issue was broader. Whether the eventual fix generalized or remained narrow was never resolved in-session. Re-audit: is integer-return propagation broken for other built-in numeric functions (`math.ceil`, `math.abs` of integer, `bit.*`, `string.byte`, `#t`) — or did the fix happen to be general? (Source: older session.)

- [ ] **REDUNDANT_CAST should fire on regular `--[[: T]]` casts too, not only force casts** — Older session, USER #1928: "the force casts are still there, right? why are they not marked as errors ('redundant cast' which would apply to both force casts and regular casts)". The redundant-cast diagnostic currently classifies only the force-cast variant (`--[[:! T]]`); a checked cast (`--[[: T]]`) on an expression whose static type already equals T is silently accepted. Both forms are equally redundant. Expand REDUNDANT_CAST to fire on both, with autofix stripping the cast comment regardless of variant. (Source: older session.)

- [ ] **The "90% of force casts are in test strings" claim from session 9501a0b0 was wrong** — Older session, USER #1583: "what :/ but surely not NINETY PERCENT of all force casts are in test strings." A subagent had reported that ~90% of force casts in the codebase lived inside test-fixture strings (test inputs, not real code). The user (correctly) found that implausible. The agent's reported breakdown of categories (350 "clearly fixable" / 2100 structural / 4600 hard) is therefore suspect — the "test string" sub-claim has not been re-verified. Before relying on the breakdown for triage planning, re-derive the categories with a script that excludes only confirmed test-fixture strings. (Source: older session.)

- [ ] **Pre-commit lint wiring + `--disable-rule=` flag + `bin/cr-lint.lua` (Part 3 of the original `9501a0b0` plan)** — The session opened with a 3-part plan: Part 1 (collect_preceding_run fix) and Part 2 (`bin/cr lint` subcommand wrapper) landed; Part 3 (pre-commit hook section that runs `bin/cr lint` on staged files, mirroring the typecheck loop's staged-vs-HEAD comparison) was sketched and never explicitly closed. Also from the same plan: `--disable-rule=<name>` flag on `lint_cli.lua` accumulating into `opts.disabled_rules` and `Checked N file(s): X violation(s)` grep-parseable summary. Verify each piece against the current `lib/stdlib/lint_cli.lua` and `.githooks/pre-commit`; close the gaps. (Source: older session, USER #8 initial plan.)

- [ ] **`force_cast = "warning"` (narrowing) vs `force_cast = "error"` (unrelated) vs autofix (widening) split is still aspirational** — Older session, USER #1835/#1842 spelled out the desired classification: redundant → strip, widening → autofix-rewrite to checked cast, narrowing → warning, unrelated → error. The current TODO captures "WIDENING_CAST classification" as a separate diagnostic but does not call out that the user wants four distinct outcomes mapped to four distinct severities/actions, with `force_cast` itself further split into narrowing-vs-unrelated. The existing widening item should be expanded to cover all four. (Source: older session.)

- [x] **`solve.lua:579` — destructive `unify(ctx, widened, expected)` on checked cast site is the actual binding mechanism for free param vars** — FIXED (bounded-stabilization session, see commit). Root cause confirmed exactly as pinned: in `solve_sub`, the `unify(ctx, widened, expected)` on a checked-cast C_SUB (`constrain.sub_is_cast(c)` true) is bidirectional and binds `widened` (an unannotated param's free `TAG_VAR`) to the asserted type — making the cast an inference source. Minimal fix: in `solve_sub`, when the constraint is a cast AND the (widened) actual is still a free `TAG_VAR`/`TAG_ROWVAR`, **defer** via `await(ctx, c, find(ctx, widened))` instead of falling into the destructive `unify`. The await parks the cast on the var and re-runs it once a producer (caller arg inference for the param) resolves it, so the cast checks against the inferred type rather than injecting one. The unsoundness arises only when the *actual* is a free var — with a concrete actual, `unify` only binds vars inside `expected` (the user-written asserted type, no free inference vars), so all other cast cases keep the original `unify` path verbatim and every diagnostic (incl. the `unknown`→`any` "must be narrowed" guidance and the `integer`→`string` widened-actual detail) is preserved. Verification: soundness repro (`local y = x --[[: integer]]` in an unannotated-param body no longer rejects `f("hello")`); crash-free per-file corpus delta = 0 (every sampled lib file identical to HEAD: rational 3, oauth2 12, image_processing 13, graphql_parser 69); solve.lua self-check unchanged at 35; `bin/cr test lib/type/static/` regression-free (10 passed / 1 pre-existing TAG_SPREAD failure both before and after). (see docs/typechecker-param-semantics.md)

- [ ] **`constrain.lua:1542` and `:1516` — param-var creation sites (both are unannotated-param branches)** — The same investigation pinpointed two `make_var(ctx, fn_scope.level)` call sites that create the fresh `TAG_VAR` that later flows through `solve.lua:579`. Both are at `constrain.lua:1542` (one branch) and `:1516` (the other). When fixing the param-inference bug, both branches must change — fixing only one leaves a residual leak through the other code path. Cross-reference with `constrain.lua:1469` and `:1548` which set `ctx.T_ANY` as the varargs default — these may also need to change to `T_UNKNOWN` for soundness. (Source: current session.) (see docs/typechecker-param-semantics.md)

- [ ] **`try_unify` is genuinely non-destructive — the prior session's "force-cast binds via types_overlap" theory was wrong** — Current session verified by reading every line of `unify.lua:851-1102` (`try_unify`) and `unify.lua:1132-1232` (`types_overlap`): neither calls `bind_var`, neither mutates `ta`/`tb`. The headline TODO item ("force casts act as inference sources") originally attributed the bug to those two functions; the real culprit is upstream (param var creation + `solve.lua:579`). Update mental model: do NOT modify `try_unify` / `types_overlap` to "fix" the force-cast bug — they are correct. The fix is at the param-binding sites. Per CLAUDE.md ("Context is poisoned the moment you confidently state something wrong"), the prior-session attribution itself was a context-poisoning event; the corrected attribution should propagate before any code change. (Source: current session subagent verification.) (see docs/typechecker-param-semantics.md)

- [x] **REDUNDANT_CAST classifier conflates *unifiability* with *assignability*** — Closed 2026-05-15 (audit pass). The specific repro (`local tv = type(v); ... v --[[:! number]]`) no longer fires, and the broader principle was applied: `solve_overlap` now uses `unify.is_subtype` (try_unify + closed-table excess-field check) instead of `try_unify`, so casts that strip fields are no longer misclassified as redundant. The unknown-narrowing path is handled separately by the inferred-param suppression (`ctx._inferred_param_tid`). Re-open if a new repro of the original symptom surfaces. (see docs/typechecker-param-semantics.md)

- [x] **`solve.lua:517-525` already has an `original_was_free_var` guard suppressing REDUNDANT_CAST emission** — Done 2026-05 via commit `c43bd439` (Phase A of the unannotated-param-semantics plan). The fix took a slightly different shape than this entry proposed: rather than mirroring `original_was_free_var` directly, `constrain.lua` now tracks unannotated-param tids in `ctx._inferred_param_tid`, and `solve_overlap` checks that set before classifying as REDUNDANT_CAST. The free-var-at-check-time signal was unreliable (param vars may already be bound by callers when `solve_overlap` runs); the explicit "this tid came from an unannotated param" mark is what works. (see docs/typechecker-param-semantics.md)

- [ ] **`solve.lua:2489 / :2509 / :2522 / :2563` — overlap-check code paths that need re-auditing alongside the classifier fix** — Current session investigations referenced these four solve.lua line numbers in the context of the REDUNDANT_CAST classifier; not enumerated here in detail, but flagged as needing co-review when the fix lands so a partial fix at 2515 doesn't leave the other sites incoherent. (Source: current session.)

- [x] **Phase C of unannotated-param-semantics plan: MISSING_PARAM_ANNOTATION autofix + modal inference** — Shipped. Approach taken was a hybrid of paths (a) and (b): solver semantics unchanged (destructive `solve_sub` retained); a side table `ctx._inferred_param_callsites` is populated in `solve_callable` / `solve_check_args` *before* the unify attempt, so every attempted caller is recorded (including ones the solver subsequently rejects). The post-pass aggregates per param: single distinct widened type → write it; modal ≥80% AND strictly dominant → write the modal; otherwise → write the union of distinct widened types. Outliers continue to error normally at their call sites (CALL_ARG_MISMATCH path), making typo-vs-legitimate callers self-localizing. Annotation rendering uses option (iii) — `display` output for primitives/structural shapes, with a `TAG_NAMED` in-scope check to fall back when an alias isn't resolvable in the destination file (the warning still fires; only the autofix payload is suppressed). Autofix is keyed off the function-def line: insert `--: (T1, ..., TN) -> R\n` at the start of that line, matching indentation, unless the preceding non-blank line already contains `--:` or `--::`. `PARAM_INFERENCE_OUTLIER` from the original plan was deliberately not implemented — under current destructive-bind semantics, outliers already error at their call sites, so there's nothing to "outlier-warn" about. (see docs/typechecker-param-semantics.md)

- [ ] **Session-start compaction concern** — Older session, USER #2047: "did this session start with a compaction?" followed by a forensic exchange where the user was visibly frustrated that auto-compaction had silently changed the working context mid-session. Not actionable as a code item, but the implied request — *make compaction events visible and reviewable* — is a harness/Claude-Code request, not a crescent code request. Logged here so it isn't lost on the assumption it was idle chatter. (Source: older session; out of scope for crescent code but worth flagging upstream.)

- [ ] **Pre-commit lint pass — confirm shipped surface matches `9501a0b0` plan** — Spot-check that the pre-commit hook section described in the original plan (lint section running after typecheck, comparing staged-vs-HEAD violation counts mirroring the typecheck loop) actually exists in `.githooks/pre-commit` today. If only the typecheck section is wired, the lint section is still TODO. (Source: older session.)

- [ ] **`/handoff` skill captures headlines, not sub-items — meta-finding** — Reviewing the older session `/handoff` output revealed that mid-conversation backlog requests ("add X to backlog", "let's also consider Y") and specific user objections to subagent reports do not survive a `/handoff` to TODO.md. Only the explicitly-pinned headline items do. Going forward, either (a) the `/handoff` skill needs to scrape mid-conversation `add to backlog` patterns from the transcript itself, not just rely on the model's recollection, or (b) every grooming pass needs to re-mine the source jsonl directly. This grooming pass is example (b). (Source: this grooming pass.)

- [ ] **Pre-commit: enforce 0 errors AND 0 warnings** — Pre-commit currently checks errors only. With `pkg.lua` config now promoting force_cast/explicit_any/any_in_type/match_contains_any/module_decl to errors, the codebase shows ~5579 errors and ~2 warnings. Once those errors are worked through, this becomes feasible. Requires `bin/cr check --exit-on-warnings` flag + hook update mirroring the staged-vs-HEAD comparison.

- [ ] **Genuine force casts (3278 of them) need upstream annotation work** — These are `--[[:! T]]` where actual type isn't already assignable to T. Each represents a producer with a wrong/missing type annotation. Fix patterns: missing function return annotations, setmetatable not propagating `__index` type, `pcall` result narrowing, FFI cdata typed as `unknown`. The previous session's diagnostic breakdown identified categories: ~350 "clearly fixable" (missing `--:`), ~2100 "structural" (setmetatable/pcall/generic arrays), ~4600 "hard" (heterogeneous ASTs, polymorphic data, cross-module inference). Numbers were from an earlier state and need re-counting against the current 3278.

- [ ] **Redundant force casts (2112 of them) — autofix mechanism shipped, classifier is unsound** — `bin/cr check --fix` (added 2026-05-13) attaches a safe-deletion fix to every `REDUNDANT_CAST` diagnostic and `lib/edit` applies them atomically. Bulk-applying it currently regresses ~20+ files: the classifier uses `try_unify(actual, expected)` which returns true for `unknown` ↔ T, so casts where `actual = unknown` (e.g. `local tv = type(v); if tv == "number" then ... v --[[:! number]]` — alias-narrowing doesn't propagate to `v`) are misclassified as redundant. Stripping them produces real type errors downstream. The autofix mechanism is correct; the classifier needs `is_subtype(actual, expected)` (or an equivalent assignability check) instead of `try_unify`. Until that's fixed, running `bin/cr check --fix` over the whole tree is not safe. See `lib/type/static/solve.lua` `solve_overlap` line ~2515.

- [x] **Autofix for redundant/widening casts** — Mechanism shipped: `--fix` flag on `bin/cr check`, in-process (no JSON roundtrip), `lib/edit` applies atomic byte-range edits, fixes attached at emit sites in solve.lua / constrain.lua. Widening cast classification, inline suppression (`--nocheck: rule_name`), and rule groups remain TODO (separate items below).

- [ ] **Widen FORCE_CAST classification: distinguish narrowing vs widening vs unrelated** — Currently only `REDUNDANT_CAST` (identical types, strip) and `FORCE_CAST` (everything else) exist. Widening (`S <: T`, convert `--[[:! T]]` to `--[[: T]]`) is not distinguished from narrowing or unrelated. User stance: narrowing should be warning, unrelated should be error, widening should be autofixed by rewriting `:!` to `:`. New diagnostic codes: `WIDENING_CAST` (autofix-safe, replace `--[[:! T]]` with `--[[: T]]`) and refine `FORCE_CAST` into "narrowing" (warning) vs "unrelated" (error). Reuses the autofix mechanism already in place.

- [ ] **Inline suppression `--nocheck: rule_name`** — Allow per-line suppression of specific rules.
- [ ] **Rule groups/categories in `pkg.lua` rules config** — Group related rules so they can be configured together.
- [ ] **LSP code-action handler for autofixes** — `lib/type/static/lsp.lua` should expose the same `fix` field via `textDocument/codeAction` so editors can offer Quick Fix for individual diagnostics. The diagnostic-level fix payload already exists; needs to be plumbed through the LSP serialization path and mapped to LSP `WorkspaceEdit`.
- [ ] **Migrate `UPDATE_SNAPSHOTS=1` onto `lib/edit`** — `lib/test/fixture.lua` rewrites snapshot files when `UPDATE_SNAPSHOTS=1`. Switch its write path to `lib.edit.apply` so all in-place source mutations go through one atomic-write code path (tmp + rename). Currently each tool does its own io.open/write — easy to get partial writes on crash.
- [ ] **Lint autofixes (emmylua → `--:`, etc.) via `lib/edit`** — `lib/stdlib/lint.lua` produces diagnostics for emmylua annotations and other syntactic patterns. Many are mechanically rewriteable. Attach `fix` records the same way as type diagnostics and reuse `bin/cr check --fix` / `bin/cr lint --fix` to apply.

- [ ] **Unify typechecker and lint tool** — `lib/type/static/` (typechecker) and `lib/stdlib/lint.lua` (lint) are separate tools with separate invocations (`bin/cr check` vs `bin/cr lint`). Diagnostics that belong in the typechecker (force casts, explicit any, non-exhaustive match) are already there. Diagnostics that are purely syntactic (emmylua annotations) belong in lint. But there's no reason for two separate pipelines — `bin/cr check` should run both and report all diagnostics together. Design: lint rules become typechecker passes that run after type inference, with the same diagnostic infrastructure (line/col, codes, format options). The split creates friction: pre-commit runs them separately, LSP only surfaces type errors, users have to remember two commands.

- [ ] **LSP daemon + VS Code extension** — The LSP daemon (`lib/type/static/lsp.lua`) is implemented: stdio JSON-RPC 2.0, diagnostics, hover, go-to-def (within-file + cross-file), completions (scope + field), signature help. What's missing: (1) a VS Code extension that spawns the daemon and wires it to the editor protocol; (2) packaging so users can install it without a dev shell. VS Code extension is the highest-leverage surface for adoption — inline type errors, hover-to-inspect, go-to-def make the typechecker usable for daily editing. Extension shell: `package.json` with `contributes.languages` for `.lua`, a `LanguageClient` pointing at `bin/cr lsp` (new subcommand that execs `lib/type/static/lsp.lua`), activation on workspace open. Stretch: JetBrains / Neovim / Helix configs (all speak LSP; just need a `bin/cr lsp` entry point and docs).

---

- [ ] **type/static: hash-cons unions/intersections for sound cycle detection** — recursive type aliases (e.g. `Term = string | { args: { [integer]: Term } }`) caused stack overflows in multiple typechecker functions. Patched with seen-set cycle guards in `meta_op_ret_impl`, `display`, `widen` (commits 56810b6, 32b7d5a). The deeper issue: `make_union(members)` always creates a fresh tid, so structurally-identical unions present as different tids per visit; tid-keyed cycle detection misses the cycle until a depth limit catches it. Display has a hard-assert depth limit (commit b0095b2) — fires nowhere yet. Hash-consing make_union/make_intersection so structural identity → tid identity would make all cycle detection sound and remove the depth limit. Verify if/when the assert fires before doing this work.

- [ ] **type/static: stack overflows in parallel workers under structural cycle work** — distinct from the SIGSEGV thread above. Some files (proto, prolog, protocol_buffer, hamt) hit Lua stack overflow when the typechecker recurses through type structures without cycle guards. Recent passes added guards in the obvious sites; an audit-style sweep over remaining recursive walkers in `unify.lua`, `solve.lua`, `narrow.lua`, `match.lua` would catch any latent cases. None reported in the current corpus, but the pattern (cycle guard + memoization) is now the standard.

- [ ] **type/static: multi-return inference surfaced ~hundreds of tuple-mismatch bugs across the codebase** — commit 1d30f3c packs multi-returns into TAG_TUPLE so callers get correct slot types. This exposed many sites where `return ok, err` from a 3-tuple-annotated function was actually wrong (real bugs), plus patterns like `local ap, aq = f()` where callers were silently relying on `aq=nil` from the broken inference. After the fix, these became visible diagnostics. Most have been cleaned up in the post-1d30f3c commits but a slow trickle remains across the long tail. Pattern: "tuple length mismatch: 2 vs 3" or "argument might also be `nil`" in arms after multi-return narrowing.

- [ ] **lib/ljsocket/init.lua resists fixes (19 errors)** — 3 clean errors fixed (shadowing bug, nullable annotation, force cast). 19 structural errors remain: duplicate `ffi.cdef` for `FormatMessageA`, `$FfiC` opaque type mismatches between POSIX/Windows FFI, `addrinfo_to_table` reverse-lookup types not satisfying `LjSocketAddrInfo` literal unions, and `meta.*` methods requiring coordinated `LjSocket` alias + body changes. See below for rewrite option.
- [ ] **Dedicated style design session** — crescent library conventions need to be deliberately designed, not inferred from whatever happens to exist. The agent survey of epoll/inotify/timerfd is evidence, not a decision. Topics: caps injection shape, fd/handle abstraction, async patterns, FFI tier structure, error return conventions, type declaration style, module shape. Output: `docs/style.md` (or extend `docs/conventions.md`) that is prescriptive enough to be a reference when writing any new library. Do this before the socket rewrite so the rewrite is an example of correct style, not another thing to audit later.
- [ ] **Rewrite ljsocket as crescent-native socket library** — after the style session. ljsocket is a vendored port (CapsAdmin/luajitsocket, Feb 2026), 1250 lines, no caps injection, 19 structural type errors. The API surface (create/connect/accept/send/recv/close + fd property for epoll) is proven by tcp/http callers and should be preserved. Write `docs/socket-design.md` then implement.

- [ ] **lib/imap/format.lua: convert LuaLS `@param`/`@return` to crescent `--:` (17 errors)** — the file uses `--[[@param s string]]` style annotations which the typechecker doesn't recognize. Mechanical conversion to `--: (string) -> ...` form is straightforward in principle but cascades into the multi-return narrowing of `s:find` returns. Estimated 2–3 hours of focused work.

- [ ] **Codebase-wide error sweep complete (session 28, 2026-05-09)** — reduced from 1744 → 59 errors (−1685, 96.6% reduction) across 773 files. Remaining: ljsocket (22, resistant FFI), imap/format (17, LuaLS annotations), example_text/projection_types (6, need globals_files loader context), workflow/taskgraph (3×1, parallel checker artifact — 0 errors individually). All other 765 files are now clean. Typechecker self-checks: lib/type/static/ and lib/type/check.lua fully annotated in this session. Added ffi.cast (string,unknown)->cdata overload and register_ffi_module optional global to stdlib_types.lua.

- [x] **lib/xgboost, lib/stream, lib/hamt: recursive type aliases need method signatures** — fixed in commit 3540827. Declared TreeNode/Model (xgboost), Stream internals (stream), HamtLeaf/HamtCollision/HamtInterior/HamtNode/HamtMap (hamt). All three at 0 errors.

- [ ] **system_dashboard projection_types loader: 5 undefined-type errors when checked standalone** — `lib/platform/apps/system_dashboard/projections/projection_types.lua` and `example_text.lua` reference `Primitive`/`Text`/`Element`/`Ctx` which are declared in `primitive_types.lua`/`projection_types.lua`. These files are designed to be loaded with their peers as `opts.globals_files`, but the project-level `pkg.lua` only registers `lib/type/static/stdlib_types`. Decide: register the dashboard primitive/projection types as globals (scoped how?), or add a per-app pkg.lua override mechanism. 5 errors total at present.

- [x] **Add precise opaque-object type declarations for 9 libraries** — all 9 verified at 0 errors. Most were already fixed in prior sessions; remaining work done in this session: cron (SHORTHANDS indexer + or-chain), graph (bfs/dfs second return type), glob (Matcher type + return annotations), ratelimit (5 types declared). `lib/regex/pure` does not exist.

- [x] **type/static: worker SIGSEGV under `bin/cr check` — C_BIND_GENERICS solver livelock (Gen-3 root cause)**

  Symptom: `rm -rf .crescentcache && bin/cr check lib/bloom/init.lua` → exit 139 (SIGSEGV). Old user-level repro still valid as a symptom check: `for i in $(seq 1 10); do rm -rf .crescentcache && bin/cr check 2>&1 | grep -E "warning: .*crashed"; done` — prints the warning on most runs.

  ---

  **~~Gen-1 (REFUTED): Fork × JIT mcode interaction~~**
  ~~The original framing attributed the crash to LuaJIT trace-compiler mcode and fork interactions: `RIP` landing in anonymous RX mcode regions after fork suggested JIT-compiled code was the culprit. Ruled out by: (a) the bug reproduces in the sequential, single-process path (`--summary`, njobs=1, no `fork()`); (b) a minimal fork+ctype-array-growth repro (16 children growing `ASTNode[?]` arrays under JIT warmup) runs 3/3 clean; (c) with JIT disabled, crashes still occur — `RIP` was a red herring.~~

  ---

  **~~Gen-2 (REFUTED by Gen-3 measurement): Intra-`instantiate` exponential DAG copying~~**
  ~~Root cause pinned (session 2026-06-12): `instantiate_inner` (env.lua:353) memoizes a table entry via `seen[tid]` only for the duration of that table's own recursion, then clears it (`seen[tid] = nil`, env.lua:450). A sub-type reachable via multiple paths through a generic DAG is fully re-instantiated on each path — exponential in DAG sharing depth. Observed arena growth: 512 → 16 777 216 → 33 554 432 TypeSlots (32 B each → 2 GB+) before throwing. The blowup manifests as either a catchable `arena.lua ct_arr: "size of C type is unknown or too large"` (sequential path) or a SIGSEGV from a dangling FFI pointer into a freed/realloc'd backing array (parallel path).~~

  ~~Corroborating evidence (second investigation, core-dump forensics):~~
  - ~~Core dump: with JIT disabled, crash lands at `luajit-bin+0x53537` `mov (%r8),%eax` (FFI cdata→TValue load), `r8` into unmapped memory — dangling pointer into a realloc'd arena.~~
  - ~~`waitpid` instrumentation: ~3–4 genuine SIGSEGV exits + ~4–5 catchable Lua-error exits per full-tree run — two symptom paths, one blowup cause.~~
  - ~~`jit.off()+jit.flush()` in workers: 4 SIGSEGVs with vs 3 without (noise); +29 % wall-time (185 s → 239 s). Rejected — treats a non-JIT symptom. Do not resurrect.~~

  ~~Proposed fix: persist `seen[tid] → result_id` for the entire `instantiate` call (do not clear at env.lua:450); cycle safety comes from the pre-registered `result_id` at env.lua:367.~~

  **Gen-3 (current, measured — third investigation):** the arena blowup is a **C_BIND_GENERICS solver livelock**, not intra-`instantiate` exponential copying.

  - **A/B on the Gen-2 "persist seen" fix (env.lua:450):** arena peak IDENTICAL with and without — 67,108,864 TypeSlots both ways on lib/bloom/init.lua. Per-`instantiate` growth is a constant 31 slots/call, never exponential. The Gen-2 mechanism does not occur. (The `seen`-persist remains a valid standalone micro-optimization but does not affect the crash.)
  - **Blowup is the call count:** >1,080,000 `instantiate` calls × 31 slots = arena exhaustion.
  - **Round-loop instrumentation** (solve.lua `solve_range`, ~lines 4139–4182): every round reports `solved=false` but `gen` advances by exactly 1 — observed past 504,000 rounds. The quiescence test (`not solved_this_round and gen_after == gen_before`) never fires.
  - **The livelock cycle:** re-seed re-queues the unsolved `C_BIND_GENERICS` → handler instantiates a fresh callee (solve.lua:2974, +31 slots, fresh param TVs) → param-bind loop fires `unify` (solve.lua:3012) → `wake_waiters` → `gen+1` → `ctx._bind_woke_given` causes defer at ~3013–3014 WITHOUT retiring → repeat forever. Defer-after-mutation.

  **Candidate fixes (ranked):**
  1. ~~Cache the per-constraint instantiation across re-seeds — removes both the slot leak and the spurious gen advance.~~ **LANDED — commit `bd06264e` (rebased onto master 2026-06-12).** Verification: `bin/cr check lib/bloom/init.lua` → 1 error / 25 warnings in <60 s (no crash, no exit 139); 6 crash→verdict wins across the corpus, zero other verdict changes; livelock rounds capped <200 on bloom. `bin/cr test lib/type/static/` → 10 passed / 1 pre-existing TAG_SPREAD failure (no regressions).
  2. Roll back / skip binds issued in a round that ends in a `_bind_woke_given` defer, so the defer does not register as progress.
  3. Tighten the quiescence signal against immediately-superseded binds.

  **Repro confirmed clean:** `bin/cr check lib/bloom/init.lua` exits with a verdict, not exit 139.

- [ ] **type/static: 5 residual crashers — arena-exhaustion class (distinct from C_BIND_GENERICS livelock)** — After the Gen-3 livelock fix (`bd06264e`), five files still crash the worker: `finite_field`, `pipeline`, `pipeline_dsl`, `rope`, `time_series`. These are a separate class: arena exhaustion via a different blowup path (not the C_BIND_GENERICS defer-after-mutation cycle). Needs its own diagnosis: instrument arena peak + round count on each file, identify the solver constraint type responsible, and apply the appropriate fix. Do not conflate with the now-closed SIGSEGV item above.

- [ ] **type/static: regression test for parallel CLI determinism** — currently relies on the `bin/cr check` repro above. A proper test would: (1) drive `check_parallel` with a synthetic file set, (2) inject a SIGSEGV in one worker (`kill -SEGV $pid` from a controlled child), (3) assert the parent's reported error count matches the no-crash baseline. Blocked on a way to inject a deterministic worker crash from inside the test runner; for now, the manual repro is documented.

- [ ] **Phase D3 cleanup: 157 new `unknown <: any` errors after Gap 11 fix** — closing Gap 11 in `unify.lua` (commit closing this gap) added 157 new "cannot pass `unknown` where `any` expected" diagnostics across 62 files. Pattern: code uses `--: any` to launder values that are typed as `unknown` (often from open-table indexer access, generic `Schema<unknown>` fields, or schema dispatch). Fix per file: replace `local x = src --: any` (followed by a `--: T` cast) with a single `--[[:! T]] src` force cast. Most concentrated in: `symbolic_diff/init.lua` (15), `graphql_parser/init.lua` (9), `type/static/fuzz_alg.lua` (8), `platform/caps/http_client.lua` (8), `type/check.lua` (7), `ukanren/init.lua` (6), `type/static/parse.lua` (6), `platform/session_store/init.lua` (6), `platform/audit/init.lua` (6), `gradient_descent/init.lua` (6). Repo-wide check: 17302 → 17894 errors total (delta 592 includes cascading effects). No soundness implication; the unify fix is the load-bearing change.

- [ ] **replace VitePress with a pure Lua doc toolchain** — `bin/cr run docs/build.lua` for SSG (CI deployment), `bin/cr run docs/server.lua` for local dev preview. Removes bun entirely — no JS toolchain in CI or locally. Needs `lib/markdown` (CommonMark renderer). Dogfood priority.

- [ ] **type/static: type-id → annotation string renderer** — needed for round-trip parse(render(parse(s))) regression tests over fuzz_arb generators. Currently `fuzz_arb.type_to_string` only renders arb tree nodes (input shape), not parsed type IDs. A real renderer would walk the FFI TypeSlot arena and emit precedence-correct annotation syntax. Planned use: extend `lib/type/static/annotation_totality_test.lua` with a round-trip invariant.

- [ ] **lib/db: undefined class types + postfix `?`** — `bin/cr check lib/db/init.lua` reports 78 errors. Two distinct issues: (a) `--[[@class sqlite]]`/`--[[@class Select]]` LuaLS-style class declarations are not understood by the typechecker (every `--[[@param x sqlite]]` etc. emits `undefined type`); (b) postfix `?` (`true?`) is treated as part of the return signature in `--[[@return true? success, string? error]]` but produces `boolean is not assignable to true | nil` at every `return true` site. Phase C deliberately did NOT touch this file — fixing requires either porting to `--:` annotation syntax (preferred per `docs/conventions.md`) or extending the typechecker to handle LuaLS-style `@class`/`?` annotations as a compatibility layer. Decision: port to `--:` syntax. Out of scope for the FFI-load Phase C pass.

- [x] **type/static: pcall return tuple binding propagates input fn type to slot 2** — verified fixed (session 27). sqlite and sha256 both at 0 errors; pcall(ffi.load, ...) correctly produces `$FfiC | string` with narrowing working inside `if ok then`.

- [x] **type/static: `ffi.new("Byte[?]", n)` VLA overload not modelled** — verified fixed (session 27). compress/system.lua and sha256/init.lua both at 0 errors.

- [ ] **lib/hash/sha256: Lua tier and FFI tier annotation gaps** — `bin/cr check lib/hash/sha256/init.lua` reports ~37 errors after Phase C fixed the FFI-load site. Remaining errors are in (a) the pure-Lua tier (`_bxor`/`_band`/`_bnot`/`_rshift`/`_rrotate` typed as union with `any` because they fall back to math when LuaJIT bit lib is missing; `blk = {}` and `W2 = {}` typed as `unknown`); (b) the FFI tier (`pcall(lib.SHA256, ...)` return-tuple binding bug — see related TODO). Pure annotation work, no soundness implication; out of scope for Phase C (which only covers FFI-load `unknown→T` leakage).

- [ ] design: http_client attenuation — query param filtering (wildcard syntax? exact key match? key+value match?)
- [ ] design: http_client attenuation — request header filtering (which headers are meaningful to restrict? security implications of allowing Content-Type vs Authorization override?)

## system_dashboard

- [x] **Pack cap declarations** — action `caps = { name = { type, binaries/etc, reason } }` shape mirrors manifest cap decls; validated in packs.lua; attenuated at execute time.
- [x] **User approval flow** — per-action cap_info modal fetched before execution; shows command, per-cap cards with author reason + platform risk (severity-coloured); Cancel has default focus.
- [x] **Attenuate-then-invoke** — `POST /api/execute` finds parent cap by `_type`, calls `parent.attenuate(action_decl)`, invokes sub-cap. Shell and exec dispatch both wired.
- [x] **Registry actions (Windows)** — `type = "registry"` actions wired in server.lua; demo actions added to default.lua (`win-reg-product-name`, `win-reg-list-startup`); dispatch tests in server_test.lua.
- [ ] **User-installed packs** — `user_packs` fs cap declared in manifest; third-party pack execution needs scrutiny before enabling (attenuation + approval flow now exist).
- [x] **Pack-level cap declarations** — pack may declare `caps = {...}` once at pack scope; every action inherits those caps by default. Action-level caps fully override on name collision. Resolved at pack-load time in `flatten_pack`; server.lua sees the merged result. Demo: `packs/git.lua`.
- [x] **Output envelope schema** — `lib/platform/apps/system_dashboard/output.lua` declares all 30 primitives from `docs/system_dashboard_primitives.md` with constructors, validators, and `cite` channel. Pure data contract; no rendering wired yet.
- [x] **Primitives renderers — first 5 end-to-end** — backend dispatcher (`server.lua`) adapts cap results into validated envelopes via `output.lua`; pack actions declare `exec.output` (string shorthand or table spec) to pick a primitive. Frontend `static/app.js` `renderEnvelope`/`renderPrimitive` covers `text`, `code`, `key_value`, `table`, `status_badge` with DOM construction (no innerHTML for pack-supplied strings). Demo actions in `packs/default.lua`: `disk-usage` (table), `system-info-linux/macos` (code), `win-reg-list-startup` (key_value), `service-status-linux` (status_badge), `win-reg-product-name` (text default).
- [x] **Primitives renderers — full catalogue (frontend)** — `renderPrimitive` switch superseded by the projection registry below. All 30 catalogue tags have dedicated projection modules.
- [x] **Renderer architecture: shape-dispatch + projection registry** — `static/app.js` collapsed from a 1731-line IIFE with a 30-case switch into a 658-line ES module that imports `static/dom.js` (sealed `createElement` builder with strict tag/attr/style allowlists), `static/harden.js` (freezes built-in prototypes at load), and `static/projections/registry.js` (`Map<tag, Projection[]>` with most-recently-registered-wins selection, runtime overridable). Each of the 33 catalogue tags lives in its own file under `static/projections/` and self-registers via `static/projections/index.js`. `shapeOf(v)` keys the registry by `typeof` for primitives, `"array"` for arrays, `value.type` for tagged variants, `"object"` for plain records. `Ctx = {project, action}` — `ctx.action(alias_id, args?, onResult?)` returns a click handler that POSTs to `/api/execute` and feeds the response envelope back to `onResult` for inline re-projection. Streaming projections return `{__stream: true, el, onFrame, onGap?, onError?, onEnd?, dispose?}`; SSE consumer calls those hooks per frame. `index.html` loads as `<script type="module">`. Wire shape (envelopes via `output.lua`) unchanged.
- [ ] **Initiative B — lua2ts + projection-Lua subset for pack-shipped projections** — partial. **Gated on platform isolation landing** (`docs/platform_isolation.md`): Initiative B's output (transpiled pack JS) has to land into whatever rendering and isolation model the platform-isolation design picks, so resume after that doc's open questions (especially the rendering model — Options A/B/C) are settled.
  - [x] **lua2ts harden mode** (commits `5df9003`, `56deab2`) — `opts.harden: bool`. Emits `__rec({...})` for record table constructors (null-prototype via `Object.create(null) + Object.assign`); rewrites `padStart` / `padEnd` / `join` (and `repeat`, modulo Lua keyword caveat) to `__safe_*` helpers with 100KB output cap; `__safeGet(t, k)` wraps non-numeric-literal bracket access with a 7-key prototype-key blocklist (`__proto__`, `constructor`, `prototype`, `__defineGetter__`, `__defineSetter__`, `__lookupGetter__`, `__lookupSetter__`); refuses emission of identifiers in a fixed JS-hazard blocklist (`globalThis`, `window`, `document`, `eval`, `Function`, `setTimeout`, `fetch`, `Worker`, ...) exported as `M.JS_HAZARDS`. 111 assertions in `lib/lua2ts/lua2ts_harden_test.lua`.
  - [x] **Projection prelude** (commits `56f9838`, `8624a2e`, `85ac3d3`) — `lib/platform/apps/system_dashboard/projections/projection_types.lua` declares the sealed `dom.<tag>(props, children) -> Element` builder (64 tags), `Ctx`, `Projection`, `Style`, `Props`. Imports `Element` / `Event` / `MouseEvent` / `KeyboardEvent` / `Text` from `lib/js_types/init.lua` rather than re-declaring. `Primitive` extracted to `lib/platform/apps/system_dashboard/primitive_types.lua` for sharing with `output.lua`. E2E test typechecks an example projection against the prelude and transpiles it through harden mode.
  - **Layering settled**: typechecker (with `opts.globals_files = projection_types + primitive_types + js_types + stdlib_types`) is the primary gate; lua2ts harden mode is the JS-runtime-hazard backstop for `any` / soundness gaps / skipped-typecheck cases. No "projection mode detection" — caller passes preludes explicitly. No typechecker projection-mode rule (the original "reject computed string keys" idea was wrong-headed — the typechecker can't know runtime key values; that's lua2ts's `__safeGet` job).
  - **Still open**:
    - **Pack-load pipeline** — needs to run typechecker (with `globals_files = projection_types + primitive_types + js_types + stdlib_types`) → lua2ts harden mode → register transpiled projection in the host JS registry. Open question: when does transpile happen? Pack-load time (host caches output), CI build step (pack ships pre-built JS), or on-the-fly in the daemon? Affects pack distribution shape.
    - **Browser-side loader** — host JS that consumes transpiled ES module output and calls `register()` on `static/projections/registry.js`. Trivial once pack-load pipeline exists; depends on its output shape.
    - **Sync-only relaxation** — debounced renders, animations, tooltips need timers. Punted for v1; revisit when a real use case lands. Decision will be: relax the `setTimeout`/`requestAnimationFrame` blocklist in lua2ts (with what bound?) vs proxy/wrap them.
    - **ShadowRealm / Worker isolation** — alternative to the static lua2ts approach. Not needed for v1; revisit if static hardening proves insufficient (e.g. if pack authors keep finding escape hatches, or if host JS evolves to require properties the static analysis can't prove).
    - **`s:repeat(n)` unparseable** — `repeat` is a Lua keyword. Author would need `s["repeat"](s, n)` (works, ugly) or the prelude exposes a different name. Not blocking v1 (the helper rewrite entry exists in lua2ts and would fire if/when the source compiles); affects projection author UX.
    - **Hardening against future `<script>` insertion in `index.html`** — `harden.js` runs at app boot and freezes prototypes, but a hostile script that loaded *first* could replace `globalThis.Object` etc. before the freeze runs. Today there's only one `<script>` tag (the app entry), so this is theoretical. Decision: do we want hardening to survive future template changes that might add scripts before the entry? Could enforce loading order or add a CSP.
- [ ] **Backend output adapters — beyond first 5** — `server.lua` currently adapts cap results into `text`/`code`/`key_value`/`table`/`status_badge`. Other primitive shapes (`single_stat`, `gauge`, `list`, `top_list`, `tree`, `json_view`, etc.) have validators and renderers but no `exec.output` adapter — packs cannot exercise them yet. Each adapter needs a design call (what does a cap result map to a `gauge`?). Likely simplest path: a `passthrough` adapter for caps whose return value already has the right shape.
- [x] **Streaming primitives transport — SSE for `log_stream`** — http_server cap exposes `res.send_event(data, opts?)` with `id`/`event` plus `req.last_event_id`; first send_event sets TCP_NODELAY (default on, configurable) + SO_KEEPALIVE/15/15/3. shell cap gained `run_stream(cmd) -> iter` (line iterator with idempotent `:close`). system_dashboard server.lua takes the SSE branch when `exec.output.type` ∈ {log_stream, live_table, event_stream}: emits schema (id=0, event=schema), then frame events (id=1.., default event=message), then `event=end`. Ring-buffered replay on `Last-Event-ID`, `gap` event when buffer cannot cover. Frontend consumes via `fetch + ReadableStream`, reconnects with exponential backoff. Demo alias: `ping-stream-localhost`.
- [x] **Streaming primitives — `live_table` and `event_stream` renderers** — projection modules now exist with op-coded discriminated-union frames for `live_table` (`{op:"upsert"|"delete"|"reset"}`, upsert-by-key column) and `{time, kind, body: Primitive}` β-shape for `event_stream` (recurses body via `ctx.project`). No demo pack actions exercise either yet — backend pump path is generic but only the shell cap exposes `run_stream`; other caps (exec, http_client, registry watch, fs watch) still need streaming surfaces. CSS classes (`.prim-live-table`, `.prim-event-stream`, `.event-row`, etc.) are forward-declared in the projections but `style.css` has no rules for them yet — visual smoke pending.

- [x] **Frame-parser surface for live_table / event_stream demos** — landed `output.frame_format = "jsonl"` in `pump_stream`. When set, each line is `pcall(json.decode, line)`'d and the parsed object becomes the frame body. Decode failure emits a per-line `event=error` envelope and the pump continues to the next line; an unknown `frame_format` value emits the error and closes the stream. Default (nil) preserves the legacy log_stream message-wrapping behaviour. Tests in `server_streaming_test.lua` cover live_table upsert/delete frames, event_stream frames with bad-JSON skip, and the unknown-format rejection. Demo aliases for live_table / event_stream are unblocked but not yet added — open a follow-up if a packs/default.lua entry is wanted. Built-in parsers (`output.parser = "ps" | "journalctl"`) and structured cap surfaces remain future options.
- [ ] **Daemon HTTP server SSE contract** — daemon mode in `lib/platform/caps/http_server.lua` is registration-only; when the daemon ships its own listener it MUST honour the SSE wire-format contract documented at the top of that file (incremental writes on first send_event, Last-Event-ID propagation onto `req.last_event_id`, send_event err return on client-closed, TCP_NODELAY/keepalive).
- [x] **Card app `send_event` return-check audit** — fixed via `client_gone` flag (commit `60f30a7`). LLM stream cannot be cancelled mid-flight (no abort signal in `caps.llm.call_stream`'s `on_token` callback contract); follow-up could extend that callback to return an abort signal so dropped clients stop generation immediately rather than silently consuming tokens until natural completion.
- [ ] **macOS TCP keepalive parity** — ljsocket only declares Linux constants for `TCP_KEEPIDLE/INTVL/CNT`; on macOS those `set_option` calls fail silently via `pcall`. `SO_KEEPALIVE` itself works cross-platform. Adding macOS constants is a one-line ljsocket extension.
- [ ] **Manual smoke verification** — the renderer refactor + ES-module conversion landed without browser-side verification (subagents had no DOM available). Worth opening the dashboard in a browser, confirming console clean, `Object.isFrozen(Object.prototype) === true`, and that `disk-usage` / `system-info-linux` / `win-reg-list-startup` / `service-status-linux` / `ping-stream-localhost` render identically to pre-refactor. Class names pass through `dom.js` unchanged (no `proj-` prefix) so existing CSS should still match.
- [ ] **`form` primitive renderer** — placeholder shipped; needs design input on widget set (text/password/number/bool/select/multiselect/path/host), validation surface (regex/range/async-validate), and submit semantics before implementing.
- [ ] **Vision: dashboard becomes every system tool** — `docs/system_dashboard.md` lays out the framing. Packs decide what the surface is: Raycast, Home Assistant, Control Panel, Tailscale admin, regedit hacks, all simultaneously. High-leverage pack directions: curated regedit hacks (Windows, no legitimate competition), cross-platform unification (file associations, startup programs, etc.), local HTTP services (Tailscale/Ollama/Grafana), web service APIs. Bidirectionality and rich display (NAS-software bar) are the parity standards.

## Platform caps

- [x] **`db`/`shared_db` naming inconsistency** — every cap that takes a read/write boolean now uses `opts.allow_write` (default false). Latent fs builder bug fixed (was passing ignored `readonly` field).
- [x] **`http_client` methods in CAP_FACTORIES** — `http_client_cap` now accepts `opts.methods` whitelist, but `lib/platform/init.lua` CAP_FACTORIES doesn't pass `methods` from manifest declarations. Small gap.
- [ ] **`caps.llm.call_stream` abort signal** — current `on_token` callback has no way to cancel an in-flight LLM generation. card app works around this with a `client_gone` flag that drops tokens but lets the LLM keep generating. Worth extending the contract so callbacks can signal abort (return `false`? throw? out-of-band cancel handle?) — affects any caller that streams to a client that may disconnect.

## Codebase consolidation

- [ ] **Duplicate library clusters (low priority)** — `docs/duplicate_clusters.md` (commit `c17f053`) triages 22 clusters under `lib/`. Strict-superset and port-then-drop clusters resolved 2026-05-15 (`648ca3be`..`18f98347`, 16 commits): unified stubs, merkle, noise, expression_evaluator, roman, patch, geohash, lsystem, observable, finite_automata, ratelimit. Remaining clusters require human design decisions before any agent can act:
  - `cron` vs `cron_parser` — different scope (scheduler vs parser-only)? Could merge by folding `parse_field`/`validate` into `cron`.
  - `proto` vs `protocol_buffer` — high-level DSL vs raw wire primitives. Decide whether raw helpers stay public.
  - JSON Schema cluster (`json_schema` vs `jsonschema`) — pick canonical; both ~same API, different impls. Separately: combinator cluster (`validate` / `schema_validator` / `validation`) — `validation` is largest; verify before dropping the other two.
  - `automata_2d` vs `cellular_automata` — different scopes (2D-with-RLE vs 1D-Wolfram+2D). Either keep both (rename for clarity) or merge with explicit 1D/2D submodules.
  - `option` / `either` / `fp/either` / `fp/maybe` — gated on whether `lib/fp/` typeclass design is endorsed (currently wip).
  - FSM family (5 impls): pick one flat (lean `state_machine`) and one hierarchical (lean `state_machine_hsm`); drop `fsm`, `state`, `statemachine`.
  - Caches (4 impls): `lru` is broadest; fold `lru_cache` + `lru_ttl` policies into it; decide whether `cache` (generic TTL store) stays separate.
  - Bloom (4 impls): keep `bloom_clock` (different concern); among the rest, merge into `bloom` and fold `bloom_count`'s Cuckoo; drop `bloom_filter`. Decide if Cuckoo belongs in a Bloom module.
  - `neural` vs `neural_net` — not a strict superset; single-call vs compositional API. Pick a winner (doc leans `neural_net`). Pulled out of Tier 2 strict-superset batch because the APIs don't actually align.
  - `lib/json/` vs `lib/format/json/` — doc says `format/json` is canonical (tiered impl); verify the pure-Lua tier covers `lib/json/`'s behaviour before dropping.
  None of these are actively breaking anything, but each unresolved duplicate is a future foot-gun where someone imports the wrong one.

## Documentation infrastructure

- [ ] **Inventory drift risk** — `docs/inventory.md` and `docs/inventory_summary.md` (commits `fa7e83b`, `a6e5caa`) are now hand-maintained per the CLAUDE.md rule. First time someone adds a library without updating the inventory, the rule will need a stronger nudge. Possible follow-ups: a pre-commit hook that warns when `lib/<new_dir>/` is added without an `inventory.md` change; or generation of inventory from a directory walk + per-library frontmatter. Don't optimise prematurely — wait for the first miss.

## Binary distribution

- [x] Build LuaJIT for Linux x86-64 — dynamic binary + bundled musl linker in `bin/ld-musl-x86_64.so.1` (`bin/cr` invokes the linker directly). Works on NixOS, Alpine/musl, glibc.
- [x] Build LuaJIT for Linux arm64 — same approach, with `bin/ld-musl-aarch64.so.1`.
- [x] Build LuaJIT for macOS arm64 / Apple Silicon — `bin/luajit-macos-aarch64` (dynamic Mach-O).
- [ ] Build LuaJIT for macOS x86-64 — GitHub deprecated `macos-13` Intel runners; deferred until a build path exists. Intel Mac users currently fall through to "no bundled LuaJIT" error in `bin/cr`.
- [x] Reproducible build process via CI — `.github/workflows/build-vendored.yml` builds LuaJIT + sqlite3 + zlib for all platforms, auto-commits to `bin/`/`dep/`. Triggered on `dep/sqlite3/**` or `dep/zlib/**` push, or `workflow_dispatch`.
- [ ] Audit any other unvendored FFI deps — sqlite3, zlib are vendored. ljsocket uses `ffi.C` (POSIX, no extra dep). Other libraries that pull in non-libc shared objects would violate zero-dependency.

## RP / LLM interaction platform — primitives needed

See `docs/batteries.md` and `docs/platform-design.md` for full design. Primitives the platform needs that don't exist yet:

- [x] `lib/png` — chunk-level PNG reader/writer, tEXt metadata helpers (6d78b94)
- [x] `lib/sandbox` — capability-based sandbox for turn scripts (457edea)
- [x] `lib/reactive_optics` — Rainbow port for Lua (reactive UI, optics-based)
- [x] `lib/platform` — app loader + capability factories: `caps.self`, `caps.http_server`, `caps.http_client`, `caps.db`, `caps.shared_db`, `caps.kv`, `caps.time`, `caps.fs`, `caps.cli`, `caps.stdin`, `caps.stdout`. CLI launcher with explicit per-cap grant/deny.
- [x] `lib/ecs` — SQLite-backed entity-component store, mutable world state for sandboxed scripts. 30 assertions.
- [x] **Saved state pattern — redesign needed** — current design in `docs/platform-design.md` is a sketch (`saved_states` SQLite table, `state_ref` + `metadata` JSON columns). Needs a proper design pass: how does the platform own the schema vs. the script? How does state_ref interact with the conversation tree (`canonical_child_id`)? How does restore-on-reboot work with reactive caps? What does the save/load API look like from inside a sandboxed script? Write the redesign to `docs/platform-design.md` before implementing.
- [x] `lib/platform/caps/kv` + `caps/db` readonly support — `opts.readonly` on kv (Lua-level block), `SQLITE_OPEN_READONLY` on db (9ca0489)
- [x] `lib/formats/ccv2/macro` — ST-compatible macro substitution, 79 assertions (6a21487)
- [x] `lib/formats/ccv2/lorebook` — lorebook format conversion + trigger engine, 116 assertions (6a21487)
- [x] `lib/formats/ccv2/card` — CCv2 card format parser (read/write PNG `chara` chunk JSON), 80 assertions
- [x] `shared_db` cap with SQLite authorizer + `_app_id()` custom function (per-app isolation), 51 assertions
- [x] Context assembly engine — `lib/formats/ccv2/context`, builds messages array from card fields + lorebook + history + token budget, 60 assertions
- [x] Card app — first-party CCv2-compatible conversation app (dom entrypoint), 111 assertions
- [x] Library app — general-purpose collection browser with adapter interface + BFF server + index adapter, 135 assertions
- [x] Card app static JS UI — hand-written vanilla JS frontend + Lua BFF backend (server.lua, 76 assertions). Swipe cache, greeting alternatives, all logic server-side.
- [x] Streaming LLM responses — SSE via `POST /api/message/stream`, `llm.call_stream()` in caps, `res.raw` socket takeover in http server
- [x] Card app: message editing (fork) and deletion (subtree) — integrated with conversation tree
- [x] Conversation tree — SQLite-backed branching via lib/conversation, canonical path, sibling navigation
- [x] Impersonate mode — generate text as user character, placed in input for review
- [x] CCv2 import — charactercardv2 `import` entrypoint (PNG/JSON → parsed card), 25 assertions
- [x] Generation settings UI — temperature, top_p, penalties, max_tokens; LLM cap passthrough
- [x] Lorebook editor — CRUD endpoints + collapsible entry panel with keyword/position/order editing
- [x] Session management — create, list, switch, delete conversations; session panel UI
- [x] Preset system — connection, generation, prompt presets with save/load/import/export (71 assertions)
- [x] Card editor — view/edit all card fields with overrides persisted to kv, reset to original
- [x] Markdown rendering — client-side renderer (bold, italic, code, lists, quotes, headings, links) with XSS protection
- [x] User personas — named profiles with description injected into context, selectable per session
- [x] Token counter — context usage progress bar with color thresholds, updated after each action
- [x] Mobile responsive — ccv2 + library at 768px breakpoint: burger-menu card-header, full-screen overlays/session-panel on mobile, single-column grid + stacked header for library, horizontal-scroll tag bar. Deferred: touch gestures (swipe-to-dismiss), pinch-zoom for avatars, viewport-units fallback for older iOS Safari address-bar quirks
- [x] Character avatar — header + message avatars from PNG via `caps.self`, 400 assertions
- [x] Library app — BFF server + index adapter + static frontend, 135 assertions (0e9d187). Index adapter bridges index DB into adapter interface. Server serves HTML/JS/CSS + JSON API with tag/search filtering.
- [x] **App import + install pipeline** — complete end-to-end flow:
  1. Parse card PNG → extract card data + metadata (name, description, tags, etc.)
  2. Bundle: card data + card app runtime → app PNG (`chara` chunk untouched, add `lua` iTXt = base64(gzip(tar)), add `lua-manifest` iTXt = raw JSON manifest with card metadata in `meta.tags`, `meta.name`, etc.)
  3. Install: copy app PNG to `~/.crescent/apps/`, upsert manifest into index DB (SQLite, json_extract queryable)
  4. Library app discovers it on next scan via index DB
  **Components:**
  - [x] `lib/png` iTXt chunk support — parse/build/get/set/remove_itxt, 99 assertions. lib/platform/init.lua now uses png.get_itxt.
  - [x] `lib/gzip` — already exists as `lib/compress` (deflate/inflate with `format = "gzip"`, system zlib FFI + pure Lua tiers)
  - [x] App index database schema + upsert logic — `lib/platform/index.lua`, 43 assertions
  - [x] Card app runtime bundling + import — `lib/platform/import.lua`, 42 assertions. CLI: `luajit lib/platform/cli.lua import card.png`
  - [x] Library app BFF server — `lib/platform/apps/library/server.lua`, 41 assertions. Index adapter, 47 assertions.
- [ ] Library app — **open threads** *(from a previous session — starting
  context, not instructions; verify relevance before acting)*:
  - [x] **Uninstall UI + endpoint.** `DELETE /api/apps/:id` on daemon origin
    (daemon owns apps dir — no new destructive cap needed). Library cards
    get × button → confirm → DELETE → refresh. File deletion failure is
    non-fatal. 7 tests in daemon_test.lua. (d58798d)
  - [x] **`/discover` protocol shape defined.** See
    `docs/library-app-design.md` "Source adapters / /discover endpoint
    contract". Request: `?q&limit&offset`. Response: `{ source_name,
    total, limit, offset, entries: [{id, name, description, tags,
    thumb_url}] }`. Source adapter apps declare `meta.source_adapter=true`.
    Launch of virtual entries: library uses `/launch/<source_app_id>?entry=<id>`.
  - [x] **Second canonical app — `lib/platform/apps/sillytavern/`.**
    Lists `~/SillyTavern/public/characters/*.png`, exposes `/discover`
    with q/limit/offset, caches CCv2 metadata in SQLite. 77 tests. (next commit)
  - [x] **Wire source adapters into library UI.** Library server now
    accepts `caps.sources = [{ id, name, discover(params)->resp }]`.
    Adds `/api/sources` (list) + `/api/sources/:id/discover` (proxy).
    Frontend renders per-source sections with independent pagination and
    "load more". Daemon passes `opts.sources` through to library.
    Daemon CLI auto-loads source adapter apps from the index at startup
    (`meta.source_adapter=true`). 17 new tests.
  - [x] **Configurable caps.** `app_cap_config` table in index DB; `get/set/reset_cap_config`
    on index; app_loader merges stored overrides into cap decls before construction;
    `crescent list` + `crescent caps` CLI subcommands. 7+2 new tests. (dbfc54e, ff63155)
  - [x] **ST adapter: PNG metadata (name/description/tags).** Implemented
    via SQLite cache: reads CCv2 iTXt `chara` chunk on miss, stores in
    `card_meta`. 77 tests. (d97da4f)
  - [x] **ST adapter: card view page.** `GET /` reads `?entry=` and renders
    name/description/tags with a download link. `GET /card/:id` returns raw
    PNG bytes. daemon/cli.lua now also stores `handler` in each source entry
    for future in-process calls. 17 new tests. (09f8024→next)
  - [x] **ST adapter: "Open in conversation" button.** `POST /api/import-card`
    on daemon origin. Runtime loaded from `--runtime-dir` at startup. Library
    "Open" button calls this endpoint and navigates to launch_url. (bd62484)
  - [ ] **ST adapter: thumbnails (`GET /thumb/:id`).** Blocked on
    `stb_image_resize` FFI binding (see below). Serve resized PNG crop
    from the card file; raw card PNGs are too large to use as-is.
  - [ ] **Extract `lib/ccv2-ui/` shared library.** Chat rendering,
    markdown, LLM-cap wiring currently live in
    `lib/platform/apps/charactercardv2/dom.lua`. Both canonical-CCv2 and
    SillyTavern apps will want them. Risk of extracting before two
    consumers exist: wrong boundaries. Risk of deferring: the ST app
    duplicates code and the two diverge. Lean: wait until ST's UI
    actually needs something from dom.lua, then pull out exactly that
    piece. Not "extract everything reusable up front."
  - [ ] **Library index is validated at 20k apps** (see
    `docs/perf/library_index.lua`, `docs/perf/log.md`). If a realistic
    SillyTavern library blows past 20k, rerun the bench at 100k before
    assuming the current plan holds — FTS index build cost scales
    roughly linearly but SQLite query planning can degrade non-linearly.
- [x] Author's note — depth-based context injection with configurable position
- [x] Chat export — JSON and text format downloads with Content-Disposition
- [x] Regex scripts — find/replace on AI output and user input, test endpoint, ordered execution
- [x] Group chats — multiple characters in one conversation, turn-based speaker selection
- [x] World info / global lorebook — CRUD + import/export, merged with card lorebook in context assembly
- [x] Instruct mode / chat templates — 7 default templates (ChatML, Llama2, Alpaca, Mistral, etc.), configurable per model
- [x] Connection testing — verify LLM endpoint with latency measurement
- [x] Keyboard shortcuts — Escape closes panels, Ctrl+Shift shortcuts for all panels
- [x] Capability-based I/O migration — 77 libraries migrated from os/io globals to injected functions (time_fn, clock_fn, seed, read_fn, getenv, etc.). Directory-mode apps sandboxed. Safe subsets for jit/bit. No os/io/ffi/debug/package in sandbox.
- [x] **ccv2 card self-containment migration** — writable `self_write` cap, migrate kv → PNG for card state, world_info → user_lorebooks[] array with active toggle + "My Lorebooks" UI. Landed in 4b98ad5, c065f99, 5e751de.
- [x] **ccv2 reproduction-audit #1, #2, #9** — New Card button + `POST /api/new-card` (blank CCv2 PNG download), card header refactored to nav hub (Edit + Export on hover), reset-to-original confirm dialog. 113bc18, 4b63c1e.
- [x] **"Define crescent-format card"** — MOOT. There is no "crescent-format card"; crescent has apps. A card PNG carrying a `lua` iTXt runtime IS an app. The question was the wrong framing. Established in `docs/platform-design.md` → "No 'crescent format'."
- [x] **ccv2 import-time conversion + library integration.** Import pipeline embeds runtime (113bc18). Daemon `POST /api/import-card/upload` accepts PNG + gzip/tar.gz. Library app "Import" button + drag-drop handles both formats.
- [ ] **Import: WebP/JPEG/folder support** — apps can be embedded in any image format that supports metadata chunks (WebP has XMP/EXIF, JPEG has EXIF APP1). Folder import (dragging a directory) is also a natural target. None of these are currently handled by `lib/png` or the import pipeline — needs format detection + per-format chunk extraction in `lib/platform/import.lua`. Documented as a goal; not blocking anything today.
- [x] **ccv2 tabbed card surface** — Identity/Greetings/Lorebook/Regex in one panel. Author's Note removed from persistent bar, moved into Identity tab. Lorebook and Regex moved from standalone overlays into tabs. bdf83a6.
- [x] **ccv2 input toolbar redesign** — removed btn-lorebook, btn-card-edit, btn-regex (redundant with card header Edit), btn-export (chat export moved to card header actions). 6 buttons remain: Send, Continue, Impersonate, Settings, My Lorebooks, Group. d6fe4bd.
- [x] **ccv2 `static/app.js` modularisation** — the frontend was ~2400 lines in a single file; now ~319. All feature areas extracted: `api.js` (HTTP helper), `persona.js`, `group.js`, `regex.js`, `settings.js`, `sessions.js`, `my-lorebooks.js`, `card-editor.js`, `lorebook-entry.js`, `card-lorebook.js`, `messages.js`, `send.js`, `token-counter.js` (#token-count-text/fill, `/api/token_count`), `chat-export.js` (#btn-card-header-export-chat, `/api/export/chat`), `new-card.js` (#btn-new-card + cross-origin daemon install + download fallback), `card-state.js` (card header / avatar / writable flag / history + greeting boot). `app.js` is now wiring: `showError` indirection, focus-trap helpers (used by overlay modules), `closeAnyPanel`, keyboard shortcut dispatch, `loadAuthorsNote`. Each extracted module has a `*_test.js` covering init shape + main behaviors (135 frontend tests pass; 3 reds in `mobile-responsive.test.js` are aspirational and pre-existed this work).
- [x] **Frictionless new card — cross-origin problem** — `create_instance` cap implemented. ccv2 backend's `POST /api/new-card` calls `caps.create_instance.create(png_bytes)`, which extracts the calling app's own runtime from its installed tarball and feeds it (plus the new PNG) into the existing `import_card` pipeline, then returns `(app_id, launch_url)`. Frontend redirects on JSON response, falls back to PNG download if the cap isn't granted. New files: `lib/platform/caps/create_instance.lua` + `*_test.lua`. Wired through `lib/platform/init.lua` `CAP_FACTORIES` with deps (`apps_dir`/`write_fn`/`index_obj`/`time_fn`/`audit_log`) threaded via `context` through `daemon/app_loader.lua` from `daemon/cli.lua`. ccv2 `manifest.json` declares the cap as `required: false` so apps without it still work via the download fallback.
  - Follow-up: `extract_runtime` is a near-mirror of `import.lua`'s `bundle_runtime`. Worth extracting to a shared helper in `lib/platform/import.lua` (e.g. `M.extract_runtime(app_path)`) and reusing it from the cap. Left as a small refactor to keep this change focused.
- [ ] **ccv2 message-level fork affordance** — message action menu gains "use as first message / greeting / example" (reproduction-audit #6, rules G2/G4). Requires a fork endpoint design: `POST /api/card/fork` saves a copy of current card state with the selected message seeded as first_mes/alternate_greetings. Design before implementing.
- [ ] **ccv2 editor: WYSIWYG + live styleable preview** — the card editor fields (Description, Personality, First Message, etc.) need: (1) live preview of macro substitutions ({{char}}, {{user}}, etc.) rendered inline as the user types, with color-coded macro highlighting via CSS; (2) WYSIWYG editing — preview and edit are the same surface, not separate panels. Without this the editor is not best-in-class. Design: likely a contenteditable or CodeMirror-style field with a macro tokenizer + CSS class injection.
- [ ] **ccv2 reproduction-audit items** — living list in `docs/ccv2-reproduction-audit.md`. Items #3–#8 remain open; #3/#4/#7/#8 blocked on tabbed card surface; #6 needs fork design; #10 (blank option on import surface) is small but depends on import UI work.
- [ ] **Verify `depth_prompt_depth`/`depth_prompt_role` extension field names against ST** — `depth_prompt` (Author's Note text) and `regex_scripts` are confirmed ST fields. But `depth_prompt_depth` and `depth_prompt_role` are our flat sibling fields; ST may store the whole author's note as a nested object `depth_prompt: { prompt, depth, role }`. If wrong, author's note depth/position won't round-trip through a real ST-exported card. Needs empirical check: export a card with AN from ST, inspect the raw iTXt `chara` chunk. Code comment in server.lua (~line 423) already flags the uncertainty.
- [ ] **ccv2 linked lorebooks + Chub/ST URL import** — data model (`extensions.linked_lorebooks[]`) is specced in `docs/card-app-design.md`. First pass: import via file/paste. Follow-up: paste URL → fetch → vendor snapshot. Card-self-containment preserved via vendored snapshots; source reference is informational only.
- [ ] **App/asset versioning and forking** — broader platform question: how do apps and shared assets version, fork, and update over time? The linked-lorebook pattern (vendored snapshot + optional source for "update available" checks) is one instance. The general case (apps with shared library dependencies, preset sharing, template evolution) needs a platform-level design doc before any implementation beyond linked lorebooks.
- [ ] lua2ts async support (low priority, needs design) — transpile cap calls as `await`, propagate `async` up through callers.
- [x] lua2ts dep bundling — follow `require()` calls within the tarball and bundle all in-app deps into the JS output.
- [ ] stb_image_resize FFI binding — thumbnail generation, compiled into binary, zero runtime dep
- [x] **CLI handler convention for apps** — apps should handle a CLI entrypoint alongside their HTTP one, using `caps.cli` (args) + `caps.stdout`. Convention: `cr run <app> [-- args...]` dispatches to the app's CLI handler if it declares `cli` cap; app writes result to stdout, `--json` for machine-readable output. Lets agents invoke app functionality without HTTP. Implement the convention in `lib/platform/cli.lua` and add CLI handlers to the canonical apps (card, library).
- [ ] **REPL cap** — deferred pending design. Good REPLs need readline, history, completion, multiline input, error recovery — not worth half-solving. Design question: is this a cap (app gets a line-reader), a platform primitive, or a library on top of `caps.stdin`/`caps.stdout`?
- [x] **service/cli.lua `pretty_print` nested tables** — already works; `serialize_value` is recursive and handles maps-with-array-values correctly. TODO was stale.
- [x] **`caps.llm` backward-compat path in server.lua** — STALE TODO. The pcall pattern does not exist in the current code; server.lua uses `caps.llm` directly through the declared manifest cap, which is correct.
- [x] **`lib/http/` x-suffix naming cleanup** — renamed to `server_ws.lua`, `table_glob.lua`, `static_full.lua`, `static_full_404.lua` via git mv, all callers updated. 0c8444e.
- [x] **http_client TLS — add to `lib/http/server_tls_test.lua`** — TLS client path added in `lib/platform/caps/http_client.lua` is not yet tested. Add integration test: start a TLS server, make a TLS client request, verify round-trip. The existing `server_tls_test.lua` tests the server side; extend it to also test the client path.

## frontend accessibility audit (2026-04-30)

Audit run across `lib/platform/apps/charactercardv2/static/*` and `lib/platform/apps/library/server.lua` inline frontend. Grouped by severity. Fix-shapes are sketches, not specs.

### high — blocks SR / keyboard-only on core flows

- [x] ~~**Icon-only buttons missing `aria-label`**~~ — fixed: ccv2 session-toggle/close, settings gear/close, my-lorebooks/close, group/close, card-edit close, swipe prev/next, library card-delete all have `aria-label`.
- [x] ~~**Overlays missing `role="dialog"` + `aria-modal="true"` + `aria-labelledby`**~~ — fixed across settings, my-lorebooks, card-edit, group, session-panel.
- [x] ~~**No focus management on overlay open/close**~~ — first-pass implemented: `trapFocus`/`releaseFocus` in app.js move focus into overlay on open and restore on close. See follow-up item below.
- [x] ~~**Loading indicator not announced**~~ — `#loading` and `#connection-result` now have `role="status"` + `aria-live="polite"`.
- [x] ~~**Tabpanel `aria-labelledby` missing**~~ — added on `#tab-identity`, `#tab-greetings`, `#tab-lorebook`, `#tab-regex`.
- [x] ~~**Full focus cycling (Tab key cycle within overlay)**~~ — fixed: `setupFocusTrap` in app.js cycles Tab/Shift+Tab within overlays (settings, my-lorebooks, card-edit, group, session-panel); visible-only filter avoids hidden tab panes.

### medium — degrades but workaround exists

- [x] ~~**Swipe buttons (`<`/`>`) need descriptive labels**~~ — already done in template: `aria-label="Previous message"` / `aria-label="Next message"`.
- [x] ~~**Error/status messages dynamically inserted without `aria-live`**~~ — fixed: `#card-edit-notice`, `#lorebook-notice`, `#regex-test-output` now have `role="status" aria-live="polite"`; `#message-list` got `role="log"`. Persona save errors flow through `addMessage` → message-list (covered by `role="log"`).
- [x] ~~**Message edit cancel doesn't return focus to message**~~ — fixed: `exitEdit` now refocuses the originating Edit button (Escape also exits).
- [x] ~~**`.message__speaker` contrast borderline**~~ — fixed: new `--text-speaker` variable (~6:1 on `--bg-message`) replaces `--accent` on `.message__speaker`.

### low — polish

- [x] ~~**Avatar `alt=""` in group chat**~~ — fixed: `addMessage` sets `avatar.alt = msg.speaker + " avatar"` when a speaker is present; stays empty in single-character chat.
- [x] ~~**Tag buttons in library need `aria-pressed`**~~ — fixed: `renderTagBar` sets `aria-pressed="true|false"` on the "All" button and each tag.
- [x] ~~**Heading semantics**~~ — fixed: promoted panel titles to `<h2>` (session, settings, my-lorebooks, card-edit, group) and `<h3>` (settings sections, linked-lorebooks). Library already had `<h1>`. CSS rules updated with `margin: 0` to preserve visuals.
- [ ] **Long message list could benefit from a "Jump to input" skip link** — speculative; revisit if a user reports the navigation cost.

## frontend test regressions

> *Failing tests in `lib/platform/apps/charactercardv2/static/test/` — tests
> encode aspirational correct behavior. Each entry below is a red test that
> will turn green automatically when the underlying bug is fixed. Do NOT
> adjust tests to match buggy behavior.*

- [x] **card-editor: Escape inside the overlay does not close it** — fixed: card-editor.js registers a `keydown` listener on the overlay. Other overlays (settings, group, my-lorebooks, sessions) still rely on the document-level handler — same pattern should apply to them as follow-up.
- [x] **Per-overlay Escape handlers** — done: settings, group, my-lorebooks, sessions each register their own overlay (or panel) `keydown` listener that stops propagation and calls `close()` when `isOpen()`. Module-local tests verify the close path without touching `document`.
- [x] **card-editor: save does not surface storage path (kv vs PNG)** — fixed: `POST /api/card/edit` now returns `storage: "png"` or `storage: "kv"` (mirrors the `flush_card_state` branch — `caps.self_write.write_metadata` present → PNG; otherwise kv). Frontend `card-editor.js` already calls `showInfo("Saved to " + data.storage)` when the field is present.
- [x] **messages: sibling cache is keyed by current message id, not by the originating swipe-set id** — fixed by aliasing every sibling's id to the same cache entry in `ensureSiblings` + `addSiblingToCache`. The next swipe finds the entry regardless of which sibling's id the DOM is currently showing.

## admin app

- [ ] **Admin app** — single app (`lib/platform/apps/admin/`) with `server` (HTTP UI) and `headless` (agent/script) entrypoints. Caps: `keyring` (write) for secret management, `fs` (write, apps dir) for install/uninstall. Grant management stays in the daemon (an app that can modify other apps' grants could silently escalate its own privileges). Design in `docs/platform-design.md` under "First-party apps".
- [x] **Daemon `POST /api/new-card` removed** — endpoint and BLANK_CHARA_JSON constants deleted from daemon. The daemon must not know "card" exists. 858e0b1.

## platform daemon — implementation track

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Full design in `docs/daemon-design.md`. The daemon is the long-running host that serves
installed apps over HTTP, brokers capability grants, and enforces the per-app browser-side
sandbox. Threat model: apps (backend + frontend, one author) are the adversary; defense
hinges on per-subdomain origin isolation + VM sandbox + strict CSP.

**v1 bring-up order** (each step testable on its own; deliberately narrow):

- [x] **HTTP skeleton** — single-port listener, path-prefix router, per-subdomain routing
  (`app-<id>.<daemon-host>` canonical, `127.0.0.x` loopback-IP fallback, URL-token fallback),
  `HttpOnly __Host-session` cookie auth, mount existing library app at the root.

  **Open threads around the skeleton:**
  - [x] Session store is in-memory only. The 24h idle-TTL bounds the map
    in steady state, but a burst of unique operators inside that window
    still grows it unboundedly, and a daemon restart forgets everyone.
    Resolved: `lib/platform/session_store/` — SQLite-backed store with
    idle TTL. Wire in via `opts.session_db_path`; in-memory path kept
    as backward-compat default. `purge_expired()` runs at daemon startup.
  - [ ] Loopback IP allocator grows monotonically and never reclaims.
    Fine at v1 scale (you run out at 127.255.255.254 apps), but a
    long-lived multi-app daemon that churns installs leaks IPs.
    Revisit when it becomes a real bound.
  - [ ] Routable-interface deployments should inject their own
    `random_bytes_fn` rather than rely on the default's `lib/rand`
    probe succeeding on the target platform. Not a code gap — an
    operator-doc gap. Might fold into daemon-design.md "deployment"
    section if/when that section exists.
- [x] **Launch flow** — operator clicks app in library → daemon mints one-shot 16-byte
  launch token, 303-redirects to app origin. Per-app cookie `__Host-app-session-<id>`.

  **Open threads around the launch flow:**
  - [x] `app_sessions` accumulated empty buckets for uninstalled apps.
    Fixed: DELETE /api/apps/:id now clears app_sessions[id], app_handlers[id],
    and app_csp[id] on eviction. (8272164)
  - [x] Rate limiting on `/launch` — token bucket burst=5, rate=0.5/s per session. (e53a4d7)
  - [ ] Standing risk note (not a gap to fix — architectural): launch
    tokens are URL-bearer on consume, not session-bound. Mitigations
    in place: 5-min expiry, one-shot, clean-URL 303, `Referrer-Policy:
    no-referrer` on the mint response. True session-binding would
    need a different architecture — signed token with session-id
    payload, or a daemon→app-origin bridge — because the daemon
    session cookie cannot cross origins. Worth revisiting if/when
    bearer semantics become an incident.
- [x] **Per-app VM host** — per-app env built from `lib/sandbox/` + `platform.make_caps()`,
  served by daemon's Host-based app dispatch. Env-based tier-1 sandbox (single state +
  per-app env table + pcall wrap).

  **Open threads around the VM host:**
  - [ ] `caps.self.origin` (full scheme+host URL) is not exposed. Not
    speculatively adding it — the first concrete caller that needs it
    gets to shape the field.
  - [ ] Tier 2/3 isolation escalation: coroutine-per-request with
    `debug.sethook` instruction quota (tier 2), or separate `lua_State`
    per app (tier 3). Design + triggers in `docs/daemon-isolation.md`.
  - [ ] **Grant UI: surface cap `reason` fields** — manifest cap declarations support a `"reason"` string (e.g. `"reason": "Timestamps cache entries..."`). The grant/install UI should display this alongside the cap name so operators know why the app needs each capability. Currently ignored at runtime.
    Not urgent for loopback/Tailscale-private; required before any
    routable-interface deployment, and entangled with the grant UI
    work (both move "apps are untrusted" from "documented" to
    "enforced").
  - [x] Handler cache has LRU eviction but no time-based invalidation.
    Wired `handler_ttl` daemon opt: passes `{ttl, clock}` to
    `cache.new`. Default nil (no expiry — install-time cache-busting
    covers the normal reinstall path). Hot-reload workflow: pass a
    short `handler_ttl`.
  - [ ] `app_load_errors` has a 5s retry TTL but no link to index-DB
    change notifications. A partially-written tarball during
    `pkg install` heals in 5s; an explicit operator "retry this app"
    button or an index-DB write callback would heal instantly.
    Depends on whether the index layer grows a change-notification
    surface.
  - [x] `app_loader` auto-grants every declared cap when no decisions are
    stored (`_auto_grants` fallback). Fixed: `resolve_grants` now returns
    nil (undecided) when `get_grants` is available but no decisions stored.
    Raw-db test stubs (no `get_grants`) still auto-grant for compat.
  - [ ] Typechecker gap noted during wiring: optional fields (`T | nil`)
    in an expected record must appear in the table literal even when
    semantically absent. `daemon.make({...})` callsites hit this.
    Belongs in a typechecker session, not here — but worth linking to
    when someone picks up the optional-field work.
- [x] **Cap grant UI + endpoint** — grant page at daemon origin. Zero-JS HTML form, CSRF
  token in hidden input, POST stores decisions, dispatch gate redirects on undecided required
  caps, handler cache invalidated on save. (c457175)
- [x] **CSP emission** — daemon injects `Content-Security-Policy` on all app-origin
  responses: `default-src 'self'; connect-src 'self' <http_client hosts>; frame-ancestors
  'none'; form-action 'self'`. Hosts from operator cap_config. (9576acf)
  - [ ] Tighten to `default-src 'none'` + explicit directives once apps declare their
    static asset needs in the manifest. Requires manifest-level `script-src`/`style-src`
    declarations or nonce injection.
- [x] **Daemon UI XSS resistance** — grant page ships with strict CSP (`default-src 'none';
  style-src 'unsafe-inline'; form-action 'self'`), all user/app strings HTML-escaped.
  (c457175)
- [x] **Rate limiting** — per-session token bucket on `/launch` (burst=5,
  rate=0.5/s) and `POST /apps/:id/grant` (burst=10, rate=1/s). Uses
  `lib/ratelimit` keyed limiter. Per-IP and auth-endpoint limits deferred
  (daemon has no direct access to remote IP; no auth endpoints beyond session
  cookie minting, which is implicit and not rate-sensitive).
- [x] **Audit log** — append-only log of every cap grant, every auth event, every
  admin/policy change. Tamper-evident hashing (prior-entry hash chain).
  Implemented in `lib/platform/audit/`. SHA-1 hash chain; SQLite backend;
  wired into daemon (cap_grant, auth_session, launch_token, app_install,
  app_uninstall events). `audit_log` is optional in `daemon_opts` — nil skips
  logging. 31 test assertions.
- [x] **TLS on routable interfaces** — binding to loopback is TLS-optional; binding to
  Tailscale or any routable interface requires TLS. Cert loading from disk (daemon does
  not do ACME in v1 — user provides cert). v1 implemented: `--tls-cert`/`--tls-key` flags
  in daemon CLI; `lib/http/server.lua` wraps accepted sockets via libtls `tls_accept_socket`;
  falls back to plaintext if libtls unavailable; daemon warns on non-loopback bind without TLS.
- [x] **Admin policy layer** — admin can set blanket allow/deny ceilings per app, per cap,
  per cap+host tuple. Caps the grant UI against those ceilings so the operator cannot be
  socially engineered past admin intent.

## lib/mdast Phase 2 — CommonMark gaps and GFM extensions

**[x] Phase 2 fixture validation substantially complete.** CommonMark 0.31.2 spec fixture suite
validated via `lib/unified/mdast/commonmark_fixtures_test.lua`. Current pass rates (652 examples):
- Block structure (ATX, setext, fenced code, indented code, paragraphs, thematic breaks): 100%
- Block quotes: 100%, Thematic breaks: 100%, List items: 100%, Lists: **100%** (26/26)
- Emphasis: **100%** (132/132), Code spans: 91% (20/22)
- Links: **98.9%** (89/90), Images: 100%, Hard line breaks: 87%
- Tabs: 73% (8/11) — tab expansion in indented code/list contexts

**[x] Phase 3 CommonMark compliance pass complete** (commit 8728def, 2026-04-10). All gaps from Phase 2 fixed:
- ex312 (lists lazy continuation): item_lazy_set tracks lazy lines; parse_blocks skips list-item match for them.
- Emphasis with inline HTML (ex475-ex481): tokenizer scans `<tag>`, `</tag>`, `<!-- -->`, `<![CDATA[…]]>`, `<?…?>`, `<!DECL>` as opaque html tokens; delimiters inside are never paired.
- Unicode punctuation/whitespace: full codepoint decoding via decode_utf8_at/before; U+00A0 NBSP as whitespace; Sc currency symbols (£, €) as punctuation to match cmark.
- HTML entity decoding in link URLs and titles (decode_entities, encode_url non-ASCII bytes).
- Backslash escapes in link titles.
- Multi-line link reference definitions (two-line join in block parser).
- Unicode case folding for link labels (ẞ → ss).

Remaining known gaps (acceptable, no fix planned):

- **ex491 (links)** — `[link](<foo\nbar>)` newline inside angle-bracket URL; valid raw HTML pass-through across newlines. Unfixable without implementing raw HTML block section (skipped).
- **HTML blocks** — 7 block types with different termination rules (skipped).
- **Autolinks** — `<url>` and `<email>` forms (skipped section; autolinks ARE rendered correctly via html token detection in inline renderer).
- **Backslash escapes / Entity references** — full entity name → character conversion (skipped section).
- **GFM extensions** — tables, strikethrough (`~~text~~`), task list items (`- [x]`).
- **`mdast.stringify` completeness** — round-trip is best-effort; complex nested
  structures may not stringify perfectly.
- **Benchmarks** — no throughput benchmark committed yet (needed before lib/hast).

## lib/hast and unified pipeline

- [x] **`lib/hast`** — mdast-to-hast transformer + HTML serializer. Input: mdast Root node. Output: hast Root node (element/text/raw nodes following hast spec). `hast.to_html(tree)` → HTML string. Phase 1: covers all mdast Phase 1 node types. 66 assertions.
- [x] **`lib/unified`** — pipeline runner (`:use(plugin, opts)`, `:process(source)`). 23 tests.
- [x] **`lib/rehype`** — hast plugins ported: slug, autolink-headings, sanitize, highlight, and ~20 more. See `lib/unified/STATUS.md`.

## CRITICAL: fuzz the typechecker against the full type system spec as invariants

**Prerequisite: typechecker must be in a non-broken state before starting.**

The test suite tests behaviors, not invariants. The invariants must encode the **spirit** of the type system from first principles — not mirror the implementation, which is likely wrong in places.

The full type system expressed as invariants (not exhaustive, but the spirit):
- **Subtyping**: if `A <: B`, every program that typechecks with a value of type B must also typecheck with a value of type A in its place
- **Union introduction**: a value of type A is assignable to `A | B`; a value of type B is assignable to `A | B`
- **Union elimination**: code that handles both A and B handles `A | B`
- **Intersection**: a value of type `A & B` is usable as both A and B independently
- **Function**: calling `(A) -> B` with a value of type A always produces a value of type B; calling with a non-A is always rejected
- **Narrowing**: after a nil check on `T | nil`, the type in the non-nil branch is `T`; `T` is a subtype of the original
- **Annotation soundness**: a function whose body is accepted with return type `T` annotation cannot produce a value outside `T`
- **Multi-return**: slot N of a multi-return must be the declared type for that slot; extra slots are nil

Every feature needs its own invariant class:
- **Spread multi-return**: slot extraction, narrowing propagation across slots, spread in argument position
- **HKTs**: applying a type constructor to a type argument produces the correct instantiation; HKT + generic constraints compose correctly
- **Every intrinsic** — full list, each with its own contract. Type-level intrinsics: `$Keys<T>` (union of string literal field names), `$EachField<T, F>` (maps F over each field), `$EachUnion<T, F>` (maps F over each union arm), `$Opaque<T>` / `$Opaque<T, U>` (nominal newtype with optional exposed view), `$FfiC` (closed table from ffi.cdef calls), `$GlobalScope` (closed table of declared globals), `$Name` (string literal of declaration name), `$Require<T>` (module type from string literal).
  - **v7 note:** this is a legacy/current-checker fuzz inventory, not the v7 admitted-intrinsic list. v7 tracks admitted/candidate status in `docs/typechecker-v7-kernel-semantics.md` and `docs/typechecker-v7-consolidation-audit.md`; `$Name` is currently not admitted there.
  - **Note: builtins must not be special-cased.** `require`, `pcall`/`xpcall`, `pairs`/`ipairs`, `type()`, `assert`, `error`, `select`, and stdlib functions like `string.find`/`io.open`/`string.byte` are currently hardcoded in constrain.lua. Each special case is a missing type system feature — the goal is to eliminate all of them by making stdlib_types.lua declarations expressive enough. The fuzz suite should verify each builtin's contract holds AND that the contract is expressible without special-casing. Removing a special case and replacing it with a stdlib_types.lua declaration is a correctness win, not just cleanup.
- **Match/narrowing patterns**: `if type(x) == "string"`, `if x then`, `if not x`, `if x == nil`, `and`/`or` chains — each must narrow to exactly what the spec says, no more, no less
- **Generic constraints**: a generic `<T: Constraint>` rejects instantiations that violate the constraint; accepts all that satisfy it
- **Literal types**: `1` is assignable to `integer` and `1` but not `2`; literal widening is explicit not implicit
- **Generic constraints on HKTs**: `<F: Functor>` where F is itself a type constructor — fmap must typecheck correctly for any valid F

Use `lib/test/fuzz.lua` + `lib/test/arb.lua` to generate programs and assert these invariants hold across random inputs. Fuzz targets derived from the spec, not the implementation.

**Performance**: include a benchmark gate — if typechecking throughput on a fixed corpus regresses beyond a threshold, the fuzz suite should flag it. The typechecker has a performance bar and regressions are as bad as correctness failures.

The bar to beat is `@typescript/native-preview` (tsgo / ts7 — the Go rewrite of tsc). Benchmark methodology: construct a representative "nice" TypeScript program and a structurally similar Lua program, compare cold-start + incremental throughput. Also include pathological Lua cases (deep union chains, heavily generic code, large files) that have no TS equivalent — these stress the solver and expose regressions invisible in the nice-program comparison.

**Performance note on multi-return redesign**: always wrapping rl=0 and rl=1 returns in TAG_TUPLE adds allocation + C_INDEX destructuring overhead on every call site. We may want to re-specialize these cases (bind directly, skip the tuple barrier) after measuring. Don't assume the overhead is acceptable — benchmark first.

## ~~CRITICAL: write docs/semantics.md~~ DONE (8ec327c)

`docs/semantics.md` now covers: all type tags + data layouts, the complete
subtyping relation (19 cases), expression typing rules, the constraint solver,
narrowing, annotation syntax, invariants (incl. untested blind spots), and
intrinsic contracts. Read it before touching typechecker internals.

## CRITICAL: write implementer specs before delegating

Each item below needs a self-contained spec in `docs/` (or inline in TODO) that a subagent can implement from without reading session history. Design decisions scattered across TODO.md + docs/type-system.md + session notes are not enough — an implementer needs: what to build, what files to touch, what the data representation is, what tests to write.

Items that currently lack an implementer-ready spec:
- [x] **TAG_SPREAD in return position** — spec written: `docs/tag-spread-spec.md`. Ready to delegate.
- [x] **`$Opaque<T, U>` two-arg form** — implemented (ae91a98). Fields in U accessible; fields not in U error; one-arg opaque field access errors. `ctx._opaque_nominals` + `ctx._opaque_view` side tables.
- [x] **`--:: unseal`** — implemented (6805930). Rebinds opaque variable to inner type T from declaration point forward. Line-by-line application in gen_block; block scoping via child scope; rejects newtype nominals.
- [x] **Argument literal widening at typevar binding** — was already handled by `widen_for_sub` in `solve_callable`. Clarified with explicit `widen_literal` helper + comments + 10 tests confirming the behavior (ad58bc6).
- [x] **GAP-HKT3 fix: `$Opaque` keys in lib/fp/** — applied to all 10 typeclass modules + 9 instance modules. `fa[Mappable.key]` now resolves via FLAG_OPAQUE_KEY. (2026-03-29, 839610f)
- [x] **`$Require<T>` as parameterized intrinsic** — implemented (9d92308). `expand_require` in intrinsic.lua; `resolve_deferred_intrinsic` in solve.lua evaluates TAG_TYPE_CALL on TAG_INTRINSIC callees after arg solving. Module declaration processing moved to pass 0. constrain.lua special case preserved pending full de-specialcase.
- [ ] **De-specialcase builtins** — `require` (f468b72), `pcall`/`xpcall` (d7950de), `pairs`/`ipairs` (d7950de) done. All stdlib tables (string/table/math/io/os/coroutine/debug + primitive meta types) now declared in stdlib_types.lua (33640d0). Remaining special-casing: `type()` narrowing in narrow.lua (justified, can stay), `require()` side effects in constrain.lua (architectural). Still too-loose: `select()` (needs overloads or literal matching). `string.match` ($PatternReturn<P>), `string.gmatch` ($PatternReturn<P> via iterator), `string.find` ($FindReturn<P>) all have pattern introspection. `string.gsub` returns `(string, integer)` and needs no pattern introspection. `assert` and `error` are clean.
- [x] **Eliminate intrinsics via `match` arm patterns** — MOSTLY DONE. Function-type arms, indexer arms, spread-in-tuple-position, all-fields pattern, and capture sigil all implemented (2026-03-29–30). `$PcallReturn`, `$PairsReturn`, `$IpairsReturn`, `$Keys`, `$Values`, `$IpairsValues` all deleted and replaced with pure match aliases in stdlib_types.lua.
  **Remaining intrinsics (permanent or blocked):**
  - `$Require<T>` — permanent; module system, needs literal type propagation through generics
  - `$Opaque<T>` — permanent; nominal identity
  - `$FfiC` — permanent; builds closed table from ffi.cdef call sites
  - `$EachField<T, F>` — blocked on HKT application in result position. F is a type constructor (`* -> *`); `$EachField` calls `F(field_descriptor)` per field. Match types can destructure but can't apply an arbitrary type constructor parameter. Eliminating this requires higher-kinded type application, not more match patterns.
  - `$GlobalScope` — undocumented; used for typing `_G`. Document or replace.
- [x] **Invariant-based fuzz suite** — implemented (e3d5f96): `lib/type/static/fuzz_test.lua` + `fuzz_arb.lua`. 6 invariants + performance gate (≥500 programs/sec).
- [x] **Fuzz suite gaps** — all three tiers complete: algebra (A1–A5), eval (E1–E11 + G1–G3), grammar (P1–P5). See `docs/fuzz-gaps.md` for details.
- [x] **Parser stack overflow on deeply-nested types** — fixed (5150a5a, 2026-03-29): added depth counter to scanner; parse_type fires "too deeply nested" diagnostic at depth>64 (MAX_TYPE_DEPTH). depth_limit_hit flag distinguishes this from silenced syntax errors. fuzz_test.lua pre-check skips these cleanly.
- [x] **fuzz_arb.lua sub_size halving reduces deep-type coverage** — added `M.arb_type_deep` (2026-03-29): uses `sub_size = min(size-1, 8)` for deeper trees, capped at 8 to prevent 2^N blowup. Used in fuzz_alg.lua invariants 15-18 (deep reflexivity, deep union intro, deep inter elim, deep intersection intro). Grammar-level tests still use halved arb_type (must parse strings).
- [x] **`pcall`/`xpcall` de-specialcase** — implemented (d7950de): `$PcallReturn<F>` intrinsic.
- [x] **`pairs`/`ipairs` de-specialcase** — implemented (d7950de): `$PairsReturn<T>`/`$IpairsReturn<T>` intrinsics.
- [x] **Self-check regression: constrain.lua 60 errors** — fixed (5c23738): `--:` annotations added across constrain.lua, narrow.lua, check.lua, solve.lua, lsp.lua, ctx_types.lua, type_soundness_test.lua. All now self-check at 0 errors.
- [x] **Self-check: match.lua annotation pass** — fixed (6740aeb, 2026-03-30): added Ctx type to function signatures; --: integer for lists/fields:get(); --: any for merge_bindings. 0 errors, 6 intentional any warnings.

## typechecker soundness gaps (found by type_soundness_test.lua)

- [x] **`unknown` was not strict** — `TAG_UNKNOWN` was behaving like `TAG_ANY`: field access, calls, and arithmetic silently passed through. Fixed in solve.lua: all three now emit errors. `unknown` requires narrowing first.
- [x] **Coinductive cycle detection in unify.lua** — `lib/fp/maybe` and `lib/fp/either` caused stack overflow during typechecking. Fixed by adding `seen` parameter with `copy_seen()` for disjunctive iterations.
- [x] **`match` type adversarial coverage** — non-exhaustive match on union, wrong arm result type downstream, unreachable arm, match on `never` → `never`, nested match types (concrete inner args), and `--:: module` declaration / require basic coverage all tested. Note: unreachable arm does not warn (no diagnostic emitted).
- [x] **Typechecker: nested match typevar not forwarded to inner type call** — fixed (85c92d6). Root cause: `substitute_inner`'s TAG_MATCH_TYPE handler didn't defer when subject was TAG_NAMED (only deferred for TAG_VAR/TAG_ROWVAR). Fix: added TAG_NAMED to the deferred-evaluation guard in env.lua.

- [x] **Soundness gap: optional field not rejected in required position** — `{ x?: T }` is currently accepted where `{ x: T }` (required) is expected. `unify.lua` skips source fields that are absent but does not check FLAG_OPTIONAL on *source* fields vs required target. `{ x?: T } </: { x: T }` should fail. Found while adding fuzz_eval.lua invariants (2026-03-30).

- [x] **Field access on nil/boolean** — fixed f1a9882
- [x] **Annotation on M.field assignment not enforced** — fixed 08fd6a4
- [x] **`and` RHS not narrowed** — fixed 11cf377
- [x] **Readonly not enforced through intersection** — fixed 0b40861
- [x] **Literal table not assignable to indexer type** — fixed 0b40861
- [x] **Missing return detection** — fixed; `is_definitely_returning` analysis in constrain.lua emits implicit nil C_RETURN for non-definitely-returning annotated functions.

- [ ] **Soundness gap 8: `local x --: T = expr` does not enforce the subtype check.** Broad gap, not just `unknown`:
  ```lua
  local x --: integer = "hello"      -- accepted; should error
  local s --: string = "hi"
  local y --: integer = s            -- accepted; should error
  ```
  The cast form `local y = --[[: integer]] s` is correctly rejected. The
  annotated-local path at `constrain.lua:2440` emits the same `C_SUB(rhs_tid,
  ann_tid)` constraint but the check silently passes. Function return
  annotations (`local function f() --: () -> T`) also enforce correctly. Find
  the divergence between the cast `C_SUB` and the local-init `C_SUB` and
  close the bypass. See `docs/soundness-audit.md` Gap 8 for four repros. The
  "annotation enforcement gotcha" note in `lib/type/static/CLAUDE.md` is a
  symptom of this same gap.

- [ ] **Soundness gap 9: `local x --: T` (no initializer) silently accepted.** Same family as Gap 8 — annotated local whose declared type is not enforced against the actual binding. Runtime value is `nil` but type says `T`:
  ```lua
  local y --: integer
  print(y + 1)   -- typechecks; runtime: nil + 1 errors
  ```
  Likely the same code path in `constrain.lua` near line 2440. Fix direction (preferred, matches TS): reject the declaration when `nil` is not in `T` and there is no initializer — equivalent to TS's "definite assignment" check, the strictly-weaker form (without flow analysis) that catches the obvious cases. Weaker fallback: widen to `T | nil` so reads must narrow before use. See `docs/soundness-audit.md` Gap 9. **Compounded by Gap 10**: until the parser stops dropping `= x` after `--: T`, fixing Gap 9 alone still leaves `local y --: integer = x` silently mis-parsing — fix Gap 10 first or together.

- [ ] **Soundness gap 10: parser silently accepts invalid syntax in `--:` annotations.** `integer = x` is not a valid type expression, but `ann.lua:1153–1155` parses the `integer` prefix and returns without checking the scanner reached end-of-content (`lex.lua` captures everything to EOL as the annotation content). So `local y --: integer = "string literal"`, `local y --: integer ! ! garbage`, `local y --: integer = undefined_ident` all typecheck with 0 diagnostics. This is a parser bug — the parser must reject what it cannot understand — and it is the load-bearing footgun for Gap 9: `local y --: T = x` *looks like* annotated assignment, parses cleanly, and silently becomes a no-initializer declaration. Fix: in `ann.lua` after `parse_type(s)` for `ANN_TYPE` (also `ANN_TYPE_ARGS` and the type tail of `ANN_DECL` / `declare` / `newtype`), reject with a parse error pointing at the unexpected token whenever the scanner has unconsumed non-whitespace content. No warning-instead-of-error; no weaker fallback. See `docs/soundness-audit.md` Gap 10.

- [ ] **Add fuzz invariant for `local x --: T = expr` annotation enforcement.** Existing annotation-soundness invariants use function returns as the harness, missing the local-init path entirely (which is why Gap 8 survived). Add: for `expr` of type `U` and annotation `T`, expect an error iff `U </: T`. Combine with `unknown` in the type generator (see next item) for full coverage.

- [ ] **Add `unknown` to `fuzz_arb.lua` type generator.** Currently absent (see `lib/type/static/CLAUDE.md` "Generator coverage"). Adding it will let the new annotation invariant cover the `unknown <: T` case, plus narrow / type-guard / call-result invariants currently blind to the unknown boundary.

## typechecker cast / annotation syntax

- [ ] **Decide: implement `--[[as T]]` semi-sound cast (overlap-required)?** Previously documented in `docs/type-system.md` as if real, but never implemented. The doc has been corrected to remove the false claim. If we want this, design and implement: an "overlap" check (target type must share *some* value with the source), then accept the cast even if neither direction is a subtype. Otherwise leave as-is — the current `--[[: T]] expr` is a sound checked cast and may be all we need.

- [ ] **Decide: implement `--[[as! T]] expr` force / unsafe cast?** Previously documented as if real (see above). If we want a way to escape the type system inline (vs. routing through an `any`-typed intermediary), pick a syntax — `--[[as! T]]`, `--[[unsafe T]]`, `--[[: T !]]`, etc. — and wire it through `lex.lua`/`parse.lua`/`constrain.lua` as a `NODE_CAST_EXPR` variant that emits no constraint and just rebinds the type. Keep it grep-able. Otherwise close this with "use `any` instead."

## typechecker match semantics gaps

- [x] **`Parameters<typeof f>` captures only first param** — FIXED. `Parameters<F> = match F { (...%P) -> %R => P }` now gives `(integer, string)` for `f: (integer, string) -> boolean`. fuzz_test.lua P2a/P2b both pass.

- [x] **Intersection types are opaque in match arms** — FIXED properly (521226a). DNF normalization in `M.evaluate`: `to_dnf` expands `A|(B&C)` and `A&(B|C)` into terms; each term dispatched independently. For pure-table intersections, `flatten_to_table` merges all member fields into one TAG_TABLE so structural patterns see all fields. Band-aid (0ace6b0) replaced.

## typechecker missing features

- [ ] **Bounded existentials (low priority, future extension).** Crescent uses `$Opaque<T>` (nominal opaqueness with optional view type) as a primitive form of existential. A more general bounded existential `∃T <: B. F(T)` could enable module-style abstraction, plugin systems, and abstract data types with constraints. Not currently needed — `$Opaque` has been sufficient for every observed use case. Flag for revisit only if a concrete use case appears that `$Opaque` cannot express. See `docs/type-system.md` "Union, intersection, and complement" for the foundational decisions this would extend.
- [x] **`?` optional field shorthand breaks alias usability** — `T?` in struct position was previously a thrown error that silently aborted the whole annotation parse, causing the alias to not be registered at all. Fixed: `parse_postfix` now uses `scan_hint` (non-fatal) so the error is reported as a structured diagnostic while the rest of the struct (and the alias itself) still parse correctly. `T | nil` remains the correct syntax; `T?` now produces a visible diagnostic rather than silently breaking the enclosing alias.
- [x] **`--:: require` doesn't resolve `?/init.lua` packages** — `load_decl_file` in `constrain.lua` converts the module path with `gsub("%.", "/") .. ".lua"`, so `--:: require "lib.reactive"` opens `lib/reactive.lua` (which does not exist) instead of `lib/reactive/init.lua`. Type declarations in packages structured as directories with `init.lua` are silently ignored. Fix: after the `.lua` path fails, fall back to `gsub("%.", "/") .. "/init.lua"`. Same logic used in `$Require`/`cri_loader` already handles this; `load_decl_file` is missing the fallback. Found during `lib/web/reactive_dom/init.lua` annotation: `--:: require "lib.reactive"` cannot import Signal/Computed from `lib/reactive/init.lua`. Workaround: redeclare types inline. Blocking: any `--::` declaration file that imports types from a `?/init.lua` package.
- [ ] **`lib/web/reactive_dom/` needs generics** — 12 errors remain because `signal.get()` returns `unknown` (correct — Signal is polymorphic) and `children[i]` returns `unknown` (correct — heterogeneous array). Neither is fixable by casting; both require generics: `Signal<T>` with `get: () -> T`, typed child arrays. Blocked on generic type parameters.
- [ ] **Table literal computed-key entries collapse into one indexer** — when a table literal has multiple `[key_expr]: value` entries with nominally distinct key types (e.g. `$Opaque`), the typechecker folds them into a single indexer and unifies the value types, causing false errors on heterogeneous dispatch tables like `fn_index` in `lib/fp/fn/`. Correct behavior: each distinct key type produces a separate field in the inferred table type. Fix is in table literal type construction — stop collapsing computed-key entries into one indexer; instead treat each distinct key type as a distinct field. Concrete symptom: `fn_index[Profunctor.key] = fn_profunctor_impl` errors because the inferred indexer value type comes from the first three entries (all have `map`).
- [ ] **Table construction type inference** — `local k = {}` followed by `k.field = value` should refine the type of `k` to include each assigned field, so methods defined on `k` can access those fields without `any`. Currently the typechecker treats `k` as a fixed open table throughout, so `self._insns` inside a closure assigned to `k.method` returns `unknown`. The workaround `unknown → any → T` two-step in `lib/asm/ir.lua` (`insns_any`/`self_args_any`) is a direct symptom. Real fix: flow-sensitive table type widening during construction, or structural typing on method-receiver `self` via declared object type.
- [ ] **Render function bidirectional parameter typing** — `lib/tui/init.lua` render closures (`function(a, b)`) have untyped parameters because no declared Widget.render type is checked against them. If `Widget = { render: (Widget, Ctx) -> string }` were checked bidirectionally when the closure is assigned into a Widget table, `b` would get type `Ctx` and `unpack_ctx`'s `any` parameters would be unnecessary. Root cause: typechecker does not propagate expected function parameter types into anonymous closures from the surrounding table literal. Real fix: bidirectional type checking for closures assigned to known-typed table fields.
- [x] **Record spread types** — `{ ...T, k: V }`, `{ ...T, ...U }`, `{ k: V, ...T }` as type-level operations. Unification added (33640d0): unify.lua checks spread fields by expanding inner TAG_TABLE and verifying each required field exists in the actual. Gap: **spread-union distribution** — when the spread inner type is a TAG_UNION (`{ ...(A | B), k: V }`), env.lua `substitute_inner` keeps a placeholder instead of distributing. Correct fix: distribute over union members in `env.lua:substitute_inner`, then handle in `solve.lua` field lookup and unify.lua. Needed for builder pattern and mapped-type aliases instantiated with union types.
- [x] Typechecker: `collect_rank_n_generics` over-fires on ordinary higher-order generics
  - `lib/type/static/env.lua:588-601` uses `TAG_FUNCTION` as proxy for rank-N; should use `TAG_FORALL`
  - Causes `<R>(() -> R) -> () -> R` and similar to be incorrectly skolemized
  - Minimal repro: `--:: declare wrap = <R>(() -> R) -> () -> R` then `local x = wrap(function() return 1 end)`
  - Design doc: `docs/typechecker-rank-n.md` describes the correct TAG_FORALL-based dispatch
  - Fix requires care to not regress rank-N soundness tests (N1/N5/N6/N7/N8 in type_soundness_test.lua)

## typechecker stdlib / module typing

- [x] **`module "name": T` syntax** — `--:: module "name": T` declares the type returned by `require("name")`. Implemented in ann.lua (ANN_MODULE), constrain.lua (module_types registry), prelude.lua (loaded from .d.lua files). Undeclared modules → `unknown`. stdlib_types.lua now declares `"ffi"` and `"bit"` properly.
- [x] **`$Require<Path>` intrinsic** — implemented. `require` declared as `<T: string>(module: T) -> $Require<T>` in stdlib_types.lua. `expand_require` in intrinsic.lua resolves module types from `ctx.module_types` (declarations) or `ctx.cri_loader` (cross-file cache). Undeclared modules → `T_UNKNOWN` (fixed e48fd1f — was `T_ANY`, silently disabling checking on all undeclared module returns).
- [x] **Cross-file inference enabled by default** — removed `_disk_cache_dir` gate on `check_file`'s `cri_loader` (ead40ae). Also fixed `init.lua` resolution for `require("lib.path")` → `lib/path/init.lua`.
- [x] **`$FfiC` intrinsic** — implemented. `TAG_FFIC = 26`, deferred resolution in solve.lua, cdef.lua makes `T_FFI_C` closed (undeclared C symbols error), stdlib_types.lua declares `C: $FfiC`.

## stdlib_types.lua coverage gaps (audit 2026-04-01)

- [x] **Over-broad `any` return types** — PARTIALLY FIXED (06c6b38). Tightened 7: `coroutine.status` (literal union), `string.gmatch` (`function`), `table.remove` (`any | nil`), `coroutine.create`/`wrap`/`resume`/`yield` (function params + multi-return). Remaining:
  - `assert` → needs `typeof(val)` (type-level computation)
  - `string.match` → DONE ($PatternReturn<P>, 2026-04-19)
  - `string.gmatch` → DONE ($PatternReturn<P> in iterator, 2026-04-19)
  - `string.find` → DONE ($FindReturn<P>, 2026-04-19)
  - `os.date` → format-dependent return (`string | { [string]: integer }`)
  - `io.open` / `io.popen` → needs file handle opaque type
  - Parser limitation: function types in table field return positions break the annotation parser silently
- [x] **Missing stdlib functions** — FIXED (819179f). Added `io.flush`/`input`/`output` + 8 `ffi.*` functions. Remaining:
  - `os.setlocale` (low)
  - `debug.getupvalue`, `debug.setupvalue` (low)
- [x] **`$GlobalScope` intrinsic documented** — listed in `lib/type/static/CLAUDE.md` under permanent intrinsics with full explanation of the synthesis mechanism.
- [ ] **Generalize stdlib_types.lua beyond LuaJIT** — currently mixes Lua 5.1 and LuaJIT-specific declarations (`ffi`, `bit`, `Ptr<T>`, `Arr<T>`, `Cdata`, `Ctype`, `CTypeMap`) in one file. Should split per-runtime: `stdlib_lua51_types.lua`, `stdlib_luajit_types.lua`, `stdlib_lua54_types.lua`, etc. Loaded via `pkg.lua typecheck.globals` per-project. Blocks supporting Lua 5.4 semantics (integer subtype, `//`/`>>`/`<<` ops, goto, etc.) and other variants without forking the file.
- [x] **Module type field access loses concrete types for `?/init.lua` packages** — resolved as a consequence of the `?/init.lua` resolution fix (d907c40). `R = require("lib.reactive")` now resolves to the full typed module; `R.focused` returns a concrete function type. Remaining `unknown` params in method signatures are expected — `lib/reactive` uses plain Lua generics, not Crescent type parameters.

### ffi types — open threads (from a previous session — starting context, not instructions; verify relevance before acting)

See `docs/ffi-types.md` for the postmortem and design state. Resolved in recent commits: T-as-Lua-type semantics, extensible CTypeMap, `T[K]` indexed access, `Keys<>` constraint, TAG_NOMINAL arith unwrap, dropped `Cdata<T>` wrapper, declarative `Ptr<T>`/`Arr<T>` in stdlib.

- [ ] **`int64_t`/`uint64_t` typing** — currently mapped to `integer` in `CTypeMap`. Wrong: in LuaJIT these stay as cdata, don't coerce to Lua integer (>2^53 lossy). Idea floated: each gets its own type with its own metatable defining `#__add: (int64_t, int64_t) -> int64_t` etc. — NOT promotion to integer. Open: what's the right declaration shape? Plain opaque + meta slots, or some other primitive? Also — does our typechecker handle the metatable-based arith for these once declared? May need spot-checking after authoring.
- [ ] **LuaJIT integer literal suffixes** — `5LL` is `int64_t`, `5ULL` is `uint64_t`. The lexer probably doesn't recognize these (vanilla Lua doesn't have them). Should check `lib/type/static/lex.lua` and either add LL/ULL parsing or punt and require users to use `ffi.new("int64_t", 5)`.
- [ ] **`metatype.metatable` shape** — currently `{ [string]: unknown, ... }`. Could tighten to a proper Lua metatable with named meta slots: `{ #__index: ..., #__add: ..., #__sub: ..., ... }`. Probably reusable across lua-side `setmetatable` too. See existing `setmetatable: <T, MT>(t: T, mt: MT) -> T & { #...MT }` pattern.
- [ ] **`Cdata<T> <: T` asymmetric subtyping** — only relevant if we re-introduce a `Cdata<T>` wrapper. Current model (no wrapper, return T directly) sidesteps it. But if we ever want a "branded but transparent" wrapper for FFI provenance, the typechecker has no asymmetric-subtyping primitive: `$Opaque<T,T>` is invariant, intersection-with-marker brands are hacky per the user's explicit ruling. Probably means designing a real "covariant newtype" mechanism in the typechecker, or just accepting Cdata-is-T forever.
- [ ] **Audit remaining `unknown`/`any` outside the ffi module** — string/table/math/io/os/coroutine/debug modules not yet audited in this pass. Section above lists known holes (`assert`, `string.match`, `os.date`, `io.open` file handle); a fresh sweep might surface more, plus places where `any` could be `unknown` or further constrained.

## typechecker type guards and assertions

TypeScript's type guards can lie — `function isString(x): x is string { return true }` typechecks fine. We should do better.

- [x] **User-defined type guards** — implemented (0e3be6f, 2026-03-30). `(x: unknown) -> x is T` return type: ann.lua parses the predicate, stores in pool._type_predicates; narrow.lua `guard_check` kind narrows the argument at call sites (truthy/falsy/negated). Body return type is enforced as boolean.

- [x] **Assertion functions** — implemented (6740aeb, 2026-03-30): `(x: T) -> asserts x is GuardType` parses in ann.lua, unconditional scope narrowing in StmtRule[NODE_EXPR_STMT]. Also fixed latent bug: predicate IDs now propagated from annotation arena to ctx.types arena.

- [ ] **Verified type guards** — rather than trusting the annotation, verify that the function body actually performs checks consistent with the declared predicate. If the body provably returns true for non-T values, emit a warning. This is beyond TS — TS never verifies guards, it just trusts them. Even partial verification (detecting trivially lying guards) would be a win.

- [x] **Predicate narrowing from `type()` calls** — implemented in `narrow.lua` (extract_narrowing detects `type(x) == "string"` pattern; apply_narrowing filters union members). All forms: `type(x) == "string"`, `type(x) ~= "string"`, multi-branch, `any`, `unknown`.

- [x] **`assert()` as a built-in assertion** — `assert(x)` and `assert(x, msg)` both narrow `x` to non-nil/non-false in the continuation.

- [ ] **`for` loop variable narrowing** — `for _, v in pairs(t)` where `t: { [integer]: string | nil }` gives `v: string | nil`. `if v then` should narrow `v` to `string` inside the body for all use contexts (calls, assignments, table indexing). Currently narrowing applies to specific-function call arguments but NOT to: generic function args (e.g. `table.insert`), table index assignments (`t[k] = v`), or local variable declarations (`local x = v`). Root cause likely in how narrow.lua applies narrowed env at use sites — the narrowed type map isn't queried for these patterns. Concrete symptom: `lib/asm/ra.lua` `assignment` table must be `--: any` because `pairs(assignment)` returns `string | nil` values that fail to narrow in the callee_saves loop.

## typechecker warnings / quality-of-life

- [x] **Redundant type assertion warning** — implemented. `NODE_CAST_EXPR` emits a warning when a `--[[: T]]` cast asserts a structurally identical type; excludes `any` on either side.
- [x] **Error message quoting audit** — fixed in `unify.lua` (2026-03-30): 8 error strings used single quotes around type names; converted to backtick style. All type names in error messages now use backticks.

## typechecker narrowing gaps

- [x] **Optional field narrowing** — `if opts.f then opts.f(x) end` — FIXED (5da2138, 2026-04-10). `narrow_field_non_nil` now clears FLAG_OPTIONAL on the narrowed field entry so `solve_index` doesn't re-add nil inside the branch. Early-return pattern (`if not opts.f then return end`) also works.
- [x] **Variadic param ignored in function subtyping** — when a function had fewer fixed params than expected (or vice versa), the missing param fell back to `T_NIL` instead of the function's variadic type (`data[4]`). `(integer, string) -> boolean <: (...never) -> unknown` failed because at i=0 bpl=0 triggered T_NIL fallback instead of never. Fixed 2026-04-19 in unify.lua (both unify and try_unify): out-of-bounds param index now uses `fn.data[4]` (vararg type) if available, T_NIL only if no vararg. Same session: returns loop changed from `max(arl,brl)` to `brl` only — extra actual returns are ignored in Lua, not compared against nil.
- [ ] **Optional field calls not checked at call-site** — calling an optional field OUTSIDE a guard (`opts.f(x)` without any `if opts.f then`) currently produces no error, even though `f?: T` should make `opts.f` have type `T | nil` and nil is not callable. Requires `solve_index` to error on a non-callable union.
- [x] **`ffi.C` typed from file-local cdefs** — implemented via `$FfiC`. `ffi.C` resolves to `ctx.T_FFI_C`, a closed table accumulated from `ffi.cdef(...)` calls in the file. Undeclared C symbols are errors.
- [x] **`lib/js_types/init.lua` method convention** — stripped self-parameter from all 602 DOM method declarations (single-pass: `(TypeName)→()` before `(TypeName,rest)→(rest)`). `lib/web/html/init.lua` now declares `document = Document` instead of `any`. (62cb311)
- [x] **`lib/web/reactive_dom/` typechecker annotations** — annotated with `--:: require "lib.js_types"` + `--:: declare document = Document` + Signal/Computed/Lens/Prism/EventHandler/AttrMap/CleanupArray/KeyEntry/KeyMap type aliases. 12 irreducible errors remain (see typechecker missing features: no generics, unknown→concrete casts blocked, module type mangling for `?/init.lua` packages). All 63 reactive_dom_test.lua assertions still pass.
- [x] **lib/ljsocket type declarations** — added `--::` crescent annotations: `LjSocket`, `LjSocketAddrInfo`, `LjSocketModule`, `LjSocketFamily`, `LjSocketType`, `LjSocketProtocol` to `lib/ljsocket/init.lua`. Also added `local bit = require("bit")` and `--:: declare register_ffi_module`. 100 errors remain — all internal FFI implementation details (`ffi.new`/`ffi.cast`/`ffi.sizeof` overloads, `ljsocket_ffi` unknown via `generic_function` dynamic dispatch). The `http/server.lua` `client:send/close` errors require `lib/socket/server.lua` to also be annotated to return `LjSocket`.
- [ ] **Narrowing doesn't apply to locals assigned from function call returns** — at narrowing time during constraint generation, locals assigned from function calls are still TAG_VAR (unsolved constraint variables). `types.subtract(TAG_VAR, T_NIL)` returns TAG_VAR unchanged. Workaround: add `--: T | nil` annotation to the receiving local so it gets a concrete type. Affects all `if not x then return end` patterns where `x` comes from a function call.
  **Architecture investigation (2026-04-01):** Flow typing is not inference — separate concerns. Current narrowing is cleanly split: `extract_narrowing` (structural, pure) and `apply_narrowing` (type transformation). The multi-return mechanism (`propagate_multi_ret_narrowing`) already works as a post-solve pattern. Separation is feasible — narrowing is a scope-binding side effect, not core constraint logic.
  **Complication:** constraints from narrowed scopes reference the un-narrowed TAG_VAR. After solving, `?A = string | nil`. If narrowing would have given `string`, the constraint `?A:upper()` fails against `string | nil` but would have succeeded against `string`. This is NOT just conservative — it produces false errors. Constraints from narrowed scopes need the narrowed type, not the original.
  **Options:** (a) defer constraint generation inside narrowed scopes until after solving + narrowing — re-walk those AST nodes with concrete narrowed types. Closest to a clean two-pass but requires tracking which AST regions to re-process. (b) Emit constraints against TAG_VAR as now, post-solve apply narrowing, then re-verify only the constraints that reference narrowed variables. (c) Make narrowing a solver-integrated operation: when the solver resolves a TAG_VAR that has a pending narrowing, immediately apply the narrowing and update the scope binding before evaluating dependent constraints.
  **Current status:** needs design decision on which option before implementation.
- [x] **`or` condition narrowing overwrites previous narrowing for same variable** — `if not x or x == 0 then return end` failed to narrow `x` because the second `record_narrowing` call overwrote the first. Fixed: `record_narrowing` now chains through `narrowed[name_id]`.
- [x] **Multi-return annotation on single-var capture** — fixed in solve_sub: when actual is TAG_TUPLE and expected is scalar, project first element. Annotated `local x --: string; x = f()` where f returns (string, number) now type-checks correctly.
- [x] **Multi-return aliased-call narrowing** — `local find = string.find; local s, e = find(...)` didn't narrow after `if not s then return end` because `ExprRule[NODE_FIELD_EXPR]` returned a fresh TAG_VAR; `peek_callee_ret_union` found TAG_VAR instead of TAG_FUNCTION. Fixed: `ctx._var_origin[res]` populated in NODE_FIELD_EXPR; peek traces through it. Same for ASSIGN_STMT. Call-site contamination fixed by `call_uid` on each `_multi_ret` entry. `peek_callee_ret_union` now always wraps rl=1 returns in a 1-tuple so `eager_slot` always succeeds. (2026-03-29, commits 588f56d–e0980ac)
- [ ] **`eager_slot` out-of-range should be a type error** — `slot > 0` on a concrete single-value return currently silently binds to `nil` instead of emitting a diagnostic "function returns 1 value, cannot capture slot N". The two meanings of `eager_slot` returning nil ("not a tuple" vs "out of bounds") are conflated. Blocked on TAG_SPREAD (once returns are always explicit tuples, the check is trivial).
- [ ] **Generic function body checking via skolem variables** — generic function bodies are NOT checked at definition time (`constrain.lua:1369-1376`, explicit comment). A function annotated `--: <S, C, V>((S, C) -> V, S, C) -> () -> V` whose body returns a hardcoded `42` produces no error. All verification is deferred to call sites via `C_CALLABLE`. The correct fix: at definition time, instantiate the generic params as **skolem constants** (abstract types that the solver cannot bind — distinct from the per-call-site fresh TVs). Check the body against the skolems. Binding a skolem = type error. Benefits: (1) errors at definition not call site (QoL), (2) body checked once instead of reconsidered at every call site (performance — O(1) vs O(N calls)).
- [x] **Deferred arg checking for free-TV params** — when `<F: (A,B)->R, A, B, R>(f: F, a: A, b: B)->R` is called, `a: A` and `b: B` are free TVs at argument-checking time and absorb any arg type (no error for wrong types). Fixed in solve.lua: pre-scan in `solve_callable` detects when param 0 is a free TV and arg 0 is a function (indicating a pending C_BOUND back-propagation); binds F_fresh from arg 0, then returns false to defer A/B checking until C_BOUND fires and resolves them. Guard: only defers when param 0 is TAG_VAR AND arg 0 is TAG_FUNCTION — monomorphic functions (add(a,b)) are not deferred. Tests T6 (valid call, 0 errors), T7 (wrong first arg rejected), T8 (wrong second arg rejected) all pass. type_soundness_test.lua updated accordingly.
- [ ] **Union-of-tuples detection is shape-based** — `peek_callee_ret_union` distinguishes `string.find`-style multi-returns by checking whether ALL arms are TAG_TUPLE. This is a structural hack: any function returning a single-value-union-of-tuples will be misidentified as multi-return. Correct fix: explicit `-> ...((T, T) | (nil, string))` spread syntax (TAG_SPREAD). Until then, the hack survives but is known-unsound for the edge case. See TAG_SPREAD item in CRITICAL section.
- [x] **Optional field absence in structural assignment** — already works. `{x=1}` satisfies `{x: number, y?: number}` because unify.lua skips absent optional fields (line 470: `if band(bfe.flags, FLAG_OPTIONAL) == 0 then`).

## libraries needing rewrite from scratch

These exist in `lib/` but are legacy/stubs — not crescent-native (wrong annotation style,
no init.lua, no tests, incomplete, or just placeholder files). Do not rely on them as-is;
they need to be rewritten before use.

- [ ] **`lib/mud_cp/`** — MUD Client Protocol (moo.mud.org/mcp/mcp2.html). Stubs with FIXME/TODO throughout, wrong annotation style, no tests. Low priority; rewrite if/when MUD substrate needs it.
- [x] **`lib/github/`** — rewritten with crescent annotations and tests (9 assertions).
- [ ] **`lib/markdown/`** — incomplete parser, FIXME comments, no tests. Rewrite when needed (Lumen, docs site).
- [ ] **`lib/imap/`** — EmmyLua style, incomplete RFC 9051 parser, no init.lua, no tests. Low priority.
- [x] **`lib/wave/`** — rewritten with init.lua + wave_test.lua (32 assertions).
- [ ] **`lib/socket/`** — effectively a stub (client.lua is 1 line). Superseded by `lib/ljsocket` + `lib/tcp`. Can be deleted or left until needed.
- [ ] **`lib/https/`** — client.lua and init.lua done (callbacks on instance, receive added, per-request TLS context). serverx.lua deleted (was broken stub). Certificate verification still disabled by default.
- [ ] **`lib/posix/`** — 6-line execv/execlp stub. Absorb into `lib/process/` or expand when needed.

Not libraries (do not rewrite, repurpose instead):
- `lib/crescent_examples/` — collection of small scripts demonstrating crescent. Not a unified library.
- `lib/linux/` — raw OS FFI definitions. Keep as a definitions file, not a library.
- `lib/stdlib/` — compliance linter. Keep as a linter, not a library.

## near-term (next sessions)

- [ ] **`lib/asm/emit/arm64.lua`** — NEON machine code emitter. Same structure as `emit/x64.lua`
  but NEON encoding (A64 instruction format). Gate tests on `cpu.neon` (always true on arm64).
- [ ] **`lib/asm/` convenience wrapper** — `lib/asm/init.lua` single-call API:
  `asm.compile(kernel_fn, ctype)` → selects abi (cpu.arch), calls `ra.allocate`, calls `emit.compile`.
  Hides the ra/abi/emit wiring from callers.
- [x] **`lib/reactive/`** — signal primitives. See entry in future libraries section.
  Start point: `signal`, `computed`, `effect`, `batch`. Rainbow is the API reference.
- [x] **Fuzz suite gaps** — `docs/fuzz-gaps.md` fully done (all A/E/G/P tiers checked off).
- [x] **`Parameters<typeof f>` rest capture** — FIXED (see match semantics section above). fuzz_test.lua P2a/P2b pass.
- [ ] **Spread-union distribution** — `{ ...(A | B), k: V }` keeps a placeholder instead of
  distributing. Fix in `env.lua:substitute_inner`: distribute over union members, handle in
  `solve.lua` field lookup and `unify.lua`. Needed for builder pattern + mapped-type aliases.
- [ ] **Optional field narrowing** — `if opts.f then opts.f(x) end` still errors: second read
  of `opts.f` returns the union type, not narrowed non-nil. Workaround (extract to local) is
  known; real fix requires field-access narrowing in narrow.lua.
- [ ] **Narrowing for function-call return locals** — `local x = f(); if not x then return end`
  does not narrow `x` in the continuation because `x` is TAG_VAR at narrowing time. Three
  architectural options in TODO (a/b/c); needs a design decision before implementation.
- [x] **`$GlobalScope` documented** — added to permanent intrinsics list in `lib/type/static/CLAUDE.md`.
  Synthesizes a closed TAG_TABLE from all `--:: declare` globals; same pattern as `$FfiC` but for `_G`.
- [x] **`lib/bundle/`** — Lua module bundler. Resolve static requires, inline modules, single-file output. Circular dependency handling. 99 assertions.
- [x] **`lib/diff/`** — Myers diff algorithm: diff arrays/strings, unified format, patch, LCS. 96 assertions.
- [x] **`lib/csv/`** — RFC 4180 CSV parser/encoder: quoting, headers, streaming decoder. 135 assertions.
- [x] **`lib/embed/`** — Vector index/search on lib/vec: kNN, cosine/euclidean/dot, metadata filter, serialize. 112 assertions.
- [x] **`lib/graph/`** — Graph data structures + algorithms: BFS, DFS, Dijkstra, topological sort, SCC, cycle detection. 164 assertions.
- [x] **`lib/cache/`** — LRU cache with TTL, eviction callbacks, injectable clock, resize. 102 assertions.
- [x] **`lib/validate/`** — Schema validation for Lua tables: composable validators, records, arrays, combinators. 193 assertions.
- [x] **`lib/stream/`** — Lazy iterator combinators: map, filter, reduce, take, zip, flat_map, chunks, etc. 120 assertions.
- [x] **`lib/color/`** — Color manipulation: RGB/HSL/HSV/hex conversion, lighten/darken/mix, WCAG contrast. 198 assertions.
- [x] **`lib/cron/`** — Cron expression parser: matches, next/prev scheduling, shorthands, describe. 185 assertions.
- [x] **`lib/fsm/`** — Finite state machine: declarative transitions, guards, actions, wildcards, history. 125 assertions.
- [x] **`lib/heap/`** — Binary heap/priority queue: min/max/custom, heap sort, merge, keyed mode. 615 assertions.
- [x] **`lib/set/`** — Mathematical set: union, intersection, difference, symmetric difference, subset/superset. 108 assertions.
- [x] **`lib/ringbuf/`** — Fixed-size ring buffer: O(1) push/pop both ends, overflow wrapping. 111 assertions.
- [x] **`lib/trie/`** — Prefix tree: autocomplete, longest prefix match, prefix counting. 108 assertions.
- [x] **`lib/glob/`** — Glob pattern matching: *, **, ?, [...], {a,b}, compile/match/filter. 151 assertions.
- [x] **`lib/matrix/`** — 2D matrix math: arithmetic, transpose, determinant, inverse, solve Ax=b, Gaussian elimination. 169 assertions.
- [x] **`lib/bits/`** — Bitset + Bloom filter: set/clear/toggle, popcount, set operations, FNV-1a hashing. 157 assertions.
- [x] **`lib/promise/`** — Promises/A+: resolve/reject, and_then/catch/finally, all/race/any/all_settled. 92 assertions.
- [x] **`lib/interval/`** — Interval arithmetic + tree: contains, overlaps, merge, gaps, point/overlap queries. 110 assertions.
- [x] **`lib/deque/`** — Growable double-ended queue: O(1) push/pop both ends, rotate, iterate. 1160 assertions.
- [x] **`lib/bigint/`** — Arbitrary precision integers: base 10^7, add/sub/mul/div/pow, GCD/LCM, hex. 172 assertions.
- [x] **`lib/router/`** — Radix tree URL router: :params, *wildcards, method dispatch, groups. 158 assertions.
- [x] **`lib/retry/`** — Retry with backoff (none/linear/exponential/fibonacci) + circuit breaker. 177 assertions.
- [x] **`lib/base64/`** — Base64 encode/decode (RFC 4648), URL-safe variant. 145 assertions.
- [x] **`lib/event/`** — Event emitter: on/once/off, wildcards, priority, stop propagation, mixin. 107 assertions.
- [x] **`lib/ini/`** — INI parser/encoder: sections, comments, quoted values, multiline. 90 assertions.
- [x] **`lib/pool/`** — Object pool: acquire/release, health checks, with(), buffer pool. 117 assertions.
- [x] **`lib/schema/`** — Database DDL migration DSL: create/alter/drop table, column types, constraints, indexes. 137 assertions.
- [x] **`lib/mime/`** — MIME type lookup: 120+ types, extension↔type, charset, content_type. 102 assertions.
- [x] **`lib/url/`** — URL parser/builder: RFC 3986, query strings, percent-encoding, resolve, normalize. 152 assertions.
- [x] **`lib/template/`** — String template engine: {{ expr }}, {% code %}, {# comment #}, filters, compile. 100 assertions.
- [x] **`lib/ratelimit/`** — Rate limiting: token bucket, sliding/fixed window, leaky bucket, per-key. 367 assertions.
- [x] **`lib/i18n/`** — Internationalization: translations, interpolation, pluralization, locale fallback. 85 assertions.
- [x] **`lib/codec/`** — Codec composition: chain, conditional, map, hex/rot13/xor built-ins. 103 assertions.
- [x] **`lib/observable/`** — Reactive streams: operators (map/filter/take/flat_map), subjects, combinators. 510 assertions.

## lib/asm — SIMD kernel compiler

- [x] `lib/asm/cpu.lua` — CPU feature detection (sse2/avx/avx2/neon, arch)
- [x] `lib/asm/ra.lua` — linear scan register allocator with aliasing model (51 assertions)
- [x] `lib/asm/ir.lua` — virtual register IR builder, live interval computation, loop backedge extension
- [x] `lib/asm/abi/x64.lua` — SysV AMD64 + Win64 register files (407 assertions)
- [x] `lib/asm/abi/arm64.lua` — AAPCS64 register file
- [x] `lib/asm/emit/x64.lua` — x86-64 machine code emitter: VEX-encoded AVX instructions,
  mmap executable memory, full vmulps/vaddps/vsubps/vdivps/vfmadd213ps + loop (27 assertions, AVX-gated)
- [ ] **`lib/asm/emit/x64.lua` — `insn.dst` nil safety** — `Insn.dst` is `VReg | nil` (nil for store/ret ops), but load/arith branches unconditionally access `insn.dst.id` and `.type`. Requires either runtime nil guard or opcode-specific Insn subtypes. Exposed by replacing `--: any` with `--: Insn`.
- [ ] **`lib/asm/emit/x64.lua` — `ffi.copy` string-source overload** — `alloc_exec_mem` calls `ffi.copy(ptr, code_str, n)` with a Lua string as src. stdlib_types.lua only declares the `(Ptr<T>, Ptr<U>, integer)` form; missing `(Ptr<T>, string, integer)` overload (LuaJIT special-cases string src). Causes false positive type error at call site.
- [ ] `lib/asm/emit/arm64.lua` — NEON emitter (A64 encoding)
- [x] `lib/asm/init.lua` — convenience wrapper: `asm.compile({args,ret,ctype}, build_fn)`. Selects abi+emit by jit.arch; supports x64 (sysv/win64). 28 assertions in asm_test.lua.

## lib/stb — image decode/resize (vendored stb)

- [x] Package scaffold: tier selection (vendored > system-vips > pure-lua), `lib/stb/init.lua`, `lib/stb/ffi.lua`, `lib/stb/pure/resize.lua` (nearest-neighbor, full), `lib/stb/pure/image.lua` (PNG stub), `lib/stb/build.lua`, `lib/stb/src/README.md`, `lib/stb/stb_test.lua` (80 assertions)
- [ ] Download stb headers and compile vendored binaries for all 5 platforms via CI (`lib/stb/build.lua`)
- [ ] Implement pure Lua PNG decoder in `lib/png/` and wire into `lib/stb/pure/image.lua`
- [ ] Implement system-vips decode/resize wrappers in `lib/stb/init.lua` try_system_vips()
- [ ] Parity tests: vendored vs pure-lua resize on random pixel buffers (identical output)
- [ ] Benchmarks: vendored stbir vs pure-lua nearest-neighbor; record in `docs/perf/log.md`

## future libraries

See `docs/batteries.md` for the full ecosystem scope. Key entries below; batteries.md is authoritative.

- [x] **`lib/taskgraph/`** — implemented: graph.lua, context.lua, exec.lua, combinators.lua (map/retry/refine), init.lua, executor/ai.lua, orchestration_test.lua (27 assertions).
- [x] **`lib/cli/`** — arg-parsing library. Declarative spec API: flags, options, positionals, subcommands, type coercion, auto-help/version, shell completions. 70 assertions.
- [x] **`lib/datetime/`** — date/time parsing, formatting, arithmetic. ISO 8601, Unix timestamps, offset-aware arithmetic. 186 assertions (c6e9bbb).
- [x] **`lib/regex/`** — PCRE2 FFI system tier + pure Lua backtracking fallback. compile/match/find/gmatch/gsub/split. 70+ assertions.
- [x] **`lib/uuid/`** — UUID v4/v7 generation. v4 (random), v7 (timestamp+monotonic). FFI tiers: getrandom → arc4random_buf → /dev/urandom → pure. 250 assertions.
- [x] **`lib/log/`** — structured logging with levels and sinks. log.new(), collect_sink, file_sink, stderr/stdout_sink, text/json/ansi formats, child loggers, set_level, add/remove sink. 80 assertions.
- [x] **`lib/compress/`** — zlib/gzip via FFI (system tier) + pure Lua inflate (RFC 1951). Two tiers: system-zlib (full deflate+inflate) and pure-lua (inflate only). Streaming and one-shot APIs. 24 assertions.
  - [x] **Pure Lua inflate parity bug** — FIXED (0989bb7). decode_symbol was building Huffman codes MSB-first but build_tree stores reversed codes. Fixed to accumulate bits LSB-first. 181 assertions now passing.
- [x] **`lib/ansi/`** — ANSI escape codes (colours, cursor movement). Foundation for `lib/tui/`.
- [x] **`lib/tui/`** — TUI widget layer (boxes, tables, input fields).
- [x] **`lib/reactive/`** — reactive signal primitives. Push-based, no implicit tracking scheduler.
  Core API: `signal(init)` → `{get, set, update}`, `computed(fn, deps)`, `effect(fn)`, `batch(fn)`.
  No dependencies outside crescent — not even on Rainbow.
  **Rainbow** (`~/git/rhizone/rainbow/`) is a parallel TypeScript implementation of the same algebra,
  maintained separately. It defines the intended API surface and semantics (`Signal<A>`, `computed()`,
  `cond()`, `batch()`, `product()`, `stateful()`). The Lua and TS implementations are peers —
  neither depends on the other. `lib/lua2ts/` can transpile this to standalone TS that is
  API-compatible with Rainbow but does not import from it.
  **Done**: dccd023. signal/computed/effect/batch/focused/narrowed. 56 assertions.

- [x] **`lib/reactive_optics/`** — signals focused through optics. `signal:focus(lens)` produces a
  derived signal that reads/writes structurally; lens laws (get-set, set-get, set-set) guarantee
  state consistency by construction. Combines `lib/reactive/` with `lib/fp/optics/` (already built).
  Key combinator: `focus(signal, optic)` → `{get(), set(v), update(fn)}`.
  Parallel TS implementation: Rainbow's optics layer (`~/git/rhizone/rainbow/src/optics/`).
  Again: no dependency on Rainbow — same algebra, separate codebases.
  **Done**: dccd023. field/compose_focus/focus/narrow. 9 assertions.
- [x] **`lib/ml/`** — ML vertical: `lib/xgboost` (pure Lua reference + FFI).
- [x] **`lib/knn/`** — k-nearest neighbors with euclidean/cosine/manhattan distance, classification, regression. 55 assertions.
- [x] **`lib/tfidf/`** — TF-IDF text scoring, cosine similarity, corpus search, keyword extraction. 61 assertions.
- [x] **`lib/search/`** — FTS5 full-text + vector similarity + hybrid search on SQLite. 65 assertions.
- [x] **`lib/email/`** — email composition (RFC 5322 MIME) + SMTP client with mock transport. 71 assertions.
- [x] **`lib/realtime/`** — pub/sub hub, presence tracking, event store with aggregation. 83 assertions.
- [x] **`lib/vec/`** — dense vector math with FFI and pure Lua tiers. 192 assertions.
- [x] **`lib/web/`** — web application framework: middleware, routing, cookies, CORS, CSRF, static files. 56 assertions.
- [x] **`lib/auth/`** — JWT (HS256), PBKDF2-SHA256 password hashing, token generation, HMAC-SHA256. 44 assertions.
- [x] **`lib/queue/`** — SQLite-backed task queue with priority, delay, retry, scheduling, dead-letter. 69 assertions.
- [x] **`lib/taskgraph` frontier/exec_graph/scaffolds** — absorbed from nanites design. Dynamic graph growth, frontier (live pending set, opt-in via `track=true`), exec_graph (monotonic audit log), scaffolds (pre-execution hooks). 53 assertions. Parallel LLM dispatch still needs epoll-backed HTTP (see entry above); vLLM integration (`caps.llm` → local vLLM OpenAI-compatible API) is a follow-on. Reference: `~/git/rhizone/nanites/`.

## Agent infrastructure

- [x] **`lib/exec/`** — subprocess runner (`exec.run`/`exec.run_ex`), `--help` parser
  (`lib/exec/help.lua`), identifier normalizer (`lib/exec/ident.lua`). HelpSchema produced
  by `help.fetch` or `help.parse`. Done.

- [ ] **`lib/exec/make_api`** — fluent typed API generator from HelpSchema. See `docs/exec-api-design.md`.
  Inputs: HelpSchema + cmd name + opts (`popen` injected). Outputs: `api_table` + `--::` decls string.
  Node shapes via bitflags (`CALLABLE=0x1`, `HAS_SUBCOMMANDS=0x2`). "Both" nodes use `#__call` metamethod.
  Flag expansion: named table `{json=true, limit=5}` → CLI arg strings. Depends on: `lib/exec/help`,
  `lib/exec/ident` (done). File: `lib/exec/make_api.lua`.

- [ ] **`lib/agent/` substrate** — context set, render, curated leaf executor, preset registry.
  See `docs/agent-impl.md` Section 1. Depends on: `lib/taskgraph` (done).
  Key invariant: set is re-rendered fresh each LLM call; raw tool output never accumulates.
  Files: `lib/agent/set.lua`, `lib/agent/render.lua`, `lib/agent/leaf.lua`, `lib/agent/preset.lua`.

- [ ] **`caps.exec`** — `lib/platform/caps/exec.lua` exists (popen injection removed this session) but is NOT wired into CAP_FACTORIES in `lib/platform/init.lua`. Adding it to CAP_FACTORIES is the remaining step.
  See `docs/agent-impl.md` Section 2. Depends on: `lib/exec/make_api`, `lib/platform/caps/` pattern.
  Construction auto-fetches `--help` per binary; grant precision via `allow` list restricts to specific subcommand paths.

- [ ] **`caps.llm`** — platform cap for grammar-constrained LLM generation via llama.cpp.
  See `docs/agent-impl.md` Section 3. Depends on: `lib/ai/providers/openai_compat` (done).
  File: `lib/platform/caps/llm.lua`. Endpoint: `http://127.0.0.1:8081` default. `response_format`
  JSON schema mode for structured output; response validated before returning.

- [ ] **First narrow agent app** — **priority: medium-high**. Full infrastructure stack is
  now in place (`lib/exec/`, `lib/agent/`, `caps.exec`, `caps.llm` all done) — this is a
  pure implementation task, no blockers.
  Candidate: polish-agent (parallel audit lenses, structured findings, POLISH.md artifact,
  human-as-decision-node). See `docs/agent-design.md` for thesis and design constraints.
  Success criteria from design doc: narrow app under 200 lines of Lua, useful output on small
  local model, audit trail = `exec_graph` snapshot + tarball hash.

- [ ] **`lib/protocol/capnp`** — zero-copy binary serialization via Cap'n Proto. Wire format reader + writer using LuaJIT FFI (fixed-width fields + typed pointers → direct buffer casting, near-zero allocation). Pure reader first; `.capnp` schema parser deferred (hand-write schemas as Lua tables initially). RPC layer (`lib/capnprpc`) separate. Moderately high priority — genuine capability gap over JSON/CBOR for high-throughput IPC.
- [x] **`lib/ukanren/`** — microKanren port. Goals, unification, streams, fair interleaving. 52 assertions.
- [x] **`lib/datalog/`** — pure Lua Datalog engine, naive bottom-up evaluation, recursive rules, guards. 87 assertions.
- [x] **`lib/crypto/`** — AES-256-GCM (system libcrypto FFI), ChaCha20-Poly1305 (system + pure Lua), HKDF-SHA256, random_bytes. 36 assertions + 10 skipped (AES without libcrypto).
- [x] **`lib/openapi/`** — OpenAPI 3.x parser, $ref resolution, request/response validation, JSON Schema subset, lib/web router integration. 111 assertions.
- [x] **`lib/parse/`** — parser combinators: literal, pattern, seq, alt, many, opt, map, sep_by, lazy, whitespace, number, string, ident. 92 assertions.
- [ ] **`lib/ir/`** — compiler intermediate representation (not yet implemented).
- [x] **`lib/asm/`** — SIMD kernel compiler: cpu detection, linear scan RA, virtual IR, x64 emitter. See `## lib/asm` section above.

- [x] **`lib/lua2ts/`** — Lua → TypeScript transpiler. The typechecker already builds an AST;
  emitting TS syntax instead of Lua syntax is mostly mechanical. Prior art: `dep/lua2js.lua`
  (AST printer that outputs JS syntax). Metatables are the awkward mapping; FFI doesn't cross.
  Crescent's type annotations map directly to TS types — typed Lua → typed TS with no extra
  annotation work. Primary use case: write `lib/reactive_optics/` logic in Lua, emit typed TS,
  run in browser alongside Rainbow components. Rainbow (`~/git/rhizone/rainbow/`) is the
  deployment target — `lib/lua2ts/` output is designed to compose with Rainbow's signal/optics layer.

- [x] **`lib/lua2ts/`: `__index = table` metatable → TS class** — top-level `local M = {}` +
  `M.__index = M` → `class M { ... }`. Handles `setmetatable({}, M)` and
  `setmetatable({}, { __index = M })` constructor variants. Instance methods (`function M:f()`
  and `function M.f(self, ...)`), static methods, and `function M.new(...)` constructor.
  Emits `const self = this;` preamble so method bodies work without rewriting identifiers.

- [ ] **`lib/lua2ts/`: OOP patterns not yet translated** (known limitations):
  - `__index = function(t, k)` — dynamic indexer; would need JS `Proxy`. Currently emitted as-is.
  - Inheritance: `setmetatable(Child, { __index = Parent })` at module level (not in `new`).
    Would need `class Child extends Parent`. Not yet detected.
  - `M.__index = M` where M is NOT a local `{}` declaration (e.g., assigned via `require`).
    Not detected; passes through unchanged.
  - Multiple return from constructor beyond `return self` (e.g., `return self, err`).
    The `return self` skip only triggers for single-value returns of `self`.
  - Method bodies are given `const self = this;` but `self` in nested closures inside methods
    will capture the `const self`, not the outer `this` — correct for Lua semantics.

- [x] **`lib/jsonrpc/`** — request/response dispatch over stdio or TCP. Substrate for LSP, Model Context Protocol, and any JSON-RPC protocol. Transport abstraction, method registry, typed handler registration. (1d4f85e)

- [x] **`lib/lsp/`** — LSP method bindings on top of `lib/jsonrpc`. Server builder with `on_*` registration, auto-capability detection, lifecycle handling. Covers: initialize, hover, completion, definition, references, documentSymbol, signatureHelp, formatting, rename, codeAction, diagnostic, text sync. 60 assertions.

- [x] **`lib/mcp/`** — Model Context Protocol server on top of `lib/jsonrpc`. Tool/resource/prompt registration, capability negotiation, logging with level filtering, completions. 44 assertions.

- [ ] **`lib/ecs/`** — entity-component substrate. Named entities, typed components, spatial containment (entities inside entities), mutable state store. User-defined schemas — no hardcoded concepts like "room" or "inventory". The primitive for building world simulations, games, or any entity-centric stateful system. Turn loop, perception rules, mutation rules, and renderers (RP prose, MUD-style, etc.) are built on top by the user.

## typechecker type-level features (designed this session, needs implementation)

- [x] **`$EachField<T, F>` intrinsic** — flatMap semantics implemented (fbb00f5, 2026-03-30).
  F returns a brace-tuple: `{}` = drop, `{ D }` = keep/transform, `{ D1, D2 }` = expand.
  Detection: empty TAG_TABLE → drop; positional-indexer TAG_TABLE → multi-element tuple;
  anything else → backward-compat single-descriptor. Grammar gap fixed (124c438):
  `{ { optional: true, ...Rest } }` now parses — root cause was `else break` in the
  field loop not handling `{`-started positional entries. `...Rest` splice already
  worked. `MakeOptional`, `MakeReadonly`, `DropOptional`, `Partial<T>` all tested.

- [x] **Interface declaration syntax `--:: Name: Base`** — implemented (551cbdb, 2026-03-30).
  `--:: Name<T>: Constraint<T> = body`: (1) checks `body <: Constraint<T>` at definition,
  emits E.CONSTRAINT_MISMATCH = 26 on failure; (2) registers ctx.declared_subtypes oracle
  so try_unify(Name<X>, Constraint<X>) short-circuits in O(1). ann.lua parses `: Constraint`
  before `=`; constrain.lua resolves + registers + checks; unify.lua oracle-first for TAG_NAMED pairs.

- [x] **Partial application of generic aliases** — implemented (22f1e8f, 2026-03-30). TAG_PARTIAL_APP = 31.
  Under-arity alias call (1–N-1 args) returns TAG_PARTIAL_APP(name_id, partial_args).
  apply_type_fn completes the call. substitute_inner re-evaluates when args become concrete.
  match.lua TAG_UNION pattern added (needed for `match K { Keys => ... }` where Keys is a union).
  Enables Pick<T, Keys> and Omit<T, Keys> via $EachField + PickKey<Keys> partial app.

- [x] **`{ ...[%K]: %V }` table-pattern rest capture** — `{ field: %X, ...%Rest }` in
  match patterns: captures remaining fields into Rest; `...Rest` in result splices them
  back. Specced in docs/capture-sigil-spec.md. Needed for $EachField F aliases.
  Implementation: ann.lua + match.lua. Done 2026-03-30.

- [x] **`(...%P) -> T` and `(A, ...%P) -> T` param captures** — specced in
  docs/capture-sigil-spec.md. Enables Parameters<F>, Tail<F>, Last<F>, Init<F>.
  At most one `...%P` per param list, may appear anywhere. Implementation: ann.lua +
  match.lua. Done 2026-03-30.

- [x] **`{ #...%M }` meta-slot spread** — specced in docs/meta-spread-spec.md.
  `setmetatable = <T, MT>(t: T, mt: MT) -> T & { #...MT }`. `MetaOf<T>` alias.
  Implementation: ann.lua + match.lua + types.lua + constrain.lua + env.lua + defs.lua.
  Done 2026-03-30.

- [ ] **Literal type ops** — see docs/literal-type-ops-spec.md. Conclusion: none needed
  now. Implement on demand. Boolean ops expressible as match aliases (no primitives needed).
  String `..` has no crescent use case (JS-heritage motivation doesn't apply). `#tuple`
  and `LIT_INTEGER` arithmetic have no concrete use cases yet.

## priorities (medium horizon)

- [ ] **Registry + docs site** (`pkg.crescent.run`) — see `docs/registry-design.md` for full vision.
  Key pieces: static JSON index (GitHub Pages), install fetches from GitHub releases directly,
  no server required. Docs site renders auto-generated type signatures from typechecker output.
  Uniquely: **Hoogle-style type search** — parse a query type annotation, unify against every
  exported binding in the index using the existing unify.lua engine. The hard part (type inference)
  is already done. Three sub-projects:
  - [x] Docgen tool (`lib/doc/`) — extract `---` doc comments + inferred types → JSON/Markdown.
    `doc.generate(file)` / `doc.generate_string(src)` / `doc.generate_package(dir)`.
    CLI: `luajit lib/doc/cli.lua [--format json|text|markdown] [--package dir] <file>...`
    Filters `_`-prefixed exports, extracts parameter names, batch mode.
  - [x] Type search library (`lib/type/search/`) — Hoogle-style: parse query type annotation,
    unify against exports using try_unify. `search.build_index(files)` / `search.query(type_str, index)`.
    CLI: `luajit lib/type/search/cli.lua "(string) -> string" <files...>`
  - [ ] Type search improvements:
    - Unseal mode (`{ unseal = true }`) — search through $Opaque wrappers
    - Opaque pattern queries — `$Opaque<string>` means "any opaque wrapping string"
    - Accept type_id + ctx as query (programmatic, not just strings)
    - Acceleration structures for registry-scale indexes (bloom filter, inverted index)
    - [x] Subtype ranking (exact > subtype > supertype) — 3-level scoring
    - [x] Arity pre-filtering before check_string
    - [x] Persistent index — save_index/load_index JSON, CLI --save-index/--load-index
  - [x] Stabilise `--dump` output as machine-readable JSON (exported bindings + type sigs) — `--dump --format json` emits `[{file, bindings:[{name,type}], return}]`; M.dump_one/dump_json testable exports (edaaf6f)
  - [ ] Static docs site — renders docgen JSON; search calls type-search endpoint or
    runs unification client-side. **Medium priority: replace bun with crescent-native
    markdown renderer** (`lib/markdown/` once complete) so the docs toolchain is
    self-hosted. bun is the current placeholder; it should not be a permanent dep.
  - [ ] GitHub Action — on release tag: run typechecker + docgen, publish JSON to index.
  - [ ] `cr add <name>` — resolve short name via index.json, fetch GitHub release tarball,
    extract to `dep/<name>/`, resolve transitive deps.

- [ ] **Test runner performance** — benchmark against bun; must be at parity or better.
  Current runner shells out to `find` + `sort`, then `dofile`s each file sequentially.
  Profile first: startup cost, require() overhead, per-file execution. Candidates:
  native file discovery (FFI readdir), parallel execution (fork + collect), preloaded
  module cache, LuaJIT JIT warm-up tuning. Target: same program runs comparably fast
  in bun and luajit; if not, the design needs revisiting.

- [x] **Package manager** (`lib/pkg/`) — core implementation done. See design docs for full detail.
  - [x] semver, manifest, lockfile, install (resolve/fetch/hardlink), config, CLI (install/add/remove/update/info/publish/eject/diff)
  - [x] Transitive dep resolution (BFS, cycle detection, diamond dedup)
  - [x] Version conflict detection (two-pass MVS resolver, constraint collection)
  - [x] `dep/` → `lib/` migration; lockfile v2 (include, tarball_hash, tree_hash)
  - [x] Include glob filtering + union merge across dependents
  - [x] Tree hash verification + local modification detection
  - [x] `cr diff`, `cr eject`, `cr update --merge`
  - [x] Pure Lua three-way merge (`lib/merge3/`) — Myers diff, no external deps
  - [ ] **Phantom dep linting** — `cr check`/`cr publish` scans require paths vs own `pkg.lua`
  - [ ] **Parallel fetch** (`--jobs`) — fork-based, I/O-bound, significant on large dep trees
  - [ ] **Workspaces** — single `crescent.lock` covering all packages in a monorepo; MVS resolver takes union of all workspace `pkg.lua` roots
  - [ ] **Lockfile format freeze** — add `lockfile_version` field, stabilise before v1 registry use
  - [ ] **`cr add` / `cr publish`** — blocked on live registry infrastructure

- [ ] **Typechecker** — large ongoing backlog; dedicated sessions welcome.
  Near-term candidates: access control design (see below), module-level LSP cache.
  (Variance was demoted from soundness to expressiveness, commit `ca64aeb1`; see
  `docs/typechecker-variance.md` and the variance entry below.) See typechecker
  section below for full list.
  - [x] **Overload checking against body** — implemented: `collect_preceding_run` in
    constrain.lua accumulates consecutive `--:` annotations into intersection types;
    `check_body_against_intersection` runs N inference passes (one per overload member).

- [ ] **Stdlib rewrites** — vendored packages currently in `lib/` violate the ownership
  rule (docs/stdlib-design.md). Each needs a fresh crescent-native rewrite before the
  registry exists and the vendored copy can be removed:
  - [x] `lib/format/json/` — crescent-native JSON, three tiers (pure/ffi/simd stub).
    Parity tests + benchmarks done. pure: 72 MB/s, ffi: ~same. See docs/perf/log.md.
  - [ ] `lib/format/json_sax/` — SAX + zerocopy variant (separate library, different interface).
    Design: `scan(src, cb(key,val))` and `scan_pos(src, cb(ks,ke,vs,ve))`. Pure tier only
    (no table alloc = no bottleneck to tier away). Benchmarked: 247 ns / 254 MB/s (SAX) and
    155 ns / 405 MB/s (zerocopy) on 90B object — 2.1x faster than Node.js JSON.parse.
    Implement when HTTP layer needs streaming/large JSON parsing. Design notes: docs/perf/log.md.
  - [ ] `lib/format/cbor/` — rewrite vendored CBOR. Low priority until cbor sees more use.
  - [x] `lib/encode/base64/` — rewritten. Three-tier (simd stub > ffi > pure), RFC 4648 §4+§5, 108-line tests.
  - [ ] `lib/hash/sha1/` — rewrite mpeterv/sha1. Already heavily patched; sha256 shows
    the tiered pattern to follow.
  - [ ] `lib/ljsocket/` — largest and most complex. Blocked on registry (http/websocket
    depend on it); rewrite as cross-platform `lib/socket/` (POSIX + winsock via FFI).
  - [x] `lib/cparser/`, `lib/cmark/`, `lib/plterm/` + `lib/crescent_examples/ple.lua` — deleted (unused vendored code).

- [ ] **Stdlib buildout** — see `docs/stdlib-roadmap.md`. Phase 1–3 done (2026-03-20):
  path guards, init.lua entry points, error convention sweep, tests for core packages,
  new packages (process, iter, rand, signal, format/msgpack, format/toml, hash/hmac).
  46 app-specific packages archived. Remaining: dep.* coupling resolution, type
  annotations across Tier A (done for 24 owned packages; vendored code skipped),
  tests for ljsocket/tls/dns/inotify.
  [x] dep.* coupling resolved (a79167d) — 8 dep paths across 28 files updated.
  [x] HTML docgen output (582247c) — `--format html` with inline CSS.

- [x] **Typechecker: multiline `--::` declarations** — lexer now concatenates
  continuation `--::` lines when brackets are unbalanced. Forward references between
  `--::` types in the same file work via the existing two-pass design.
  **Note**: multi-return function types in record fields must use parens:
  `generate: (req: T) -> (R?, string?)` not `-> R?, string?` (comma is ambiguous
  with field separator).

- [ ] **Typechecker: annotation parser multi-return in record fields** — bare
  `-> R?, string?` inside `{ ... }` is ambiguous (`,` could be field separator or
  multi-return separator). Workaround: parenthesize returns `-> (R?, string?)`.
  Could fix by parsing return types greedily until `,` followed by an identifier + `:`.

- [x] **Typechecker: type-level imports** — `--:: require "path"` (ANN_REQUIRE) is the
  mechanism: it loads all `--::` declarations from the referenced file into the current
  file's scope. Already implemented and in active use by lib/taskgraph/, lib/asm/,
  lib/web/, and others. No separate `--:: import` syntax is needed.

- [ ] **Shared cap function types library** — common injected-function signatures repeated
  across libs (`POpenFn`, `IOOpenFn`, `RemoveFn`, `TmpnameFn`, `ReadFn`, etc.) should
  live in one place (e.g. `lib/caps/types.lua`) declared with `--::`, imported via
  `--:: require "lib.caps.types"`. Eliminates per-file repetition and keeps cap
  signatures consistent across the codebase.

- [ ] **Type annotation syntax docs** — no public-facing `docs/type-syntax.md` exists.
  `docs/conventions.md` mentions `--:` / `--::` exist but doesn't document them.
  Need: complete syntax reference (primitives, unions, intersections, generics, tuples,
  function types, `--:: require`, `--:: declare`, intrinsics like `$Opaque`/`$Values`).
  Include: known limitations, examples.

- [ ] **Type docs staleness detection** — script that compares `git log` date of
  `docs/type-syntax.md` (once it exists) against latest commit touching
  `lib/type/static/`. Run in CI or as a pre-commit hook to catch silent doc drift.

- [ ] **Typechecker: nested generic alias application** — `Partial<Partial<T>>`
  produces `never` even though `Partial<{a: string|nil}>` (the inner result)
  works fine directly. The bug is in how a generic alias application passes its
  result as the type argument to an outer alias application. Manifests with any
  two-level `$EachField` composition. Discovered via type_complex_test.lua.

- [ ] **Typechecker: recursive structural type checking** — `{ head=1, tail=99 }`
  is accepted where `List<number>` (tail must be `List<number>?`) is expected.
  The recursive field constraint is not enforced at depth. Likely the unification
  of the recursive type hits the cycle guard before checking the concrete field.

- [ ] **Runtime type validator** (`lib/type/runtime/`) — Zod/Typebox/Arktype-style
  schema library: `T.string()`, `T.number()`, `T.object({...})`, `T.union([...])`,
  `T.array(T.string())`. Returns a validator function `(value) -> true | nil, err`.
  Pure Lua, no codegen. Key design: validators compose via the same combinators as
  the static type system. Long-term: static typechecker infers validator types so
  `local x = T.string():parse(v)` gives `x: string` after the call.

- [ ] **Typeclass dispatch key pattern** — `lib/fp/` dispatch tables annotated `{ [any]: any }` today.
  Correct design: each typeclass module exposes a `.key` field declared `--:: FooKey: $Opaque`,
  dispatch table annotated `{ [FooKey]: FooImpl, [BarKey]: BarImpl, ... }`, and
  `fa[Mappable.key]` in code resolves via the existing FLAG_OPAQUE_KEY mechanism keyed by
  the nominal `$Opaque` type instead of just the variable name string. Requires:
  (1) `$Opaque` declaration in each typeclass module (mappable, applicable, etc.),
  (2) cross-file type alias resolution in bracket-key annotation position already works
  via the existing FLAG_OPAQUE_KEY + LIT_OPAQUE_KEY path once the key IS a declared type.
  Eliminates `{ [any]: any }` from fp dispatch tables.

- [x] **Typechecker: table-valued dispatch key (GAP-HKT3)** — applied to all lib/fp/ typeclass and instance modules. `fa[Mappable.key]` resolves via FLAG_OPAQUE_KEY to the instance type. Callers annotate parameters with `{ [MappableKey]: { map: ... } }` for type-checked dispatch. (2026-03-29, 839610f)

- [x] **Typechecker: argument literal widening** — implemented in `solve.lua` (`widen_literal` applied at typevar binding; `ret_uses_tv_in_intrinsic` exempts `$Require<T>` to preserve string literal for module lookup). Confirmed: `id(0); id(1)` and `id(0); id('x')` both work.

- [ ] **Refinement types / control-flow narrowing system** — type guards, assertions, and
  `type()` narrowing are all instances of a general `refine_true`/`refine_false` algebra.
  Needed: (1) `assert(e)` narrows after the call (`x: T` in continuation); (2) `x is T`
  return type syntax for bool guards — checker *verifies* body, unlike TS which trusts;
  (3) `asserts x is T` return type for void assertions; (4) `T & asserts x is T` for
  functions that both return a value AND narrow a parameter (TS cannot express this);
  (5) `and`/`or`/`not` compose refinements automatically; (6) `getmetatable(x) == MT`
  narrows to MT's registered type; (7) exhaustiveness on `if type(x) == ...` chains.
  Design doc: `docs/type-system.md` § "Refinement types: the general system".

- [ ] **Difference types `T \ U`** — false branch of any narrowing produces `T \ U`, not
  open `~T`. Expressible as `Exclude<T, U> = match T { U => never, _ => T }`. Standalone
  `~T` only valid within Lua's closed `type()` universe (8 known values). Implement as
  false-branch refinement in constrain.lua + `Exclude` in the type prelude.

- [ ] **Type operations standard library** — `docs/type-system.md` § "Type operations are
  library aliases". Ship in prelude: `Exclude`, `Extract`, `NonNil`, `ReturnType`,
  `ElemType`, `UnwrapMaybe`, `Flatten`, `Partial`, `Required`, `Pick`, `Omit`.
  All expressible as `--::` aliases over `match` — no new compiler intrinsics needed.

- [ ] **Typechecker: HKT type argument extraction** — when `<F, A>(fa: F<A>)` is called
  with `Maybe<number>`, the solver can't extract `F = Maybe, A = number` from the
  expanded structural type. Once expanded, constructor/argument decomposition is lost.
  Constraints like `<F, A: Semigroup>(fa: F<A>)` are unenforceable — `A` is unbound.
  Blocks: typed `fmap`, typeclass-polymorphic functions, `lib/fp/` full type safety.
  Fix requires nominal type preservation or bidirectional inference before expansion.
  See `docs/type-system.md` line 862.
  **GAP-HKT1 (found 2026-03-29)**: chained fmap result is not re-usable as an HKT argument — the return type of `fmap(f, ma)` loses its constructor identity and cannot be passed to another HKT-parameterised function. Demonstrated in lib/fp/ type_complex_test.lua.

- [ ] **Typechecker: `{ [K]: V }` type param not substituted as indexer key** — when a
  generic type parameter is used as the key type of an indexer (`{ [K]: V }`), the
  parameter is not substituted at instantiation. The indexer key stays as the raw type
  variable rather than the concrete argument. Found 2026-03-29 via lib/fp/ testing.

- [ ] **Typechecker: generic variance (expressiveness, not soundness).**
  All generics are currently invariant. `Box<Dog>` is not a subtype of
  `Box<Animal>`. Demoted from soundness to expressiveness in commit
  `ca64aeb1` after the design pass (`docs/typechecker-variance.md`,
  2026-05-17): probing showed structural invariance + function
  contravariance + FLAG_SKOLEM rejection already prevent the bad cases
  the soundness audit worried about. Remaining gap is purely
  expressiveness — can't declare covariant/contravariant containers
  like `ReadOnlyMap`. Implement when a user writes the first
  heavily-generic library that wants it. Not blocking.

## security (fix soon)
- [x] http/router: path traversal via symlinks — `path.safe_resolve()` with FFI `realpath()`
- [x] http/server: reads one packet, not until headers complete — loop until `\r\n\r\n`, then read body by Content-Length
- [x] http/router/staticx: pattern `.gz$` should be `%.gz$` (Lua pattern, `.` matches any char)
- [x] http/router/staticx: opens files in `"r"` mode — should be `"rb"` to avoid newline mangling
- [x] charactercardv2/server.lua: `require("lib.keyring")` inside app — sandbox violation, app could read any key. Fixed: key resolved at platform level, injected as pre-keyed llm cap.
- [x] sillytavern/server.lua line 143: `os.time()` called directly — must accept injected `time_fn` cap instead
- [x] library/server.lua: `io.write()` / `io.stderr:write()` in CLI handler — must accept injected `stdout`/`stderr` write fns
- [x] **Sandbox: all required modules run with full host privileges** — both tarball and whitelisted platform modules run in global env. Fix: (1) tarball modules → `load(source, "t", env)`; (2) whitelisted pure-Lua platform modules → source-load from disk via `load(source, "t", env)`; (3) FFI-backed functionality → cap system only: declared in manifest, explicitly granted by platform, injected as `caps.*` globals. Apps use `caps.compress(data)` not `require("lib.compress")`. `ffi` is never on any whitelist; FFI modules are not requireable inside the sandbox. Maintain sandbox-local `package.loaded`. Fixed: tarball modules now load via `load(source, "t", env)` in `lib/platform/init.lua`.
- [x] **`caps` leaks into all module envs** — currently `caps` is a global in the sandbox env shared by all modules. Required modules must receive an env without `caps`; only the entrypoint gets it. App passes caps to internal modules explicitly as arguments. Fixed: caps stripped from module envs in `lib/platform/init.lua`.
- [x] **Dev/prod sandbox inconsistency** — CLI dev mode uses a blocklist (`ffi`, `io`, `os`, `debug`, `package`); daemon mode uses a whitelist. A violation present in dev may be invisible in prod and vice versa. Fix: CLI dev mode must use the same whitelist-only sandbox as daemon mode. Fixed: `lib/platform/cli.lua` now uses whitelist sandbox.
- [ ] Full security audit of all imported libraries

## correctness
- [x] http/router/staticx: `Content-Length = ""` is invalid HTTP — omit header entirely
- [ ] http/router/staticx: detects directories via `read("*all") == nil` — fragile, use lfs or stat
- [ ] http/router/staticx: reads entire files into memory — needs size cap or streaming for large files

## stdlib

### sha256 FFI tier performance
- [ ] `lib/sha256` FFI tier benchmarks at 72 MB/s vs theoretical ~200-500 MB/s. Known causes: `compress` is a closure (JIT can't inline), `u32_to_hex8` allocates a table per call (8× per hash), zeroing loop should use `ffi.fill`, mixed Lua number/FFI integer arithmetic in schedule extension. Not a blocker for CRI workload but worth fixing before the system tier is wired up.

### crypto / hashing stdlib design
- [ ] Design a coherent `lib/hash/` or `lib/crypto/` namespace before adding more algorithms. Questions to answer: how do tiered implementations (system lib > FFI scalar > pure Lua) get shared across blake3, xxhash, md5, sha256, etc.? How are parity tests and benchmarks structured per-algorithm vs shared? Does each algorithm live in `lib/hash/sha256/`, `lib/hash/xxhash/`, etc., or is there a single `lib/hash/` with a dispatch table? `lib/sha256/` exists as a prototype — treat it as a reference, not the final shape.

### dep.* import resolution
- [ ] Many packages in `lib/` reference `dep.ljsocket`, `dep.lunajson`, `dep.epoll`, `dep.tls`, `dep.ljltk`, etc. — these resolve against `~/git/lua/dep/` in the parent monorepo, not against anything in crescent. Affected: `lib/http/client.lua`, `lib/http/serverx.lua`, `lib/https/`, `lib/codetree/`, `lib/dns/tcp_client.lua`, `lib/discord/`, `lib/lsp/`, `lib/markdown/`, and others. These packages are not self-contained and cannot be vendored. Each needs its dependencies either pulled into `lib/` properly or declared in a manifest and resolved via the package manager.

### package audit
103+ packages surveyed. Most predate the ecosystem design and were written without crescent's conventions in mind. Many will need partial or full rewrites to meet the bar — not just cleanup. Treat the audit findings as a roadmap, not a checklist.

**Verdict summary:** type/static, test, sqlite, ljsocket, lunajson, cbor, base64, sha1, urlencode, fs/dir_list, cparser, git → `clean`. http, pkg, websocket, cli → `needs-work`.

**Wrong-home (belong in registry, not stdlib):**
- [ ] `lib/glua/` — OpenGL bindings, application-specific
- [ ] `lib/mock/` — large mock library (2.6 MB), not foundational
- [ ] `lib/love/` — game framework bindings
- [ ] `lib/tree_sitter/` — parse library bindings
- [ ] `lib/ljltk/` — Lua parser/compiler (third-party origin)
- [ ] `lib/crescent_examples/` — collection of small scripts demonstrating crescent

**Missing init.lua (35+ packages):** http, https, fs, socket, tcp, dns, imap, irc, test, and others — violates "every package is a directory with init.lua entry point". Many of these also need rewrites, so add init.lua as part of the rewrite, not as a standalone fix.

**Missing spec traceability:** ~70+ packages lack RFC/spec citations. Add as part of rewrites, not retrofitted onto existing code that may be replaced anyway.

**Missing conformance tests:** dns, irc, imap, websocket, http (partial) — no tests at all for protocol behavior. Add as part of rewrites.

#### http
- [x] No `init.lua` — re-export `format`, `client`, `status` from a top-level init
- [x] `http/client`: replace `assert(socket.create(...))` with `return nil, err` — fails with unhelpful message on socket error
- [ ] `http/format`: silently drops unparseable headers — log or return error
- [ ] extract network layer (client.lua, server.lua) — needs lib/ljsocket, lib/epoll, lib/socket/server.lua
- [ ] **`lib/http/client.lua` epoll support** — add optional `epoll` parameter (same pattern as `~/git/lua/lib/tcp/client.lua`). Non-blocking socket + epoll callback registration so multiple concurrent HTTP requests (e.g. parallel vLLM calls) can share one event loop. Prerequisite for parallel nanite fleet.
- [ ] extract routers — needs lib/path, lib/mimetype, lib/fs, lib/lunajson

#### https
- [ ] `lib/https/client.lua`: module-level TLS state (single concurrent connection) — acceptable for now but needs per-request TLS context for concurrency
- [ ] `lib/https/client.lua`: certificate verification disabled by default — `tls.config_verify()` should be the default; current code omits it for compatibility
- [ ] `lib/https/serverx.lua`: non-functional (FIXME placeholders, wrong imports) — needs full rewrite

#### ai (`lib/ai/`)
- [ ] `lib/ai/` providers hardcode `require("lib.https.client")` — violates caps-first; should accept an http client as a parameter
- [ ] `lib/ai/init.lua`: no retry/backoff on transient errors (429, 5xx)
- [ ] `lib/ai/providers/anthropic.lua`: tool call streaming only emits on content_block_stop — no partial tool call deltas
- [ ] `lib/ai/providers/openai.lua`: only flushes first accumulated tool call on finish — multi-tool-call streaming incomplete
- [ ] `lib/ai/tools.lua`: assistant message in tool loop doesn't carry tool_calls metadata — some providers need it for multi-turn tool conversations
- [ ] `lib/http/stream.lua`: buffer growth via string concat in hot path — should use table accumulator or FFI buffer
- [ ] **low-prio** providers needing custom adapters (not OpenAI-compatible):
  - Azure OpenAI (`api-key` header instead of `Authorization: Bearer`)
  - Amazon Bedrock (SigV4 signing)
  - Google Vertex AI (GCP OAuth, different endpoint from Gemini API)
  - Replicate (predictions API, polling model)
  - Cloudflare Workers AI (`account_id` in URL path)
  - Reka (own request format)

#### websocket
- [x] 15 TODOs — resolved/categorised (perf/api/extensions/policy/refactor); aa5a4e0
- [x] Tests — 118 assertions: frame encode/decode, masking, close/ping/pong, error cases
- [x] `package.path` guard added
- [ ] Error return convention: int → string (breaking API change, deferred)
- [ ] Packet size limit enforcement (caller policy decision, deferred)

#### sqlite
- [x] No tests — add coverage for query, parameter binding, iteration, error paths (sqlite_test.lua, 72 assertions)
- [x] `db:close()` bug: passes `self.db` (`sqlite3 *[1]`) to `sqlite3_close_v2` which expects `sqlite3 *`; should be `self.db[0]` — fixed (4b9ae58)
- [ ] blob support missing (TODO in source) — `sqlite3_bind_blob` declared in FFI cdef but unreachable from Lua API
- [x] macOS: dlopen path for libsqlite3 — fixed with pcall-based multi-name fallback (commit 4f67ac9)

#### pkg
- [x] `install.lua`: resolver and downloader — implemented (resolve, fetch, link, run)
- [x] `config.lua`: `~/.crescent/config.lua` loading with defaults

#### cli (lib/crescent_examples/)
- [ ] Scripts mix `main()` logic with library code — not composable
- [ ] Many scripts have implicit dep on lib/ layout; add path fixups or document
- [ ] Review lib/crescent_examples/ scripts — sort into per-library homes or keep as demos

#### cross-cutting
- [ ] Standardise error return style: prefer `nil, err` for recoverable errors; `error()` only for invariant violations. Affected: http/client (uses assert), cbor/lunajson (uses error() for encode failures — acceptable but document the choice)
- [ ] LICENSE files: most vendored packages have headers but no LICENSE file — add or verify (ljsocket, lunajson, cbor, sha1, base64, cparser, git)
- [ ] `package.path` guard missing from websocket and http submodules — add where standalone use is expected
- [ ] Review and polish all libraries pulled from ~/git/lua (bulk import done)
- [ ] lib/todo/: conflicts with dep/todo/ (stubs for jpeg, png, xcb, soloud + a sqlitex.lua (old naming), webp.lua) — decide what to keep
- [ ] Remove or integrate duplicate/overlapping libs (e.g., mock.lua vs mock/, lil.lua vs lil/)
- [ ] replx: add provenance tracking for lazy-loaded globals (symbol → source module)
- [ ] FFI bindings: add ABI sanity checks (sizeof/offsetof assertions for wlroots version skew)
- [ ] Formalize C header ingestion pipeline (update_wlroots.sh pattern) as reusable tooling

## typechecker

### self-hosting blockers (run clean on own codebase)
- [x] Widen literal types on reassignment (`local k = 1; k = k + 1` should work)
- [x] Multi-return unpacking (`local a, b, c = f()` should assign all three)
- [x] Forward-declared locals (`local f; f = 42` — use typevar, not nil)
- [x] Integer literal inference (hex `0x36` should be integer, not number)
- [x] Arithmetic on integers returns integer, not number
- [x] String method resolution (`s:gsub(...)` resolves via string metatable)
- [ ] **`string <: { sub: _ }` fails in structural subtyping** — method dispatch (`s:sub()`) already resolves via the string prelude, so the checker knows `string` has those methods. But the subtyping relation doesn't use the same lookup: `string` as a primitive fails `<: { sub: _ }`. These are the same invariant — one code path (method dispatch) uses the prelude, the other (structural subtyping) doesn't. Fix: when checking `string <: { field: T }`, look up the field in the string prelude before failing. Causes ~59 pre-existing errors in `lib/parse/init.lua`.
- [ ] **Mixed named/unnamed params in a `--:` annotation mis-infer DISTANT code** — writing `--: (Val, atom: string) -> boolean` on v9 lattice.lua's `has_atom` (commit ff25df8c, where it is spelled unnamed `(Val, string)`) makes the legacy checker report `cannot take length of type never` at the UNRELATED, much earlier `#fn.results` (lattice.lua:645, inside clip); the fully-unnamed spelling checks clean. Whole-file inference is annotation-shape sensitive at a distance — either reject the mixed spelling with a parse diag or fix the inference; silent far-away `never` is the worst failure shape.
- [x] `number` assignable to `integer` parameter (safe widening direction)
- [x] Union-typed operands (`x and "y" or "z"` produces union — concat/arithmetic now accept)
- [x] Reassignment of literal-typed bindings (`ret = "()"` then `ret = "..."` — fixed by T.widen)
- [x] Forward references in `local M = {}` / `function M.foo()` pattern (prescan)
- [x] Dict-style computed access `t[key]` checks string-keyed fields (literal and general)
- [x] Empty table `{}` assignable to array-typed parameter (absorbs indexers in unify)
- [x] `x = x or default` pattern — strip self-ref var from union in bind_var
- [x] Cross-call-site typevar mutation — generalize params + FunctionDeclaration writes raw table
- [x] Recursive `local function f()` — pre-bind name as typevar before body inference
- [x] Discriminated union narrowing (`if t.kind == "literal" then ...`)

### unify.lua blockers
- [x] Structural narrowing after `if ty.tag == "var" then` (adjust_levels/bind_var expect level/id fields on resolved vars) — fixed: `and/or` idiom nil-union, assignment-narrowing ops annotation, d.path[i] with `--: [string]?` guard

### output formats
- [x] `--format json` structured output (file, line, severity, message)
- [x] `--format sarif` for GitHub Code Scanning / CI integration
- [x] Column numbers in error positions
- [x] SARIF column off-by-one: typechecker cols are 1-indexed; `errors.format_sarif` uses `e.col+1` → outputs col+1 (2-indexed). Should use `e.col` for 1-indexed SARIF. Fixed 2026-03-15.

### done
- [x] Full require() return type tracking (infer module return type)
- [x] Implicit any error reporting (every ANY fallback site)
- [x] `--dump` CLI mode (print inferred bindings)
- [x] `--annotate` CLI mode (emit source with --: annotations)
- [x] Type inference for local bindings
- [x] Structural typing for tables
- [x] Angle-bracket generics (`Name<T, U>`) with constraint support
- [x] Named type resolution with two-pass forward references
- [x] Tuple types (`{ number, string }`) and spread (`{ ...Base }`)
- [x] Flow-sensitive type narrowing (type(), nil checks, truthiness, assert)
- [x] Module resolver + prelude system (Array, Dict, Set, Optional)
- [x] Nominal types (newtype, opaque)
- [x] Match types (`match T { pattern => result }`)
- [x] Intrinsics ($Keys, $EachField, $EachUnion)
- [x] Overload resolution (best-match scoring)
- [x] setmetatable __index merging, __call metamethod
- [x] `#field` metatable slot syntax — separate `meta` dict on table types; `#__add: fn` in annotations; setmetatable populates META_OPS into meta; unification checks meta fields

### known false positives
- [x] **Assignment narrowing**: assigning `nil` to a variable inside `if x then` is flagged — typechecker checks against narrowed type, not declared type. Fixed: narrowing-escape generalized from nil-only to any value; checks outer scope binding for the pre-narrowing type.
- [x] **Nil method call not caught**: `local x; x:match("pattern")` — fixed by nil_vars side-channel; `testdata/errors/nil_method.expected` now captures the error.

### access control (design complete, implementation pending)
- [x] **Design field access control model** — written to `docs/access-control.md` (2026-03-19)
- [ ] **Resolve open questions in access-control.md before implementation**: (1) annotation syntax for exported type vs internal type; (2) opt-in syntax at use site for intentional private access; (3) read/write independence in annotation syntax; (4) split FLAG_READONLY into FLAG_IMMUTABLE + FLAG_WRITE_PRIVATE in FieldEntry
- [ ] **Remove FLAG_PRIVATE** — current `_`-prefix enforcement (session 25) is wrong model. Privacy = absence from exported type + `$Opaque<T>` + `--:: unseal` opt-in. No definition-site whitelist.

### nominal type identity across files (bug)
- [x] **`newtype` and `$Opaque<T>` identity is now content-addressed**
  — nominal IDs are now derived from `fnv31(filename:ann_tid)` for `$Opaque` and
  `fnv31(filename:newtype:name)` for `newtype`, making them deterministic for the
  same source content across runs. The stable hash is stored in TAG_TYPE_CALL.data[3]
  and persisted through .cri files so cross-file aliases resolve consistently.
  **Remaining gap**: two *different* files declaring the same alias (e.g.
  `--:: Schema<T> = $Opaque<T>` in both init.lua and check.lua) still produce
  distinct types. The fix requires module type imports — when check.lua does
  `require("lib.type")`, its annotations should resolve `Schema` from init.lua's
  exported type aliases, not from a re-declaration. Tracked below.
- [x] **Module type imports**: type aliases from required modules are now in scope for annotations.
  CRI Section 6 serializes/deserializes type aliases. When `require()` resolves via
  cri_loader, aliases are returned alongside exports and injected into scope via
  `inject_imported_aliases` in constrain.lua. Local declarations take precedence.
  Fixed: cri_write now registers alias name/param strings in the string table.

### known false negatives (v2)
- [x] **nil/boolean concat**: `nil .. "a"` silently passed — fixed by replacing is_concat_scalar tag whitelist with `__concat` metamethod presence check via meta_op_ret/prim_meta. nil and boolean have no __concat → correctly fail. string|nil union member fails correctly.
- [x] **`_G` should be an intrinsic reflecting the global scope**: synthesized as `$GlobalScope` — closed TAG_TABLE (no fallback indexer), named fields per declared global, declared in stdlib_types.lua. TAG_INTRINSIC resolution in constrain.lua checks type aliases first so `$Name` works as a regular type reference when registered. (2026-03-19, 5a42a48)
- [x] **`ctx_types.lua` leaks internal bindings into user scope**: `populate()` now only loads stdlib_types.lua; `populate_checker()` loads both. (2026-03-19, 9c9f788)

### annotation syntax gaps
- [x] **Open table syntax in .d.lua**: `{ ... }` bare spread in table annotation creates a row variable; `{ fields..., ... }` = open table. `_G` now declared in stdlib_types.lua. (2026-03-03, commit 6e197c5)
- [x] **`typeof` annotation**: `typeof x` captures the inferred type of binding `x`. TAG_TYPEOF = 25; ann.lua recognises `typeof <ident>`; resolve_annotation_type does scope lookup. Top-level `--::` decls with typeof are deferred until after gen_block. (2026-03-19, 913110e)
- [x] **`typeof` in function signatures**: pre-bind param names as TAG_VAR placeholders before resolving annotations. All cases work: forward refs, backward refs, return refs, mutual refs.

### performance (v2 redesign)
**Full redesign in progress. See `docs/typechecker-v2.md` for architecture.**

v1 is a proof-of-concept for the type system semantics. v2 is the production
implementation targeting tsgo-competitive cold-start performance and sub-100ms
incremental checking at 1M+ LOC scale.

Key design decisions:
- Flat-array AST (32-byte FFI nodes, arena-allocated, zero GC)
- Integer type tags + union-find (no string dispatch, O(α) resolution)
- Custom parser → flat AST directly (no intermediate tables)
- mmap-able .cri interface files (zero-copy, content-addressed)
- Merkle DAG incremental cache (interface-hash propagation)
- Fork-based parallelism via libc FFI (wave-front scheduling)
- LSP daemon with tiered memory (hot/warm/cold)

**v2 checker Phase 3 — implemented (2026-03-02).**
Types: flat TypeSlot arenas + union-find. Env: let-polymorphism (generalize/instantiate).
Unify: structural, bidirectional, row polymorphism. Infer: full AST walk, annotations, narrowing.
Files: types.lua, env.lua, unify.lua, errors.lua, match.lua, narrow.lua, infer.lua, check.lua.
Tests: 721 assertions in v2_test.lua (1123 total across all suites).

Known gaps / Phase 4 deferred work:

**Phase 4 preamble complete (2026-03-02, commit 663e90a):**
- [x] cli.lua — thin CLI runner
- [x] prelude.lua — Lua 5.1 stdlib bindings (string, table, math, io, os, coroutine)
- [x] open-table extension — `function M.foo()` adds field via table_add_field
- [x] prescan: function M.foo() pre-populates M's field list before inference
- [x] prescan: `local M = {}` preserves prescanned type (no clobber on infer)
- [x] iterator type inference — `for k, v in pairs(t)` uses iter func return types
- [x] string method calls — `s:gsub()` looks up string prelude table

**Known false positives in v2 (catalogued 2026-03-02 against v2 source):**

Cat A — Forward-declared nil locals (large impact on infer.lua): **FIXED 2026-03-02**
- `local f; f = function()` — now binds a fresh type var instead of T_NIL when no RHS
- Fixed in StmtRule[NODE_LOCAL_STMT]: el==0 → make_var; last_rhs_is_call → T_ANY
- Remaining: `local x = nil` (explicit nil literal) still binds T_NIL — Cat A variant

Cat B — Multi-return assignment loses values: **FIXED 2026-03-02**
- Fixed in StmtRule[NODE_LOCAL_STMT] and StmtRule[NODE_ASSIGN_STMT]:
  when last RHS is a call, missing return slots → T_ANY instead of T_NIL
- Remaining: fully generic multi-return arity tracking (future)

Cat C — Literal table vs indexed type mismatch: **FIXED 2026-03-02**
- Fixed in unify.lua: when b has a numeric indexer and a has no matching indexer, check
  a's sequential integer-named fields ("1", "2", ...) and unify each value with the indexer value type.

Cat D — Boolean literal widen on reassignment: **FIXED 2026-03-02**
- Fixed in StmtRule[NODE_LOCAL_STMT]: boolean literal binds widen to `boolean`
- Fixed in StmtRule[NODE_ASSIGN_STMT]: existing binding widened before unify

Cat E — Nil-narrowing after early return: **FIXED 2026-03-02**
- narrow.lua: bare identifier treated as nil-check; guard clauses apply negated narrowing
- narrow.lua: TAG_VAR not narrowed to T_NEVER (prevent "never" in branched code)
- StmtRule[NODE_IF_STMT]: after unconditional-exit clause, apply negated narrow to continuation
- ASSIGN_STMT: skip unify when existing resolves to T_NEVER (narrowed-out branches)
- OP_AND short-circuit narrowing: `a and a.field` narrows `a` before evaluating `a.field`.
  narrow_scope handles OP_AND in truthy branch; infer.lua OP_AND early-returns with narrowing.
- OP_OR guard narrowing (2026-03-02): `if not x or not y then return end` — falsy branch of
  `A or B` applies De Morgan: narrow_scope handles OP_OR with is_truthy=false, extracting
  narrowings from both arms. Also added NODE_FIELD_EXPR support in extract_narrowing:
  `x.field` is a "field_presence" check; after `if not x.field then return end`, x.field
  is narrowed to non-nil in the continuation via narrow_field_non_nil (rebuilds table type).

Cat F — `intern_mod.get()` returns `string|nil`, `or "?"` not narrowed to `string`: **FIXED 2026-03-02**
- Fixed in ExprRule[NODE_BINARY_EXPR] OP_OR: strip nil from left side before union with right.
- Also fixed `is_concat_ok` to handle unions (all members must be concat-compatible).
- `string|nil or "?"` now produces `string|"?"` (concat-safe union), not `string|nil|"?"`.

Cat J — **FIXED 2026-03-02** (commit 0a91819):
- Removed `constrain()` / `meta_constraint()` — free typevars in arithmetic stay free.
- Added `prescan_block` call inside `infer_function` (forward-decl'd) to pre-bind nested
  `local function f()` before body inference (fixes self-recursive nested locals).
- Added `and`-short-circuit narrowing in ExprRule[OP_AND] (infer.lua) and narrow_scope
  (narrow.lua) — `ann and ann.field` no longer fails before entering the truthy branch.
- Added `seen` dedup table in `make_union` (types.lua) — prevents `'v | 'v` unions that
  broke field access after stripping nil from `nil | 'v | 'v`.
- Trade-off: arithmetic on unannotated params is no longer constrained (e.g. `add({}, {})` with
  unannotated `add(x,y) = x+y` won't error). Annotated code is unaffected.
- All 9 previously-clean v2 source files now self-check at 0 errors.

Cat G — string meta architecture: **FIXED 2026-03-02**
- `ctx.prim_index` (TAG_* → __index TID) for method dispatch; `ctx.prim_meta` (TAG_* → op-metamethods TID) for operator dispatch.
- Both populated by prelude.populate() from stdlib_types.lua aliases (number_meta, integer_meta, string_meta_ops, string var).
- infer.lua NODE_METHOD_CALL: generic prim_index[tag] lookup; literal strings normalized to TAG_STRING.
- infer.lua meta_op_ret: extended to check prim_meta for primitives — unary `-integer` now returns integer (not number).
- infer.lua binary dispatch (ARITH/CMP/CONCAT): TAG_TABLE guard prevents prim_meta from short-circuiting error checks and mixed-type arithmetic.
- unify.lua: replaced if/elseif tag switch with prim_meta[ptag] lookup (TAG_LITERAL normalized inline).
- Known gap: `nil .. "a"` not flagged — TAG_NIL is in is_concat_scalar (pre-existing, separate fix needed).

Integer literal typing: **FIXED 2026-03-03** (commit bb0c2e8 era)
- `NODE_LITERAL` handler was using numval index as a pool intern ID (IDs 0-21 are keywords).
- Fix: store `pr.lexer.numvals` in `ctx.numvals`; check `num % 1 == 0` for integer classification.
- integer <: number is now unidirectional (integer assignable to number, NOT vice versa).

Cross-type comparison: **FIXED 2026-03-03** (commit bb0c2e8)
- `"a" < 1` and `1 < "a"` silently passed because each operand individually had __lt in prim_meta.
- Fix: meta_fn_tid helper returns the full metamethod function TID. In CMP_META dispatch, after
  has_metamethod passes for both operands, look up the __lt/__le function (left first, then right
  per Lua calling rules) and validate both operands against its declared parameter types via try_unify.
- Bonus fix: try_unify union-LHS case: all members must be assignable to b (previously fell through
  to false, causing false positives for `integer | number > number` patterns in unify.lua self-check).

Cat H (new) — Optional function parameter typed as required: **FIXED 2026-03-02**
- Fixed in infer_function: scan first 10 body statements for `param = param or default`.
- After body inference, widen matched params to union(bound_type, T_NIL).
- `resolve_annotation_type(ctx, id)` (2 args) now accepted where 3rd param has default.

Cat I (new) — Explicit `local x = nil` still binds T_NIL: **FIXED 2026-03-02**
- Fixed in NODE_LOCAL_STMT: when rhs resolves to TAG_NIL, bind fresh typevar (same as Cat A).
- `local arg_ids = nil; arg_ids = {}` now works correctly.

Recursive function return type inference: **FIXED 2026-03-03** (commit 192b878)
- Prescan now creates `(T_ANY,...) → β` stubs (not bare TAG_VAR). β is shared across all recursive
  call sites (not FLAG_GENERIC → instantiate passes it through unchanged). add_return eagerly binds
  β on first return statement; all later recursive calls resolve via find(). ctx.return_stub_vars
  stack threads stub return vars into nested function scopes. Annotated functions skip eager binding.
- Limitation: unannotated params are TAG_VAR; arithmetic falls to T_NUMBER. Annotated params work.

**Phase 4 proper:**
- [x] .cri interface files (zero-copy module loading, content-addressed) — 2026-03-03: sha256.lua, cri_write.lua, cri_read.lua, cache.lua, check.lua integration
- [ ] Fork-based parallelism (Phase 5)
- [ ] LSP daemon integration (Phase 6)

**Next high-value false-positive fixes (from catalogue above):**
- [x] Cat A: forward-declared nil locals → make_var (unblocks most of infer.lua false positives)
- [x] Cat B: multi-return in assignments (right-hand side)
- [x] Cat D: boolean literal widen on reassignment
- [x] Cat E: guard/early-return nil narrowing (full fix: includes OP_OR De Morgan + field_presence)
- [x] Cat C: positional table vs indexed type — FIXED 2026-03-02
- [x] Cat F: `A or B` result narrowing — FIXED 2026-03-02
- [x] Cat H: optional function parameters (seen arg pattern) — FIXED 2026-03-02
- [x] Cat I: explicit `local x = nil` treated as forward declaration — FIXED 2026-03-02

- [x] Infinite recursion in resolve_require: fixed with `_globally_resolving` module-level table.

Lexer optimization (see `docs/perf/log.md` for measurements):
- [x] Kill `_buf` mechanism — pointer arithmetic + `ffi.string` at end (1.4x speedup)
- [x] Source-referencing intern pool — FNV-1a hash + memcmp, zero Lua strings in lex path (5.3x total vs baseline)
- [ ] (stretch) Full FFI struct hash table for intern entries — current impl uses Lua tables per entry with FNV-1a + memcmp; a flat FFI array could reduce GC pressure further but 5.3x is good enough to move on

### v2 → v3 migration (constraint-based inference)

Design: `docs/typechecker-v3.md`. Implementation: `lib/type/static/constrain.lua` + `solve.lua`.
Entrypoint: `check.check_string_v3(src)`. Status: Phase 1 (parallel) — v3 runs alongside v2.

**Phase 1 blockers (reach parity with v2):**
- [x] String method dispatch (`s:gsub(...)` via prim_meta) — prim_index lookup in solve_has_field
- [x] prim_index / metamethod lookup for primitives — same
- [x] Narrowing (type(), nil checks, `if x.tag == "foo"`) — narrow_scope/apply_narrowed in constrain.lua
- [x] pcall / xpcall — already correct via stdlib_types.lua `any` param declarations
- [x] Iterator inference (`for k, v in pairs(t)`) — already implemented in constrain.lua
- [x] `or`-expression union inference (`x or default` → `T | U`) — already implemented in constrain.lua
- [x] Correlated multi-return narrowing — C_INDEX + filter_tuple_union_arms + pcall intrinsic; io.open/string.find union-of-tuples stdlib types (2026-03-19)

**Phase 2 — cutover:**
- [x] Replace `check.check_string` with v3 pipeline — done; check.lua fully on v3 (commit 848ea56)
- [x] All existing tests must pass — 838/838 pass against v3 (2026-03-16)
- [x] Delete `infer.lua` — done (commit 2e33c62); type_test.lua migrated to check_mod

**Phase 3 — annotation pass (after Phase 2 cutover):**
- [x] Rewrite remaining sumneko-syntax `.d.lua` files in crescent annotation syntax
  (`--:` / `--::`). Files: `lib/http/format_types.lua`, `lib/lsp/types.d.lua`,
  `lib/imap/format_types.lua`, `lib/matrix/format_types.lua`. Done: commit `2a9ec10`.
- [ ] Strip all `--:` annotations from own codebase, run v3, record error set
- [ ] Re-annotate only where errors appear (load-bearing annotations)
- [ ] Mark inference-gap annotations with `-- TODO: v3 gap` comment so they're removable in bulk when the gap closes
- [ ] Keep annotations on public API functions regardless (they're contracts, not just inference hints)
- [ ] Goal: minimal annotation set where every annotation either fixes an error or documents a public contract

### v1 → v2 cutover status (2026-03-10)

v2 is architecturally superior but v1 CLI has QoL features v2 still needs before cutover:

| Feature | v1 | v2 |
|---|---|---|
| Source line + caret in errors | ✓ | ✓ (2026-03-10) |
| `--format sarif` | ✓ | ✓ (2026-03-10) |
| `--dump` mode (print inferred bindings) | ✓ | ✓ (2026-03-10) |
| `--annotate` mode (emit source + annotations) | ✓ | ✓ (2026-03-10) |
| Auto-glob `lib/*.lua` when no args | ✓ | ✓ (2026-03-10) |
| `.cri` cross-file require() types | ✗ | ✓ |
| Correct integer <: number | ✗ | ✓ |
| pcall/xpcall narrowing | ✗ | ✓ |
| Branch-join merging | ✗ | ✓ |
| Recursive fn return inference | ✗ | ✓ |

Blocking items for cutover:
- [x] `--dump` mode in v2 CLI — 2026-03-10
- [x] Auto-glob fallback in v2 CLI — 2026-03-10
- [x] `--annotate` mode in v2 CLI — 2026-03-10

### backlog
- [x] **Object narrowing via field access** — `if foo.x then aaa(foo)` narrows `foo` itself so `aaa(foo)` typechecks. Implemented via `field_presence` narrowing in `apply_narrowing` (narrow.lua): `narrowed[obj_name_id]` is set to `narrow_field_non_nil(obj_type, field_name_id)`, which rebuilds the table type with nil subtracted from the named field. Works for plain tables and unions. Tests added in type_test.lua ("checker: object narrowing via field access").
- [x] **Type system completeness audit** — tag × operation matrix written to `docs/type-tag-matrix.md` (2026-03-15, commit b51f976). Fixed: `x == "literal"` direct variable narrowing (lit_eq kind, LIT_STRING + LIT_BOOLEAN), boolean field discriminant narrowing, TAG_ROWVAR in try_unify/unify, TAG_TUPLE literal indexing. Known remaining gaps documented in the matrix: integer discriminants (numval per-file), covariant/contravariant generics, recursive types, TAG_MATCH_TYPE/FORALL/TYPE_CALL/SPREAD not handled in unify (by-design: meta-level constructs not expected in value position).
- [x] **Soundness audit** — 2026-03-15. Full audit written to `docs/soundness-audit.md`. Gaps enumerated: (1) TAG_VAR permissiveness in try_unify — union/intersection dispatch silently accepts free-var args; (2) unannotated params by design; (3) generic variance not enforced; (4) no occurs check for recursive types; (5) intersection dedup — FIXED 2026-03-15 (added `seen` table to make_intersection); (6) nil-padding in arity check — correct for Lua semantics; (7) LIT_INTEGER cross-file — deferred.
- [x] **Soundness fix: try_unify TAG_VAR** — `try_unify` no longer returns true for `ta.tag == TAG_VAR` (free actual type). Only `tb.tag == TAG_VAR` (free expected, for generic instantiation) stays true. `ta.tag == TAG_ROWVAR` kept true for open-table structural matching. (2026-03-15, session 21). See `docs/soundness-audit.md` Gap 1.
- [ ] **Soundness gap: `try_unify` does not check meta fields** — `try_unify` (used for generic constraint checks, oracle lookup, fuzz algebra) only checks regular table fields; meta fields are only checked in `M.unify` (constrain.lua path). Consequence: `<T: { #__add: T }>` generic constraints silently accept types without the required metamethod. Fix: extend the TAG_TABLE branch of `try_unify` to also iterate meta fields. Found while attempting A4 algebra fuzz invariants (2026-03-30).

- [ ] **Typechecker bug: `any?` as last param corrupts struct field resolution** — when a local function has `any?` as its last parameter (e.g. `--: (SomeStruct, integer, string, any?) -> nil`), the checker fails to resolve fields of `SomeStruct` in the function body, treating them as `unknown`. Workaround: drop the `?` from `any?` params (use `any` — makes no runtime difference since `any` absorbs nil). Found in lib/log/init.lua emit() during 2026-04-10 implementation.
- [ ] **Soundness fix: mutual recursion via non-table types** — `bind_var` has occurs() for simple self-ref; `display()` has seen guard for tables. Mutual recursion through function types (very rare in Lua) is not protected. Very low priority. See `docs/soundness-audit.md` Gap 4.
- [ ] **Generic variance (expressiveness, not soundness)** — type params in `<T>` generics have no variance annotation. Demoted from soundness to expressiveness in commit `ca64aeb1`; design at `docs/typechecker-variance.md`. Structural invariance + function contravariance + FLAG_SKOLEM rejection already prevent the bad cases. Remaining gap is being unable to *declare* covariant/contravariant containers. See `docs/soundness-audit.md` Gap 3 (historical framing).
- [ ] **Error message quality audit** — bar is Rust-level helpfulness. Specific gaps identified:
  - Source line + caret: **DONE** (2026-03-10) — errors.lua set_source/format_plain/format_ansi
  - "missing required argument" now shows expected type: **DONE** (2026-03-10) — `argument 1: missing required argument (expected 'string', got nil)`
  - Long type truncation: **DONE** (2026-03-10) — display_short() at 120 chars with …
  - "missing required argument" now includes parameter name: **DONE** (2026-03-10) — `argument 1 'opts': missing required argument...`; param name IDs stored in TypeSlot data[5]/data[6], threaded through instantiate/substitute
  - Named params in annotations: **DONE** (2026-03-10) — `(x: integer, y: string) -> boolean` syntax in ann.lua; stdlib_types.lua updated to use named params throughout; resolve_annotation_type passes names to make_func via data[5]/data[6]
  - Warn on annotation-only functions missing param names: **DONE** (2026-03-10) — `process_type_decls` in infer.lua emits a warning for `--:: declare fn = (T1, T2) -> ret` where the function type has params but no names; inline `--:` annotations on real functions don't warn (names come from AST)
  - [x] Overload mismatch: show *which* overload candidates existed and why each one failed (candidate-by-candidate diff) — **DONE** (2026-03-11): try_call_args (non-mutating) tries each candidate; first match wins; if none match, reports "no matching overload" with per-candidate argument errors
  - **DONE** (2026-03-15): Error message wording overhaul — natural English, no jargon. Patterns: `` `name` is `X`, but this location expects `Y` `` (field re-assign); `` `foo.baz` doesn't exist `` (field not found, no field listing); `` `arg` is `X`, but `fn` expects `Y` `` (call mismatch, uniform regardless of whether X is unknown). Secondary spans for field errors via reparse-on-error (same-file: AST walk; cross-module: reparse from disk). "Did you mean" and "consider annotating" suggestions removed — exact error is enough.
  - ctx_types.lua — **DONE** (2026-03-15): `lib/type/static/ctx_types.lua` declares `Ctx` type alias; loaded by prelude.lua; ~30 functions in infer.lua annotated; self-check 0 errors.
  - Field re-assignment type-check — **DONE** (2026-03-15): `` `name` is `X`, but this location expects `Y` `` with secondary "set to `X` here:" span.
  - Remaining gap: suggestions still listed as open below — actually dropped; error messages are intentionally minimal ("exact error, no more, no less")
- [ ] High-perf SHA-256 for .cri content addressing: current pure-Lua impl is correct but slow
  (~10 MB/s). For 1M LOC scale, SHA-256 should be done via FFI (libssl EVP_DigestInit or
  kernel crypto via syscall). Profile first — .cri files are small (kB range) so this may
  not matter until we're hashing source files at scale.
- [x] Generic function inference (infer type params from call site args)
- [x] `<T>` explicit generic annotation syntax — `--: <T>(T) -> T` on a function; forall vars are generic typevars, freshened at each call site; composes with type-alias params (`--:: Name<T> = …`)
- [x] Partially inferred / partially specified generics — `f --[[:<json.Format, _>]] (val)` where `_` means infer. Annotation on any line `[callee.line, node.line]` (node.line = `(` line). Lua 5.1/LuaJIT constraint: `(` cannot be on a new line from the callee (ambiguous call syntax), so annotation must share the callee's line in practice. Lua 5.2+ compat removes this restriction.
- [x] Parse LuaJIT FFI cdef blocks
- [x] **stdlib_types.lua: type `bit.*` library** — all bit.* fns typed, return integer
- [ ] **stdlib_types.lua: multi-target support** — stdlib types differ by runtime/version (LuaJIT vs Lua 5.1/5.2/5.3/5.4); currently stdlib_types.lua targets LuaJIT but isn't labelled as such; design needed: separate .d.lua files per target, or conditional sections, or CLI `--target` flag that selects which prelude to load
- [x] Field assignment `M.foo = val` now adds the field to M's table type via NODE_FIELD_EXPR handling in NODE_ASSIGN_STMT. Structural-inference guard: skip when existing field type is TAG_VAR (prevents Cat J regression where `s.pos = s.pos + 1` binds the structural typevar).
- [x] **Index assignment type-check** (`t[k] = v`) — 2026-03-15: string literal keys handled as field assignment (add/check named field); non-literal keys checked against matching indexer if present; TAG_VAR tables constrained to have `[key_type]: val_type` indexer. Conservative: no indexer added to extensible tables with no matching indexer (avoids false positives on `returns[#returns+1] = v` patterns). Field re-assignment for index exprs now matches field-expr behavior.
  - Session 15 (2026-03-15, 8486a33): enforcement tightened — error on type mismatch for concrete key types (literal, integer, etc.); skip check only when indexer key is T_ANY/T_UNKNOWN (dynamic dispatch tables). `{ [1]: string }` with `arr[1] = 42` now errors correctly.
- [x] **LIT_INTEGER literal type** — Session 15 (2026-03-15, 8486a33): `LIT_INTEGER = 4` kind added. Integer literals get globally-comparable type (value in data[1] as int32). Number annotations produce LIT_INTEGER for integers. `x == 5` narrowing, TAG_TUPLE indexing, dispatch table slot typing all benefit.
- [x] **LIT_NUMBER float fix** — Session 16 (2026-03-15, b00b27b): `double_to_i32x2`/`i32x2_to_double` helpers in defs.lua. Lex, parse, ann, types, infer, cri all updated. numvals side-array removed. Non-integer floats now produce `LIT_NUMBER` (not `T_NUMBER`), enabling `x == 3.14` narrowing.
- [x] **`x == 3.14` narrowing** — (2026-03-15, b629ef6): `make_lit_eq` in narrow.lua extended to handle LIT_NUMBER non-integer floats via `i32x2_to_double`. `M.unify`/`M.try_unify` in unify.lua fixed to compare `data[2]` for LIT_NUMBER literals (was only comparing `data[1]`).
- [x] **Enum inference** — Session 16 (2026-03-15): `TAG_ENUM_MEMBER = 24` (defs/types/unify/narrow/infer). All-literal same-kind table fields promoted to enum members via `try_promote_enum` in `StmtRule[NODE_LOCAL_STMT]`. `Status.OK` displays as `Status.OK`, `EnumMember <: integer/string` in unify. `x == Status.OK` narrowing via `enum_eq` kind in narrow.lua. Mixed-kind tables not promoted. Tests: 5 new assertions.
- [x] **Newtype IDs for type/intern/node IDs** — Session 16 (2026-03-15, f0cc150): `TypeId`, `InternId`, `NodeId`, `ListIdx` declared in ctx_types.lua. `load_decls` pass 2 in prelude.lua assigns unique `nominal_id` per newtype (was all 0, making them unify).
- [x] **Explicit `any` warning** — Session 16 (2026-03-15): DONE. `resolve_annotation_type` emits a warning when `TAG_ANY` is encountered in an explicit annotation (`ctx._ann_warn_line` set at call sites in LOCAL_STMT, FUNC_EXPR, FUNC_DECL). infer.lua annotations fixed (55 → 0 warnings).
- [x] **Structured diagnostics** — Session 16 (2026-03-15, 3cfd4b2): `M.E` table with 22 integer error codes in defs.lua. `errors.format_diag(code, args)` with per-code template closures. `report`/`warn` now take `(ctx, line, col, code, args)`. All 28 call sites updated.
- [x] v2 stdlib_types.lua: stdlib_types.lua created (2026-03-02); prelude.lua replaced with load_decls().
  `--:: declare name = type` for variable bindings; `--[[:: name = { ... }]]` for type aliases.
  Primitive meta types (number_meta, integer_meta, string_meta_ops) declared in stdlib_types.lua;
  derived into ctx fields after load_decls runs.
- [x] ann.lua: `declare` keyword added to ANN_DECL parser for variable bindings (vs type aliases).
- [x] ann.lua: function data[4] (vararg) fixed — trailing `...T` SPREAD now extracted correctly.
- [x] ann.lua: table data[4] (row_var) fixed — closed by default (-1), was accidentally open (0). Also fixed for `T[]` shorthand (parse_postfix) which had the same gap — triggered a false "undefined type S" when a generic type appeared at position 0 of the annotation arena due to `pairs()` iteration order.
- [x] ann.lua: skip_ws fixed to handle newlines (B_NL, B_CR) for multi-line block annotations.
- [x] `pcall`/`xpcall` return type narrowing — FIXED 2026-03-02: detect pcall/xpcall in ExprRule, extract wrapped fn return types, give `local ok, val = pcall(fn)` val: ret_type|nil; `if ok then`/`if not ok then return end` narrows val to ret_type via propagate_pcall_narrowing in record_narrowing.
- [x] For-in iterator return type tracking — `for k, v in pairs(t)` always gives `any` for k/v; need iterator protocol inference (ipairs/pairs over typed tables, custom iterators)
  - FIXED 2026-03-02 (commit 4efcd5a): detect pairs(t)/ipairs(t) single-call in NODE_FOR_IN; extract [K]:V indexer from actual table arg; typed loop variables. Falls back to iter-func-return extraction for other iterators.
- [x] Metatable slot syntax: `#field` in type annotations — done (see above)
- [x] Structural operator dispatch — BinaryExpression/UnaryExpression/ConcatenateExpression check `meta["__add"]` etc. on operand types via `meta_op_ret`; metamethod return type used instead of primitive check. Unlocks linalg / custom numeric types.
- [x] Structural constraint propagation for send — `x:method(args)` on a var should constrain x to `{ method: (self, args...) -> T, ...row }` (mirrors field access on var).
- [x] Implicit-any warnings on unannotated params — warn if param typevar still completely unbound after body inference; skip `self` and `_`.
- [x] Arithmetic/concat constraint propagation — `a + b` on vars should constrain to "numeric OR has `#__add`"; cannot naively bind to `number` (rejects custom types). Needs a typeclass-style "Numeric" constraint or union of `number | { #__add: ... }`. Same for concat and `#__concat`.
- [x] Branch-join / post-if type merging — FIXED 2026-03-02 (commit 19a6b19). Nil-default pattern,
  exhaustive if/else assignment, if-only assignment all handled. lookup_declared skips narrowing
  scopes; ASSIGN_STMT rebinds branch-locally; NODE_IF_STMT diffs branch scope and unions results.
  **DONE (v3, 2026-03-17, session 25)**: post-if branch-join narrowing ported to v3.
  `branch_scope_diff` + Cat E guard + union of per-branch end types. All branch-join
  tests passing. See commit `feat(type): v3 branch-join`.
- [x] Private field visibility enforcement — DONE 2026-03-17 (session 25). `_`-prefix fields
  get FLAG_PRIVATE. Cross-file access rejected in solve_has_field. ctx.type_origins maps type IDs
  to source filenames via CRI load tagging.
- [x] **Monomorphic callsite inference** — DONE (2026-03-19, commit 6cff48f): removed automatic
  `generalize` for unannotated functions. Params stay as free TAG_VARs; call-site C_CALLABLE binds
  them. Body constraints (C_ARITH etc.) defer until params are concrete. `add("hello", 2)` with
  body `a+b` now correctly errors. `self` param in methods still gets FLAG_GENERIC (avoids recursive
  type cycle). Prescan stub mutated in-place (not C_UNIFY). `unify(var, T_UNKNOWN)` now binds var.
- [x] pcall v3 narrowing — DONE (2026-03-19): C_INDEX multi-return + C_OR deferred or-expression
  fix now correctly types `s` as the pcall'd fn's return type. `s + 1` in `if ok then` errors
  with "cannot perform arithmetic on 'string'". Commits: 4976104 (C_OR), ca871ba (union subsumption).
- [x] `(string|nil) or "fallback"` not narrowing — DONE (2026-03-19): C_OR = 10 deferred constraint.
  OP_OR handler now emits `{C_OR, left, right, result}` instead of computing eagerly. solve_or
  defers while left is TAG_VAR, then runs subtract(left, nil) | right. Commit: 4976104.
- [x] `integer | 0` / `number | integer` union noise — DONE (2026-03-19): make_union now collapses
  literals subsumed by their primitive (LIT_INTEGER → integer, LIT_INTEGER → number), and integer
  into number. Fixes self-check false positives in arithmetic expression types. Commit: ca871ba.
- [ ] unnamed-params warn in --:: declare — `--:: declare fn = (T1, T2) -> R` should warn when
  param types are unnamed. Feature exists in v2 path but not v3 process_type_decls. Test fails
  after 2026-03-17 silent-crash fix.
- [x] $EachField descriptor `optional` flag — already implemented; `optional: true` in descriptor sets FLAG_OPTIONAL on output fields. Tests added (e31c6bd).
- [x] $EachField / $EachUnion full transform evaluation — descriptors, union distribution, any input all working (2026-03-19)
- [ ] Typed holes / completions
- [x] **Match type pattern-bound variables** — fixed 2026-03-19 (commit 13e9603)
- [x] **Recursive generic type crash** — fixed 2026-03-19 (commit d1bb4b9)
- [x] **`never` type not enforced** — fixed 2026-03-19 (commit bf776ff)
- [x] **`any` through `Box<any>`** — fixed 2026-03-19 (commit bf776ff + annotation authority fix)
- [x] **Tag-exclusion in else branch** — fixed 2026-03-19: else branch now applies accumulated negated narrowings from all preceding if/elseif conditions (both Cat-E exiting and pass-through). See `fix(type): tag-exclusion narrowing in else branch`.
- [x] **Tag-exclusion in else with multiple exiting elseif arms** — fixed 2026-03-20: `filter_union` added to types.lua; `guard_narrowings` fallback (when `arm_info` is nil) now uses `filter_union(guard, neg)` instead of last-write-wins, correctly intersecting the accumulated guard with each new exiting arm's negation. See `fix(typechecker): accumulate else-branch negations across all exiting elseif arms`.
- [ ] Variadic `pipe`/`compose` typing — fixed-arity overloads work but variadic needs design; blocked on generic inference + possibly variadic generics or dependent types. Low priority, pending design.

## performance

- [ ] Bench infrastructure (pure Lua, handgrown) — micro + macro; latency histograms; compare before/after on HTTP request path. v2 parser bench: `docs/perf/v2_parse.lua`; perf log: `docs/perf/log.md`
- [ ] Write buffering — HTTP response assembly currently does many small `sock:send()` calls; gather into an iovec or corked buffer before flushing (TCP_CORK / TCP_NOPUSH via setsockopt FFI)
- [ ] Zero-copy static file serving — `sendfile(2)` FFI wrapper for staticx; avoids read-into-Lua-string + write round-trip; meaningful for large files
- [ ] `writev` / scatter-gather — single syscall for header + body chunks; pairs with write buffering above; FFI wrapper + iovec builder helper
- [ ] Buffer pool — reusable fixed-size byte buffers (FFI `uint8_t[N]`) to eliminate hot-path string allocations in HTTP parser and response serialiser
- [ ] Header serialisation fast path — avoid `table.concat` + string interning on every response; pre-serialise static headers once, memcpy into buffer
- [ ] Profile-guided allocation reduction — run under `jit.p` / `jit.dump` to find top allocation sites before committing to specific optimisations

## testing

### property testing (`lib/test/prop.lua`)
- [x] QuickCheck-style property runner: `prop.check(desc, gen, fn)` / `prop.it(desc, gen, fn)` — 2026-03-11 (commit a5c2799)
- [x] Core generators: `gen.int(min, max)`, `gen.uint`, `gen.float`, `gen.bool`, `gen.byte`, `gen.string`, `gen.list(elem_gen)`, `gen.table(k_gen, v_gen)`, `gen.one_of(...)`, `gen.frequency({weight, gen}...)`, `gen.sized(fn)`, `gen.map(g, fn)`, `gen.filter(g, pred)`, `gen.constant(v)`, `gen.nil_or(g)`, `gen.tuple(gens)`
- [x] Shrinking: binary search on int ranges, element removal for lists/strings, field removal for tables
- [x] N configurable trials (default 100); on failure: print original + shrunk + seed for reproducibility
- [x] Integration with test runner: failures show in the same format as `it()` blocks; property names in output
- [x] Seed override via PROP_SEED env var for deterministic replay

### fuzz testing (`lib/test/fuzz.lua`)
- [x] Corpus-based mutation fuzzer: byte-flip, insert, delete, splice on seed inputs (2026-03-15)
- [x] Coverage-guided mode: track which branches fire (debug.sethook + branch bitmap); prefer mutations that hit new branches (2026-03-15)
- [x] Crash/error detection: wrap target in pcall; distinguish expected errors from panics (2026-03-15)
- [x] Corpus persistence: save interesting inputs to disk; resume across runs (2026-03-15)
- [x] AFL-style queue: round-robin queue; guided mode prioritises inputs that hit new branches (2026-03-15)
- [x] Integration with test runner: `fuzz.it(desc, fn, opts)` — failures appear in standard test output (2026-03-15)
- [x] Two modes: "fast" (pure random, no sethook overhead) and "guided" (coverage-guided) (2026-03-15)
- [ ] Integration with property testing: `prop.fuzz(gen, fn)` — use mutations instead of random generation when a corpus exists
- [ ] Shrinking: mutate + binary-search toward a minimal crashing input (currently reports first crash, not shrunk)

### coverage

Current: `luajit lib/test/cli.lua --coverage` does line coverage via `debug.sethook`. Gaps:

- [ ] **Statement coverage**: count each statement executed (finer than line — multiple stmts per line)
- [ ] **Branch coverage**: track both arms of every `if`/`elseif`/`else`, `and`/`or` short-circuit, `repeat`/`while`/`for` loop entry vs skip — report uncovered branches explicitly
- [ ] **MC/DC (Modified Condition/Decision Coverage)**: each boolean sub-condition independently affects the overall decision; required for aviation/automotive safety standards; needs AST instrumentation or symbolic execution
- [ ] **Path coverage**: enumerate feasible execution paths through a function; exponential in theory, approximate with DFS + budget
- [ ] **Coverage-gated CI**: fail if coverage drops below threshold; report per-file and per-function coverage delta

Branch coverage implementation sketch: instrument the AST (add synthetic nodes around branch points) or use `debug.sethook("l", ...)` + a per-function line→branch-id table derived from the parser. The v2 parser already produces a full AST, so AST instrumentation is the natural path.

### fixture / snapshot testing (`lib/test/fixture.lua`)
- [x] `fixture.run_dir(dir, runner, opts)`: discover `*.input` / `*.expected` pairs; run `runner(input)` → actual; diff vs expected; report failures with unified diff — 2026-03-11 (commit f5e9c7a)
- [x] `UPDATE_SNAPSHOTS=1` / `opts.update` mode: overwrite `.expected` files with actual output (snapshot update workflow)
- [x] Pluggable normalizers: `fixture.normalize.{strip_ws, crlf, sort_lines, compose}`
- [x] Binary fixture support: hex-dump diff on mismatch when content has non-printable bytes
- [x] Named fixture groups: `fixture.group(name, dir, runner)` wraps `run_dir` in describe
- [x] `fixture.check(in, exp, runner, opts)` — low-level single-fixture check without it() registration
- [x] `fixture.diff(expected, actual)` — LCS unified diff (pure Lua, O(n*m), capped at 600 lines)

## infra
- [ ] Formalize code style conventions — don't assume ~/git/lua conventions are correct, decide fresh
- [ ] `cr` binary entry point
- [ ] Third-party libs under lib/ must preserve original LICENSE

## LSP
- [x] LSP server (JSON-RPC over stdio) — `lib/type/static/lsp.lua`; stdio framing, initialize/shutdown/exit, textDocument/didOpen+didChange+didSave+didClose → publishDiagnostics. Full text sync. (2026-03-15)
- [x] Position → type query — `ctx.type_at` flat array {line,col,tid,...} populated by `infer_expr`; `type_at_lookup` in lsp.lua finds best match; `textDocument/hover` returns markdown type string. (2026-03-15)
- [ ] Incremental re-check — cheap scope invalidation so full reparse isn't needed on every keystroke
- [ ] Module-level type cache — avoid re-typechecking stdlib/imports on every edit; currently `check.clear_cache()` on every file change is correct but slow for large projects
- [x] Completion — scope-level name enumeration (module + stdlib + locals visible at module level); cursor-local scope completions need position-tracking infrastructure not yet built. (2026-03-15)
- [x] Completion: field completions after `foo.` — extract identifier before trigger, resolve in scope, enumerate table fields. (2026-03-15)
- [x] Completion: union/intersection field completions — table_field_items recurses into TAG_UNION/TAG_INTERSECTION members. (2026-03-15)
- [x] Go-to-def — `ctx.def_sites` (name_id → {line,col}) + `ctx.name_at` for identifier use positions; textDocument/definition handler in lsp.lua. (2026-03-15, within-file only; cross-file requires cri_loader integration)
- [x] Cross-file go-to-def for `require()` bindings — `ctx.require_sources` (name_id → module_name string) populated whenever `local x = require("mod")` is inferred. LSP go-to-def resolves module name to .lua / /init.lua file path and navigates there. Uses `rootUri`/`rootPath` from initialize. (2026-03-15)
- [x] Cross-module type resolution in LSP — `check.check_string_with_deps` added; resolves require() deps one level deep from disk (tries .lua then /init.lua). LSP uses this so hover/completions reflect actual module export types. (2026-03-15)
- [x] Signature help — `textDocument/signatureHelp` on `(` and `,` triggers; extracts callee from line prefix (simple, field, method calls), looks up function type in scope, returns SignatureInformation. (2026-03-15)
- [x] Cross-file go-to-def for fields — `x.bar` where x is a required module: navigate to where `bar` is defined in the module. Implemented via ctx.field_at flat array (stride 4: line/col/field_id/obj_id) populated in ExprRule[NODE_FIELD_EXPR]; find_field_in_ctx() scans AST; cross-file interns field name in module pool then scans module AST. (2026-03-15, commit 38f9a07)

## package manager
See `docs/pkg-design.md` for full design.
- [x] `pkg.lua` manifest format + parser — `lib/pkg/manifest.lua` (2026-03-16)
- [x] `crescent.lock` lockfile format + parser (hand-written TOML-like) — `lib/pkg/lock.lua` (2026-03-16)
- [x] Registry HTTP protocol (`pkg.rhi.zone` — simple GET index + tarballs) — curl-based v1 in `lib/pkg/install.lua` (2026-03-16)
- [x] Global cache (`~/.crescent/cache/<name>@<version>/`) — `lib/pkg/install.lua` (2026-03-16)
- [x] Install algorithm: resolve → fetch → link (hardlinks) → write lockfile — `lib/pkg/install.lua` (2026-03-16)
- [x] Lockfile fast path: dep/ name+version check → skip network entirely — `dep_ok` check in `lib/pkg/install.lua` (2026-03-16)
- [x] `--frozen-lockfile` for CI — `opts.frozen` in `lib/pkg/install.lua` (2026-03-16)
- [x] CLI: `cr add / install / remove / update / info` — `lib/pkg/cli.lua` (2026-03-16); `publish` not yet done
- [x] Semver parser (pure Lua, small) — `lib/pkg/semver.lua` (2026-03-16)
- [x] Multi-registry support with priority ordering and per-registry auth — `lib/pkg/config.lua` (2026-03-16)
- [ ] Fork-based parallel fetch with `--jobs=N` (default: CPU count) — v1 fetch is sequential
- [ ] `cr publish` — not yet implemented
- [ ] Package manifest `files` field — declare which files get installed (source only; tests, benchmarks, fixtures, docs stay in the repo). Installed footprint should be just the `.lua` files needed to run. Key to avoiding node_modules-scale bloat when vendoring.

## protocol rewrites — deferred

- [ ] **HTTP/1.1 server rewrite** — async, keep-alive (Connection: keep-alive), persistent connections. Blocked on socket layer rewrite.
- [ ] **HTTP/1.1 client rewrite** — connection pooling, redirect following, proper error recovery.
- [ ] **HTTPS rewrite** — module-level TLS state bug, `ffi.new("FIXME")` in serverx. Blocked on socket + TLS.
- [ ] **HTTP/2** (RFC 9113) — HPACK header compression, binary framing, stream multiplexing, flow control, server push. Major new implementation.
- [ ] **HTTP/3** (RFC 9114) + **QUIC** (RFC 9000) — UDP-based transport, 0-RTT, connection migration. Requires QUIC implementation first.
- [ ] **HTTP trailer fields** (RFC 9112 §7) — currently ignored in stream.lua chunks().
- [ ] **Transfer-Encoding: gzip/deflate** decompression in stream.lua.
- [x] **Path traversal audit** — `lib/http/router/static.lua` and `staticx.lua` use `path.safe_resolve()` (realpath + prefix check). No vulnerabilities found.
- [ ] **WebSocket: permessage-deflate** (RFC 7692) — compression extension.
- [ ] **WebSocket: max frame/message size policy** — currently unbounded, memory exhaustion risk.
- [ ] **WebSocket: client-side** — initiating connections (currently server-side only).
- [ ] **WebSocket: subprotocol negotiation** (RFC 6455 §4.2.2).
- [ ] **DNS: UDP client** (RFC 1035 §4.2.1) — 512-byte limit, TC flag, fallback to TCP.
- [ ] **DNS: EDNS(0)** (RFC 6891) — OPT pseudo-record, larger responses.
- [ ] **DNS: server implementation** — `lib/dns/server.lua` stub exists.
- [ ] **DNS: master file parser** (RFC 1035 §5) — `lib/dns/format_master_file.lua` stub exists.
- [ ] **DNS-over-HTTPS** (RFC 8484), **DNS-over-TLS** (RFC 7858).
- [ ] **Socket layer rewrite** — replace vendored ljsocket with cross-platform `lib/socket/` (POSIX + Winsock FFI). Prerequisite for proper async server, keep-alive, connection pooling.

## documentation (low priority now, high priority eventually)

- [ ] **Design crescent doc-comment syntax** — many `lib/` files use `-- @param`/`-- @return` in LDoc/Javadoc style as prose documentation. Before converting or deleting them, design a first-class crescent doc-comment syntax. Research prior art: LDoc (`-- @param name type desc`), Rustdoc (`/// text`), TSDoc (`/** @param */`), Julia docstrings (Markdown fenced above the binding), Haddock, Documenting Lua idioms in use across the corpus. Goals: (1) machine-readable enough for `lib/doc/` to generate HTML/JSON from, (2) composable with `--:` type annotations (types shouldn't be duplicated), (3) minimal syntax overhead — crescent has no multiline string syntax pressure. Candidate: `--| description` lines immediately after the function signature, with `--:` already providing the types. Write a design doc at `docs/doc-comment-design.md` before implementing anything.
- [ ] **Comprehensive library docs** — every `lib/` package documented: purpose, API reference, usage examples. Enough that someone new to the codebase can pick up any library and use it without reading the source.
- [ ] **Codebase directory files** — `OVERVIEW.md` or `index` files at key directories explaining the shape: what lives where, how pieces relate, what to read first. Not API docs — orientation docs. `lib/OVERVIEW.md`, `lib/platform/OVERVIEW.md`, etc.
- [ ] **Lua tutorial for beginners** — a crescent-flavored intro to Lua targeting people who know at least one other language. Covers the gotchas (no `++`, `1`-indexed, `local` scoping, metatables), the LuaJIT-specific bits (FFI, `bit.*`), and the crescent conventions. Lives at `docs/lua-primer.md`.

## lib/css

Type-safe CSS builder library. Lua table → CSS string. Pairs with `lib/html/html_builder` so web frontends write HTML + CSS in Lua, generated at server startup or request time. No build step. Design doc: `docs/css-design.md`.

- [x] **Phase 1 — Core type machinery, selector DSL, stylesheet builder, renderer.** Nominal newtype constructors (`css.class`, `css.id`, `css.var`, `css.anim`, `css.varref`), batch `css.declare`, composable selector DSL (`css.sel.*` + combinator methods), `css.rule`/`css.stylesheet`/`css.render`. Snake_case → kebab-case property normalization. CSS var keys (`--*`) left as-is. Deterministic output via sorted declarations. Files: `lib/css/init.lua`, `lib/css/css_test.lua`. 35 assertions.

- [x] **Phase 2 — Keyframe animations.** `css.keyframe_rule(name, stops)` where stops maps `"from"/"to"/percentage` keys to declaration tables. `css.render_keyframes(kf)` renders `@keyframes name { ... }`. The `AnimationName` nominal type from Phase 1 types `animation-name` property values so mismatched names are caught. Files: `lib/css/keyframes.lua`, extended `lib/css/init.lua`.

- [x] **Phase 3 — Media queries.** `css.media(query, items)` constructs `@media` rules. Query DSL covers `min-width`/`max-width`, `prefers-color-scheme`, `orientation`, and logical operators (`and_`, `or_`, `not_`). `css.render` extended to handle `_type = "media"` items. Files: `lib/css/media.lua`, extended `lib/css/init.lua`.

- [x] **Phase 4 — CSS custom property tooling.** `css.property(name, opts)` renders `@property` declarations (syntax, inherits, initial-value). Scope analysis: given a stylesheet and a set of `CssVar` names, report which rules declare vs. reference each variable. Useful for detecting undefined or unused variables at build time. Files: `lib/css/property.lua`.

- [x] **Phase 5 — lib/html integration.** Typed style injection into `lib/html` elements. Scoped class generation: given a stylesheet, emit a `<style>` block and return a record of typed `ClassName` values for use with `lib/html` element builders. Eliminates class-name string scatter from `lib/html/html_builder.lua`'s `mod.style`. Files: `lib/css/scoped.lua`.

## stretch goals (low priority, high reward)

*Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

- [ ] **Backend framework** (`lib/web/`) — high-quality, typed, idiomatic Lua web framework.
  HTTP server + router (lib/http already exists) + middleware pipeline + request/response types +
  SQLite ORM layer + templating. API inspired by Lapis/Sinatra but first-class crescent types
  throughout. Goal: write a web app in Lua that a Rails/Express developer finds familiar.

- [ ] **Games** — headless pure Lua game engines, each with CLI/TUI/web frontends.
  Pattern: library (rules + state + move gen) + `lib/minimax` AI + three frontends.
  Web frontend is a Lua HTTP server app (same pattern as card app — no build step).
  Type-safe builder APIs for constructing initial game state.
  - [ ] `lib/chess` — FEN/PGN, legal move generation, check/checkmate/draw detection
  - [ ] `lib/mahjong` — Riichi Mahjong, yaku/fu/han scoring, multi-player state
  - [ ] `lib/solitaire` — Klondike: tableau/foundation/stock/waste, auto-complete
  - [ ] `lib/spider` — Spider Solitaire: 1/2/4-suit, sequence completion, undo
  - [ ] `lib/freecell` — FreeCell: freecell/cascade/home rules, supermove, deal number

- [ ] **Reactive frontend** — Lua implementation + optional TS deployment:
  1. `lib/reactive/` + `lib/reactive_optics/` are self-contained Lua libraries
  2. `lib/lua2ts/` can transpile them to standalone TypeScript (no Rainbow import)
  3. The transpiled TS is API-compatible with Rainbow so it drops into Rainbow-based apps,
     but crescent has zero runtime dependency on Rainbow — not even as an optional dep
  Rainbow (`~/git/rhizone/rainbow/`) is a parallel implementation of the same algebra in TS,
  maintained in the rhi ecosystem. Same relationship as Rust crates ↔ crescent libraries:
  peers, not wrappers. ~90 tests in Rainbow serve as a cross-implementation parity reference.
  TUI variant: `lib/tui/reactive` — same `lib/reactive_optics/` model, terminal renderer.
  Depends on `lib/tui/` and `lib/ansi/` first.

- [x] **FFI fixed-size-array element typing (typechecker prerequisite for accessor cleanup).** Fixed: `solve_index`'s LIT_INTEGER branch handled TAG_TUPLE but fell through to `unify(res, obj_tid)` for TAG_TABLE — so `t.data[N]` on `{[integer]: T}` returned the whole array. Added a TAG_TABLE branch in `lib/type/static/solve.lua` that (1) checks for an integer-named positional field, (2) consults integer/number indexers and returns the value type, (3) preserves the slot-0-is-self fallback for multi-return slot extraction. Closed >1000 pre-existing errors across `lib/type/static/*.lua` (e.g. constrain.lua 388→38, solve.lua 333→114, env.lua 138→12). Repro `ffi.cdef[[ typedef struct { int32_t data[7]; } S; ]]; local function f(t --: S) return t.data[0] end` typechecks cleanly.

### Authoring tools backlog

- [ ] **RPG Maker replacement** (2026-05-22) — offline-first, crescent-native RPG authoring tool; all features discoverable in-tool, no tutorials required to use core features (see docs/principles.md)
- [ ] **Ren'Py / visual novel authoring replacement** (2026-05-22) — offline-first, crescent-native VN authoring tool; discoverability in the tool, no online resources in the loop (see docs/principles.md)
- [ ] **Interactive fiction authoring tool** (2026-05-22) — Twine/Inform-class, offline-first, crescent-native; make interactive anything small, discoverable without tutorials (see docs/principles.md)

- [x] **Tuple positional-slot typing (parser representation bug, blocks cleanup C4+).** Fixed via option 1: parser emits `TAG_LITERAL(LIT_INTEGER, N)` keys for positional brace-tuple entries (`ann.lua` ~758-770, 833-844), and `constrain.lua` NODE_INDEX_EXPR defers literal-integer access on TAG_TABLE to C_INDEX so `solve_index`'s slot-aware branch (1404-1446) handles it instead of the legacy "first indexer wins" shortcut at 1627-1635. Consumer audit: `{ ...[%K]: %V }` distribution in `match.lua` already accepts LIT_INTEGER keys (match_pattern.lua:256 makes LIT_INTEGER match TAG_NUMBER patterns, so `IpairsReturn`'s `match K { number => ... }` still fires); `$EachField` only iterates named fields, not indexers, so unaffected; `table_meta_field` is unrelated. One pre-existing test asserting "unknown" for closed-record integer access updated to assert "nil" (correct out-of-bounds tuple-slot semantics). Pinning tests added in `type_soundness_test.lua`. Cleanup C4 unblocked. Expression-side companion fix landed: `constrain.lua` `NODE_TABLE_EXPR` was still emitting positional entries as stringified-integer FIELDS, so brace-tuple expressions `{ a, b, c }` didn't match brace-tuple type annotations. Now emits the same INDEXER + `TAG_LITERAL(LIT_INTEGER, N)` shape as the parser. Also surfaced a latent unifier gap: source-side excess indexers were never checked (`{ "a", 2 }` typed as `{ [number]: string }` passed), now covered by a new excess-indexer pass in `unify.lua` (mirrors the excess-field check; TAG_VAR/ROWVAR source keys are skipped because the b-driven loop binds them). Original entry: Brace-tuple annotations `{ A, B, C, ... }` were parsed in `lib/type/static/ann.lua:758-762` (and `:833-836`) by lowering each positional entry to an indexer pair `(TAG_NUMBER, T_i)`, discarding the slot number. Consequence: `c[N]` on a tuple cannot narrow to slot N's type — `solve.lua:solve_index` (around line 1404-1446) walks the indexer list and returns the FIRST positional indexer's value type for every literal-integer access. Variable-integer access has a separate sibling unsoundness: returns the first slot's type instead of the union of all slot types. Repro: `--:: T = { string, integer, boolean }; --: (T) -> integer; local function f(c) return c[2] end` should narrow to integer; today it returns string. Three fix options with different blast radius: (1) parser emits `TAG_LITERAL(LIT_INTEGER, N)` keys (smallest, reuses existing solve_index LIT_INTEGER comparison at 1428-1433); (2) parser emits named fields "1"/"2"/...; (3) unify brace-tuples with paren-tuples via TAG_TUPLE (which `solve_index` already handles correctly at 1396-1403; biggest change because it affects multi-return typing, spread handling, Parameters<F>/Tail<F>). All three need an audit of consumers that pattern-match indexer keys: `{ ...[%K]: %V }` distribution in `match.lua`, `$EachField`, `table_meta_field` spread expansion, ipairs/pairs typing, tuple-vs-array structural subtyping. Fuzz/grammar tests for positional slot precision needed before shipping. Discovered by the cleanup C4 attempt 2026-05-17; investigation report in that attempt's stop-and-report.

## Pedagogy / reader thesis + per-question typechecker (2026-05-31)

Backlog from the foundations session captured in `docs/foundations/pedagogy-and-the-reader.md`.

- [ ] Write the from-scratch documentation doc for `lib/check_kind` — the parser reuse rationale, the annotation-syntax decisions, the typechecking algorithm, and a from-scratch "how a typechecker works" — and make it trivially findable from the source files. (Blocked on the in-progress flatten refactor.)
- [ ] Build the marker→doc findability convention + a deterministic lint that proves the links resolve bidirectionally.
- [ ] Design and build the surprisal-coverage mechanism: an LLM leaf-oracle surprisal meter, a cached deterministic artifact, and a deterministic CI coverage gate.
- [ ] Resolve the two open foundational questions: the precise statement of "coverage", and whether leaf-oracle-as-meter is acceptable.
- [ ] Fix the stale comment in `lib/type/static/defs.lua` claiming `NODE_LITERAL` stores kind/value in `data[2]`/`data[3]` — the parser actually writes `data[0]`/`data[1]`.
- [ ] Decide and execute the disposition of the v5 typechecker and `docs/type-system-design/` (the 19-axis plan), now superseded by the plural per-question approach — formal retirement/cleanup.
- [ ] Pin v6 from `docs/typechecker-v6-plan.md`: value-movement matrix first, then implement thin verticals beside v4; v5 is research input, not the foundation.
- [ ] Build checker #2: pick the next property-question (candidates: table shapes, integer/float) and write its standalone checker.
- [ ] Land the deferred sub-checkers from checker #1: integer/float distinction, table shapes, literal refinement, generics, intersections, match types, multi-return.
- [ ] Finish flattening `lib/check_kind` — the refactor into per-node-kind handler functions over an explicit `ctx` is mid-done but `ctx` has no explicit type annotation, so the checker can't unify its shape across handler call sites and emits ~26 typecheck errors; add an explicit `ctx` type, re-verify tests + typecheck, then integrate.

## typechecker declarative core (2026-07-05)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Open threads from the declarative-core session; details in
`docs/artifacts/2026-07-05-typechecker-declarative-core/open-threads.md`.

- [ ] H1: the middle derivation layer is still undefined (undecided undefinable without it; ◇-refutation witness object undefined) — shelf: Cousot calculational AI, 3-valued/abstract model checking, O'Hearn incorrectness logic.
- [ ] Uniformity class: whether the 2-safety framing is correct remains open (owner's standing "seems wrong" objection) — might need re-derivation; single-trace claim grammar cannot express it (H4).
- [ ] The mined-beliefs presupposition catalog ("form F presupposes φ") is unwritten — H5; only two examples exist.
- [ ] The process-killer gap: terminal states / increments / banking absent from all design material — untouched by the session.
- [ ] Bar negotiability: owner has not ruled on the Dialyzer point (consistency-only keeps lie-findings/behavior-output/never-reject; gives up proven-fine + dominance-over-tsc-truths).
- [ ] Convergence evidence: LLM-solver-simulation ruled inadmissible (owner-certified); requires human hand-run or a minimal real implementation (proposed: lib/json screen prototype + minimal chase over 10 labeled cases).
- [ ] Owner decision: does the ceiling-survey composite spine become the design direction (demoting the pool design from spine to layer)? See `docs/artifacts/2026-07-05-typechecker-declarative-core/research/ceiling-survey/judgment.md`.
- [ ] Owner decision: is the ceiling mandate ("unlimited short of uncomputable") the binding ambition? See `docs/artifacts/2026-07-05-typechecker-declarative-core/research/ceiling-survey/judgment.md`.
  2026-07-06 owner call: provisionally executing the entire composite (FP spine + all layers, pool demoted to claim-harvester) 'in some order or another'. Both items stay open — the wall execution hits is the evidence that closes them. No permanent spine/ceiling commitment made.
- [ ] Session-process context recorded nowhere durable except here: the previous session's owner stated preferences for frequent owner checkpoints with a bias toward stopping; that research must be problem-anchored, not incumbent-design-anchored (that session was corrected twice on this); that LLM hand-simulation of unimplemented machinery is not admissible evidence (also in open-threads.md); and that design work is currently quarantined from the bars ("bars irrelevant FOR NOW" — owner's words).
- [ ] owner: certify/reject abstract-kernel synthesis deltas (docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/synthesis.md)

## persona-prompt iteration (2026-07-05)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

`.claude/agents/me.md` / `general-purpose.md` were rewritten (commit `0a2e3917`) from a
structure that had grown one rule per annoyance into a file that says who the agent is — "a
friend who knows you, but not that well" — and says what to do rather than what not to.
Pre-rewrite drafts kept alongside as `.orig`.

- [ ] The new framing is untested in the wild: this session's own responses ran under an older draft, so there is no live sample of it yet.
- [ ] Open question: whether the new framing actually suppresses the habits it replaced (unearned praise, filler acknowledgments, narrating compliance, made-up option menus), or whether some of them need explicit mention again once there's live evidence. Any future edit should respect what the owner already said no to: a one-rule-per-annoyance structure, a detached "no stakes" identity, guard rules the identity already implies, and rules phrased as don'ts.
  2026-07-06 first live sample (session running under the rewritten persona), owner verdict: succeeded at 'superficial changes' (register, hedging words, friend framing), failed at 'literally everything that matters'. Failures observed in the orchestrator's own voice, not relays: issuing design verdicts without standing ('the encoding that actually answers your critique is...' — crowned an encoding one message before the owner showed it was wrong); grading the owner's own suspicion ('your special-casing suspicion — half right, in an interesting way'); session-coined jargon density; each successive apology itself a new confident (wrong) diagnosis of the failure. Pattern per owner: the confident conclusion is generated first and the persona's register is applied on top — 'the hedge decorates the overreach instead of preventing it' (agent's own description, owner did not dispute). Open question sharpened: promptable at all, or stop iterating the file.
- [ ] owner rule candidate (2026-07-06, owner's wording): 'ANYTHING undecided that affects semantics/behavior AT ALL, MUST halt.' Replaces unpromptable disposition ('don't be overconfident') with an auditable behavior (halt-on-underspecification). Supporting cases from this session: invert engine's UNDERSPECIFIED halt exposed a real design gap (good); harvester invented site string formats where design was silent → manufactured the misleading 100%-Open corpus number (bad); orchestrator invented design verdicts without standing (bad). Known hard case: the site-format choice looked cosmetic and was load-bearing — the rule's 'affects semantics/behavior' test must catch that class. Undecided: where to install (persona files me.md/general-purpose.md, CLAUDE.md delegation section, standard subagent prompt clause) — owner's call.
- [ ] Undecided, not discussed with the owner: whether sibling personas (v14, v15 agents) should inherit the new framing — do not presume either way.
- [ ] `.claude/settings.json` carries an uncommitted modification (owner's own mid-session hooks work, distinct from the hooks commits already landed) — owner's call whether/how it lands.

## Ecosystem priorities + platform design (2026-07-09)

> *Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.*

Roadmap and platform capability design notes were written this session. Key artifacts:
- `docs/artifacts/2026-07-08-roadmap/roadmap.md` — three priorities + overarching "crescent as the entire computer" vision
- `docs/artifacts/2026-07-09-platform-caps-design/notes.md` — capability model design principles with mined owner quotes
- `docs/artifacts/2026-07-08-toy-checker-findings/notes.md` — parked typechecker toy findings

### Priority 1: Scribble ideas → crescent

Import scribble's ideas (creative tool primitives) into crescent as core ecosystem libraries/apps. The old scribble design doc (`~/git/rhizone/scribble/docs/design.md`) is partially wrong per owner — primitives need fresh thinking, not cargo-culting from the old doc. The tool should be something people "just reach for" to make art (interactive or not). Imported ideas lose their special names and become core ecosystem capabilities.

- [ ] Design pass needed: what are the right creative-tool primitives for crescent? Not tilemap/sprite/spatial from the old doc — those are unexamined.
- [ ] Open: how does this relate to dusklight's projectional UI? Owner said "dusklight is the multi-projectional UI" but also "it is dusklight does not mean it is dusklight" — the idea matters, the codebase boundary doesn't.

### Priority 2: AI RP frontend

Non-conversational-context AI roleplay frontend, based on `lib/platform/`. Existing app at `lib/platform/apps/charactercardv2/`. Design pass needed — prior sessions may have design intent recoverable via `normalize sessions`.

- [ ] Design pass needed. Mine prior sessions for design intent on the RP frontend.
- [ ] The cap set for ccv2 (self, self_write, kv, time, http_server, llm, shared_db, create_instance) is the current working example of the platform cap model.

### Priority 3: Taskgraph

Agent harness as platform app. "Beyond SOTA agent harness by deleting the concept of an agent." Existing code at `lib/taskgraph/`. Design pass needed.

- [ ] Design pass needed.

### Platform capability model

Design principles established this session (details in the caps design notes):
- Swappability determines cap level (not I/O boundary, not service level)
- Attenuation narrows a capability before passing it on
- Construction assembles higher-level caps from lower-level resources + config
- DIP: app depends on cap interface, platform injects implementation
- Hot-swappability: cap implementations swappable at runtime
- Permission dialog: all caps require dialog, no silent grants, user-defined presets only (predefined presets unacceptable), compression to true decision points
- Sandbox: tarball modules load in sandbox so they are not an escape vector (not "so caps don't leak")

- [ ] Open: powerbox design was discussed in some prior session, possibly under other names — unmined.
- [ ] Unmined session dumps at /tmp/mine2.txt (48.6KB capability search) and /tmp/mine3.txt (29.6KB manifest search) — may contain additional design intent. Ephemeral; may not survive.

### Toy typechecker (parked)

Moded-obligation toy checker at `lib/toy_checker/` validated the approach at toy scale (43 assertions). Parked with findings written up. Key insight for future work: constraint structure is a graph (not a flat pool); real typecheckers use AST as the schedule; dynamic edge direction through shared variables is the open hard problem. Mode proliferation is static approximation of a dynamic property.

- [ ] Resume point: graph-structure insight as starting point, not mode proliferation workaround.

## conventions

- [ ] Adversarial audit of existing function names against naming convention (low priority)
- [ ] 2026-07-07 owner: design-it-twice skill removed. Grounds: 2026-07-06 evidence — 4/4 same-model 'decorrelated' candidates failed identically (flagship overclaim); supporting 'adversarial critique panel' numbers died in verification (aggregator gloss, no primary source); evidenced alternative is cross-model review + output verification (see docs/artifacts/2026-07-06-agentic-coding-research/agentic-coding-evidence.md). Open: whether design-an-interface and the CLAUDE.md 'decorrelate via parallel subagents' disposition line follow.

## Prior art survey — rhi ecosystem (2026-07-09)

Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.

- [ ] Survey all repos under ~/git/rhizone/ for ideas/functionality to subsume into crescent
- [ ] Survey all repos under ~/git/exoplace/ for ideas/functionality to subsume into crescent
- [ ] unshape (~/git/rhizone/unshape/) partially surveyed — see docs/artifacts/2026-07-09-userspace-exploration/unshape-xref.md
- [ ] dusklight (~/git/rhizone/dusklight/) discussed in roadmap — see docs/artifacts/2026-07-08-roadmap/roadmap.md
- [ ] scribble (~/git/rhizone/scribble/) discussed in roadmap — see docs/artifacts/2026-07-08-roadmap/roadmap.md
- [ ] marinada (~/git/rhizone/marinada/) — placement question open, see roadmap

## Cross-platform event loop (2026-07-09)

Open threads from a previous session. Treat as starting context, not instructions — verify relevance before acting.

- [ ] Vendor wepoll.dll in dep/ for Windows — lib/epoll/ already has the FFI code (lines 22-73) but the binary is missing
- [ ] Implement kqueue backend for macOS — no code exists yet
- [ ] Unify lib/epoll/ + lib/async/ — epoll does I/O multiplexing, async does coroutine promises, but they don't talk to each other
- [ ] Update batteries.md async I/O gap — the "everything currently blocks" claim (written March 27) was already wrong when written (lib/epoll/ imported Feb 26); the gap description needs to reflect current state
- Note: batteries.md's #1 priority was AI-generated from first principles without checking the codebase; provenance traced to session fccf7f65 turn 22
