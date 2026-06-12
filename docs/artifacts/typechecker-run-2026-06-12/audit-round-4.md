# Adversarial audit round 4 — crescent slice v2 increments 5–6

Date: 2026-06-12. HEAD `27bd7a79` (increment 6). Execution-led; every finding below
is reproduced against the real substrate via `crescent_slice_lower.lower → A.check`.
Scope: the new surfaces since round 3 — increment 5 (`f3c10332`: `synth_tuple`,
`index_result` dynamic-key read rules, `index_write_target` write duals,
multi-assign call/method-call spread, multi-return statements) and increment 6
(`27bd7a79`: the empty-closed-rec→`unknown` write rule, diagnose-first re-ranking).

Scratch probes lived in `/tmp/probe_*.lua` (removed). Nothing in `lib/` was modified.

---

## Mandate A — attack the new rules

Probes drove real source through the lowering frontend and the substrate, reading
verdict + rejected/unknown counts + markers. Direct `index_result` /
`index_write_target` calls validated the rule shapes.

### A-F1 [HIGH — soundness] `rec_with_indexer` dynamic-key READ ignores the listed fields

**Reproduced.** `index_result` over a `rec_with_indexer` under a *dynamic* key returns
ONLY the index-signature value type, dropping every listed field type. The listed
fields and the index signature can legitimately DISAGREE, so a dynamic read can be
typed strictly narrower than a value the table actually holds.

```lua
--: ({ a: string, [string]: integer }, string) -> integer
local function f(t, k) return t[k] end   -- CLEAN — accepted as integer
```

`t : { a: string, [string]: integer }`. The dynamic key `k : string` can equal
`"a"` at runtime, in which case `t[k]` is the field `a`, a **string**. The rule
(`crescent_slice.lua:449-451`) returns `obj_ty.val` = `integer` and the function is
accepted as returning `integer`. The STATIC read `t.a` is correctly flagged
(`string ⇐ integer` mismatch); the DYNAMIC read is not. Direct probe:

```
A3c rwi DISAGREE (a:str, [str]:int) dyn read:  integer        <- unsound
    rwi DISAGREE static read .a:                string         <- correct
```

The sound result is `union(field-value-types) | val` (the field union joined with the
indexer value), mirroring the closed-`rec` dynamic-read rule directly below it
(lines 459-464) which DOES union the field types in. The `rec_with_indexer` branch
omits exactly that join.

**Provenance / why it is a round-4 finding.** The branch text predates the slice
(pass 2, `5f53fff3`), but it was UNREACHABLE for dynamic reads until increment 5
routed real `t[e]` reads through `index_result`'s `key_ty` path (the 2-premise
`synth_index` dynamic-key form + the lowering `indexdyn` arm). Increment 5 made the
latent unsoundness live on the new path. Severity HIGH: a real program is accepted
with an unsound result type. Principled fix: union the listed field value types into
the `rec_with_indexer` dynamic-key result, identical to the closed-`rec` rule.

### A-OK1 The empty-rec write IS sound — the READ side does not regress

The §6.10 rule `out = {}; out[k] = v ⇒ unknown` was attacked on its dual: after the
write, does a subsequent READ of `out` claim anything unsound? **No.** The slice is
flow-insensitive — the write does not widen `out`'s type, which stays the empty
closed rec `{}`. The empty-rec READ rule returns `nil` for every dynamic read:

```
empty-rec dynamic READ:    nil
empty-rec WRITE target:    unknown
A1d  out={}; out[k]=5; return out[j]  used as integer  -> FINDINGS (correctly refused)
```

`local x: string = out[j]` / `return out[j]` typed as integer both produce an honest
`type-mismatch` (the read is `nil`, not the written value) — the accepted write
licenses NO unsound read. The asymmetry between accumulated static fields and a
dynamic write on the same table is sound in both directions tested: a heterogeneous
static-field rec under a dynamic write is the recorded `dynamic-index-assign`
deferral (out-of-subset, not accepted). The write rule is sound as claimed.

### A-OK2 `synth_tuple` truncation matches LuaJIT multi-value semantics

Verified against real Lua adjustment rules by type-distinguishing probes:

- **Arg position** `g(pair())` truncates a multi-return call to its first value when
  the callee takes fewer params; `synth_call_expr` synthesizes a call as `ret.fixed[1]`
  in value position, so a multi-return used as a single value contributes one slot.
- **Non-final call** `local a,b = pair(), 9` — `pair()` is NON-final, truncated to 1.
  Distinguishing probe (`pair : () -> (integer, string)`, then `a + b` requiring `b`
  integer): CLEAN, confirming `b = 9` (the literal), NOT `pair`'s second value
  `string`. A wrong spread would have made `b : string` and failed `a + b`.
- **Final call** `local a,b = pair()` spreads to `a=1, b=2`; `local a,b,c = pair()`
  leaves `c = nil`. Both handled (`flatten_values`, last-value-only spread).
- **Check-mode closure slot** `apply(function(a,b) return a+b end)` against
  `((integer,integer) -> integer) -> integer`: CLEAN; the expected param types push
  inward to the closure params.

No truncation defect found. The increment-5 note that `synth_tuple` was a needed
substrate method (vs the design's "zero new methods") is corroborated — the rule is
correct.

### A-OK3 `index_result` reads — union dispatch, optional fields, no double-nil

- Closed rec `{a:int,b:str}` dynamic read = `union{integer, string, nil}` (correct).
- Closed rec with an OPTIONAL field `{a?:int, b:str}` dynamic read = `union{integer,
  string, nil}` — a SINGLE `nil`, NOT a double-nil. The optional field contributes
  its bare value type `integer` (the union normalizer collapses the appended `nil`
  with any field `nil`). No double-nil bug.
- `union(rec, rec)` dynamic read distributes and unions correctly.
- `rec_with_indexer` where the rec part and indexer AGREE reads soundly; the DISAGREE
  case is A-F1 above.

### A-OK4 Round 1–3 fixes hold on the new paths

- **F1 (module-rec rebind) × dynamic writes on M.** `M = {}; function M.f() …;
  M[k] = v; return M.f()` — the dynamic write does not staleify or widen `M`'s rec;
  `M.f` reads its declared type, and `M = {}` followed by a dynamic write + `M.f`
  read correctly reports `no-such-field:f` (the stale rec is gone). No interaction
  regression; every probe had `rej=0` (the residual findings are the pre-existing
  unannotated-`function M.f` return boundary, not the write).
- **Collision detection / well-formedness gates.** These live in the alias-import /
  value-type path (`import_top_level_aliases`), orthogonal to increments 5–6, which
  touch only `index_result` / `index_write_target` / tuple lowering. Untouched and
  confirmed active in round 3; nothing in 5–6 reaches them.

### Mandate A finding count by severity

| Severity | Count | Findings |
|---|--:|---|
| HIGH (soundness) | 1 | A-F1 (`rec_with_indexer` dynamic read drops field types) |
| MEDIUM | 0 | — |
| LOW | 0 | — |

(Plus four positive validations A-OK1..A-OK4: the empty-rec write, `synth_tuple`
truncation, the read-rule union/optional handling, and the round-1–3 regression
spot-checks are all sound.)

---

## Mandate B — adjudicate the checker's rejections

The 13 CHECKED-FINDINGS files from the increment-6 e2e survey
(`bin/cr run lib/type/analysis/slice_survey.lua --e2e --md`). Each file's first
diagnostics were adjudicated by reproducing the failing pattern in isolation and
reading the `lib/` source. Buckets:

- **TRUE POSITIVE** — a real bug or wrong annotation in `lib/` code (the checker
  earning its keep).
- **FALSE POSITIVE** — a checker precision / soundness-of-rejection defect
  (severity: wrong-rejection). The code and annotation are correct; the checker
  refuses (rejects, or abstains-`unknown`) a sound program.
- **ANNOTATION-GAP** — the code is fine but an annotation (in the file or a required
  dependency) uses a fenced/out-of-subset construct, correctly surfaced.

### Bucket tally

| Bucket | Count | Files |
|---|--:|---|
| TRUE POSITIVE | **0** | — |
| FALSE POSITIVE (wrong-rejection) | **11** | agent/render, base64url, math/init, caps/kv, caps/time, socket/init, taskgraph/frontier, v7_mr0/fixtures, rehype_document, rehype_infer_title, rehype_meta |
| ANNOTATION-GAP | **2** | https/init (union-of-tuples-with-nested-fn return, fenced), tcp/client (`{A,B}` shorthand in the `lib.ljsocket` `LjSocket` alias) |

**No TRUE POSITIVES.** Every rejection over correct corpus code traced to a slice
precision gap; the two ANNOTATION-GAPs are out-of-subset annotation constructs
(known fences), not bugs in the code.

### The dominant false-positive root cause — `and`-guard does not narrow

Five of the type-mismatch files (rehype_meta, rehype_document, rehype_infer_title,
agent/render, and the optional-record fixtures in v7_mr0) reduce to a single
narrowing gap. The slice narrows a bare truthy test but NOT a compound `and` test:

```
B5a  if title then       id(title)   -> CLEAN     (bare truthy narrows)
B5b  if title and x then id(title)   -> FINDINGS  (and-guard does NOT narrow title)
B5c  if title and title ~= "" then   -> FINDINGS  (the exact rehype_meta idiom)
```

`title : string | nil`; inside `if title and …`, `title` is provably non-`nil`, but
the slice leaves it `string | nil`, so `id(title)` fails `string | nil ⇐ string`.
`rehype_meta`'s three findings are all this idiom (`if opts.title and opts.title ~=
"" then …`). It compounds with the documented field-path-narrowing deferral
(`opts.title` is also a field path), but the `and`-narrowing gap fails even a plain
local. This is a precision defect that rejects sound programs — the principled fix is
to thread the truthiness of each `and` conjunct's variable into the consequent.

### The `rec_with_indexer` dynamic READ is also why A-F1 matters here

`taskgraph/frontier` and the cross-module rehype/agent writes also exercise
field-path/optional precision; all check CLEAN in isolation with matching inline
aliases, so the residual rejection is cross-module alias resolution thinning a type
to `unknown` or the `and`-narrowing gap — never a code bug.

### Per-file adjudication (first diagnostics)

| File | First diag(s) | Root cause | Bucket |
|---|---|---|---|
| `unified/rehype_meta/init.lua` | 3× type-mismatch | `if x and …` does not narrow `x` (see above); `opts.title`/`opts.description` field paths used after an `and`-guard | FALSE POSITIVE |
| `unified/rehype_document/init.lua` | 2× type-mismatch + 1 unknown | same `and`/field-path narrowing family; `opts_t.title or ""` + branch guards | FALSE POSITIVE |
| `unified/rehype_infer_title/init.lua` | type-mismatch + unknown | `node.value or ""`, `node.children` field-path narrowing; same family | FALSE POSITIVE |
| `agent/render.lua` | type-mismatch | `pairs(task_inputs)` keys typed `unknown` + guarded `if v ~= nil` field/var precision; `val_to_str` result flow | FALSE POSITIVE |
| `type/v7_mr0/fixtures.lua` | 2× type-mismatch | deeply-optional record literals (`type?`, `pack?`, …) built then read — optional-field narrowing precision | FALSE POSITIVE |
| `taskgraph/frontier.lua` | type-mismatch | cross-module `FrontierNode` write; the `add`/`snapshot` patterns are CLEAN with inline aliases — cross-module resolution precision | FALSE POSITIVE |
| `socket/init.lua` | xmodule-alias-error: `server_socket: unknown type name: 'server_client'` | `server_socket` references sibling alias `server_client`; BOTH are declared in `lib.socket.server`, but the cross-module import does not resolve a sibling referenced by an imported alias (in-file sibling refs DO resolve, B7) | FALSE POSITIVE |
| `math/init.lua` | 1 unknown claim | unannotated closure `M.tointeger = function(x)` checked against `(unknown) -> integer \| nil`; the `checks_against` claim abstains (`unknown`, not rejected) — closure check-mode precision | FALSE POSITIVE |
| `platform/caps/kv.lua` | 1 unknown claim | `M.kv_cap` returns capturing closures + multi-return; module-value-type synthesis abstains | FALSE POSITIVE |
| `platform/caps/time.lua` | 1 unknown claim | same capability-closure / multi-return synthesis abstention | FALSE POSITIVE |
| `encode/base64/base64url.lua` | 1 unknown claim | `M.encode` forwards to cross-module `base64.encode`; the cross-module value-type `checks_against` abstains | FALSE POSITIVE |
| `https/init.lua` | type-mismatch + annotation-error | return annotation `((() -> string\|nil, string\|nil)\|nil, …) \| (nil, string\|nil)` — union-of-tuples with nested function types, a fenced construct ("a multi-element tuple is only valid as function params/return") | ANNOTATION-GAP |
| `tcp/client.lua` | xmodule-alias-error: `LjSocket: {A,B} not a v1 table type`, then `LjSocketModule: unknown type name 'LjSocket'` | the `lib.ljsocket` `LjSocket` alias uses `{A,B}` list-shorthand-as-element (out-of-subset); the failure cascades to `LjSocketModule` | ANNOTATION-GAP |

Note on the four `unknown`-claim files (base64url, math, kv, time): these are
ABSTENTIONS (`0 rejected, 1 unknown`), not active rejections. The substrate could not
decide the claim — over correct code, an inability to accept is itself a precision
defect, so they bucket as FALSE POSITIVE (wrong-rejection) with the sub-note that the
manifestation is `unknown`, not `rejected`.

### The most interesting result

There is no TRUE POSITIVE: the new checker found zero real bugs in the corpus this
round; all 13 CHECKED-FINDINGS rejections are slice precision gaps (11) or fenced
out-of-subset annotations (2), the largest single gap being that an `and`-guard
does not narrow its conjuncts.

---

## Regressions

**No.** Round 1–3 fixes hold on the new paths (A-OK4): the F1 module-rec rebind does
not interact unsoundly with dynamic writes on `M`; collision detection and
well-formedness gates are orthogonal to increments 5–6 and untouched. Full analysis
suite green at **6427 assertions, 0 failed** (`bin/cr test lib/type/analysis/`).

## Summary

- **Mandate A:** 1 HIGH soundness finding (A-F1: `rec_with_indexer` dynamic-key read
  drops field types — accepts an unsound result type; latent since pass 2, made live
  by increment 5's dynamic-read routing). The empty-rec write rule, `synth_tuple`
  truncation, and the read-rule union/optional handling are all SOUND.
- **Mandate B:** 0 TRUE POSITIVE / 11 FALSE POSITIVE (wrong-rejection) / 2
  ANNOTATION-GAP. Dominant false-positive root cause: `if x and …` does not narrow
  `x`. No real corpus bugs found by the new checker this round.
- **Regressions:** none.
