# static-v4 — typechecker foundation (Phase 4a)

Greenfield typechecker, derived from `docs/typechecker-rewrite-design.md`
(itself derived from simple-sub and MLstruct).

This directory implements **only Phase 4a**: type representation and the
subtyping algorithm core. The AST walker, CLI integration, cache (`.cri`),
recursion (`mu`), complement (`~T`), quantifiers (`forall`), match types,
indexed access, and effects are all out of scope and will land in later
phases.

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
- No recursive types (`mu`). The cache prevents infinite descent on
  cyclic variable links, which is the termination concern shared with
  recursive types, but `mu X. F(X)` as a constructor is not yet defined.
- No quantifiers (`forall`), no skolemization, no escape check.
- No coalescing / display-form simplification. `M.show` is a debug
  printer; user-facing principal type recovery is a later phase.
- No source positions. Per type-system.md Principle 13, locations are
  not part of the type representation.

## Running

```
timeout 60 bin/cr test lib/type/static-v4/
timeout 30 bin/cr check lib/type/static-v4/types.lua \
                       lib/type/static-v4/subtype.lua \
                       lib/type/static-v4/init.lua \
                       lib/type/static-v4/static_v4_test.lua
```

Both must pass cleanly.
