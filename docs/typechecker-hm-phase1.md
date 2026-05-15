# Phase 1 of HM let-polymorphism — design

Captured from the Plan agent in session 2026-05-15 after the structural-binding
attempt was reverted.

## Diagnosis

The naive "construct a structural meta-table and unify" approach for
body-usage shape inference doesn't work for arithmetic on primitives:
`integer` carries `__add` via `prim_meta`, not as a structural meta-slot,
so unifying `add`'s param (bound to a structural meta-table with `__add`)
with `1` fails.

The right abstraction is **bounds**: register the inferred constraint via
`ctx._forall_bounds[param_var_tid] = bound_tid`. The existing call-site
loop at `constrain.lua:2233-2241` already reads `_forall_bounds[orig_tv]`,
instantiates through `inst_mapping`, and emits `C_BOUND` against the fresh
per-call var.

**However**: `solve_bound`'s fallthrough branch (`solve.lua:886-899`) is
plain `try_unify` — it has no metamethod-aware path. A bound shaped
`{ #__add: (Self, Other) -> R, ... }` checked against an `integer` actual
fails because `integer` is not structurally a table. **A new
`propagate_meta_bound` branch is the prerequisite for Phase 1**, not an
optional polish item.

## Bound shapes per body operation

All shapes are **open** (`...` row var) — the actual must have *at least*
the named requirements. `Self` is the equi-recursive self-reference (the
param's own tid; see §"Self-references" risk).

| Body op | Bound on lhs (and symmetrically on rhs if free) |
|---|---|
| `t.x` (named field) | `{ x: U, ... }` — purely structural |
| `t[n]` (literal int key) | `{ [n]: U, ... }` — tuple slot |
| `t[K]` (typed key) | `{ [K]: V, ... }` — indexer |
| `a + b` (`__add`) etc. | `{ #__add: (Self, Other) -> R, ... }` |
| `a < b` / `a <= b` | `{ #__lt: (Self, Other) -> boolean, ... }` |
| `a .. b` | `{ #__concat: (Self, Other) -> string, ... }` |
| `f(args)` (free callee) | `(Args...) -> R` (function bound) |

`__len` deferred from Phase 1 — table-implicit-length semantics make the
bound shape awkward (`{ #__len: ... } | { ... }`-shaped). Use
`IMPLICIT_ANY` warning for unannotated `#x` until Phase 1 expands.

## Bound composition

When body solver sees a free param at tid `tv` with `existing =
ctx._forall_bounds[tv]`:

- `nil` → `ctx._forall_bounds[tv] = new_bound`
- non-nil → `ctx._forall_bounds[tv] = make_intersection(ctx, { existing, new_bound })`

`make_intersection` already deduplicates. `solve_bound` must handle
`TAG_INTERSECTION` by recursing into each member.

In-place table extension is rejected: re-introduces the structural-binding
mistake by pretending the param has a single concrete shape.

## Implementation phases

### Phase 1a — `propagate_meta_bound` branch in `solve_bound`

Add the metamethod-aware branch. When the bound is `TAG_TABLE` with
meta-slots and the open marker, validate via `meta_op_ret_impl`'s
prim_meta + table dispatch. Decompose the matched metamethod's signature
into the bound's free Self/Other/R TVs (analogous to
`propagate_function_bound`).

Test with hand-written `<T: { #__add: (T,T) -> T, ... }>(T,T) -> T` plus
calls `(1,2)` (accept) and `("a",1)` (reject). No new callers of the
path until Phase 1c.

### Phase 1b — sub-solve plumbing

Restore the bracketing + `solve_range` call in `gen_function` (the
prototype reverted in 2026-05-15). Add `ctx._sub_solve_params` set.
Generalize after sub-solve. **No body-solver changes yet** — verify
`id(x) return x end` polymorphism works; `add` falls through to existing
monomorphic behavior.

### Phase 1c — body solver bound emission, one solver per commit

Order chosen to minimize risk:

1. `solve_index` named field — purely structural, no metamethod
2. `solve_callable` free callee — reuses `propagate_function_bound`
3. `solve_arith` binary ops — first metamethod-bound exercise
4. `solve_compare`
5. `solve_arith` `__concat`
6. `solve_arith` unary
7. `solve_index` integer-key tuple slot, then indexer-key form

Each commit updates the two "monomorphic inference" tests at
`type_test.lua:4671/4679/4689` if the semantics change.

### Phase 1d — `MISSING_FUNCTION_SIGNATURE` demotion

Demote from error to warning per the committed decision. **Separate
commit** — diagnostic-policy change, not part of the inference
mechanism.

## Risks & open questions (load-bearing — verify with 5-line repros)

1. **Equi-recursive `Self` in bounds.** Hypothesis: param's own TAG_VAR
   tid as `Self` slot works via existing TAG_NAMED + lazy expansion.
   Repro: `--: <T: { #__add: (T, T) -> T, ... }>(T, T) -> T` then
   `add(1, 2)`. If `bin/cr check` accepts today, self-reference works.
   If it errors, equi-recursive support needs filling first or the
   fresh-self-TV+C_UNIFY workaround applies.

2. **`instantiate_inner` walks TAG_INTERSECTION.** Hypothesis: yes (env.lua
   already iterates intersection members). Verify by reading
   `instantiate_inner`. One-line fix if missing.

3. **`solve_range` retries deferred constraints within its range.**
   Recursive function references in body emit `C_CALLABLE` that defers
   waiting for the outer function tid. If `solve_range` is single-pass,
   needs a second sub-solve pass after `make_func` but before generalize.
   Polymorphic recursion is out of scope (TODO.md), so monomorphic
   resolution is fine semantically; the question is just whether the
   constraint gets re-fired.

4. **Mutual recursion grouping.** `function a() b() end function b() a()
   end`. Sub-solves see only own body; cross-function deferred
   constraints need the global solve OR group-bracketed sub-solves.
   Open: does the existing prescan already group mutual recursion?

## Test corpus impact

- `type_test.lua:4671` (id used at same type twice ok) — still passes.
- `type_test.lua:4679` (id called at two types errors) — **breaks
  intentionally**. Replace with the opposite assertion + a properly
  monomorphic-error example like
  `function f(x) return x + 1 end; f("hello")` errors.
- `type_test.lua:4689` (arith on string param caught) — still passes,
  via different mechanism (`propagate_meta_bound` vs deferred C_ARITH).
  Adjust expected error substring.
- `type_test.lua:4698` (arith on integer infers integer return) —
  still passes.
- Autofix tests for `MISSING_PARAM_ANNOTATION` — unaffected (Phase 3
  separately removes `_inferred_params` side-tables).

## Verified vs hypothesized

- **Verified by code reading**: `solve_bound` fallthrough is `try_unify`
  not metamethod-aware; `meta_op_ret_impl` dispatches prim_meta + table;
  call-site `_forall_bounds` loop exists; `make_intersection` exists with
  dedup; `gen_function` structure.
- **Hypothesized, must verify with repros before commit**: equi-recursive
  `Self`; `instantiate_inner` over TAG_INTERSECTION; `solve_range` retry
  semantics; prescan mutual-recursion grouping.
