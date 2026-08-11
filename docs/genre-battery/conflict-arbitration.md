# Conflict-arbitration/ordering layer for function-wrapping mods

**Status: PROPOSAL — awaiting sign-off. Not implemented. No lib/ code exists
for this yet.**

Scope note per `docs/genre-battery-design.md` ("Harmony-style modding in Lua
is a smaller problem than in .NET"): crescent does not need IL-patching
mechanics — `orig = t.f; t.f = function(...) ... end` already works, free, in
plain Lua. What's missing is the coordination layer Harmony's
`[HarmonyPriority]`/`[HarmonyBefore]`/`[HarmonyAfter]` annotations provide:
letting N independently-authored mods declare relative order over wraps of
the same function, chaining those wraps predictably, and making the result
introspectable and reversible. This document designs that layer only.

## Existing lib/ survey (no reuse found — reasoning below)

Grepped `lib/` for hook/middleware/advice/aspect naming. Two libraries are
close enough in *shape* to check in detail; both read as false positives
against this problem, same class as the `lib/network_sim` naming collision
noted in the task:

- **`lib/mediator/init.lua`** — commands/queries/events/middleware. Its
  `:use(name_or_mw, mw)` builds a wrap chain via nested closures
  (`lib/mediator/init.lua:63-86`), which is structurally the closest thing in
  the repo to "chain multiple wraps." But: order is strictly FIFO by
  registration (`-- FIFO order (first registered = outermost)`, line 8), no
  priority/before/after concept, no mod identity attached to a registration,
  no introspection of "who's registered," and no `off`/remove for a specific
  middleware entry (only events via `:off`/`handle:remove()` support
  removal — middleware does not). It is a dispatch pipeline for a mediator's
  own named commands, not a wrapper over pre-existing arbitrary functions.
- **`lib/pubsub/init.lua`** — topic-pattern event bus, also has middleware.
  Multiple independent subscribers per topic, but again no ordering hints
  beyond registration order, no identity, fan-out semantics (all handlers
  run, no chain-with-short-circuit contract), not built around wrapping an
  existing function's return value.

Neither is a fit to extend: both lack the core primitive this problem needs
— a *named* patch with declared ordering constraints relative to *other
named patches*, resolved before dispatch, over a *single target function*
with a defined return-value contract through the chain. Building this as a
third, distinct library (not a refactor of mediator/pubsub) is consistent
with `CLAUDE.md`'s "when one implementation can't satisfy all legitimate use
cases, provide multiple" — this is a different use case (patch arbitration
over foreign functions) from mediator's (dispatch for the mediator's own
named commands) and pubsub's (fan-out notification).

No other library in the hook/middleware/aspect grep sweep (`http/server`,
`git`, `ljsocket`, `https/client`, `type/static/*`, `sandbox`, `websocket`,
`taskgraph`, `platform/daemon`, `web`, `notify`, `realtime`, `pool`,
`layout`, `scheduler`, `task_runner`, `connection_pool`, `game_math`,
`state_machine`, `reactive_store`, `workflow`, `js_pack_validator`,
`bookkeeping`, `fractal/*`, `pdf/font`) addresses cross-mod ordering over a
shared target function; the grep hits there are either literal use of the
word "hook" in an unrelated FFI/HTTP sense, or unrelated pattern-matching
hits ("aspect" as in aspect ratio in `game_math`/`layout`). Confirmed by
reading, not assumed from the name match.

## Vocabulary

- **Target**: the function being wrapped (`t.f`, a module-table field, or any
  Lua function value reachable by the caller).
- **Patch**: one mod's wrap of one target — a prefix and/or postfix function,
  attached to a **mod id** (a string the registering mod supplies) and an
  ordering declaration.
- **Chain**: the composed function actually installed at the target's slot,
  built by walking all currently-registered patches for that target in
  resolved order.

## 1. Registration API shape

Modeled on Harmony's prefix/postfix/priority/before/after vocabulary (per
`docs/genre-battery-design.md`'s Harmony section), adapted to Lua's
value-level functions instead of method/annotation reflection:

```lua
local arbiter = require("conflict_arbitration")

-- one arbiter instance per (or shared across) target function.
local patch, err = arbiter.wrap(target_table, "field_name", {
  mod_id   = "my_mod",       -- required, unique per patch on this target
  prefix   = function(...) ... end,  -- optional: runs before orig, can short-circuit
  postfix  = function(result, ...) ... end, -- optional: runs after orig, can transform result
  priority = 100,             -- optional, default e.g. 0; higher runs earlier among prefixes
  before   = { "other_mod" }, -- optional: this patch's prefix must run before other_mod's
  after    = { "other_mod" }, -- optional: this patch's prefix must run after other_mod's
})
if not patch then
  -- err is a string; registration failure (e.g. cycle) never throws
end
```

`arbiter.wrap` reads `target_table[field_name]` as the current value (whether
that's the raw original or an already-installed chain from a prior patch),
records the patch, recomputes chain order, and reinstalls the composed
function at `target_table[field_name]`. `before`/`after` name other mods'
`mod_id`s, mirroring Harmony's `[HarmonyBefore]`/`[HarmonyAfter]`; `priority`
is a total-order fallback when no explicit before/after applies, mirroring
Harmony's `[HarmonyPriority]`.

Open point deliberately left to the options section below: whether
`before`/`after` apply per-role (prefixes ordered among prefixes, postfixes
among postfixes — Harmony's actual model) or as a single ordering over the
whole patch. See Option A vs. B.

## 2. Composition at call time

Two substantively different shapes considered; this is a real design fork,
not a settled call:

**Explicit chain data structure, rebuilt on every registration/removal.**
`arbiter.wrap` maintains a list of patch records per target (not per-call
closures). On registration or removal, it re-derives a total order from the
priority/before/after constraints and rebuilds *one* dispatcher closure that
walks the ordered list, then installs that single closure at the target
slot. Nested nesting is bounded to one extra frame per prefix/postfix
regardless of patch count — the dispatcher is a loop, not a stack of N
closures.

```
dispatcher(...):
  args = {...}
  for each prefix in order:
    ok, args_or_result, skip = prefix(unpack(args))
    if skip: return args_or_result  -- short-circuit, orig and postfixes not run
    if args_or_result ~= nil: args = args_or_result  -- prefix may rewrite args
  result = orig(unpack(args))
  for each postfix in order:
    result = postfix(result, unpack(args))  -- postfix may rewrite result
  return result
```

This is the shape that makes introspection (item 4) and removal (item 4)
possible without walking nested closures — the ordered list *is* the
introspectable state, and removal is "delete from list, rebuild dispatcher,"
never "unwind a closure chain."

**Nested closures (mediator's existing pattern).** Each new patch wraps the
previously-installed function: `new_chain = function(...) return
patch(prev_chain, ...) end`. Simpler to implement (this is what
`lib/mediator/init.lua:63-86` already does), but two structural costs for
this specific problem: (a) removal of a specific mod's patch mid-chain
requires unwrapping and re-wrapping every closure above it, since each
closure's `prev_chain` upvalue is baked in at creation time — undoing patch 3
of 5 means rebuilding closures 4 and 5; (b) introspection ("which mods are
wrapping this, in what order") requires either walking closure upvalues
(fragile, relies on debug library / implementation detail) or maintaining a
parallel metadata list anyway — at which point the metadata list should just
be the source of truth, which is the explicit-chain design.

Given (a) and (b), nested closures do not independently satisfy requirements
(c) introspection and (d) removal from the task; an explicit ordered list
that the dispatcher walks satisfies both directly. This narrows the two
composition shapes to one for the purposes of this design, but is stated
here as a reasoned narrowing, not asserted as uncontestable — a
reviewer could still choose nested closures plus a separately-maintained
metadata list, which is possible but duplicates state that the explicit-list
design keeps single-sourced.

**Return values and side effects through the chain**: prefixes can either
pass through (return nothing / return only rewritten args) or short-circuit
(signal "skip orig and remaining prefixes, this is the final result") —
mirroring Harmony's own prefix return-value contract (a Harmony prefix
returning `false` skips the original method). Postfixes always run in order
and each receives (and may transform) the running result, mirroring
Harmony's postfix chaining. Side effects (mods doing I/O or mutating shared
state inside prefix/postfix) are not sequenced or isolated by the arbiter
beyond call order — same class of caveat Harmony itself carries; the
arbiter guarantees *order*, not effect isolation.

## 3. Conflict/ambiguity handling

Per `docs/genre-battery-design.md`, Harmony's own order is "adaptive and
prioritized," not fully deterministic without explicit ordering hints — two
mods patching the same method with no explicit ordering hit documented,
real unpredictability. Crescent has to choose a stance here; this is named
as an open tradeoff, not resolved by this document (see options below for
the concrete alternatives and their costs). The dimensions of the choice:

- **Accept the same ambiguity class as Harmony**: when two patches have no
  explicit before/after relationship and equal priority, order between them
  is unspecified (e.g. resolved by registration order as a tiebreak, but not
  contractually guaranteed to stay stable across a mod-list reorder or
  crescent version bump). Cheapest to build; matches prior art; but
  reproduces the exact class of pain (`docs/genre-battery-design.md` cites
  "unpredictable patch interaction with no explicit ordering") that made
  Harmony Patch Scanner-style tooling and BepInEx/HarmonyX#64 (patch
  registry feature request) necessary in the .NET ecosystem.
- **Stricter: require every pair of patches on the same target to be
  resolvable to a total order**, and reject (via `(nil, errmsg)`, never a
  runtime crash) any registration that would leave the target's patch set
  ambiguous, unless the registering mod explicitly opts into "unordered
  relative to X" for a named patch. This trades ease of adding a patch
  (a new mod might need to add explicit `before`/`after` hints against
  mods it didn't know about, or the registration fails) for full
  reproducibility — same tradeoff a build-system-style topological sort
  makes vs. an unordered set. Also demands a well-defined answer to "what
  counts as a real ambiguity" (do two patches with different priorities
  count as ordered, or only explicit before/after?) — that's a semantic
  decision the options below split on.

**Cycles**: regardless of which stance is chosen, a circular before/after
declaration between two or more mods (A before B, B before A) must be
detected at registration time and reported as `(nil, "cycle detected: A ->
B -> A")` or similar — never a stack overflow, infinite loop, or thrown
error. This is unconditional per the task's error-handling requirement and
per crescent's `(nil, errmsg)` convention (`CLAUDE.md` "Library
Conventions"); topological-sort-with-cycle-detection is the standard
technique and applies identically whichever stance is picked.

## 4. Introspection / removal API

Because the composition model (item 2) keeps an explicit per-target ordered
list of patch records as the source of truth, introspection and removal
both reduce to operations on that list, not on the installed closure:

```lua
local patches, err = arbiter.list(target_table, "field_name")
-- patches: array of { mod_id, priority, before, after, has_prefix, has_postfix }
-- in currently-resolved call order; nil, err if target/field never wrapped

local ok, err = arbiter.remove(target_table, "field_name", "my_mod")
-- removes my_mod's patch record, rebuilds and reinstalls the dispatcher
-- from the remaining patches. ok = true, or nil, err (e.g. "no patch
-- registered for mod_id 'my_mod' on this target").
```

`arbiter.remove` operating on the record list rather than unwinding closures
is what makes "undo one mod's wrap without disturbing others" well-defined:
the remaining N-1 patches keep their own before/after/priority relationships
to each other unchanged, and the dispatcher is rebuilt from scratch off the
remaining set — there's no "hole" left by removing the middle of a closure
chain the way there would be under the nested-closure composition model.

`arbiter.list` is also the direct language-level answer to the
Harmony-ecosystem gap the design doc cites: BepInEx/HarmonyX#64 asks for a
patch registry because Harmony has no built-in way to see who's patching a
method; third-party tools (Harmony Patch Scanner) exist to fill that gap.
Crescent's version has this as first-class API, not bolted-on tooling,
because the explicit-list design already needs the data to compute order.

## 5. Error handling

Per crescent convention (`CLAUDE.md` "Library Conventions": `(nil, errmsg)`
return, never throw from data errors), every registration/removal/query
function returns `(result, nil)` on success or `(nil, "message")` on
failure. Concretely, `arbiter.wrap` must reject (not throw) at minimum:

- duplicate `mod_id` re-registering on the same target without an explicit
  replace/update call (ambiguous intent otherwise),
- a `before`/`after` reference to a `mod_id` that has no patch on this
  target at registration time (whether this is an error or a no-op
  constraint is itself an open call — see options),
- any cycle in the before/after graph across all patches on the target,
  detected via topological sort,
- (under the strict ordering stance only) any pair left unresolvable after
  topological sort.

None of these are "ordinary registration conflicts" in the sense of a
runtime crash — they're expected, recoverable outcomes a mod author's own
code should check and handle, consistent with the task's explicit
requirement that circular before/after constraints be a reported error, not
an exception.

## Design options (no winner picked)

### Option A — Harmony-parity: per-role ordering, loose (Harmony's own stance)

Prefixes are ordered among themselves via priority/before/after; postfixes
are ordered among themselves independently (a patch's prefix and postfix are
not coupled in ordering — this matches Harmony, where prefix and postfix
patch lists are each their own priority queue). Ambiguity stance: loose
(unordered pairs allowed, resolved by a documented but non-contractual
tiebreak such as registration order). `before`/`after` referencing an
unregistered `mod_id` is *not* an error — it's a constraint that simply has
no effect until/unless that mod also patches the target, so patch order
doesn't depend on load order between mods that both know about each other.

- *Pro*: closest to Harmony, so any documentation/intuition mod authors
  bring from Harmony/BepInEx transfers directly; permissive registration
  never blocks a mod from loading over an ordering technicality.
- *Con*: reproduces Harmony's own documented ambiguity class
  ("adaptive and prioritized," not fully deterministic) — crescent inherits
  the same silent-reorder-across-versions risk BepInEx/HarmonyX#64 exists
  to paper over.

### Option B — Single ordering, strict, fail-closed

One ordering per patch (no prefix/postfix split — a patch's before/after
applies to its whole slot in the chain, prefix and postfix both). Ambiguity
stance: strict — registration fails with `(nil, errmsg)` if the new patch's
position relative to any existing patch on the same target can't be
resolved by priority or explicit before/after, forcing the registering mod
(or a coordinating layer) to disambiguate explicitly. `before`/`after`
referencing an unregistered `mod_id` *is* an error at registration time
(fails fast on typos/renamed mod ids) but is re-validated (not re-required)
whenever the target's patch set changes.

- *Pro*: no silent nondeterminism — if `arbiter.wrap` succeeds, the chain
  order is fully pinned and reproducible across runs/reorders; introspection
  output (`arbiter.list`) is a complete explanation of behavior, not a
  partial one.
- *Con*: load-order-sensitive failures — mod C's registration can fail
  depending on whether mods A and B were already loaded and what they
  declared, which is a worse failure mode for a modder than Harmony's
  "it works, just maybe not in the order you expected"; requires every mod
  author to know about conflicting mods in advance or requires a
  coordinating "load order" concept above this layer (out of scope here,
  per the task boundary) to pre-declare mod-vs-mod relationships.

### Option C — Priority-bucketed, deterministic tiebreak, no strict rejection

Keep Harmony's priority/before/after vocabulary and *never* reject a
registration for ambiguity, but make the tiebreak for unordered pairs fully
deterministic and documented (e.g. `mod_id` lexicographic order, not
registration order) instead of Option A's "resolved but not contractual"
stance. `before`/`after` referencing an unregistered mod behaves as in
Option A (constraint dormant until that mod appears).

- *Pro*: keeps Option A's permissiveness (nothing ever fails to register
  over ordering) while removing the specific pain Harmony has — order is
  always reproducible given the same set of registered mods, because the
  tiebreak is a pure function of mod_id, not registration sequence (which
  can vary run-to-run depending on file scan order, plugin discovery order,
  etc.).
- *Con*: "deterministic but arbitrary" (lexicographic mod_id order) is still
  not "correct" in the sense the mods' authors intended if neither declared
  a preference — it just guarantees the same wrong-per-nobody's-intent order
  every time rather than a possibly-different wrong order each time. Doesn't
  solve the underlying coordination problem, only its irreproducibility.

All three keep the same registration API shape (item 1), composition model
(item 2, explicit ordered list + rebuilt dispatcher), introspection/removal
API (item 4), and `(nil, errmsg)` error convention (item 5) — they differ
only in the ordering-scope split (per-role vs. whole-patch) and the
ambiguity stance (loose/tiebreak-only vs. strict-reject vs.
loose/deterministic-tiebreak). That narrower disagreement is the actual
decision this proposal is surfacing for sign-off.
