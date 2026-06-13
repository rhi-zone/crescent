# Static Analysis Map

This document names the current static-analysis artifacts and their authority.
It exists to prevent old typechecker tracks from regaining authority by
accident.

## Status

Static analysis is not one linear `vN` track.

The current map is:

- `v4`: the running Crescent checker.
- `v5`: abandoned architecture and prior-art mine.
- `v6`: design exploration, not an implementation target.
- `v7_mr0`: prototype residue, not a product direction.
- `framework`: rejected proof/evidence direction, retained as prior art.
- `agnostic static analysis`: active design direction, not yet implemented.

No artifact becomes canonical merely because code exists for it.

## v4

`lib/type/static-v4/` is the checker that currently runs.

Authority:

- may be patched for concrete user-visible bugs;
- may be used as a behavior corpus;
- may be mined for feature inventory and failure cases.

Limits:

- not a model for the future architecture;
- not trusted as a soundness proof;
- not evidence that a feature belongs in the next system.

## v5

`lib/type/static-v5/` is abandoned.

Authority:

- useful for mining decisions, failed attempts, and test cases.

Limits:

- not a target for repair;
- not a source of architectural authority;
- not a reason to preserve operational-semantics machinery.

## v6

The v6 documents are design exploration.

Authority:

- useful as recorded reasoning and rejected/viable alternatives.

Limits:

- not an implementation target unless a later document explicitly re-adopts a
  piece with a project-relative reason;
- not a bridge from v5 to product code.

## v7 MR0

`lib/type/v7_mr0/` and the v7 MR0 documents are prototype residue.

Authority:

- evidence replay experiments;
- canonical serialization experiments;
- examples of premature theory-specific commitment.

Limits:

- dead as "the next Crescent typechecker";
- not a product direction;
- not a license to implement more v7 features.

Terms such as `scope_from` belong to this prototype/framework experiment space.
They should not drive implementation.

## Framework

`lib/type/framework/` and `docs/typechecker-framework*.md` are rejected as the
static-analysis direction.

Authority:

- useful for mining ideas about data formats, replay, canonicalization,
  evidence, and oracle boundaries;
- useful as negative/falsification material for a future static-semantics
  design.

Limits:

- dead as "the next Crescent typechecker";
- dead as the current type-system-agnostic framework direction;
- not a Crescent typechecker;
- not a source of Crescent semantics;
- not automatically the right architecture just because it is more general.

New framework implementation work should not happen. The active agnostic static
analysis direction must not inherit this artifact's assumptions, terminology, or
implementation shape by default.

Why it was rejected, what it had validated, and the substrate-independent
findings the agnostic direction must preserve:
`docs/typechecker-framework-postmortem.md`. The short version: rejected on
judgment of premature theory-specific commitment, not on a demonstrated defect —
it reached its STLC-capable binder-replay milestone with tests.

## Agnostic Static Analysis

The active design direction is a fully agnostic static-analysis substrate.
Entry point: `docs/agnostic-static-analysis-design.md`. The durable *position* —
what this typechecker is as a design stance (sound, coverage-gradual, modular) —
is stated in `docs/typechecker-design-thesis.md`.

It is not a Crescent checker first. It should be able to host static semantics
for very small calculi, for conventional typed languages, and eventually for
Crescent/Lua. Crescent is a client and stress test, not the defining center.

Authority:

- should be designed from first principles rather than from v4/v5/v7/framework
  implementation residue;
- should treat v4/v5/v6/v7/framework material as evidence, examples,
  counterexamples, and prior decisions, not authority;
- should make language-specific semantics explicit as hosted definitions rather
  than built into the substrate.

Current status: the object model is settled
(`docs/agnostic-static-analysis-object-model.md`), the propositional,
untyped-lambda, cyclic/fixpoint-evidence, and STLC validation passes are written,
and **mechanization has landed through STLC**. The code lives in
`lib/type/analysis/`: the substrate (`init.lua`), four independent hosted
semantics (`prop.lua` = `prop.logic.min`, `lambda.lua` = `lambda.untyped.min`,
`dataflow.lua` = `dataflow.reach.min`, `stlc.lua` = `stlc.min`), and tests
(`prop_test.lua`, `lambda_test.lua`, `dataflow_test.lua`, `stlc_test.lua`,
`substrate_test.lua`, 153 assertions) that mechanize every worked example plus
the un-falsifiable-on-paper probes (claim identity, scheduling
order-independence, cycle termination, unknown propagation, adversarial
smuggling, fixpoint witnessing, deep derivation trees, claim-identity-under-
context). Mechanization findings are recorded in the object-model and four
validation docs. The STLC rung (`docs/agnostic-static-analysis-stlc.md`)
introduced the first hosted `type` vocabulary, typing contexts, and deep
derivation trees with **no substrate change** — types and contexts ride
`ArgValue` claim args, and structural substrate claim identity is exactly right
for context-dependent judgments. The tiny Crescent slice (ladder rung 5, the
final rung) is now **fully mechanized** (all five passes DONE, 2026-06-12) in
`lib/type/analysis/{slice_ty,slice_subtype,slice_ty_arg,crescent_slice,
crescent_slice_parse,slice_narrow,crescent_slice_lower}.lua` (+ tests), per
`docs/agnostic-static-analysis-crescent-slice.md` (`crescent.slice.v1`, the first
consumer of the ratified kernel). **Pass 5** added the statement-lowering frontend
(`crescent_slice_lower.lua`): real Lua source text → artifact + claim/evidence
graph end-to-end, the gap the survey exposed. The load-bearing corpus run is now
the lowered path (`corpus_lower_test.lua`): 2/11 fixtures CLEAN, 9/11 OUT-OF-SUBSET
with 0 rejections anywhere — the honest data the hand-built `corpus_test.lua`
(retained as evidence-method unit tests) had assumed away. No substrate change
across any pass. **Mechanization through the whole ladder is complete**;
`lib/type/analysis/` now holds the slice's seven modules and a subtype benchmark.

Rung status (ladder, design doc):

- 1 propositional — mechanized.
- 2 untyped lambda — mechanized.
- 3 cyclic/fixpoint-evidence — mechanized (`dataflow.reach.min`); substrate
  unchanged, witness model holds.
- 4 STLC — mechanized (`stlc.min`); substrate unchanged. Hosted `type`
  vocabulary, typing contexts, and deep evidence trees all hosted; arg-schema
  open item closed (no schema mechanism, no identity override needed).
- 5 tiny Crescent slice — **mechanized** (all five passes DONE, 2026-06-12;
  `docs/agnostic-static-analysis-crescent-slice.md`, `crescent.slice.v1`). First
  consumer of the ratified kernel (`docs/decisions/kernel-recommendation.md`):
  bidirectional synth/check spine, ONE cycle-guarded equirecursive (hash-consed μ)
  subtype relation, local generic instantiation as witnessed evidence, separate
  flow-narrowing layer. v1 type grammar derived whole from the Lua value universe;
  `for-in` decided (`pairs`/`ipairs` + numeric included, general iterator protocol
  deferred). Capability-reachability and imperative-store pressure absorbed here
  (stores handled flow-insensitively by check-against-declared-element-type).
  **Pass 5 added the statement-lowering frontend** (`crescent_slice_lower.lua`):
  source text → claim/evidence graph end-to-end, §5 subset only, out-of-subset
  statements construct-tagged (never silently skipped). The production Lua parser
  was NOT reused (too coupled to its FFI arena); a focused §5 lexer+parser instead.
  Code in `lib/type/analysis/{slice_ty,slice_subtype,slice_ty_arg,crescent_slice,
  crescent_slice_parse,slice_narrow,crescent_slice_lower}.lua` (+ tests +
  `slice_subtype_bench.lua`).
  **Corpus result (Pass 4, hand-built): all 11 fixtures Accept (0 errors)**
  (`corpus_test.lua`, the §7 grading run, now an evidence-method unit test); the five
  legacy REMAINS gaps
  (boolean `and`, closure return-slot, table-widening, redundant-cast, hamt
  tag-narrow) all closed, the six FIXED guards held. The substrate (`init.lua`) was
  **not touched** across any pass — the ladder's falsifiable bet settled at target.
  **Adversarial audit round 1 (2026-06-12): 5 findings fixed** (well-formedness now
  a hard precondition; `lit_int` integer validation; `unknown` narrowing; subtype
  DAG memoization; `instantiate_witness` callee binding), each a permanent
  regression test (§9.7).
  **Adversarial audit round 2 (2026-06-12): 4 findings fixed** (F1 collision
  detection between exporters; F2 mutual-alias claim retracted, §6.6.4 corrected;
  F3 malformed-path hardening; F4 content digest in dependency records), 33 new
  regression tests, 6226 total (§9.11).
  **Adversarial audit round 3 (2026-06-12): 1 unsound + 2 precision fixed** (F1
  module-table rebind resets accumulated rec; F2 fewer-param closure into wider fn
  slot now accepted — arity decision pinned in §6.8.3; F3 trivial direct-alias
  propagation fixed, conditional/wrapped forms remain documented deferrals), 46 new
  regression tests, 6374 total (§9.14).
  **Survey pass landed (2026-06-12): `slice_survey.lua` over the 864-file real `lib/`
  corpus** (`docs/slice-survey-v1.md`) — 26.6% CHECKED-CLEAN, 1.6% CHECKED-FINDINGS,
  58.4% OUT-OF-SUBSET, 13.3% NO-ANNOTATION, 0 timeouts/crashes. The annotation
  adapter now emits out-of-subset construct tags; the demand histogram (v2's build
  order) is led by named parameters (266 files), cross-module/unresolved type
  aliases (232), `self` parameters (128), and `T[]` array shorthand (88). The survey
  is a reusable measurement tool, re-run after every v2 increment.
  **End-to-end survey (`slice_survey.lua --e2e`): 0.6% CHECKED-CLEAN** (5 files),
  98.7% OUT-OF-SUBSET, **0 TIMEOUT** over 868 files. The whole-file CLEAN number is
  gated by each file's LAST out-of-subset construct; the load-bearing delta is the
  CONSTRUCT histogram. **Slice v2 increment 3** (§6.7) landed the top of that
  histogram — operator typing (`synth_binop`/`synth_unop`, metatable-free; the
  metatable cases are out-of-subset deferrals, never errors), assignment forms
  (multi-assign/swap/indexer-write), method calls (`o:m()` desugar), unannotated
  functions (params `unknown`, body-synthesized return), and an injected stdlib cap
  (caps-first). `operator-concat`/`operator-arith`/`method-call`/named-`unannotated-
  function` all DROPPED OUT of the ranking; the new front is globals
  (`unbound-name:package`/`require`/`table`), assignment/multi-return forms, and
  anonymous closures. Two new evidence methods only; substrate untouched. The
  `require`-returns-module-VALUE-type synthesis + broader globals model is the
  dependency-honest TAIL (§9.12/§10.4). **Slice v2 increment 4** (§6.8) landed exactly
  that tail — the extended stdlib globals cap, expression-position closures with
  check-mode typing (the expected `fn` param types pushed inward), and
  `require("lib.y")`-returns-the-module-VALUE-type synthesis (the M-table `rec`
  accumulated over `function M.f`/`M.f = …`, resolved by recursively lowering the
  exporting module through the existing xmodule machinery, shared-PTy-cache memoized).
  ZERO new evidence methods. The whole-file **e2e CHECKED-CLEAN broke off the
  increment-3 floor: 5 → 22 (0.6% → 2.5%), ~4.4×, 0 TIMEOUT**. A timeout root cause
  (un-memoized recursive precompute, `check.lua` 74.76s → 0.79s after a shared cache)
  was found and fixed. Earlier findings: a parser non-termination (FIXED) and a
  substrate-scaling TIMEOUT (FIXED, content-addressed keys). See
  `docs/slice-survey-v1.md` "after v2 increment 4". **Slice v2 increment 5** (§6.9)
  landed the multi-return / dynamic-index statement family (the e2e histogram's top
  after incr 4: `dynamic-index` read, `multi-return` statement, `dynamic-index-assign`,
  `multi-assign` with method-call last value): dynamic-key reads reach `index_result`
  (a new closed-rec-under-dynamic-key result rule, `union(fields)|nil`, the closed-row
  dual of the open-row `unknown`); the `return a, b` statement builds the §6.5.5 tuple
  (one new evidence method, `synth_tuple`, the dual of `synth_table`); `flatten_values`
  spreads any multi-return last value (method-call / field-call), and homogeneous
  closed-rec dynamic writes check `v ⇐ V`. Substrate untouched. **e2e CHECKED-CLEAN
  22 → 25 (2.9%)**; the per-construct demand fell sharply (`multi-return` 482 → 317,
  `dynamic-index` 589 → 512). The heterogeneous closed-rec dynamic write and the
  body-synthesized multi-return join are recorded §9.15 deferrals. See
  `docs/slice-survey-v1.md` "after v2 increment 5". **Slice v2 increment 6** (§6.10)
  burned down those deferrals — diagnosis-first, and the diagnosis was the result: a
  per-MARKER reason histogram showed the named deferrals were the wrong shape
  (§9.15.4 is 2548-empty / ≈1-heterogeneous), dead (§9.15.5 `return f()` spread, 0
  corpus sites), or downstream coverage symptoms (`multi-assign`/`multi-return` block
  on argument/value expressions, not the landed mechanism). The one sound in-fence
  item: the empty-fresh-table dynamic write (`out = {}; out[k] = v`), `index_write_target`
  over an empty closed rec ⇒ `unknown` (the WRITE dual of the open-row rule). One
  branch, no new method, substrate untouched. **e2e CHECKED-CLEAN 25 → 26**;
  `dynamic-index-assign` fell #2 → #4 (482 → 282 files; −2548 markers). See
  `docs/slice-survey-v1.md` "after v2 increment 6".

Limits:

- the propositional, lambda, cyclic/fixpoint, and STLC rungs are mechanized (the
  tiny Crescent slice is next); fixpoint *acceptance* via post-hoc witnesses is
  demonstrated (`dataflow.reach.min`), and the substrate hosts mutually-dependent
  claims without accepting circular justification;
- not the existing `lib/type/framework/`;
- not a universal inference engine by assumption;
- not allowed to smuggle Crescent-specific rules into the substrate.

## Acceptance/Falsification Corpus

`lib/type/analysis/corpus/` — kernel-agnostic fixture set for the tiny Crescent
slice rung (ladder step 5). Eleven minimal self-contained `.lua` fixtures encoding
documented legacy-checker failures with expected-correct verdicts; `corpus.md`
is the manifest with source fire references, feature families, and actual
legacy-checker verdicts from `bin/cr check`. Five fixtures expose REMAINS gaps
(active in current checker); six are FIXED regression guards. The corpus orders
the slice's tests, never its design. See `docs/agnostic-static-analysis-design.md`
§"First Validation Ladder" for the methodological rule.

## Crescent Static Semantics

Crescent static semantics is a later hosted design, not the root direction.

It may eventually define Crescent-specific judgments, effects, tables,
mutation, metatables, modules, annotations, guards, overloads, and escapes. It
should be designed against the agnostic substrate only after that substrate's
shape is clear enough to avoid another ad-hoc checker.

## Working Rule

Before coding static-analysis work, name which artifact is being changed.

Use this status language:

- `patch v4`: fix the running checker.
- `mine prior art`: read v4/v5/v6/v7 for decisions or failures.
- `design agnostic static analysis`: work on the first-principles substrate.
- `design Crescent static semantics`: make a Crescent-specific hosted-semantics
  decision only after the substrate boundary is clear.

If the work cannot be named as one of those, stop and write the missing framing
first.
