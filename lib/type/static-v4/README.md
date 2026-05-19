# static-v4 — typechecker foundation (Phases 4a–4c)

Greenfield typechecker, derived from `docs/typechecker-rewrite-design.md`
(itself derived from simple-sub and MLstruct).

This directory currently implements:
- **Phase 4a** — type representation and the subtyping algorithm core.
- **Phase 4b.1** — equi-recursive μ types.
- **Phase 4b.2** — indexed access types `T[K]`, with record indexers
  (`{ [K]: V }`) added to the record constructor.
- **Phase 4c** — complement `~T`, DNF-based emptiness checking, and the
  MLstruct negation rewrite that lifts the 4a union-on-RHS / intersection-
  on-LHS rejection (see "Phase 4c" section below).

Still out of scope: the AST walker, CLI integration, cache (`.cri`),
match types (4d), quantifiers / rank-N (4e), effects (4f).

## Layout

- `types.lua` — type representation. Defines the discriminated union of
  type shapes (top, bot, primitive, literal, function, record, union,
  intersection, variable) and pure constructors for each. Includes a
  minimal pretty-printer for diagnostics. No solver logic.
- `subtype.lua` — the subtyping algorithm. A simple-sub style constraint
  solver: `constrain(s, A, B)` recursively decomposes `A <: B` either
  structurally (between matching constructors) or by recording bounds on
  type variables. Includes a cache to guarantee termination on cyclic
  variable graphs.
- `init.lua` — public entry point. Re-exports constructors, a few
  primitive shortcuts (`M.number`, `M.string_`, ...), and the subtype
  predicate. This is what callers `require("lib.type.static-v4")`.
- `static_v4_test.lua` — unit tests covering primitives, literals,
  top/bottom, functions (covariant return, contravariant params, arity),
  records (width and depth subtyping, open vs closed), unions and
  intersections (introduction and elimination), variable bound
  accumulation and transitive closure, and termination on cyclic
  variable links.

## Why this shape

- **Constructors and boolean combinators are separate tags.** Per the
  rewrite design, the lattice is set-theoretic; union and intersection
  are first-class types, not just operations on a fixed tag matrix.
- **Variables carry mutable bound lists.** Following simple-sub /
  MLstruct §3.2, each variable accumulates lower and upper bounds (and
  links to other variables) during constraint solving. There is no
  union-find collapse; the solver maintains the transitive closure of
  bounds explicitly so principal type information is preserved.
- **A single constraint primitive: `A <: B`.** Per design doc §3, all
  other inference obligations (equality, field-access, callability)
  reduce to subtyping. The solver has no `C_CALLABLE`-style kinds — the
  representation precludes adding them.
- **The tag is a string literal, not an enum.** The crescent typechecker
  narrows on `t.tag == "var"` (literal-string comparison). Constants
  like `M.TAG_VAR` are exposed for external callers but internal code
  uses the literals so narrowing fires.

## What 4a does NOT do

- No AST walker, no parser, no CLI. Tests construct types directly via
  the constructor functions.
- No complement (`~T`), no MLstruct-style RDNF, no DNF emptiness check.
  Without complement, the principled handling of `A <: B | C` (the
  MLstruct rewrite `A ∧ ¬B <: C`) is not expressible, so 4a rejects both
  union-on-RHS and intersection-on-LHS obligations outright with an
  error pointing at Phase 4c. A "try each disjunct with cache rollback"
  stopgap was considered and rejected: it is sound only on ground inputs
  and silently loses principal types when variables appear, exactly the
  shape future sessions would pattern-match as the intended design
  (CLAUDE.md's "temporary measures are context poisoning"). Union-on-LHS
  and intersection-on-RHS decompose without backtracking and are
  supported in full.
- No quantifiers (`forall`), no skolemization, no escape check.
- No coalescing / display-form simplification. `M.show` is a debug
  printer; user-facing principal type recovery is a later phase.
- No source positions. Per type-system.md Principle 13, locations are
  not part of the type representation.

## Phase 4b.1 — equi-recursive μ types

Recursive types are introduced as a dedicated `mu` constructor (design doc
§4.1 `Mu(X, T)`). The user-facing API is `M.fix(f)` where `f` receives a
self-reference handle that *is* the resulting `mu` node — any reference to
the handle inside the returned body produces a cyclic Lua table.

```lua
local list = V.fix(function(self)
    return V.rec({ value = V.integer, next = self }, false)
end)
-- list denotes  μX. { value: integer, next: X }
```

`M.mu(body)` is a lower-level alternative for callers that built the cycle
manually; `fix` is the recommended path.

### Subtyping

A single rule, placed before the variable rules in `constrain`:

- `μX. T <: U`  ⇔  `T[μX.T/X] <: U`  (lazy unfold; "substitution" is
  trivial because the cycle is represented by table identity, so reading
  `mu.body` is already the substituted form).
- Symmetric for the right-hand side.

Termination is guaranteed by the existing identity-keyed cache: every
constraint `(a, b)` is admitted to the cache before recursion, so when the
unfolded body's traversal lands on the same `(μ, other)` pair a second
time, the cache short-circuits with success. This is the canonical
Amadio-Cardelli (1993) equi-recursive subtyping discipline; the rule lives
*above* the variable handling because it is purely structural and never
introduces or links variables.

### Interaction with deferred features

Equi-recursive subtyping reduces a `μ` obligation to a structural one on
the body. If the body decomposes to a constraint shape that 4a defers —
union on the right or intersection on the left — that constraint is
rejected with the same Phase 4c message as a non-recursive obligation
would be. Example: `μX. {tag: "leaf"} | {tag: "node", child: X}` is
constructible in 4b.1, and subtyping it against itself by identity
succeeds, but subtyping it against a *structurally equivalent* but
distinct μ would unfold to `union(...) <: union(...)` and then decompose
to `member <: union(...)`, hitting the 4c block. This is the right
behavior: the principled cross-disjunct case requires complement, and
patching it ad hoc here would replicate the disjunct-try backtracking
already rejected for 4a.

### Pretty-printing

`M.show` displays a μ type as `(μ X<id>. body)` and uses the same id-tagged
binding for back-references within the body, terminating on cycles. The id
makes nested μ types distinguishable (`(μ X1. ... (μ X2. ...) ...)`).
MLstruct §3.5 / simple-sub §4 use the same μ-form for coalesced recursive
types; that's the user-facing target whenever full coalescing lands.

## Phase 4b.2 — indexed access types

`T[K]` is a first-class lattice operation (design doc §1.1, §9.2.5). The API
is `M.index(obj, key)`, which returns `(type, nil)` on success or
`(nil, errmsg)` on failure. Pure: no mutation of `obj`, `key`, or solver
state.

### Record indexers

The record constructor gained an optional third argument:

```lua
V.rec({},               false, V.indexer(V.string_, V.boolean))  -- { [string]: boolean }
V.rec({ x = V.integer}, false, V.indexer(V.string_, V.boolean))  -- { x: integer, [string]: boolean }
```

Per the type-system reference, `...` (row extension) and `{ [K]: V }`
(indexer) are distinct. The third arg encodes the latter; `open` (second
arg) encodes the former.

Subtype rules added in 4b.2:
- `{ [K]: V } <: { [K']: V' }` — `K' <: K` (contravariant key), `V <: V'`
  (covariant value).
- Named LHS field flowing into an indexer-typed RHS: the field's literal
  key must lie in `K` and its value must satisfy `V`.
- A closed-no-indexer RHS still rejects extras on the LHS (including an
  LHS indexer); only an open or indexer-typed RHS admits them.

### Reduction rules

| Target shape                         | Key                                | Result                  |
|--------------------------------------|------------------------------------|-------------------------|
| Closed `{ x: A, y: B }`              | literal `"x"`                       | `A`                     |
| Closed `{ x: A, y: B }`              | literal `"z"` (absent)              | **error**               |
| Closed `{ x: A, y: B }`              | union `"x" \| "y"`                  | `A \| B`                |
| Closed `{ x: A, y: B }`              | primitive `string`                  | `A \| B`                |
| Open   `{ x: A, ... }`               | literal `"x"`                       | `A`                     |
| Open   `{ x: A, ... }`               | literal `"z"` (absent)              | `unknown` (row var)     |
| Indexer `{ [string]: V }`            | any string-typed key                | `V`                     |
| Mixed `{ x: A, [string]: V }`        | literal `"x"`                       | `A` (named wins)        |
| Mixed `{ x: A, [string]: V }`        | literal `"other"`                   | `V` (falls through)     |
| `(R1 \| R2)[K]`                      | any                                 | `R1[K] \| R2[K]`        |
| `(μX. body)[K]`                      | any                                 | `body[K]` (lazy unfold) |

### Decisions and their rationale

**Missing literal key on a closed record: error, not `never`.** The
lattice answer is `never` (no inhabitant carries that field), but
producing `never` silently degrades downstream into "X is not a subtype
of never" errors that point nowhere near the typo that caused them.
Surfacing the bug at the indexed-access site itself is the principled
response.

**Type-variable key (or target): rejected, not deferred.** The design
doc (§1.1 last paragraph) calls for deferred resolution against unbound
key variables. Phase 4a's solver does not yet expose a
deferred-constraint queue — it has only the `<:` primitive with eager
bound propagation. Per CLAUDE.md's "Temporary measures are context
poisoning" and "Ad-hoc conditions are strictly forbidden," 4b.2 does NOT
bolt a one-off pending-index queue on the side just for this feature.
The principled response is to reject loudly until the general
suspension mechanism lands (which also serves match-type evaluation per
design §5.3). The error message names this explicitly so a future
session writing the queue knows where the call sites are.

**Negated keys: not constructible.** Per design §1.1, `T[~"x"]` is
accepted in principle. But `~T` (complement) is Phase 4c — 4b.2's
lattice has no `neg` constructor. Negated keys are therefore literally
inexpressible at this phase, and no API surface is reserved for them.
When 4c lands, it adds complement first; `index.lua` then gains a case
for `key.tag == "neg"`.

### Implementation notes

- Key analysis (string-literal or union-of-literals or the `string`
  primitive) and target shape both have to be locally decidable. The
  module deliberately does NOT call into the solver to discharge
  obligations during indexed access, because indexed access is a pure
  type-level operation and must not mutate variable bounds as a side
  effect.
- Distribution over `union` and unfolding of `mu` are recursive but
  finite: keys cannot contain `mu` (they are restricted to literals,
  primitives, and unions), so the unfold-then-project pipeline halts.
- The `pairs(t)` value-type narrowing in the typechecker isn't strong
  enough to see that `r.fields` values are non-nil; the implementation
  uses an explicit guard rather than a force cast.

## Phase 4c — complement and DNF emptiness

Phase 4c adds the complement constructor `~T` and the lattice machinery that
closes the Boolean algebra: De Morgan, distribution, self-cancellation,
excluded middle. The 4a "deferred until 4c" rejections for union-on-RHS
(`A <: B | C`) and intersection-on-LHS (`A & B <: C`) are now **resolved**
in `subtype.lua` via the MLstruct negation rewrite — they reduce to an
emptiness check on `A ∩ ¬B`.

### API

- `M.neg(T)` — complement constructor. Short-circuits at construction:
  `~⊤ = ⊥`, `~⊥ = ⊤`, `~~T = T`. No further simplification at construction
  (that's `empty.lua`'s job, applied on demand).
- New tag `"neg"`, new variant `V4Neg = { tag: "neg", body: V4Type }`.

### `empty.lua`

The emptiness primitive — `is_empty(T, solver)` — converts `T` to DNF (push
`¬` inward via De Morgan, distribute `∩` over `∪`, eliminate `~~T`) and
checks each disjunct (a conjunction of positive and negated atoms) for
emptiness via:

1. `⊥` in positives or `⊤` in negatives → empty.
2. Self-cancellation: `P == N` by identity (cheap path).
3. Cross-kind disjointness: two positives of structurally disjoint kinds
   (e.g. `integer ∩ {x: int}`) → empty.
4. Same-kind primitive/literal collisions (`integer ∩ string`, two
   distinct same-base literals) → empty.
5. Positive-covers-by-negative via the solver's structural subtype check:
   if any positive `P` is `<:` any negative `N`, then `P ∩ ¬N = ⊥`.

The check recurses into `constrain` (subtype.lua) for rule (5); termination
follows because each recursive call operates on a strict subterm of the
original input, the solver shares its identity-keyed cache across recursion,
and μ types are treated as atoms (their bodies unfold lazily via the cache).

### Decision-point invocation (deferred until forced)

Per design doc §2.2 — "DNF emptiness checking is deferred until forced,
not universal" — `is_empty` fires only at three decision points in
`subtype.lua`:

1. Union on the right: `A <: B | C` reduces to `is_empty(A ∩ ¬(B | C))`.
2. Intersection on the left: `A & B <: C` reduces to
   `is_empty((A & B) ∩ ¬C)`.
3. Explicit `~T`: `A <: ¬B` ⇔ `is_empty(A ∩ B)`; `¬A <: B` ⇔
   `is_empty(¬A ∩ ¬B) = is_empty(¬(A ∪ B))`.

The constraint solver does NOT call `is_empty` on every constraint —
ground primitive subtyping, function/record decomposition, μ unfolding,
and variable bound graphs all stay in the original simple-sub path. Only
the negation-or-union-RHS shapes invoke DNF.

### Worst case and complexity

DNF normalization is worst-case exponential in the number of conjuncts
under unions. For typical crescent types (small unions, modest nesting),
the blowup is bounded. Pathological cases manifest as long-but-finite
typechecks; per design §2.2 the answer is timeouts at the call site, not
a restricted algebra.

The `pure_subtype` helper inside `empty.lua` refuses to discharge subtype
checks involving type variables on either side, to avoid mutating variable
bounds as a side effect of an emptiness query. Variables in DNF disjuncts
are treated as opaque atoms (their inhabitation is undetermined for the
purposes of the disjunct, which keeps the routine sound — never spuriously
concluding empty — at the cost of incompleteness for queries like
`α ∩ ¬α = ⊥` when `α` is bare. The constraint solver already records `¬T`
as an upper bound on `α` and propagates, so this rarely matters in
practice.)

### Indexed access on negated keys

Not yet implemented in `index.lua`. The design (§1.1 "negated keys are
accepted") admits `T[~"x"]`; realizing it requires subtracting the negated
literal from the contributing key set inside the index reducer. Tracked
for Phase 4d when match-type wildcards force the feature in. Negation
itself is still constructible — only the index reducer's handling of it
is pending.

## Running

```
timeout 60 bin/cr test lib/type/static-v4/
timeout 30 bin/cr check lib/type/static-v4/types.lua \
                       lib/type/static-v4/subtype.lua \
                       lib/type/static-v4/empty.lua \
                       lib/type/static-v4/index.lua \
                       lib/type/static-v4/init.lua \
                       lib/type/static-v4/static_v4_test.lua
```

Both must pass cleanly.
