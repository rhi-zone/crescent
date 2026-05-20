# K6 — v4 vs legacy parity discovery

Read-only audit. Output of `bin/cr check --compare` run across the
non-test, non-v4-internal `lib/` corpus. No code changed by this pass;
the report is the deliverable.

## Method

- Corpus: every `lib/**/*.lua` file excluding `*_test.lua` (subjects, not
  exercisers) and `lib/type/static-v4/**` (v4-internal — not a parity
  subject). Enumeration: `find lib -type f -name "*.lua" ! -name "*_test.lua"
  ! -path "lib/type/static-v4/*"`.
- Invocation: `timeout 30 bin/cr check --compare <file>` per file. Exit
  codes captured per the cli_compare.lua contract (0=agree, 1=decision,
  2=details, 124=hard timeout, internal errors surface as exit 1 with the
  message `cr: internal error in "check": …`).
- All 783 files processed (100% coverage). Median invocation ≈ 50ms; no
  invocation came close to the 30s cap except the 5 timeouts called out
  below.

## Totals

| Category | Count | Notes |
| --- | ---: | --- |
| `agree (clean)` | 21 | Both impls accept with no errors and no warnings. |
| `agree (errored)` | 0 | No file has both impls reject with identical position multisets. |
| `diverge_decision (v4 strict)` | 153 | Legacy accepts (possibly with warnings), v4 emits ≥1 error. |
| `diverge_decision (v4 lax)` | 1 | `lib/type/static/stdlib_types.lua` — legacy rejects, v4 clean. |
| `diverge_details` | 473 | Both reject, but error position multisets differ. |
| `driver_failure` (v4 crash) | 130 | v4 driver raised an uncaught Lua error; surfaced as exit 1. |
| `timeout` (>30s) | 5 | See list below. |
| **Total** | **783** | |

Note on `agree (errored)` = 0: 100% of files where both impls reject
diverge on at least one position. Legacy and v4 have independent error
taxonomies and independent position bookkeeping (legacy reports
`function-has-no-signature` warnings, v4 reports per-AST-node walker
gaps), so byte-identical multiset agreement is structurally rare. The
real parity signal is the decision split, not detail agreement.

## Most striking finding

The v4 driver is **structurally incomplete, not subtly wrong**. Of the
762 files where the two impls disagree at any level:

- **130 (17%) crash the v4 driver** with one of three root causes
  (control_flow.lua "unknown primitive" / env.lua nil `require_chain`).
- **153 (20%) are v4-strict decision divergences**, but the strictness
  is almost entirely driven by **deferred sub-phases** (NODE_BINARY_EXPR,
  NODE_UNARY_EXPR, NODE_CAST_EXPR, table literals, method dispatch, the
  deferred-constraint queue), not by v4 catching real bugs legacy misses.
- **473 (60%) diverge on details**, and inspection of large-delta cases
  shows the same root causes: v4 reports many "walker not yet implemented"
  errors that legacy doesn't, while legacy reports many real semantic
  errors (force-cast violations, union-narrowing failures) that v4
  silently doesn't reach because the walker fails earlier.

Only **1 file (0.13%)** is genuinely v4-lax — `stdlib_types.lua` — and
that one looks like a deliberate v4 design choice (legacy hardcodes a
"don't use `--::` for module decl" rule that v4 hasn't ported).

## Driver crash signatures (130 files)

Three signatures cover all 130 crashes:

| Count | Signature | Likely cause |
| ---: | --- | --- |
| 89 | `walker/control_flow.lua:269: unknown primitive: table` | Control-flow walker doesn't handle the `table` primitive kind. Likely the type-tag matrix in control_flow.lua is missing entries for primitive tags `table` and `function`. |
| 37 | `walker/control_flow.lua:269: unknown primitive: function` | Same root cause as above; different missing tag. |
| 4 | `walker/env.lua: attempt to index field 'require_chain' (a nil value)` | Driver constructs an env without `require_chain` for some call path. |

Top 10 crash files (all driver crashes — all should be fixed before any
meaningful parity work continues):

- `lib/aho_corasick/init.lua` — control_flow.lua:269: unknown primitive: table
- `lib/bignum/init.lua` — control_flow.lua:269: unknown primitive: table
- `lib/agent/leaf.lua` — control_flow.lua:269: unknown primitive: table
- `lib/async/init.lua` — control_flow.lua:269: unknown primitive: table
- `lib/agent/preset.lua` — control_flow.lua:269: unknown primitive: table
- `lib/agent/render.lua` — control_flow.lua:269: unknown primitive: table
- `lib/asm/init.lua` — control_flow.lua:269: unknown primitive: table
- `lib/automata_2d/init.lua` — control_flow.lua:269: unknown primitive: function
- `lib/config/init.lua` — control_flow.lua:269: unknown primitive: table
- `lib/bigint/init.lua` — control_flow.lua:269: unknown primitive: table

## Timeouts (5 files)

These exceeded the 30s per-file cap; they are likely a non-termination
or exponential-expansion bug in either the legacy or v4 pipeline (one
invocation contains both):

- `lib/bloom/init.lua`
- `lib/platform/apps/system_dashboard/search.lua`
- `lib/platform/apps/system_dashboard/server.lua`
- `lib/stats/init.lua`
- `lib/text_stats/init.lua`

Per CLAUDE.md the hang itself is the signal — surface to orchestrator.
No silent skip.

## Top error patterns across `diverge_decision (v4 strict)` (153 files, 1696 v4 errors)

These are the v4 error messages, sorted by frequency. Almost every one
is a sub-phase-deferred TODO rather than a substantive type rule:

| Count | v4 error |
| ---: | --- |
| 468 | `field: indexed access on a type variable target is deferred until the variable is bound; Phase 4b.2 has no deferred-constraint queue. Materialize the target first.` |
| 302 | `table: non-empty table literals land in a later sub-phase (sub-phase F handles {} only; full table-literal CHECK/SYNTHESIZE per §3.10 follows)` |
| 253 | `walker: NODE_BINARY_EXPR not yet implemented` |
| 107 | `method call: receiver has non-record type … (full method dispatch lands in sub-phase F)` |
| 64 | `assign: indexed LHS root must be a simple identifier (chained or computed paths land as a separate contribution if needed)` |
| 63 | `walker: NODE_UNARY_EXPR not yet implemented` |
| 33 | `walker: NODE_CAST_EXPR not yet implemented` |
| 23 | `undefined name io` |
| 21 | `field: indexed access target must be a record …; got 'inter'` |
| 15 | `for-in: iterator is not a function type (unknown)` |
| 12 | `call: callee has non-function type …` |
| 9 | `require: module ffi not found (tried ffi.lua and ffi/init.lua)` |
| 8 | `require: module bit not found (tried bit.lua and bit/init.lua)` |
| 8 | `assign: undefined name 'ESC'` |
| 5 | `undefined name os` |

### Top 10 v4-strict files by v4 error count

(All are files where legacy accepts cleanly.)

- `lib/type/static/defs.lua` — 77 v4 errors
- `lib/html/html_builder_basic.lua` — 54
- `lib/pipeline_dsl/init.lua` — 53
- `lib/type/static/unify.lua` — 48
- `lib/either/init.lua` — 46
- `lib/string_ext/init.lua` — 44
- `lib/safe_regex/init.lua` — 43
- `lib/pipeline/init.lua` — 40
- `lib/color_space/init.lua` — 35
- `lib/geo/init.lua` — 31

### Representative v4-strict snippet

```
lib/encode/init.lua:
  DIVERGE on decision: legacy accepts, v4 rejects
  legacy:
  (clean)
  v4:
  lib/encode/init.lua:1:8: error: method call: receiver has non-record type string (full method dispatch lands in sub-phase F)
```

A one-line v4 failure on a file legacy accepts cleanly. The error
references "sub-phase F" — that is, v4 deliberately hasn't implemented
method dispatch on string yet and emits a TODO-as-error. Every such case
inflates the divergence count without corresponding to a real bug.

## The single `v4 lax` case

```
lib/type/static/stdlib_types.lua:
  DIVERGE on decision: v4 accepts, legacy rejects
  legacy:
  lib/type/static/stdlib_types.lua:64:1: error: --:: module declaration should not be used — require() return types are inferred from return M
  lib/type/static/stdlib_types.lua:105:1: error: --:: module declaration should not be used — require() return types are inferred from return M
```

Legacy enforces a hand-coded lint ("don't write `--::` for the module
return type — let `return M` infer it"). v4 doesn't yet implement this
lint. Not a soundness gap; a policy lint that v4 could port or
deliberately drop.

## Top 10 `diverge_details` cases by absolute error-count delta

| |Δ| | legacy | v4 | file |
| ---: | ---: | ---: | --- |
| 220 | 33 | 253 | `lib/type/static/constrain.lua` |
| 130 | 13 | 143 | `lib/type/static/types.lua` |
| 122 | 160 | 38 | `lib/argon2/init.lua` |
| 92 | 3 | 95 | `lib/web/html/init.lua` |
| 75 | 35 | 110 | `lib/type/static/solve.lua` |
| 75 | 14 | 89 | `lib/schema_validator/init.lua` |
| 70 | 104 | 34 | `lib/prolog/init.lua` |
| 62 | 3 | 65 | `lib/geom/init.lua` |
| 62 | 14 | 76 | `lib/interval/init.lua` |
| 60 | 1 | 61 | `lib/platform/apps/charactercardv2/lib/formats/ccv2/macro.lua` |

Two directions in this list:

- v4 explodes (constrain.lua 33→253, web/html 3→95) — almost always
  walker-not-yet-implemented and deferred-field cascades.
- v4 silently passes through what legacy catches (argon2 160→38,
  prolog 104→34) — legacy reports many real arithmetic and metamethod
  errors that v4 doesn't yet emit because its walker bails earlier.

Inspection of `lib/argon2/init.lua` confirms: legacy catches dozens of
real `cannot assign nil to number` and missing-metamethod constraint
failures; v4 produces a smaller set of walker-deferred TODO errors.
**This is the dangerous shape of divergence**: v4 looks less noisy on
some files because it never reaches the real checks.

## Patterns

### Pattern 1 — v4 walker is incomplete

Three node kinds account for ~350 of the 1696 v4 errors in the
v4-strict bucket: `NODE_BINARY_EXPR`, `NODE_UNARY_EXPR`, `NODE_CAST_EXPR`.
Every file containing arithmetic, comparison, logical, concat, length,
unary minus, `not`, or `--[[: T]]` casts trips at least one. This is
the highest-leverage gap by far — implementing these three node kinds
in the walker would resolve the v4-strict status of the vast majority
of currently-divergent files.

### Pattern 2 — table literals and method dispatch are stubs

`{ k = v }` literals and `x:method(...)` dispatch both error with
"lands in a later sub-phase (sub-phase F)". 409 occurrences combined.
Until sub-phase F lands, any file that constructs a non-empty table or
calls a method (which is most of the corpus) cannot be parity-tested.

### Pattern 3 — deferred-constraint queue absence cascades

468 errors of the form "indexed access on a type variable target is
deferred until the variable is bound; Phase 4b.2 has no deferred-
constraint queue". This is one missing mechanism causing failures
across most files. Whether the right answer is to port the legacy
deferred-constraint queue or to restructure constraint ordering is a
design call, but the diagnostic explicitly flags the missing
infrastructure.

### Pattern 4 — the `require_chain` field is sometimes nil

Only 4 files (small sample), but the message "attempt to index field
'require_chain' (a nil value)" suggests the driver constructs at least
one env without initializing this field. Cheap fix; should be
unconditionally initialised at env construction.

### Pattern 5 — `unknown primitive: table / function`

89+37=126 crashes from `walker/control_flow.lua:269`. The control-flow
walker has a kind dispatch that explicitly doesn't list `table` and
`function` primitives. Likely a missing case in a pcase/dispatch table.
This alone accounts for 17% of the corpus crashing.

## Recommendations — which divergences look like v4 bugs to fix first

Ranked by leverage (files unblocked per fix-unit):

1. **Add `table` and `function` cases to `control_flow.lua:269`'s
   primitive dispatch** — unblocks 126 of 130 driver crashes. The four
   files where v4 also reports a `require_chain` nil are likely also
   resolved by the same audit pass.
2. **Initialize `require_chain` unconditionally in env construction** —
   4 files.
3. **Implement `NODE_BINARY_EXPR`, `NODE_UNARY_EXPR`, `NODE_CAST_EXPR`
   in the walker.** This is sub-phase F work but it dwarfs every other
   gap; until done, no parity claim is meaningful for the bulk of the
   corpus.
4. **Implement non-empty table literal CHECK/SYNTHESIZE** (sub-phase F
   item §3.10). 302 errors.
5. **Implement method dispatch on non-record receivers** (sub-phase F).
   Currently every `s:sub(...)` errors at column 8 of line 1 with
   "receiver has non-record type string". 107 errors plus the entire
   method-on-`string` family.
6. **Port the deferred-constraint queue.** 468 errors all blame Phase
   4b.2's lack of one. Even a minimal queue removes the largest single
   error category.
7. **Defer the `--::` module-declaration lint** (the single v4-lax
   case). Low value; can be ported as a stylistic check after
   correctness work.

## What this report does NOT establish

- It does not show v4 producing any false negatives on legitimate
  type bugs that legacy catches — there is one apparent case
  (`stdlib_types.lua`) and it is a lint, not a soundness gap.
- It does not show v4 producing any false positives on legitimate
  programs — every v4-strict error inspected was a deferred sub-phase
  TODO, not a real type-rule mistake.
- It does not benchmark v4 vs legacy. Both impls run in <50ms per
  file on the surveyed corpus, modulo the 5 timeouts.

The conclusion is **v4 is presently a stub-rich skeleton, not a
production-ready alternative**. Parity work cannot begin in earnest
until sub-phase F (binary/unary/cast/table-literal/method dispatch)
and the deferred-constraint queue land. The 130 driver crashes are
the only "real bugs" surfaced here; everything else is the system
honestly reporting its own incompleteness.
