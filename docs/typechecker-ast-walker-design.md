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
   in any read source; design needed before Phase J.
