# TODO

## security (fix soon)
- [x] http/router: path traversal via symlinks — `path.safe_resolve()` with FFI `realpath()`
- [x] http/server: reads one packet, not until headers complete — loop until `\r\n\r\n`, then read body by Content-Length
- [x] http/router/staticx: pattern `.gz$` should be `%.gz$` (Lua pattern, `.` matches any char)
- [x] http/router/staticx: opens files in `"r"` mode — should be `"rb"` to avoid newline mangling
- [ ] Full security audit of all imported libraries

## correctness
- [x] http/router/staticx: `Content-Length = ""` is invalid HTTP — omit header entirely
- [ ] http/router/staticx: detects directories via `read("*all") == nil` — fragile, use lfs or stat
- [ ] http/router/staticx: reads entire files into memory — needs size cap or streaming for large files

## stdlib
- [ ] http: extract network layer (client.lua, server.lua) — needs lib/ljsocket, lib/epoll, lib/socket/server.lua
- [ ] http: extract routers — needs lib/path, lib/mimetype, lib/fs, lib/lunajson
- [ ] Review and polish all libraries pulled from ~/git/lua (bulk import done)
- [ ] lib/todo/: conflicts with dep/todo/ (stubs for jpeg, png, xcb, soloud + a sqlitex.lua, webp.lua) — decide what to keep
- [ ] Audit vendored third-party libs (ljsocket, lunajson, sqlite, cparser, etc.) — ensure LICENSE files present
- [ ] Review lib/cli/ scripts — many have implicit dep on lib/ layout, may need path fixups
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

### annotation syntax gaps
- [ ] **Open table syntax in .d.lua**: `_G` and `ffi.C` require Lua code in `create_env()` because annotation syntax has no rowvar expression. Need `{ ... }` spread or `open {}` syntax.

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

Cat E — Nil-narrowing after early return: **PARTIALLY FIXED 2026-03-02**
- narrow.lua: bare identifier treated as nil-check; guard clauses apply negated narrowing
- narrow.lua: TAG_VAR not narrowed to T_NEVER (prevent "never" in branched code)
- StmtRule[NODE_IF_STMT]: after unconditional-exit clause, apply negated narrow to continuation
- ASSIGN_STMT: skip unify when existing resolves to T_NEVER (narrowed-out branches)
- OP_AND short-circuit narrowing: `a and a.field` narrows `a` before evaluating `a.field`.
  narrow_scope handles OP_AND in truthy branch; infer.lua OP_AND early-returns with narrowing.
- Remaining Cat E variant: compound `or` conditions like `if not x.field or ... then return end`
  cannot be narrowed — requires reasoning about sub-expressions of `or`

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

Cat G — string meta architecture (minor):
- `s:method()` special-cased via `recv_r == ctx.T_STRING` in ExprRule[NODE_METHOD_CALL]
- More principled: store `ctx.string_meta_tid` in prelude, use generically
- Blocked on: primitive types having declared metatables (a .cri/stdlib concern)

Cat H (new) — Optional function parameter typed as required: **FIXED 2026-03-02**
- Fixed in infer_function: scan first 10 body statements for `param = param or default`.
- After body inference, widen matched params to union(bound_type, T_NIL).
- `resolve_annotation_type(ctx, id)` (2 args) now accepted where 3rd param has default.

Cat I (new) — Explicit `local x = nil` still binds T_NIL: **FIXED 2026-03-02**
- Fixed in NODE_LOCAL_STMT: when rhs resolves to TAG_NIL, bind fresh typevar (same as Cat A).
- `local arg_ids = nil; arg_ids = {}` now works correctly.

**Phase 4 proper:**
- [ ] .cri interface files (zero-copy module loading, content-addressed)
- [ ] Module caching beyond single-session simple table
- [ ] Fork-based parallelism (Phase 5)
- [ ] LSP daemon integration (Phase 6)

**Next high-value false-positive fixes (from catalogue above):**
- [x] Cat A: forward-declared nil locals → make_var (unblocks most of infer.lua false positives)
- [x] Cat B: multi-return in assignments (right-hand side)
- [x] Cat D: boolean literal widen on reassignment
- [x] Cat E: guard/early-return nil narrowing (partial fix; compound conditions remain)
- [x] Cat C: positional table vs indexed type — FIXED 2026-03-02
- [x] Cat F: `A or B` result narrowing — FIXED 2026-03-02
- [x] Cat H: optional function parameters (seen arg pattern) — FIXED 2026-03-02
- [x] Cat I: explicit `local x = nil` treated as forward declaration — FIXED 2026-03-02

- [x] Infinite recursion in resolve_require: fixed with `_globally_resolving` module-level table.

Lexer optimization (see `docs/perf/log.md` for measurements):
- [x] Kill `_buf` mechanism — pointer arithmetic + `ffi.string` at end (1.4x speedup)
- [x] Source-referencing intern pool — FNV-1a hash + memcmp, zero Lua strings in lex path (5.3x total vs baseline)
- [ ] (stretch) Full FFI struct hash table for intern entries — current impl uses Lua tables per entry with FNV-1a + memcmp; a flat FFI array could reduce GC pressure further but 5.3x is good enough to move on

### backlog
- [x] Generic function inference (infer type params from call site args)
- [x] `<T>` explicit generic annotation syntax — `--: <T>(T) -> T` on a function; forall vars are generic typevars, freshened at each call site; composes with type-alias params (`--:: Name<T> = …`)
- [x] Partially inferred / partially specified generics — `f --[[:<json.Format, _>]] (val)` where `_` means infer. Annotation on any line `[callee.line, node.line]` (node.line = `(` line). Lua 5.1/LuaJIT constraint: `(` cannot be on a new line from the callee (ambiguous call syntax), so annotation must share the callee's line in practice. Lua 5.2+ compat removes this restriction.
- [ ] Parse LuaJIT FFI cdef blocks
- [x] v2 stdlib.d.lua: stdlib.d.lua created (2026-03-02); prelude.lua replaced with load_decls().
  `--:: declare name = type` for variable bindings; `--[[:: name = { ... }]]` for type aliases.
  Primitive meta types (number_meta, integer_meta, string_meta_ops) declared in stdlib.d.lua;
  derived into ctx fields after load_decls runs.
- [x] ann.lua: `declare` keyword added to ANN_DECL parser for variable bindings (vs type aliases).
- [x] ann.lua: function data[4] (vararg) fixed — trailing `...T` SPREAD now extracted correctly.
- [x] ann.lua: table data[4] (row_var) fixed — closed by default (-1), was accidentally open (0).
- [x] ann.lua: skip_ws fixed to handle newlines (B_NL, B_CR) for multi-line block annotations.
- [ ] `pcall`/`xpcall` return type narrowing
- [ ] For-in iterator return type tracking — `for k, v in pairs(t)` always gives `any` for k/v; need iterator protocol inference (ipairs/pairs over typed tables, custom iterators)
- [x] Metatable slot syntax: `#field` in type annotations — done (see above)
- [x] Structural operator dispatch — BinaryExpression/UnaryExpression/ConcatenateExpression check `meta["__add"]` etc. on operand types via `meta_op_ret`; metamethod return type used instead of primitive check. Unlocks linalg / custom numeric types.
- [x] Structural constraint propagation for send — `x:method(args)` on a var should constrain x to `{ method: (self, args...) -> T, ...row }` (mirrors field access on var).
- [x] Implicit-any warnings on unannotated params — warn if param typevar still completely unbound after body inference; skip `self` and `_`.
- [x] Arithmetic/concat constraint propagation — `a + b` on vars should constrain to "numeric OR has `#__add`"; cannot naively bind to `number` (rejects custom types). Needs a typeclass-style "Numeric" constraint or union of `number | { #__add: ... }`. Same for concat and `#__concat`.
- [ ] Branch-join / post-if type merging — after `if/else`, merge the types from each branch (currently outer scope is used unchanged). E.g. `x: A|B; if type(x)=="A" then x=b_val end` leaves x as `A|B` after the block rather than `B|A`. Requires tracking per-branch mutations and joining at merge point.
- [ ] Private field visibility enforcement
- [ ] $EachField / $EachUnion full transform evaluation
- [ ] Typed holes / completions
- [ ] Variadic `pipe`/`compose` typing — fixed-arity overloads work but variadic needs design; blocked on generic inference + possibly variadic generics or dependent types. Low priority, pending design.

## performance

- [ ] Bench infrastructure (pure Lua, handgrown) — micro + macro; latency histograms; compare before/after on HTTP request path. v2 parser bench: `docs/perf/v2_parse.lua`; perf log: `docs/perf/log.md`
- [ ] Write buffering — HTTP response assembly currently does many small `sock:send()` calls; gather into an iovec or corked buffer before flushing (TCP_CORK / TCP_NOPUSH via setsockopt FFI)
- [ ] Zero-copy static file serving — `sendfile(2)` FFI wrapper for staticx; avoids read-into-Lua-string + write round-trip; meaningful for large files
- [ ] `writev` / scatter-gather — single syscall for header + body chunks; pairs with write buffering above; FFI wrapper + iovec builder helper
- [ ] Buffer pool — reusable fixed-size byte buffers (FFI `uint8_t[N]`) to eliminate hot-path string allocations in HTTP parser and response serialiser
- [ ] Header serialisation fast path — avoid `table.concat` + string interning on every response; pre-serialise static headers once, memcpy into buffer
- [ ] Profile-guided allocation reduction — run under `jit.p` / `jit.dump` to find top allocation sites before committing to specific optimisations

## infra
- [ ] Fuzz infrastructure (pure Lua, handgrown)
- [ ] Formalize code style conventions — don't assume ~/git/lua conventions are correct, decide fresh
- [ ] `cr` binary entry point
- [ ] Third-party libs under lib/ must preserve original LICENSE

## LSP
- [ ] LSP server (JSON-RPC over stdio) — wire protocol is ~100 lines; hard part is the incremental model
- [ ] Position → type query — retain `(line, col) → type` table during inference for hover
- [ ] Incremental re-check — cheap scope invalidation so full reparse isn't needed on every keystroke
- [ ] Module-level type cache — avoid re-typechecking stdlib/imports on every edit
- [ ] Completion — field enumeration on partial expressions; needs partial-parse recovery
- [ ] Go-to-def — binding provenance map (name → declaration site)

## package manager
- [ ] Vendor-first install (copy .lua files into project)
- [ ] Registry / index format
