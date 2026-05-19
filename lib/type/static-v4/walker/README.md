# static-v4/walker — AST → v4 bridge

The walker translates Lua AST nodes (kinds from `lib/type/static/defs.lua`)
into v4 type-system constraints. See
`docs/typechecker-ast-walker-design.md` for the full design.

This directory is being built incrementally across sub-phases A–J (design
doc §13). **Current state: sub-phase G complete** — FFI cdef integration
recognises `ffi.cdef[[ ... ]]` call sites and populates the `$FfiC`
intrinsic table (the closed record bound to `ffi.C`). Stacks on top of A
(env/dispatch), B (literals, identifiers, varargs), C (functions, calls,
returns), D (control-flow + flow-sensitive narrowing), E (local/assign +
match), and F (indexed access, module pattern, varargs polish).

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
