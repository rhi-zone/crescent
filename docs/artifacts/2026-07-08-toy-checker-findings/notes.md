# Toy checker findings

## What was built

- A toy typechecker sketch at `lib/toy_checker/` testing whether a
  claims-engine with moded obligations, open producers, and saturation-pool
  scheduling works as a typechecker substrate
- Tiny toy language (let, fn, call, if/else, basic types with subtyping,
  generics) — AST-as-tables, no parser
- Two commits: initial sketch (a3f5d3a4, 28 tests), accumulate mode extension
  (7feb8430, 43 tests)
- Moded obligation IR (in/out/accumulate), registered producers (Unify, Sub,
  Infer, Check, Instantiate, Generalize), saturation pool with worklist

## What it found

### Mode proliferation is the central finding

- Started with two modes: in (must be ground) and out (this obligation writes
  it)
- Needed a third (accumulate) because `Sub(int, ?x)` can't express "record a
  lower bound" with just in/out — it collapsed to Unify, losing precision
- Needed a fourth mechanism (producer-initiated deferral) because
  `Sub(uvar, uvar)` can't be expressed by any static per-position mode —
  readiness depends on which combination of slots is ground
- Each addition papered over the same underlying problem

### Root cause: modes are a static approximation of a dynamic property

- "Is this obligation ready to run?" depends on the runtime state of its
  arguments (which uvars are solved, what bounds exist), not on a fixed label
  declared at creation time
- Sub isn't one operation with a complicated mode signature — it's four
  different runtime behaviors (ground/ground → check, ground/uvar →
  accumulate lower, uvar/ground → accumulate upper, uvar/uvar → defer)
  wearing one name
- The proliferation isn't "we need more modes" — it's that static
  per-position declarations are the wrong primitive for scheduling

### How real typecheckers avoid this

- Syntax-directed systems (Algorithm W, bidirectional checking, TypeScript):
  the AST traversal order IS the schedule. The type-theoretic rules already
  describe information flow direction at each AST position. The algorithm
  follows the rules; no scheduling decisions needed.
- Constraint generation + solving (OutsideIn, MLsub): two phases. Phase 1
  walks AST, generates all constraints. Phase 2 runs a specific solving
  algorithm with its own fixed strategy. No general-purpose worklist.
- Key insight: real typecheckers get scheduling for free from the AST's tree
  structure. The pool threw away that structure and spent three iterations
  trying to reconstruct it from mode annotations.

### The actual constraint structure is a graph

- Parent-child (tree) captures intra-expression structure but not
  cross-expression sharing
- Two separate structures (tree locally, graph globally) is also wrong —
  it's one graph with subgraphs that happen to be tree-shaped
- The constraint dependencies form a graph. Scheduling is dataflow:
  "obligation A produces this variable, obligation B consumes it, A before
  B"
- Modes were trying to describe the graph edges without having the graph
  edges

### The open hard problem

- Edge direction through shared variables is sometimes dynamic: Sub reads OR
  accumulates depending on what's ground at scheduling time
- This means the dependency graph isn't fully known at constraint emission
  time
- This is where every formulation broke down, and naming the structure
  differently doesn't make it go away
- No clean resolution was found

## OWNER-CALLs (open semantic forks documented in lib/toy_checker/init.lua)

- **A**: env threaded as auxiliary field vs reified as own Lookup judgment
- **B**: generic type-constructor variance defaults to invariant (Unify) vs
  covariant (Sub)
- **C**: Sub against unresolved uvar — collapse to Unify vs bounded
  constraint (resolved by accumulate mode, but see D)
- **D**: auto-resolve on first ground lower bound vs wait for more bounds
  (lattice-meet territory)

## Status

Parked. The toy sketch served its purpose — it found the graph-structure
insight and the dynamic-edge-direction problem in two iterations. The next
step, if resumed, would be to test whether "obligations as a dataflow graph
with the AST tree as scaffolding" avoids the mode proliferation, but that's a
redesign of the IR, not a patch.
