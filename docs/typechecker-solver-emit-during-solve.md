# Typechecker — Solver Emit-During-Solve

Prerequisite architectural change for option (X) (defer per-call
instantiation as a first-class solver constraint, see
`docs/typechecker-h2-correct-design-v3.md`). The current `solve_range` was
designed before any handler needed to emit; its fixed-`hi` was an unstated
assumption, not a deliberate invariant. This design generalizes the
invariant.

## Current `solve_range` (solve.lua:3819-3936)

```lua
for i = lo, hi do constraints[i]._deferred = false end
for pass = 1, 4 do
    ...
    for i = lo, hi do                       -- hi captured once at entry
        local c = constraints[i]
        ...
        if handler and not c._solved then
            if c._deferred then n_deferred += 1
            else
                local result = handler(ctx, c)
                if result == false then c._deferred = true
                else c._solved = true end
            end
        end
    end
    ...
    if not changed then break end
end
```

`hi` is a parameter, never re-read. Up to 4 passes. Deferred re-tried every
pass. `_solved` is sticky across `solve_range` invocations.

**Call sites:**
- `solve.lua:3948` — `M.solve` calls `solve_range(ctx, constraints, 1, #constraints)`. Whole-program.
- `constrain.lua:2246` — `gen_function` sub-solve over `[body_start+1, body_end]`. Captured at AST-traversal time. Invariant: every constraint emitted from this body's AST traversal lives in the closed range; nothing outside the function emits into the range.

## No existing handler emits during solving

Exhaustive grep verified: `ctx._constraints` is read-only in solve.lua;
no `emit(ctx, ...)` or `_constraints[#_constraints + 1]` appends inside
handlers. `_forall_ops` re-emission runs at AST-traversal time
(`constrain.lua:2958-2992`), not from a solver handler.

This means the redesign is purely infrastructural — no migration of
existing emit sites.

## Sub-solve invariants

`gen_function`'s sub-solve over `[body_start+1, body_end]` depends on:

1. **Closure**: every constraint semantically belonging to the body was emitted from inside `gen_block(bs, bl)` and so sits in the range.
2. **No external interleaving**: between `body_start = #ctx.constraints` and `body_end = #ctx.constraints`, nothing outside the body's AST traversal appends. True today because AST traversal is sequential.
3. **Post-solve quiescence**: when sub-solve returns, body constraints are either `_solved` or `_deferred`.
4. **`_sub_solve_params` scoping**: set on entry, restored on exit.

What "body-internal" means: any constraint produced *as a logical
consequence of* a body constraint (e.g., `C_INSTANTIATE_AT_CALL` for a body
call site whose handler runs during sub-solve and emits `C_BIND_GENERICS`
/ `C_CHECK_ARGS`) is morally body-internal and must be solved before
sub-solve returns — otherwise the parent emits a `_forall_ops` record over
an incomplete body, or generalization captures unresolved TVs.

## Design candidates

Shapes evaluated:

| shape | LOC | ad-hoc | preserves sub-solve | composes-with-defer | composes-with-(X) |
|---|---|---|---|---|---|
| α dynamic high-water  | 30 | yes (attribution heuristic) | weak  | yes      | weak |
| β child constraint lists | 80 | no | yes | yes (parent defers) | yes |
| γ range attribution tag  | 60 | no | yes | yes | yes |
| δ recursive solve_range  | 10 | no, but unclear pass semantics | yes | unclear | partial |
| ε two-phase per range    | 50 | yes | weak | yes | weak |
| ζ eager in-handler dispatch | 0 | yes | n/a | no | violates "no special cases" |
| **η structured emit channel** | **50** | **no** | **yes** | **yes** | **yes** |

## Recommendation: (η) handler returns structured emit channel

Rationale:

- **Attribution is automatic and explicit:** emitted constraints belong to the same range as the parent. No `range_id`, no high-water-mark race.
- **Deferral semantics unchanged:** emitted children join the range as ordinary constraints; if they defer, the standard per-pass retry handles them.
- **Sub-solve invariants preserved:** `gen_function`'s `body_end = #ctx.constraints` is taken after `gen_block` returns; sub-solve calls `solve_range` which now grows the range while solving — but every grown constraint is, by construction, a consequence of a body constraint, so it logically belongs to the body. `body_end` becomes the *initial* upper bound; the loop reads `#constraints` each pass.
- **Composes with (X):** `C_INSTANTIATE_AT_CALL` handler returns its fresh `C_BIND_GENERICS` / `C_CHECK_ARGS` as `emit`. They join the active range; if called from sub-solve, they're solved before sub-solve returns; if called from outer solve, they're solved before outer solve returns. No new flags.
- **Loses nothing:** handlers that don't emit return `true` / `false` as before; the channel is opt-in.

(β) was close but requires structural recursion through children, complicating the `_solved` / `_deferred` flag dance (a child can flip the parent's state). (η) keeps the worklist flat.

### Concrete protocol

- Handler return convention changes from `boolean` to
  `boolean | { solved: boolean, emit?: { Constraint... } }`.
- Backward-compatible boolean handling: `if type(result) == "boolean" then handle-as-today; else c._solved = result.solved; for _, nc in ipairs(result.emit or {}) do ctx.constraints[#ctx.constraints+1] = nc; nc._deferred = false; end end`.
- `solve_range` re-reads `hi = #constraints` at the top of each pass; treats anything past the original `hi` as still in-range.

## Sizing

**One commit, ~60-100 LOC** in `solve.lua`. No migration of existing
handlers required. The redesign is purely infrastructural: change
`solve_range`'s loop bound and the handler return protocol, with
backward-compatible boolean handling.

If a smoke test reveals subtle ordering interactions (e.g., a deferred
parent emits children that defer to later passes), split into:
1. Dynamic `hi` rebinding only, no protocol change (~20 LOC).
2. Structured emit channel (~60 LOC).

Default: single commit.

## Open questions for implementation session

1. **Test surface.** Does any existing rank-N / HKT test exercise sub-solve nesting where a body constraint's handler produces follow-on work? If not, add a regression test pairing this redesign with a stub `C_INSTANTIATE_AT_CALL` handler that emits a trivial child constraint as part of this commit — minimum bar for confidence.
2. **Deferral × emit interaction on re-entry.** If a parent constraint defers AND has emitted children in a prior pass, what happens to the children on re-entry? Proposal: children are normal range members from emit time onward; the parent's deferral is independent. Verify no handler relies on "children only exist if parent solved."
3. **Pass-count budget.** `solve_range` caps at 4 passes. If emits cascade (handler A emits B, which emits C), does 4 passes suffice? Cascade depth in practice is bounded by AST nesting, but worth measuring once Option (X) is live.

## Position vs. project goal

Crescent's typechecker goal (CLAUDE.md): "safer than Rust and more powerful
than Haskell." (η) makes the dependency between a constraint and its
emitted consequences a first-class part of the solver protocol — the kind
of generalization the project's principles endorse (one rule, no special
case). It composes with Option (X) without introducing a
`C_INSTANTIATE_AT_CALL`-shaped condition anywhere in the solver loop. The
only debt it leaves is the pass-count budget question (#3 above), which
is empirical, not principled.
