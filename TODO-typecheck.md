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

- [ ] `lib/crescent_examples/composter.lua` (311) — 253 "must be narrowed before indexing"
- [ ] `lib/type/static/parse.lua` (177) — 151 "must be narrowed before calling"
- [ ] `lib/lua2ts/init.lua` (162) — 110 "must be narrowed before calling", 22 arithmetic on unknown
- [ ] `lib/xpath/init.lua` (150) — 90 "must be narrowed before calling", 10 cannot take length
- [ ] `lib/type/static/ann.lua` (144) — 53 "must be narrowed before calling", 20 "argument might also be X"
- [ ] `lib/bin_packing/init.lua` (112) — 88 "must be narrowed before indexing" — see SKIP note (untyped locals; restructure)
- [ ] `lib/lru/init.lua` (107) — 70 "must be narrowed before indexing"
- [ ] `lib/observer/init.lua` (98) — 66 "must be narrowed before calling"
- [ ] `lib/observable/init.lua` (83) — 51 "must be narrowed before calling", 18 "must be narrowed before indexing"
- [ ] `lib/red_black_tree/init.lua` (72) — 43 "must be narrowed before indexing"
- [ ] `lib/layout/init.lua` (89) — 38 "must be narrowed before indexing", 23 arithmetic on unknown

## Tier 2 — Concrete-shape replacement (vague `table` / missing fields)

Files where the dominant pattern is a structurally wrong annotation: missing
fields, excess fields, wrong-tag literals. Fix by replacing the vague type with
the concrete record shape it actually has.

- [ ] `lib/platform/apps/charactercardv2/server.lua` (271) — 44 "missing field 'enabled'", 49 indexing-narrow
- [ ] `lib/unified/mdast/init.lua` (176) — 23 "is not assignable", 21 "cannot assign", 38 arithmetic
- [ ] `lib/crescent_examples/x11_wm.lua` (178) — 99 "field doesn't exist"
- [ ] `lib/yaml/init.lua` (143) — 57 missing argument, 20 cannot compare
- [ ] `lib/ical/init.lua` (123) — 36 narrow + 35 missing argument
- [ ] `lib/cryptography/init.lua` (107) — 26 "cannot assign X to X", 24 arithmetic on unknown
- [ ] `lib/json/init.lua` (106) — 31 "cannot compare", 22 arithmetic, 20 "is not assignable"
- [ ] `lib/css_parser/init.lua` (103) — 18 cannot compare, 15 field doesn't exist (see SKIP — prior attempt regressed)
- [ ] `lib/wire_protocol/init.lua` (98) — 31 arithmetic, 17 cannot-assign chains
- [ ] `lib/graphql_parser/init.lua` (86) — 20 cannot-pass, 16 narrow-before-indexing (see SKIP — AST shape mismatches)
- [ ] `lib/bson/init.lua` (73) — 33 arithmetic, 13 cannot-assign
- [ ] `lib/toml/init.lua` (72) — 13 cannot-pass + 13 compare + 13 cannot-assign (uniform)
- [ ] `lib/unified/rehype_highlight/init.lua` (74) — 28 "field N is not X" (numeric child indices)

## Tier 3 — Numeric / FFI buffers (arithmetic / length on unknown)

These typically need a `--[[: integer]]` or `--[[: number]]` cast at the FFI
boundary, or annotating local arrays of bytes as `integer[]`/`uint8_t[]`.

- [ ] `lib/blake2/init.lua` (145) — 72 narrow, 64 arithmetic on unknown
- [ ] `lib/bignum/init.lua` (95) — 20 arithmetic, 14 "cannot take length"
- [ ] `lib/matrix/init.lua` (72) — 25 arithmetic, 22 "no method on this type"
- [ ] `lib/protocol_buffer/init.lua` (79) — 36 arithmetic
- [ ] `lib/bits/init.lua` (76) — 37 "union member is not callable", 11 arithmetic
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

## FFI-bound (likely unfixable without restructuring)

- [ ] `lib/ljsocket/init.lua` (100) — 29 narrow + 19 missing argument + 18 cannot-assign — SKIP unless coupling with cdef
- [ ] `lib/crypto/system.lua` (80) — 33 narrow + 33 return mismatch + 5 no-matching-overload — SKIP

## Skipped in prior runs (with reason)

- `lib/midi/init.lua` — `string.byte()` variadic multi-return resists annotation
- `lib/expr/init.lua` (73) — pervasive unknown propagation, requires restructuring
- `lib/graph_algorithms/init.lua` (77) — recursive `dfs_visit` pre-declared but checker still flagged
- `lib/platform/cli.lua` (68) — disparate nil/concat issues, no single pattern
- `lib/bin_packing/init.lua` — untyped local variables (`bins`, `remaining`); restructuring needed
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
- `lib/lru/init.lua` — attempted `Cache`/`Lfu`/`TwoQ` concrete shape replacement; narrow errors stayed at 70 (helper functions take `self` as untyped parameter, shape doesn't propagate) while constructor return-type mismatches added 3 new errors. Net 107→110, reverted. Proper fix requires annotating every `self` parameter on internal helpers + reconciling `_cap: integer` vs `math.floor(capacity)` literal flow. Restructuring.

## Done in current session

(workers append here in `[x] lib/foo/init.lua (was N → now M, commit <hash>)` form)
