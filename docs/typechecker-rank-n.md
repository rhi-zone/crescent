# Typechecker — Rank-N Subsumption

**Status: landed 2026-05-17.** Call-site argument subsumption against
forall-typed parameters is implemented; cases N1/N5/N6/N7/N8 in
`lib/type/static/type_soundness_test.lua` flip to `has_error`, body-check
control N9 unchanged. See `feat(type): rank-N call-site subsumption` commit.

## The gap

A function parameter whose type contains a `<T>` quantifier parses and is used
correctly *inside* the function body, but **the call site does not check that
the argument actually has the polymorphic shape the slot requires**.

```lua
--: (x: number) -> number
local function only_number(x) return x end

--: (f: <T>(T)->T) -> number
local function apply_twice(f)
  local a = f(42)        -- f is correctly checked as polymorphic here
  local b = f("hello")   -- and here
  return 0
end

local r = apply_twice(only_number)   -- 0 errors today — should error
```

The body of `apply_twice` is sound: `f(42) : integer`, `f("hello") : string`,
and a return type mismatch in the body is caught. The unsoundness is the call:
any function-typed argument is accepted, including monomorphic ones and even
wrong-arity ones (`() -> number` passes a `<T>(T)->T` slot today).

Pinned by `assert.describe("soundness: rank-N polymorphism call-site (KNOWN
GAP)", ...)` in `lib/type/static/type_soundness_test.lua` (commit `a017b046`).
Cases N1, N5, N6, N7, N8 lock current-wrong-behavior; N9 is the body-check
control the fix must not regress.

## Dispatch sites

The bug is the absence of `TAG_FORALL` cases at two places, not a wrong
implementation:

- `solve.lua:solve_check_args` (near line 2716) branches on
  `callee_t.tag == TAG_FUNCTION` and has no arm for `TAG_FORALL`. When the
  parameter type or argument type is a forall, the subtype check is silently
  skipped.
- `env.lua:instantiate_inner` (near line 515) has no `TAG_FORALL` arm and falls
  through, returning the forall unchanged instead of instantiating its body
  when an LHS forall meets a concrete RHS.

## The rule (rank-N subsumption)

Standard bidirectional rank-N (Peyton Jones et al., *Practical type inference
for arbitrary-rank types*). To check `arg : σ <: τ`:

1. **RHS forall** — `arg : σ <: ∀a. τ'`:
   - Generate a fresh **skolem** for `a` at the current scope level.
   - Recurse on `σ <: τ'[a := skolem]`.
   - After the check, verify the skolem has not escaped (see below).

2. **LHS forall** — `∀a. σ' <: τ` where `τ` is not a forall:
   - Instantiate `a` to a fresh **unification var** at the current level.
   - Recurse on `σ'[a := freshvar] <: τ`.

3. **Both forall** — `∀a. σ' <: ∀b. τ'`:
   - Apply (1) first (skolemize the RHS), then (2) (instantiate the LHS) on
     the resulting goal. Nesting falls out of recursion.

4. **Neither forall** — fall through to the existing structural subtype check.

This is bidirectional: subsumption is **not symmetric**. `<T>(T)->T <:
(number)->number` is fine (specialize the polymorphic side); the reverse is
not (a concrete function is not polymorphic enough).

## Existing infrastructure to reuse

The pieces needed already exist:

- **`FLAG_SKOLEM`** (`defs.lua:241`) — flag on a type variable. `unify.lua`
  `bind_var` refuses to bind a skolem, which is exactly what step (1) needs
  for the body-side check.
- **`skolemize_fn`** (`constrain.lua:1665–1670`) — converts `FLAG_GENERIC` vars
  on a function's quantifier into `FLAG_SKOLEM` for body checking. This is
  *already* the rank-1 special case of step (1); the rank-N fix generalizes it
  to also fire at call sites where the *slot* is forall.
- **Per-tv scope level** (`data[1]`, set at `constrain.lua:902` and elsewhere)
  — every type variable records the level at which it was introduced. This is
  the foundation for the escape check.
- **`env.lua:instantiate`** (lines 522–526) creates fresh unification vars at a
  chosen level — exactly what step (2) needs.

## The escape check

The subtle part of rank-N. After step (1) finishes, the freshly minted skolems
for the RHS quantifier must not appear in any binding that outlives the call
site. Concretely: no skolem at the call-site level should be reachable from
(a) the inferred return type returned to the caller, or (b) any outer
binding's type. If it is, the polymorphic slot has been "specialized" to a
non-polymorphic value masquerading as polymorphic — unsoundness.

Scope of the check: this is **call-site local**, not a global post-traversal
pass. After each `solve_check_args` call that introduced skolems, walk the
constructed return type and the relevant constraint outputs for any tv with
`FLAG_SKOLEM` whose level matches the call frame. If found, error
("polymorphic value escapes its quantifier").

This is narrower than a generalized escape-detection phase. The subagent
investigation suggested a 300–400 line phase; that estimate was for a
generalized scope-invariant check. The focused per-call version is smaller,
likely 80–150 lines including the dispatch additions.

## Implementation sketch

Order of work:

1. **Add the `TAG_FORALL` cases** to `solve_check_args` and
   `instantiate_inner`. Reuse `skolemize_fn` for the RHS-forall case;
   reuse `instantiate` for the LHS-forall case. Without escape checking,
   this already flips N1/N5/N6 to errors (verifiable by running
   `bin/cr test lib/type/static/type_soundness_test.lua` — the pinned
   `no_errors` assertions will start failing, signalling progress).
2. **Add the per-call escape check.** Verifies N7 (forall in return position)
   and similar cases. Without it, step 1 still has a residual unsoundness.
3. **Update the soundness tests:** flip the `no_errors(...)` assertions in
   the `KNOWN GAP` describe block to `has_error(...)`, and either rename
   the describe block (drop "KNOWN GAP") or move the cases to the
   general rank-N section.
4. **Add positive tests:** the TS-forwardRef-style example (smuggling a
   generic through two layers), a rank-3 nest with correct polymorphic args,
   and at least one case where the LHS-forall path fires (passing a
   polymorphic function into a monomorphic slot, which should specialize
   correctly).
5. **CLAUDE.md / docs:** narrow or remove the "more powerful than Haskell"
   claim, or — once this lands — actually back it up. Update
   `docs/typechecker-reference.md` to document forall in parameter and
   return positions as a first-class feature.

## Decisions on landing

- **Skolem scope representation: per-call counter on ctx**
  (`ctx._rank_n_call_counter`), stored in the skolem TV's `data[4]` slot.
  Levels alone are insufficient because nested calls live at the same
  `ctx.scope.level`. A monotonic counter is cheaper than threading AST node
  ids and only matters for the per-call escape walk lookup.
- **`_forall_bounds` / `C_BOUND` interaction:** the call-site loop at
  `constrain.lua` already emits `C_BOUND` for every TV in `inst_mapping`,
  which includes the rank-N skolems. `solve_bound` defers on skolems (they
  remain free TAG_VARs in find()), which is harmless — the bound never
  fires, but it also never errors. Adequate for the current tests; a future
  pass may want active bound enforcement on skolems.
- **Variance probe outcome:** the variance hypothesis (Gap 3) is closed
  for the rank-N case by structural invariance of table fields plus
  FLAG_SKOLEM bind rejection. The probe `take_poly(only_number_array)` in
  `type_soundness_test.lua` confirms `(Arrn<number>) -> number` is rejected
  where `<T>(Arrn<T>) -> T` is required, without needing variance
  annotations. Variance work remains relevant for broader scenarios but
  was not a blocker here.

## Tests

Already pinned in `lib/type/static/type_soundness_test.lua` under
`assert.describe("soundness: rank-N polymorphism call-site (KNOWN GAP)")`:

- N1 — monomorphic `(number)->number` passed where `<T>(T)->T` required.
- N5 — wrong-arity `() -> number` passed where `<T>(T)->T` required.
- N6 — `(string)->string` passed where `<T>(T)->T` required, body uses at
  multiple types.
- N7 — forall in return position; monomorphic returned where polymorphic
  required.
- N8 — rank-3 nested forall; monomorphic forced into forall slot via inner
  call.
- N9 — control: body-side check still rejects forall used at incompatible
  annotated type. **The fix must not regress this.**

The implementation is not done until these flip from `no_errors` to
`has_error`, plus the positive cases listed in step 4 above pass.
