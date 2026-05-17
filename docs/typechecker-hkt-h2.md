# Typechecker — HKT H2 (Record-of-Generic-Functions Dispatch)

Design for the H2 gap in the broader-HKT roadmap. Decision-ready plan; B1
base (H1, H3, H4) already landed — see `docs/typechecker-hkt-broader.md`
and the "Known limitation" section of `docs/generic-params-spec.md`.

## The gap

```lua
--:: Maybe<A> = { tag: "some", value: A } | { tag: "none" }
--:: Functor<F: Maybe> = { map: <A, B>(F<A>, (A) -> B) -> F<B> }
--:: declare functor_maybe = Functor<Maybe>
local x = { tag = "none" } --: Maybe<integer>
local y = functor_maybe.map(x, function(a) return tostring(a) end)
```

Probe (verified): error at the call site —

```
argument 1: cannot pass `{ tag: "some", value: integer } | { tag: "none" }`
where `Maybe(_)` expected: ... is not assignable to `Maybe(_)`
```

The `Maybe(_)` form is the smoking gun: the param slot is
`TAG_TYPE_CALL(TAG_NAMED:Maybe, A_fresh)` where `A_fresh` is still free at
unify time.

## State of the path (verified by probe)

1. **`Functor<Maybe>` instantiation correctly substitutes** the outer `F` to
   `TAG_NAMED(Maybe)`. The field `map`'s type after access is a forall
   `<A,B>(TAG_TYPE_CALL(NAMED:Maybe, A), (A)->B) -> TAG_TYPE_CALL(NAMED:Maybe, B)`.
   The probe with `local m = functor_maybe.map; m(x, fn)` produces the same
   error, confirming the field's type carries the concrete-callee
   `TAG_TYPE_CALL` regardless of whether the call is fused with the
   field-access.

2. **The call-site path (`NODE_CALL_EXPR`) at `constrain.lua:2683+`** reaches
   the unified call code at lines 2789–2919 for both `fmap(...)` and
   `functor_maybe.map(...)`. There is no separate "method dispatch" path —
   `functor_maybe.map(x, fn)` is a plain `NODE_CALL_EXPR` whose callee is a
   `NODE_FIELD_EXPR`. `callee_tid` is computed by `gen_expr` and already
   carries the instantiated forall.

3. **The C_HKT_DECOMPOSE emission at `constrain.lua:2817–2891`** walks
   `inst_mapping` keyed by fresh TVs whose origin had a generic-alias bound
   (the `<F: Maybe>` shape). For H2, `inst_mapping` contains only `A_fresh`
   and `B_fresh` — neither has a generic-alias bound. `hkt_fresh_to_bound`
   is empty. The `TAG_TYPE_CALL` param slot is then inspected for
   `callee2 ∈ hkt_fresh_to_bound` — which is false because the callee is
   `TAG_NAMED:Maybe`, not a fresh TV at all. No decompose fires.

4. **`unify.normalize_type_call`** would resolve
   `TAG_TYPE_CALL(NAMED:Maybe, A_fresh)` if `A_fresh` were concrete, but it
   bails on free TVs (line 52). So the param slot enters structural unify as
   the opaque `Maybe(_)` form and fails.

The H1/fmap path that works has a *fresh-TV* callee in the param slot (F is
in `inst_mapping`), and the existing emission predicate catches it. H2's
callee is *already concrete*. That is the only difference.

## Approach options

### (A) Substitute at field access

When `m.map` is accessed and `m : Functor<Maybe>`, substitute F→Maybe in
the field's forall before returning. **Already happens today** — the probe
confirms the field type contains `TAG_TYPE_CALL(NAMED:Maybe, A)`, not
`TAG_TYPE_CALL(F, A)` with free F. So (A) is moot: substitution is already
eager. The remaining gap is downstream.

### (B) Extend C_HKT_DECOMPOSE emission to cover concrete-callee TAG_TYPE_CALL

When a param slot is `TAG_TYPE_CALL(callee, args)` and the resolved callee
is a `TAG_NAMED` referring to a generic alias (arity ≥ 1, not in
`inst_mapping`), emit `C_HKT_DECOMPOSE` with `f_fresh = callee` and
`bound_alias = callee`. The solver's existing `solve_hkt_decompose_impl`
already handles this shape — it treats `f_fresh` and `bound_alias`
symmetrically (both point to the same named alias). The final
`bind_var_to_type(f_fresh, bound_tid)` step is a no-op because `f_fresh`
isn't a `TAG_VAR` — the existing guard at `solve.lua:3737`
(`if ff_t.tag == TAG_VAR or ...`) already skips that path.

### (C) Eager TAG_TYPE_CALL resolution at field access

Force `TAG_TYPE_CALL(NAMED:Maybe, A_fresh)` to expand to Maybe's body with
`A_fresh` substituted in, before the call-site sees it. Essentially inlining
the structural decomposition into the param slot. Risk: changes the forall's
parameter shape from a nominal `Maybe<A>` to a structural union, destroying
diagnostics ("argument is not a Maybe") and complicating return-slot
re-resolution. Also: the body type still has
`TAG_TYPE_CALL(NAMED:Maybe, B_fresh)` and would need re-resolution once B
is solved — which is exactly what `normalize_type_call` already does. So
(C) overlaps with (B) but loses nominal precision.

## Recommendation: (B)

Rationale:

1. **Smallest change.** The emission code already walks `TAG_TYPE_CALL` param
   slots; just widen the predicate. The solver is unchanged.
2. **Symmetric with H1.** The "F is a fresh TV bound to a generic alias" and
   "F is already a generic alias" cases produce the same decomposition
   template (substitute alias.params → tycall args, unify against actual).
   Treating them in one code path is conceptually right.
3. **No regression risk on H5 (control).** H5 uses a monomorphic
   `(Maybe<integer>) -> Maybe<string>` — no `TAG_TYPE_CALL` survives in the
   param slot (`resolve_named_type` already expanded it eagerly). The new
   predicate only fires when a `TAG_TYPE_CALL` is present.
4. **Preserves nominal precision in errors.** The decomposition unifies the
   structural witness against the alias body template; errors surface as
   "cannot unify Maybe<A>'s body with List<integer>" rather than losing the
   nominal frame.
5. **Return-slot already handled.** Once A and B are bound,
   `unify.normalize_type_call` collapses `TAG_TYPE_CALL(NAMED:Maybe, B)` to
   `Maybe<B>` on the next unify-entry. The return value `y` will type as
   `Maybe<string>` without further changes.

## Dispatch sites that change

- **`lib/type/static/constrain.lua` lines 2861–2891.** In the param-slot
  walk inside `if hkt_fresh_to_bound and arg_tids then`, add a sibling
  branch: when `slot.tag == TAG_TYPE_CALL` and the callee is a `TAG_NAMED`
  referring to a generic alias (lookup via `env_mod.lookup_type` with
  `alias.params and #alias.params >= 1`), emit `C_HKT_DECOMPOSE` with
  `f_fresh = callee2, bound_alias = callee2`. The guard
  `if hkt_fresh_to_bound and arg_tids` must be relaxed (the new path
  doesn't require `hkt_fresh_to_bound` to be non-empty).
- **Restructure the enclosing condition** at line 2850 so the param-slot
  walk runs whenever `arg_tids` is present and the callee is a function,
  with `hkt_fresh_to_bound` treated as optional (only the bound-walk +
  eager-bind sections depend on it).
- **Optional: tighten `unify.normalize_type_call`** to also fire on
  intermediate unify recursion when one side has `TAG_TYPE_CALL` and args
  became concrete during nested unification. Probably already covered by
  the existing call at line 305–306.
- **No changes to `solve.lua`.** `solve_hkt_decompose_impl` already does
  the right thing when `f_fresh == bound_alias_id` (both = NAMED:Maybe).
  The `TAG_VAR` guard at line 3737 already skips the no-op rebind.
- **No changes to `env.lua`.** Existing `substitute_inner` for
  `TAG_TYPE_CALL` handles the return-slot case.

## Test-pinning strategy

In `lib/type/static/type_soundness_test.lua`, the H2 test is already pinned
as `has_error` with `"Maybe%(_%)"`. Flip to `no_errors` once implementation
lands. Add:

- **H2a (positive).** `functor_maybe.map(x, tostring)` returns
  `Maybe<string>` — assert the inferred type. Mirrors H1.
- **H2b (positive, Monad bind).** Record with
  `bind: <A,B>(M<A>, (A)->M<B>) -> M<B>` — call through the record.
  Returns `Maybe<B>`.
- **H2c (negative, wrong shape).** Pass a `List<integer>` to
  `functor_maybe.map` — error pattern should mention the alias or the body
  mismatch (analogous to H3).
- **H2d (negative, wrong alias).** Instantiate `Functor<List>` where List
  is shape-incompatible with the bound `<F: Maybe>` — error at record
  instantiation time (this is a `C_BOUND` check, not a call-site H2 issue,
  but worth pinning to confirm it works).
- **H2e (rank-N interaction).** The inner forall
  `<A,B>(F<A>, (A)->B)->F<B>` passes a function-typed second arg. Verify
  that the per-call rank-N skolemization (B in this case appears in both
  return and the second-arg function's return — already rank-1) still
  produces correct binding.
- **H2f (pure through record).** `Monad<Maybe>.pure(42)` returns
  `Maybe<integer>` — eager-bind path for return-only F should still fire
  for the concrete-callee shape. **This is the riskier case;** see Open
  Questions.

H5 control must remain green.

## Implementation order

1. **Add positive tests H2a, H2b** as `has_error` pins of the current
   `Maybe(_)` form. Add H2c–f as pins reflecting current behavior.
2. **Relax the outer guard** at `constrain.lua:2850` so the param-slot
   inspection runs whenever `arg_tids` exists and `ic.tag == TAG_FUNCTION`.
   Keep the `hkt_fresh_to_bound`-driven branches gated on its non-emptiness.
3. **Add the concrete-callee branch** in the param-slot loop: when
   `callee2`'s resolved tag is `TAG_NAMED` with alias arity ≥ 1, emit
   `C_HKT_DECOMPOSE` with `f_fresh = callee2, bound_alias = callee2`.
4. **Run the suite.** H1, H3, H4, H5 must stay correct. H2/H2a/H2b should
   flip to no-error. H2c should error with an alias-body mention.
5. **Handle the eager-bind branch (H2f) for concrete callees.** When the
   concrete callee appears in the return slot but not in any param slot, no
   decompose has fired and no `f_fresh` binding is needed — the slot
   already has a concrete callee, so `normalize_type_call` will collapse it
   once args are concrete. Likely no code change; confirm via H2f.
6. **Update `docs/generic-params-spec.md`** "Known limitation" — strip the
   "Field-access call sites" bullet.
7. **Update `docs/typechecker-hkt-broader.md`** with a "H2 landed" note.

Estimated complete-implementation work: ~50–120 lines (mostly tests; the
constrain change is ~20 lines), single session.

## Open questions

- **Q1.** When the concrete-callee `TAG_TYPE_CALL` appears in a return slot
  but never in a param slot (`pure` analogue), does
  `normalize_type_call` reliably collapse it once args are bound? The
  invocation at `unify.lua:305` runs at every unify, but the call's return
  type is bound via `make_unify(ret, ...)` only once. If the return slot
  is `TAG_TYPE_CALL(NAMED:Maybe, B_fresh)` and B is bound *after* the
  return-binding unify, normalization may not re-fire. The eager-bind
  branch for fresh-TV F resolves this by binding F before unify; the
  concrete-callee path skips that step. May need a "deferred normalize"
  emission or a `solve_unify` post-pass. **Probe early.**
- **Q2.** Does H2c (wrong-shape, `List<integer>` argument to a
  `Functor<Maybe>.map` slot) produce a useful error? The decomposition
  unifies `List<integer>`'s expansion against Maybe's body template. The
  error may be a structural-mismatch deep in the union, which is the same
  experience as H3 today — acceptable, but worth checking the message
  quality.
- **Q3.** Does the relaxed outer guard accidentally fire on `TAG_TYPE_CALL`
  slots whose callee is a `TAG_INTRINSIC` (`$Require`, `$EachField`, etc.)?
  Need an explicit check: only `TAG_NAMED` with alias body, not
  `TAG_INTRINSIC`. The current emission predicate via `hkt_fresh_to_bound`
  filters this implicitly because intrinsics aren't forall-bound TVs.
- **Q4.** Interaction with `solve_bound` on the inner forall's A/B (which
  have no bound). Should be inert — no change expected — but verify.

## Sizing claim

- ~50–120 lines including tests.
- Single implementation session.
- Same shape as the rank-N landing — extends an existing emission
  predicate rather than adding new infrastructure.

If Q1 (return-slot normalization) requires a deferred-normalize constraint,
add ~50–80 lines for that. Still under the broader-HKT B1 budget.

## Critical files for implementation

- `lib/type/static/constrain.lua`
- `lib/type/static/solve.lua`
- `lib/type/static/unify.lua`
- `lib/type/static/type_soundness_test.lua`
- `docs/generic-params-spec.md`
