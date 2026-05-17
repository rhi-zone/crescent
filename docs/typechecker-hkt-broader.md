# Typechecker — Broader HKT (F<A> Composition)

Design for B1 in the typechecker roadmap. **H1, H3, H4, H5, H6 landed.** **H2
(record-of-generic-functions dispatch) was attempted, reverted, and is now
pending the (X) redesign** — see `docs/typechecker-h2-correct-design-v2.md`
for the v2 recommendation. The original H2 commit (`213d8516`) shipped
Approach (B) (predicate widening + a NODE_CALL_EXPR callee override) but the
override was unsound; per v2, predicate widening alone is sound-but-useless
and the full commit was reverted in favour of deferred instantiation as a
first-class solver constraint (option X), to be designed in a future session.

## The gap

`<F: SomeAlias>` parses and `F<A>` parses. `resolve_annotation_type` already
emits a `TAG_TYPE_CALL(F_tv, A_tv)` for `F<A>` when `F` is a forall-bound TV
(`constrain.lua:582–604`, deferred-application branch). The parameter slot
of `fmap` is correctly built as `TAG_TYPE_CALL(F, A)`. The body type `F<B>`
is also a `TAG_TYPE_CALL(F, B)`.

What fails is everything downstream:

1. `unify.lua` has **no `TAG_TYPE_CALL` arm**. When the call-site argument
   type `Maybe<integer>` (already expanded by `resolve_named_type` into
   `{tag:"some",value:integer}|{tag:"none"}`) meets the param slot
   `TAG_TYPE_CALL(F, A)`, the structural side wins, F and A stay free, and
   the error is `cannot assign ... to _(_)`.
2. `solve.lua:solve_bound` (line 1070–1074) explicitly skips bound checks
   when `bound.tag == TAG_TYPE_CALL`: *"unapplied HKT application — not yet
   supported"*.
3. Even if unify decomposed `TAG_TYPE_CALL` structurally, the LHS has lost
   its `Maybe`-ness — aliases are eagerly expanded. There's no
   `Maybe<integer>` shape left to align with `F<A>`.

Probe (confirmed):

```
--:: Maybe<A> = { tag:"some", value:A } | { tag:"none" }
--:: declare fmap = <F: Maybe, A, B>(fa: F<A>, f: (A)->B) -> F<B>
fmap(x, fn)  -- error: ... where `_(_)` expected
```

## The two approaches

### Approach 1 — Nominal preservation of applied aliases

Stop eagerly expanding `Alias<X>` to its body. Introduce a wrapper (or reuse
`TAG_TYPE_CALL` with a `TAG_NAMED` callee) that preserves the symbolic form
`Alias<X>` in slot types and only unfolds when forced. Then `unify(Maybe<int>,
TAG_TYPE_CALL(F, A))` decomposes by aligning callees (bind `F := Maybe`) and
args (bind `A := integer`).

**Concrete changes:**

- `types.lua`: introduce `TAG_APPLIED_ALIAS(name_id, args)` or reuse
  `TAG_TYPE_CALL(TAG_NAMED(Maybe), [integer])` as canonical when the alias
  is generic. Today `resolve_named_type` immediately substitutes — change to
  return the wrapper for generic aliases. Force-unfold via a
  `force_alias(ctx, tid)` helper called by union/intersection normalization,
  narrowing, field access, etc.
- `unify.lua`: add a `TAG_TYPE_CALL × TAG_TYPE_CALL` arm decomposing
  callee+args structurally. Add fallback arms that force-unfold one side
  when shapes mismatch.
- `constrain.lua`: every site that calls `resolve_named_type` and assumes a
  concrete result must handle the wrapper. Field-access fast path,
  discriminant narrowing in `narrow.lua`.
- `solve.lua:solve_bound`: drop the `TAG_TYPE_CALL` skip; enforce by unifying
  the applied alias with the bound.
- `env.lua:substitute_inner`/`instantiate_inner` for `TAG_TYPE_CALL`: when
  callee substitutes to a TAG_NAMED alias, return the wrapper instead of
  force-resolving.

**Compatibility:**

- `TAG_PARTIAL_APP`: orthogonal.
- `$Opaque`: nominal already — unaffected; existence proof that nominal
  preservation works in crescent.
- `$Require`: returns singleton-keyed nominal; unaffected.
- Match types: subject types may now be wrapped; need `force_alias` before
  pattern dispatch.
- Row polymorphism: structural rows unaffected.
- Rank-N: clean composition.
- HM Phase 2: `_forall_bounds[F]` can now hold the wrapper and `solve_bound`
  actually enforces it.

**Risks (biggest):**

- Every code path that pattern-matches on `tag == TAG_UNION` etc. and was
  accustomed to seeing the expanded form now needs `force_alias`. Wide blast
  radius.
- Pretty-printing, display, error messages — many string builders.
- Memoization keys (`stable_id` for `$Opaque`, `data[3]` on TAG_TYPE_CALL)
  need extension to include alias args.
- Performance: extra indirection on every structural operation.

**Size estimate: 600–1000 lines** plus extensive test churn. Largest item
in Phase B by far.

### Approach 2 — Bidirectional propagation through TAG_TYPE_CALL

Keep eager structural expansion of `Alias<X>`. At the call site, when a
parameter is `TAG_TYPE_CALL(F, A)` and the argument is structurally
`Maybe<integer>`'s expansion, propagate backward: F has a kind bound
(`<F: Maybe>`) — use the bound to recognize that the actual shape came from
instantiating `Maybe`'s body, then back-solve to recover A.

**Concrete changes:**

- `constrain.lua` call-site path (around line 2514, where `_forall_bounds`
  are walked): when `_forall_bounds[F] = Maybe` (a generic alias), and the
  param slot contains `TAG_TYPE_CALL(F_fresh, A_fresh)`, emit a new
  constraint `C_HKT_DECOMPOSE(F_fresh, A_fresh, Maybe, actual_arg_tid)`.
- `solve.lua`: new `solve_hkt_decompose` — when the actual is `Alias<X1..Xn>`'s
  expansion (per alias body template), pattern-match it against the alias
  body using `A_fresh` as the slot, bind A and F. First-order unification
  of a known template against a structural witness.
- `solve.lua:solve_bound`: stop skipping `TAG_TYPE_CALL` bounds; trigger
  the same decomposition.
- `env.lua:substitute_inner` (1024–1116): handle the case where F resolves
  to a `TAG_NAMED(Maybe)` and re-resolve the alias body with bound args.
  Already partially exists.

This is the spiritual sibling of HM Phase 2 (Option C): record extra info
at template-construction time, re-emit derived constraints at call site.

**Compatibility:**

- `TAG_PARTIAL_APP`, `$Opaque`, `$Require`: all unchanged.
- Match types: unchanged; subject is already concrete.
- Rank-N: composes — rank-N skolems flow through args of `TAG_TYPE_CALL`
  the same way as elsewhere.
- HM Phase 2: directly extends the same `_forall_bounds` machinery.

**Risks:**

- Pattern-matching a structural type back into an alias template is
  ambiguous when alias bodies overlap. Mitigation: kind-bound `<F: Maybe>`
  pins F to that template by definition; F is not "solved" — it's fixed by
  the bound. Only A and friends are solved.
- Bidirectional decomposition is shallow: works for alias bodies that mention
  their params positionally and structurally. Match types in alias bodies
  (`type Foo<X> = match X { ... }`) cannot be inverted.
- Loses ability to write `<F, A>(fa: F<A>)` without a bound on F — there's
  nothing to back-solve against. The spec already requires HKT params to
  be bounded; no regression.

**Size estimate: 250–450 lines.** Roughly a third of Approach 1.

## Concrete repros under each approach

### Repro 1 — `fmap`

```lua
--:: Maybe<A> = { tag: "some", value: A } | { tag: "none" }
--:: declare fmap = <F: Maybe, A, B>(fa: F<A>, f: (A) -> B) -> F<B>
local x --: Maybe<integer> = { tag = "none" }
local y = fmap(x, function(a) return tostring(a) end)
-- want: y : Maybe<string>
```

- **Today:** `argument 1: ... where _(_) expected`. Both F and A unbound.
- **Approach 1:** `Maybe<integer>` stays wrapped. Unify with
  `TAG_TYPE_CALL(F, A)` decomposes — F := Maybe, A := integer. Body uses
  `TAG_TYPE_CALL(F, B) = Maybe<B>`; once B is solved (from f's codomain
  string), return is `Maybe<string>`. Clean.
- **Approach 2:** `_forall_bounds[F] = Maybe`. New
  `C_HKT_DECOMPOSE(F, A, Maybe, expansion)` fires. Pattern-match expansion
  `{tag:"some",value:integer}|{tag:"none"}` against Maybe's body template
  `{tag:"some",value:A}|{tag:"none"}` — solve A := integer, F := Maybe
  (already pinned). Return slot `F<B>`: after B := string, resolve via the
  alias to `Maybe<string>`.

### Repro 2 — `Functor` typeclass record

```lua
--:: Functor<F: Maybe> = { map: <A, B>(F<A>, (A) -> B) -> F<B> }
```

- **Approach 1:** record-typed; field `map` is a forall whose params reference
  F (from outer scope). When instantiated (`Functor<Maybe>`), F substitutes
  to the Maybe alias wrapper, fields reconstruct. Works.
- **Approach 2:** When `Functor<Maybe>` is requested, substitute
  `F := TAG_NAMED(Maybe)`. The `TAG_TYPE_CALL(F, A)` substitutes its callee
  to `TAG_NAMED(Maybe)`, and `env.substitute_inner` for `TAG_TYPE_CALL`
  already handles "callee is TAG_NAMED → re-resolve" (line 1090–1107). For
  the dispatch table pattern in `lib/fp/`, this might actually work TODAY —
  worth probing. The probe failure suggests it does not (A is still bound
  by the inner `<A,B>` forall and only the outer F gets substituted).

### Repro 3 — `bind` (monad)

```lua
--:: Monad<M: Maybe> = {
--::   bind: <A, B>(ma: M<A>, k: (A) -> M<B>) -> M<B>,
--::   pure: <A>(a: A) -> M<A>,
--:: }
```

Both approaches handle this the same way as Functor. `pure` is the harder
case for Approach 2 — the return type is `M<A>` and there's no actual to
back-solve from. But A is solved from the argument `a`, M is pinned by the
bound, so substitution-time resolution suffices: `pure(42)` produces
`Maybe<integer>` directly.

## Recommendation

**Approach 2 — bidirectional propagation.**

Rationale:

1. **Compatibility.** Approach 1 touches every site that pattern-matches on
   type tags. crescent's typechecker is dense with such sites. Switching to
   wrapped aliases means every existing site needs a new "unfold-if-wrapped"
   guard. Approach 2 adds one constraint kind and one solver case.
2. **Composability with rank-N and HM Phase 2.** Approach 2 is the same
   shape as HM Phase 2 (record info at template, re-emit at call site).
   Rank-N already walks `TAG_TYPE_CALL` for instantiation; nothing to add.
3. **Implementation size.** ~3× smaller. Phase B has multiple items; B1
   shouldn't eat the budget for B2–B5.
4. **Ergonomics.** Approach 2 requires an HKT param to have a constructor
   bound (`<F: Maybe>`). The spec already documents this. No regression.
   Functor/Monad/Traversable are exactly the use case the bound was designed
   for.
5. **Honest about limitations.** Approach 2 can't invert alias bodies using
   match types or non-structural decomposition. Document this; carve out
   explicitly. For `lib/fp/` typeclasses, all templates are plain structural
   ADTs.

Approach 1 is the right long-term answer for full TypeScript-class HKT, but
the cost is too high for the present roadmap. Revisit if Approach 2 hits a
wall in `lib/fp/` real-world usage.

## Dispatch sites that change (Approach 2)

- `lib/type/static/constrain.lua` near line 2514: extend the `_forall_bounds`
  walk at call sites to recognize bounds that are generic aliases
  (`TAG_NAMED` with arity ≥ 1) and emit `C_HKT_DECOMPOSE` for each param
  slot containing `TAG_TYPE_CALL(F_fresh, ...)` where `F_fresh ∈ inst_mapping`.
- `lib/type/static/defs.lua`: add `M.C_HKT_DECOMPOSE` constraint kind near
  the existing constraint kinds (~line 122).
- `lib/type/static/solve.lua`: new `solve_hkt_decompose` — given
  `(F_fresh, args_fresh, bound_alias, actual_tid)`, resolve the alias body
  against actual, binding `args_fresh`. Add to constraint dispatch.
- `lib/type/static/solve.lua:solve_bound` line 1072: drop the
  `TAG_TYPE_CALL` skip; route to the new path.
- `lib/type/static/env.lua:substitute_inner` (TAG_TYPE_CALL branch, line
  1090–1107): when callee is a generic alias and all args resolved,
  re-resolve via `resolve_named_type` so `TAG_TYPE_CALL(Maybe, integer)`
  collapses to the alias expansion. Already partial; verify completeness.
- `lib/type/static/unify.lua`: optional minor — add a
  `TAG_TYPE_CALL <:> TAG_TYPE_CALL` arm for the double-deferred case
  (callees unify, args unify recursively).

## Test-pinning strategy (mirrors A1)

In `lib/type/static/type_test.lua`, add
`describe("HKT broader: F<A> composition (KNOWN GAP)", ...)`:

- **H1.** `fmap(maybe_int, tostring)` returns `Maybe<string>`. Pin current
  `has_error` with the `_(_)` text.
- **H2.** `Functor<Maybe>` instantiation produces a usable record. Pin
  current `has_error` on usage.
- **H3.** Bound enforcement: `<F: Maybe>` and call with `F := List` should
  error. Today: passes silently per `solve_bound`'s `TAG_TYPE_CALL` skip.
  Pin `no_errors` (wrong) → flip to `has_error`.
- **H4.** `pure(42) : M<integer>` resolves when M is supplied/inferred. Pin
  current behavior.
- **H5.** Control: monomorphic `(Maybe<integer>) -> Maybe<string>` continues
  to typecheck. Must remain green throughout.
- **H6.** Match-typed alias body (`type Foo<X> = match X { ... }`) — HKT
  through this is **not** supported by Approach 2 and must emit an explicit
  error rather than miscompiling.

Implementation done when H1–H4 flip from current state to correct, H5 stays
green, H6 emits the documented "non-invertible alias body" error.

## Implementation order

1. **Pin H1–H6** as above. Red baseline.
2. **Add `C_HKT_DECOMPOSE`** in `defs.lua` and a stub `solve_hkt_decompose`
   that just `return true` (defer). Wire emission in `constrain.lua`'s
   `_forall_bounds` walk.
3. **Implement structural decomposition** in `solve_hkt_decompose` — for
   plain alias bodies (TAG_UNION / TAG_TABLE / TAG_TUPLE), unify the actual
   against the body-template-with-fresh-vars-where-A-was, binding fresh A
   from the structural witness.
4. **Drop the TAG_TYPE_CALL skip** in `solve_bound`; route to the same
   path. H3 flips.
5. **Tighten `env.substitute_inner` for TAG_TYPE_CALL** so the return-side
   `F<B>` collapses cleanly once F is pinned. H4 should pass.
6. **Add the optional `TAG_TYPE_CALL <:> TAG_TYPE_CALL` unify arm** for
   double-deferred cases.
7. **Document the limitation** (match-typed alias bodies) and ship H6 as
   the explicit-error case.
8. **Update `docs/generic-params-spec.md`** "Known limitation" section to
   reflect the new state.

## Open questions

- **Q1.** Does `env.substitute_inner` for `TAG_TYPE_CALL(TAG_NAMED, args)`
  already correctly re-resolve when all args are concrete? Code at
  env.lua:1090–1107 suggests yes, but the Functor repro suggests partial.
  Needs a direct probe early in implementation.
- **Q2.** When alias bodies overlap (`A<X> = X | nil`, `B<X> = X | nil`),
  is the kind bound truly sufficient to pin F? Believe yes — F's identity
  comes from the bound declaration, never from witness inference — but
  worth a soundness test.
- **Q3.** Performance impact of the call-site loop emitting
  `C_HKT_DECOMPOSE` per HKT param. Probably negligible; HKT params are
  rare. Bench before/after on `lib/fp/` files.
- **Q4.** How does the new constraint interact with the existing
  `_forall_ops` re-emit at line 2529 (HM Phase 2)? Likely orthogonal —
  HM Phase 2 covers ARITH/COMPARE/etc., not type-application — but verify
  no double-fire.

## Sizing claim

- B1 under Approach 2: **~300 lines including tests**, fits within a single
  implementation session.
- B1 under Approach 1: **~1000 lines**, multi-session, blast radius across
  the typechecker.

This is comparable to the rank-N landing (also ~300 lines) — not larger
than the rest of Phase B combined.

## Critical files for implementation

- `lib/type/static/constrain.lua`
- `lib/type/static/solve.lua`
- `lib/type/static/env.lua`
- `lib/type/static/defs.lua`
- `lib/type/static/type_test.lua`
