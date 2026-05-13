# Unannotated parameter semantics — open question

## Context

The typechecker currently creates a fresh `TAG_VAR` for each unannotated function
parameter (`lib/type/static/constrain.lua:1516`, `:1542`). The first call-site
`C_SUB(arg_type, param_var)` constraint hits `solve_sub`
(`lib/type/static/solve.lua:579`) which calls destructive `unify`, binding the
param's var to the caller's argument type.

This makes param types depend on *usage* rather than *declaration*. The bug
surfaces in REDUNDANT_CAST diagnostics: `--[[:! string]]` on an unannotated
param `s` is flagged redundant because by the time `solve_overlap` runs, `s`
is already bound to `string` by some caller. The cast itself is innocent — the
binding is upstream.

Verified during investigation: `try_unify` and `types_overlap` in
`lib/type/static/unify.lua` are genuinely non-destructive (no `bind_var`
calls). The binding does NOT come from the cast path; it comes from
`solve_sub`'s destructive `unify` on the call-site C_SUB.

## Options

Three semantics for unannotated params have surfaced in conversation. None is
committed.

### Option 1: Default to `unknown`

Unannotated params are typed as `unknown` (top type, must be narrowed before
use). Call sites don't back-propagate; `unknown` accepts everything.

Consequences:
- Every body usage like `s:find(...)`, `s + 1`, `s.field` fails. The fix at
  every such site is an annotation.
- Force casts on unknown become meaningful (narrow `unknown` → `T`).
- Massive surge in errors across the corpus on first run.

A prior session committed to this option unilaterally without comparing
alternatives. That commitment was not user-approved.

### Option 2: Implicit-missing-annotation is a hard error at the def site

No inference for unannotated params. Missing an annotation is an error at the
*function definition*, not at every usage inside the body. Mirrors
TypeScript's `noImplicitAny`.

Consequences:
- One error per missing annotation, not one per usage. More tractable error
  count.
- Error fires where the fix belongs (the signature), not where the symptom
  appears.
- Same end state as option 1 (annotated everything) but a different path
  through.

### Option 3: Hindley-Milner-style generalization

Param vars become generic for the duration of the function; each call site
instantiates a fresh copy. Avoids first-call-wins pollution without forcing
annotations.

Consequences:
- Substantial typechecker change. HM generalization is currently only present
  for `let`-style locals, not function params.
- Preserves the convenience of unannotated params for genuinely-generic
  functions.
- May produce confusing errors for non-generic functions the author intended
  to be monomorphic.

## Design constraint: signatures, not body narrowing

Whatever the param semantics, **body-level narrowing is never an acceptable
substitute for a parameter annotation.** If a function needs `s` to be a
string, the signature says so — `--: (string) -> ...`. Adding
`type(s) == "string"` guards, `assert(...)` preconditions, or other in-body
narrowing in lieu of annotating is a copout: it relocates the contract from
where callers can see and check it (the signature) to where it costs runtime
and silently re-validates caller correctness on every call. Suggesting
in-body narrowing to "fix" a missing annotation is wrong.

This rules out a fourth option that might seem tempting — "leave params as
fresh vars but require narrowing in the body before use." That is option 1
with a worse error location.

## What's not decided

Which option to take. The choice belongs to the user, not the session
implementing the fix. A session arriving at this work should read this note,
understand the trade-offs, present the choice freshly to the user — and not
commit to one unilaterally.

## Related files

- `lib/type/static/constrain.lua:1516`, `:1542` — param TAG_VAR creation
- `lib/type/static/constrain.lua:1469`, `:1548` — vararg `T_ANY` defaults
- `lib/type/static/solve.lua:579` — destructive `unify` on call-site C_SUB
- `lib/type/static/solve.lua:517-525` — existing `original_was_free_var` guard
  for checked casts (incomplete; does not extend to force casts)
- `lib/type/static/solve.lua:~2515` — REDUNDANT_CAST classifier; conflates
  unifiability with assignability when actual is bound by upstream constraints
- `lib/type/static/unify.lua:851-940` — `try_unify` (verified non-destructive)
- `lib/type/static/unify.lua:1132-1156` — `types_overlap` (verified
  non-destructive)
