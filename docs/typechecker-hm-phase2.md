# HM Phase 2 — field-value-type propagation through bounds

Captured from a Plan agent in session 2026-05-15 evening, after the
H10 fuzz invariant exposed an unsoundness gap: `function f(t) return
t.x + t.y end; f({x="a", y="b"})` is silently accepted because the
HM body's field-result TVs (`U_x`, `U_y` in the example) are template-
scoped, but `propagate_meta_bound` unifies per-call instance TVs at
the call site, so call-site values never flow back into the body's
deferred `C_ARITH(U_x, U_y, R)`.

## Root cause (verified)

Body of `f(t) return t.x + t.y end` is solved once as a polymorphic
template:

- `t : T` (template TV)
- field-result TVs `U_x`, `U_y` from `t.x` / `t.y`
- `_forall_bounds[T]` = `{ x: U_x, y: U_y, ... }`
- Body emits `C_ARITH(U_x, U_y, R)` — deferred against template TVs.

At each call site `f(actual)`, `instantiate` walks the param type
producing `inst_mapping`. The bound becomes `{ x: U_x', y: U_y', ... }`.
`propagate_meta_bound` unifies the actual's `x` field with `U_x'` —
the *instance* TV. The body's `C_ARITH` references `U_x`, `U_y` (the
*template* TVs), which remain unbound forever. `solve_arith` defers
indefinitely, no error fires.

## Selected mechanism (Option C — deferred-ops attached to _forall_bounds)

Alongside `_forall_bounds[T] = bound_tid`, store
`_forall_ops[T] = [ {kind, args, ...}, ... ]` listing each body
constraint whose operands include free template TVs reachable from
`_forall_bounds[T]`'s structure. At call site, in addition to the
existing `C_BOUND` emission loop, re-emit each recorded op with
operands rewritten through `inst_mapping`. The rewritten op fires
with concrete operands once `propagate_meta_bound` binds the instance
TVs from the actual's fields.

## Why other options were rejected

- **Option B (back-edge in propagate_meta_bound binding both instance
  AND template TVs)**: monomorphises the template after the first call
  site. A second call corrupts every prior body inference.
- **Option A (re-emit ALL body constraints per call site)**: works but
  emits non-polymorphic-rooted ops needlessly. C is the principled
  subset.
- **Option D (whole-program monomorphisation)**: gives up HM. Off the
  table.

## Implementation phases

### Commit 1 — failing tests

Add to `type_test.lua` near the existing HM tests:
- `function f(t) return t.x + t.y end; f({x="a", y="b"})` — must error.
- Same with `{x=true, y=false}` and `{x=nil, y=nil}`.
- Counter-example that must STILL pass: `f({x=1, y=2})`.

These will fail until Commit 3 lands (red baseline).

### Commit 2 — record polymorphic-rooted ops

In `constrain.lua`, when emitting a body constraint whose operand TVs
include any key in `ctx._forall_bounds`, push the constraint
descriptor into `ctx._forall_ops[root_template_tv]` (keyed by the
param TV the operand traces back to; push to multiple if operands
trace to multiple templates).

No semantic change yet. Verify via debug dump that the right ops are
recorded for `t.x + t.y`, `t.x .. t.y`, `t.x < t.y`, `t.x[1]`, `f(t.x)`
where `f` is free.

**Hypothesis to verify before this commit**: a single, identifiable
body-constraint emission point (or a small enumerable set). If
scattered, prep commit factors through a helper.

### Commit 3 — re-emit recorded ops at call site

In `constrain.lua` ~line 2273-2280 (the existing `C_BOUND` emission
loop over `_forall_bounds`), add a parallel pass that clones each
recorded op with operands mapped through `inst_mapping`, then
re-emits. This makes Commit 1's failing tests pass.

**Hypothesis to verify**: `inst_mapping` covers all template TVs
reachable from `_forall_bounds[T]` and `_forall_ops[T]`, not just
`T` itself. If only `T`, instantiation must extend to mint fresh
TVs for all reachable polymorphic-rooted TVs.

### Commit 4 — flip H10 fuzz invariant

In `lib/type/static/fuzz_test.lua`, find the H10 case currently
encoding the buggy-accepted behavior and flip to require rejection.
Verify ≥500 programs/sec gate.

### Commit 5 — extend coverage to remaining body operations

If Commit 2 was scoped narrowly (e.g. only C_ARITH), broaden to
C_COMPARE, C_CONCAT, C_INDEX (literal-key access on a result-of-
field-access value, e.g. `t.x.y`), C_CALLABLE for free-callee body
ops. Each gets its own positive + negative test.

### Commit 6 — performance check

Run the typechecker self-check + perf workload from
`docs/perf/log.md`. Quadratic blowup (call_sites × body_ops) is the
risk. Cap: ~500 extra constraints per generic helper at typical
scale — not catastrophic. Mitigation if needed: memoise on
`(call_site, op)` so repeats don't redo.

## Risks

1. **Recursive functions**: monomorphic recursion is the only kind
   supported. Self-call C_CALLABLE re-emits at each external call
   site. Guard: skip op re-emission if `template_tv` is in a
   "currently generalizing" set — prevents infinite re-emission
   during mutual-recursion solve.

2. **Mutual recursion**: same open question as Phase 1's mutual-
   recursion concern. Op recording happens at body-solve time;
   verify the prescan groups mutually-recursive functions and
   solves them as a unit before any external call-site emission.

3. **Performance — quadratic in (call_sites × body_ops)**: realistic
   scale ~500 extra constraints per generic helper. Solver routinely
   processes 10⁵+ constraints; not catastrophic. Mitigation:
   deduplicate by `(call_site_span, op_id)`.

4. **Annotated `<T: bound>` regression**: annotated generics have
   concrete operands in their body C_ARITH. Don't populate
   `_forall_ops` for annotated bounds — activate only for inferred
   bounds. Verify by regression test that `<T: { x: integer, ... }>(t: T) -> integer`
   body `return t.x + 1` called with `{x="a"}` still errors via the
   existing path.

5. **Closure capture**: a closure body with `t.x + captured` records
   an op whose operands include both polymorphic-rooted (`U_x`) and
   non-polymorphic (`captured`) TVs. The rewriter must pass `captured`
   through unchanged when `inst_mapping` has no entry for it.

6. **Bounds on non-param TVs**: if `_forall_bounds` is ever populated
   for a TV that isn't a function param (e.g. a let-bound polymorphic
   local), the same recording mechanism applies symmetrically.

## Test corpus impact

- `type_test.lua` lines ~4671/4679/4689: should be unaffected
  (those are about polymorphism, not field-arith).
- H10 fuzz invariant: explicit flip in Commit 4.
- Add new fuzz invariant: "polymorphic body operation soundness".
- Stdlib regression check: `lib/iter/init.lua` and other generics-
  heavy files. Run full self-check after Commit 3.
