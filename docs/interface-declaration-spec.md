# Interface Declaration: `--:: Name<T>: Constraint<T>`

## Problem

Structural subtype checking is recursive and O(fields). In a codebase with many
call sites that expect `Functor<T>`, every call checks `Monad <: Functor` by
walking all fields — repeatedly. When `Functor` adds a field, the error appears
at every call site that passed a `Monad`, not at the one place where the
relationship was claimed.

## Solution

`--:: Name<T>: Constraint<T> = body` declares an explicit subtype relationship:

```lua
--:: Functor<F> = { map: <A, B>((A) -> B, F<A>) -> F<B> }
--:: Monad<F>: Functor<F> = { map: ..., bind: ..., return_: ... }
```

Two effects:
1. **Checked assertion**: at definition time, verify `body <: Constraint<T>`
   structurally. Error at the declaration if not satisfied.
2. **Subtype oracle**: register `(Monad_alias_id, Functor_alias_id)` in a
   table. Future `Monad<X> <: Functor<X>` checks hit the oracle in O(1).

## Syntax

```
alias_decl ::= "--:: " Name params? (":" constraint)? "=" type_expr
params      ::= "<" param ("," param)* ">"
constraint  ::= Name ("<" type_arg ("," type_arg)* ">")?
```

The `:` appears between the param list and `=`. Only named type aliases as
constraints (no inline type expressions). Consistent with `<T: Bound>`.

```lua
--:: Name = body                     -- simple alias, no change
--:: Name<T> = body                  -- generic alias, no change
--:: Name<T>: Constraint<T> = body   -- with constraint declaration
--:: Name: Constraint = body         -- non-generic with constraint
```

## Definition-time check

When processing `--:: Name<T>: Constraint<T> = body`:

1. Build substitution mapping for params (TAG_VAR per param, same as normal).
2. Resolve `body` to `body_tid` under the substitution.
3. Resolve `Constraint<T>` to `constraint_tid` using the same param TAG_VARs.
4. Call `try_unify(ctx, body_tid, constraint_tid)`.
5. If fails: emit `E.CONSTRAINT_MISMATCH` at the `--::` declaration location.

The check is symbolic: `T` is a TAG_VAR in both body and constraint. `try_unify`
handles TAG_VAR via reflexivity (TAG_VAR with same name_id unifies with itself).
This verifies the relationship holds for all instantiations.

**Assigned properties**: field assignment inference runs before type alias
evaluation. A table built up via `M.foo = bar` has its row variable closed
before `--:: M: Base` is checked. No special handling needed.

## Subtype oracle

`ctx.declared_subtypes`: a flat array of `{ sub_alias_id, sup_alias_id }` pairs,
where both IDs are interned alias name_ids. Populated at definition time.

### Oracle lookup in `try_unify` (unify.lua)

Before the structural field walk, when both sides are TAG_NAMED applications:

```
actual   = Name_A applied with args_A
expected = Name_B applied with args_B
```

Check oracle: is `(Name_A_id, Name_B_id)` in `ctx.declared_subtypes`?
If yes, and `#args_A == #args_B`, and each `args_A[i]` unifies with `args_B[i]`:
→ short-circuit, return true (subtype confirmed).

The args check ensures `Monad<integer> <: Functor<integer>` passes but
`Monad<integer> <: Functor<string>` falls through to structural (which will
fail). If both sides have zero args (non-generic), oracle hit with no arg check.

### Oracle lookup in `solve.lua` / field access

When the solver resolves field access on a TAG_NAMED type (e.g., accessing
`.map` on `Monad<T>`), it currently walks fields structurally. With the oracle,
it can also check: for each `(Monad, Base)` oracle pair, if Base has the field,
include it in the candidate set.

This is a follow-up optimization — not required for correctness (structural walk
still works), but important for performance at scale.

## Error message

New code: `E.CONSTRAINT_MISMATCH = 26`

Format: `"'{name}' does not satisfy constraint '{constraint}': {structural_diff}"`

Where `structural_diff` is the existing type mismatch detail (missing fields,
wrong field types, etc.) from the failing `try_unify` call.

Example:
```
lib/maybe.lua:14: 'Monad' does not satisfy constraint 'Functor<F>': missing field 'map'
```

## Concrete examples

```lua
-- Typeclass refinement
--:: Monad<F>: Functor<F> = { map: ..., bind: ..., return_: ... }

-- Concrete implementation
--:: Vec2: Addable = { x: number, y: number, #...number_meta }

-- Via assigned properties
local List = {}
List.map = function(f, xs) ... end
List.filter = function(f, xs) ... end
--:: List: Functor<List>   -- checked after all assignments
```

## What this is NOT

- Not nominal typing: `Name` is still structurally compatible with everything
  its body is compatible with. The declaration doesn't restrict use sites.
- Not inheritance: no field inheritance from constraint. `Name`'s body must
  explicitly include all required fields.
- Not an interface keyword: just an assertion on an existing alias.

## Implementation order

1. `ann.lua`: parse `: Constraint` in alias declarations, store on alias entry
2. `constrain.lua` or `check.lua`: after processing `--::` body, do the check
   and register in `ctx.declared_subtypes`
3. `defs.lua`: add `E.CONSTRAINT_MISMATCH = 26`
4. `errors.lua`: add format template for CONSTRAINT_MISMATCH
5. `unify.lua`: oracle lookup at the start of TAG_NAMED vs TAG_NAMED comparison
6. Tests: declaration errors, oracle hit (correct args), oracle miss (wrong args)
