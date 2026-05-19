# static-v4/walker — AST → v4 bridge

The walker translates Lua AST nodes (kinds from `lib/type/static/defs.lua`)
into v4 type-system constraints. See
`docs/typechecker-ast-walker-design.md` for the full design.

This directory is being built incrementally across sub-phases A–J (design
doc §13). **Current state: sub-phase B complete** — the env/dispatch
scaffolding from A plus SYNTHESIZE handlers for literals, identifiers,
and varargs. CHECK mode now actually emits constraints via the default
synth-and-subtype rule (§2.1).

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
