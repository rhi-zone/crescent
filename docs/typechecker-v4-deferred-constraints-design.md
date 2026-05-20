# Typechecker v4 — deferred-constraint queue (K6f)

## §0 Frame

Several v4 walker phases reject loudly today because there is no general
mechanism for a constraint to *wait* on a type variable. The four documented
rejection sites are:

- **4b.2 — indexed access**: `index.lua` rejects with "indexed access on an
  unbound type variable […] is deferred until the variable is bound;
  Phase 4b.2 has no deferred-constraint queue" (both for `obj` as a `var`
  and for the key as a `var`).
- **4d — match types**: `match.lua` `arm_outcome` reports `"suspended"`
  whenever the subject (or pattern) mentions a free, non-capture variable;
  the public `forward` then translates that to "Phase 4d has no general
  suspension queue".
- **K6c — operators**: operators against an unresolved TV operand currently
  resolve against the current bound only.
- **K6e — method dispatch**: TV receivers reject with "annotate the
  receiver" rather than wait for the receiver's type to be inferred.

K6 discovery counted ~468 errors of the 4b.2 shape across the corpus, all
fundamentally the same pattern: a constraint discovered too early, before
the TV it depends on has narrowed enough to discharge it.

This document designs the missing infrastructure: a **deferred-constraint
queue**, threaded through the v4 solver, that lets such constraints
*suspend on a specific TV* and *wake when that TV's bound changes*.
Reference points: MLstruct §3.2 (polar bounds + transitive closure),
MLstruct §3.3 / §5.2 (RDNF and the "deferred until forced" discipline
already used by `empty.lua`), and simple-sub's variable-watcher pattern
(Parreaux 2020). The design also mirrors what `empty.lua` and `match.lua`
already do *locally* via `pure_subtype` / `mentions_free_var`: refuse to
mutate, report a status, and bail. K6f generalizes that "refuse + report"
into "refuse + park on the awaited TV + resume on wake".

The design is real infrastructure, not a carve-out — there is no
constraint-kind-specific code path. Suspension is expressed once on the
solver in terms of TV identity and a thunk; every rejection site converts
to producing one of those thunks.

## §1 What is a deferred constraint?

A **deferred constraint** is a unit of work the solver could not complete
because, structurally, it needed a TV to be more determined than it is.
"More determined" is defined per-site by the producer of the thunk; the
queue itself does not interpret it. The constraint carries:

- the **awaited TVs** — a non-empty set of `V4Var.id` values; the
  constraint cannot make progress until at least one of these TVs has its
  bound list changed (a new lower or upper bound, or a link). The "wake on
  any-of" semantics is the right default — see §5.
- the **resume thunk** — `(V4Solver) -> "done" | "still_waiting" |
  "failed"`. The thunk re-runs the work; if it can complete, it discharges
  any further obligations through the normal `constrain` primitive. If it
  still cannot make progress, it re-defers (potentially on different TVs,
  if the obstruction has moved).
- **origin metadata** — the source location, the constraint kind, and a
  human description for diagnostics if the constraint never wakes or
  ultimately fails (§7).

Concrete instances from the four rejection sites:

1. **4b.2 — `obj` is a TV.** `index(α, "foo")` cannot reduce; the TV has no
   record-shaped lower bound yet. Awaited: `{α.id}`. Resume: re-run
   `index(α, "foo")` with the *current* `α`. If `α` is now a `rec`, the
   reduction proceeds and the resulting `<:` obligation to the originally
   requested result type is constrained. If `α` is still a variable but now
   has a record in its `lower`, re-defer on `α` (a tighter bound may yet
   come) — see §5 on this guard.

2. **4b.2 — key is a TV.** `index(obj, β)` where `β` is the key.
   `analyze_key` rejects because adding the current bound would race future
   tightening. Awaited: `{β.id}`. Resume: re-run `analyze_key(β)`.

3. **4d — match subject is a TV.** `forward(α, arms, wildcard)` reports
   `"suspended"` because `arm_outcome` would mutate `α` via `constrain`.
   Awaited: `{α.id}` plus any other free vars in `α`'s structure (in
   practice just `α` itself; for compound subjects with multiple free vars,
   the union of their ids). Resume: re-run `forward`.

4. **K6c — operator on TV operand.** `α + 1` cannot fully resolve `α`'s
   numeric kind until `α`'s bounds settle. Awaited: `{α.id}`. Resume:
   re-emit the operator's structural constraint (`α <: number`) at wake
   time. The K6c sub-case where the *current* bound already determines the
   operator does NOT defer — that work happens inline.

5. **K6e — method receiver TV.** `α:foo(...)` requires
   `α <: { foo: Tcall, ... }` and that the receiver-passed argument lines
   up. K6e currently rejects to ask for an annotation. The deferred form:
   await `α.id`; on wake, run K6e's existing dispatch once `α` has a record
   shape.

In all five cases the thunk is the same shape: a closure that re-runs the
site's normal reducer.

## §2 Suspension mechanism

### 2.1 Waiter lists live on the TV

The natural home for a waiter list is the `V4Var` itself. Each variable
already carries `lower`, `upper`, `lower_vars`, `upper_vars`. K6f adds:

- `waiters : { [integer]: DeferredConstraint }` — an id-keyed set of
  deferred constraints parked on this TV. Id-keyed because a single
  constraint may park on several TVs and we need O(1) removal when it
  wakes on one of them (the others must drop the entry).

A constraint with multiple awaited TVs appears in the `waiters` map of
each — the same record, by identity. When any one fires, the wake step
removes it from all of them before invoking the thunk (§3).

### 2.2 A global queue on the solver too

The solver gets a small extension:

- `s.pending : DeferredConstraint[]` — FIFO of constraints whose wake has
  been *triggered* but not yet run. Wake is decoupled from execution so
  that bound propagation can finish before we recursively run waiter
  thunks (avoids deeply nested re-entry into `constrain`).
- `s.next_constraint_id : integer` — for stable ids on deferred records.

**Why both.** The TV's `waiters` is the lookup index ("which constraints
should fire when this TV's bounds change?"). The solver's `pending` is the
runlist ("which deferred constraints have been woken and are ready to
re-run?"). Without `pending`, a wake during `add_lower` would have to call
the thunk reentrantly inside the propagation loop, and a thunk that calls
`constrain` would corrupt `subtype.lua`'s implicit assumption that bound
propagation completes its own loop before yielding control. With
`pending`, wake is just enqueue + bound-step continues; the outer driver
drains pending when its current obligation returns.

### 2.3 Identifying the awaited TV

A site that defers must already know *why* it is deferring — it just hit
a `tag == "var"` branch (or `mentions_free_var` reported a non-capture
var). The id is read from that var. For compound suspensions (match
subject containing several free vars in a record), the producer walks the
subject once and collects every `var.id` it would refuse to descend into;
that set becomes the awaited TVs. The walker that produces this set is
the existing `mentions_free_var` (in `match.lua`) and the existing
`mentions_var` (in `empty.lua`) — both are already separate predicates;
K6f extends them with an "id collector" variant that returns the set
instead of a boolean. Same traversal; different accumulator. Not a new
primitive — a generalization of the existing one.

### 2.4 The suspend API

```
M.defer(s, awaited_ids, resume, origin) -> nil
```

- `awaited_ids` — `{ [integer]: boolean }` set of TV ids.
- `resume` — `(V4Solver) -> "done" | "still_waiting" | "failed"`. On
  `"still_waiting"`, the thunk is responsible for calling `M.defer` again
  with its updated awaited set before returning. On `"failed"`, the thunk
  must have already populated `s.error` (with origin context, §7).
- `origin` — `{ kind, site, type_snapshot, description }`. `kind` is one
  of the rejection-site names ("index", "index_key", "match",
  "operator", "method"). `site` is the source location passed in from the
  walker. `type_snapshot` is the input type(s) at the time of suspension
  (for diagnostics; not used by the queue itself). `description` is the
  human-readable message that becomes the diagnostic if the constraint
  never wakes (§7).

`defer` inserts the same `DeferredConstraint` record into each awaited
TV's `waiters` map. The record carries its own id so all references stay
in sync.

## §3 Resumption mechanism

### 3.1 Wake triggers

A TV's bounds change in exactly these places in `subtype.lua`:
`add_lower`, `add_upper`, `link_vars`. Each is the natural wake point.
K6f extends them with a single line at the *end*: after the propagation
loop completes (i.e., after the new bound has been added and propagated
to existing bounds and linked variables), call `M.wake(s, v)`.

`wake(s, v)` moves every entry of `v.waiters` into `s.pending`,
*removing* each woken constraint from the `waiters` maps of all the other
TVs it was parked on. The TVs themselves are not modified further; only
the waiter membership changes.

### 3.2 Draining `pending`

The outer driver — `M.subtype(a, b)` — wraps the top-level constrain in a
loop:

```
constrain(s, a, b)
while #s.pending > 0 and not s.error do
  c = table.remove(s.pending, 1)
  status = c.resume(s)
  -- "done" / "failed" / "still_waiting" all leave the queue in a
  -- consistent state; "still_waiting" reparks via M.defer.
end
```

Bound propagation inside a single `add_lower` does NOT drain `pending`
itself — it just enqueues. The loop runs at obligation boundaries, where
re-entry is safe.

For solver users beyond `M.subtype` (e.g. `match.lua` calling
`ST.constrain` on a freshened arm), the same drain must happen.
The cleanest answer is to add a `M.solve(s)` step that callers invoke at
the boundary of their work — and to make `M.subtype` simply
`constrain + solve`. `match.lua`, `empty.lua`'s `pure_subtype`, and the
indexer all gain one explicit `solve` call after their inner `constrain`
work and before returning. This is *not* a per-site special case; it is
the same one-line call at every solver-owning site.

### 3.3 What "still_waiting" means

A resume that runs and discovers the obstruction is still present
(e.g. the TV is now linked to another TV, but still no `rec` in the
lower bound) reparks itself with the updated awaited set. The queue is
**not** an event log — it does not retry on every bound change forever;
it retries on the *next* change to one of the currently-named awaited TVs.

This guarantees forward progress modulo the cycle rules in §5.

## §4 API additions to v4

### 4.1 New symbols in `subtype.lua`

```
M.defer(s, awaited_ids, resume, origin) -> nil
M.wake(s, v) -> nil           -- internal but exported for tests
M.solve(s) -> ()              -- drain pending until empty or s.error
M.subtype(a, b) -> (ok, errmsg)  -- updated: now constrain + solve
```

### 4.2 New field on `V4Solver`

```
V4Solver = {
  cache: { [string]: boolean },
  error: string | nil,
  pending: DeferredConstraint[],     -- NEW
  next_constraint_id: integer,       -- NEW
}
```

### 4.3 New field on `V4Var`

```
V4Var = {
  ...existing...
  waiters: { [integer]: DeferredConstraint },   -- NEW
}
```

### 4.4 New record

```
DeferredConstraint = {
  id: integer,
  awaited: { [integer]: boolean },  -- TV ids currently parked on
  resume: (V4Solver) -> string,     -- "done" | "still_waiting" | "failed"
  origin: DeferredOrigin,
  wake_count: integer,              -- §5 termination guard
}

DeferredOrigin = {
  kind: string,         -- "index" | "index_key" | "match" | "operator" | "method"
  site: SourceLoc | nil,
  type_snapshot: V4Type[],
  description: string,
}
```

### 4.5 What changes elsewhere

- `index.lua`: the two "rejects loudly" branches (`obj.tag == "var"` and
  `analyze_key`'s var case) become `M.defer` calls. The current `(nil,
  err)` shape stays for the immediate caller — but now the err is the
  user-facing "could not finally resolve" message that fires only if the
  constraint never wakes or ultimately fails.
- `match.lua`: the suspension branches in `forward` / `backward` /
  `arm_outcome` ride the same primitive. The existing "suspended" return
  becomes the trigger to call `M.defer` rather than to surface an error.
- `K6c` (operator dispatcher) and `K6e` (method dispatch) gain the same
  conversion in their respective implementations.

No new constraint *kind* — see §3 of `typechecker-rewrite-design.md`,
"closed set of constraints is `{ <: }`". A deferred constraint is just a
thunk that, on wake, emits one or more `<:` obligations. The queue is
infrastructure, not vocabulary.

## §5 Cycle detection / termination

The MLstruct construction has a single termination argument: the bound
graph is finite, the cache prevents revisiting in-progress subtype
pairs, and structural recursion descends on syntactically smaller types
(§3.2). K6f must not break that argument.

Termination concerns introduced by deferral:

1. **A wakes → defers on β; β bind → wakes A; A re-defers on α.** A pure
   ping-pong is possible if two constraints each wait on each other.
   Mitigation: a `wake_count` field on each `DeferredConstraint`, bounded
   per constraint. Resume returning `"still_waiting"` *without changing
   the awaited set* increments `wake_count`; reaching a threshold (e.g.
   the number of distinct TV ids in `s` × a small constant) converts the
   constraint to a `"failed"` outcome with a "cycle suspected" diagnostic.
   A resume that **does** change its awaited set (different obstruction
   TV) resets the counter — that is genuine progress.

2. **Cascading wakes.** A single bound change wakes K waiters; each may
   re-enqueue more. The `pending` queue is FIFO and bounded by the
   product of (TVs × constraints-per-TV); cumulative work per top-level
   `subtype` call is finite because each thunk either makes a `<:`
   obligation that the cache discharges, or reparks (bounded by
   `wake_count`).

3. **Cache safety.** The existing `s.cache` is keyed on
   `(tostring(lhs), tostring(rhs))`. Re-running a deferred constraint
   re-emits `<:` obligations with possibly the same pair, which the
   cache will short-circuit. This is *desired* on success paths — but if
   a previous attempt at the pair had failed silently (set
   `s.error`, which the obligation owner observed and recovered from),
   the cache might claim the pair holds when it does not. Audit
   required: today's solver only writes to `cache` *before* the proof
   completes; if `s.error` becomes set the cache entry stays. K6f either
   (a) clears the cache entry when the discharge fails, or (b) keys the
   cache on `(pair, success)`. (a) is cleaner; the existing transitive
   closure already does not benefit from a stale `true` entry.

4. **No global lattice loop.** A deferred constraint's resume must
   discharge through `constrain` (which has its own termination). The
   queue does NOT itself iterate to fixpoint with arbitrary depth — each
   deferred thunk runs once per wake, plus the `wake_count` bound.

## §6 Integration plan per rejection site

Each site loses its reject-loudly branch and gains a `M.defer` call. The
walker layer above each site keeps the same `(V4Type | nil, string | nil)`
return type — but now `nil, err` is the *terminal* failure path (the
constraint genuinely could not be discharged at solver-completion time)
while in-flight deferral returns `nil, nil` (or, more honestly, a sentinel
result type that the caller substitutes with a placeholder — see §9).

### 6.1 4b.2 — indexed access on TV target

Site: `index.lua` `index = function(obj, key) ... if obj.tag == "var" then ...`.

Conversion:
- Collect `{obj.id}` as awaited.
- Build a thunk that re-calls `index(obj, key)` after wake.
- `M.defer(s, awaited, thunk, origin{kind="index", ...})`.
- Return a fresh placeholder TV `γ` to the caller; the thunk, when it
  resolves, emits `index_result <: γ` and `γ <: index_result` (the result
  TV is then equal to whatever the deferred reduction produced).

The placeholder pattern is the same trick simple-sub uses for any "result
of an operation on a TV": the result is itself a TV, with bounds populated
when the operation resolves.

### 6.2 4b.2 — indexed access with TV key

Site: `analyze_key` `tag == "var"` branch.

Same shape: await `{key.id}`, return placeholder, defer the analysis.

### 6.3 4d — match subject is a TV (or contains free vars)

Site: `match.lua` `forward` reading the `arm_outcome == "suspended"`
result.

Conversion: collect the set of free non-capture var ids from the subject
(via the id-collector extension of `mentions_free_var`, §2.3). Await all
of them. Resume re-runs `forward`. Result placeholder is a fresh TV
representing "the match's result"; on success the thunk constrains the
placeholder against the firing arm's result.

### 6.4 K6c — operator on TV operand

Site: K6c's operator dispatcher (file not read here per the rejection-site
description in the task; this section is normative for the conversion).

Conversion: when the *current bound* of the TV already determines the
operator's structural constraint, emit that constraint inline (no
deferral — this is the existing "works for current bound" path).
Otherwise, defer on the operand TV; resume re-runs the operator's
structural-constraint emission.

The discrimination "current bound determines vs does not" is per-operator
and lives in K6c; K6f provides the queue but does not legislate when an
operator may defer.

### 6.5 K6e — method receiver TV

Site: K6e's method-dispatch path.

Conversion: defer on the receiver TV; resume re-runs method dispatch.
This trivially replaces "annotate the receiver" with "wait for the
receiver to be inferred elsewhere".

## §7 Diagnostic origin handling

A deferred constraint can fail in three ways:

1. **Discharge failure on resume.** The thunk runs, the constraint
   reduces to a concrete `<:` obligation, and that obligation fails.
   *Report at the original site* — the `origin.site` recorded at defer
   time. Rationale: the user wrote `obj[k]` at line 42; that is where the
   constraint was born; the wake at line 90 (where some unrelated TV
   bound was added) is an implementation detail.
2. **Never woke.** Solving finishes (the top-level `M.subtype` drains
   `pending` to empty and exits), but the awaited TV never had a bound
   change. The constraint is still parked in `waiters`. At
   solve-completion, the driver scans for non-empty `waiters` across all
   variables referenced by the solver; any remaining deferred constraints
   are forced to a terminal failure with `origin.description` as the
   message. Report at `origin.site`.
3. **Cycle suspected.** `wake_count` exceeded threshold (§5). Report at
   `origin.site` with a "deferred constraint never converged" message
   that also lists the awaited TVs and their final bounds for inspection.

In all three cases the wake site is *not* the diagnostic site, but it MAY
be included as supplementary context ("constraint was last woken when
`α` received bound `…` at line 90"). The primary anchor is the origin.

The existing `s.error` channel carries only one error at a time; in the
"never woke" path the driver may discover multiple parked constraints.
The right shape is to emit the first one through `s.error` and surface
the rest through a separate `s.deferred_failures` list that callers can
walk for the "show all errors" mode. This matches how `M.subtype` already
treats `s.error` as the first failure.

## §8 Sub-phase breakdown

Implementation order (small, testable, each independently committable):

1. **K6f.1 — `V4Solver` and `V4Var` shape changes.** Add `pending`,
   `next_constraint_id`, `waiters` fields. No behavior change; type
   annotations updated. Tests: solver construction round-trips, existing
   subtype tests still pass.
2. **K6f.2 — Defer + wake plumbing.** Implement `M.defer`, `M.wake`,
   `M.solve`. Hook `wake` into `add_lower`/`add_upper`/`link_vars`. No
   site uses them yet. Tests: synthetic deferred constraint that fires
   when a specific TV gets a bound; cycle bound via `wake_count`;
   "never woke" diagnostic at `solve` time.
3. **K6f.3 — Cache safety audit & fix.** Make the cache entry conditional
   on success (or clear on `s.error`) per §5(3). Tests: a failed pair
   does not poison a subsequent identical pair.
4. **K6f.4 — Origin metadata pipeline.** Plumb `origin.site` through the
   walker's existing source-location pathway down into `M.defer`. Update
   `s.error` formatting; introduce `s.deferred_failures`. Tests: a
   failing deferred constraint reports at the original site, not the
   wake site.
5. **K6f.5 — 4b.2 conversion (obj is var).** Migrate the first rejection
   site. Tests: existing K6 corpus errors of this shape are reduced (or
   resolved entirely).
6. **K6f.6 — 4b.2 conversion (key is var).** Migrate the second site.
7. **K6f.7 — 4d conversion.** Migrate `match.lua` suspension paths.
   Tests: a match whose subject is a TV resolved later in the walk now
   succeeds without an annotation.
8. **K6f.8 — K6c conversion.** Migrate the operator dispatcher's deferred
   cases.
9. **K6f.9 — K6e conversion.** Migrate method dispatch.
10. **K6f.10 — Corpus measurement.** Re-run K6 discovery; expect the ~468
    indexed-access errors and the analogous match/method/operator
    errors to drop to zero (or to be re-classified as genuine type
    errors that the deferred reduction surfaced cleanly at the original
    site).

Ten sub-phases; each independently committable and testable.

## §9 Open questions

The following are honest unknowns that this design does not resolve and
that should be answered during implementation rather than guessed at now:

1. **Placeholder result TVs vs nil result.** §6.1 sketches "return a
   fresh TV as the result". The alternative is to make the API
   *constraint-position only* — `index.lua` already produces a `V4Type`,
   and a caller that needs the result for further constraints would
   plumb a TV target through. Which shape composes better with the
   walker's existing flow? Decide by trying both on the smallest 4b.2
   call site.

2. **Subject-walk scope for awaited TVs.** §2.3 says collect every free
   non-capture var id. For deeply nested types (a function inside a
   record inside the subject), that could pin a constraint on many TVs
   that have nothing to do with the actual obstruction. Is a more
   selective collector (e.g. only "directly load-bearing" TVs — the ones
   `analyze_key` or `arm_outcome` actually peeked at) worth the
   complexity? Default: collect all; revisit if benchmarks show waste.

3. **Match-arm capture-binding under deferral.** `match.lua` currently
   runs `constrain(s, subject, fresh_pattern)` to populate capture
   bounds *after* a definite fire. Under deferral, the fire decision
   itself may be deferred; the constrain-with-real-solver step then
   moves into the resume thunk. Does that interact correctly with the
   freshening of captures? Suspected yes (captures are freshened per
   evaluation, and the thunk closes over the freshened set) but unproven
   until 4d conversion is attempted.

4. **Coalescing interaction.** When a coalescing pass runs on a TV that
   has parked waiters, does coalescing constitute a "bound change" that
   should fire wakes? Probably yes — coalescing tightens what the TV
   denotes — but the v4 coalescer is not yet built. Flag for whoever
   builds it.

5. **Cross-file resolution under deferral.** `cache.lua` serializes
   inferred export interfaces. A deferred constraint that never wakes
   within a file leaves a TV with no concrete lower bound; the
   serializer must either force the deferral to a terminal failure
   (giving a clear diagnostic) or refuse to serialize while pending
   constraints exist. Choose explicitly when 4g re-touches the cache
   format.

6. **`wake_count` threshold.** §5 picks "TV count × small constant" as a
   ceiling. Is that the right shape? Probably not principled — but a
   principled bound (proof that the queue terminates absolutely) needs
   a separate termination argument tied to the bound-graph's structure.
   Until that argument exists, the threshold is a backstop; do not
   pretend it is a proof.

7. **Effects of deferral on rank-N escape checks.** `forall.lua`'s
   `find_escape` reads variables' current bounds; if a constraint that
   would have added a skolem-mentioning bound is deferred past the
   escape check, the check may pass spuriously. Suspected fix: drain
   `s.pending` (calling `solve`) *before* every escape check. Verify
   when 4e is revisited.

These are the questions that will hit during implementation; they are
intentionally not pre-resolved here. The design above is structurally
complete; these are the genuine soft spots.
