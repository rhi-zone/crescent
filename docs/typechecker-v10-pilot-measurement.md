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

## Run 3 — loop-invariant certificates (commit `4a741cae`)

Measured against commit `4a741cae` ("v10 fixpoint prover — loop-invariant certificates from
real source (Phase 3)"), which is both the pilot-code commit and HEAD at measurement time.
`bin/cr test lib/type/v10_kernel/pilot/` 9/9 files green, 338 assertions (up from run 2's 249 —
`fixpoint_v1_test.lua` (Phase 2) and `fixpoint_prover_test.lua` (Phase 3) added since).
`bin/cr test lib/type/v10_cleanroom/` 3/3 files green, 1044 assertions (unchanged — not touched
by Phase 3). Both reconfirmed at this HEAD. No pilot source was modified to produce these
numbers; drivers are disposable scripts outside the repo (`/tmp/v10_parity/scan_loops_run3.lua`,
`measure_run3.lua`, `probe_certified_run3.lua`).

What run 3 adds over runs 1–2: `fixpoint_prover.analyze_file` (new in `4a741cae`) attempts a
`loop-invariant-discharge` certificate for every `NODE_WHILE_STMT` × every tracked
six-tag-union local/parameter in scope at it, root-replayed via `M.replay` (root-strict, not
`M.observe`). The narrowing prover (`prover.analyze_file`) is measured alongside, unchanged,
for run-1/2 comparability.

### Corpus

Runs 1–2's 27 files, plus every additional file found by an exact full-tree scan: ran the real
`fixpoint_prover.analyze_file` over all `lib/**/*.lua` (997 files; same exclusions as run 1 —
`lib/type/v10_kernel/`, `lib/type/v10_cleanroom/`, `*_test.lua`) and kept every file with
`loop_vars_attempted > 0` (a tracked union-annotated variable in scope at a while-loop). This
is the prover's own tracking rule applied verbatim, not a grep heuristic. Scan result: 376/997
files contain at least one while-loop; **24** have a tracked variable in scope at one. Three
(`lib/actor/init.lua`, `lib/platform/audit/init.lua`, `lib/struct/init.lua`) were already in
the run-1/2 corpus; the **21 additions**:

`lib/async_queue/init.lua`, `lib/bencode/init.lua`, `lib/bookkeeping/store.lua`,
`lib/cli/init.lua`, `lib/email/init.lua`, `lib/format/yaml/init.lua`, `lib/pdf/filter.lua`,
`lib/pdf/form.lua`, `lib/platform/apps/charactercardv2/server.lua`,
`lib/platform/apps/finance/tui.lua`, `lib/platform/caps/http_client.lua`,
`lib/platform/caps/shared_db.lua`, `lib/stream/init.lua`, `lib/string_ext/init.lua`,
`lib/string_template/init.lua`, `lib/type/static/constrain.lua`, `lib/type/static/env.lua`,
`lib/type/static/errors.lua`, `lib/type/static/unify.lua`, `lib/type/v9/annot/init.lua`,
`lib/unified/remark_github/init.lua`.

Final corpus: 48 files, 1,698,092 combined bytes.

### Aggregate results

Narrowing (run-1/2-comparable) and loop-invariant metrics, side by side. The 27 run-1/2 files'
narrowing subtotals are IDENTICAL to run 2 (guards found 546, handled 23, annotations parsed
284, certificates 27, replay 27/0) — Phase 3's only change to the narrowing path
(`prover_narrow.lua` emitting an additional `while_loop` event that `prover.lua` ignores)
altered no narrowing behavior. Checked by summing the per-file table below over those 27 rows.

| metric | run 2 (27 files) | run 3 (48 files) |
|---|---:|---:|
| guards found | 546 | 1239 |
| guards handled | 23 | 35 |
| guards skipped | 523 | 1204 |
| annotations parsed | 284 | 458 |
| annotations skipped | 757 | 2061 |
| narrowing certificates emitted | 27 | 40 |
| narrowing replay pass / fail | 27 / 0 | 40 / 0 |
| narrowing judgments | 27 | 40 |
| **while-loops found** | — | **199** |
| **(loop, var) pairs attempted** | — | **48** |
| **(loop, var) pairs certified (root-accepted)** | — | **7** |
| **loop-invariant judgments (root-replayed)** | — | **7** |
| loop-invariant replay failures | — | 0 |

**The headline number is 7**: seven root-accepted loop-invariant certificates over real,
unmodified corpus code, in 3 files (`lib/type/static/constrain.lua` 3,
`lib/type/static/env.lua` 2, `lib/unified/remark_github/init.lua` 2). Zero replay failures —
every certificate the prover chose to emit was accepted root-strict.

Guard-skip reasons (narrowing, 1204 total): 1202x `guarded variable not a tracked annotated
local or parameter` (same dominant reason as runs 1–2); 2x `truthiness guard unsupported:
declared union includes plain 'boolean'` — the first real-corpus occurrence of this documented
scope limit (runs 1–2 explicitly noted it never fired in their corpus); both from
`lib/type/static/constrain.lua`, a run-3 corpus addition, so runs 1–2's statement remains true
of their own corpus. Annotation-skip reasons: same taxonomy as run 2 (six-tag rejections
dominate, whole-annotation and per-parameter), no new categories. `emission_skipped`
(narrowing): 0, same as runs 1–2.

### Loop skip-reason breakdown

`loop_vars_attempted` counts (loop, var) pairs; `no tracked variable in scope` counts loops.
199 loops − 159 no-tracked-var loops = 40 loops with at least one tracked variable, carrying
48 (loop, var) pairs; 7 certified + 41 skipped = 48 ✓.

| reason | count |
|---|---:|
| `no tracked variable in scope at this loop` (per loop) | 159 |
| `control-flow statement breaks persistence chaining (out of scope)` (per pair) | 41 |
| `copy source not independently established at the assign point` | 0 |
| `assignment RHS out of scope (not literal or bare-identifier copy)` | 0 |
| `multi-target/multi-value assignment to the invariant variable (out of scope)` | 0 |
| `empty loop body: no persistence chain from loop head to back edge under this theory` | 0 |
| `reassigned type not a member of the declared invariant` | 0 |
| replay rejected an emitted certificate | 0 |

Every real-corpus skip is one of two reasons. All 41 in-body skips are control-flow (an
`if`/`while`/`for`/`return`/`break` at the loop body's own top level) — the conservative
persistence rule from the Phase-3 §8.3 doc correction. The assignment-shaped skip reasons
(copy/RHS/multi-target), the empty-body edge case, and the documented
`tag_true`/`tag_false`-vs-`tag_boolean` literal mismatch never occurred naturally; they are
exercised only by `fixpoint_prover_test.lua`'s fixtures. **Consequence for the two parked
scope reductions** (assign-copy-transfer unreachability under the corrected `Pa` convention;
vacuous-discharge reasoning): their real-corpus coverage cost in this measurement is **zero**
— no (loop, var) pair was lost to a copy-RHS or literal-reassignment case; every lost pair
died on control-flow chaining, which is a different (and larger) gap.

All 7 certified pairs are **persistence-only** invariants (the body never touches the tracked
variable; `ty_sub` closed by `ty-sub-refl`): the `assign-literal-transfer` path produced zero
real-corpus certificates and is exercised only by the test fixture. Stated plainly: on this
corpus, the entire assignment-transfer half of the fixpoint theory (§2) went unused; the
certificates that exist stand on `seq-persist` + `loop-invariant-discharge` +
`pilot-initial-facts-v1` alone.

### Per-file table

Columns as in runs 1–2, plus loop metrics. `parse_ms`/`pass1_ms` are separately-timed direct
calls to the same parse/pass-1 code `fixpoint_prover.analyze_file` runs internally;
`fixTotal_ms` is the whole `fixpoint_prover.analyze_file` call (which re-runs parse + pass 1
internally, so `fixTotal_ms` INCLUDES its own parse/pass-1 cost; the separate columns are for
scale, not exact decomposition — separate invocations, so JIT/cache state differs).

| file | bytes | v3_exit | v3_ms | gF | gH | annP | certs | rP/rF | analyze_ms | emit_ms | judg | loops | lvAtt | lvCert | parse_ms | pass1_ms | fixTotal_ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| lib/dice/init.lua | 21129 | 1 | 339 | 27 | 0 | 36 | 0 | 0/0 | 14.081 | 0.938 | 0 | 3 | 0 | 0 | 10.124 | 1.900 | 14.244 |
| lib/platform/daemon/init.lua | 71669 | 1 | 642 | 58 | 2 | 29 | 2 | 2/0 | 17.472 | 15.852 | 2 | 0 | 0 | 0 | 6.592 | 1.706 | 10.690 |
| lib/compress/system.lua | 10952 | 1 | 143 | 5 | 0 | 10 | 0 | 0/0 | 9.284 | 0.643 | 0 | 0 | 0 | 0 | 4.450 | 0.555 | 4.527 |
| lib/actor/init.lua | 22525 | 1 | 228 | 9 | 1 | 14 | 1 | 1/0 | 9.757 | 7.324 | 1 | 3 | 4 | 0 | 4.243 | 1.075 | 47.912 |
| lib/platform/apps/finance/views.lua | 31368 | 0 | 250 | 19 | 2 | 15 | 2 | 2/0 | 6.679 | 12.868 | 2 | 0 | 0 | 0 | 4.897 | 1.159 | 4.901 |
| lib/exec/make_api.lua | 10651 | 0 | 197 | 5 | 0 | 4 | 0 | 0/0 | 2.546 | 0.512 | 0 | 1 | 0 | 0 | 1.485 | 0.414 | 2.948 |
| lib/exec/help.lua | 16574 | 1 | 249 | 14 | 0 | 8 | 0 | 0/0 | 3.832 | 0.995 | 0 | 4 | 0 | 0 | 2.963 | 0.745 | 9.615 |
| lib/columnar/init.lua | 12601 | 1 | 177 | 9 | 0 | 7 | 0 | 0/0 | 2.631 | 0.717 | 0 | 0 | 0 | 0 | 1.645 | 0.421 | 2.890 |
| lib/bookkeeping/import_qif.lua | 13482 | 0 | 203 | 2 | 0 | 6 | 0 | 0/0 | 5.908 | 2.493 | 0 | 1 | 0 | 0 | 3.705 | 0.424 | 4.741 |
| lib/platform/session_store/init.lua | 9183 | 1 | 236 | 18 | 3 | 3 | 3 | 3/0 | 3.641 | 12.037 | 3 | 0 | 0 | 0 | 1.831 | 0.459 | 2.200 |
| lib/platform/audit/init.lua | 10328 | 1 | 240 | 13 | 2 | 7 | 3 | 3/0 | 3.360 | 12.498 | 3 | 2 | 2 | 0 | 1.264 | 0.586 | 13.812 |
| lib/roman_numeral/init.lua | 16452 | 1 | 266 | 11 | 2 | 7 | 2 | 2/0 | 6.147 | 3.982 | 2 | 0 | 0 | 0 | 2.940 | 0.808 | 3.556 |
| lib/pid/init.lua | 7870 | 1 | 137 | 3 | 0 | 10 | 0 | 0/0 | 2.519 | 0.573 | 0 | 0 | 0 | 0 | 1.213 | 0.394 | 5.257 |
| lib/dsp/init.lua | 14997 | 1 | 196 | 3 | 0 | 16 | 0 | 0/0 | 6.766 | 0.511 | 0 | 1 | 0 | 0 | 2.048 | 0.366 | 2.792 |
| lib/ai/providers/openai.lua | 863 | 1 | 160 | 2 | 0 | 4 | 0 | 0/0 | 0.509 | 0.526 | 0 | 0 | 0 | 0 | 0.186 | 0.044 | 2.738 |
| lib/type/static/solve.lua | 221816 | 1 | 1706 | 60 | 0 | 8 | 0 | 0/0 | 13.559 | 2.511 | 0 | 14 | 0 | 0 | 17.751 | 2.797 | 10.974 |
| lib/type/analysis/crescent_slice_parse.lua | 55409 | 0 | 207 | 63 | 2 | 32 | 2 | 2/0 | 6.816 | 3.255 | 2 | 16 | 0 | 0 | 2.925 | 0.776 | 5.943 |
| lib/sscanf/init.lua | 16850 | 1 | 104 | 15 | 1 | 1 | 1 | 1/0 | 2.210 | 1.933 | 1 | 8 | 0 | 0 | 1.751 | 0.546 | 3.105 |
| lib/platform/caps/create_instance.lua | 9047 | 1 | 125 | 10 | 1 | 3 | 1 | 1/0 | 5.574 | 2.051 | 1 | 0 | 0 | 0 | 1.818 | 0.223 | 2.500 |
| lib/platform/apps/system_dashboard/server.lua | 30949 | 1 | 191 | 43 | 1 | 14 | 2 | 2/0 | 8.809 | 5.413 | 2 | 1 | 0 | 0 | 3.697 | 0.831 | 5.393 |
| lib/ljsocket/init.lua | 40364 | 1 | 162 | 30 | 0 | 6 | 0 | 0/0 | 4.961 | 0.564 | 0 | 1 | 0 | 0 | 2.893 | 1.936 | 5.373 |
| lib/http/server.lua | 13123 | 1 | 137 | 6 | 0 | 2 | 0 | 0/0 | 1.633 | 0.426 | 0 | 1 | 0 | 0 | 0.776 | 0.202 | 1.931 |
| lib/ed25519/init.lua | 31093 | 1 | 123 | 11 | 3 | 9 | 4 | 4/0 | 10.437 | 9.273 | 4 | 1 | 0 | 0 | 6.565 | 0.979 | 4.998 |
| lib/argon2/init.lua | 37795 | 1 | 135 | 33 | 1 | 13 | 1 | 1/0 | 5.091 | 1.709 | 1 | 0 | 0 | 0 | 4.687 | 2.115 | 4.368 |
| lib/struct/init.lua | 16042 | 1 | 90 | 32 | 0 | 1 | 0 | 0/0 | 2.367 | 0.342 | 0 | 2 | 2 | 0 | 1.313 | 0.550 | 6.539 |
| lib/pdf/object.lua | 21535 | 0 | 91 | 22 | 1 | 5 | 2 | 2/0 | 3.304 | 5.387 | 2 | 10 | 0 | 0 | 1.425 | 0.537 | 2.004 |
| lib/oauth2/init.lua | 26366 | 1 | 124 | 23 | 1 | 14 | 1 | 1/0 | 11.013 | 2.442 | 1 | 7 | 0 | 0 | 6.716 | 3.613 | 4.266 |
| lib/async_queue/init.lua | 17384 | 1 | 99 | 7 | 1 | 11 | 2 | 2/0 | 3.440 | 4.009 | 2 | 5 | 3 | 0 | 1.522 | 0.402 | 6.733 |
| lib/bencode/init.lua | 6400 | 1 | 68 | 10 | 0 | 3 | 0 | 0/0 | 1.596 | 1.177 | 0 | 2 | 1 | 0 | 2.563 | 0.701 | 1.666 |
| lib/bookkeeping/store.lua | 31286 | 0 | 129 | 60 | 0 | 8 | 0 | 0/0 | 2.151 | 0.555 | 0 | 4 | 2 | 0 | 5.516 | 1.974 | 8.278 |
| lib/cli/init.lua | 17076 | 1 | 108 | 9 | 0 | 6 | 0 | 0/0 | 4.524 | 0.342 | 0 | 2 | 2 | 0 | 2.235 | 0.756 | 7.846 |
| lib/email/init.lua | 31028 | 1 | 146 | 30 | 2 | 23 | 2 | 2/0 | 5.012 | 3.920 | 2 | 4 | 1 | 0 | 2.725 | 0.782 | 5.301 |
| lib/format/yaml/init.lua | 37504 | 1 | 96 | 48 | 0 | 5 | 0 | 0/0 | 7.619 | 0.669 | 0 | 21 | 1 | 0 | 2.789 | 1.588 | 18.133 |
| lib/pdf/filter.lua | 21131 | 0 | 85 | 36 | 1 | 10 | 1 | 1/0 | 3.765 | 5.184 | 1 | 8 | 1 | 0 | 1.657 | 0.596 | 4.752 |
| lib/pdf/form.lua | 23902 | 0 | 119 | 43 | 1 | 11 | 1 | 1/0 | 2.222 | 2.355 | 1 | 7 | 3 | 0 | 1.146 | 0.460 | 7.851 |
| lib/platform/apps/charactercardv2/server.lua | 140228 | 1 | 833 | 162 | 2 | 23 | 2 | 2/0 | 14.252 | 3.825 | 2 | 2 | 2 | 0 | 15.415 | 2.527 | 24.111 |
| lib/platform/apps/finance/tui.lua | 13973 | 0 | 158 | 17 | 0 | 4 | 0 | 0/0 | 2.881 | 0.259 | 0 | 1 | 1 | 0 | 0.932 | 0.281 | 14.423 |
| lib/platform/caps/http_client.lua | 26583 | 1 | 179 | 59 | 0 | 9 | 0 | 0/0 | 3.073 | 0.470 | 0 | 10 | 2 | 0 | 1.692 | 0.445 | 2.495 |
| lib/platform/caps/shared_db.lua | 21947 | 1 | 157 | 11 | 0 | 2 | 0 | 0/0 | 4.219 | 1.806 | 0 | 2 | 2 | 0 | 9.341 | 0.422 | 4.395 |
| lib/stream/init.lua | 15362 | 1 | 99 | 18 | 2 | 7 | 2 | 2/0 | 3.663 | 3.333 | 2 | 15 | 2 | 0 | 1.329 | 0.293 | 5.386 |
| lib/string_ext/init.lua | 10261 | 0 | 81 | 7 | 1 | 6 | 1 | 1/0 | 1.637 | 3.217 | 1 | 5 | 1 | 0 | 0.739 | 0.217 | 2.769 |
| lib/string_template/init.lua | 10867 | 1 | 72 | 7 | 0 | 5 | 0 | 0/0 | 2.545 | 0.297 | 0 | 1 | 1 | 0 | 0.683 | 0.179 | 4.813 |
| lib/type/static/constrain.lua | 278721 | 1 | 1824 | 106 | 0 | 12 | 0 | 0/0 | 16.543 | 2.362 | 0 | 7 | 6 | 3 | 16.155 | 3.333 | 74.629 |
| lib/type/static/env.lua | 65876 | 1 | 531 | 17 | 0 | 1 | 0 | 0/0 | 3.404 | 0.926 | 0 | 8 | 2 | 2 | 2.265 | 0.465 | 29.516 |
| lib/type/static/errors.lua | 21211 | 1 | 127 | 9 | 0 | 14 | 0 | 0/0 | 4.709 | 2.222 | 0 | 2 | 1 | 0 | 1.366 | 0.292 | 3.134 |
| lib/type/static/unify.lua | 77343 | 0 | 309 | 13 | 1 | 1 | 1 | 1/0 | 3.688 | 2.164 | 1 | 2 | 1 | 0 | 8.895 | 1.309 | 23.544 |
| lib/type/v9/annot/init.lua | 26980 | 0 | 95 | 16 | 1 | 7 | 1 | 1/0 | 4.754 | 1.883 | 1 | 9 | 2 | 0 | 2.696 | 1.198 | 6.943 |
| lib/unified/remark_github/init.lua | 11996 | 1 | 82 | 8 | 0 | 6 | 0 | 0/0 | 2.927 | 0.460 | 0 | 6 | 3 | 2 | 1.169 | 0.232 | 9.695 |

### Truth check — all 7 loop-invariant judgments, individually verified

Correlation methodology, same as run 1: a disposable parallel walk
(`/tmp/v10_parity/probe_certified_run3.lua`) re-implements `fixpoint_prover`'s per-(loop, var)
classification over pass 1's `while_loop` events, purely to attach source line + variable name
to each attempt, then cross-checks its predicted certified count against the REAL
`fixpoint_prover.analyze_file` stats per file — 3/3 files MATCH (predicted 3/2/2 = real 3/2/2).
Each row was then hand-verified: opening the file, reading the loop, and checking the claim —
`holds_at(entry_of(body), X, Tinv)`, i.e. the variable's declared union actually holds at the
loop head on every iteration.

All 7 are persistence-only certificates (the loop body never mentions the tracked variable),
so each hand-check reduces to: (a) confirm no body statement assigns the variable (including
shadowing subtleties), (b) confirm the variable is not assigned anywhere else in the function
in a way that could put a non-union value in it at the loop head, and (c) confirm the declared
annotation is the one claimed. Lua locals/parameters cannot alias, so (a)/(b) are decidable by
reading the function.

| # | file | location (manual) | variable / claimed invariant | verdict |
|---|---|---|---|---|
| 1 | lib/type/static/constrain.lua | L1481–1485, `while i < as + al - 1 do` (match-arm resolve loop inside `resolve_annotation_type`); body = two `arms[...] = resolve_annotation_type(...)` assigns + `i = i + 2` | `allow_unapplied : boolean\|nil` (parameter 3 of `resolve_annotation_type`, signature L840) holds at loop head every iteration | TRUE — body assigns only `arms` and `i`; the parameter is never assigned anywhere in the function (the file's own L825–829 comment: flip sites pass modified values to recursive calls instead of mutating) |
| 2 | same loop | `in_match_arm : boolean\|nil` (parameter 4) | TRUE — same reasoning |
| 3 | same loop | `in_func_ann : boolean\|nil` (parameter 5) | TRUE — same reasoning |
| 4 | lib/type/static/env.lua | L901–905, `while i < is + il - 1 do` (indexer-substitution loop inside `substitute_inner`); body = two `new_indexers[...] = substitute_inner(...)` assigns + `i = i + 2` | `in_match_arm_subst : boolean\|nil` (parameter 5 of `substitute_inner`, signature L690) | TRUE — body assigns only `new_indexers` and `i`; parameter never assigned in the function (grep: no assignment anywhere) |
| 5 | lib/type/static/env.lua | L1024–1028, `while i < as + al - 1 do` (match-arm substitution loop, same function); body = two `new_arms[...] = ...` assigns + `i = i + 2` | same variable | TRUE — same reasoning |
| 6 | lib/unified/remark_github/init.lua | L127–128, `while j <= len and (s:byte(j) or 0) >= 48 and ... do j = j + 1 end` (bare-issue digit scan inside `find_next`); body = `j = j + 1` | `repo : string\|nil` (parameter 2 of `find_next`, signature L113) | TRUE — body assigns only `j`; `repo` is never assigned anywhere in the file |
| 7 | lib/unified/remark_github/init.lua | L169–170, same digit-scan shape (cross-repo issue branch) | same variable | TRUE — same reasoning |

**7/7 verified TRUE. No wrong judgment found.** Caveats, stated plainly: all 7 are
persistence-only (`ty-sub-refl`) invariants over variables the loop body never touches — the
weakest interesting form of the theory (no assignment transfer, no union-membership `ty_sub`
chain exercised on real code); each carries the taint of `pilot-loop-facts-v1`,
`pilot-stmt-seq-facts-v1`, `pilot-stmt-preserves-facts-v1`, `pilot-initial-facts-v1`, and
`ty-sub-refl` (honest reality-boundary/structural-truth pricing, per the theory's design); and
the entry fact is the `pilot-initial-facts-v1` annotation-trust citation at the loop head, not
a derived fact from preceding code (the sequential-flow substrate for deriving it is §8.3's
same-block straight-line case only, and no pre-loop straight-line derivation was attempted by
this phase). 7 judgments is the entire real-corpus population at this commit, not a sample.

### Wall-clock

Summed over 48 files: narrowing `analyze_ms` 269.53, narrowing `emit_ms` 149.21 (both within
run-2 per-byte expectations given the corpus roughly doubled in bytes); `parse_ms` 184.733,
`pass1_ms` 44.613 (separately-timed direct calls); `fixpoint_total_ms` 456.63 (whole
`fixpoint_prover.analyze_file` calls, each internally re-running parse + pass 1). The heaviest
fixpoint file is `lib/type/static/constrain.lua` at 74.6ms (278KB, 7 loops, 6 attempted pairs,
3 certificates with their seq-persist chains and observe-per-step replays).

**v3 baseline divergence, flagged not explained**: `v3_ms` (`timeout 30 bin/cr check <file>`,
same `date +%s%N`-around-subprocess methodology as runs 1–2) no longer sits in runs 1–2's
narrow 29–45ms band — run 3 measured 68–1824ms over the same command shape, with the largest
files clearly dominating (`solve.lua` 1706ms and `constrain.lua` 1824ms vs run 2's 45ms for
the same `solve.lua`). The runs-1–2 "process-startup-dominated" characterization does NOT hold
at this measurement. Contributing factors were not investigated (out of this measurement's
scope); candidates include v3 checker changes between measurement dates and system state.
The numbers are reported as measured; cross-run `v3_ms` comparisons should not be treated as a
controlled series.

### Reproduction

Drivers (disposable, not part of the repo): `/tmp/v10_parity/scan_loops_run3.lua` (corpus
scan), `/tmp/v10_parity/measure_run3.lua` (measurement), `/tmp/v10_parity/probe_certified_run3.lua`
(truth-check correlation). Run via:

```sh
REPO=/home/me/git/rhizone/crescent
"$REPO/bin/ld-musl-x86_64.so.1" "$REPO/bin/luajit-bin" /tmp/v10_parity/measure_run3.lua "$REPO"
```

## Run 4 — if/else branch-join control-flow chaining (commit `1a491500`)

Measured against commit `1a491500` ("v10 fixpoint prover — if/else branch-join control-flow
chaining"), HEAD at measurement time. `bin/cr test lib/type/v10_kernel/pilot/` 9/9 files green,
356 assertions (up from run 3's 338 — new fixpoint_prover_test.lua fixtures for the join, per
the taxonomy this run reports). `bin/cr test lib/type/v10_cleanroom/` 3/3 files green, 1044
assertions (unchanged — not touched). Both reconfirmed at this HEAD. No pilot source was
modified to produce these numbers; the run-3 driver scripts (`/tmp/v10_parity/measure_run3.lua`,
`/tmp/v10_parity/scan_loops_run3.lua`) were reused UNCHANGED against the new HEAD, plus two new
disposable scripts (`/tmp/v10_parity/identify_run4_pairs.lua` for per-pair correlation,
`/tmp/v10_parity/probe1.lua`/`probe2.lua`/`probe3.lua` for the ad-hoc soundness probes in the
truth-check below).

**What run 4 adds:** `fixpoint_prover.lua`'s loop-body walk now recurses into a single-clause
`if`/`if-else` (docs/typechecker-v10-fixpoint-proposal.md §4's `cf_join`/`narrow-join`, already
declared in `fixpoint_v1.lua`'s v3 signature bump since run 3's own commit but never cited by
the prover until now), deriving each branch's own fact and merging at the join point. Elseif
chains and any control-flow construct (nested if/while/for/etc.) inside a branch remain
conservative, counted skips — the join rule as designed is strictly binary and one level of
nesting only, per the brief.

### Corpus

Same 48 files as run 3 (27 from runs 1–2 + 21 run-3 additions), re-confirmed via
`scan_loops_run3.lua` re-run unchanged against this HEAD: **24/997** files still have a tracked
variable in scope at a while-loop (`with_tracked_var_at_loop=24`), and the 24-file NAME LIST is
byte-identical to run 3's. **No newly-eligible files** — expected and unsurprising, since
`loop_vars_attempted` eligibility comes entirely from `prover_narrow.lua`'s scope-tracking pass,
which this change does not touch; only whether an already-attempted pair CERTIFIES or SKIPS
could move, and did.

### Aggregate results

Narrowing metrics (guards/annotations/certificates) are IDENTICAL to run 3 (this change touches
no narrowing code) — omitted here; see run 3's own table for those. Loop-invariant metrics,
side by side:

| metric | run 3 (48 files) | run 4 (48 files) | delta |
|---|---:|---:|---:|
| while-loops found | 199 | 199 | 0 |
| (loop, var) pairs attempted | 48 | 48 | 0 |
| **(loop, var) pairs certified (root-accepted)** | **7** | **12** | **+5** |
| loop-invariant judgments (root-replayed) | 7 | 12 | +5 |
| loop-invariant replay failures | 0 | 0 | 0 |

**The headline number is 12** — five more root-accepted loop-invariant certificates than run 3,
all five newly closed by the if/else join, zero regressions (every run-3 certificate still
certifies; zero replay failures on either run). Certified pairs now span **5 files**
(`lib/type/static/constrain.lua` 6, `lib/type/static/env.lua` 2,
`lib/unified/remark_github/init.lua` 2, `lib/async_queue/init.lua` 1,
`lib/type/v9/annot/init.lua` 1) — up from run 3's 3 files. **All 12 certificates remain
persistence-only** (`ty-sub-refl`/`ty-sub-union-of-subsets` closing `ty_sub(Tp, Tinv)` without
ever exercising `assign-literal-transfer`'s own union-membership chain on real code): every
newly-certified pair's tracked variable is untouched by BOTH branches of its if-statement, not
reassigned — the assignment-transfer half of the theory (§2) is still exercised only by
`fixpoint_prover_test.lua`'s fixtures, unchanged from run 3's own finding. This is reported
plainly, not as a shortfall of this run's own scope (control-flow chaining) — closing that gap
was this run's job; assignment-transfer's real-corpus coverage is an independent, still-open
gap.

### Loop skip-reason breakdown, with run-3 deltas

199 loops − 159 no-tracked-var loops = 40 loops with at least one tracked variable, carrying 48
(loop, var) pairs; 12 certified + 36 skipped = 48 ✓.

| reason | run 3 | run 4 | delta |
|---|---:|---:|---:|
| `no tracked variable in scope at this loop` (per loop) | 159 | 159 | 0 |
| `control-flow statement breaks persistence chaining (out of scope)` (per pair) | 41 | 28 | −13 |
| `elseif chain in loop body not yet supported for branch-join chaining (out of scope)` (per pair) | — (bucket did not exist) | 6 | +6 (new) |
| `multi-target/multi-value assignment to the invariant variable (out of scope)` | 0 | 2 | +2 |
| `copy source not independently established at the assign point` | 0 | 0 | 0 |
| `assignment RHS out of scope (not literal or bare-identifier copy)` | 0 | 0 | 0 |
| `empty loop body: no persistence chain from loop head to back edge under this theory` | 0 | 0 | 0 |
| `reassigned type not a member of the declared invariant` | 0 | 0 | 0 |
| replay rejected an emitted certificate | 0 | 0 | 0 |

Zeros are zeros with reasons, restated per-run: the assignment-shaped skip reasons, the
empty-body edge case, and the tag_true/tag_false-vs-tag_boolean mismatch still never occur
naturally in this corpus at this HEAD; only `fixpoint_prover_test.lua`'s fixtures exercise them.

The run-3 "control-flow" bucket (41) decomposes exactly: **5** newly certified (this run's own
join), **6** reclassified into the new, more specific `elseif chain` bucket (an if/elseif/else
that was ALREADY being counted as "control-flow breaks chaining" in run 3, now correctly
attributed to the specific reason it still can't chain — the join rule is strictly binary), **2**
newly surfaced as `multi-target/multi-value assignment` (a multi-target assignment that was
PREVIOUSLY hidden one level up behind the enclosing if-statement's own "control-flow" skip in
run 3 — now that the enclosing if is walked into, the walk reaches this deeper, genuinely
different skip reason), and **28** still genuinely blocked by an unsupported construct (nested
if/while/for/return/break inside a branch, or any other unrecognized statement) — 5 + 6 + 2 +
28 = 41 ✓.

### Truth check — all 5 NEW loop-invariant judgments, individually verified

Correlation methodology: a disposable script (`/tmp/v10_parity/identify_run4_pairs.lua`)
re-walks `prover_narrow`'s own `while_loop` events per file (the exact pass-1 data
`fixpoint_prover` consumes) to attach a tracked-variable name + declared-union to every
attempted pair, cross-checked against the REAL `fixpoint_prover.analyze_file` per-file
`loop_vars_attempted`/`loop_vars_certified` counts — exact match on all 5 files carrying a
change. Each of the 5 NEW pairs was then hand-verified by opening the file and reading the
loop; the 7 run-3 pairs are unaffected (same certificates, re-confirmed still certifying at
this HEAD, not re-verified here — see run 3's own truth-check table).

| # | file | location (manual) | variable / claimed invariant | branch shape | verdict |
|---|---|---|---|---|---|
| 1 | `lib/type/static/constrain.lua` | L1197–1206, `while i < is + il - 1 do` (table-indexer resolve loop inside `resolve_annotation_type`); body = two `resolve_annotation_type(...)` calls, an else-less `if (kt == ctx.T_ANY or vt == ctx.T_ANY) and tbl_ann_line ~= 0 then warn(ctx, ...) end`, then two `indexers[...] = ` assigns + `i = i + 2` | `allow_unapplied : boolean\|nil` (parameter 3, signature L840) | else-less if; body is a bare `warn(...)` call (rule (c), preserving); no else | TRUE — neither the if's body nor anything else in the loop assigns the parameter; `warn` is a call-statement, not an assignment |
| 2 | same loop | `in_match_arm : boolean\|nil` (parameter 4) | same | same | TRUE — same reasoning |
| 3 | same loop | `in_func_ann : boolean\|nil` (parameter 5) | same | same | TRUE — same reasoning |
| 4 | `lib/async_queue/init.lua` | `Queue:tick`'s 2nd while-loop, `while j <= #self._pending do ... end` (cancelled-task sweep); body = `local task = ...`, `if task.cancelled then arr_remove(self._pending, j); self._stats.pending = ... else j = j + 1 end` | `clock : number\|nil` (parameter of `tick`) | if/else, both branches preserving (assignments target `self._pending`/`self._stats.pending`/`j`, never `clock`) | TRUE — `clock`/`clock_` is not assigned anywhere in this loop's body; `tick`'s OTHER two while-loops that also track `clock` still correctly skip (one hits a nested `if` inside its branch, the other a bare `break` inside its branch — both genuine, still-unsupported constructs, not silently miscounted) |
| 5 | `lib/type/v9/annot/init.lua` | nested `while not at(p, ",") and not at(p, "}") and peek(p) ~= nil do ... end` inside `parse_record`'s `"#"` (meta-slot) branch; body = `if at(p,"{") or at(p,"(") or at(p,"[") or at(p,"<") then skip_balanced(p) else advance(p) end` | `feature : string\|nil` (local, declared L202) | if/else, both branches a single call-statement (`skip_balanced`/`advance`), preserving | TRUE — neither branch assigns `feature`; `parse_record`'s OUTER while-loop (the one with the actual 4-clause `if/elseif/elseif/else` that ASSIGNS `feature` in three of its four clauses) correctly remains a skip under the new `elseif chain ... not yet supported` reason, not silently miscounted as certified |

**5/5 verified TRUE. No false certificate found on real corpus.** Two of the five (#4, #5)
double as small negative-case confirmations in passing: in both files, a SIBLING while-loop
over the SAME tracked variable that hits a genuinely unsupported construct (nested `if`,
`break`, an elseif chain that actually mutates the variable) correctly remains uncertified —
the new code is not merely "more permissive," it is exactly as conservative as designed on the
constructs it does not yet handle. All 5 carry the same taint set as every persistence-only
certificate (`pilot-loop-facts-v1`, `pilot-stmt-seq-facts-v1`, `pilot-stmt-preserves-facts-v1`,
`pilot-initial-facts-v1`, `ty-sub-refl`) PLUS, newly, `pilot-cf-join-facts-v1` (the join's own
reality-boundary axiom) and (for #1–#3, whose branch has no `else`) no additional axiom beyond
that — none of the 5 exercised a recognized guard (`guard_selects`/`pilot-syntax-facts-v1`)
narrowing the branches, since none of the five if-tests recognized a guard on their own tracked
variable; guard-narrowed-branch and literal-reassignment-inside-a-join shapes are exercised only
by `fixpoint_prover_test.lua`'s fixtures at this commit, same real-corpus absence run 3 reported
for the assignment-transfer half.

### Wall-clock

Summed over 48 files: `parse_ms` 155.2 (run 3: 184.7), `pass1_ms` 32.0 (run 3: 44.6),
`fixpoint_total_ms` 483.8 (run 3: 456.6) — the fixpoint total rose modestly (more real
certificates attempted-and-closed per file means more axiom citations + `rl.observe` calls per
attempt; `constrain.lua` alone rose from 74.6ms to 126.1ms, `env.lua` from 29.5ms to 44.8ms,
consistent with the extra join/branch bookkeeping over the SAME 48-file corpus, not a
complexity blowup — no file exceeded the 30s per-file `bin/cr check` timeout). Whole-measurement
wall-clock (`time` around the driver process): **2.87s** for the full 48-file run (parse + pass
1 + narrowing + fixpoint, all four analyses, per file, sequentially) — run 3's own
whole-process wall-clock was not separately recorded in that report, so this is reported as a
fresh absolute number, not a cross-run delta claim (matching run 3's own stated caution about
`v3_ms` comparisons across runs/system-state).

### Reproduction

Drivers (disposable, not part of the repo, all under `/tmp/v10_parity/`): `scan_loops_run3.lua`
(corpus/eligibility re-scan, unchanged from run 3), `measure_run3.lua` (measurement, unchanged
from run 3), `identify_run4_pairs.lua` (new — per-pair variable/loop correlation for the
truth-check table above). Run via:

```sh
REPO=/home/me/git/rhizone/crescent
"$REPO/bin/cr" run /tmp/v10_parity/scan_loops_run3.lua "$REPO"
"$REPO/bin/cr" run /tmp/v10_parity/measure_run3.lua "$REPO"
"$REPO/bin/cr" run /tmp/v10_parity/identify_run4_pairs.lua "$REPO"
```

## Run 5 — assignment transfer from an annotated-call RHS (commits `464964f8`, `0dae97e6`)

Measured against commit `0dae97e6` ("v10 prover — assignment transfer from an annotated-call
RHS"), HEAD at measurement time; theory content landed one commit earlier (`464964f8`, "v10
fixpoint theory — assign-call-transfer (v4 bump)"). `bin/cr test lib/type/v10_kernel/pilot/`
9/9 files green, 402 assertions (up from run 4's 356 — new hand-built certificate tests for
`assign-call-transfer` in `fixpoint_v1_test.lua`, new taxonomy fixtures in
`fixpoint_prover_test.lua`, both enumerated below). `bin/cr test lib/type/v10_cleanroom/` 3/3
files green, 1044 assertions (unchanged — not touched). Both reconfirmed at this HEAD. No pilot
source was modified to produce the measurement numbers below (the two commits above are the
FEATURE work itself, landed and tested before measuring); the run-3 driver scripts
(`/tmp/v10_parity/measure_run3.lua`, `/tmp/v10_parity/scan_loops_run3.lua`) were reused
UNCHANGED against this HEAD — `fixpoint_prover.analyze_file`'s call signature and stats shape
are unchanged, so no driver edits were needed at all.

**What run 5 adds:** per
`docs/typechecker-v10-fixpoint-proposal.md`'s assignment-transfer scope (§2) and this
extension's own brief (assignment transfer from an annotated-call RHS — the gap runs 3-4's own
reports identified as the reason every real certificate was persistence-only), `fixpoint_v1.lua`
gained one additive operator/axiom/rule (`assign_call`/`pilot-assign-call-facts-v1`/
`assign-call-transfer`, `narrow-pilot-v1` v3→v4), and `fixpoint_prover.lua`'s loop-body walk now
attempts this rule for a bare-identifier, non-method call RHS whose callee resolves, STATICALLY
AND LOCALLY, to a same-file chunk-top-level function declaration with a resolvable `--:
(T1,...) -> R` annotation whose `R` parses as a single six-tag-vocabulary value. See
`lib/type/v10_kernel/pilot/fixpoint_prover.lua`'s own header for the full taxonomy and the one
reported, NOT-closed scope limit (callee-name shadowing is checked only within the current
block, not the full enclosing lexical chain — sound for the tracked variable `X` itself, which
`prover_narrow.lua` already resolves globally, but not fully sound for an arbitrary callee name,
which has no such upstream resolution; no case triggering this was found in this corpus).

**A pre-existing latent bug was found and fixed during this work** (not part of the original
task scope, in-scope because it directly blocked this extension's own multi-member-return
fixture): `suffix_union`/`build_declared_union` (`fixpoint_prover.lua`, dating to run 3's own
commit `4a741cae`) were left-associated in their actual implementation despite their own doc
comments already claiming "right-associated" — invisible through runs 1–4's entire measurement
history because every real-corpus certificate and every hand-built theory test to date used
only a 2-member declared union, where a left fold and a right fold produce the identical single
`ty_union` term (the bug only manifests at 3+ members). This session's own first 3-member-union
fixture (`get_opt` returning `string | nil` transferred into a `string | nil | number` invariant)
was the first thing in this codebase's history to exercise it, surfacing a real replay rejection
("metavariable 'Tinv' bound to two different terms"). Fixed by folding both functions from the
last member backward, matching `build_ty_sub_to_union`'s own trans-chaining requirement.

### Corpus

Identical to run 3/4's own scan: re-ran `scan_loops_run3.lua` (unchanged) over all `lib/**/*.lua`
(997 files, same exclusions). Result: **997/997 parsed, 376 files contain a while-loop, 24 have
a tracked variable in scope at one — the exact same 24-file list, byte-for-byte, as runs 3/4**
(diffed directly: `run5_files.txt` against the file list runs 3/4 report). **Zero newly-eligible
files** — expected, and confirmed rather than assumed: call-RHS transfer does not change
`loop_vars_attempted` eligibility at all (that is entirely `prover_narrow.lua`'s own
`--:`-annotated scope-tracking pass, untouched by this work) — only whether an
ALREADY-attempted pair certifies or skips could move, exactly the same structural point run 4's
own report made about its own (different) extension.

Final corpus: same 48 files as runs 3/4 (27 from runs 1–2 + 21 run-3 additions), 1,698,092
combined bytes (unchanged).

### Aggregate results

Narrowing metrics (guards/annotations/certificates) are IDENTICAL to runs 3/4 (this change
touches no narrowing code) — confirmed by direct re-run, not assumed: guards found 1239, handled
35, annotations parsed 458, certs 40, replay 40/0, judgments 40 — all byte-identical to run
3/4's own reported numbers. Loop-invariant metrics, side by side:

| metric | run 4 (48 files) | run 5 (48 files) | delta |
|---|---:|---:|---:|
| while-loops found | 199 | 199 | 0 |
| (loop, var) pairs attempted | 48 | 48 | 0 |
| **(loop, var) pairs certified (root-accepted)** | **12** | **12** | **0** |
| loop-invariant judgments (root-replayed) | 12 | 12 | 0 |
| loop-invariant replay failures | 0 | 0 | 0 |

**The headline number is 12 — unchanged from run 4. Zero new mutation-class certificates on
this real corpus.** Per-file certified counts are byte-identical to run 4's own breakdown
(`lib/type/static/constrain.lua` 6, `lib/type/static/env.lua` 2,
`lib/unified/remark_github/init.lua` 2, `lib/async_queue/init.lua` 1,
`lib/type/v9/annot/init.lua` 1 — same 5 files, same counts, re-confirmed by direct re-run of the
per-file table, not carried forward from run 4's report). **All 12 remain persistence-only** —
this is not a coincidental equal total masking a compositional change (one call-RHS gain
offsetting one other loss); it is proven by a stronger fact below (skip-reason parity), not
merely inferred from the total matching.

### Loop skip-reason breakdown, with run-4 comparison

199 loops − 159 no-tracked-var loops = 40 loops with at least one tracked variable, carrying 48
(loop, var) pairs; 12 certified + 36 skipped = 48 ✓ (unchanged from run 4).

| reason | run 4 | run 5 | delta |
|---|---:|---:|---:|
| `no tracked variable in scope at this loop` (per loop) | 159 | 159 | 0 |
| `control-flow statement breaks persistence chaining (out of scope)` (per pair) | 28 | 28 | 0 |
| `elseif chain in loop body not yet supported for branch-join chaining (out of scope)` (per pair) | 6 | 6 | 0 |
| `multi-target/multi-value assignment to the invariant variable (out of scope)` | 2 | 2 | 0 |
| `copy source not independently established at the assign point` | 0 | 0 | 0 |
| `assignment RHS out of scope (not literal, bare-identifier copy, or annotated same-file call)` | 0 (n/a, older wording) | 0 | — |
| `method call callee out of scope (not statically resolvable)` (NEW bucket, v5) | — | 0 | — |
| `computed callee (not a bare identifier, not statically resolvable)` (NEW bucket, v5) | — | 0 | — |
| `callee identifier locally shadowed within the loop body ...` (NEW bucket, v5) | — | 0 | — |
| `callee is not a same-file top-level function declaration (unresolvable)` (NEW bucket, v5) | — | 0 | — |
| `callee name has multiple same-file top-level declarations (ambiguous, not resolvable)` (NEW bucket, v5) | — | 0 | — |
| `callee has no resolvable function-type annotation` (NEW bucket, v5) | — | 0 | — |
| `callee has multiple preceding function-type annotations (overload) ...` (NEW bucket, v5) | — | 0 | — |
| `callee annotation is not in '(T1, ...) -> R' form` (NEW bucket, v5) | — | 0 | — |
| `callee return annotation: unsupported annotation member ...` (NEW bucket, v5) | — | 0 | — |
| `callee return annotation declares multiple return values (first-value-only scope)` (NEW bucket, v5) | — | 0 | — |
| `reassigned type not a member of the declared invariant` | 0 | 0 | 0 |
| `empty loop body: no persistence chain from loop head to back edge under this theory` | 0 | 0 | 0 |
| replay rejected an emitted certificate | 0 | 0 | 0 |

**Every one of run 5's nine NEW taxonomy buckets reads zero on this real corpus.** This is the
sharpest form of the finding: it is not merely that no NEW certificate resulted (the headline
12=12 above) — no (loop, var) pair in this 48-file corpus ever even REACHED an
`assign_call`-eligible call-RHS assignment statement at all. Every one of the 36 real skips this
run still decomposes exactly as run 4 reported (28 control-flow, 6 elseif-chain, 2
multi-target) — the SAME upstream gaps (nested control flow, elseif chains) that blocked
persistence-chaining in run 4 block it identically here, before the walk ever reaches a
bare `X = <call>` assignment statement to test against the new rule. This proves (not merely
suggests, since a skip-reason COUNT moving would have been the observable signature of any
change) that zero pairs changed outcome in either direction: no regression, and no new
certificate, composed from the exact same mechanism as run 4's own 12.

### Truth check

**Zero new loop-invariant judgments exist to verify.** The measurement's own instruction (every
new real-corpus invariant hand-verified individually, mutation-class ones checked against the
mutation and the callee's own annotation cross-checked against the callee's body) applies to
NEW invariants; there are none. This is the measured-zero outcome the extension's own brief
named up front as an equally valid finding to a nonzero one ("Expected outcome either way is the
finding: mutation-class certificates on real code, or a measured zero saying real loops don't
assign from same-file annotated callees"). The 12 pre-existing (run-4) certificates are
unaffected (same files, same counts, same skip-reason totals) and were already hand-verified in
run 4's own truth-check table — not re-verified here (nothing about them changed).

**Root cause of the zero, stated plainly (not merely "gap remains," but WHY, to the extent this
corpus reveals it):** of the 48 attempted (loop, var) pairs, 34/36 skips (28 control-flow + 6
elseif-chain) never reach the loop body's OWN top-level statement list far enough to test an
assignment's RHS shape at all — they abandon the persistence/join chain at a NESTED
`if`/`while`/`for`/`return`/`break` or an elseif chain first. The remaining 2 skips
(multi-target assignment) DO reach an assignment to the tracked variable, but its shape (2+
targets or 2+ values) is excluded before the RHS is even inspected. **Zero of the 48 pairs ever
present a single-target, single-value assignment to the tracked variable with a call RHS at
the loop body's own top level** — the exact shape this extension was built to transfer. This is
a materially narrower finding than "callees aren't resolvable" or "annotations are missing": on
this corpus, the call-RHS transfer mechanism was never even given a candidate to accept or
reject. Widening `seq-persist`'s own control-flow scope (nested loops/conditionals, elseif
chains — already-known, already-documented gaps from runs 3/4) is the prerequisite for this
extension to ever be exercised on this corpus at all, not a matter of this extension's own scope
of RHS-shape coverage.

### Wall-clock

Summed over 48 files: `parse_ms` 148.5 (run 4: 155.2), `pass1_ms` 34.2 (run 4: 32.0),
`fixpoint_total_ms` 525.2 (run 4: 483.8, +8.6%) — a modest rise, consistent with more work
attempted per (loop, var) pair even on a path that ultimately skips (building the chunk-top-level
function-name index once per file, and — for the 2 multi-target-assignment pairs specifically —
now probing the RHS-shape branch further before abandoning) rather than any complexity blowup;
no file exceeded the 30s per-file `bin/cr check` timeout. `v3_ms` continues to sit outside runs
1–2's original "process-startup-dominated" band (same divergence run 3 already flagged and left
uninvestigated, out of this measurement's own scope — not re-investigated here either).

### Reproduction

Drivers (disposable, not part of the repo, all under `/tmp/v10_parity/`): `scan_loops_run3.lua`
and `measure_run3.lua`, BOTH reused completely unchanged from run 3 (no driver edits were needed
for this run — `fixpoint_prover.analyze_file`'s external shape is unchanged). Run via:

```sh
REPO=/home/me/git/rhizone/crescent
"$REPO/bin/cr" run /tmp/v10_parity/scan_loops_run3.lua "$REPO"
"$REPO/bin/cr" run /tmp/v10_parity/measure_run3.lua "$REPO"
```
