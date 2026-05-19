# Typechecker AST walker — design

## 0. Frame

This document specifies the AST walker that bridges crescent's Lua parser
(producing the node kinds enumerated in `lib/type/static/defs.lua`) to the v4
type system core (`lib/type/static-v4/`). It is derived from two inputs only:
the v4 public API (`types.lua`, `subtype.lua`, `empty.lua`, `index.lua`,
`match.lua`, `forall.lua`, `cache.lua`, `init.lua`) and the canonical feature
surface in `docs/typechecker-reference.md` / `docs/type-system.md` /
`docs/typechecker-rewrite-design.md`. The walker described here was not read
out of any pre-existing constraint-generator file; it is a clean-room design
intended to replace `lib/type/static/constrain.lua` wholesale, not extend it.

This doc is **not**: a delta against the existing constrain.lua/solve.lua, a
roadmap for incremental migration, or a fallback plan. It is the target shape.
Mismatches with the current code are the current code's problem to resolve.

The v4 module is referred to throughout as `V`; the public surface is what
`lib/type/static-v4/init.lua` re-exports. Constraints are emitted by calling
`V.constrain(solver, A, B)`. There is exactly one constraint primitive (`<:`);
every obligation in this document reduces to that call.

## 1. AST node inventory

The Lua parser (`lib/type/static/defs.lua`) defines 29 node kinds. Walker
behavior is specified per-kind. Each entry: (k) short description, (f) the
structurally meaningful fields, (i) the information that must flow.

1. **NODE_CHUNK** (k) top-level file. (f) list of statements. (i) the chunk's
   inferred export type (the `return M` if present, otherwise `nil`).
2. **NODE_LITERAL** (k) `nil`, `true`, `false`, numbers, strings, vararg literal.
   (f) base, value. (i) a literal type or primitive.
3. **NODE_IDENTIFIER** (k) variable reference. (f) name. (i) the binding's type
   from the environment (including narrowed view).
4. **NODE_VARARG_EXPR** (k) `...`. (f) none. (i) the enclosing function's
   vararg type.
5. **NODE_UNARY_EXPR** (k) `-x`, `not x`, `#x`. (f) op, operand. (i) result
   type from operator-specific rules.
6. **NODE_BINARY_EXPR** (k) arithmetic, comparison, logical, concat. (f) op,
   left, right. (i) result type; for `and`/`or` also a narrowing contribution
   to either branch.
7. **NODE_INDEX_EXPR** (k) `t[k]`. (f) target, key. (i) result via `V.index`.
8. **NODE_FIELD_EXPR** (k) `t.k`. (f) target, name. (i) result via `V.index`
   with a string-literal key.
9. **NODE_CALL_EXPR** (k) `f(a, b, ...)`. (f) callee, args. (i) instantiated
   return type; emits a subtype constraint on `callee <: fn(args -> α)`.
10. **NODE_METHOD_CALL** (k) `obj:m(args)`. (f) receiver, method, args. (i)
    same as CALL_EXPR with receiver prepended.
11. **NODE_FUNC_EXPR** (k) anonymous function literal. (f) params, vararg,
    body, attached annotation. (i) a `V.fn(...)` (or `V.forall(..., V.fn(...))`
    if generic).
12. **NODE_TABLE_EXPR** (k) `{ ... }`. (f) list of TABLE_FIELDs. (i) a
    `V.rec(...)` with inferred field types; or a tuple-shaped record when all
    keys are positional.
13. **NODE_TABLE_FIELD** (k) single field. (f) key-form (positional, name,
    expr), key, value. (i) contributes a field to the enclosing TABLE_EXPR's
    rec.
14. **NODE_CAST_EXPR** (k) `expr --[[: T]]` (checked) / `expr --[[:! T]]`
    (force). (f) inner, target type, force-flag. (i) checked path emits
    `inner <: target`; force path is overlap-checked via emptiness.
15. **NODE_ASSIGN_STMT** (k) `lhs = rhs`. (f) lhs list, rhs list. (i) emits
    `rhs_i <: typeof(lhs_i)`; for `M.foo = ...` on a module table, accumulates
    a field.
16. **NODE_LOCAL_STMT** (k) `local x, y = a, b`. (f) names, annotations,
    rhs list, attribute (`<const>`, `<close>`). (i) binds new locals; if
    annotated, emits `rhs <: ann` and uses `ann` as the binding type; else
    binds the synthesized rhs type.
17. **NODE_FUNC_DECL** (k) `function name() end` / `function t.k:m() end`. (f)
    name path, is-method, params, body. (i) emits a function-expression-shaped
    type and binds it to the name path (which may be a multi-segment field
    assignment on a module table).
18. **NODE_DO_STMT** (k) `do ... end`. (f) body. (i) opens a scope.
19. **NODE_WHILE_STMT** (k) `while c do ... end`. (f) cond, body. (i) cond
    narrows in the body; body re-enters narrowed scope.
20. **NODE_REPEAT_STMT** (k) `repeat ... until c`. (f) body, cond. (i) cond
    narrows after the body.
21. **NODE_IF_STMT** (k) `if/elseif/else`. (f) clauses. (i) each clause's
    cond narrows its body; else-tail receives the accumulated complement.
22. **NODE_IF_CLAUSE** (k) one arm of an if. (f) cond (or nil for else), body.
23. **NODE_FOR_NUM** (k) `for i = a, b, c do`. (f) var, init, stop, step,
    body. (i) `i` binds to a numeric type derived from init/stop/step.
24. **NODE_FOR_IN** (k) `for k, v in iter do`. (f) names, iter exprs, body.
    (i) destructure the iterator's return tuple into the loop names.
25. **NODE_RETURN_STMT** (k) `return ...`. (f) exprs. (i) emits subtype
    constraints from each expression into the enclosing function's return
    type slot (single-return: ret; multi-return: a tuple record).
26. **NODE_BREAK_STMT** (k) `break`. (f) none. (i) terminates flow; no type.
27. **NODE_GOTO_STMT** (k) `goto label`. (f) name.
28. **NODE_LABEL_STMT** (k) `::name::`. (f) name.
29. **NODE_EXPR_STMT** (k) bare expression statement (call as statement). (f)
    expr.

Annotations are attached out-of-band by the lexer (`ann.lua`'s
`parse_annotations`); the walker reads them off the relevant nodes' attached
metadata. The annotation forms themselves are listed in
`docs/typechecker-reference.md`.

## 2. Walker shape and modes

The walker is **bidirectional**. Every expression node visit takes one of two
modes:

- **CHECK(expected_type)** — the caller has a target type; the walker emits
  constraints to prove the expression conforms. Returns nothing (failure is
  reported via the solver's accumulated error state).
- **SYNTHESIZE()** — no target; the walker produces a v4 type witnessing what
  it inferred. Returns a `V4Type`.

Statement nodes have neither mode; they walk in their own discipline and
mutate the environment.

### 2.1 Mode-switch policy

- **Default-synthesize, check-on-demand.** Walkers default to SYNTHESIZE
  except where context provides an expected type. Sources of an expected type:
  - the right-hand side of a `--:` annotated `local`,
  - an explicit `--[[: T]]` cast,
  - a function argument flowing into an annotated parameter slot,
  - a `return` expression flowing into an annotated return slot,
  - a table-field initializer flowing into an annotated field of an
    expected-table type (e.g. `local t --: { x: T } = { x = ... }`).
- **Check ↔ synthesize crossing.** A CHECK at node N with expected `E`
  reduces to SYNTHESIZE at N then `V.constrain(s, synth, E)` whenever N has
  no direct CHECK rule of its own. This is the simple-sub style "if in
  doubt, synthesize and subtype".
- **Direct CHECK rules** exist where bidirectional checking yields
  meaningfully better types — table literals, function literals, calls of
  generic functions, match expressions, the `or`-as-default idiom.

### 2.2 Why bidirectional

The set-theoretic lattice gives rich inferred types but coalescing every
binding into a user-readable form would be expensive. CHECK mode pushes
expected types inward so that intermediate constructions never accumulate
constraints they don't need (e.g. a table literal CHECKed against a known
record never has to invent a fresh row variable). This is the same payoff
bidirectional typing buys in Dunfield-Krishnaswami systems; it is independent
of the inference algorithm underneath.

## 3. Per-node constraint generation

For brevity, `S` = current solver (`V.new_solver()` instance), `E` =
environment frame, `expected` = the CHECK target.

### 3.1 Literals and primitives

- `nil` literal — synthesize `V.prim("nil")` (or `V.literal("nil", nil)` to
  preserve the singleton).
- Boolean literal — synthesize `V.literal("boolean", v)`.
- Number literal — synthesize `V.literal("integer", v)` if value is an
  integer, else `V.literal("number", v)`.
- String literal — synthesize `V.literal("string", v)`.

CHECK collapses to synthesize + `V.constrain(S, synth, expected)`.

### 3.2 Identifier

- SYNTHESIZE — look up the binding's current view (narrowed type if inside
  a narrowing scope, else its declared/inferred type). If polymorphic, the
  binding's type is a `V.forall(...)`; do **not** instantiate at the
  reference itself (only at the call site or at an explicit annotation).
  Identifiers used in a non-call position with a polymorphic binding flow
  the forall itself.
- CHECK — synthesize then constrain.

### 3.3 Vararg expression

The enclosing function's vararg type is bound in `E` as a special name
(`...`); SYNTHESIZE looks it up. In tuple-return position (last expression
of a call argument list, return statement, table constructor), the vararg
flows spread; otherwise it is treated as its first element type.

### 3.4 Unary

- `-x` — emit `synth(x) <: V.prim("number")`; result is `V.prim("number")`
  (or the more precise primitive subtype if the operand is `integer`).
- `not x` — result is `V.prim("boolean")` (or the literal `true` / `false`
  if the operand's type is provably nil/non-nil).
- `#x` — emit `synth(x) <: V.union({ V.prim("string"), <some record> })`.
  Result is `V.prim("integer")`.

### 3.5 Binary

- Arithmetic (`+ - * / % ^ // .. negation`) — emit subtype constraints on
  each operand against the operator's expected input type; result is the
  output type. Use the `__add`/`__concat` metatable hooks as part of the
  expected type only when a non-`number`/non-`string` LHS is known.
- Comparison (`== ~= < <= > >=`) — synthesize `V.prim("boolean")`.
- Logical `and` / `or` — bidirectional: `a and b` synthesizes
  `V.union({ truthy(synth(a)) & synth(b), falsy(synth(a)) })` where
  `truthy(T) = T & ~nil & ~false_literal` and `falsy(T) = T & (nil | false)`.
  `or` is dual.

### 3.6 Indexed access (FIELD_EXPR, INDEX_EXPR)

Synthesize as `V.index(synth(target), key_type)` where `key_type` is the
literal type for `t.k` (a `V.literal("string", "k")`) or the synthesized type
for the bracket expression. v4 returns `(type, nil)` or `(nil, errmsg)`;
errmsg becomes a diagnostic at the access site. CHECK reduces to
`V.constrain(S, V.index(...), expected)`.

### 3.7 Call expressions

For `f(a1, ..., an)`:

1. Synthesize `Tf = synth(f)`.
2. If `Tf` is a `V.forall(...)`, instantiate via `V.instantiate(Tf)` —
   instantiation is rank-1 at the call site. (Higher-rank arguments are
   handled by §6.)
3. Synthesize each `ai`; collect as `arg_types`.
4. Fresh return variable `α = V.var("ret")`.
5. Construct an expected callee shape:
   `expected_fn = V.fn(arg_types, α, current_effect_context)`.
6. Emit `V.constrain(S, Tf, expected_fn)`.
7. Synthesized type of the call is `α`.

For CHECK mode on a call, use `expected` for the return slot directly rather
than allocating a fresh variable.

Special calls (`require`, `error`, `pcall`, `setmetatable`, `pairs`, `ipairs`,
type predicates) follow §9, §10, §5 respectively.

### 3.8 Method call

`obj:m(args)` rewrites to `(synth(obj).m)(obj, args...)`. Treat as a
field-access + call with an extra leading argument.

### 3.9 Function literal (FUNC_EXPR / FUNC_DECL body)

- If a function-type annotation is attached (preceding-line `--:` form):
  - If the annotation is a `V.forall`, skolemize via `V.skolemize` to get a
    rigid body and a skolem list. Bind each param name to the skolemized
    param type. CHECK the body against the skolemized return type. Run the
    standard escape check after the body (every reachable skolem must be
    confined to the body's resulting type).
  - If the annotation is a plain `V.fn`, bind params to the annotated
    param types and CHECK body against annotated return.
  - Result type is the annotated function type (the user wrote it).
- If unannotated:
  - Allocate fresh `V.var()` per parameter.
  - SYNTHESIZE the body in a new function-scope frame; collect any return
    statement contributions into a fresh return var.
  - Result type is `V.fn(param_vars, ret_var, inferred_effects)`. No
    implicit let-generalization: §6.

### 3.10 Table literal

CHECK against a `V.rec(...)`:
- For each named field present in expected, CHECK the corresponding
  field-init against the expected field type.
- For positional slots (tuple form), CHECK against the expected positional
  slot type.
- If expected has an indexer, CHECK extra fields' values against the
  indexer's value type; extra keys must be subtypes of the indexer key.
- If expected is closed and the literal has extra fields, the closedness
  rule fires (constrain emits an error).

SYNTHESIZE:
- Synthesize each value; build `V.rec({ k1 = T1, ... }, /*open*/ false)`.
- If any keys are non-constant expressions, fold those into an `indexer`
  by joining their inferred key/value types.

### 3.11 Assignment / local statements

- LOCAL_STMT — for each `(name, ann_opt, init_opt)`:
  - If `ann_opt` and `init_opt`: CHECK `init` against `ann`. Bind name to
    `ann`.
  - If `ann_opt` only: bind name to `ann` (use site CHECKs against it; the
    body of the function will later assign).
  - If `init_opt` only: bind name to `synth(init)`. Widen literal types
    on mutable bindings unless `<const>` attribute is present.
  - Neither: bind name to a fresh `V.var()`.
- ASSIGN_STMT — for each lhs/rhs pair, emit `synth(rhs) <: typeof(lhs)`.
  Module-pattern assignments to a top-level table (`function M.foo() end`,
  `M.x = ...`) are tracked as an open accumulation on `M`'s record type
  (the field-add discipline used by simple-sub for record-row inference,
  inverted: we add lower-bound fields to the record's variable).

### 3.12 Control flow statements

- IF_STMT — see §5.
- WHILE_STMT — narrow the loop body by the condition's positive narrowing;
  after the loop, the negative narrowing applies.
- REPEAT_STMT — the body executes once with no narrowing; the test
  narrows whatever follows the loop.
- FOR_NUM — bind loop var to `V.prim("integer")` if init/stop/step are
  all integers, else `V.prim("number")`.
- FOR_IN — emit `V.constrain(S, synth(iter), <iterator shape>)` where
  the iterator shape is the standard `( -> (K?, V?) )` produced by
  `pairs`/`ipairs`/custom iterator returns. Destructure into loop names.
- RETURN_STMT — emit `V.constrain(S, synth(each expr), enclosing_return)`.
  Multi-return packs into the enclosing function's return tuple.

### 3.13 Cast expressions

- `--[[: T]] expr` (checked): emit `V.constrain(S, synth(expr), T)`.
  Synthesized type of the cast expression is `T`.
- `--[[:! T]] expr` (overlap-checked force): emit
  `V.empty.is_empty(V.inter({ synth(expr), T }))` and reject if empty.
  Otherwise the cast's synthesized type is `T`. The force form is the
  "almost never correct" escape hatch per CLAUDE.md.

## 4. Scope and environment

The walker threads an `E` (environment) record through every visit:

```
E = {
  bindings  : map[name -> V4Type],         -- in scope, untenarrowed
  narrowed  : map[name -> V4Type],         -- in-scope narrowing overlay
  return_ty : V4Type | nil,                -- enclosing function's return slot
  vararg    : V4Type | nil,                -- enclosing function's vararg type
  effects   : EffectSet,                   -- accrued effects in current fn body
  module    : V4Var | nil,                 -- the `local M = {}` being built, if any
  expected  : V4Type | nil,                -- current CHECK target (only on expressions)
  source    : { file, pool },              -- for diagnostics
}
```

`E` is **functional-with-overlays**: entering a new scope (block, function,
narrowing frame) produces a child `E'` that delegates lookups to its parent
but records new bindings in its own map. Exiting reverts to the parent. The
narrowing overlay is consulted before `bindings`; on overlay miss, the
underlying binding's full type is used.

Function entry pushes a fresh `return_ty`/`vararg`/`effects`/`module`
frame. Function exit pops it.

## 5. Narrowing

Narrowing is the central use of v4's complement `V.neg`. A guard expression
produces (a) an atom `A` and (b) a polarity. The truthy branch overlays
`E.narrowed[x] := V.inter({ E.lookup(x), A })` for the narrowed variable
`x`; the falsy branch overlays with `V.inter({ E.lookup(x), V.neg(A) })`.

Guard form → atom `A` mapping (mirrors `typechecker-reference.md`):

| Guard                              | Var | Atom                              |
|------------------------------------|-----|-----------------------------------|
| `if x then`                        | x   | `V.inter({V.neg(nil_), V.neg(false_lit)})` |
| `if x ~= nil`                      | x   | `V.neg(V.prim("nil"))`            |
| `if type(x) == "string"`           | x   | `V.prim("string")`                |
| `if x == "GET"`                    | x   | `V.literal("string", "GET")`      |
| `if x.tag == "leaf"`               | x   | `V.rec({tag=V.literal("string","leaf")}, true)` |
| `if is_T(x)` (predicate annotated `(x: unknown) -> x is T`) | x | `T` |

Composite forms:
- `if a and b` — overlay accumulates `A_a ∩ A_b` on both vars.
- `if a or b` — truthy branch overlays the union; falsy branch overlays
  the intersection of complements.
- `if not p` — swap the truthy/falsy mappings.

### 5.1 Where the atoms come from

For type-test predicates, the atom is `V.prim(name)`. For literal-equality
checks, `V.literal(...)`. For discriminated-record narrowing, a singleton
open record `V.rec({k = lit}, true)`. The walker recognizes these guard
shapes syntactically before producing constraints; no extra solver
primitive is needed.

### 5.2 Join at the branch end

When two branches reconverge (end of `if/elseif/else`), each variable's
post-branch type is the union of its overlay types from each branch (via
`V.union`). Variables narrowed in only one branch revert to the
pre-branch type in the other.

### 5.3 Early-exit avoidance

If a branch terminates with `return`/`error`/`break`, it contributes
nothing to the join. The walker tracks "branch terminates" as a bool
returned from statement walking.

### 5.4 Re-emission discipline (the "open problem" in type-system.md)

Constraints emitted *inside* a narrowed scope must reference the **narrowed
view** of the variable, not the underlying binding. The walker consults
`E.narrowed[name]` first when synthesizing an identifier reference, so any
downstream constraint sees the intersected type. This is the explicit form
of the §"Type narrowing" open problem's resolution: a single pre-solve
walker pass that already operates on flow-typed views.

## 6. Function definitions and rank-N

Generic function declarations (`<T>(...)`) are surface annotations. The
walker turns them into `V.forall(names, body_fn)` types where `body_fn`
receives v4 bound vars and constructs the body using them.

### 6.1 Skolemization at body entry

When a function literal's annotation is a `V.forall`, the body is checked
under `V.skolemize(forall) -> (body_ty, skolems)`. The skolems are rigid
opaque atoms; param/return types within `body_ty` reference them. The body
walker binds parameter names to slots of `body_ty`. After the body, run
the standard escape check (already in v4 via `forall.find_escape`).

### 6.2 Instantiation at use sites

At a call expression whose callee synthesizes to a `V.forall`,
`V.instantiate` produces a body with fresh inference variables. The call
constraint then drives those fresh vars to their solved bounds.

### 6.3 No implicit let-generalization

`local f = function(x) return x end` does **not** introduce a forall.
`f`'s type is `V.fn({α}, α)` with `α` a free inference variable. Polymorphism
is opted into by explicit `<T>` annotation. This matches the design doc §6
commitment and avoids the value-restriction-like surprises that bite
ML-style let generalization in the presence of mutability.

### 6.4 Bounds

Annotation `<T: Bound>` constructs a forall whose body emits
`V.constrain(S, var, Bound)` at instantiation/skolemization time. This is
expressed by including the bound constraint inside the body via a
synthetic `local _ --: Bound = T_var`-equivalent inserted at body entry.

## 7. Match expressions

The Lua-surface form is `--:: T = match X { P => R, _ => R' }` for a
type-level alias, and there is no value-level `match` statement in current
crescent surface (per `typechecker-reference.md`). The walker therefore
emits match-type expressions only in two places:

- **Type-alias declarations** with `match` on the right-hand side. The
  walker parses arm patterns/results via the annotation parser, builds
  `V.arm(pattern, result, captures)` for each arm, and applies `V.match`
  to the scrutinee.
- **Type-level expressions inside annotations** (anywhere a type is
  expected). Same construction.

### 7.1 Capture sigils

Pattern captures `%X` are surface syntax for "introduce a fresh capture
var named `X` that is shared between pattern and result." The walker
allocates `cap_X = V.var("X")` once per match expression, weaves the same
handle into both pattern and result, and passes `{cap_X, ...}` as the
arm's captures list.

### 7.2 Wildcard `_`

The walker desugars `_ => R` to "all arms but this contribute their
pattern union; wildcard is `V.neg(V.union(other_patterns))`". This is
literally what v4's `match.lua` already wires; the walker constructs the
arm list and passes `wildcard_result` separately to `V.match`.

### 7.3 Backward direction

`V.match_backward` is used during constraint generation when an expected
result is known but the subject must be derived (e.g. inferring the
argument type that satisfies `match Arg { P => Expected }`). Walker
invokes it inside `Index`-into-match patterns and inside generic alias
instantiation when an expected return type is known.

## 8. Indexed access, varargs, multi-return

### 8.1 Indexed access

`obj[key]` and `obj.k` both reduce to `V.index(target_ty, key_ty)`. v4's
indexer handles distribution over unions, μ unfolding, indexer-typed
records, and closed/open record rules. Walker passes through; failures
become diagnostics.

### 8.2 Varargs

Inside a function, `...` is bound in `E.vararg` to a `V4Type` that is the
spread of all unconsumed parameters past the formal arity. For
`function(a, ...)` the vararg is `V.var("vararg")` unless annotated
(`function(a, ...) --: (T, ...U) -> R`) in which case it is the spread
element type.

In return-position or call-argument tail-position, vararg flows as a
spread into the receiving tuple. In any other position, it collapses to
its element type (single value).

### 8.3 Multi-return

A function returning multiple values has return type
`V.rec({}, /*open*/ false, /*positional slots*/)` — the tuple
representation per `typechecker-reference.md` "brace-tuple positional
slots." `return a, b, c` constructs `V.rec({[1]=Ta, [2]=Tb, [3]=Tc}, false)`
and constrains it against `E.return_ty`. Single-return collapses to a
plain type when arity is exactly one.

Assignment LHS-multi (`local a, b = f()`) destructures: each LHS slot
gets `V.index(call_ret, V.literal("integer", i))`.

## 9. FFI cdef integration

`ffi.cdef[[ ... ]]` is recognized by the walker via a call-site shape match:
callee is `ffi.cdef` (an identifier chain), single string-literal argument.
The walker invokes the cdef parser (`lib/type/static/cdecl_parse.lua` plus
`cdef.lua`) on the string content; the parser yields a list of
`(name, c_type)` declarations.

Each declaration is translated to a v4 type:
- C primitives → `V.prim(...)` (with crescent's int/uint/float lattice).
- C pointer `T*` → record `{ [0]: <T's v4 type>, ... }` per
  `typechecker-reference.md` `Ptr<T>`.
- C struct → closed `V.rec`.
- C function pointer → `V.fn(...)` with a `cdata` effective receiver.

The translated declarations are registered into the `$FfiC` intrinsic
table (a closed record bound to `ffi.C` in the prelude environment).
Subsequent `ffi.C.foo(...)` accesses are ordinary field-access on the
prelude binding.

The cdef parser exists today; the walker's contribution is the call-site
recognition and the type-translation table. This is **not** architectural
typechecker work — it's a parser-driven environment-population pass.

## 10. Effects: yield, throw

The walker maintains `E.effects` as it walks a function body; on function
exit, the accumulated set populates the `effects` arg of the
`V.fn(params, ret, effects)` constructor.

### 10.1 Yield

A call to `coroutine.yield(...)` adds `"yield"` to `E.effects`. The
function literal containing it synthesizes to a `V.fn(..., effects = {yield})`.
The argument type of `yield` and the return type of the enclosing
`coroutine.wrap`/`resume` are linked via a dedicated coroutine type schema
(out of scope for the walker proper — the schema lives in the prelude).

### 10.2 Throw

A call to `error(...)` adds `"throw"` to `E.effects`. The expression's
result type is `V.bot()` (never) since the call does not return.

### 10.3 pcall

`pcall(f, ...)` calls `f` in a throw-consuming context. The walker
synthesizes `pcall`'s return as `V.match`-style:
`match typeof(f) { (...P) -> R => (true, ...R) | (false, string) }`,
exactly the `PcallReturn<F>` schema in `typechecker-reference.md`. The
inner-call effect set is masked: `throw` is consumed and removed from the
outer function's `E.effects` contribution.

### 10.4 Effect subtyping

v4 handles effect subtyping covariantly via the function-arrow subtype
rule (`e1 ⊆ e2`). The walker emits no special constraints; effects ride
on the arrows and v4 propagates.

## 11. Cross-file resolution

`require("path")` is recognized as a call-site shape match: identifier
`require` (in scope from the prelude), single string-literal argument.

### 11.1 Cache lookup

1. Resolve `path` to a source file via crescent's module resolution rules.
2. Hash the source content (SHA-256 via `V.content_hash`).
3. Call `V.cache_lookup(io_caps, cache_dir, source_hash)`.
4. On hit: `V.deserialize(bytes)` yields the cached export type. Bind it
   to the call-expression's synthesized result.
5. On miss: recursively typecheck the imported file. The result is the
   cached export type. `V.cache_store(io_caps, cache_dir, source_hash,
   type, deps)` writes it.

### 11.2 Deps tracking

Each typecheck records every transitively-required file's source hash in
the manifest, so a downstream change invalidates importers automatically.
The walker maintains a "deps accumulator" per top-level file walk; on
finish, the accumulator is passed to `cache_store`.

### 11.3 Recursion

If `require` is called from inside an in-progress typecheck of the same
file (cycle), bind the result to a placeholder `V.var` and resolve when
the cycle completes. Genuine module-level cycles (mutual import) are
rejected with a diagnostic; lazy/late `require` calls inside function
bodies break the cycle by deferring lookup to invocation time.

### 11.4 I/O capabilities

The walker is constructed with an `io_caps` parameter (read_file,
write_file, mkdir, file_exists) — passed through to `cache_lookup` /
`cache_store`. Per CLAUDE.md, never default to globals; if `io_caps` is
absent, the walker errors loudly.

## 12. Diagnostic positions

Every AST node carries `line`/`col`/`file` (parse.lua arena slot). The
walker maintains a `position_stack`: each visit pushes the current node's
position; each emitted constraint is annotated by the solver's accumulated
"current source position" side-channel.

v4 itself does **not** store source positions in types (per
`type-system.md` Principle 13: "source locations do not belong in the type
system"). The walker maintains positions in a parallel structure: an
`origin_map` from `(constraint id)` to `(file, line, col, ast_node_id)`.
On constraint failure (returned via solver error state), the walker
re-maps the failure id to a position for diagnostic emission.

For multi-step inferences (a constraint failure rooted in a chain of
prior constraints), the walker's diagnostic layer uses the origin chain
to construct a "root cause" report — surfacing the originating expression
rather than the bottom-of-the-chain failure. This is the explicit shape
of `bin/cr check --summary`.

## 13. Sub-phase breakdown

The walker is decomposed into 10 sub-phases, each independently
dispatchable. Dependencies (`<=`) and parallel-eligible markers are
called out.

**Phase A — Scaffolding** (no dependencies)
Deliverable: `walker.lua` skeleton with the visitor table, the `E`
environment record, scope push/pop, mode dispatch (CHECK vs SYNTHESIZE),
and a stub for every NODE_* kind. No constraints emitted yet. Tests
ensure traversal hits every node kind exactly once on a small program.

**Phase B — Literals, identifiers, varargs** (<= A)
Deliverable: SYNTHESIZE for NODE_LITERAL, NODE_IDENTIFIER, NODE_VARARG_EXPR.
Tests cover all primitive/literal types, identifier lookup, vararg in tail
and non-tail positions.

**Phase C — Annotations and casts** (<= B; parallel with D)
Deliverable: integration with `ann.lua` parser; NODE_CAST_EXPR handling
(both `--[[: T]]` and `--[[:! T]]` via emptiness); `--:` on local stmts.
The annotation-to-V4Type translator. Tests cover every annotation form in
`typechecker-reference.md` §"Annotation syntax".

**Phase D — Expressions, calls, indexing** (<= B; parallel with C)
Deliverable: SYNTHESIZE/CHECK for NODE_UNARY_EXPR, NODE_BINARY_EXPR,
NODE_FIELD_EXPR, NODE_INDEX_EXPR (using `V.index`), NODE_CALL_EXPR,
NODE_METHOD_CALL, NODE_TABLE_EXPR, NODE_TABLE_FIELD. Includes basic
function-call constraint generation (no generics yet — those land in F).

**Phase E — Statements and control flow scaffolding** (<= D)
Deliverable: NODE_LOCAL_STMT, NODE_ASSIGN_STMT, NODE_EXPR_STMT,
NODE_RETURN_STMT, NODE_DO_STMT, NODE_BREAK_STMT, NODE_GOTO_STMT,
NODE_LABEL_STMT, NODE_FUNC_DECL (non-generic), NODE_FUNC_EXPR
(non-generic), NODE_FOR_NUM, NODE_FOR_IN, NODE_WHILE_STMT,
NODE_REPEAT_STMT. No narrowing yet — `if` is a stub.

**Phase F — Narrowing** (<= E)
Deliverable: NODE_IF_STMT, NODE_IF_CLAUSE, guard-form recognition,
intersection/complement overlays via `V.inter`/`V.neg`, branch-join via
`V.union`, early-exit tracking. Every guard form from
`typechecker-reference.md` §"Narrowing forms" tested.

**Phase G — Rank-N: forall annotations** (<= E; parallel with F)
Deliverable: forall in function annotations, skolemization at body entry
via `V.skolemize`, escape check via the v4 mechanism, instantiation at
call sites via `V.instantiate`. Type predicates (`x is T`) and assertion
functions land here as they require forall-shaped types.

**Phase H — Match types** (<= C, G)
Deliverable: annotation-side parsing of `match X { P => R, _ => R }`,
capture sigil handling, wildcard desugaring, integration with
`V.match`/`V.match_backward`. Type-level only (no value-level match in
crescent surface).

**Phase I — FFI cdef** (<= D; parallel with F/G/H)
Deliverable: call-site recognition for `ffi.cdef`, cdef parser invocation,
C-type-to-v4-type translation table, `$FfiC` prelude population. The
existing `cdef.lua` / `cdecl_parse.lua` are reused unchanged.

**Phase J — Effects + cross-file + diagnostics** (<= F, G, H, I)
Deliverable: `coroutine.yield`/`error`/`pcall` effect plumbing into
`V.fn`'s effects slot; `require` cache integration via `V.cache_lookup`
and `V.cache_store`; the origin map and root-cause diagnostic
layer. This phase ties the walker to the user-facing CLI (`bin/cr check`)
and is the integration phase — everything must work end-to-end.

Phases C and D can proceed in parallel after B. Phases F and G can
proceed in parallel after E. Phase I can proceed any time after D. Phase
H requires both C (annotations parse match syntax) and G (forall is
present in v4-bridge layer). Phase J is the integration phase and runs
last.

## 14. Open questions

These are genuinely unresolved from the canonical docs alone:

1. **Module-pattern accumulation semantics.** `local M = {}; function M.foo(...)`
   — is `M` typed as a record with a *lower bound* growing across the file, or
   as an *open record* whose closedness is fixed at `return M`? The v4
   constructor `V.rec` takes a closedness boolean at construction; growing a
   record post-hoc requires either a variable-bound accumulation (lower bounds
   contributing fields) or mutation (which v4 does not support on rec nodes).
   The principled answer is likely "bind `M` to a `V.var`, accumulate
   contributing record types as lower bounds, freeze at scope exit," but this
   needs a worked example to confirm v4 handles it.

2. **Multi-return and the tuple representation.** `typechecker-reference.md`
   describes brace-tuple positional slots (`{ A, B, C }`) as the multi-return
   form. v4's `V.rec` allows arbitrary field names, including integer keys.
   But the AST `return a, b` does not produce a node tagged "tuple" — it
   produces a list. The walker must construct the tuple-record on the fly.
   Confirming v4's `V.rec` with integer-keyed fields participates correctly
   in subtype against an annotated `(A, B, C)` return type is a small
   round-trip test that this design assumes works but hasn't verified.

3. **Effect inference inside a forall body.** When a generic function body
   contains `coroutine.yield`, does the resulting type quantify over the
   effect set (it can't — design §3.1 says no effect polymorphism) or
   commit to the concrete effect at the forall? The answer is "commit to
   the concrete effect," but the walker still must decide whether to
   propagate effects observed during skolemized body checking back into the
   forall's body arrow. Almost certainly yes, but the v4 docs do not
   explicitly cover effect attribution under skolemization.

4. **Where do annotations on `function(x --:: T)` go?** The reference notes
   that inline param annotations are unsupported syntax. The walker only
   needs to handle preceding-line function-type annotations. Confirming
   no surface form requires per-param inline annotation is a one-grep
   verification this design assumes was done.

   **Inline param annotations — verified (2026-05-20).** `typechecker-reference.md`
   §"Annotation syntax" states: *"To annotate params: use preceding-line
   function type (only supported form). WARNING: `function(x --: string)` is
   INVALID — `--` starts a line comment, eating `)` and beyond. WARNING:
   `function(x --[[: string]])` is also INVALID — block comment form is
   parsed as a cast, not a param annotation; silently ignored in param
   position."* Grep of `lib/` finds zero inline-param-annotation call sites
   (`function.*\(.*--:`); every annotated function uses preceding-line `--:
   (...) -> ...` or trailing same-line `--: (...) -> ...` attached to a
   `local function f()` or `function() ... end` expression. Repros confirm:
   (A) `function f(x --: string, y --: integer)` is a Lua parse error
   (`expected ')', got 'return'`) because `--:` is a line comment; (B)
   preceding-line `--: (string, integer) -> string` typechecks cleanly and
   enforces argument types (mismatched call rejected with `cannot pass
   integer where string expected`); (C) block-comment form `function(x
   --[[: string]], y --[[: integer]])` parses but the typechecker emits a
   `no signature` warning — the block comments are silently ignored, exactly
   as the reference warns. **Walker action:** parse only preceding-line and
   trailing same-line `--:` function-type annotations on `local function`,
   `function NAME`, and `M.x = function(...)` forms. Param names come from
   the AST function-def node; param *types* come from positionally zipping
   the annotation's arrow-arg list against those names. Do not attempt to
   recognize inline `(x --: T)` — it can never reach the walker (Lua parser
   rejects it first). Do not attempt to recognize `(x --[[: T]])` as a param
   annotation; the cast-syntax form is reserved for value casts and treating
   it as a param annotation would silently change semantics for any caller
   who wrote one expecting the existing (ignored) behavior. If the user
   writes one, the existing `no signature` warning is the correct
   diagnostic.

5. **Generic `typeof` resolution order.** `(a: typeof b, b: typeof a)` —
   the design doc says union-find equivalence. v4 has no union-find — it
   uses MLstruct bound graphs. The walker must implement `typeof` by
   pre-binding param names as `V.var()`s before resolving annotations, and
   wiring `typeof b` to *be* the same var. This works but requires the
   walker to traverse param annotations in two passes (declare-all, then
   resolve-each).

6. **Module re-export through `$Require`.** The `$Require<T>` intrinsic in
   `typechecker-reference.md` §"Permanent intrinsics" hints at literal-type
   propagation through generics. With v4's indexed access, a `require`
   could be modeled as `V.index(module_table, V.literal("string", "path"))`,
   sidestepping `$Require` entirely. Whether to retain `$Require` as a
   named intrinsic or remove it in favor of indexed-access is a design
   choice the rewrite-design §9.2.5 footnotes but does not resolve.

7. **Diagnostic root-cause grouping algorithm.** Section 12 mentions an
   "origin chain" used by `bin/cr check --summary`. The exact grouping
   discipline (what makes two errors share a root cause?) is not specified
   in any read source; design needed before Phase J. See "Root-cause error
   grouping (`--summary`)" below — audit of the existing implementation
   resolves what the walker must emit.

## Root-cause error grouping (`--summary`)

Audit of the current implementation, conducted to determine what the v4 AST
walker must emit so the `--summary` mode is reproducible (or what should be
replaced). Sources read: `lib/type/static/cli.lua` lines 610-870 (the entire
`-- ── Summary mode ──` section), the dispatch at line 902 (`--summary`
flag), and the per-file accumulation at lines 1107, 1145-1146, 1197-1198.
The mode is **not** documented in `docs/typechecker-reference.md`.

### What `--summary` does

It re-formats the same per-error list that the normal printer emits, but
collapses it into:

1. A total error count per file.
2. A "Root causes" section listing **unresolved `require()` calls** and the
   number of `unknown`-cascade errors attributed to each.
3. A "Remaining" section bucketing every non-cascade error by a coarse label
   (`type mismatch / assignment`, `field doesn't exist`, `call / overload
   mismatch`, `operator on wrong type`, `missing required argument`,
   `unknown identifier`, `other`).
4. An "Unresolved requires (no cascade errors attributed)" section listing
   unresolved modules that had no `unknown`-cascade errors blamed on them
   (so the user still sees them as suspect root causes).

Example. The file `/tmp/cascade_big.lua` (5 lines accessing a missing
require, plus one unrelated return-type mismatch) produces:

Default printer (4 separate, equal-weight errors):

```
/tmp/cascade_big.lua:3:14: error: value of type `unknown` must be narrowed before indexing
/tmp/cascade_big.lua:4:14: error: value of type `unknown` must be narrowed before indexing
/tmp/cascade_big.lua:5:14: error: value of type `unknown` must be narrowed before indexing
/tmp/cascade_big.lua:11:3: error: return type mismatch: cannot return `42`: ...
Checked 1 file(s): 4 error(s), 0 warning(s)
```

`--summary` (root-cause-grouped):

```
/tmp/cascade_big.lua: 4 errors
  Root causes:
    require("nonexistent.mod") → unknown (module not found): 3 downstream errors
  Remaining (no cascade root):
      1  type mismatch / assignment
```

The user immediately sees that 3 of the 4 errors are caused by one missing
module, and that there is exactly one independent error to investigate.

### The existing grouping mechanism

**Verdict: ad-hoc.** The grouping is not derived from any structured
metadata attached to errors. It is a post-hoc heuristic computed at output
time by `print_summary` (cli.lua:673) over the same flat `err_ctx.errors`
list the default printer consumes. Concretely:

- **Bucket labels** are assigned by `bucket_label(msg)` (cli.lua:642-668) by
  `string.find` substring-matching the rendered error message text:
  `"of type \`unknown\`"`, `"doesn't exist"`, `"cannot call"`, `"cannot
  perform arithmetic"`, etc. The taxonomy lives entirely in this function
  as a hand-written if/elseif chain.
- **Unresolved requires** are discovered by **re-reading the source file
  from disk** (cli.lua:696-697), running a regex
  (`require%s*%(%s*["']([^"']+)["']%s*%)`) over a comment-stripped copy
  (cli.lua:633), and probing the filesystem with `io.open` to decide
  whether each module resolves (`resolve_mod_path`, cli.lua:614-625). The
  typechecker's own module-resolution state is not consulted; the summary
  re-derives it from scratch.
- **Cascade attribution** (which `unknown` error belongs to which missing
  require) is a **source-line proximity heuristic** (cli.lua:749-805):
  scan the source line-by-line for `require(...)` calls, record their line
  numbers, then for each `unknown`-cascade error, attribute it to whichever
  unresolved require's line number most recently precedes the error's
  line. There is no dataflow link from the error's offending value back to
  the require expression that produced it. The single-unresolved fast path
  (cli.lua:739-740) just blames the first one unconditionally.
- **No structured fields exist on errors for any of this.** The walker
  emits `{ msg, line, ... }` records (cli.lua:672 type annotation) and the
  summary recovers everything else by string-matching `msg`.

Consequences observed during this audit:

- With two unresolved requires and cascades reachable from only one of
  them, attribution can misroute errors to whichever require's line number
  happens to be closer — see the `/tmp/cascade_demo.lua` run, where two
  cascade errors derived from `foo` (line 1) and `bar` (line 2) were both
  attributed to `bar` because of "most recent preceding require" logic
  (cli.lua:786-797). The wrongly-blamed require gets printed as
  "Unresolved requires (no cascade errors attributed)" — visible but
  misclassified.
- Localised error rephrasing changes the bucket. If `errors.lua` ever
  rewrites `"cannot perform arithmetic"` to `"arithmetic operator
  requires"`, the `operator on wrong type` bucket silently goes empty and
  every such error reclassifies as `other`. The taxonomy is coupled to
  message wording by string equality of substrings.
- The summary cannot represent transitive cascades (error B caused by
  error A which is itself a cascade) because errors carry no parent
  pointer. Only the top-level "unresolved require → unknown" link is
  modelled, and only by source-position proximity.

### What the v4 walker must emit per error

To make the same grouping reproducible **without re-parsing the source and
without substring-matching messages**, each diagnostic emitted by the
walker should carry structured fields:

1. **`code`** — a stable machine identifier for the error class (e.g.
   `E_UNKNOWN_NOT_NARROWED`, `E_FIELD_MISSING`, `E_ASSIGN_MISMATCH`,
   `E_CALL_ARITY`, `E_CALL_NO_OVERLOAD`, `E_OP_TYPE`, `E_ARG_MISSING`,
   `E_IDENT_UNKNOWN`, `E_REQUIRE_UNRESOLVED`). This replaces
   `bucket_label`'s substring matching with direct lookup. The taxonomy
   becomes data, not parser logic.
2. **`pos`** — source span (start/end line+col) of the offending node, not
   just `line`. The current `line`-only field is what forces the
   proximity heuristic; with an exact span, a cascade error can point at
   the *variable* whose unknown type was indexed, which is a real symbol
   the walker already knows about.
3. **`origin`** — a structured reference to the producing diagnostic or
   producing node, when one exists. For `E_UNKNOWN_NOT_NARROWED`, this is
   the upstream node (or upstream diagnostic ID) that *gave* the value its
   `unknown` type — typically the `require()` call whose target failed to
   resolve, or the `--: unknown` annotation site, or the variable
   declaration that inherited `unknown` from an unresolved import. The
   walker has this information at the point of failure (it constructed
   the `unknown` type variable); persisting it onto the diagnostic
   replaces the proximity heuristic with a real edge.
4. **`origin_kind`** — discriminant on `origin` so the summary printer
   can group: `require_unresolved`, `annotation_unknown`,
   `propagated_unknown`, `no_origin`. With this, the "unresolved require
   → N downstream errors" line becomes a direct group-by on
   `origin_kind == require_unresolved`, no source re-parse needed.
5. **`module`** — for `E_REQUIRE_UNRESOLVED` specifically, the literal
   module name string. The walker knows this; storing it removes the
   regex scan over source.
6. **`severity`** — already implicit; keep as a first-class field so
   future modes (e.g. "warnings only") don't add another substring
   matcher.

With (1)-(5) the entire 200-line summary implementation collapses to a
`group_by(code, origin_kind, origin)` over the diagnostics list, plus a
join from `E_REQUIRE_UNRESOLVED` diagnostics to the `unknown`-cascade
diagnostics whose `origin` points at them. No source re-read. No regex.
No "most recent preceding require" heuristic. Attribution is exact
because the walker recorded the actual dataflow edge.

### Recommendation

**Do not preserve the existing grouping verbatim.** The current
implementation is a self-contained post-processor over rendered messages
and re-parsed source; reproducing it in v4 would mean carrying forward
the misattribution bugs above and freezing the bucket taxonomy to the
exact wording of v3's error strings.

Instead: in v4 the walker emits diagnostics with the structured fields
above (`code`, `pos`, `origin`, `origin_kind`, `module`). The `--summary`
printer becomes a thin transform that group-bys on those fields. The
existing v3 output format (the textual layout — "Root causes:" /
"Remaining:" / "Unresolved requires:" headings) is fine to keep as the
default presentation; only the data path underneath changes.

This shifts root-cause discipline from a fragile output-time heuristic
into a walker invariant: **every diagnostic whose `code` indicates
"derived from an `unknown`" must carry an `origin` pointing at the
producing diagnostic or producing node, or the walker has a bug.** Phase
J becomes a checklist of "for each error site that constructs an
`unknown`-propagation diagnostic, what is its `origin`?" — a question
with a finite, enumerable set of answers, not an open-ended heuristic.

The v3 implementation should remain unchanged until v4 ships a
replacement; it works well enough on the common single-unresolved-require
case and we have no second consumer to break.

## Multi-return audit findings

Audit performed 2026-05-20 against `lib/type/static/` (the existing
solve+constrain implementation). Goal: decide whether the v4 AST walker
should mirror the existing multi-return story or design fresh.

### 1. Existing representation

Multi-return is represented as a **`TAG_TUPLE`** of slot type IDs. Three
sites synthesise the tuple:

- `constrain.lua:4380-4396` (`NODE_RETURN_STMT`): when `#ret_tids > 1`,
  packs the per-expression types into `types_mod.make_tuple(ctx, ret_tids)`
  and emits a single `C_RETURN(tuple, ret_var)`. Single returns stay
  scalar.
- `constrain.lua:2257-2282` (annotated function body push): when an
  annotation declares `() -> (A, B, C)`, the body's `ret_var` is bound to
  `TAG_TUPLE(A, B, C)` so the body's return is checked slot-wise.
- `constrain.lua:2366-2371` (call return assembly for unannotated callee):
  multiple return slots are collected into a `TAG_TUPLE` so `C_INDEX` can
  project per-slot at the call site.

In addition, `TAG_SPREAD` is used in two related roles: (a) `...(T)` in an
annotated return position (`solve.lua:2743-2749` unwraps it); (b)
`(true, ...R)` splice in `match`-typed result expressions.

### 2. Subtyping / assignment rules

- **`C_RETURN` against an annotated tuple** (`solve.lua:2724-2772`):
  - If actual is `TAG_TUPLE` and expected is `TAG_TUPLE`: unify directly.
  - If actual is *not* tuple but expected is `TAG_TUPLE`: take slot 0 of
    expected and unify against the scalar actual. This is the "only the
    first `return` expr was emitted as the C_RETURN value" path — note it
    silently ignores any annotation slots beyond slot 0.
  - If expected is `TAG_SPREAD(T)`: unwrap to `T` and unify scalar against
    `T`.

- **Multi-assign slot extraction** (`constrain.lua:3563-3719` for
  `NODE_LOCAL_STMT`, `3722-...` for `NODE_ASSIGN_STMT`):
  - Only when the *last* RHS expression is a `NODE_CALL_EXPR /
    NODE_METHOD_CALL` does slot extraction run. The `call_slot = i -
    (el - 1)` formula projects per-target via either `eager_slot` (concrete
    tuple) or `C_INDEX` (deferred).
  - Targets to the *left* of the call expression simply pick `rhs_types[i +
    1]` — the i-th RHS expression's whole type. There is **no truncation
    pass** for non-last call expressions.

- **`gen_call` arg packing**: `gen_expr_list` is called on the arg list as
  if each arg-expr produced exactly one slot. Multi-return spread of `f()`
  into call args is not implemented; tuple-typed args are matched
  positionally against single param slots, which fails.

### 3. Edge cases — what works, what doesn't

Probed via small repros under `bin/cr check`; outcomes 2026-05-20:

| # | Case | Behavior | Sound? |
|---|------|----------|--------|
| W1 | `local function f() return 1,"x" end; local a,b = f()` | `a:integer, b:string` | yes (matches `type_soundness_test.lua:1129-1146`) |
| W2 | `--: () -> (integer,string) ... return 1,"x"` annotated 2-and-2 | typechecks | yes |
| W3 | `return 1,"x",true` against `(integer,string)` | error: tuple length 3 vs 2 | yes |
| W4 | `--: () -> (integer,string)` body `return 1` (missing slot) | **accepted, 0 errors** | **NO — slot 1 should require nil ∈ string** |
| B1 | `g(f())` where `g: (integer,string)->nil`, `f: ()->(integer,string)` | rejected: "cannot pass (integer,string) where integer expected" | **NO — Lua spreads when call is last in arg list** |
| B2 | `g(f(), "y")` with `f` returning 2 values | rejected with same message | **NO — first arg should truncate to first slot** |
| B3 | `local a,b = f(), 99` with `f:()->(integer,string)` | `a` typed as full tuple `(integer,string)`, NOT truncated to integer | **NO — non-last call expr must truncate to slot 0** |
| B4 | `--: () -> ...(integer); return 1,2,3` | error: cannot assign `(1,2,3)` to integer; subsequent locals `b,c` typed as nil | **NO — `...(T)` should accept N integer returns AND give `b,c: integer`** |
| K1 | "io.open multi-return narrowing" (known gap, `type_test.lua:7045`) | comment says nil-narrowing only works on direct annotation, not multi-return | known gap |

Repros: `/tmp/mraudit/r{1..10}*.lua`.

### 4. Verdict — has-defects

The existing implementation is **partially sound**. It correctly:

- Synthesises multi-return as `TAG_TUPLE`.
- Slot-projects when call is the last RHS of a multi-local.
- Catches over-arity returns against annotation (W3).
- Handles correlated multi-return for stdlib intrinsics (`pcall`,
  `io.open`, `string.find`) via `pending_multi_return_override` and
  `peek_callee_ret_union`.

It has the following defects (in increasing order of severity):

- **D1 (soundness — W4).** A `return N` body whose annotation declares
  more than N return slots is silently accepted. `solve_return` uses
  *only slot 0* of the expected tuple when the actual is scalar
  (`solve.lua:2757-2761`). Slot 1+ are never checked. This is the precise
  failure mode the comment at `solve.lua:2754-2756` describes — and the
  comment normalises it ("only the first expression is emitted via
  C_RETURN") rather than fixing it. The constraint emitter at
  `constrain.lua:4380-4396` packs a tuple **only when `#ret_tids > 1`**,
  so `return 1` against `() -> (integer, string)` emits a scalar
  C_RETURN; solve falls into the slot-0-only branch and slot 1 (`string`)
  is never compared against the implicit `nil` that Lua would actually
  produce at runtime.
- **D2 (Lua-semantics — B1, B2).** Multi-return spread into call
  arguments is unimplemented. Per Lua, if `f` is the last expression in
  an argument list `g(..., f())`, `f`'s return values spread positionally
  to fill remaining params; if `f` is in any other position, it truncates
  to its first return. The existing code calls `gen_expr_list` which
  produces one type per arg-expr, so a tuple-typed last arg is matched
  against a single param.
- **D3 (Lua-semantics — B3).** Non-last call expressions in a multi-LHS
  binding do not truncate. The target left of the call gets the full
  tuple type, not slot 0. `NODE_LOCAL_STMT`'s loop sets `bind_tid =
  rhs_tid` (the whole `gen_expr_list` result) for non-call slots, with
  no truncation pass for any RHS expression that happens to be a call.
- **D4 (annotation expressivity — B4).** `() -> ...(T)` (spread return)
  is documented in `typechecker-reference.md:125` as "multi-return
  spread (T may be a tuple type alias)" but the implementation treats it
  as a scalar single-return `T` for body-checking (so `return 1, 2, 3`
  is rejected because the body emits a tuple actual against scalar
  expected) and does not propagate `T` to per-slot inference at the
  multi-LHS call site. The `TAG_SPREAD` unwrap in `solve_return`
  produces `T`, not "zero-or-more T", so neither end works.
- **D5 (assignment).** Excess LHS slots beyond function arity are not
  pinned in tests. Per Lua semantics they must be `nil`. The current
  code path (`NODE_LOCAL_STMT` else-branch, `bind_tid = ctx.T_NIL`)
  appears to handle the no-call-expr case but the call-expr branch
  emits `C_INDEX` with the literal slot index against the tuple, and
  the slot extraction in `solve_index` for out-of-bounds slots returns
  nil only when the tuple is concrete — for deferred (free TV) cases
  the behavior is untested and unverified by this audit.

None of the defects are silent miscompiles in the sense of allowing
genuinely wrong runtime values through. D1 is the dangerous one: it
masks missing return values. D2/D3 are *false rejections* of valid Lua
(the typechecker is too strict — sound-by-rejection). D4 is an
expressivity gap. D5 is unverified.

### 5. V4 walker recommendation — design fresh

Mirroring the existing approach inherits D1-D4. The right shape:

**Representation.** Multi-return is always a tuple `T_tup = (T_1, ...,
T_n)` carrying an explicit "spreadable" flag (or last slot tagged as
spread `...T`). Single-return is `(T_1)` — a 1-tuple, not a scalar.
This eliminates the "scalar actual vs tuple expected" special case
that produces D1.

**Subtype rule against `(A_1, ..., A_n)` annotated return.** Pad the
actual tuple with `nil` to length n (right-pad — Lua's discard-extras /
fill-missing-with-nil semantics), then unify slot-wise. Reject if
actual length > n (already caught — W3) OR if `nil </: A_i` for any
padded slot (catches D1). For `...A_last` annotation, the tail
absorbs all remaining slots, each subtyped against `A_last`.

**Spread at call sites.** The walker must classify each argument-list
position by Lua's rule: a call expression in the **last** position
contributes its full tuple, expanded into the remaining parameter
slots; in any **other** position it contributes only slot 0. Same rule
governs `return f()` (last-position spread) and multi-assignment RHS
(last-position spread, others truncate). One classification pass on
the argument/RHS list — not three independent implementations.

**Match interaction.** `(...%P) -> %R` already binds `R` to a tuple
for multi-return; preserve that. The walker's call-site rule above
makes `R` directly substitutable wherever a multi-return is required
(arg spread, return spread, multi-LHS).

**Test obligation.** Phase-J walker must ship with explicit tests for
W1-W4, B1-B4, plus excess-LHS-padded-with-nil. The existing
`type_soundness_test.lua:1129-1146` coverage is too thin — it tests
W1 only and would have passed even with D1-D4 present.

