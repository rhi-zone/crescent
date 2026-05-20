# static-v4/walker — AST → v4 bridge

The walker translates Lua AST nodes (kinds from `lib/type/static/defs.lua`)
into v4 type-system constraints. See
`docs/typechecker-ast-walker-design.md` for the full design.

This directory is being built incrementally across sub-phases A–J (design
doc §13). **Current state: sub-phase J in progress** — structured
diagnostics, source-position threading, and origin metadata are in place
(`diag.lua` / `origin.lua`). The recursive-walk-on-miss pipeline (parser →
walker → cache store) and `--summary` CLI rendering remain to land.

Stacks on top of A (env/dispatch), B (literals, identifiers, varargs),
C (functions, calls, returns), D (control-flow + flow-sensitive narrowing),
E (local/assign + match), F (indexed access, module pattern, varargs
polish), G (FFI cdef integration), H (effects), and I (cross-file require
resolution + `.cri` cache integration).

## Sub-phase J — structured diagnostics (this phase)

Per the design doc's `--summary` audit (the "Root-cause error grouping"
section): every walker-emitted diagnostic is now a **structured record**,
not a bare string. The audit's mandate is "taxonomy as data" — the
`--summary` grouping (whose default printer becomes a thin transform later)
must group_by `code` / `origin_kind` / `origin`, never by regex over
rendered messages.

### Diagnostic shape

```
{
  code:        string,        -- one of D.CODES (closed set)
  pos:         { file, line, col, end_line?, end_col? },
  msg:         string,        -- rendered human message
  origin:      Diagnostic | Origin | nil,
  origin_kind: string | nil,  -- "from-require", "from-cast", "propagated", ...
  module:      string | nil,  -- module name (E_REQUIRE_UNRESOLVED)
  severity:    string,        -- "error" | "warning"
  origin_rhs:  Origin | nil,  -- RHS-end of a subtype-failure chain
}
```

A `__tostring` metamethod renders to the legacy `file:line:col: severity:
msg` format; a `__concat` metamethod preserves the existing `"prefix: " ..
err` patterns at error-propagation sites. Error handlers thus return a
diagnostic record where they used to return a string, and existing string-
concatenating call sites continue to compile.

### Codes (closed set)

The taxonomy lives in `diag.lua`:

| Code                       | Meaning                                              |
|----------------------------|------------------------------------------------------|
| `E_UNDEFINED_NAME`         | Unbound identifier (no ambient globals)              |
| `E_TYPE_MISMATCH`          | Subtype failure (assign / call arg / return / check) |
| `E_FIELD_MISSING`          | Field access on a record without that field          |
| `E_CALL_ARITY`             | Arity mismatch on a call or annotation               |
| `E_CALL_NON_FN`            | Callee is not a function type                        |
| `E_OP_TYPE`                | Operator applied to wrong type                       |
| `E_ARG_MISSING`            | Missing required argument                            |
| `E_REQUIRE_UNRESOLVED`     | `require("mod")` failed to resolve                   |
| `E_REQUIRE_IO`             | `require` had no I/O caps / cache_dir                |
| `E_VARARG_OUT_OF_SCOPE`    | `...` used outside a vararg function                 |
| `E_RETURN_OUTSIDE_FN`      | `return` outside a function body                     |
| `E_EFFECT_UNDECLARED`      | Body performs an effect not in the annotation        |
| `E_FFI_CDEF`               | `ffi.cdef` shape / parse failure                     |
| `E_NOT_NARROWED`           | Value of type `unknown` must be narrowed             |
| `E_UNSUPPORTED_NODE`       | Walker has no handler yet for this node shape        |
| `E_INTERNAL`               | Walker invariant violated (bug)                      |
| `E_MATCH`                  | Match-type evaluation error                          |
| `E_CAST`                   | Cast failed (forced cast, etc.)                      |

Emitting an unrecognised code is a hard error (a typo in a walker handler
is a bug, not a runtime fallback): `D.emit` raises immediately if `code` is
not in `D.CODES`. New codes go in `diag.lua` deliberately.

### Origin metadata (parallel map, not on V4Type)

v4 itself does NOT store source positions on type values
(`type-system.md` Principle 13: "source locations do not belong in the
type system"). Origins live in `origin.lua` — a module-level parallel map
keyed by V4Type table identity. The lower-risk alternative was chosen over
retrofitting origins onto `types.lua`: v4 core stays untouched and the
origin policy lives in the walker, where the import-surface / cast /
narrowing concepts exist.

`O.record(ty, origin)` and `O.get(ty)` are the primitives. An origin
record carries:

```
{ kind: string, pos: { file, line, col, ... } | nil,
  module: string | nil, msg: string | nil, parent: Origin | nil }
```

`O.from_env(env, kind, opts)` builds one from `env.source`. `O.reset()` is
test-only / between-walks.

### Where origins are recorded

| Site                                 | Kind              | Carries                |
|--------------------------------------|-------------------|------------------------|
| `require("mod")` success (export ty) | `from-require`    | module name + pos      |
| `require("mod")` cycle placeholder   | `from-require`    | module name + pos      |
| Future: `--[[: T]]` cast result      | `from-cast`       | cast-site pos          |
| Future: `--: T` annotation binding   | `from-annotation` | annotation-site pos    |
| Wrapped propagation                  | `propagated`      | inner diagnostic       |

Subsequent sub-phases will extend the recording sites; the load-bearing
one for the `--summary` use-case (a `require` whose downstream uses fail)
is already in place.

### Diagnostic emission API

| API                                          | Use                                          |
|----------------------------------------------|----------------------------------------------|
| `D.emit(env, code, msg, opts?)`              | Standard emission                            |
| `D.from_solver(env, code, msg, solver, A, B)`| Subtype failure — consumes `solver.error`, populates origin from A's recorded origin |
| `D.chain(env, code, msg, inner)`             | Wrap an inner diagnostic with new context, marking the wrap as `propagated` |
| `D.lift(env, code, err)`                     | Normalise a possibly-raw error to a Diagnostic |
| `D.is_diagnostic(d)`                         | Predicate                                    |
| `D.position_from(env, opts)`                 | Resolve a pos table from env / opts          |

Opts on `D.emit`:

- `pos` — explicit position override (a sub-expression's pos beats env's).
- `origin` — explicit origin (a Diagnostic or an Origin record).
- `origin_type` — a V4Type; its recorded origin (if any) becomes the
  diagnostic's origin / origin_kind / module. This is the load-bearing
  piece: subtype failures automatically pull origin metadata from the
  participating types.
- `origin_kind`, `module`, `severity` — explicit overrides.

### Source-position threading

`env.source` is the canonical "where am I" reference, threaded through
every visit by `walker.lua`'s `position()` helper (sub-phase A). Every
walker error site reads from `env.source` via `D.position_from`. Nodes
that carry their own `line`/`col` (most do) override the threaded value
at visit-entry — `position()` calls `E.with_position(env, line, col)`
before dispatch. The end result: every emitted diagnostic carries a pos
that names the source location of the offending sub-expression, not just
the enclosing statement.

### What sub-phase J does NOT do (yet)

- Recursive walk on cache miss (parser → walker → cache store) — bigger
  structural work, lands later.
- `--summary` rendering itself — sub-phase J makes the structured data
  available; the CLI conversion comes next.
- Cast/annotation origin recording — the plumbing is in place
  (`O.O_FROM_CAST`, `O.O_FROM_ANNOTATION` constants exist) but no walker
  site currently produces these. They land when the annotation-parser
  bridge / cast handler lands.

## Earlier sub-phases (A–I)

## Sub-phase H — effects

`effects.lua` is the final CALL_EXPR-handler layer in the override chain
(B → C → F → G → H). It special-cases three intrinsic call shapes whose
semantics ordinary call-application cannot express:

- **`error(msg, ...)`** — adds `throw` to `env.effects` and synthesises
  to `V.bot()` (the call does not return).
- **`pcall(f, args...)`** — calls `f` in a throw-consuming context.
  Non-throw effects from `f` propagate to the outer frame; `throw` is
  masked. Returns `(true, R) | (false, string)` as a union of two closed
  records, matching `PcallReturn<F>` in `typechecker-reference.md` modulo
  the match-type sugar (a later sub-phase can swap in a `V.match` form).
- **`xpcall(f, msgh, args...)`** — same throw-mask, plus the message
  handler's effects propagate (a throw inside `msgh` is not masked —
  the protocol re-raises).

`coroutine.yield(...)` is **not** special-cased. The ordinary
binding-driven call-application path (sub-phase C's `apply_arrow`)
accumulates the `yield` effect automatically when `coroutine` is bound
to a record carrying `yield: () -[yield]-> nil`. The prelude is
responsible for providing that binding; the walker just walks.

Body-vs-annotation effect checking already lives in sub-phase C's
function handler (`functions.lua` lines 501-507): the body's accumulated
effect set must be a subset of the annotation's declared effects.
Sub-phase H provides the accumulation; sub-phase C provides the check.

Effect annotation surface syntax (`(A) -[yield]-> B`) has no consumer in
v4 yet — the bridge from legacy `ann.lua` to V4Type is sub-phase J. The
walker accepts pre-resolved `V.fn(params, ret, effects)` annotations on
AST nodes; that is the de-facto spec for now.

## Sub-phase I — cross-file resolution

`require_resolve.lua` is the final CALL_EXPR-handler layer in the override
chain (B → C → F → G → H → I). It recognises the call-site shape
`require("modname")` (bare-identifier `require` callee, single string-
literal argument) and resolves it through the v4 `.cri` content-addressed
cache. Non-require calls fall through to H unchanged.

### Pipeline

1. **Module-name → path resolution.** `lib.foo.bar` resolves to
   `lib/foo/bar.lua` if that file exists, otherwise
   `lib/foo/bar/init.lua`. This mirrors Lua's standard `package.path`
   with crescent's `?/init.lua` convention. File existence is queried via
   the injected `io_caps.file_exists`.
2. **Content hash.** The imported source file's raw bytes are SHA-256
   hashed via `lib.hash.sha256`. The hash is the cache lookup key.
3. **Cache lookup.** `V.cache_lookup(io_caps, cache_dir, source_hash)`
   returns serialised `.cri` bytes or nil.
4. **Cache hit.** `V.deserialize(bytes)` produces an *artifact* V4Type
   (see "Artifact encoding" below). The walker unpacks it into
   `(exports, aliases)`, binds the exports as the call expression's
   synthesised result, and merges the imported file's `--::` aliases into
   the requiring file's alias scope via `E.bind_alias`.
5. **Cache miss.** REJECT LOUDLY. Sub-phase I does not include the
   recursive walk — that requires an AST/source-parse pipeline which has
   no v4 bridge yet (sub-phase J). The miss diagnostic names the
   limitation honestly. Populating the cache out-of-band remains a
   supported workflow (the `cache_store` API is unchanged).

### Cycle detection

`env.require_chain` is a `{ [string]: V4Type | boolean }` map populated
while a `require` is in progress. Before resolving `require("A")`, the
chain entry `"A"` is pushed; a recursive `require("A")` inside A's body
sees the entry and returns the placeholder (Lua runtime semantics: the
inner require sees the in-progress module). The chain is unwound on the
way out so a sibling `require("A")` in the same scope re-resolves
through the cache. A genuine module-level cycle (A requires B requires A)
remains diagnosable: the second visit to A returns the placeholder var,
and downstream type unification surfaces any cycle-introduced
contradictions at use sites.

### Artifact encoding (export + aliases)

v4 `cache.lua` serialises a single V4Type. A file's import surface is two
things: the runtime exports type AND the file-scope `--::` aliases the
file declared. Sub-phase I packs both into one cacheable V4Type using a
closed-record wrapper:

```
V.rec({
  exports = <export V4Type>,
  aliases = V.rec({ Foo = <T>, Bar = <U>, ... }, false, nil),
}, false, nil)
```

The wrapper is opaque to `cache.lua` (one V4Type in, one V4Type out)
and the walker unpacks it on the read side via
`require_resolve.unpack_artifact`. This sidesteps any extension to the
cache wire format — the artifact-vs-bare-type distinction lives in the
walker, where the import-surface concept exists. Files written to the
cache from outside the walker must use the same wrapper shape;
`require_resolve.pack_artifact` is the canonical builder.

### I/O capability injection

The require resolver does NOT reach for `io` / `os` directly. The
walker's env carries:

- `env.io_caps` — `{ read_file, write_file, mkdir, file_exists }` for all
  file operations. Required for `require`; absence + an attempted
  `require` errors loudly (no fallback to globals, per CLAUDE.md
  "Caps-first, everywhere").
- `env.cache_dir` — base directory for the `.cri` cache. Required
  alongside io_caps.

Helpers: `E.with_io_caps`, `E.with_cache_dir`. These are file-scope
slots: `E.enter_function` preserves them across function boundaries (a
nested function body still resolves `require` against the file's
configured caps).

### Cross-file `--::` aliases

A file declaring `--:: Foo = ...` populates its own `env.aliases` map.
When that file is `require`d, the cached artifact's alias map is merged
into the requiring file's `env.aliases` (the v4 equivalent of legacy
Pass -1 alias propagation). Annotation resolution in the requiring file
then sees `Foo` as if it had been declared locally. The mechanism is
load-bearing for `--::` aliases that reference other files' types — the
walker does not improvise alias resolution from first principles.

The `--::` declaration walker that POPULATES `env.aliases` from in-file
`--::` lines is sub-phase J's responsibility (the annotation-parser
bridge); sub-phase I delivers the cross-file *plumbing*. Tests in I drive
the alias-map injection directly to verify the merge path.

### Decoded node shape — synthetic for sub-phase I

The require resolver consumes the existing `NODE_CALL_EXPR` shape (from
sub-phase C). No new decoded shapes.

### Env slots added in I

| Slot            | Type                                      | Purpose                                       |
|-----------------|-------------------------------------------|-----------------------------------------------|
| `aliases`       | `{ [string]: V4Type }`                    | File-scope `--::` alias names                 |
| `io_caps`       | `V4IoCaps \| nil`                         | Injected file I/O caps (read/write/mkdir/exists) |
| `cache_dir`     | `string \| nil`                           | Base directory for the `.cri` cache          |
| `require_chain` | `{ [string]: V4Type \| boolean }`         | Cycle-detection in-progress map               |

Helpers: `E.bind_alias`, `E.lookup_alias`, `E.with_io_caps`,
`E.with_cache_dir`, `E.push_require`, `E.pop_require`,
`E.lookup_require`. All are functional (return new env; original
untouched). `E.enter_function` preserves all four slots (file-scope, not
function-scope).

These four fields are intentionally NOT in the env.lua `--::` WalkerEnv
alias body (extending it triggers more of the documented cross-module
alias-resolution cascades). They are runtime-only extensions; helper
function signatures inline them at each use site.

### Cache miss — why "loud rejection" is principled here

Per CLAUDE.md "no half-measures with a TODO" — a cache miss path that
silently widens the requiring file's binding to `unknown` would poison
context for every future session: downstream code would see the wrong
type and reason from a broken premise. The loud rejection ensures the
miss is visible. The recursive-walk path is non-trivial because v4 has
no AST-source pipeline yet; the bridge (parse.lua → walker AST →
constraint generation → cache store) is sub-phase J's deliverable.
Until then, the cache miss is the signal, and the diagnostic names that.

## Sub-phase A — what's here

- **`env.lua`** — the `E` record from design §4. A functional record threaded
  through every walker visit:
  - `bindings` — name → V4Type, the visible scope.
  - `narrowed` — overlay consulted before `bindings` (the §5.4 "narrowed
    view" rule). Lookup precedence: narrowed wins.
  - `return_ty`, `vararg`, `effects` — current function-body frame.
  - `module` — the module-pattern accumulator slot (§3.11; semantics
    deferred to a later sub-phase per design §14 open question 1).
  - `expected` — current CHECK target. Set by the caller to switch the
    walker into CHECK mode; cleared back to SYNTHESIZE.
  - `source` — `{ file, line, col }` for diagnostics. Threaded via
    `with_position`; v4 itself does not carry positions
    (type-system.md Principle 13).
- **`walker.lua`** — dispatch shell only. `walk` / `walk_synth` /
  `walk_check` dispatch on `node.tag`. No handlers registered in A; every
  tag returns a stub error naming the node kind.
  - Extension mechanism: `register_synth(tag, handler)` /
    `register_check(tag, handler)`. Later sub-phases call these from their
    own module load sequence so dispatch wires up without editing this
    file.

## Design choices documented per design §14

§4 of the design doc is high-level. Three choice points were exercised in A
and are recorded here so a future session can audit them:

1. **Flat-with-copy vs parent-chain delegation.** §4 says "delegates lookups
   to its parent but records new bindings in its own map." We chose the
   flat copy-on-edit form: every `E.bind` returns a new env table with a
   fresh `bindings` map (the env table is also fresh, but other fields
   share references). Lookups are O(1); the cost is per-edit allocation.
   This fits CLAUDE.md "Table construction" (one hidden class per shape).
   Branch-join (§5.2) is also simpler with flat frames since each owns its
   full view.
2. **`source` shape.** The doc draft shows `{file, pool}`; we use the
   line/col form the sub-phase A prompt asks for: `{ file, line, col }`.
   The "pool" reference is to parser arena indexing, which the walker
   reads via the parallel `origin_map` (§12) — not stored in the env.
3. **`module` slot.** Typed `V4Type | nil` (the prompt's shape), not the
   §4-draft `V4Var | nil`. Sub-phase A does nothing with it; the
   downstream phase that wires module-pattern accumulation chooses the
   concrete shape (open question §14.1).

## Typechecker limitation discovered in A

The env shape is repeated inline at every function signature in `env.lua`
and `walker.lua` rather than abstracted as a single `--::` alias. The
crescent typechecker resolves cross-module aliases (`V4Type`, `V4Solver`)
inside `--:` function annotations and `--[[: T]]` casts — visibility flows
along the require graph — but **NOT** inside top-level `--::` alias
declarations whose bodies reference cross-module aliases. Attempting to
declare `--:: WalkerEnv = { bindings: { [string]: V4Type }, ... }` produces
"undefined type `V4Type`" even when `lib.type.static-v4.types` is required
at the top of the file. Inlining the shape sidesteps the limitation
without a lazy `unknown` widening (CLAUDE.md "Don't add type aliases that
legitimize laziness"). This is verbose; if the limitation is fixed
upstream, the shape can be consolidated to one alias.

## Sub-phase B — what's here

- **`literals.lua`** — SYNTHESIZE handlers for the three node kinds whose
  semantics map one-to-one to a v4 constructor with no subtyping, call,
  narrowing, or scope manipulation:
  - `NODE_LITERAL` (§3.1) — `lit_kind` selects the constructor:
    - `LIT_NIL` → `V.prim("nil")` (the canonical interned singleton; the
      design doc admits either prim or `V.literal("nil", nil)` — prim is
      preferred because a `nil` literal carries no useful precision).
    - `LIT_BOOLEAN` → `V.literal("boolean", v)`.
    - `LIT_INTEGER` → `V.literal("integer", v)` (the lexer distinguishes
      integer vs number; the walker trusts that).
    - `LIT_NUMBER` → `V.literal("number", v)`.
    - `LIT_STRING` → `V.literal("string", v)`.
  - `NODE_IDENTIFIER` (§3.2) — `E.lookup` (narrowing overlay takes
    precedence over the underlying binding). An unbound name errors
    `"undefined name X"`; crescent disallows ambient globals, so silently
    widening to `unknown` is forbidden.
  - `NODE_VARARG_EXPR` (§3.3) — synthesizes `env.vararg`; errors
    `"varargs not in scope"` when no enclosing function bears one. The
    tuple-spread semantics from §3.3 ("last expression of a call argument
    list / return / table constructor") is a property of the *enclosing*
    node, deferred to sub-phase D.

- **`walker.lua`** — the CHECK default rule (§2.1 "if in doubt, synthesize
  and subtype") now actually emits `V.constrain` and surfaces
  `solver.error`. Sub-phase A had the rule plumbed but deferred the
  constrain call until synth handlers existed; B is where that landed.
  `M._register_builtins()` composes the per-sub-phase handler modules
  on load (currently just `literals`); future sub-phases extend the list.

### Decoded node shape

Handlers consume a Lua-table view of each node, intentionally divorced
from the parser's FFI ASTNode struct so handlers stay portable to
non-parser callers (tests, REPL eval, future cdef integration). The
FFI→walker bridge is part of sub-phase J. The shapes:

| Node               | Fields                                                       |
|--------------------|--------------------------------------------------------------|
| NODE_LITERAL       | `{ tag, line, col, lit_kind, value }`                        |
| NODE_IDENTIFIER    | `{ tag, line, col, name }`                                   |
| NODE_VARARG_EXPR   | `{ tag, line, col }`                                         |

`lit_kind` is one of `defs.LIT_NIL`, `LIT_BOOLEAN`, `LIT_INTEGER`,
`LIT_NUMBER`, `LIT_STRING`. `value` is the Lua-typed payload (no payload
for `LIT_NIL`).

The Lua AST has no `NODE_PAREN_EXPR`: the parser unwraps parentheses
inline (`(x)` parses to the same node as `x`), so no handler is needed.

## Sub-phase C — what's here

- **`functions.lua`** — SYNTHESIZE handlers for the function/call surface:
  - `NODE_FUNC_EXPR` / `NODE_FUNC_DECL` (§3.9, §6.1): annotated path
    skolemizes a `V.forall` at body entry, binds parameters to the
    skolemized arrow's param types, walks the body in a fresh function
    frame, then runs the v4 escape check (`forall.find_escape`) on the
    return type. An annotated body whose effects exceed the annotation's
    declared effects is rejected. Unannotated path allocates fresh
    `V.var()` per param and a fresh return var, synthesizes the body
    (return statements constrain the ret var), and yields a `V.fn(...)`
    whose `effects` are the accumulated body effects. **No implicit
    let-generalization** — §6.3.
  - `NODE_CALL_EXPR` (§3.7): SYNTHESIZE callee → `forall.instantiate` if
    needed → SYNTHESIZE each argument → arity-check → constrain each
    arg against the corresponding param → accumulate the arrow's effects
    into `env.effects` → return the arrow's `ret`. Calls whose callee is
    `NODE_FIELD_EXPR` / `NODE_INDEX_EXPR` are **rejected loudly** with a
    "sub-phase F" message, per the hard rule (no temp-measure
    placeholders for indexed access).
  - `NODE_METHOD_CALL` (§3.8): SYNTHESIZE receiver → look up `method` on
    the receiver's `V.rec` fields → call-apply with the receiver
    prepended as the `self` argument. Receivers outside closed `V.rec`
    error cleanly — full union/μ distribution is in `V.index` and
    arrives in sub-phase F.
  - `NODE_RETURN_STMT` (§3.12, §8.3): zero-expr emits
    `V.nil_ <: return_ty`; single-expr collapses to scalar subtyping;
    multi-expr packs into a string-keyed `V.rec({["1"]=T1, ...}, false)`
    per the design's tuple convention (V4Rec.fields is typed
    `{ [string]: V4Type }`; the legacy D1/D2/D3/D4 tuple-spread fixes
    live in the multi-return-via-tuple representation, not in the v4
    tuple shape itself — the v4 subtype rule surfaces a scalar-vs-tuple
    mismatch directly).
  - `NODE_EXPR_STMT`: minimal expression-as-statement form needed so a
    function body can contain a bare call (the effect-accumulation tests
    rely on it). The full statement set lands in sub-phase E; only this
    one statement form is registered here because skipping it would
    leave sub-phase C's effect-accumulation tests inexpressible.

### Decoded node shapes added in C

| Node              | Fields                                                        |
|-------------------|---------------------------------------------------------------|
| NODE_FUNC_EXPR    | `{ tag, line, col, params: {{name, ann?}}, vararg, vararg_ann?, ret_ann?, generic?, annotation: V4Type?, body: Node[] }` |
| NODE_FUNC_DECL    | same as NODE_FUNC_EXPR (the decl-vs-expr distinction lives in the surrounding statement, which is sub-phase E) |
| NODE_CALL_EXPR    | `{ tag, line, col, callee: Node, args: Node[] }`              |
| NODE_METHOD_CALL  | `{ tag, line, col, receiver: Node, method: string, args: Node[] }` |
| NODE_RETURN_STMT  | `{ tag, line, col, exprs: Node[] }`                           |
| NODE_EXPR_STMT    | `{ tag, line, col, expr: Node }`                              |

`annotation` (on a function node) is the pre-resolved full function type
— a `V.fn` or `V.forall(.., V.fn)`. When present, the walker uses it
verbatim and the per-field annotations (`params[i].ann`, `ret_ann`,
`vararg_ann`) are ignored. When absent, the walker assembles the arrow
from those fields and from fresh vars. Wiring the annotation parser to
populate the `annotation` field is design Phase C (the "annotations and
casts" deliverable); walker sub-phase C consumes the field opaquely.

## Sub-phase D — what's here

- **`control_flow.lua`** — SYNTHESIZE handlers for the seven control-flow
  statements plus the centralised guard-pattern analyzer driving §5
  narrowing.

  Handlers registered:
  - `NODE_IF_STMT` (§3.12, §5) — folds `if`/`elseif`/`else` chains into
    nested two-branch joins. Guard analysis produces a positive and a
    negative narrowing map; the then-branch overlays positive, the
    else-recursion overlays negative. Branches that terminate (via
    `return` / `break`) drop out of the join. The post-`if` env has
    only narrowings the join produced; bindings introduced inside a
    branch are scoped out (block-scope discipline).
  - `NODE_WHILE_STMT` — body sees the guard's positive narrowing; after
    the loop, the negative narrowing applies (the loop exited because
    the guard became false).
  - `NODE_REPEAT_STMT` — body runs once with no incoming narrowing
    (Lua semantics: cond is at the END); the cond's positive narrowing
    flows past the loop into the surrounding scope.
  - `NODE_FOR_NUM` — synthesises init / stop / step; binds the loop var
    as `integer` if all three are integer-typed, else `number`. The
    loop-var binding is block-scoped to the body.
  - `NODE_FOR_IN` — synthesises the iterator expression; if it's a
    `forall`, instantiates it. Extracts the return-tuple positions
    (`V.rec` with string-indexed slots `"1"`, `"2"`, ...) and binds the
    loop names; a scalar return binds to the single name.
  - `NODE_DO_STMT` — walks the body with block-scope discipline.
  - `NODE_BREAK_STMT` — termination signal; `walk_statements` short-
    circuits the remaining statements in the same block on a break,
    and the surrounding loop/if-join treats the branch as terminated.

### Narrowing model (per design §5)

Both `atoms_pos` and `atoms_neg` carry **directly-applied** atoms —
the framework does NOT implicitly `V.neg` the falsy atom. The recogniser
encodes the complement explicitly when the guard form demands it. This
symmetry is essential for `not p` to be a literal pos↔neg swap and for
`and`/`or` to compose via per-map ops.

| Guard                              | atoms_pos                                  | atoms_neg                                  |
|------------------------------------|--------------------------------------------|--------------------------------------------|
| `if x then`                        | `~(nil \| false_lit)`                      | `nil \| false_lit`                         |
| `if x == lit` / `x ~= lit`         | `V.literal(...)` / `V.neg(...)`            | `V.neg(...)` / `V.literal(...)`            |
| `if x == nil` / `x ~= nil`         | `V.prim("nil")` / `V.neg(nil)`             | `V.neg(nil)` / `V.prim("nil")`             |
| `if type(x) == "kind"` / `~= ...`  | `V.prim("kind")` / `V.neg(prim)`           | `V.neg(prim)` / `V.prim("kind")`           |
| `if x.k == lit`                    | `V.rec({k=lit}, true)`                     | `V.neg(...)`                               |

Composites:
- `if a and b` — pos = pos(a) ⊓ pos(b) (per-var V.inter); neg = `{}`
  (a false `and` could be either side — no per-var info is safe).
- `if a or b`  — pos = pos(a) ⊔ pos(b) (per-var V.union, names in
  ONLY one side dropped — that side gives no info about a name the
  other doesn't constrain); neg = neg(a) ⊓ neg(b) (both must be false).
- `if not p`   — pos := neg(p); neg := pos(p).

Unrecognised guard form: walked for synth side-effects (so undefined
names / arity errors surface), no narrowing applied. This is **not**
deferred — it is the principled position. A guard form the recogniser
doesn't decode legitimately carries no information about variable
types and must not narrow.

### Decoded node shapes added in D

| Node              | Fields                                                                |
|-------------------|-----------------------------------------------------------------------|
| NODE_IF_STMT      | `{ tag, line, col, clauses: {{cond,body}}, else_body: Node[] \| nil }`|
| NODE_WHILE_STMT   | `{ tag, line, col, cond, body }`                                      |
| NODE_REPEAT_STMT  | `{ tag, line, col, body, cond }`                                      |
| NODE_FOR_NUM      | `{ tag, line, col, name, init, stop, step \| nil, body }`             |
| NODE_FOR_IN       | `{ tag, line, col, names: string[], exprs: Node[], body }`            |
| NODE_DO_STMT      | `{ tag, line, col, body }`                                            |
| NODE_BREAK_STMT   | `{ tag, line, col }`                                                  |
| NODE_BINARY_EXPR  | `{ tag, line, col, op: string, lhs, rhs }` (recognised by guard analyzer only — full handler in sub-phase E) |
| NODE_UNARY_EXPR   | `{ tag, line, col, op: string, operand }` (ditto) |
| NODE_FIELD_EXPR   | `{ tag, line, col, target, key: string }` (recognised by guard analyzer for discriminant narrowing only — full handler in sub-phase F) |

The guard analyzer pattern-matches `NODE_BINARY_EXPR`, `NODE_UNARY_EXPR`,
and `NODE_FIELD_EXPR` SHAPES without invoking synth handlers for them —
synth handlers for these nodes belong to sub-phases E/F. Pattern-matching
the shape from a control-flow context is **not** an indexed-callee /
binary-expr handler; it is the design's §5 recogniser reading the AST
directly.

## Sub-phase E — what's here

- **`statements.lua`** — SYNTHESIZE/CHECK handlers for local/assign
  statements and value-level match expressions.

  Handlers registered:
  - `NODE_LOCAL_STMT` (§3.11) — per-slot binding rules:
    - `(ann, init)` → CHECK `init` against `ann`; bind `ann`.
    - `(ann, _)`    → bind `ann`.
    - `(_,   init)` → bind `synth(init)`.
    - `(_,   _)`    → bind a fresh `V.var()`.
    Multi-binding uses last-spreads / non-last-truncates RHS distribution.
    Single-expr + single-annotated-name takes the bidirectional CHECK
    fast path (the common `local x --: T = expr` case).
  - `NODE_ASSIGN_STMT` (§3.11) — simple local-var assignment:
    `synth(rhs) <: typeof(lhs)`. LHS must be `NODE_IDENTIFIER` and the
    name must be bound. `NODE_FIELD_EXPR` / `NODE_INDEX_EXPR` targets are
    **rejected loudly** with a sub-phase-F message (no temp-measure for
    indexed writes). Multi-assign uses the same last-spreads /
    non-last-truncates distribution as local. Re-assignment does not
    refine the declared binding type — narrowing (a read-side overlay)
    is the only mechanism that refines a name's view.
  - `NODE_MATCH_EXPR` (§7) — value-level match-on-type:
    - SYNTHESIZE: synth the subject, dispatch to `V.match(subj_ty,
      arms, wildcard_result)`. Disjointness / non-exhaustive /
      suspension errors are surfaced verbatim.
    - CHECK: dispatch to `V.match_backward(arms, wildcard, expected)`
      to derive a subject constraint, then CHECK the subject against it.
    Captures (`%X`) are not manufactured by the walker — they're
    `V.var()`s shared between pattern and result, listed in
    `arm.captures`, allocated by the lowering / annotation-parser site
    that builds the node. Per `match.lua`, v4 freshens these on each
    evaluation, so the same node may be matched repeatedly without
    cross-contamination.

  **Module-pattern accumulation deferred.** The design doc §3.11 +
  §13.5 calls for tracking lower-bound field accumulation on a
  module-pattern accumulator (`local M = {}; M.foo = ...`). That
  requires indexed-access machinery, which is sub-phase F. The
  `module` slot in `env.lua` is already plumbed; once `V.index`-based
  field writes arrive in F, the accumulator wiring is mechanical. Per
  CLAUDE.md's no-temp-measure rule, field assignment in sub-phase E
  rejects loudly rather than half-implementing the accumulator.

### Multi-return distribution (Lua semantics)

For both `local` and `assign` with N targets and M RHS expressions:

  - If `M == 0`: every target binds `nil` (local) or is a no-op (assign).
  - For non-last RHS positions `i < M`: if `synth(rhs[i])` is a multi-
    return tuple (`V.rec({["1"]=...,...}, false)` with at least two
    string-keyed slots), truncate to slot `"1"`. Otherwise pass through.
  - For the last RHS position `M`: if multi-return, spread across the
    remaining LHS positions starting at `M`. Otherwise it fills slot `M`
    only.
  - LHS positions beyond what the RHS covers (after spreading) bind
    `V.nil_` for `local`. For `assign`, an uncovered position elides
    its constraint (matching Lua's runtime, which leaves the variable
    unchanged — modelled here by no-op rather than nil assignment).

This matches the legacy D2/D3/D4 multi-return fixes via v4's tuple
representation, not by porting the legacy code.

### Decoded node shapes added in E

| Node              | Fields                                                              |
|-------------------|---------------------------------------------------------------------|
| NODE_LOCAL_STMT   | `{ tag, line, col, names: {{ name, ann?: V4Type }}, exprs: Node[]? }` |
| NODE_ASSIGN_STMT  | `{ tag, line, col, targets: Node[], exprs: Node[] }`                |
| NODE_MATCH_EXPR   | `{ tag, line, col, subject: Node, arms: V4Arm[], wildcard_result: V4Type? }` |

`NODE_MATCH_EXPR` is a walker-only synthetic tag (defs.lua = 29). The
Lua parser does not emit it — there is no surface value-level match
construct. Tests and future lowering passes that lower annotation-side
`match X { ... }` types onto value-level matches construct the node
directly. Arms are records `{ pattern, result, captures }` consumable
by `V.match` / `V.match_backward` without further transformation.

## Sub-phase F — what's here

- **`indexed_access.lua`** — SYNTHESIZE handlers for indexed access plus
  the OVERRIDES for sub-phase C's `NODE_CALL_EXPR` (indexed callees) and
  sub-phase E's `NODE_LOCAL_STMT` / `NODE_ASSIGN_STMT` (module pattern
  + indexed-LHS writes).

  Handlers registered/overridden:
  - `NODE_FIELD_EXPR` (§3.6) — `obj.k` synthesizes the target, then
    `V.index(target, V.literal("string", k))`. Failures from `V.index`
    (closed-record missing field, unbound-variable target, indexer-key
    not locally discharge-able) become walker diagnostics verbatim.
  - `NODE_INDEX_EXPR` (§3.6) — `obj[key]` synthesizes both target AND
    key, then `V.index(target, key_ty)`. v4's index reducer handles
    the supported key shapes (literal string, primitive string, union
    thereof) and rejects unbound-variable keys per its own contract —
    the walker passes the rejection through without elaboration.
  - `NODE_TABLE_EXPR` (§3.10, partial) — the EMPTY case only. `{}`
    synthesizes to `V.rec({}, /*open=*/false, nil)`. Non-empty literals
    reject loudly with a "later sub-phase" message; the full table-literal
    CHECK/SYNTHESIZE pair is mechanical but isn't required by F (only the
    empty case feeds the module-pattern trigger).
  - `NODE_CALL_EXPR` (OVERRIDE; was rejected in C) — indexed callees
    (`obj.method(args)`, `tbl[k](args)`) now synthesize through the
    standard recursion (`W.walk_synth(node.callee, ...)` reaches the F
    field/index handlers) and continue with the function-call logic
    from C. The override also adds vararg spread on last-position
    arguments per §8.2 (see below).
  - `NODE_LOCAL_STMT` (OVERRIDE; module-pattern trigger) — the syntactic
    shape `local M [--: T] = {}` is detected:
    - With annotation: bind M to T directly. The empty-table init is
      treated as "M starts as the declared T"; subsequent field-writes
      are checked against T. Per design §13.5.3, the init expression's
      type is NOT checked against the annotation — `{}` is the canonical
      "I will fill this in" idiom.
    - Without annotation: allocate α_M = `V.var(name)`. Constrain
      `V.rec({}, false, nil) <: α_M` as a baseline lower bound. Bind
      M to α_M.
    All other LOCAL_STMT shapes defer to E's existing handler.
  - `NODE_ASSIGN_STMT` (OVERRIDE; indexed-LHS + module accumulation) —
    targets with `NODE_FIELD_EXPR` / `NODE_INDEX_EXPR` shape are
    resolved per Option D's two regimes:
    - **Variable-bound base** (the module-pattern case): build a
      singleton-field open record and constrain it as a lower bound:
      `V.rec({k = synth(rhs)}, /*open=*/true) <: α`. The `open=true`
      flag is load-bearing — it lets the singleton subtype any record
      containing `k`. Non-literal keys on a var-bound base fall back to
      indexer accumulation: `V.rec({}, true, V.indexer(key_ty, rhs_ty))`.
    - **Concrete-typed base** (the annotated case): query v4's index
      reducer for the field's type, then constrain `rhs <: field_ty`.
      `V.index` errors at write-of-absent-field-on-closed-record cleanly,
      surfacing the diagnostic at the assign site.
    Chained paths (`a.b.c = ...`) and computed-base shapes
    (`f(x).k = ...`) reject loudly with a clear message — they require
    field-path-root tracking that is not in F's scope.
    Plain `NODE_IDENTIFIER` targets fall through to E's logic
    (inlined here so the already-synthesized RHS types aren't re-walked).

### Module-pattern accumulation: design §13.5 (Option D)

The contract: a `V.var()` accumulator is the binding's type. Each
field-write adds a singleton-record lower bound. Reads via `V.index(α,
"k")` are deferred per v4 4b.2's no-deferred-queue rule until v4
gains the suspension queue (design §13.5.5 open subquestion 2). `return
M` flows α directly into the enclosing return slot; the var's
accumulated lowers travel along the bound graph into the receiving slot.

Whole-M against a multi-field expected record is NOT yet provable: v4
4a has no row polymorphism, so the open singleton `{foo, ...}` does
not subtype `{foo: integer, bar: string, ...}`. Per design §13.5.5
open subquestion 5, this lands when coalescing / row-polymorphism
arrives in a later v4 phase. The current implementation is principled:
each lower bound is structurally correct; the downstream observation
(individual M.foo lookups, or annotated module exports) is what waits.

### Varargs spread/non-spread (§8.2)

The vararg node itself (`NODE_VARARG_EXPR`, sub-phase B handler) still
synthesizes to `env.vararg` — a single value type or tuple. Sub-phase F
adds the enclosing-context discipline in `NODE_CALL_EXPR`:

- **Last-position vararg argument**: if env.vararg is a tuple-shaped
  `V.rec` (positional `"1"` / `"2"` / ... slots), spread its slots
  into the argument list. Otherwise the vararg contributes one
  scalar argument.
- **Non-last vararg argument**: collapse to the first positional slot
  (Lua semantics: `f(..., y)` evaluates `...` to its first value).

The same discipline belongs in `NODE_RETURN_STMT` and the (future)
non-empty table literal handler. F doesn't touch RETURN_STMT — the
existing single-expr collapse + multi-expr tuple-pack covers the
non-vararg cases; vararg-in-return-position is a later contribution
together with the full table-literal pass.

### Decoded node shapes added in F

| Node              | Fields                                                       |
|-------------------|--------------------------------------------------------------|
| NODE_FIELD_EXPR   | `{ tag, line, col, target: Node, key: string }`              |
| NODE_INDEX_EXPR   | `{ tag, line, col, target: Node, key: Node }`                |
| NODE_TABLE_EXPR   | `{ tag, line, col, fields: TableField[] }` (only `#fields == 0` accepted in F) |

## Sub-phase G — what's here

- **`ffi_cdef.lua`** — call-site recognition for `ffi.cdef[[ ... ]]`,
  invocation of the existing cdef parser
  (`lib/type/static/cdecl_parse.lua`), CTypeDesc → V4Type translation,
  and `$FfiC` accumulation via re-binding of the `ffi` env entry.

  Handlers registered/overridden:
  - `NODE_CALL_EXPR` (OVERRIDE; was sub-phase F's indexed-callee variant)
    — wraps F's handler. On a callee that matches `ffi.cdef` /
    `ffi["cdef"]` with exactly one string-literal argument, the cdef
    string is parsed via `cdecl_parse.parse(source, pool)` (the **existing**
    parser; we DO NOT reimplement). Each declaration is translated to a
    V4Type per design §9, and `ffi.C` is rebound to a new closed record
    carrying the merged field set. Non-cdef calls defer to F's handler
    unchanged.

  Detection contract:
  - `ffi.cdef` (NODE_FIELD_EXPR over identifier `ffi`, key `"cdef"`).
  - `ffi["cdef"]` (NODE_INDEX_EXPR with string-literal key `"cdef"`).
  - Any other callee shape is ignored (the call falls through to F).
  - Argument list must be exactly one NODE_LITERAL of LIT_STRING. A
    non-literal argument is rejected — static cdef analysis requires
    the literal text. Wrong arity is also rejected.

  $FfiC representation:
  - `ffi` is in env.bindings as a closed record `{ cdef: (string)->nil,
    C: V.rec({...}, /*open=*/false, nil) }`. The `C` field is the
    `$FfiC` accumulator.
  - Each cdef call rebuilds the `ffi` record with `C` replaced by a new
    closed record carrying the union of previous and new declarations.
    Closed-record discipline gives undeclared-symbol errors for free
    via v4's index reducer: `ffi.C.undeclared_xyz` resolves through
    the standard NODE_FIELD_EXPR path and errors at the missing field.
    No special case in the walker.

  CTypeDesc → V4Type table (design §9):
  - `void` → `V.prim("nil")`.
  - `bool` → `V.prim("boolean")`.
  - `int` / `char` / `enum` / typedef'd int kinds → `V.prim("integer")`.
  - `float` / `double` → `V.prim("number")`.
  - `char*` → `V.prim("string")` (C strings).
  - `void*` → `V.top()` (opaque).
  - struct → closed `V.rec` with named fields recursively translated.
  - `struct T *` → `V.rec({}, /*open=*/true, V.indexer(literal(0), inner))`
    — the open-record-with-zero-indexer encodes both pointer
    dereference (`ptr[0]`) and the structurally-implied field reads.
  - function / function pointer → `V.fn(params, ret, {})`. Variadic C
    functions get a trailing `V.top()` param as the principled fallback
    until v4 grows native variadic-fn support.
  - union / unresolved typedef name → `V.top()` (not safely representable
    as a closed rec; matches the v3 translator's choice).

  Translator parallel to `lib/type/static/cdef.lua`:
  The v3 translator writes into arena-backed type IDs; v4 uses value
  records. The translation table is the same (per design §9) but the
  output representation differs, so we re-derive the mapping in v4's
  constructors rather than wrapping the v3 translator. Per CLAUDE.md
  "Multiple implementations of the same spec" applies — both are real
  implementations of design §9, not one wrapping the other.

  Typedef and struct-declaration handling:
  - `typedef int my_int_t;` — the cdef parser tracks the typedef in its
    own typedef table; subsequent decls in the same call resolve `my_int_t`
    to `int`. The walker does NOT bind type aliases on the env (the
    walker env has no type-alias slot in 4a; this is a v4 limitation,
    not a sub-phase G punt). The integration is sufficient for the
    common case where typedefs are used to inform the same cdef block's
    function signatures.
  - `struct foo { int x; };` — defines a type but does not register a
    symbol on `ffi.C`. Field-write to `ffi.C` accepts only `func` /
    `var` / `enum_val` decl kinds per the parser's classification.

### Annotation-free, parallel to functions.lua / indexed_access.lua

`ffi_cdef.lua` follows the now-canonical annotation-free convention. The
cross-module `--::` alias-resolution limitation in env.lua's
`--:: WalkerEnv` declaration would re-trigger env.lua diagnostics if this
file carried `--:` annotations or `--::` aliases referencing V4Type. The
file is intentionally bare; structural narrowing uses `type()` guards
where field shape needs to be confirmed.

To work around per-branch narrowing of `ctype` to the literal type
checked at the dispatch site (`{k: "func"}` etc.) which would otherwise
make recursive sub-calls fail with "missing field" diagnostics, the
struct and function helpers (`struct_fields_to_v4`, `func_parts_to_v4`)
accept the raw inner fields rather than the parent descriptor. The
calling site indexes the fields out of the descriptor (`ctype.fields`,
`ctype.params`, etc.) before invoking the helper — this keeps the
helper's inferred signature independent of the dispatch branch.

### Decoded shapes added in G

The CTypeDesc shape comes from `lib/type/static/cdecl_parse.lua`. It is a
recursive open record with a `k` discriminant: `void`/`bool`/`int`/
`char`/`float`/`enum`/`ptr`/`arr`/`struct`/`union`/`func`/`name`. Fields
beyond `k` depend on `k` (`to` for `ptr`, `of` for `arr`,
`fields`/`members` for `struct`, `params`/`ret`/`vararg` for `func`).
See `lib/type/static/cdef.lua` and `cdecl_parse.lua` for the authoritative
shape.

## What comes next (design doc §13)

Sub-phase J remaining work:

- Recursive walk on cache miss (parser → walker → cache store pipeline).
- `--summary` CLI rendering (`bin/cr check --summary <file>`) as a
  thin transform over the structured diagnostic stream.
- Cast (`--[[: T]]`) and annotation (`--: T`) origin recording.
- Test corpus migration from `lib/type/static/` once parity is reached.

## Sibling: `../driver/` — the v4 driver

The parser→walker pipeline integration lives in `lib/type/static-v4/driver/`
(see `docs/typechecker-v4-driver-design.md`). The driver owns the
`{ source path, io_caps, stdlib, ... } → (exports, diagnostics, deps)`
contract. K2 of that work is the **arena → POJO decoder**
(`driver/decoder.lua`): given the legacy parser's
`{ nodes, lists, pool, root }` arena output, it produces the POJO
node tables this walker reads. The walker contract (integer `node.tag`,
`node.line/col`, per-kind fields from the "Decoded node shape" tables
above) is the decoder's output contract. No walker change is needed.
