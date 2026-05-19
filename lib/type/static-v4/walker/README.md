# static-v4/walker — AST → v4 bridge

The walker translates Lua AST nodes (kinds from `lib/type/static/defs.lua`)
into v4 type-system constraints. See
`docs/typechecker-ast-walker-design.md` for the full design.

This directory is being built incrementally across sub-phases A–J (design
doc §13). **Current state: sub-phase D complete** — control-flow
statements (`if`, `while`, `repeat`, numeric/generic `for`, `do`-blocks,
`break`) and the flow-sensitive narrowing engine on top of A (env/dispatch),
B (literals, identifiers, varargs) and C (functions, calls, returns).

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

## Sub-phase A does NOT include

- Per-node handlers — every `node.tag` dispatches to a stub.
- Constraint emission via `V.constrain`.
- Narrowing logic (just the data structure for it).
- Effect inference (just the `effects` slot).
- Module-pattern handling (just the `module` slot).
- Diagnostic / origin-map machinery beyond `with_position`.
- CLI integration.

## What comes next (design doc §13)

- **Phase C** — annotations and casts (parallel with D).
- **Phase D** — expressions, calls, indexing (parallel with C).
- **Phase E** — statements and control-flow scaffolding (no narrowing).
- **Phase F** — narrowing.
- **Phase G** — forall annotations / rank-N (parallel with F).
- **Phase H** — match types.
- **Phase I** — FFI cdef integration.
- **Phase J** — effects + cross-file `require` cache + diagnostics
  (integration phase).
