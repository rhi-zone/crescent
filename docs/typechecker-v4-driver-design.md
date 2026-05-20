# Typechecker v4 — Driver + CLI Integration Design

## 0. Frame

This doc designs the **driver** that turns a Lua source file into a
`(export_type, diagnostic_stream)` pair using the v4 type system and AST
walker, and the **CLI integration** that wires `bin/cr check` to that
driver. It is derived from three already-committed surfaces: the v4 public
API (`lib/type/static-v4/init.lua`), the AST walker A–J
(`lib/type/static-v4/walker/`), and the legacy parser's output schema
(`lib/type/static/parse.lua`).

What this doc is **not**: a redesign of the walker, the cache, or the
solver; an annotation grammar; a new diagnostic taxonomy beyond what
`walker/diag.lua` already declares. Those exist and are load-bearing
inputs.

## 1. Driver API

A single entry module `lib/type/static-v4/driver.lua` exports:

```
drive(source_path, opts) ->
    ( { exports: V4Type | nil,
        aliases: { [string]: V4Type },
        diagnostics: Diagnostic[],
        deps:    { [source_path]: source_hash },
        source_hash: string },
      errmsg | nil )
```

`opts` is required and caps-first (CLAUDE.md "Caps-first, everywhere"):

```
opts = {
    io_caps:       V4IoCaps,                 -- as in cache.lua
    cache_dir:     string,                   -- .cri cache root
    stdlib:        StdlibBindings,           -- pre-loaded (§3)
    require_chain: { [string]: V4Type | boolean } | nil,
                                             -- for recursive invocations
    solver:        V4Solver | nil,           -- nil means mint one
    parse:         (source: string, file: string) -> ParseResult,
                                             -- parser cap (parse.lua's M.parse)
    on_diagnostic: ((Diagnostic) -> nil) | nil,
                                             -- optional streaming sink
}
```

**Inputs**: `source_path`, `io_caps` (for source read + cache I/O),
`cache_dir`, pre-loaded `stdlib` bindings (loaded once per process,
re-injected per call). `parse` is itself an injected cap so the driver
never reaches `io.open` or a global parser.

**Outputs**: structured record with `exports` (the V4Type the file
synthesised as its `return` value, or `nil` for a side-effect-only
chunk), `aliases` (the file's `--::` declarations), the diagnostic stream,
and the dep-hash map (for `cache_store`'s `deps` argument).

**Side effects**: on success and only on success (no diagnostics with
`severity == "error"`), `V.cache_store(io_caps, cache_dir, source_hash,
artifact, deps)` is called with the packed `(exports, aliases)` artifact
(`require_resolve.pack_artifact`).

**Error modes**:

- **Parse failure**: `parse(...)` errored. Surface as a single
  `Diagnostic { code = E_INTERNAL or new code E_PARSE_FAILED, pos =
  parsed-from-error-string, msg }`. No cache write.
- **Walker structural failure**: an `E_UNSUPPORTED_NODE` (legitimate
  walker limit) or `E_INTERNAL` from the dispatch shell propagates as a
  diagnostic; no cache write.
- **Deep diagnostic accumulation**: the walker emits per-site
  diagnostics but does not short-circuit. The driver collects every
  diagnostic the walk produces. A non-empty error-severity list
  suppresses `cache_store`.
- **Recursive cycle**: handled by `require_chain` (§6); not an error.

The driver returns `(result, nil)` even when diagnostics include errors —
the second return is reserved for driver-itself failures (bad opts,
missing cap, parser unavailable). Error-vs-pass at the file level is a
predicate over `result.diagnostics`.

## 2. Parser invocation

`lib.type.static.parse.M.parse(source, filename, pool?)` returns
`{ nodes, lists, pool, root, lexer }`. The AST is arena-encoded:

- `nodes` is an `arena_mod.new_node_arena()` of fixed-shape `ASTNode`
  rows with `kind`, `flags`, `line`, `col`, and `data[0..5]` payload
  slots. Children are referenced by **integer indices** into the arena.
- `lists` is a list pool storing flat sequences of child indices,
  themselves referenced via `(start, len)` pairs stored in `data[i]`
  slots.
- `pool` is the intern pool — string and identifier slots are intern
  IDs, not strings.
- `root` is the arena index of the `NODE_CHUNK` row.

The walker, however, consumes **POJO nodes** with field names: `{ tag,
line, col, ... }` with handler-specific extras (e.g.
`NODE_LITERAL.lit_kind`/`value`, `NODE_IDENTIFIER.name`,
`NODE_CALL_EXPR.callee`/`args`, `NODE_FUNC_EXPR.params`/`body`). This is
documented in `walker/README.md` ("Decoded node shape") and is by design
— handlers stay portable to non-parser callers.

**Therefore the driver owns a node decoder** (`lib/type/static-v4/driver/decode.lua`,
co-located): given the arena triple `(nodes, lists, pool)`, hydrate a
single arena row into the POJO shape the walker expects, on demand. Per
node kind it reads the `data[]` slots, resolves intern IDs back to
strings, follows `(start, len)` references into `lists` to materialise
child arrays, and **recursively hydrates children lazily** — a parent's
`body` slot is a function `() -> POJONode[]` or a memoised array that
materialises on access. Lazy hydration is required: eager full-AST
materialisation defeats the arena's memory layout. The decoder is the
only module that knows both encodings; the walker continues to see only
POJO.

Decoder responsibilities per kind are mechanical; the table maps
`(kind, data slot semantics)` taken from `parse.lua` to the POJO field
names the walker handlers read.

`NODE_CHUNK`'s POJO shape is `{ tag = NODE_CHUNK, line, col, filename,
body: POJONode[] }`. The walker currently has no `NODE_CHUNK` handler —
this is what the driver adds.

## 3. Initial environment

At chunk entry the driver constructs an env via `E.new()` and threads:

```
env = E.with_source(
        E.with_cache_dir(
          E.with_io_caps(
            inject_stdlib(E.new(), opts.stdlib),
            opts.io_caps),
          opts.cache_dir),
        { file = source_path, line = 1, col = 1 })
env.require_chain = opts.require_chain or env.require_chain
```

`bindings` carry the stdlib globals; `aliases` carry the stdlib's `--::`
type aliases (`PcallReturn`, `Keys`, `Values`, `Open`, `Closed`,
`MetaOf`, …). `effects`, `module`, `expected`, `return_ty`, `vararg`
remain empty/nil (a chunk has no return expectation; `--::` declarations
in the chunk *can* set `return_ty`, but the driver does not pre-set it).

### Stdlib bindings — **chose Option B**: a dedicated v4 stdlib declaration file at `lib/type/static-v4/stdlib_types_v4.lua` exporting a `StdlibBindings = { bindings: { [string]: V4Type }, aliases: { [string]: V4Type } }` record built directly with `V.fn`, `V.rec`, `V.forall`, `V.match`, etc.

Reasoning, against the alternatives:

- **A (translate legacy `lib/type/static/stdlib_types.lua`)**. The legacy
  file is annotation-source (Lua comments with `--::`) that the legacy
  pipeline parses via `ann.lua` → legacy type IDs. v4 has no annotation
  parser bridge yet (the walker README calls this out: "the bridge from
  legacy `ann.lua` to V4Type is sub-phase J … walker accepts pre-resolved
  `V.fn` annotations"). Driving stdlib from A would force the
  annotation-parser bridge into the *driver's* critical path — a much
  larger scope than the driver itself.
- **C (bootstrap via the walker)**. Cyclic: the walker needs stdlib
  bindings to walk *any* file, including the file declaring those
  bindings. A `.cri` checked-in to the repo seems clever but pins the
  cache format as the canonical declaration source, which makes a format
  bump simultaneously a stdlib rebuild — a coupling the cache section
  explicitly avoids.
- **B** keeps stdlib declarations explicit, source-readable, machine-
  evaluable (it's just Lua building V4Type values), and decoupled from
  the annotation parser. When the annotation-parser bridge eventually
  lands, B's file can be regenerated *from* the legacy declarations as a
  one-time migration, but the driver path remains stable.

The file is loaded once per `bin/cr` invocation (top-level `require`,
returning the bindings record) and re-injected per `drive` call.
`inject_stdlib(env, bindings)` walks `bindings.bindings` and
`bindings.aliases`, calling `E.bind` / `E.bind_alias` for each entry.

## 4. Walk and result

The driver mints a solver via `V.new_solver()` (or accepts one) and:

```
local chunk_node = decode.hydrate_chunk(parse_result)
local _, env_out, err = W.walk_synth(chunk_node, env, solver)
```

The chunk handler (registered by the driver, since the walker has none —
confirmed by `walker_test.lua` which uses `NODE_CHUNK` as the canonical
unsupported-tag stub) iterates `chunk_node.body` and `walk_synth`s each
statement, threading the env forward. The handler returns:

- `exports`: the V4Type of the chunk's `return` expression. If the chunk
  has no `return`, the export is `V.prim("nil")` (Lua semantics: missing
  return is `nil`). If a `--::` declaration on the chunk overrides this,
  the chunk handler enforces it via a CHECK against the declared module
  type. (The chunk-level module-type declaration syntax lives in §11 as
  an open question.)
- `env_out`: the final env after the chunk. The driver pulls
  `env_out.aliases` into the result for cache packing.

Diagnostics are collected by routing every `D.emit` site through a
**driver-installed accumulator**. The cleanest path: the driver passes an
`on_diagnostic` cap on `env` (a new slot) which `D.emit` invokes after
constructing the Diagnostic. The walker's existing pattern (return
`(nil, env, err)` from a handler) continues to work — handlers already
return errs upward — but per-site emissions (such as inside
`require_resolve` and the future cast/annotation sites) also flow into
the accumulator without requiring every handler to bubble. The new env
slot is `env.diag_sink: ((Diagnostic) -> nil) | nil`, set on chunk entry
by the driver.

(Open question §11 #1: alternative is to scan `solver` post-walk for
accumulated constraint errors. The sink approach is preferred because
the walker already builds Diagnostics at the emission site with full
position/origin metadata; the solver only retains the latest error.)

## 5. Cache store

On a clean walk (no error-severity diagnostics):

1. **Source hash**: `source_hash = lib.hash.sha256.sha256(source_bytes)`.
   Same hash function the require-resolver already uses (matches the
   import side; the cache key is the *imported* file's source hash, so
   consistency is required).
2. **Pack the artifact**:
   `artifact = require_resolve.pack_artifact(exports, env_out.aliases)`
   — produces a closed `V.rec({ exports, aliases })`.
3. **Deps map**: the driver tracks every successful `require(...)` made
   during the walk, keyed by the resolved source path, valued by the
   imported file's source_hash. The walker's `require_resolve` is
   amended to populate `env.deps` (new slot, accumulated like
   `effects`) — or, equivalently, the recursive-walk callback (§6)
   records the dep at the call site. The driver merges these into
   `deps` for `cache_store`.
4. **Store**: `V.cache_store(io_caps, cache_dir, source_hash, artifact,
   deps)`.

`cache_store` already handles content-addressed file deduplication and
manifest update.

**On failure, no write.** The cache must never contain a partially-
typed file. This is non-negotiable: the cache is consulted as ground
truth on subsequent requires, and a half-typed cache entry poisons every
downstream file's reasoning.

## 6. Cache miss → recursive walk

Currently `require_resolve.lua` rejects with `E_REQUIRE_UNRESOLVED` on
miss. The driver replaces this with a recursive callback:

**Mechanism**. The driver installs an `env.drive_recursive` cap. The
`require_resolve.synth_call` handler, on cache miss, instead of emitting
`E_REQUIRE_UNRESOLVED`, calls:

```
env.drive_recursive(resolved_source_path, env)
```

which returns `(exports, aliases, source_hash, errmsg)`. The cap is
implemented by the driver as a call to itself (`drive`) with:

- `require_chain = E.push_require(env.require_chain, mod_name, true)`
- Same `io_caps`, `cache_dir`, `stdlib`, `parse`.
- A *fresh* solver (constraint state must not leak across file
  boundaries; `cache_store` only persists the final type, and inter-
  file constraints have no representation in the cache format).

The recursive driver call performs its own walk and cache store; the
outer caller then proceeds with the returned `exports`/`aliases` as if
it had been a cache hit. **The require_chain is the cycle detector** —
the existing `E.push_require` / `E.lookup_require` machinery already
implements this:

- **Cycle handling**. When `require("A")` recursively re-enters
  `require("A")` (A imports B imports A), the inner call's
  `E.lookup_require(env, "A")` finds the placeholder (`true` sentinel),
  the existing handler mints a `V.var("require:A")` placeholder, tags
  its origin, and returns it. The outer `A`-walk eventually resolves to
  a concrete type; unification through the placeholder's bounds
  back-propagates. **This matches Lua's runtime semantics** (the partial
  module is returned to the cyclic importer).

  The alternative (rejecting mutual imports as a soundness move) is
  rejected: Lua programs use them, the type system already supports
  them via `V.var` placeholder unification, and rejecting them would be
  a regression vs the legacy checker.

- **Recursion termination**. A recursive `drive` call MUST consult its
  passed-in `require_chain` before walking, so a `require("A")` deep in
  the import graph that re-enters A through a different path still
  short-circuits. The `require_resolve` handler already does this — the
  driver's only job is to thread `require_chain` through the recursive
  invocation.

- **No re-entrant cache writes**. A cache miss → recursive walk →
  successful walk → `cache_store(A)` happens before the outer caller
  resumes. By the time the outer caller's `require("A")` returns, A's
  `.cri` is on disk, so a sibling import of A from another walk that
  starts after this one is a hit. A sibling concurrent walk (parallel
  driver invocations) is a non-goal — the driver is single-threaded.

## 7. CLI integration

`bin/cr check <file>` currently dispatches to `bin/cr.lua` which in turn
loads the legacy CLI module. The transition path is **flag-gated** with
the v4 driver reachable via `bin/cr check --v4 <file>` and the default
remaining the legacy path until the cutover gate (§10) is satisfied.

Rationale:

- **Default-stay-legacy** preserves repository typecheck-on-commit
  invariants until v4 parity is proven. CLAUDE.md's pre-commit hook
  uses `bin/cr check` and any regression there breaks every commit
  flow; flipping the default before parity proof is a self-inflicted
  outage.
- **Compare mode** (running both, reporting divergences) is added as a
  second flag `--compare` reachable from the same dispatch. Compare is
  the workhorse for parity work — divergences become the v4 todo list.
  It is slow (two full pipelines), so it is not the default.
- **Default-v4** lands only after the §10 gate, at which point the
  legacy path becomes the flagged opt-in (`--legacy`) and is retired
  once no test or workflow references it.

Dispatch lives in a new `lib/type/static-v4/cli.lua` that the existing
`bin/cr.lua` shells into when `--v4` or `--compare` is present. The new
CLI module owns: arg parsing (filename(s), `--summary`, `--v4`,
`--compare`, `--cache-dir` overrides), driver opts construction
(`io_caps` built from real `lib.fs` functions, stdlib loaded once,
parser cap = `parse.M.parse`), driver invocation, and rendering (§8).

## 8. Diagnostic rendering

The walker emits `Diagnostic` records (see `walker/diag.lua`) with a
`__tostring` metamethod that renders `file:line:col: severity: msg`. The
driver collects them; the CLI is the rendering surface.

**Default rendering**: iterate the collected diagnostics, print
`tostring(d)` per line, exit non-zero if any has `severity == "error"`.
The existing concatenation patterns continue to work (`__concat` is
installed).

**`--summary` rendering**: a `group_by` over the structured fields, NOT
a regex over rendered text. Bucket selection in priority order per
diagnostic:

1. If `origin_kind` is set, the bucket is `(origin_kind, module)` —
   e.g. `("from-require", "lib.foo")` collects every downstream
   diagnostic that traces back through a single require, so the summary
   reads "23 errors caused by require(\"lib.foo\")".
2. Else, the bucket is `code` — e.g. `("type-mismatch")` for direct
   subtype failures with no origin chain.
3. The bucket's representative is the first diagnostic in the bucket;
   the bucket's count + a one-line summary of the representative is
   printed; under `--summary -v` the full list is expanded.

This is the audit's mandate (`walker/diag.lua` comment §0) realised in
the rendering layer — taxonomy lives in the data, the renderer is a
group_by lookup.

## 9. Test corpus migration strategy

The legacy test corpus (`type_test.lua`, `type_soundness_test.lua`,
`type_complex_test.lua`, fuzz suites) drives `check_string` and asserts
pass/fail. The v4 corpus migration is a **parity-test harness**:

- Add a `tests/v4_parity/` harness that, for each legacy test program
  (extracted from the existing `_test.lua` files into source files +
  expected-result files via a one-shot generator script committed in
  the same change), runs both pipelines:
  - Legacy: existing `check_string` returning `(ok, errors)`.
  - v4: `drive(temp_file_with_program, opts)` returning the diagnostic
    list.
- Assertion: `ok_legacy == (errors_v4 == empty)`. The bodies of error
  messages are not compared — only the pass/fail predicate. Error-body
  comparison is in scope at the rendering layer for compatible tooling,
  not at the parity level.
- Divergences are categorised:
  - **D1 (intentional)**: nil-padding semantics, structured diagnostic
    fields, stricter narrowing in v4. Documented in
    `docs/typechecker-v4-divergence.md` (new), one entry per case, with
    a justification. The divergence file is the cutover gate's record.
  - **D2 (bug)**: a v4 false-positive or false-negative without
    justification — fix v4.
  - **D3 (legacy bug, v4 correct)**: the legacy was wrong, v4 is right.
    Re-pin the legacy expectation; mark as intentional in the
    divergence file.

The fuzz suite (`fuzz_alg`, `fuzz_eval`, `fuzz_test`) is ported in a
second phase: `fuzz_alg` runs against v4 directly with no parser
involvement; `fuzz_test` requires parser+driver, ported in the same
parity-harness pattern.

## 10. Cutover strategy

v4 takes over as the default `bin/cr check` when:

1. **Parity acceptance**: 100% of the parity harness's positive cases
   pass. Every legacy-accepted program is v4-accepted (no false
   negatives).
2. **Parity rejection**: 100% of legacy-rejected programs are v4-
   rejected, modulo the explicit D1 list in the divergence doc. Every
   case on D1 is justified with a citation to `docs/type-system.md` or
   `docs/typechecker-reference.md` showing the new semantics are
   intentional.
3. **Fuzz parity**: `fuzz_alg` (algebra invariants — reflexivity, union
   intro, transitivity, etc.) passes on v4 at the same trial count as
   legacy. `fuzz_test` grammar invariants pass.
4. **Performance**: v4 is within 2× of legacy on the existing perf
   corpus (`docs/perf/log.md`), measured cold and warm. Within 1.2× is
   the long-term target; the cutover gate is 2× because the cache hit
   path makes warm runs fast independent of solver constant factors.
5. **Pre-commit gate**: `.githooks/pre-commit` exercised with v4 as
   default produces identical accept/reject decisions to legacy on the
   current `lib/**/*.lua` corpus. Any divergence is on the D1 list.

After cutover, `--legacy` remains for one release cycle for regression
extraction, then the legacy pipeline (`lib/type/static/cli.lua`,
constrain.lua, solve.lua, etc.) is deleted in a single commit. Half-
deleted legacy is forbidden per CLAUDE.md "minimal change" rejection.

## 11. Open design questions

These were not resolvable from the inputs and require either a session
with the user or empirical investigation. **Honest list, not
speculation**:

1. **Chunk-level module-type declarations**. The legacy syntax for "this
   file's return type is T" (used heavily across `lib/type/static-v4/`
   itself) is `--:: M = ...` plus an implicit `return M`, or an explicit
   `--: T` on the `return` statement. v4's chunk handler needs to
   resolve which form is canonical and what the typed-`module`-pattern
   accumulator does in env. The walker leaves `env.module` plumbed but
   uninterpreted (sub-phase A doc §14 #1). Driver design defers to a
   chunk handler that consults `env.module` if non-nil at chunk end,
   else falls through to `return`-expression synthesis.

2. **Annotation-parser bridge**. The walker `accepts pre-resolved V.fn
   annotations on AST nodes` (sub-phase H README). Real Lua source has
   `--:` comments that the legacy parser tokenises via `ann.lua` into
   legacy type IDs, NOT V4Types. The driver therefore needs a v4
   annotation parser (or a legacy→V4 type-id translator) to give the
   walker the `V4Type` values it expects on annotated function/local
   nodes. This is a large piece of work the driver depends on but does
   not itself design. Two paths: (a) write a v4-native annotation
   parser; (b) translate legacy `ann.lua` output into V4Type at the
   decoder boundary. (a) is cleaner; (b) is faster to ship. Unresolved.

3. **Decoder laziness vs eagerness**. The §2 sketch assumes lazy
   per-handler hydration. Measurement is needed: does eager full-tree
   POJO materialisation actually defeat the arena layout in practice,
   or is the JIT smart enough to keep the hot path cache-friendly
   regardless? If eager is competitive, decoder code is simpler. No
   data yet.

4. **Streaming vs batched diagnostics**. `on_diagnostic` is sketched as
   a per-emission sink. CLI rendering could equally consume a batched
   list at the end. Streaming benefits long files (early-output to the
   terminal) but complicates `--summary` (must wait for full list to
   bucket). Default likely batched; streaming is an opt-in. Unresolved
   whether streaming is worth designing in from day one.

5. **Parser as a cap vs an import**. `parse` is an injected cap in §1's
   opts; this is the caps-first reading. An alternative is to treat
   `lib.type.static.parse` as a pure module (no side effects beyond
   arena alloc) and import it directly. The injection form is preferred
   for testability (a fixture parser can be passed) but adds plumbing.
   Currently leaning injection; not strongly held.

6. **Solver lifecycle across recursive walks**. §6 says fresh solver per
   recursive `drive` call. Open question: does this lose any unification
   information that would help diagnose cross-file errors? The cache
   only persists the final V4Type (with bounded vars resolved), so a
   constraint that crosses a require boundary is unobservable. But if
   that's the wrong invariant for some future inference rule, the
   recursion design needs a per-file solver-scope flag. No
   counter-example today; flagging as a known assumption.

7. **`--cache-dir` default**. Per-repo `.crescent-cache/` vs `$XDG_CACHE_HOME/crescent/`?
   The former is git-aware (`.gitignore`-able), the latter is shared
   across clones. CLAUDE.md "git clone and run" suggests per-repo so a
   fresh clone starts with an empty cache (no stale entries from a
   previous clone). Unresolved whether this is the right default.

8. **Diagnostic dedup**. A `require_resolve` cache-miss + recursive
   walk that fails will surface the inner walk's diagnostics *and* the
   outer `E_REQUIRE_UNRESOLVED`. Should the outer suppress when the
   inner already errored? Probably yes (the outer is a propagation, not
   a new fact), but the rule needs stating. Not designed here.
