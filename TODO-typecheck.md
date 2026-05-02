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
- [ ] `lib/lua2ts/init.lua` (162) — 110 "must be narrowed before calling", 22 arithmetic on unknown — see SKIP note (closure-built ctx is untyped, needs L2TSCtx alias + full method annotation; complex)
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
- [x] `lib/yaml/init.lua` (143 → 42) — annotated YState + helpers; cur/peek return integer with fallback
- [x] `lib/ical/init.lua` (123 → 70) — annotated add_prop signature with optional params
- [x] `lib/cryptography/init.lua` (107 → 64) — annotated all `table` shapes; rewrote u32be/u32le with math.floor(tonumber(byte)) pattern; fixed ror64/shr64 bit-op integer params; guarded chacha20 return in poly1305 encrypt/decrypt
- [x] `lib/json/init.lua` (106 → 17) — annotated decode_number/array/object/encode_value/encode_array/encode_object; added i=ni force-casts; encode_value type narrowing casts; remaining 17 from string.byte ...integer comparison (unfixable)
- [ ] `lib/css_parser/init.lua` (103) — 18 cannot compare, 15 field doesn't exist (see SKIP — prior attempt regressed)
- [x] `lib/wire_protocol/init.lua` (98 → 93) — replaced bare `table` in framer/receiver/decode_all with concrete shapes
- [ ] `lib/graphql_parser/init.lua` (86) — 20 cannot-pass, 16 narrow-before-indexing (see SKIP — AST shape mismatches)
- [ ] `lib/bson/init.lua` (73) — 33 arithmetic, 13 cannot-assign — see SKIP note (force-cast on byte regressed)
- [x] `lib/toml/init.lua` (72 → 68) — added forward declarations for parse_datetime and _parse_time_part
- [x] `lib/unified/rehype_highlight/init.lua` (74 → 44) — added TokenList shape annotation on tokenizer accumulator locals

## Tier 3 — Numeric / FFI buffers (arithmetic / length on unknown)

These typically need a `--[[: integer]]` or `--[[: number]]` cast at the FFI
boundary, or annotating local arrays of bytes as `integer[]`/`uint8_t[]`.

- [x] `lib/blake2/init.lua` (145 → 49) — annotated b_compress/s_compress v and m tables; replaced rejected force cast on ffi.typeof
- [x] `lib/bignum/init.lua` (95 → 89) — bind string.byte() multi-return to single locals before arithmetic
- [x] `lib/matrix/init.lua` (72 → 48) — annotated self: matrix on methods accessing _rows/_cols/_data
- [ ] `lib/protocol_buffer/init.lua` (79) — 36 arithmetic — see SKIP note (cascading integer|nil from decode_varint)
- [ ] `lib/bits/init.lua` (76) — 37 "union member is not callable", 11 arithmetic — see SKIP note (pcall require bit fall-through)
- [ ] `lib/midi/init.lua` (90) — 33 arithmetic, 14 tag-literal mismatches (see SKIP — variadic byte() resists annotation)

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

- [x] `lib/xml/init.lua` (62 → 2) — 2 remaining: nil-assignment to typed arrays (typechecker limitation)
- [x] `lib/cbor/init.lua` (66 → 5) — 5 remaining: type() narrowing limitations in encode_value
- [x] `lib/cron_parser/init.lua` (63 → 0)
- [x] `lib/soundex/init.lua` (84 → 0)
- [x] `lib/csv/init.lua` (60 → 0)
- [x] `lib/http/format.lua` (9 → 0) — cast find() returns after nil-check; tonumber() integer cast for sub() arg
- [x] `lib/smtp/init.lua` (47 → 25) — annotated param/return types; remaining 25 from Session self.transport unknown (prototype method lookup limitation)
- [ ] `lib/diff/init.lua` (8) — remaining integer|integer compare (typechecker limitation, see Skipped)

## FFI-bound (likely unfixable without restructuring)

- [ ] `lib/ljsocket/init.lua` (100) — 29 narrow + 19 missing argument + 18 cannot-assign — SKIP unless coupling with cdef
- [ ] `lib/crypto/system.lua` (80) — 33 narrow + 33 return mismatch + 5 no-matching-overload — SKIP

## Skipped in prior runs (with reason)

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
- `lib/css_parser/init.lua` — prior attempt at `is_ident_start`/`is_digit` annotation regressed (103→104)
- `lib/regexp/init.lua` (~42) — skipped in prior session
- `lib/graphql_parser/init.lua` — AST-shape mismatches around `insert(args, {kind=...})`
- `lib/glob/init.lua` — return-type union mismatches at iterator boundary
- `lib/crescent_examples/composter.lua` — pervasive LuaLS-style `@type`/`@diagnostic` annotations not understood by crescent typechecker; 253 narrow-before-indexing errors come from FFI-returned `unknown` values across the entire file. Fixing requires either rewriting all annotations or wholesale `--[[:! T]]` casts after each external call. Restructuring.
- `lib/type/static/parse.lua` — 151 narrow-before-calling errors all from `L:next()`, `nodes:get()`, `lists:push()` etc. on locals returned by `lex_mod.new`/`arena_mod.new_node_arena`/`arena_mod.new_list_pool`. Fix would require giving those constructors return type annotations — typechecker self-check work that requires reading `docs/typechecker-v2.md` and `docs/type-system.md` first per `lib/type/static/CLAUDE.md`. Out of scope for cleanup pass.
- `lib/lua2ts/init.lua` — attempted annotating `scan_annotations(source)`, `ctx:name`/`ctx:list` returns; ctx still flows as unknown into emit_expr (closure-built ctx not seen at call sites). Net 162→163, reverted. Same family as parse.lua: needs constructor return types on `parse_mod.parse`/`new_ctx`. Out of scope for cleanup pass.
- `lib/red_black_tree/init.lua` — recursive `RBNode` type with self-referential left/right/parent fields. Sentinel construction starts with `nil` then assigns NIL = NIL.left, defeating any concrete annotation. All 72 errors are `x.parent.left.color` chains; needs structural recursive type support, restructuring.
- `lib/bits/init.lua` — annotating `band/bor/bxor/bnot/lshift/rshift` with `(integer, integer) -> integer` to remove `union member any not callable` regressed 76 → 82 (concrete return type cascades into stricter checks elsewhere). Reverted. Root cause is `pcall(require, "bit")` fall-through producing union of pure-Lua impl and bit module; needs Bitset/Bloom shape annotations first.
- `lib/bson/init.lua` — force-cast `byte(s, pos) --[[:! integer]]` per byte regressed 73 → 85 (caster mismatch on `integer | nil` source) — reverted. Fix would need either narrowing `nil` separately, or upstream `byte` typing change.
- `lib/protocol_buffer/init.lua` — pervasive `integer | nil` from `decode_varint` second return flows through arithmetic at every call site (313, 382, 388, 393, 395, 462…); 79 errors require cascading nil-guards across decode pipeline. Restructuring.

## Done in current session

(workers append here in `[x] lib/foo/init.lua (was N → now M, commit <hash>)` form)

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
