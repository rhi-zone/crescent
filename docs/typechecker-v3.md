# Typechecker v3 — Constraint-Based Inference

## Why v3

v2 kept the inference algorithm from v1 (online unification) while rebuilding the
data structures (flat-array AST, arena allocation, union-find). The data structures
are correct and stay. The inference algorithm is not.

**Online unification** binds type variables immediately as the AST is walked.
This makes inference order-dependent:

```lua
local function v(maj, min, pat)   -- unannotated: maj/min/pat are free TAGVARs
  return { major=maj, minor=min, patch=pat }
end
v(cv.major + 1, 0, 0)   -- first call: binds min→LIT_INTEGER(0), pat→LIT_INTEGER(0)
v(maj, min + 1, 0)       -- second call: `number` not assignable to `0` ← wrong
```

The first call site "wins" and pins the typevar to a literal. Every later call
that passes a different (but compatible) type fails. The workaround is to widen
literals at call sites — but that's a patch on a broken foundation.

**Constraint-based inference** (Algorithm W / Damas-Milner) separates:

1. **Constraint generation** — walk AST, emit typed constraints, do not solve
2. **Solving** — find the most general unifier across all constraints simultaneously

All call sites contribute constraints together. The solver finds `integer` as the
most general type satisfying `LIT_INTEGER(0)`, `LIT_INTEGER(0)`, and `number` —
without any call site winning. Literal widening falls out naturally.

## What stays from v2

Everything except the inference pass:

- Flat-array AST, FFI arena, integer node types
- Lexer, parser, annotation parser
- Type arena, integer type tags, union-find (`find`, `bind_var`)
- Types: TAG_TABLE, TAG_UNION, TAG_INTERSECTION, TAG_FUNC, TAG_TUPLE,
  TAG_LITERAL, TAG_ENUM_MEMBER, TAG_ROWVAR, TAG_UNKNOWN, TAG_ANY, TAG_NEVER, ...
- Prelude, stdlib.d.lua, ann.lua
- .cri format, cache.lua, cri_read/write
- errors.lua, check.lua, cli.lua, lsp.lua

Replace: `infer.lua` → `constrain.lua` + `solve.lua` (+ updated `narrow.lua`)

## Constraint language

```
Constraint:
  Unify(t1, t2, span)          -- t1 and t2 must be the same type
  Sub(t1, t2, span)            -- t1 must be assignable to t2
  HasField(t, name_id, res, span)  -- t has field name_id of type res
  Callable(t, args[], res, span)   -- t is callable with args, returns res
  Arith(op, t1, t2, res, span)     -- arithmetic/comparison result type
  IsReturn(t, span)            -- t is a return type of the current function
```

`span` carries the AST node location for error reporting. Constraints are
emitted into a flat array during the generation walk; solving happens after.

## Constraint generation (constrain.lua)

Same AST walk as current infer.lua, but instead of unifying immediately:

- Emit `Sub(actual, expected, span)` at call sites, assignments, return stmts
- Emit `HasField(obj, name, result_fresh_var, span)` at field accesses
- Emit `Callable(callee, arg_tids, ret_fresh_var, span)` at call expressions
- Emit `Arith(op, lhs, rhs, result_fresh_var, span)` at binary expressions
- Fresh type variables (TAG_VAR) are created freely; solving binds them

No typevar is bound during generation. The generation pass is a pure reader
of the AST that writes to the constraint array and the type arena (for fresh vars).

## Solving (solve.lua)

Iterate the constraint array. For each constraint:

- `Unify(t1, t2)` → call `unify(find(t1), find(t2))` (existing unify.lua logic)
- `Sub(t1, t2)` → widen t1 to base type, then `Unify(widened, t2)`
- `HasField(t, name, res)` → if t is TAG_VAR, add field to open table and bind;
  if t is TAG_TABLE, look up field and `Unify(field_type, res)`;
  if t is TAG_UNION, res = union of each member's field type
- `Callable(t, args, ret)` → instantiate function type, unify args and ret
- `Arith(op, t1, t2, res)` → resolve metamethods or primitive dispatch, `Unify(res, result_type)`

Iterate to fixpoint (most constraints resolve in one pass; recursive types may
need two). Errors fire during solving with the span from the constraint.

## Let-polymorphism

Local functions defined with unannotated parameters should be **generalized**
at their definition point and **instantiated** (fresh typevars) at each call site —
exactly like v2's existing generalize/instantiate, but now triggered correctly:

- After solving the function body constraints, call `generalize(fn_tid)` to
  replace solved-but-still-free typevars with ForAll-bound vars
- At each call site, `instantiate(fn_tid)` freshens the ForAll vars

This gives `v` the type `<A, B, C>(A, B, C) -> { major: A, minor: B, patch: C }`
rather than `(number, 0, 0) -> ...`. All call sites succeed.

Currently v2 has generalize/instantiate but it only fires for cross-call-site
typevar mutation avoidance, not for proper let-polymorphism. Constraint-based
inference makes generalization a natural consequence of the solve order:
**generalize after solving the definition, before processing call sites**.

## Narrowing

`narrow.lua` is structurally unchanged. Narrowing is a post-constraint-generation
step that refines types in conditional branches. It reads solved types and emits
refined bindings into branch scopes — exactly as today.

The only change: narrowing reads from `find(tid)` (solved types) rather than
whatever was bound online during inference.

## Error reporting

Each constraint carries a `span` (line, col, node_id). When solving fails on a
constraint, the error message uses that span. The "might also be" union error
format from v2 applies identically — it's a property of the display/message layer,
not the solver.

For multi-step errors (e.g. "field X was set here, mismatches here"), the
constraint's span is the *use site*; a secondary span can be attached at
generation time by recording where the constraining type was first introduced.

## Migration plan

### Phase 1 — Parallel implementation
- Implement `constrain.lua` + `solve.lua` alongside existing `infer.lua`
- New entrypoint: `check.check_string_v3(src)` runs new pipeline
- Run both v2 and v3 on the test suite; diff results
- v3 is ready when it matches or exceeds v2 on correctness (fewer false positives,
  same true positives)

### Phase 2 — Cutover
- Replace `check.check_string` with v3 pipeline
- Delete `infer.lua` (or keep as reference for 1 commit)
- All existing tests must pass

### Phase 3 — Enable new capabilities
- Arithmetic constraint propagation to field-slot typevars
  (e.g. `a.major < b.major` → `a.major: number`)
- Correlated multi-return narrowing (backlog item from session 24)
- Improved generic inference (constraint-directed instantiation)

## Performance

Constraint generation is a single AST pass — same complexity as the current
inference walk. Solving is O(n·α) in the number of constraints (n) where α
is the inverse Ackermann factor from union-find. For typical files this is
effectively O(n).

The constraint array is a flat Lua table of {kind, t1, t2, span} records.
If profiling shows this is a bottleneck (unlikely at file scale), it can be
moved to an FFI array — but start with Lua tables.

## Open questions

1. **Recursive types**: the occurs check prevents infinite types, but mutually
   recursive table types (rare in Lua) may need a occurs-check relaxation.
   Defer until it surfaces.

2. **Union types**: HM doesn't naturally produce unions — they're introduced by
   explicit `|` annotations and `or`-expression inference. Union members are
   individual constraints; the union is assembled at the end. This is the same
   as v2.

3. **Row polymorphism**: TAG_ROWVAR (open tables) maps cleanly to row variables
   in constraint-based systems. `HasField` on a TAG_ROWVAR adds to its row;
   this is exactly the existing `table_add_field` behaviour, deferred to solve time.

4. **Annotation interaction**: annotated functions skip constraint-based param
   inference — their declared types are ground truth. This is unchanged from v2.
