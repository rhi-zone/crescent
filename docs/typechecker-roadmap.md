# Typechecker Roadmap

A prioritized map of the work between today's typechecker and a system that
honestly backs the CLAUDE.md claim ("safer than Rust and more powerful than
Haskell"). Today the claim is overstated on several axes; this document is the
plan to either back it up or narrow it.

## Status today (May 2026)

Audit performed this session against the major axes of type-system power.
Summary:

**Sound and working:** rank-1 let-polymorphism, row polymorphism, match types,
discriminated union narrowing, bidirectional inference, type predicates,
match-types-as-type-level-computation.

**Known unsoundness:** rank-N subsumption at call sites, HM Phase 2
field-value-type propagation, variance annotations on generic params.

**Not implemented:** higher-kinded types, effect tracking, impredicativity,
GADT-strength flow typing, refinement types, linear types.

**Wins vs. Haskell** (axes where crescent matches or exceeds): row
polymorphism (Haskell has no native form), match types (Haskell approximates
via closed type families with worse ergonomics), discriminated union narrowing
(parity with TS).

## Phase A — Soundness (mandatory)

Any "more powerful" claim presupposes the basics are sound. These items
actively poison the repo today: future sessions will reach for features that
appear to work and build on the unsoundness.

### A1. Rank-N subsumption at call sites

**State:** designed, pinned, not implemented.

- Design: `docs/typechecker-rank-n.md`
- Pinned tests: `lib/type/static/type_soundness_test.lua`,
  `assert.describe("soundness: rank-N polymorphism call-site (KNOWN GAP)")`,
  commit `a017b046`.
- TODO: `TODO.md` under HM let-polymorphism Phase 1 → Still open.

### A2. HM Phase 2 — field-value-type propagation

**State:** known unsoundness, open in TODO.md (line 372 area). Not yet
designed.

Generic params do not propagate field-value constraints through bounds.
Example from TODO.md: `f(t) return t.x + t.y end; f({x="a", y="b"})` silently
passes when it should error. Needs a design doc analogous to
`typechecker-rank-n.md` before implementation.

### A3. Variance annotations

**State:** known unsoundness, `docs/soundness-audit.md` Gap 3. Structural
subtyping happens to catch some bad cases but the discipline is missing.

Interacts with A1: rank-N subsumption needs variance-correct behavior on
container types (`<T>(Container<T>) -> T` vs. `(Container<number>) -> number`).
The two should probably be designed jointly or A3 deferred until A1 lands.

## Phase B — Power (in priority order)

### B1. Higher-kinded types

The single biggest deficit vs. Haskell. Blocks every functor/monad/traversable-
shaped abstraction. Audit found that `<F: SomeGeneric>` parses but does not
compose: `F` is treated as a type variable, not a type constructor, so

```lua
--: <F, A, B>(F<A>, (A)->B) -> F<B>
```

does not work. Verification: probed this session, fails.

Highest leverage because so many idiomatic abstractions assume it. If only one
power axis is closed, this is the one.

### B2. Effect tracking

`docs/effects.md` exists as a design exploration, classified Level 0.5
(defer). Async / coroutines are currently `any`. Finishing this would put
crescent **ahead of mainstream Haskell**, which delegates effects to
libraries with non-trivial ergonomics. Strong leverage for the "more powerful
than Haskell" claim.

### B3. Impredicativity

Instantiating a type variable with a polymorphic type (`Maybe (∀a. a -> a)`).
Likely falls partially out of A1 done right (QuickLook-style impredicativity).
Revisit after A1 lands rather than designing separately.

### B4. GADT-strength flow typing

Match types cover part of this. The gap is type-variable equations exposed by
discriminant narrowing. Narrower use cases than B1/B2; defer until A and B1/B2
are done.

### B5. Refinement types

Predicate subtyping (`{x: number | x > 0}`). Biggest stretch — would put
crescent in LiquidHaskell territory. Major design work. Only justified if the
project explicitly wants that mantle.

## Phase C — Documentation honesty

Parallel; can land any time.

- If Phase A is incomplete: narrow CLAUDE.md's boast to the wins
  (row polymorphism, match types, discriminated unions). Do not claim
  "more powerful than Haskell" while rank-N is unsound.
- Once Phase A is done: restate the claim to be specific — "matching Haskell
  on rank-N, exceeding on row polymorphism, match types, and effects (once
  B2 lands)."
- `docs/typechecker-reference.md` should document each axis's current state.
  Today it presents features without flagging which ones have known
  soundness gaps; that is itself a poison source.

## Order of work

Implementation order: **A1 → A3 (or jointly with A1) → A2 → B1 → B2 → B3 →
C → B4 → B5**.

Rationale:
- A1 is furthest along (designed) and unblocks the variance discussion at
  depth.
- A3 is small and interacts with A1; bundling reduces churn.
- A2 needs its own design pass; sequencing after A1/A3 lets the design borrow
  the rank-N skolem/level work.
- B1 (HKT) is the headline power gap and should land before any expansion of
  the "more powerful than Haskell" claim.
- B2 puts crescent meaningfully ahead on a recognized axis.
- C (doc honesty) gates expanding the boast; do it as each phase clears.
- B4/B5 are stretch goals and not required for the core claim.

## Non-goals

- Linear / affine types: Lua's table semantics make linearity ill-fitting;
  not on the roadmap.
- Dependent types in the Idris/Lean sense: out of scope; refinement types
  (B5) is the closest crescent will go.
- Removing structural subtyping in favor of nominal: deliberately preserved;
  structural is one of the wins.
