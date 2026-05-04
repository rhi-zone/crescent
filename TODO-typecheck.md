# Type Error Cleanup Queue

Last updated: 2026-05-01. Total errors: 15707 across the lib/ tree.

Methodology: ran `bin/cr check` over `lib/**/*.lua` (excluding `_test.lua` and `dep/`)
in alphabetical batches; ANSI-stripped, file-aggregated counts. Per-file error
patterns characterized by stripping argument literals and digits from the dominant
3 messages. Workers should pop the highest-impact file in their tier, fix, commit,
and append to "Done in current session".

## Tier 1 — Narrowing-needed (`unknown` → cast / type predicate)

Highest leverage: a single call-site narrow can collapse many derived errors. Look
for `unknown` flowing out of `tonumber`, `string.match`, table reads of unknown
shape, or returns annotated as `unknown`. Add `--[[:! T]]` overlap-cast or
`if type(x) == "number" then ... end` predicate to narrow.

- [x] `lib/crescent_examples/composter.lua` (311 → 300) — added missing `bit` require; remaining 300 are FFI-bound (wlr/wl/xkb unknown)
- [ ] `lib/type/static/parse.lua` (177) — 151 "must be narrowed before calling"
- [x] `lib/lua2ts/init.lua` (162 → 0) — already fixed in prior session (confirmed 0 errors at session start)
- [x] `lib/xpath/init.lua` (150 → 122) — annotated tokenize signature; replaced bare `table` with `{ ... }`
- [ ] `lib/type/static/ann.lua` (144) — 53 "must be narrowed before calling", 20 "argument might also be X"
- [x] `lib/bin_packing/init.lua` (112 → 2) — annotated all 1D/2D fn params and locals; 2 typechecker limitations remain
- [x] `lib/lru/init.lua` (107 → 8) — defined LruNode/Cache/LfuNode/LfuBucket/Lfu/TwoQNode/TwoQFifoQ/TwoQLruQ/TwoQ shapes; annotated all helper fns and methods with self types; force-cast setmetatable returns; cap/o locals to avoid type narrowing bug; `--[[:! Cache]]` overlap casts. Remaining 8: multi-return nil in factory fns (typechecker limitation), `self:method()` calls where `self` is a named type (method lookup doesn't follow metatable).
- [x] `lib/observer/init.lua` (98 → 95) — bind+nil-check+force-cast on optional callbacks
- [x] `lib/observable/init.lua` (83 → 81) — same pattern for SafeObserver._raw callbacks
- [x] `lib/red_black_tree/init.lua` (72 → 0) — defined RBNode/RBTree shapes; annotated all helper fns and M methods; force-casts on sentinel, cmp, and control-flow merge points (ww/ww2 locals); `local x = NIL --[[:! RBNode]]` init; verify check fn annotated; bh_l/bh_r narrowed after nil-check.
- [x] `lib/layout/init.lua` (89 → 0) — added LayoutNode type alias fields (id, col/row/col_span/row_span, columns/rows, width/height as string|number|nil); annotated compute_box/compute_grid/compute_node/resolve_tracks; force casts for type(node.width)=="number" branches; 0.0 initializations

## Tier 2 — Concrete-shape replacement (vague `table` / missing fields)

Files where the dominant pattern is a structurally wrong annotation: missing
fields, excess fields, wrong-tag literals. Fix by replacing the vague type with
the concrete record shape it actually has.

- [x] `lib/platform/apps/charactercardv2/server.lua` (271 → 190) — annotated conv_query and json_ok signatures
- [x] `lib/unified/mdast/init.lua` (176 → 168) — annotated split_lines/count_indent/strip_indent/is_blank/is_thematic_break
- [x] `lib/crescent_examples/x11_wm.lua` (178 → 160) — added local bit = require("bit")
- [x] `lib/yaml/init.lua` (143 → 42 → 0) — annotated YState + helpers; cur/peek return integer with fallback
- [x] `lib/ical/init.lua` (123 → 70 → 0) — annotated add_prop signature with optional params
- [x] `lib/cryptography/init.lua` (107 → 64) — annotated all `table` shapes; rewrote u32be/u32le with math.floor(tonumber(byte)) pattern; fixed ror64/shr64 bit-op integer params; guarded chacha20 return in poly1305 encrypt/decrypt
- [x] `lib/json/init.lua` (106 → 17) — annotated decode_number/array/object/encode_value/encode_array/encode_object; added i=ni force-casts; encode_value type narrowing casts; remaining 17 from string.byte ...integer comparison (unfixable)
- [ ] `lib/css_parser/init.lua` (53 after partial fix) — remaining: integer|integer phi-join in new_selector_parser (pervasive), SelectorParser method shape mismatches (field doesn't exist)
- [x] `lib/wire_protocol/init.lua` (98 → 93) — replaced bare `table` in framer/receiver/decode_all with concrete shapes
- [x] `lib/graphql_parser/init.lua` (86 → 0, commit c0c3681) — insert(arr,node) → arr[#arr+1]=node --[[: any]]; annotated printer fns; cast node params to { [string]: unknown }
- [x] `lib/bson/init.lua` (73 → 0, commit a5ff410) — byte() individual extraction, ffi_ typed alias, --[[: any]] cast for pairs(), decode_document cursor via tonumber()
- [x] `lib/toml/init.lua` (72 → 68) — added forward declarations for parse_datetime and _parse_time_part
- [x] `lib/unified/rehype_highlight/init.lua` (74 → 44 → 0) — added TokenList shape annotation on tokenizer accumulator locals

## Tier 3 — Numeric / FFI buffers (arithmetic / length on unknown)

These typically need a `--[[: integer]]` or `--[[: number]]` cast at the FFI
boundary, or annotating local arrays of bytes as `integer[]`/`uint8_t[]`.

- [x] `lib/blake2/init.lua` (145 → 49) — annotated b_compress/s_compress v and m tables; replaced rejected force cast on ffi.typeof
- [x] `lib/bignum/init.lua` (95 → 89) — bind string.byte() multi-return to single locals before arithmetic
- [x] `lib/matrix/init.lua` (72 → 48) — annotated self: matrix on methods accessing _rows/_cols/_data
- [ ] `lib/protocol_buffer/init.lua` (79) — 36 arithmetic — see SKIP note (cascading integer|nil from decode_varint)
- [x] `lib/bits/init.lua` (76 → 0) — already fixed in prior session (confirmed 0 errors at session start)
- [x] `lib/midi/init.lua` (90 → 0) — already fixed in prior session (confirmed 0 errors at session start)

## Tier 4 — Self-typecheck files (typechecker checking itself)

Lower priority; these are ergonomic cleanup of the typechecker source. Touch
last because the type system itself is the testbed.

- [ ] `lib/type/static/fuzz_alg.lua` (315) — 112 narrow chains via field-of-field
- [ ] `lib/type/static/fuzz_eval.lua` (158) — 80 missing argument
- [ ] `lib/type/static/fuzz_arb.lua` (80) — 18 cannot-pass, 13 missing-field
- [ ] `lib/type/static/constrain.lua` (99) — 20 field-doesn't-exist
- [ ] `lib/type/static/errors.lua` (69)
- [ ] `lib/type/static/lsp.lua` (66)
- [ ] `lib/type/static/intrinsic.lua` (62)

## Tier 5 — Uncatalogued files (discovered in cleanup pass)

### Newly discovered (not yet attempted)
- ~~`lib/spreadsheet/init.lua`~~ — done (see session N+3)
- ~~`lib/prolog/init.lua`~~ — done (see session N+3)
- ~~`lib/complex/init.lua`~~ — done (session N+4)
- ~~`lib/convex_hull/init.lua`~~ — done (session N+4)
- ~~`lib/asn1/init.lua`~~ — done (session N+4)
- ~~`lib/columnar/init.lua`~~ — done (session N+4)
- `lib/ai/providers/anthropic.lua` (28) — json.decode returns unknown; field access on unknown can't be cast with --[[: any]] (need --[[:! T]]); pervasive cascade; skip until json.decode return type is narrowable
- `lib/ai/providers/google.lua` (50) — same json.decode cascade pattern; skip
- `lib/ai/providers/openai_compat.lua` (43) — similar; skip
- `lib/argon2/init.lua` (54) — FFI + unknown cascade; skip
- ~~`lib/http/stream.lua`~~ — DONE (19 → 0, commit b262691)
- ~~`lib/http/server.lua`~~ — DONE (33 → 0, commit b262691)
- ~~`lib/http/client.lua`~~ — DONE (4 → 0, commit b262691)
- ~~`lib/http/router/api.lua`~~ — DONE (13 → 0, commit b262691)
- `lib/bloom/init.lua` (12) — `local bit = bit` global is unknown; full Bloom type annotation cascades badly (23 errors when attempted); skip
- `lib/base32/init.lua` (11) — string param annotation cascades: math.floor → number → sub() integer args fail; skip (confirmed)
- `lib/base58/init.lua` (2) — any fix to sha256fn call sites triggers new error in hex_to_bin (typechecker limitation with gsub return + checked cast interaction)
- `lib/benford/init.lua` — DONE (see session log)
- `lib/barcode/init.lua` — DONE (see session log)
- `lib/bayesian_filter/init.lua` — DONE (see session log)
- `lib/ansi/init.lua` — DONE (see session log)
- `lib/bezier/init.lua` (12 → 5) — remaining: setmetatable return intersection not assignable to named aliases with self-referential method sigs (typechecker limitation)
- `lib/bundle/init.lua` (15 → 0) — done



- [x] `lib/xml/init.lua` (62 → 2) — 2 remaining: nil-assignment to typed arrays (typechecker limitation)
- [x] `lib/cbor/init.lua` (66 → 5) — 5 remaining: type() narrowing limitations in encode_value
- [x] `lib/cron_parser/init.lua` (63 → 0)
- [x] `lib/soundex/init.lua` (84 → 0)
- [x] `lib/csv/init.lua` (60 → 0)
- [x] `lib/http/format.lua` (9 → 0) — cast find() returns after nil-check; tonumber() integer cast for sub() arg
- [x] `lib/smtp/init.lua` (47 → 25) — annotated param/return types; remaining 25 from Session self.transport unknown (prototype method lookup limitation)
- [x] `lib/diff/init.lua` (8 → 0) — force-cast x_/y_/prev_k_/diag_start_ locals after if/else branch joins; annotated myers_forward/myers_backtrack signatures

## FFI-bound (likely unfixable without restructuring)

- [ ] `lib/ljsocket/init.lua` (100) — 29 narrow + 19 missing argument + 18 cannot-assign — SKIP unless coupling with cdef
- [ ] `lib/crypto/system.lua` (80) — 33 narrow + 33 return mismatch + 5 no-matching-overload — SKIP
- [ ] `lib/process/init.lua` (53) — 49 ffi.C.* field errors (pipe/fork/exec/close/dup2/chdir/setenv etc); unfixable without cdef type annotations

## Skipped in prior runs (with reason)

- `lib/text_diff/init.lua` (57) — Myers diff uses heterogeneous stack entries {op, x1, x2, y1, y2}; op=string other fields=integer; phi-join `integer | integer` comparison failures; typed stack caused cascade. Needs tagged-union type.
- `lib/validation/init.lua` (57) — self on Schema methods is unknown; `new_schema(proto)` param annotation doesn't override inferred type from first call; 15 `_type_name` literal mismatches remain.
- `lib/midi/init.lua` — `string.byte()` variadic multi-return resists annotation
- `lib/expr/init.lua` (73) — pervasive unknown propagation, requires restructuring
- `lib/graph_algorithms/init.lua` (77) — recursive `dfs_visit` pre-declared but checker still flagged
- `lib/platform/cli.lua` (68) — disparate nil/concat issues, no single pattern
- `lib/bin_packing/init.lua` — ~~untyped local variables (`bins`, `remaining`); restructuring needed~~ (done: 112 → 2)
- `lib/matrix_ext/init.lua` (97) — table↔matrix swap is net neutral
- `lib/interval/init.lua` (65) — already minimized in prior session (96→65)
- `lib/multipart/init.lua` — setmetatable shape incompatibility
- `lib/markdown/init.lua` — narrowing requires direct field access, not local alias
- `lib/taskgraph/executor/ai.lua` — protective sentinel, any change cascades
- `lib/css_parser/init.lua` — prior attempt at `is_ident_start`/`is_digit` annotation regressed (103→104); session N+9 attempt at SelectorParser/TokenStream method annotations regressed 53→86; setmetatable return type not recognized as method-bearing by typechecker
- `lib/regexp/init.lua` (~42) — skipped in prior session
- `lib/graphql_parser/init.lua` — AST-shape mismatches around `insert(args, {kind=...})`
- `lib/glob/init.lua` (39) — return-type union mismatches: `(integer, fn) | (nil, string)` not narrowed by typechecker after nil-check guard; phi-join i vars; attempted fix session N+23 regressed badly; structural limitation
- `lib/crescent_examples/composter.lua` — pervasive LuaLS-style `@type`/`@diagnostic` annotations not understood by crescent typechecker; 253 narrow-before-indexing errors come from FFI-returned `unknown` values across the entire file. Fixing requires either rewriting all annotations or wholesale `--[[:! T]]` casts after each external call. Restructuring.
- `lib/type/static/parse.lua` — 151 narrow-before-calling errors all from `L:next()`, `nodes:get()`, `lists:push()` etc. on locals returned by `lex_mod.new`/`arena_mod.new_node_arena`/`arena_mod.new_list_pool`. Fix would require giving those constructors return type annotations — typechecker self-check work that requires reading `docs/typechecker-v2.md` and `docs/type-system.md` first per `lib/type/static/CLAUDE.md`. Out of scope for cleanup pass.
- `lib/lua2ts/init.lua` — attempted annotating `scan_annotations(source)`, `ctx:name`/`ctx:list` returns; ctx still flows as unknown into emit_expr (closure-built ctx not seen at call sites). Net 162→163, reverted. Same family as parse.lua: needs constructor return types on `parse_mod.parse`/`new_ctx`. Out of scope for cleanup pass.
- `lib/red_black_tree/init.lua` — recursive `RBNode` type with self-referential left/right/parent fields. Sentinel construction starts with `nil` then assigns NIL = NIL.left, defeating any concrete annotation. All 72 errors are `x.parent.left.color` chains; needs structural recursive type support, restructuring.
- `lib/bits/init.lua` — annotating `band/bor/bxor/bnot/lshift/rshift` with `(integer, integer) -> integer` to remove `union member any not callable` regressed 76 → 82 (concrete return type cascades into stricter checks elsewhere). Reverted. Root cause is `pcall(require, "bit")` fall-through producing union of pure-Lua impl and bit module; needs Bitset/Bloom shape annotations first.
- `lib/bson/init.lua` — force-cast `byte(s, pos) --[[:! integer]]` per byte regressed 73 → 85 (caster mismatch on `integer | nil` source) — reverted. Fix would need either narrowing `nil` separately, or upstream `byte` typing change.
- `lib/protocol_buffer/init.lua` — pervasive `integer | nil` from `decode_varint` second return flows through arithmetic at every call site (313, 382, 388, 393, 395, 462…); 79 errors require cascading nil-guards across decode pipeline. Restructuring.
- `lib/parse/init.lua` (57) — parser combinator library; closures return multi-value types like `(string, integer) | (nil, integer, string)` — annotating closure params regresses errors because typechecker doesn't handle multi-value return annotations on returned closures correctly.
- `lib/automata/init.lua` (27) — NFA/DFA setmetatable overlap fails; multi-param annotation syntax confusion; sorted_keys is a generic function (key type depends on input) that the typechecker can't express; DFA add_state opts mismatch at many call sites. Net regressed to 35 on attempt; reverted.

## Done in current session (session N+26)

- [x] `lib/lindenmayer/init.lua` (54 → 0, commit d8cae77) — LsCmd/LsRule/LsRng/LsOpts/LsObj/LsBounds type aliases; annotated match_parametric/apply_rules_once/interpret_string/compute_bounds/to_svg/Ls methods; parts_/cmds_/stack_ any-intermediates; opts field force-casts to number/string; entry.prob/rule casts
- [x] `lib/search/init.lua` (53 → 0, commit 17d14c3) — open-record query type; constructors --[[: any]] returns; eval_query/collect_query_terms q --[[: any]] branches; typed prev/curr integer arrays; inverted/docs --[[: any]]; opts force-casts; idx:add self annotation
- [x] `lib/struct/init.lua` (54 → 0, commit b23b7b6) — StructOp type alias; parse_fmt/write_op/read_op signatures; ops_ any-intermediate; nv locals after type() guards; out_ any-intermediate for string.char; phi-join integer casts; union_f32/f64 --[[: any]] cast

## Done in current session (session N+25)

- [x] `lib/units/init.lua` (11 → 0, commit 7652fbe) — annotated def() param as { [string]: number | boolean }; cast precision to integer before concat
- [x] `lib/workflow/init.lua` (10 → 0, commit 7652fbe) — WfDef/WfInst/HookList/HistEntry type aliases; self_ casts in all methods; typed errs/queue/visited/breaks arrays; string narrowing for start_/name_; inst.step() called via inst.step(self_) to avoid unknown self
- [x] `lib/word_wrap/init.lua` (18 → 0, commit 7652fbe) — annotated greedy/optimal/justify/truncate params with integer width; typed wlen/cost/brk/breaks/result_lines arrays; phi-join casts for space/line_len/current_len using local cl_ intermediates
- [x] `lib/trie/init.lua` (24 → 0, commit 7652fbe) — TrieNode type alias (with optional has_value/value); annotated walk() as (TrieNode,string)->TrieNode|nil; self_ casts in all methods; typed buf/results/stack arrays; --[[: any]] for nil array-element assignments; TrieNode constructor includes has_value=nil,value=nil fields

## Done in current session (session N+24)

- [x] `lib/compress/init.lua` (1 → 0, commit 48464ac) — cast pcall fallback `impl` via `--[[: any]]` on both the assignment and return
- [x] `lib/datalog/init.lua` (5 → 0, commit 48464ac) — inline DB field init in constructor with setmetatable `--[[: any]]` + `--[[:! Database]]` return; fix `is_var` boolean return via `and true or false`; `assert_all` uses `self_ = self --[[: any]]`; `tuple_key` param typed `{ [integer]: string }`
- [x] `lib/asm/cpu.lua` (2 → 0, commit 48464ac) — cast `ffi = require("ffi") --[[: any]]` to resolve `ffi.new` string-arg overload mismatch
- [x] `lib/brotli/init.lua` (7 → 0, commit 48464ac) — annotate `try_load` params as `{ [integer]: string }` with `(any | nil)` return; fix `os.getenv|nil` concat via `--[[:! string]]` force-cast; replace undefined `table` type with `{ [string]: unknown }`

## Done in current session (session N+23)

- [x] `lib/aho_corasick/init.lua` (was 2 → now 0, commit 576faa9) — Automaton type alias with full method sigs; annotated replace() self as Automaton; force-cast replacements after type() check to typed fn/table
- [x] `lib/regexp/init.lua` (was 42 → now 0, commit 576faa9) — annotated parse_alt/parse_concat/parse_atom/parse_brace_quant; Thread/ThreadList type aliases in nfa_run; typed alts/frags as { [integer]: Frag }; e_ force-casts after nil-check in Re methods; Outs[i][1] integer casts in clone loops; emit() accepts any; src_ cast in clone_frag
- [x] `lib/prolog/init.lua` (was 18 → now 2, commit 0790249) — mk_list optional tail annotation; extract_bindings typed params; ARITH_CMP fn cast; eval_arith (or 0) casts; term/env via intermediate locals; val_ cast from coroutine; 2 remaining: parse_term forward-declared untyped (annotating it cascades 23 new errors from arithmetic on integer return)
- skipped `lib/glob/init.lua` (39 errors) — multi-return union type `(integer, fn) | (nil, string)` not narrowed by typechecker after nil-check; phi-join i vars also fail; attempted fix regressed to many more errors; structural limitation

## Done in current session (session N+22)

- [x] `lib/ecs/init.lua` (was 4 → now 0) — cast json module via `any` intermediate to typed alias `{ encode: ..., decode: ... }`
- [x] `lib/event_emitter/init.lua` (was 5 → now 0) — EeEntry/Emitter type aliases; annotated call_list with typed list param; self_ cast in emit; fired `--: integer` accumulator with final phi-join cast
- [x] `lib/env/init.lua` (was 4 → now 0) — `debug.getinfo(1)` force-cast to `{ source: string }`; `env_ffi` cast to `any` (ffi.load return); fixed env_iter return type to `(integer | nil, string | nil)`; changed `any` to `unknown` in stateless annotation
- [x] `lib/curry/init.lua` (was 9 → now 0) — annotated fns arrays as `{ [integer]: (...unknown) -> unknown }`; n_ and remaining_ integer casts; fn_ cast before call; unpack casts in compose/pipe
- skipped `lib/deepcopy/init.lua` (8 errors) — M.copy uses `any` in params (generic table copy); transform param requires `any` → triggers annotation warning; changes phi-join conflict between `{old:T,new:nil}` and `{old:nil,new:T}` shapes. Restructuring needed.

## Done in current session (session N+21)

- [x] `lib/matrix/init.lua` (was 48 → now 0, commit 50ad046) — self_ casts in all methods; typed aug/rows/x arrays; trace/det/dot nil-return annotation changed to (number|nil,string|nil); add/sub/mul/zip self_+other_ casts; approx_eq inlined; __mul via M.scale/M.mul direct calls; setmetatable via --[[: any]] --[[:! matrix]]; zeros via M.new unwrap
- [x] `lib/blake2/init.lua` (was 49 → now 4, commit 50ad046) — S_IV as --[[:! { [integer]: integer }]] with math.floor; rotr32 annotated (integer,integer)->integer; read_u32_le annotated (string,integer)->integer with off casts; s_compress h param typed; opts_ force-casts in b_binary/s_binary. Remaining 4: B_IV uint64_t FFI arithmetic (genuinely FFI-bound)
- [x] `lib/dotenv/init.lua` (was 6 → now 0, commit 5320450) — unescape_double gsub multi-return via local r,_; expand_vars inline gsub with --[[:! string]] cast; load_files/stringify opts_ force-casts
- [x] `lib/feature_flags/init.lua` (was 6 → now 0, commit 5320450) — Registry type alias; hash_to_float annotated (string)->number; math.floor for FNV offset; emit/eval_flag annotated; self_ cast; h --: number in variant

## Done in current session (session N+20)

- [x] `lib/cr/run.lua` (was 2 → now 0, commit 91042bb) — cast loadfile() chunk to `() -> nil` before pcall
- [x] `lib/cr/init.lua` (was 11 → now 0, commit 91042bb) — CrOpts type alias; typed injected array; pkg_config string cast; annotate try_load_cr_cmd params; pcall chunk/result casts
- [x] `lib/count_min/init.lua` (was 11 → now 0, commit 91042bb) — require("bit") instead of global; CMS type alias; self_ casts in all methods; math.floor for large hex literals; individual string.byte calls in unpack_u32
- [x] `lib/conversation/init.lua` (was 12 → now 0, commit 91042bb) — Db type alias; json_ typed via any intermediate; math.floor for large hex literals; self_ casts in all db_mt methods

## Done in current session (session N+19)

- [x] `lib/http/client.lua` (was 4 → now 0, commit b262691) — headers_ force-cast to `{ [string]: unknown }`, parse_response cast, ep:loop via any
- [x] `lib/http/router/api.lua` (was 13 → now 0, commit b262691) — req_/res_ as any; json_to_/to_json_ typed locals; route as any
- [x] `lib/http/stream.lua` (was 19 → now 0, commit b262691) — self_ casts in all methods; TlsMod alias with methods; math.floor --[[:! integer]] casts; line ternary for type stability
- [x] `lib/http/server.lua` (was 33 → now 0, commit b262691) — TlsMod type alias for get_tls() return; http module cast; http_client_sock type alias; res_any for raw field; tls_cert_/tls_key_ locals

## Done in current session (session N+18)

- [x] `lib/schema/init.lua` (was 8 → now 0, commit 2f2d832) — Col/AlterBuilder type aliases + self_ casts; gsub multi-return fix; removed unannotatable vararg return sigs
- [x] `lib/shamir/init.lua` (was 9 → now 0, commit 2f2d832) — added `local bit = require("bit")`; GF_LOG as `{ [integer]: integer }` (removed nil assignment); hex_strings_ cast; i_ = tostring(i) for concat; s_ force-cast after type() check
- [x] `lib/signals/init.lua` (was 8 → now 0, commit 2f2d832) — EffNode/SubNode type aliases; snapshot arrays typed `{ [integer]: EffNode }`; eff/dep/fn force-casts after pairs; sentinel shape includes all fields; _pop nil via `--[[: any]]`
- [x] `lib/simulated_annealing/init.lua` (was 9 → now 0, commit 2f2d832) — RNG/SAOpts type aliases; seed_/opts_ casts; setmetatable via `--[[: any]]` chain + `--[[:! RNG]]`; on_accept_/on_improve_ force-casts; `len --: number` accumulator
- skipped `lib/chacha20/init.lua` (was 1 → net 89 after fix) — parse error was at `0x10000000000000ULL`; removing ULL suffix let typechecker parse the full file revealing 89 pre-existing errors; reverted

## Done in current session (session N+17)

- [x] `lib/asm/emit/x64.lua` (was 14 → now 2, commit a720eaf) — `--[[:! VReg]]` casts on all `insn.dst`/`insn.operands[i]` after extraction; separate `src2_any` local for add/mov imm-check; `enc_mov_ri64` annotated `(buf, string, integer)`; `--[[:! integer]]` on `.imm` reads; 2 remaining FFI-bound (`ffi.copy` string type, `ffi.cast` return)
- [x] `lib/agent/preset.lua` (was 1 → now 0, commit cb9b61c) — `caps_any = caps --: any` to break mismatch between AgentCaps.llm.generate returning `unknown` vs LeafCaps expecting `LlmResponse|nil`
- [x] `lib/ai/init.lua` (was 17 → now 0, commit cb9b61c) — `providers --: { [string]: ai_provider }`; annotate `resolve` return type; cast `p` from pcall via `--[[: any]]` then `--: ai_provider`; `provider_` locals with `--[[:! ai_provider]]` cast after nil-check; `make_provider_req` annotated `(unknown) -> any`; `prov --[[:! ai_provider]]` for table branch
- [x] `lib/http/router/fs_router.lua` (was 3 → now 2, commit 96fcf42) — FsRouterOpts type alias; annotate `mod.router`, `handle_file`, `handle_dir` with crescent annotations; opts_/io_open_/stderr_write_/lua_load_ casts; replace LuaLS `--[[@param path2 string]]` with preceding-line `--: (string) -> any`; `rawget(_G, "DEV")` to suppress unknown-identifier error; 2 remaining: `mimetype_by_name` $PatternReturn internal mismatch (typechecker limitation)
- skipped `lib/ai/providers/anthropic.lua` — `json.decode` returns `unknown`, and `unknown` fields can't be cast to `any` with `--[[: any]]` (need `--[[:! T]]` force-cast); pervasive field access on decoded JSON cascades net regression 28→36; reverted

## Done in current session (session N+16)

- [x] `lib/deque/init.lua` (was 31 → now 0, commit f48a220) — Deque type alias with all method sigs; self_ casts in all methods; inline field init in constructor; typed arr in to_array
- [x] `lib/disjoint_set/init.lua` (was 29 → now 0, commit f48a220) — BasicDSU/NamedDSU/PersistentDSU/WeightedDSU type aliases with full method sigs; inline field init in all constructors; self_ casts throughout; M.new annotated as (integer|nil) -> BasicDSU
- [x] `lib/duration/init.lua` (was 20 → now 0, commit f48a220) — Duration/DurationParts/DurationComponents type aliases; self_ casts in all methods; tonumber|nil guards (or 0); table.insert for typed array appends; UNIT annotated as { [string]: number }; gsub multi-return captured; parts() annotated -> DurationComponents
- [x] `lib/datetime/init.lua` (was 18 → now 0, commit f48a220) — days_in_month return typed { [integer]: integer }; tonumber|nil guards; named param annotation → positional; frac_rest narrowed via local; gsub multi-return captured; h/mi/sc initialized as `0 --: number`

## Done in current session (session N+15)

- [x] `lib/css/embed.lua` (was 3 → now 0) — replaced `table` annotation with concrete shapes for sheet/css_mod params and return type
- [x] `lib/css/media.lua` (was 3 → now 0) — replaced `table` annotation with concrete shapes; `--[[:! string]]` cast for `type() and ... or ...` phi-join
- [x] `lib/dns/tcp_client.lua` (was 3 → now 0) — added `local bit = require("bit")`; cast `dns.type` to `{ [string]: unknown }` for `["*"]` field access
- [x] `lib/pkg/lock.lua` (was 2 → now 0) — added `LockEntry` type alias; annotated `lock.parse` params/return; cast `current_pkg = {}` to `LockEntry`; `or ""` guard on `f:read()` return
- [x] `lib/unified/rehype_minify/init.lua` (was 2 → now 0) — `gsub` multi-return via `local r, _ = s:gsub(...); return r`; `not not BLOCK[tag]` to get boolean
- [x] `lib/unified/rehype_shift_heading/init.lua` (was 2 → now 0) — annotated HEADING_LEVEL as `{ [string]: integer }`; cast `node.tag` to string; cast `level + shift` to number; phi-join re-cast via `new_level_` local

## Done in current session (session N+14)

- [x] `lib/actor/init.lua` (was 52 → now 0, commit d5fa9c9) — ActorRecord/ActorCtxShape/SystemShape/SupervisorShape/ChildEntry/FailureRec type aliases; self_ casts in all methods; Opaque→any for coroutine; fix deadline number|nil comparisons; fix _kill_actor actor_ casts; supervisor spawn/handle_exit/record_failure self_ casts
- [x] `lib/circuit_sim/init.lua` (was 52 → now 0, commit 150bd02) — CompRecord/CircuitShape/ResultShape/NumMatrix/NumVec type aliases; annotated gaussian_solve/copy_matrix/copy_vec; Result and Circuit method self_ casts; _build_mna multi-return via {self_:_build_mna()}; CS_thevenin/CS_norton casts; node_voltages/power initialized with required literal fields
- [x] `lib/cli/init.lua` (was 47 → now 0, commit 76bac0e) — FlagSpec/OptionSpec/PosSpec/CmdSpec type aliases; normalize forward-declared with nil-union; generate_help/parse_spec/completions_bash/zsh/fish/public API all use CmdSpec; cmd_key local for _command field assignment; norm_ cast for recursive normalize call
- [x] `lib/color/init.lua` (was 47 → now 0, commit 33c8254) — ColorObj/NamedEntry type aliases; clamp/round annotated (number)->number; rgb_to_hsl/rgb_to_hsv/hsl_to_rgb/hsv_to_rgb with direct param usage; hue2rgb ternary chain for t phi-join; multi-return via {fn(...)} table pattern; M.rgb/hsv/hsl param casts; hex string via local sv/sv2/sv3/hex_; _color constructor with rv/gv/bv/av casts

## Done in current session (session N+13)

- [x] `lib/command_queue/init.lua` (was 5 → now 0, commit 7981d4c) — Cmd/PQEntry aliases; typed undo/redo stacks; force-cast table.remove via index+shift pattern; nil-assign via --[[: any]]
- [x] `lib/consistent_hash/init.lua` (was 9 → now 0, commit 7981d4c) — Ring type alias with open shape; self_ casts in all methods; VNode as { [integer]: any }; fnv1a integer cast; math.floor() for literal large hex; table.sort via --[[: any]] cast
- [x] `lib/config/init.lua` (was 15 → now 0, commit 7981d4c) — Config/ConfigData/EnvReader aliases; self_ casts in all methods; key_ cast; fixed gsub multi-return; deep_copy force-cast to ConfigData; opts_ cast for inflate_opts
- [x] `lib/compress/pure.lua` (was 56 → now 0, commit 7981d4c) — byte1() helper for single-byte extraction; pcall-based bit require with typed fallbacks; math.floor() for large hex literals; huffman_tree typed locals; integer casts for pos phi-joins in gzip parser

## Done in current session (session N+12)

- [x] `lib/html/init.lua` (was 58 → now 0, commit 940839f) — annotate element/raw_element/void factories as returning any; fix escape gsub multi-return; force-cast xs to concrete table type inside factory closures; fix ESCAPE_MAP cast for gsub
- [x] `lib/color_palette/init.lua` (was 56 → now 0, commit 940839f) — add Color type alias; annotate all helpers and public M functions; force-cast multi-return values from hsl_norm_to_rgb/rgb_to_lab via { } array; fix phi-join in hue2rgb; annotate channel_range/average_color/quantize/deduplicate; fix table.remove nil with explicit buckets annotation; annotate sort/nearest/best_foreground with typed params
- [x] `lib/lru_ttl/init.lua` (was 54 → now 0, commit beeccd7) — add LruNode/LruStats/Cache type aliases; annotate all Cache methods with self: Cache; self_ casts in every method; annotate helpers; fix nil narrowing after tail-guard; setmetatable via any cast then force-cast
- [x] `lib/tilemap/init.lua` (was 53 → now 0, commit beeccd7) — add TileMap/Heap/HeapEntry/RoomRect/Dir/Rng type aliases with method sigs; annotate all methods with self: T and self_ bodies; fix direction table indexing via Dir cast; annotate make_rng; fix astar with typed locals

## Done in current session (session N+11)

- [x] `lib/ai/tools.lua` (was 5 → now 0, commit 3b4de95) — ai_request cast via any intermediate, tool_calls local for nil-narrowing escape, json_encode typed local, ai_tool_call_list alias for [] syntax
- [x] `lib/automata_2d/init.lua` (was 39 → now 0, commit 3b4de95) — DenseGrid/SparseGrid/RuleFn/Cell2D type aliases; self_ casts in all methods; key/unkey annotations; parts typed as { [integer]: string }; run arithmetic with (tonumber(c) or 0); M.rules via inline do/end helper with RuleFn cast; M.dense/M.sparse constructors typed; rows table typed
- [x] `lib/codec/init.lua` (was 25 → now 0, commit 3b4de95) — Codec alias; return types updated to include nil; rot13_char annotated (string) -> string; c:byte() → string.byte(c,1); bit/bit32 via pcall; bxor typed cast; a/b integer division via math.floor; string.byte(s,i,i) for single-byte extraction

## Done in current session (session N+10)

- [x] `lib/multipart/init.lua` (was 30 → now 0, commit 7f3731c) — HeaderMap/DispositionMap/Builder/Part/DecodedPart aliases; parse_header_line/parse_disposition/gen_boundary annotated; find() return casts; phi-join pos cast; multi-return annotation (T|nil, string|nil); table.insert avoids t[i] assignment type issue
- [x] `lib/smtp/init.lua` (was 25 → now 0, commit cf6d22f) — SmtpSession with all method sigs; SmtpAuth/SmtpOpts/SmtpAddr/SmtpMsg aliases; self_ casts in all methods; base64_decode decode/out tables; table.insert avoids integer-to-string assignment issue
- [x] `lib/wire_protocol/init.lua` (was 93 → now 0, commit 342e2a6) — be_to_uint/le_to_uint annotated; byte() casts; pack/unpack fixes; length_prefixed/delimited/fixed/tlv opts casts; Framer/Receiver type aliases; method annotation self param

## Done in current session (session N+9)

- [x] `lib/yaml/init.lua` (was 42 → now 0, commit 0879e05) — stub initializers for forward-declared parse fns; annotated skip_empty_lines/current_indent/parse_double_quoted/parse_single_quoted/parse_block_scalar/parse_anchor_name/needs_quoting/quote_string/encode_value; typed parts/line_buf arrays; block_indent_ cast; encode_value type narrowing; is_array pairs cast
- [x] `lib/unified/rehype_highlight/init.lua` (was 44 → now 0, commit 2a47723) — Token type annotation fix; e_ --[[:! integer]] casts in find-guarded blocks; HastChild type alias; tokenize_fn cast; tokens_to_hast children/plain_buf typed
- [x] `lib/ical/init.lua` (was 70 → now 0, commit 3fd7aac) — RRule/ICalAlarm/ICalComponent/ICalProp/ICalDt/CalResult type aliases; annotated event_to_lines/todo_to_lines/add_dt_prop/parse_dt_prop/prop_key; force-casts for empty table init; arr[#arr+1] for integer-array inserts
- skipped `lib/css_parser/init.lua` — SelectorParser/TokenStream method annotation attempt regressed 53 → 86; core issue is metatable setmetatable return type not recognized as method-bearing

## Done in current session (session N+8)

- [x] `lib/skiplist/init.lua` (was 56 → now 0, commit f358484) — SLNode/Skiplist type aliases; new_node/find_update annotations; self_ casts in all SL methods; forward[i] --[[:! SLNode]] at traversal sites; cmp_ typed local; any→Skiplist via any chain
- [x] `lib/steering/init.lua` (was 61 → now 0, commit d33ae6a) — Vec2/Agent type aliases with method sigs; self_/param casts in vec2_mt/agent_mt; annotated all public behavior functions; break method-chain intermediates with Vec2 casts; count_ phi-join workaround
- [x] `lib/process/init.lua` (was 64 → now 53, commit bc0f794) — add bit require; fix return type annotations (nil error returns); typed opts_ casts; self_ in handle methods; #input nil-guard; setmetatable cast. Remaining 49: FFI-bound ffi.C.* (added to FFI-bound section)
- [x] `lib/db/init.lua` (was 62 → now 0, commit d1cf9e5) — sqlite/Conn/Select/Insert/Update/Delete open type aliases; _where_params/_set fields; self_/db_/any casts throughout; typed arrays; nil-guards; boolean|nil migrate return

## Done in current session (session N+7)

- [x] `lib/bson/init.lua` (was 73 → now 0, commit a5ff410) — byte() individual extraction with (x or 0) --[[:! integer]]; ffi_ typed alias for ffi module access; --[[: any]] cast on t before pairs(); decode_document cursor via tonumber() at recursive call sites
- [x] `lib/graphql_parser/init.lua` (was 86 → now 0, commit c0c3681) — insert(arr, node) → arr[#arr+1]=node --[[: any]]; annotated all printer functions with return types; cast node params to { [string]: unknown } --[[: any]] in print_node; cast ipairs() collections before iteration
- [x] `lib/css_parser/init.lua` (was 103 → now 53, commit 1f4c722) — byte(c,1) to avoid variadic; phi-join cast via local i_ --[[:! integer]] in read_ident/read_number; read_url annotation; compound field types as string|nil; remaining 53 from pervasive integer|integer phi-join in new_selector_parser and SelectorParser method shape issues

## Done in current session (session N+6)

- [x] `lib/interval_tree/init.lua` (was 16 → now 0, commit 5a97279) — ITreeNode/ITreeObj type aliases; annotate all helpers with `(params) -> ret` syntax; force-cast left/right fields as ITreeNode|nil at recursive call sites; self_ pattern in Tree methods; phi-join m_ force-cast in update_max; split multi-return assignments for bst_delete to avoid nil assignment to { [integer]: boolean }
- [x] `lib/bench/init.lua` (was 28 → now 0, commit ce5a01e) — ClockFn/Stats/BenchResult/BenchOpts/SuiteCase/SuiteResult type aliases; annotate M.stats with typed array; annotate format_ns/format_ops; self_ cast in ResultMT:format; typed samples/s arrays; var_sum/sum as number; median initializer; clock injection guard; batch_ integer cast; slowest as number; sorted SuiteResult cast for table.sort
- [x] `lib/async_queue/init.lua` (was 41 → now 0, commit 00cd0ea) — AQDoneCb/AQTask/AQState/AQStats/AQListeners/AQObj/BatcherObj type aliases; arr_remove helper to avoid table.remove type inference conflict; pq_insert annotated; rate_ok/rate_consume/finish_task/reschedule_retry/start_task annotated; self_ casts in all Queue/Batcher methods; Queue.tick/run_all use self_ for field access; Batcher._flush_key called directly for method dispatch; narrowing fixes for number|nil comparisons
- skipped `lib/automata/init.lua` (27 errors) — multi-param annotation syntax confusion + setmetatable overlap failures + generic sorted_keys; net regressed to 35 on first attempt, reverted

## Done in current session (session N+5)

- [x] `lib/toml/init.lua` (was 44 → now 0, commit b1d84fa) — changed is_ws/is_digit/is_hex/is_bare_key_char/is_newline params number→integer; replaced inline byte("x") calls with BYTE_x constants; (byte(s,pos) or 0) --[[:! integer]] force-casts; phi-join pos recast locals; fixed skip_to_newline annotation; removed unannotatable 5-return mixed type from _parse_time_part_impl; write_table empty-string sentinel for nil prefix; separate loop locals (k2/err2) for parse_key
- [x] `lib/async/init.lua` (was 34 → now 0, commit 08ae89f) — defined PromiseP/CbList/FinallyList/ResolveFn/RejectFn/LoopObj type aliases; annotated settle(); self_ casts in Promise/Loop methods; annotated M.promise() return; cast LoopObj from setmetatable; Thread cast for coroutine; yp --[[:! PromiseP]] after type check on yielded
- [x] `lib/chan/init.lua` (was 27 → now 0, commit 424bf69) — defined SendEntry/RecvEntry/ChanBuf/SendQ/RecvQ/ChanObj type aliases; annotated buf_push/buf_pop; self_ casts in all Chan methods; replaced table.remove(send_q) with index+shift (avoids generic V unification); _ready_q: { [integer]: Thread }; entry.co --[[:! Thread]] casts

## Done in current session (session N+4)

- [x] `lib/complex/init.lua` (was 35 → now 0, commit d987f07) — Complex type alias with method sigs; coerce annotated; metamethods use a_/b_ locals; self_ casts in mt methods; `--[[: any]]` on setmetatable + force cast to Complex; M.tan uses mt.__div directly; M.pow uses mt.__mul for lz; M.roots `--: number` on r_n
- [x] `lib/convex_hull/init.lua` (was 30 → now 0, commit ebd8976) — Point/Circle type aliases; annotated cross/dist/dist2/circle_from_1/2/3/point_in_circle/welzl/on_segment/is_ear/dp_rec with param types; typed sorted/filtered/stack/upper/lower/pts/indices arrays; `--: number` on accumulators; `--[[: any]]` nil-pop on stack; `(x and y) and true or false` for boolean returns
- [x] `lib/asn1/init.lua` (was 31 → now 0, commit bf832e8) — TlvNode type alias; annotated decode_tlv/decode_sequence return types; `(byte(...) or 0) --[[:! integer]]` for byte() calls; `--: number` on n accumulator; `n_ = n --[[:! number]]` after if-branch; tonumber/hex parsing fixes in encode_integer/encode_oid; `--: { [integer]: any }` on OID buf
- [x] `lib/columnar/init.lua` (was 16 → now 0, commit 13d1988) — ColDef/ColTable/ValidatorFn type aliases; validator fn table split from literal; self_ casts in all methods; col_def_ casts for ColDef; `--[[:! ColTable]]` constructor via any cast; `--[[:! number]]` on nil-guarded comparisons; `--: number | nil` on min/max accumulators

## Done in prior sessions (session N+3)

- [x] `lib/spreadsheet/init.lua` (was 122 → now 0, commit f4dcf6f) — SpreadToken/SpreadNode/ParserState/SheetType type aliases; annotated lex/cell_key/num_coerce/eval_node/collect_deps/csv_parse_row; self_ casts in Parser/Sheet methods; tonumber/math.floor/math.min casts; gsub tuple concat fixes
- [x] `lib/prolog/init.lua` (was 103 → now 18, commit 5b17255) — PrologTerm optional fields; forward-declared recursive closures; deref/walk result casts; annotated term_to_string/eval_arith/solve/collect_vars; lex integer|1 phi-join fix; string.byte variadic cast; 18 remaining: cascading env nil-assignment in DB:retract loop, ARITH_CMP functor nil, extract_bindings unknown

- [x] `lib/dice/init.lua` (was 65 → now 0, commit 201dfe0) — DiceSt/RollNode/NegNode/BinopNode/ConstNode/DiceNode/StatsResult type aliases; preceding-line fn annotations; force-cast node to subtypes after type-tag checks; `--[[:! integer]]` on tonumber/read_int returns; stats_node workaround for typechecker nil-narrowing limitation
- [x] `lib/graph_layout/init.lua` (was 63 → now 0, commit cda6749) — GNode/GEdge/Graph/Pos2D/PosMap/DispMap/AdjMap/OutAdjList/LayerMap aliases using `{ [any]: T }`; annotated all public functions + make_rng; typed pos/disp/out_adj/in_deg/layer/layers locals
- [x] `lib/template_engine/init.lua` (was 67 → now 0, commit 71ad118) — Token/ASTNode type aliases; lex() find() casts; render_sub extra_ctx optional; force-cast node.body/expr/filters in render_nodes; fixed next_i arithmetic; loader call casts
- [x] `lib/agent/leaf.lua` (was 1 → now 0, commit c1f7a04) — defined LlmResponse type; --[[:! LlmResponse]] force-cast after nil-check; typed notes_add/notes_drop/tool_call inline
- [x] `lib/agent/render.lua` (was 1 → now 0, commit c1f7a04) — inline messages initializer
- [x] `lib/asm/init.lua` (was 1 → now 0, commit c1f7a04) — force-cast desc.intervals at ra.allocate call site
- [x] `lib/asm/ra.lua` (was 4 → now 0, commit c1f7a04) — active_any intermediate for table.insert/remove overload confusion; read victim before remove; force-cast victim.id
- [x] `lib/ai/providers/openai.lua` (was 1 → now 0, commit c1f7a04) — restructure config with typed locals; fix make_headers annotation in compat to optional field

## Done in prior sessions

(workers append here in `[x] lib/foo/init.lua (was N → now M, commit <hash>)` form)

- [x] `lib/cellular_automata/init.lua` (was 2 → now 0, commit 3517df6) — `local bit = require("bit")`; annotated row array `{ [integer]: integer }` to allow assigning 1
- [x] `lib/bloom_filter/init.lua` (was 24 → now 0, commit 3517df6) — BloomFilter/ScalableBloom type aliases; annotated optimal_m/k/bitarray_new/hash_i; parse_opts return type; force-casts after nil-check; self_ casts in methods; CountingFilter alias
- [x] `lib/bloom_count/init.lua` (was 24 → now 0, commit c430a42) — `require("bit")`; CBFShape/CFShape/SBFInner/ScalableBloomShape type aliases; annotated hash helpers; `string.byte(s,i,i)` pattern for single-byte extraction; self_ casts across all methods
- [x] `lib/auth/init.lua` (was 26 → now 0, commit 09d45cb) — `require("bit")` + local aliases; force-cast base64_encode/decode/json_encode/decode as typed locals; annotated jwt_decode parts array; fixed hex_to_bytes; self-contained xor_strings with single-byte extraction

- [x] `lib/interpolation_curves/init.lua` (was 67 → now 0, commit 8d94e7f) — NumArr/NumArr2D/Spline/CSpline/HSpline/EvalSpline/Curve type aliases; bisect/thomas/mat_solve/poly_eval annotations; self_ casts in monotone/akima methods; 0→number annotated accumulators; EvalSpline cast for curve methods
- [x] `lib/physics_2d/init.lua` (was 70 → now 0, commit 28a8850) — BodyShape/JointShape/WorldShape/CollInfo/BodyOpts/WorldOpts type aliases; annotated collision helpers; setmetatable via --[[: any]] + return cast; self_ cast in World:step
- [x] `lib/validation/init.lua` (was 71 → now 57, commit af01242) — replaced XxxSchema.optional = XxxSchema.nullable with Schema.nullable (14 occurrences); remaining 57 from unknown method calls on schema prototype chain

- [x] `lib/stats/init.lua` (was 105 → now 0, commit 95e78a0) — NumArr/NumArr2D type aliases; annotated all public params; `or 0` nil-cast pattern; `0 --: number` accumulators; annotated coefficient arrays
- [x] `lib/time_series/init.lua` (was 14 → now 0, commit 5190915) — annotated bisect params/IntArr/NumArr; `lo_/hi_` force-casts for phi-join; `avg_t/avg_v --: number`; unified outlier result shapes
- [x] `lib/circuit_breaker/init.lua` (was 9 → now 0, commit 59482b8) — CB type alias; force-cast self to CB in helpers; CBClock/CBIsFailure/CBOnChange named function types
- [x] `lib/diff/init.lua` (was 8 → now 0, commit e232596) — force-cast branch-join locals; annotated helper function signatures
- [x] `lib/easing/init.lua` (was 2 → now 0) — force-cast `M[name]` return in `M.get`; cast `M[ease_fn]` in `M.interpolate`; `fn or M.linear` nil-safe call
- [x] `lib/tar/init.lua` (was 2 → now 0) — force-cast `match("^([^%z]*)")` captures; `size_` integer cast for `sub()` args
- [x] `lib/crc32/init.lua` (was 3 → now 0) — annotated `compute_with_table` with `number|nil` init param; `{ [integer]: integer }` for res/tmp; local crc_ casts for `string.format %x`
- [x] `lib/statemachine/init.lua` (was 3 → now 0) — annotated `default_sub_path` return; force-cast `target_str_` for concat; `machine_` force-cast with transition/matches shape; `new_state_` context indexing cast
- [x] `lib/bloom_clock/init.lua` (was 11 → now 0, commit 49d62d4) — Clock type alias; annotated all helpers; self_ casts in methods; FNV constant as signed int32
- [x] `lib/uuid/init.lua` (was 4 → now 3, commit 846b5d0) — rand_bytes forward-decl as rand_bytes_fn|nil; force-cast at call sites; 3 FFI ffi.new errors remain
- [x] `lib/string_ext/init.lua` (was 6 → now 0, commit be1e194) — annotated M.split/split_n/lines with string param types
- [x] `lib/table_ext/init.lua` (was 6 → now 0, commit 318ae44) — annotated flatten/zip/take/range; force-cast depth_/step_

- [x] `lib/markdown/init.lua` (was 7 → now 0, commit b60f672) — force-casts on ms_/me_/repl_ from unknown try_fn returns; s_/len_ locals after if-branch type union; bq_lines[#bq_lines] cast; i cast after increment
- [x] `lib/taskgraph/executor/ai.lua` (was 9 → now 0, commit dddcd2a) — AiMessage/CompleteInput/ToolLoopInput/ToolSpec types; ctx_ force-cast with spawn/result methods; tool_calls nil split; --[[: any]] on generate({...}) calls for optional-vs-nil mismatch
- [x] `lib/totp/init.lua` (was 12 → now 0, commit 7332268) — HotpOpts/TotpOpts/VerifyOpts/NewSecretOpts type aliases; counter_to_bytes annotated number->string; hmac_binary return annotated; lo_i/hi_i math.floor casts for bitwise; mac_/key_ checked casts; opts_ and pattern for optional fields; uri_encode gsub --[[: string]] return cast
- [x] `lib/tracing/init.lua` (was 12 → now 0, commit 3782170) — SpanObj/SpanCtx/Exporter type aliases; _xorshift32 integer->integer annotation; nibble pos cast; _make_rng time_fn annotation; self_=SpanObj cast in finish; end_time local; opts.context SpanCtx cast; M.inject SpanCtx param; id_seed cast

- [x] `lib/bezier/init.lua` (was 12 → now 5, commit d09d5a3) — annotated pt_scale z-cast, z=nil in normal() returns, number accumulator casts, SplineOpts force-cast; remaining 5: setmetatable return mismatch (typechecker limitation with self-referential aliases)
- [x] `lib/bundle/init.lua` (was 15 → now 0, commit e4a44da) — BundleOpts/BundleStringOpts/AnalyzeOpts/AnalyzeStringOpts aliases; { [integer]: string } arrays; read_fn force-cast after type guard; fallback resolver with dummy param
- [x] `lib/base58/init.lua` (was 2 → now 1, commit c27059c) — annotated get_sha256 return; remaining 1: gsub multi-return in hex_to_bin (typechecker limitation, matches skip note)
- [x] `lib/aho_corasick/init.lua` (was 5 → now 2, commit 9f2062b) — force-cast g[c]→integer in trie; annotated patterns param; tostring(i) in error strings; annotated replace text param; remaining 2: search/replacements call on unknown (needs method annotations)

- [x] `lib/cache/init.lua` (was 25 → now 0, commit 27a79b6) — CacheNode/Cache type aliases; annotated all helpers with force-cast params; compute_expiry closure; nil-safe clock/evict calls; self_ pattern in all methods
- [x] `lib/bitset/init.lua` (was 11 → now 0, commit fc13aa2) — Bitset open type alias; M.new optional arg annotation; max_words integer cast; BS.set direct call in from_bits
- [x] `lib/spell_check/init.lua` (was 13 → now 0, commit 309d884) — Checker type alias; levenshtein/build_index annotated; prev/curr typed arrays; self_ casts in all methods; Checker.method() calls for dispatch; inline field init in constructor

- [x] `lib/behavior_tree/init.lua` (was 33 → now 0, commit 457366c) — defined BTNode recursive type; annotated tick_*/reset_node/debug_node with node_ force-casts; cast children to { [integer]: BTNode }; typed state fields; fixed tick_parallel needed union
- [x] `lib/calendar/init.lua` (was 34 → now 0, commit c3f3af7) — defined Date type; annotated is_leap/days_in_month/to_ordinal/from_ordinal; self_ force-casts in date_mt methods; defined Recur type; rewrote range/recur_mt:next with from_ordinal directly; recur_mt.next() direct calls in take/all
- [x] `lib/astar/init.lua` (was 28 → now 0, commit e6eb8ff) — annotated heuristic functions; typed g_score/dist as { [integer]: T }; decode() -> (integer, integer); cur_key/key force-casts; dir[1]/dir[2] force-casts
- [x] `lib/bigint/init.lua` (was 49 → now 0, commit 31bd15b) — defined BigInt type; annotated all helpers and M functions; typed local arrays; used divmod_abs directly in gcd/to_hex; restructured boolean expressions for typechecker

- [x] `lib/xml/init.lua` (was 62 → now 2, commit 531e51e) — XmlAttrs/XmlNode type aliases; replaced all `table` annotations; annotated parse_attrs; force-cast match() captures; remaining 2: nil assignment to typed arrays (typechecker limitation)
- [x] `lib/cron_parser/init.lua` (was 63 → now 0, commit 45b6fb2) — DateFn/CronFields/Schedule type aliases; self: Schedule casts; force-cast snap_forward/snap_backward calls; annotated helper functions
- [x] `lib/cbor/init.lua` (was 66 → now 5, commit 053d6d7) — annotated read_arg/decode_value; bound byte multi-returns with or-0; pos/arg force-casts after guards; remaining 5: type() narrowing limitations
- [x] `lib/soundex/init.lua` (was 84 → now 0, commit 7d13e04) — annotated upper/sub/encode_body/lcs_length/add(p,q)/M.soundex; local i: integer; DP table shapes

- [x] `lib/csv/init.lua` (was 60 → now 0, commit fa86f34)
- [x] `lib/bencode/init.lua` (was 46 → now 0, commit 79ddc6f)
- [x] `lib/bitarray/init.lua` (was 11 → now 0, commit 6565fdc)

- [x] `lib/xpath/init.lua` (was 150 → now 122, commit e90013a)
- [x] `lib/observer/init.lua` (was 98 → now 95, commit b9fd693)
- [x] `lib/observable/init.lua` (was 83 → now 81, commit 6d2d311)
- [x] `lib/yaml/init.lua` (was 143 → now 42, commit c5fc96c)
- [x] `lib/unified/mdast/init.lua` (was 176 → now 168, commit 1bc7cba)
- [x] `lib/wire_protocol/init.lua` (was 98 → now 93, commit 9f9c522)
- [x] `lib/toml/init.lua` (was 72 → now 68, commit e5b3e2d; further reduced to 44, commit 96baa28)
- [x] `lib/ical/init.lua` (was 123 → now 70, commit ba96da6)
- [x] `lib/crescent_examples/x11_wm.lua` (was 178 → now 160, commit 11fe9a7)
- [x] `lib/platform/apps/charactercardv2/server.lua` (was 271 → now 190, commit 32a35d6)
- [x] `lib/unified/rehype_highlight/init.lua` (was 74 → now 44, commit 667c916)
- [x] `lib/bignum/init.lua` (was 95 → now 89, commit 5ec6c4e)
- [x] `lib/blake2/init.lua` (was 145 → now 49, commit ddad5ff)
- [x] `lib/matrix/init.lua` (was 72 → now 48, commit 6158453)
- [x] `lib/layout/init.lua` (was 89 → now 0, commit cac805c)
- [x] `lib/json/init.lua` (was 106 → now 17, commit a7e75c8) — 17 remaining from string.byte() ...integer comparison; unfixable without typechecker changes
- [x] `lib/cryptography/init.lua` (was 107 → now 64, commit 256f000) — 64 remaining: 10 return-nil mismatches (string|(nil,string) multi-return union), number/integer cascades in SHA-512/Poly1305 arithmetic, ...integer from string.byte in sha512_compress block loop
- [x] `lib/template/init.lua` (was 23 → now 0, commit 7088442)
- [x] `lib/diff/init.lua` (was 39 → now 8, commit d27b1b5) — 8 remaining: integer|integer compare from v-table or-chain (typechecker limitation)
- [x] `lib/base64/init.lua` (was 14 → now 0, commit 2914d91)
- [x] `lib/barcode/init.lua` (was 18 → now 0, commit 4d65c1c) — annotated code128b_value, EAN_L, CODE39_PATTERNS; fixed string.byte ...integer via locals; annotated to_svg opts; cast EanPattern indexing
- [x] `lib/bayesian_filter/init.lua` (was 13 → now 0, commit 7044dcb) — ClfCat/Classifier/ClfSerial type aliases; tokenize annotation; inline field init in constructor; softmax sum cast to number
- [x] `lib/ansi/init.lua` (was 1 → now 0, commit d386cff) — boolean coercion via `and true or false`
- [x] `lib/benford/init.lua` (was 12 → now 0, commit 4069309) — annotated lower_reg_gamma/leading_two_digits; typed observed accumulators; log_gamma c-table typed array; nil-safe leading digit extraction
