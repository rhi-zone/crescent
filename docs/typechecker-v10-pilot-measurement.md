# v10 kernel pilot — measurement report (Phase 3)

Measured against commit `eeb18b1a` (HEAD at measurement time; `lib/type/v10_kernel/pilot/*.lua`
last touched at `bd95559e`/`875e6a5d`, both ancestors of HEAD — no pilot-code edits happened
between reading the source and running this measurement). `bin/cr test
lib/type/v10_kernel/pilot/` — 7/7 files, 196 assertions green. `bin/cr test
lib/type/v10_cleanroom/` — 3/3 files, 1044 assertions green. Both reconfirmed at this HEAD
before writing this report.

This is a measurement-only report. No `lib/type/v10_kernel/pilot/*.lua` source file was
modified to produce these numbers. The driver script lives outside the repo
(`/tmp/v10_parity/measure.lua`, disposable, not committed) and calls
`prover.M.analyze_file` directly, plus shells out to `bin/cr check` for the v3 baseline.

## Corpus

Selection method: grepped `lib/` (excluding `lib/type/v10_kernel/`, `lib/type/v10_cleanroom/`,
and `_test.lua` files) for `local X --: T`-annotated locals whose annotation content is a
`|`-union of two or more of the six `type()` classes (nil/boolean/number/string/table/function),
per `prover_narrow.lua`'s `parse_annotation_members` — the exact acceptance rule pass 1 itself
uses. Two passes:

1. **File-level grep** for the annotation pattern alone (66 files matched). A file-level guard
   count (grep for `type(x)`/`==nil`/`~=nil`/`if x then` anywhere in the file, regardless of
   which variable) was used to rank/shortlist 15 files by apparent "annotation + guard density."
2. **Corpus-widening rescan** (`/tmp/v10_parity/scan.lua`): a line-based heuristic scanning
   *every* `lib/**/*.lua` file (996 files, same exclusions) for a `local X --: <six-tag-union>`
   line followed within 50 lines by a guard referencing the **same name** `X`
   (`type(X)==`/`X==nil`/`X~=nil`/`if X then`/`if not X then`/`while X do`). This is the pattern
   that actually matters for this pilot (pass 1 only tracks guards on the *same* variable it
   declared) and is a materially different, smaller set than step 1's file-level match. This
   full-tree rescan found exactly 13 additional real-file hits beyond what step 1 had already
   included; all 13 were added to the corpus (no synthetic/hand-written fixtures).

Final corpus: 27 files, 20,097 combined lines / 791,033 combined bytes. Every file found by
either scan is included — none were discarded for being "hard" or all-skipped.

| file | lines | reason selected |
|---|---:|---|
| `lib/dice/init.lua` | 668 | file-level: 20 six-tag-union annotations, 11 guard-shaped lines |
| `lib/platform/daemon/init.lua` | 1759 | file-level: 10 annotations, 47 guard-shaped lines; also a same-var rescan hit (`token`, `pol_ok`) |
| `lib/compress/system.lua` | 361 | file-level: 6 annotations, 11 guard-shaped lines |
| `lib/actor/init.lua` | 674 | file-level: 6 annotations, 11 guard-shaped lines |
| `lib/platform/apps/finance/views.lua` | 751 | file-level: 5 annotations, 26 guard-shaped lines |
| `lib/exec/make_api.lua` | 359 | file-level: 4 annotations, 14 guard-shaped lines |
| `lib/exec/help.lua` | 516 | file-level: 4 annotations, 19 guard-shaped lines |
| `lib/columnar/init.lua` | 445 | file-level: 4 annotations, 26 guard-shaped lines |
| `lib/bookkeeping/import_qif.lua` | 277 | file-level: 4 annotations, 8 guard-shaped lines; same-var rescan hit (`cur_payee`) |
| `lib/platform/session_store/init.lua` | 234 | file-level: 3 annotations, 8 guard-shaped lines |
| `lib/platform/audit/init.lua` | 259 | file-level: 3 annotations, 9 guard-shaped lines; same-var rescan hit (`app_id`) |
| `lib/roman_numeral/init.lua` | 502 | file-level: 2 annotations, 10 guard-shaped lines; same-var rescan hit (`result`) — also the file used in the existing `prover_test.lua` fixture |
| `lib/pid/init.lua` | 276 | file-level: 3 annotations, 3 guard-shaped lines |
| `lib/dsp/init.lua` | 567 | file-level: 6 annotations, 1 guard-shaped line — **kept deliberately as an awkward case**: the annotations (`b0`..`a2`, `number\|nil`) have no guard anywhere near them; the file's one guard hit is on an unrelated variable (`signal[1]`) |
| `lib/ai/providers/openai.lua` | 31 | file-level: 3 annotations, 1 guard-shaped line — **kept deliberately as an awkward case**: `chat_path`/`ep2`/`ip2` are declared `string \| nil` but never guarded; the file's one guard hit (`if base_url then`) is on an unrelated parameter |
| `lib/type/static/solve.lua` | 4463 | same-var rescan hit (`name`) |
| `lib/type/analysis/crescent_slice_parse.lua` | 1329 | same-var rescan hit (`perr`, `construct`, `fail_name`) |
| `lib/sscanf/init.lua` | 543 | same-var rescan hit (`text`) |
| `lib/platform/caps/create_instance.lua` | 223 | same-var rescan hit (`manifest_src`) |
| `lib/platform/apps/system_dashboard/server.lua` | 880 | same-var rescan hit (`fail_msg`) |
| `lib/ljsocket/init.lua` | 1268 | same-var rescan hit (`host_str`) |
| `lib/http/server.lua` | 313 | same-var rescan hit (`winner`) |
| `lib/ed25519/init.lua` | 891 | same-var rescan hit (`seed`) |
| `lib/argon2/init.lua` | 1002 | same-var rescan hit (`hash`) |
| `lib/struct/init.lua` | 524 | same-var rescan hit (`le`) |
| `lib/pdf/object.lua` | 564 | same-var rescan hit (`data_end`) |
| `lib/oauth2/init.lua` | 684 | same-var rescan hit (`raw`) |

**Coverage finding, stated plainly up front**: of the 15 files shortlisted purely by
file-level annotation+guard density (step 1), only 3 (`session_store`, `audit`,
`roman_numeral`) produced a single judgment. The other 12 (`dice`, `daemon`, `compress`,
`actor`, `finance/views`, `exec/make_api`, `exec/help`, `columnar`, `bookkeeping/import_qif`,
`pid`, `dsp`, `ai/providers/openai`) produced **zero** judgments — every guard-shaped line in
those files was on a variable *other than* the one carrying the six-tag-union annotation
(`guards_skipped: N x "guarded variable not a tracked annotated local"` for all N). This is
the dominant real finding of the corpus-selection step: file-level co-occurrence of
"annotation exists" and "guard exists" is a poor predictor of "guard is on the annotated
variable" — the two are usually unrelated statements in the same file. The step-2 full-tree
rescan (same-variable proximity) is what actually produced usable material, and even that
rescan across the **entire** 996-file `lib/` tree (minus exclusions) found only 13 hits.

## Aggregate results

| metric | value |
|---|---:|
| guards found | 546 |
| guards handled | 17 |
| guards skipped | 529 |
| annotations parsed | 141 |
| annotations skipped | 196 |
| certificates emitted | 20 |
| replay pass | 20 |
| replay fail | 0 |
| judgments (`#result.judgments`) | 20 |
| total analyze_ms (pass 1, summed) | 105.471 |
| total emit_ms (pass 2 + inline replay, summed) | 72.736 |
| combined corpus bytes | 791,033 |

`guards_found` (546) vastly exceeds `guards_handled` (17): 529 guards were skipped, and
**every single skip** across all 27 files carried the same reason string:

```
guarded variable not a tracked annotated local
```

No other guard-skip reason occurred in this corpus (no `truthiness guard unsupported:
declared union includes plain 'boolean'`, no `guard over an already-monomorphic fact`, no
`guard target not structurally first in the carried union`) — this corpus never exercised
those other documented scope limits; it only exercised the "guard is on a different variable
than the annotation" case, which is a property of the corpus (most real six-tag-union
annotations in this codebase are function-parameter annotations, e.g. `--: (string | nil) ->
...` on the line above a function, not `local x --: string | nil` statements — and
`prover_narrow.lua`'s `analyze_block` only ever populates `scope[name_id]` from a
`NODE_LOCAL_STMT`, never from a function parameter list), not a defect surfaced by the truth
check.

`annotations_skipped` (196) breaks down entirely into "unsupported annotation member ... (not
one of the six type() classes)" — record/table-shape annotations (`{ [integer]: T }`),
function-type annotations (`(A, B) -> C`), named-type aliases (`SessionStore`, `Ty`,
`ActorRecord`), and `integer`/`unknown` (not one of the six literal `type()` class names) —
all out of this pilot's declared scope per `prover_narrow.lua`'s header
(`parse_annotation_members` rejects wholesale, no partial acceptance). No annotation-skip
reason involved a bug; every one matches the documented six-tag-only restriction.

## Per-file table

`v3_ms` is `bin/cr check <file>` wall-clock via `date +%s%N` around the shelled subprocess
(process-startup-dominated at this corpus's file sizes — see Timing methodology below).
`v3_exit`: `1` = typecheck found pre-existing errors/warnings in the file (unrelated to this
measurement, not investigated further), `0` = clean.

| file | bytes | v3_exit | v3_ms | guards found | guards handled | annotations parsed | certs emitted | replay pass/fail | analyze_ms | emit_ms | judgments |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lib/dice/init.lua | 21129 | 1 | 33 | 27 | 0 | 36 | 0 | 0/0 | 9.686 | 1.477 | 0 |
| lib/platform/daemon/init.lua | 71669 | 1 | 37 | 58 | 0 | 6 | 0 | 0/0 | 9.691 | 0.746 | 0 |
| lib/compress/system.lua | 10952 | 1 | 32 | 5 | 0 | 6 | 0 | 0/0 | 1.635 | 0.782 | 0 |
| lib/actor/init.lua | 22525 | 1 | 35 | 9 | 0 | 4 | 0 | 0/0 | 7.720 | 0.585 | 0 |
| lib/platform/apps/finance/views.lua | 31368 | 0 | 30 | 19 | 0 | 6 | 0 | 0/0 | 5.180 | 0.719 | 0 |
| lib/exec/make_api.lua | 10651 | 0 | 34 | 5 | 0 | 0 | 0 | 0/0 | 1.180 | 0.366 | 0 |
| lib/exec/help.lua | 16574 | 1 | 33 | 14 | 0 | 0 | 0 | 0/0 | 3.183 | 0.472 | 0 |
| lib/columnar/init.lua | 12601 | 1 | 32 | 9 | 0 | 4 | 0 | 0/0 | 1.397 | 0.410 | 0 |
| lib/bookkeeping/import_qif.lua | 13482 | 0 | 30 | 2 | 0 | 4 | 0 | 0/0 | 0.949 | 1.028 | 0 |
| lib/platform/session_store/init.lua | 9183 | 1 | 35 | 18 | 3 | 3 | 3 | 3/0 | 0.736 | 8.249 | 3 |
| lib/platform/audit/init.lua | 10328 | 1 | 31 | 13 | 2 | 4 | 3 | 3/0 | 1.008 | 5.720 | 3 |
| lib/roman_numeral/init.lua | 16452 | 1 | 35 | 11 | 2 | 4 | 2 | 2/0 | 2.511 | 5.264 | 2 |
| lib/pid/init.lua | 7870 | 1 | 31 | 3 | 0 | 10 | 0 | 0/0 | 0.926 | 0.267 | 0 |
| lib/dsp/init.lua | 14997 | 1 | 35 | 3 | 0 | 12 | 0 | 0/0 | 1.749 | 0.289 | 0 |
| lib/ai/providers/openai.lua | 863 | 1 | 31 | 2 | 0 | 4 | 0 | 0/0 | 0.226 | 0.135 | 0 |
| lib/type/static/solve.lua | 221816 | 1 | 42 | 60 | 0 | 0 | 0 | 0/0 | 19.502 | 2.697 | 0 |
| lib/type/analysis/crescent_slice_parse.lua | 55409 | 0 | 35 | 63 | 2 | 16 | 2 | 2/0 | 4.365 | 9.121 | 2 |
| lib/sscanf/init.lua | 16850 | 1 | 36 | 15 | 1 | 1 | 1 | 1/0 | 2.202 | 1.622 | 1 |
| lib/platform/caps/create_instance.lua | 9047 | 1 | 31 | 10 | 1 | 2 | 1 | 1/0 | 0.740 | 1.303 | 1 |
| lib/platform/apps/system_dashboard/server.lua | 30949 | 1 | 35 | 43 | 1 | 3 | 2 | 2/0 | 3.210 | 7.767 | 2 |
| lib/ljsocket/init.lua | 40364 | 1 | 37 | 30 | 0 | 2 | 0 | 0/0 | 3.561 | 0.525 | 0 |
| lib/http/server.lua | 13123 | 1 | 32 | 6 | 0 | 0 | 0 | 0/0 | 5.166 | 0.393 | 0 |
| lib/ed25519/init.lua | 31093 | 1 | 29 | 11 | 2 | 1 | 2 | 2/0 | 6.458 | 6.937 | 2 |
| lib/argon2/init.lua | 37795 | 1 | 33 | 33 | 1 | 2 | 1 | 1/0 | 5.115 | 3.126 | 1 |
| lib/struct/init.lua | 16042 | 1 | 34 | 32 | 0 | 1 | 0 | 0/0 | 2.075 | 0.371 | 0 |
| lib/pdf/object.lua | 21535 | 0 | 30 | 22 | 1 | 1 | 2 | 2/0 | 2.000 | 4.604 | 2 |
| lib/oauth2/init.lua | 26366 | 1 | 34 | 23 | 1 | 9 | 1 | 1/0 | 3.300 | 7.761 | 1 |

## Timing methodology note (v3 baseline is not apples-to-apples)

`v3_ms` is the wall-clock of the FULL `bin/cr check <file>` process: vendored-musl-loader
startup + LuaJIT startup + stdlib-declaration loading + full parse + full constraint
generation + full solve + full diagnostic formatting, for the WHOLE typechecker. It sits in a
narrow 29–42ms band across every file in this corpus regardless of file size (863 bytes to
221,816 bytes) — at these file sizes the number is dominated by fixed process/interpreter
startup cost, not by per-file work; it is not a meaningful function of file size at this
corpus's scale and should not be read as a throughput measurement of v3's checker.

`analyze_ms`/`emit_ms` are pass 1 / pass 2+replay timings for the **pilot's narrowing-only
analysis** inside an already-running process (no process startup, no stdlib loading, no full
type inference — pass 1 only recognizes 3 guard shapes over a hand-rolled event tree; pass 2
only builds and replays `narrow-select-match`/`narrow-select-rest` citations). The two numbers
are not comparable in scope: v3 does full soundness-checked typechecking of the whole file;
the pilot does flow-narrowing certificate emission for a deliberately narrow slice of guard
forms. Any file where `v3_ms` and `analyze_ms + emit_ms` are close in magnitude (e.g.
`lib/platform/session_store/init.lua`: v3 35ms vs pilot 8.99ms combined) reflects v3's
fixed-cost floor at these file sizes, not the pilot doing comparable work.

## Truth check — all 20 emitted judgments, individually verified

The pilot's `ReplayResult.conclusion` is a raw `term_algebra` `Term` with no pretty-printer in
`lib/type/v10_cleanroom/`. Rather than build one for this report, the driver script
independently walks pass 1's plain-data event tree (`prover_narrow.analyze`'s output) with the
exact match-then-rest, depth-first order `prover.lua`'s own `emit_events` uses (verified by
reading that function), producing a parallel `(var_name, target, branch)` tuple per citation.
Every file's tuple count matched its judgment count exactly (no order-assumption divergence
detected). Each row below was verified by hand: opening the source file, reading the code
around the guard, and checking whether the claimed narrowed type actually holds at that
program point.

| # | file | location (manual) | claimed | branch | verdict |
|---|---|---|---|---|---|
| 1 | lib/platform/session_store/init.lua | L65-67, `local ttl = tonumber(idle_ttl) --: number\|nil; if not ttl then return nil,... end` | `ttl` is falsy (nil) inside the `if not ttl` body | match | TRUE |
| 2 | lib/platform/session_store/init.lua | L102-103, `local ts = tonumber(last_seen) --: number\|nil; if not ts then return nil,... end` | `ts` is falsy (nil) inside the body | match | TRUE |
| 3 | lib/platform/session_store/init.lua | L149-150, `local ls = tonumber(last_seen) --: number\|nil; if not ls then return nil end` | `ls` is falsy (nil) inside the body | match | TRUE |
| 4 | lib/platform/audit/init.lua | L183-191, `if limit_n and offset_n then ... elseif limit_n then ... elseif offset_n then ...` (clause 0 is `and`-conjoined, not a recognized guard shape — ineligible, chain continues unnarrowed; clause 1 test is bare `limit_n`) | at the point of clause 2's own test (`elseif offset_n then`), `limit_n` is falsy (nil) — the "match" citation is the else-continuation of clause 1's guard | match | TRUE (control only reaches clause 2's test if clause 1's `limit_n` truthy-test failed, i.e. `limit_n` was nil) |
| 5 | lib/platform/audit/init.lua | same site, clause 2 body (`elseif offset_n then ... LIMIT -1 OFFSET ...`) | `offset_n` is "rest of falsy" (number) inside clause 2's body | rest | TRUE (body only runs when `offset_n` truthy, i.e. non-nil ⇒ number) |
| 6 | lib/platform/audit/init.lua | same site, clause 1 body (`elseif limit_n then ... LIMIT n`) | `limit_n` is "rest of falsy" (number) inside clause 1's body | rest | TRUE |
| 7 | lib/roman_numeral/init.lua | L446-448, inside the `style == "unicode"` branch: `result = M.to_unicode(n); if not result then return nil,... end` | `result` is falsy (nil) inside the body | match | TRUE |
| 8 | lib/roman_numeral/init.lua | L474, after the full if/elseif/else chain: `if not result then return nil, err end` | `result` is falsy (nil) inside the body | match | TRUE |
| 9 | lib/type/analysis/crescent_slice_parse.lua | L543, `local perr --: string\|nil` (declared ~L533, no init) ... `if perr then return nil, perr, pconstruct end` | `perr` is "rest of falsy" (string) inside the body | rest | TRUE (body only reached when `perr` truthy) |
| 10 | lib/type/analysis/crescent_slice_parse.lua | L938-939, `if fail_name ~= nil then local fn = fail_name --: string ...` | `fail_name` is non-nil (string) inside the body | rest | TRUE. Note: a DIFFERENT guard on the same variable at L917 (`if fail_name == nil then fail_name = name;... end`, inside `local function elaborate(...)`) produced **no** citation and correctly does not appear in this list — that guard sits inside a nested function body, which `prover_narrow.lua`'s `NODE_FUNC_DECL` handling analyzes with a **fresh, empty scope**, so `fail_name`'s outer-scope tracking does not carry in; the guard is real code but out of this pilot's per-function scoping model, and was silently absent from `guards_found` for that reason (not double-counted, not misattributed) |
| 11 | lib/sscanf/init.lua | L271-291 (`conv == "i"` branch): `local text --: string\|nil; ...; if not text then ...; text = sub(...) end` | `text` is falsy (nil) inside the body, at entry (before the reassignment on the next line) | match | TRUE |
| 12 | lib/platform/caps/create_instance.lua | L85-100, `local manifest_src --: string\|nil` (set inside a loop not walked by this pilot) ... `if not manifest_src then return nil, "..." end` | `manifest_src` is falsy (nil) inside the body | match | TRUE |
| 13 | lib/platform/apps/system_dashboard/server.lua | L387-398, `local fail_msg --: string\|nil` set conditionally, then `if fail_msg ~= nil then ... else frame_payload = decoded end` | `fail_msg` is nil in the `else` branch | match | TRUE (`~= nil` false ⇒ nil, given the declared union is only `string \| nil`) |
| 14 | lib/platform/apps/system_dashboard/server.lua | same site, `then`-branch (error-report block) | `fail_msg` is non-nil (string) in the `then` branch | rest | TRUE |
| 15 | lib/ed25519/init.lua | L748-756, `local seed --: string\|nil`; else-branch: `seed = random_bytes_fn(32); if not seed then return nil,"..." end` | `seed` is falsy (nil) inside the body | match | TRUE |
| 16 | lib/ed25519/init.lua | L757, after the if/else: `if not seed then return nil, "seed unavailable" end` | `seed` is falsy (nil) inside the body | match | TRUE |
| 17 | lib/argon2/init.lua | L121-124, `local hash --: string\|nil; hash = b64url_decode(...); if not hash then return nil, "..." end` | `hash` is falsy (nil) inside the body | match | TRUE |
| 18 | lib/pdf/object.lua | L389-435, `local data_end --: number\|nil` ... `if data_end == nil then` (endstream-scan body) `else` (`math.floor(data_end)` body) | `data_end` is nil inside the `if` body | match | TRUE |
| 19 | lib/pdf/object.lua | same site, `else` body | `data_end` is non-nil (number) inside the `else` body | rest | TRUE |
| 20 | lib/oauth2/init.lua | L393-423, `local raw --: string\|nil`; after the FFI-attempt block: `if not raw then ... raw = table.concat(bytes) end` | `raw` is falsy (nil) at entry to the fallback body (before the reassignment on the same block's last line) | match | TRUE |

**No wrong judgment was found in this sample.** All 20 verified true against the actual code
at the claimed program point. This is a report of what was checked, not a claim that the
pilot is bug-free outside this sample — 20 judgments across 27 files, dominated by the
`falsy`/bare-truthiness and `nil`-check guard forms (18 of 20; only rows 4–6, 9 are
`type()`-tag or elseif-chain cases; and only rows 4–6 exercise the elseif-chain mechanism, and
only rows 9/10 exercise scope-boundary/nested-function behavior), is a narrow slice of the
pilot's declared scope, not exhaustive coverage of it. Notably absent from this sample:
`type(x) == "table"`/`"function"`/`"boolean"` guards, `while`-loop guards, and multi-clause
(3+) elseif chains all-eligible — none of those forms happened to occur on a
same-variable-annotated local anywhere in this 27-file corpus.

## Skip-reason summary (coverage is thin — stated in plain numbers)

- 546 guards found, 17 handled (3.1%), 529 skipped.
- 529/529 skips (100%) carry the single reason `"guarded variable not a tracked annotated
  local"` — i.e., a recognized guard shape (`type(x)==`, `x==nil`, bare truthiness) on a
  variable that either (a) was never declared via a `local x --: <six-tag-union>` statement in
  the pilot's tracked sense (most commonly: it's a function *parameter*, annotated only via the
  function's own `--: (...) -> ...` signature line, which `prover_narrow.lua`'s scope-population
  code never reads), or (b) is declared with a union outside the six-tag scope (record/function/
  named-alias types — rejected wholesale by `parse_annotation_members`), or (c) is inside a
  `for`-loop body (never walked) or a nested function body with a fresh scope (declared outside,
  guarded inside — see row 10 of the truth-check table).
- 196 annotations found, 141 parsed (six-tag union, tracked), 196 rejected as containing at
  least one non-six-tag member (records, function types, named aliases, `integer`, `unknown`).
- 0 `emission_skipped` entries anywhere in this corpus (pass 2 never had to reject a citation
  attempt as un-replayable in this corpus — contrast `prover_test.lua`'s own "ineligible middle
  clause" fixture, which does exercise a real `emission_skipped`/`replay_fail` case; that
  fixture's scenario did not occur naturally in this real-file corpus).

## Reproduction

Driver: `/tmp/v10_parity/measure.lua` (disposable, not part of the crescent repo; corpus list
and pass-1 correlation walk are inline in the file). Corpus-widening scanner:
`/tmp/v10_parity/scan.lua`. Run via:

```sh
REPO=/home/me/git/rhizone/crescent
"$REPO/bin/ld-musl-x86_64.so.1" "$REPO/bin/luajit-bin" /tmp/v10_parity/measure.lua "$REPO"
```

## Run 2 — parameter-sourced facts (commit `aa2f6155`)

Measured against commit `aa2f6155` ("v10 kernel pilot narrows function parameters, not just
locals"), same day as run 1 (`eeb18b1a` baseline unchanged, still the parent lineage). Same 27
files, same corpus, same driver methodology as run 1 — no new/removed/altered fixtures,
`prover_narrow.lua`'s scope population extended to also populate `scope[name_id]` from function
parameters sourced from a preceding-line `--: (T1, T2, ...) -> R` signature annotation (see the
commit for the full contract-extension description). `bin/cr test lib/type/v10_kernel/pilot/`
7/7 files green, 249 assertions (up from 196 in run 1 — 53 new assertions added covering each
guard form on a parameter, non-zero-index parameter addressing, nested-function-parameter
shadowing/isolation, vararg wholesale-skip, and signature/param-count-mismatch wholesale-skip).
`bin/cr test lib/type/v10_cleanroom/` 3/3 files green, 1044 assertions (unchanged — this module
is not touched by the parameter-scope change).

### Contract-extension summary

- `prover_addr.lua`: function parameters get child indices `0..np-1` (0-based, left-to-right,
  same convention as `NODE_LOCAL_STMT`'s own name-indexing), body moves from the old fixed
  child `0` to child `np` (`M.func_body_index(num_params)`, generalizing the removed
  `M.FUNC_BODY_INDEX = 0` constant — `func_body_index(0) == 0`, the same value for the no-params
  case). `M.func_param_path` added, mirroring `M.local_name_path`.
- `prover_narrow.lua`: locates the preceding-line function-type annotation using the same
  line-association rule as `lib/type/static/constrain.lua`'s `get_ann`/`collect_preceding_run`
  (inline-same-line takes priority; else scan backward skipping blank/comment-only lines,
  requiring source text — `M.analyze`'s signature gained a required third `source` parameter).
  Does NOT merge multiple consecutive annotation lines into an overload intersection (unlike the
  real checker) — 2+ is wholesale-skipped as ambiguous for positional attribution. Per-parameter
  types are sliced by a depth-aware top-level-comma split, each slice handed unmodified to the
  EXISTING `parse_annotation_members` (no new nested-shape check needed — a slice containing
  parens/braces is rejected by the same six-tag check that already rejects any non-six-tag
  member). Vararg functions and signature/parameter-count mismatches are wholesale-skipped
  (reason recorded). A function body's scope is always built fresh from `{}` plus only that
  function's own qualifying parameters — never the caller's ambient scope — which gives
  nested-function shadowing/isolation correctly by construction (verified by a dedicated test).
- **A real addressing bug was found and fixed during this work** (not part of the original
  task scope, authorized mid-task): `prover.lua`'s pass 2 (`emit_events`) hardcoded every
  tracked variable's identity path as `local_name_path(_, 0)` — correct only because locals are
  always single-name-at-index-0. A parameter can qualify at any position, so `ScopeVar` /
  `GuardHit` / `GuardEvent` gained a `kind: "local" | "param"` discriminator plus
  `root_path`/`index` fields, and pass 2 now dispatches to `local_name_path` or
  `func_param_path` with the real index (`prover.lua`'s new `var_identity_path`). A second,
  related bug was found in the same work: pass 1 populated its own scope for guard recognition
  but never emitted a `local_fact` event for parameters, so pass 2 never learned about them at
  all (`param_scope` now returns matching `LocalFactEvent`s, prepended to the function body's
  own event list via `prepend_facts`). Both bugs were caught by the new non-zero-index
  parameter test in `prover_test.lua` (an end-to-end replay test, not just a pass-1 shape test)
  before any corpus measurement was run.

### Coverage delta

| metric | run 1 | run 2 |
|---|---:|---:|
| guards found | 546 | 546 |
| guards handled | 17 (3.11%) | 23 (4.21%) |
| guards skipped | 529 | 523 |
| annotations parsed | 141 | 284 |
| annotations skipped | 196 | 757 |
| certificates emitted | 20 | 27 |
| replay pass | 20 | 27 |
| replay fail | 0 | 0 |
| judgments | 20 | 27 |
| total analyze_ms (summed) | 105.471 | 124.725 |
| total emit_ms (summed) | 72.736 | 64.903 |
| combined corpus bytes | 791,033 | 791,033 (same corpus) |

`guards_found` is unchanged (546) — parameter-sourced scope population does not change what
`extract_guard` recognizes as a guard shape, only whether the guarded variable is tracked.

### Skip-reason breakdown

**`guards_skipped` (523 total, 100% single reason, same discipline as run 1):**

```
523x guarded variable not a tracked annotated local or parameter
```

The reason string itself was updated (run 1: `"guarded variable not a tracked annotated
local"`) to reflect that parameters are now a second thing a guarded variable can be tracked
as — the skip still means neither a local nor a parameter track it. No other guard-skip reason
occurred in this corpus (unchanged from run 1: no `truthiness guard unsupported`, no `guard
over an already-monomorphic fact`, no `guard target not structurally first in the carried
union`).

**`annotations_skipped` (757 total, up from 196 — categorized, not a single reason):**

| reason category | count |
|---|---:|
| `parameter N: unsupported annotation member '...'` (six-tag rejection, per-parameter — NEW) | 543 |
| `unsupported annotation member '...'` (six-tag rejection, whole-annotation — SAME as run 1's 196) | 196 |
| `function annotation is not in '(T1, ...) -> R' form` (NEW) | 10 |
| `multiple preceding-line function-type annotations (overload) not supported` (NEW) | 5 |
| `vararg function: positional parameter/signature attribution out of scope` (NEW) | 2 |
| `function signature parameter count (N) does not match declared parameter count (M)` (NEW) | 1 |

The 196-count "whole-annotation" bucket is IDENTICAL to run 1's total — confirms the pre-existing
local-annotation rejection path is unaffected by this change. The 543-count "per-parameter"
bucket is the dominant new contributor: annotations_skipped rose sharply not because more things
are broken, but because a single multi-parameter function-type signature with N non-six-tag
parameters now records N individual per-parameter skips (one per rejected position) where run 1
recorded nothing at all for it (function signatures were entirely invisible to run 1's scope
population). `function annotation is not in '(T1, ...) -> R' form` fires when a preceding-line
annotation exists but isn't shaped like a signature (e.g. a stray type-alias-only annotation line
immediately above a function, or an annotation that actually belongs to something else the
backward scan reached). `emission_skipped`: 0 entries in this corpus, same as run 1.

### Updated per-file table

| file | bytes | v3_exit | v3_ms | guards found | guards handled | annotations parsed | certs emitted | replay pass/fail | analyze_ms | emit_ms | judgments |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lib/dice/init.lua | 21129 | 1 | 36 | 27 | 0 | 36 | 0 | 0/0 | 10.089 | 0.530 | 0 |
| lib/platform/daemon/init.lua | 71669 | 1 | 36 | 58 | 2 | 29 | 2 | 2/0 | 8.450 | 5.920 | 2 |
| lib/compress/system.lua | 10952 | 1 | 33 | 5 | 0 | 10 | 0 | 0/0 | 4.501 | 0.513 | 0 |
| lib/actor/init.lua | 22525 | 1 | 34 | 9 | 1 | 14 | 1 | 1/0 | 5.584 | 1.865 | 1 |
| lib/platform/apps/finance/views.lua | 31368 | 0 | 36 | 19 | 2 | 15 | 2 | 2/0 | 5.076 | 6.299 | 2 |
| lib/exec/make_api.lua | 10651 | 0 | 31 | 5 | 0 | 4 | 0 | 0/0 | 1.022 | 0.309 | 0 |
| lib/exec/help.lua | 16574 | 1 | 32 | 14 | 0 | 8 | 0 | 0/0 | 1.742 | 0.352 | 0 |
| lib/columnar/init.lua | 12601 | 1 | 31 | 9 | 0 | 7 | 0 | 0/0 | 1.481 | 0.300 | 0 |
| lib/bookkeeping/import_qif.lua | 13482 | 0 | 31 | 2 | 0 | 6 | 0 | 0/0 | 0.740 | 0.312 | 0 |
| lib/platform/session_store/init.lua | 9183 | 1 | 31 | 18 | 3 | 3 | 3 | 3/0 | 0.960 | 6.578 | 3 |
| lib/platform/audit/init.lua | 10328 | 1 | 30 | 13 | 2 | 7 | 3 | 3/0 | 0.938 | 3.900 | 3 |
| lib/roman_numeral/init.lua | 16452 | 1 | 31 | 11 | 2 | 7 | 2 | 2/0 | 2.921 | 4.846 | 2 |
| lib/pid/init.lua | 7870 | 1 | 38 | 3 | 0 | 10 | 0 | 0/0 | 4.611 | 0.400 | 0 |
| lib/dsp/init.lua | 14997 | 1 | 34 | 3 | 0 | 16 | 0 | 0/0 | 5.068 | 0.543 | 0 |
| lib/ai/providers/openai.lua | 863 | 1 | 36 | 2 | 0 | 4 | 0 | 0/0 | 0.321 | 0.258 | 0 |
| lib/type/static/solve.lua | 221816 | 1 | 45 | 60 | 0 | 8 | 0 | 0/0 | 15.123 | 2.453 | 0 |
| lib/type/analysis/crescent_slice_parse.lua | 55409 | 0 | 33 | 63 | 2 | 32 | 2 | 2/0 | 5.079 | 4.626 | 2 |
| lib/sscanf/init.lua | 16850 | 1 | 35 | 15 | 1 | 1 | 1 | 1/0 | 4.002 | 6.040 | 1 |
| lib/platform/caps/create_instance.lua | 9047 | 1 | 30 | 10 | 1 | 3 | 1 | 1/0 | 0.940 | 0.879 | 1 |
| lib/platform/apps/system_dashboard/server.lua | 30949 | 1 | 35 | 43 | 1 | 14 | 2 | 2/0 | 3.776 | 1.687 | 2 |
| lib/ljsocket/init.lua | 40364 | 1 | 34 | 30 | 0 | 6 | 0 | 0/0 | 5.643 | 0.790 | 0 |
| lib/http/server.lua | 13123 | 1 | 33 | 6 | 0 | 2 | 0 | 0/0 | 1.820 | 0.555 | 0 |
| lib/ed25519/init.lua | 31093 | 1 | 31 | 11 | 3 | 9 | 4 | 4/0 | 19.088 | 6.320 | 4 |
| lib/argon2/init.lua | 37795 | 1 | 33 | 33 | 1 | 13 | 1 | 1/0 | 4.499 | 3.552 | 1 |
| lib/struct/init.lua | 16042 | 1 | 35 | 32 | 0 | 1 | 0 | 0/0 | 2.720 | 0.671 | 0 |
| lib/pdf/object.lua | 21535 | 0 | 29 | 22 | 1 | 5 | 2 | 2/0 | 6.254 | 2.106 | 2 |
| lib/oauth2/init.lua | 26366 | 1 | 33 | 23 | 1 | 14 | 1 | 1/0 | 2.277 | 2.299 | 1 |

`v3_exit`/`v3_ms` are unchanged in kind from run 1 (v3 baseline was not touched by this work) —
reproduced here from the same measurement run for a complete side-by-side table; still
process-startup-dominated at these file sizes, still not a throughput measurement (see run 1's
"Timing methodology note", unchanged and still applicable).

### New judgments — truth check

7 files gained judgments that did not exist in run 1 (cross-checked against run 1's per-file
judgment counts above): `lib/platform/daemon/init.lua` (0→2), `lib/actor/init.lua` (0→1),
`lib/platform/apps/finance/views.lua` (0→2), `lib/ed25519/init.lua` (2→4). Total new judgments:
2 + 1 + 2 + 2 = **7** (20 + 7 = 27, matching the aggregate delta). All other files' judgment
counts are unchanged from run 1 (including files that already had judgments in run 1 —
`session_store`, `audit`, `roman_numeral`, `crescent_slice_parse`, `sscanf`, `create_instance`,
`system_dashboard/server`, `argon2`, `pdf/object`, `oauth2` — none of these gained a NEW
judgment; their existing local-sourced judgments are unaffected and unchanged).

**This corpus produced only 7 new judgments, fewer than the 20-judgment minimum sample size
requested.** All 7 are hand-verified below rather than padding the sample with already-verified
run-1 judgments (which would not test anything new). This is reported as a corpus-size fact, not
worked around.

| # | file | location (manual) | claimed | branch | verdict |
|---|---|---|---|---|---|
| 1 | lib/platform/daemon/init.lua | L99-102, `--: (string \| nil) -> string; local function norm_host(h) if not h then return "" end ...` | `h` is falsy (nil) inside the body | match | TRUE |
| 2 | lib/platform/daemon/init.lua | L787-789, `--: (string \| nil) -> session_record \| nil; local function session_get(sid) if not sid then return nil end ...` | `sid` is falsy (nil) inside the body | match | TRUE |
| 3 | lib/actor/init.lua | L39-53 (method), `--: (ActorCtxShape, number\|nil) -> unknown; function ActorCtx:receive(timeout_ms) ... if timeout_ms then deadline = clock_fn() + timeout_ms / 1000.0 end` (implicit `self` occupies parameter index 0 for a `:`-method; `timeout_ms` is index 1 — non-zero-index parameter, exercising the addressing fix directly) | `timeout_ms` is "rest of falsy" (number) inside the body (no else branch, so only the rest citation exists) | rest | TRUE |
| 4 | lib/platform/apps/finance/views.lua | L107-109, `--: (View, string \| nil) -> (); local function set_error(view, err) if err ~= nil then view.error = err end end` (`err` at parameter index 1) | `err` is non-nil (string) inside the body | rest | TRUE |
| 5 | lib/platform/apps/finance/views.lua | L668-682, `--: (AppApi, string \| nil) -> View; M.report_balance_sheet = function(app, as_of_date) ... if as_of_date ~= nil then local bs, err = app.get_balance_sheet(as_of_date) ...` (assign-stmt func-expr; `as_of_date` at parameter index 1) | `as_of_date` is non-nil (string) inside the body | rest | TRUE (`app.get_balance_sheet` and `#as_of_date`-shaped uses are consistent with a string) |
| 6 | lib/ed25519/init.lua | L51-60, `--: (string \| nil) -> (string, string) \| (nil, string); local function keypair(seed) if seed then ... else local ret = lib.crypto_sign_ed25519_keypair(_pk, _sk) ... end end` | `seed` is falsy (nil) inside the `else` body | match | TRUE |
| 7 | lib/ed25519/init.lua | same site, `then` body (`if #seed ~= 32 then ... end; lib.crypto_sign_ed25519_seed_keypair(_pk, _sk, seed)`) | `seed` is "rest of falsy" (string) inside the `then` body | rest | TRUE (`#seed` and the FFI call both require a string) |

**7/7 verified TRUE. No wrong judgment found.** Row 3 (`timeout_ms`, an `ActorCtx:receive`
method) is the load-bearing case for the addressing-bug fix described above: `self` (implicit,
from the `:`-method syntax) occupies parameter index 0, so `timeout_ms` is tracked at index 1 —
exactly the case a hardcoded `local_name_path(_, 0)` would have either misaddressed or failed to
replay. It replayed green, over real corpus code, not just the synthetic regression test added
to `prover_test.lua`.

### Wall-clock comparison

Run 1 total `analyze_ms` (summed): 105.471ms. Run 2: 124.725ms (+18.3%, in-process pass-1
timing over the same 27 files — more work per file now that parameter signatures are parsed).
Run 1 total `emit_ms` (summed, includes inline replay): 72.736ms. Run 2: 64.903ms (variance
between runs on this timing scale is dominated by `os.clock()` resolution and system noise at
sub-millisecond-to-low-double-digit-millisecond magnitudes per file, not attributed to a specific
code change — see run 1's own "Timing methodology note" for the same caveat applied to
`analyze_ms`/`emit_ms` generally). `v3_ms` (the v3 baseline) is unaffected by this work, still in
the same 29-45ms process-startup-dominated band as run 1.
