# N-ary constraint solver: design proposal

**Status: PROPOSAL, awaiting owner sign-off.** Nothing in this document is
built. No code exists yet for anything described here. This is a from-scratch
design pass, not a plan to patch `lib/constraint_solver` in place.

**Provenance note (required by the remediation approach in
`docs/genre-battery-design.md`):** this design was produced *without reading*
`lib/constraint_solver/` — not its source, not its tests, not any README
under that directory. The trigger for this constraint is documented in that
file: `lib/constraint_solver` special-cases ternary constraints as a
hardcoded arity fork (a boolean flag selecting between near-duplicate
backtrack functions), and AC-3 propagation never sees ternary constraints at
all. Per the owner's stated rationale, reading the flawed implementation
risks anchoring a redesign on its existing architecture's assumptions,
defeating the point of a from-scratch pass. This document is grounded in
general CSP theory and prior art (Russell & Norvig's AIMA treatment of
generalized arc consistency; Bessière & Régin's GAC-schema; Mackworth's AC-3;
Haralick & Elliott's forward checking) and in crescent's own stated
conventions (`docs/conventions.md`, `CLAUDE.md`), not in any existing
crescent code for this problem.

Where this document presents options rather than a single recommendation,
that is deliberate — the task this document answers explicitly asks for
tradeoffs laid out, not a forced winner. The owner picks.

## 1. Problem representation

A CSP is variables + domains + constraints, all uniform regardless of arity.

```lua
--:: type Constraint = {
--::   scope: string[],              -- ordered list of variable names
--::   check: (tuple: unknown[]) -> boolean,
--::   name: string?,                -- optional, for error messages only
--:: }

--:: type Problem = {
--::   variables: string[],
--::   domains: { [string]: unknown[] },
--::   constraints: Constraint[],
--:: }
```

- **A constraint is a closure, not a name-keyed dispatch entry.** `check`
  is an ordinary Lua function the caller writes: `check(tuple)` where
  `tuple[i]` is the current candidate value for `scope[i]`. This is the same
  extensible-closure pattern crescent already uses elsewhere per
  `docs/conventions.md` (codecs, protocol transports) — the solver never
  branches on constraint identity or arity; it only ever calls `check`.
- **Arity is `#scope`, nothing more.** A unary constraint has `#scope == 1`,
  binary `#scope == 2`, ternary `#scope == 3`, n-ary `#scope == n`. There is
  exactly one code path for consistency-checking a constraint: build a
  tuple in scope order, call `check(tuple)`, get back `true`/`false`. No
  arity ever needs a distinct function, table shape, or branch — this is the
  direct fix for the flaw named in `docs/genre-battery-design.md`.
- **Scope is how the solver knows which variables a constraint touches.**
  Explicit and ordered — order matters because `check` reads `tuple` by
  position. A caller writing `all_different({"a","b","c"})` supplies
  `scope = {"a","b","c"}` and a `check` that compares all pairs; the solver
  never needs to know "all-different" is a named constraint family, only
  that it has this scope and this predicate.
- **Constraints may repeat a variable in scope, or omit variables entirely
  from any constraint.** The representation does not forbid or special-case
  either. A variable with zero constraints touching it is a valid (if odd)
  CSP. A variable appearing twice in one scope is the caller's choice to
  make and the caller's `check` to interpret consistently — the solver does
  not deduplicate or reject it, since doing so would be exactly the kind of
  arity/shape special-casing this design exists to avoid.

## 2. Error handling

Per `docs/conventions.md`: `(nil, errmsg)` on failure, never throw, for data
errors — an invalid problem definition is a data error, not a programming
error.

```lua
--:: new(variables: string[], domains: table, constraints: Constraint[], opts?: table)
--::   -> Problem | (nil, string)
```

`new` validates structural well-formedness before any solving is attempted:

- Every name in every constraint's `scope` must appear in `variables`.
  Failure: `(nil, "constraint " .. (c.name or tostring(i)) .. " references undeclared variable " .. name)`.
- Every declared variable must have a `domains[name]` entry (may be an empty
  array — see below).
- `constraints[i].check` must be a function value (`type(c.check) == "function"`).
  Failure: `(nil, "constraint " .. i .. " has no check function")`.

What `new` deliberately does **not** reject: an empty domain, or a
constraint set with no solution. Those are not malformed-problem errors —
they are valid CSPs that happen to be unsatisfiable, and unsatisfiability is
discovered by solving, not by construction-time validation. Conflating "the
problem is malformed" with "the problem has no solution" would blur a
distinction the caller needs (a malformed problem is a bug in the caller's
own code; an unsatisfiable one may be the intended puzzle state — e.g. a
zachlike level the player has configured into a contradiction).

```lua
--:: solve(problem: Problem, opts?: table) -> table | (nil, string)
```

`solve` returns `(nil, "no solution")` when search exhausts without finding
a consistent full assignment. This is the same `(nil, errmsg)` shape as any
other failure, per convention — the caller distinguishes "no solution" from
a construction-time error by which call produced it, not by a different
return shape.

## 3. Consistency propagation: generalized arc consistency (GAC)

Binary arc consistency (AC-3) revises a domain against a single neighboring
variable's domain. That doesn't generalize by extending "neighbor" to "set
of neighbors" for free — the hard part is exactly what the flawed
implementation avoided by forking: a value `v` in `Di` is *supported* by an
n-ary constraint `C` with scope `(X1, ..., Xk)` iff there exists a full
tuple `(v1, ..., vk)` with `vi` drawn from `Di`'s current domain (and `v` in
the position of `Xi`) such that `check(tuple) == true`. Finding — or failing
to find — that tuple is a search problem in its own right, scaling with the
domain sizes of every other variable in the scope. This is real,
citable-in-general-CSP-theory cost (Bessière & Régin's GAC-schema names this
exact tradeoff), not an implementation detail to wave past.

Two propagation-engine options below differ in how they pay that cost. Both
share the same constraint representation from §1 — the choice is about
*how* GAC does its support search, not about a different constraint shape
per option.

### Option A — GAC via on-demand support search (GAC-schema style)

For each `(constraint, variable)` pair in a revision queue: for each
remaining value `v` in that variable's domain, run a small backtracking
search over the *other* variables in the constraint's scope (in scope
order, using their current domains) looking for any tuple that makes
`check` return `true`. If found, `v` survives; if the search exhausts
without a support, `v` is pruned and every constraint touching that
variable is re-queued (standard AC-3-style propagation to a fixpoint).

- The support search itself is uniform over arity: it is "backtrack over
  `#scope - 1` remaining positions," which degenerates correctly to O(1)
  for unary, a single nested loop for binary, and an actual small
  backtracking search for ternary and above — one algorithm, not one
  algorithm plus a fork.
- **Cost**: worst case for one value's support check is the product of the
  domain sizes of the other `k-1` scope variables — exponential in arity in
  the worst case, though usually far smaller in practice, and equal to
  standard AC-3's binary cost when `k = 2`. This is GAC-schema's documented
  cost profile, not a novel penalty introduced by generalizing.
- **Pro**: no separate index structure to maintain; correctness is easy to
  argue because it's a direct implementation of the GAC definition.
- **Con**: repeated support search recomputes work AC-3-family algorithms
  (AC-4/AC-2001, GAC variants of the same) exist specifically to amortize —
  see Option B.

### Option B — GAC via maintained support structure (AC-4/GAC-schema with support counts)

Same representation, same fixpoint propagation loop, but instead of
re-searching for a support from scratch on every revision, the solver
maintains a per-`(constraint, variable, value)` structure recording either
a cached "last known support tuple" (AC-2001-style — cheap to re-validate,
falls back to full search only when the cached support is no longer valid)
or a full support-count table (AC-4/GAC-4-style — expensive to build
up front, then O(1) amortized per pruning event).

- **Pro**: substantially cheaper propagation over the course of a full
  search when the same constraint gets revised many times (which is the
  common case inside backtracking search, not just at the root).
- **Con**: the support structure itself costs memory proportional to
  arity × domain size per constraint, and is more implementation surface —
  more state to keep consistent, more room for the maintenance logic itself
  to become the next hardcoded-arity trap if it isn't written generically
  over `#scope` from the start. This is a real engineering-complexity cost,
  not just a performance note.

**Neither option is the forced winner.** Option A is simpler to build and
to verify correct; Option B is faster on problems where propagation runs
many times per search (which is most nontrivial CSPs). A library could
reasonably ship Option A first and add Option B as a second tier later
under crescent's "provide multiple implementations, each real and
independent" convention (`docs/conventions.md` — implementation tiers) —
but that sequencing choice, like the choice itself, belongs to whoever
owns implementation, not to this design doc.

### Option C — offer a cheaper, less-complete propagation level as an explicit alternative

Full GAC (either A or B) is not the only propagation level worth exposing.
`docs/conventions.md`'s "when one implementation can't satisfy all
legitimate use cases, provide multiple" principle applies directly here:
forward checking (see §4) is strictly weaker than GAC — it only prunes a
constraint's scope when exactly one variable in that scope is still
unassigned during search, and does no standalone fixpoint propagation
before or between assignments — but it is far cheaper, since it never runs
a support search over multiple free variables at once.

A library could expose propagation strength as an explicit option on
`solve`, e.g. `opts.consistency = "forward_checking" | "gac"`, using the
*same* constraint representation and the *same* search loop (§4) either
way — only the amount of pruning done between assignments changes. This
is not a third representation option; it is an orthogonal knob that
applies on top of whichever of A/B is chosen for the "gac" level, named
here because the task calls for naming it explicitly: a caller solving a
large, loosely-constrained puzzle may prefer forward-checking's lower
per-node cost even though it explores more nodes, while a caller solving a
tightly-constrained, high-arity puzzle (the zachlike case most likely to
suffer from the arity-forking flaw this doc responds to) benefits more from
GAC's stronger pruning per node.

## 4. Search: backtracking with MRV, LCV, forward checking

None of these three heuristics need arity-specific logic — each is defined
either per-variable or per-scope-membership, which is already arity-generic
because §1's representation stores scope as a plain list with no arity
distinction to branch on.

- **MRV (minimum-remaining-values)**: at each search node, pick the
  unassigned variable with the smallest current domain. This is a property
  of a single variable's domain size, never of any constraint's arity —
  generalizes with no change. A degree-heuristic tie-break (prefer the
  variable touched by the most still-unsatisfied constraints, counting
  constraints of every arity equally by scope membership) is the standard
  companion tie-break and is equally arity-generic: "count constraints
  whose scope contains this variable" doesn't care whether a given
  constraint's scope has 1, 2, or 12 entries.
- **LCV (least-constraining-value)**: order candidate values for the
  chosen variable by how many values they would eliminate from *other*
  variables' domains if assigned — computed by simulating forward checking
  (below) for each candidate and counting eliminations across every
  constraint touching the variable, again regardless of each constraint's
  arity.
- **Forward checking**: on assigning variable `Xi := v`, for every
  constraint `C` with `Xi` in its scope, check whether exactly one variable
  `Xj` in `C.scope` remains unassigned. If so, prune from `Dj` every value
  `w` such that no completion of the now-(k-1)-fixed tuple with `Xj := w`
  satisfies `check`. If more than one variable in `C.scope` remains
  unassigned, forward checking does nothing for `C` at this step — this is
  forward checking's known limitation (it only prunes at the "last free
  variable" moment), and it is *already* arity-generic in the classical
  algorithm: "exactly one unassigned variable remains in scope" is a
  condition on `#scope` and an unassigned-count, not a per-arity branch.
  The condition degenerates correctly for binary constraints (the textbook
  case) without needing separate code for ternary or n-ary scopes.

The backtracking loop itself is unchanged from the classical algorithm:
pick a variable (MRV [+ degree tie-break]), try its domain values in LCV
order, forward-check (or run full GAC propagation, per whichever §3 option
is chosen) after each tentative assignment, backtrack on domain wipeout.
Nothing in this loop inspects `#scope` to decide what to do — arity only
ever shows up as the length of a list that generic code iterates over.

## 5. Summary of open choices for the owner

1. **Which GAC engine** (§3 Option A: on-demand support search, vs. Option
   B: maintained support structure) — or ship A first and treat B as a
   later addition under the tiered-implementation convention.
2. **Whether to expose a propagation-level option** (§3 Option C: forward
   checking vs. GAC as a caller-chosen `opts.consistency` value) or ship
   GAC only and let callers who want cheaper propagation write their own
   search loop against the same representation.
3. Sequencing of any implementation work is not addressed here — this is a
   representation and algorithm design only, not a build plan.
