# static-v4 — typechecker foundation (Phases 4a–4b.1)

Greenfield typechecker, derived from `docs/typechecker-rewrite-design.md`
(itself derived from simple-sub and MLstruct).

This directory currently implements:
- **Phase 4a** — type representation and the subtyping algorithm core.
- **Phase 4b.1** — equi-recursive μ types.

Still out of scope: the AST walker, CLI integration, cache (`.cri`),
indexed access (4b.2), complement `~T` (4c), match types (4d),
quantifiers / rank-N (4e), effects (4f).

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

## Running

```
timeout 60 bin/cr test lib/type/static-v4/
timeout 30 bin/cr check lib/type/static-v4/types.lua \
                       lib/type/static-v4/subtype.lua \
                       lib/type/static-v4/init.lua \
                       lib/type/static-v4/static_v4_test.lua
```

Both must pass cleanly.
