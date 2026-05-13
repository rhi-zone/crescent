# Unannotated parameter semantics

**Status:** Decided 2026-05. Going with Option 4 (inference + warning + autofix).
See "Chosen direction" at bottom. Phases A, B, and C all landed (Phase A:
commit `c43bd439`; Phase B: `a61c7cbb`; Phase C: this commit).

# Original framing (preserved for context)

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

## Chosen direction: Option 4 — inference + warning + autofix

User chose a fifth option in 2026-05: keep usage-driven inference for
unannotated params, but surface each inferred param as a warning at the
function-def site, plus (eventually) an autofix that writes the inferred
signature back. This preserves the convenience of inferred params while
making them visible and self-healing.

Three mechanisms, all landing at the function-def site:

1. **Track unannotated-param origin on type vars.** `constrain.lua` records
   each fresh `TAG_VAR` for an unannotated param in `ctx._inferred_param_tid`
   (set) and `ctx._inferred_params` (per-fn metadata: name_id, var_tid,
   fn_line, fn_col). Solver behavior is unchanged — these are post-pass
   metadata only, not solver predicates.

2. **REDUNDANT_CAST classifier guard** (Phase A, commit `c43bd439`).
   `solve_overlap` checks whether the raw constraint LHS tid is in
   `_inferred_param_tid`. If so, the cast asserts a type that was inferred
   from callers, not annotated — neither REDUNDANT_CAST (would strip the
   only explicit assertion) nor FORCE_CAST is right. Suppress both.

3. **MISSING_PARAM_ANNOTATION diagnostic** (Phase B, commit `a61c7cbb`).
   Post-pass walk over `ctx._inferred_params`. For each param whose var
   got bound to a concrete type (not free var, unknown, or any), emit a
   warning at the function-def site listing the inferred type. Suppressed
   when the linting config disables `missing_param_annotation`, when no
   callers bound the param, or when the inferred type is unknown/any.

4. **Autofix** (Phase C — design below; implementation pending).

## Phase C design

**Decided 2026-05** after evaluating realistic failure modes. The original
plan called for modal inference + `PARAM_INFERENCE_OUTLIER` detection as a
safety mechanism against autofixing genuinely-polymorphic functions. That
safety mechanism presupposed a solver change (non-destructive
inferred-param binding) that the current solver doesn't have — and under
current destructive-bind semantics, polymorphic-by-accident callers already
error out at their call sites, so there's nothing to "outlier-warn" about.

The end state is *all functions annotated*. The unannotated phase is
transient: typecheck runs, warnings + errors guide the user to accept
autofixes, after one round trip the code is fully annotated. Design from
that end state, not from "unannotated must always typecheck cleanly."

### Mechanism: record at C_SUB emit, autofix at post-pass

Solver semantics unchanged. `solve_sub` keeps destructive binding — first
caller wins; mismatching callers error at the call site. (This is what
localizes typo-among-many-callers bugs.)

In `constrain.lua`, when emitting `C_SUB(arg_tid, param_var)` and
`param_var ∈ ctx._inferred_param_tid`, also append
`(line, col, arg_tid)` to `ctx._inferred_param_callsites[param_var]`.
This records *all attempts*, including ones the solver subsequently rejects.

Post-pass (extending the Phase B walk):

- Resolve each recorded `arg_tid` via `find()` and widen it.
- **One distinct widened type** → write that type. Trivial case.
- **Modal type covers ≥80% and is strictly more frequent than alternatives**
  → write the modal type. Outliers continue to error at their call sites
  (the existing `CALL_ARG_MISMATCH` path); user investigates whether each
  outlier is a typo or a legitimate-but-missing-from-the-annotation type.
- **No clear modal** (close split, three-way, etc.) → write the **union**
  of distinct widened types. After accepting the autofix, all callers
  typecheck. User can narrow the annotation by hand later if they want.
- **Zero recorded callers** → no autofix (Phase B already suppresses the
  warning).

The 80% threshold is a starting heuristic. Tune after corpus results.

### How this handles realistic patterns

- **Multi-type log helper** (`log("hi"); log(42); log(true)`): no modal,
  autofix writes union; one round trip clears all call-site errors.
- **Pure forwarding wrapper**: same as above.
- **Implicit polymorphism** (`pair(1, "x")`): same as above.
- **Structural duck typing** (callers pass different shapes with a
  common field): union; body field-access works iff the field is in all
  branches.
- **Refactoring in progress**: union; body errors point at the actual
  shape mismatch.
- **Typo among many callers** (99 string + 1 integer): modal=string,
  autofix writes `(string) -> R`, typo caller errors normally at its site.

### Annotation rendering — open subproblem

The autofix needs a tid → `--:`-parseable source converter. `display_short`
exists but is not guaranteed round-trippable through `ann.lua` for all
type shapes (generics, complex unions, opaques, nominals, intersections).

Type-level `require` is the hairy case. If an inferred type references a
type defined in another module — e.g. `MyType` from `lib/foo` — the
rendered annotation needs to make that name resolvable in the destination
file. Three sub-options:

- (i) Render the type *structurally* (inline the structural shape). Avoids
  the require problem entirely but loses the alias name; produces unwieldy
  annotations for deeply-nested types.
- (ii) Render the alias name and insert a `--:: T = require("lib.foo").T`
  (or equivalent) at the top of the file if not already imported. Requires
  detecting whether the name is already in scope and synthesizing import
  text; touches more of the file than a single-line annotation.
- (iii) Render the alias name *only if already in scope* in the destination
  file; otherwise fall back to (i) for that type. Most conservative;
  may produce a mix of structural and alias forms across the file.

Decision: start with **(iii)**. It's the lowest-risk option, doesn't
touch top-of-file imports, and the structural-fallback case for
non-imported aliases is at worst noisy, never wrong. Re-evaluate after
corpus results — if structural fallbacks are pervasive, escalate to (ii).

### Autofix placement

Insert `--: (T1, ..., TN) -> R` on the line immediately above the
function definition (matching the existing `--:` convention). Single-line
defs: trivial — use the function-def line's byte position to compute the
insertion point. Multi-line defs (`local function f(\n  a,\n  b\n)`):
same rule — insertion is keyed to the `function` keyword's line, not the
end of the param list. Param-list multi-line layout doesn't affect where
the annotation goes.

If an annotation already exists on the preceding line (e.g. a partial
`--::` or a stale `--:`), the autofix is skipped to avoid mangling it.
The warning still fires; user resolves by hand.

## Rejected alternatives

The original options 1-3 were considered and rejected for the reasons above:
Option 1 (`unknown` default) and Option 2 (hard error at def site) both
produce a corpus-wide surge of errors on first run with no migration path;
Option 3 (HM generalization) is a substantial typechecker change and may
produce confusing errors for non-generic functions. Option 4 is a strictly
additive change layered over the existing inference behavior.

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
