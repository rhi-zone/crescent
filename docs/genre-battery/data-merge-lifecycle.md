# Data-merge lifecycle: Factorio-style data/control-stage split for crescent

**Status: DESIGN PROPOSAL. Not committed, not built, awaiting owner sign-off.**
Every option below is presented for a decision, not as a recommendation. Where
real tradeoffs exist between options, none is marked as preferred. Nothing in
this document authorizes implementation.

This proposal covers exactly one of the multiple mod-loading paradigms named
as owner-directed/settled in `docs/genre-battery-design.md`'s "Mod-loader
shape" section: **Factorio-style structured data-merge**. It does not touch
the other paradigms (datapacks, Forge/Fabric-style code mods, Godot overlay,
Harmony-style patching) named in that document.

## Greenfield verification

Grepped `lib/` for `prototype`, `data.stage`/`data_stage`, `mod.lifecycle`/
`mod_lifecycle` (case-insensitive). No hits relate to a mod data-stage/
prototype-merge system — matches on `prototype` are typechecker term/type
prototypes, JS `Object.prototype` references in vendored fixtures, and
unrelated uses in `lib/validation`, `lib/config`, `lib/state`, etc. No
existing crescent library implements any part of this. Confirmed greenfield.

Relevant existing libraries this proposal composes with, not duplicates:

- `lib/sandbox` — capability-based script execution (`M.env(cap, ...)`,
  `M.run(code, env, opts)`). This is the existing mechanism for injecting
  caps into a chunk's environment instead of ambient globals; the control
  stage described below should be sandboxed via this library, not a new one.
- `lib/persistent` — persistent (immutable, structurally-sharing) List/
  Vector/Map. Relevant to the freeze-enforcement options below.
- `lib/fuse/readonly.lua` — existing repo precedent for the "wrap an ops
  table, reject mutating operations" pattern (FUSE read-only filesystem
  ops), structurally similar to one of the freeze-enforcement options below.
- `lib/deepcopy` — plain deep-copy utility, relevant to one freeze option.

`docs/genre-battery/sandboxing.md` and `docs/genre-battery/conflict-
arbitration.md` do not exist yet (checked: `docs/genre-battery/` is empty
except this file). This proposal names its integration points with both as
open seams, per the task's framing — it does not block on them and does not
guess at their contents.

## 1. What a prototype is, structurally

Factorio's prototypes are always `{ type = "...", name = "...", ...fields }`
keyed into `data.raw[type][name]`. Crescent needs the same shape without
hardcoding `item`/`recipe`/`entity` as first-class concepts (`type` values
must be caller-defined strings, not a closed enum in this library — the
"no special-casing" rule in `CLAUDE.md` applies here directly: any
type-keyed branching inside this library's own code would be the same
smell as a name-keyed handler in the typechecker).

**Design option A — `(type, name)` pair, both required strings.**
Direct port of Factorio's identity shape. `type` is an opaque string this
library never inspects beyond using it as a table key; `name` likewise.
Storage: `prototypes[type][name] = proto_table`. Simple, well-precedented,
and every genre-specific "system" (an items system, a recipes system) reads
its own `type` slice and ignores the rest — the library itself never knows
`item` or `recipe` exist. Cost: assumes a two-level namespace (kind, then
identifier within kind) is the right shape for every genre; a genre needing
a different key structure (e.g. a puzzle genre keying by a coordinate pair)
has to fold that into the `name` string itself.

**Design option B — single opaque `id`, `type` used for indexing only.**
Prototype requires only `type` and `id`; `id` may be any Lua value valid as
a table key (string or number), not restricted to a name-shaped string.
Storage: `prototypes[type][id] = proto_table`. Slightly more flexible than
A (numeric ids, composite ids a genre composes itself) at the cost of losing
the specific vocabulary word "name" that maps directly onto Factorio's own
docs and onto what genre authors coming from Factorio will expect.

**Design option C — `(type, name)` pair as in A, but `name` may be any
key-valid Lua value, not string-only.** Same storage shape as A, but drops
the string restriction on the second component. Splits the difference:
keeps the familiar `type`/`name` vocabulary while allowing numeric or other
hashable ids. Cost: error messages that interpolate `name` into human-
readable text (`"prototype 'name' of type 'type' already exists"`) need a
`tostring()` and may render oddly for non-string ids; string-only (A) avoids
that formatting edge case entirely.

All three options keep the rest of the prototype table fully arbitrary —
no field beyond the identity fields is inspected, validated against a
schema, or given special meaning by this library. Field-shape validation
(e.g. "a `recipe`-type prototype must have `ingredients`") is a genre-core
concern layered on top via a per-`type` validator a genre core registers,
not something this library bakes in.

## 2. Multi-pass execution model

### Scope boundary: discovery and ordering are not this library's job

Factorio discovers mods from a mods folder and computes load order from
declared dependencies. This proposal treats "which mods, in what order" as
an input this library receives already resolved — likely from whichever
mod-loader/manifest layer ends up doing dependency resolution for the
Factorio-style paradigm specifically (not designed here, not blocking on
it). This library's entry point takes an already-ordered list of mods, each
contributing zero or more functions keyed by pass name. It does not read
files from disk, does not parse manifests, does not compute topological
order.

### Pass structure

**Design option A — fixed four-stage list, mirroring Factorio exactly**
(renamed generically): e.g. `configure` (≈ `settings.lua`), `define` (≈
`data.lua`), `patch` (≈ `data-updates.lua`), `finalize` (≈
`data-final-fixes.lua`). Every mod may supply a function for any subset of
the four names; the engine runs all mods' `configure` functions in order,
then all mods' `define` functions in order, then `patch`, then `finalize`.
Well-precedented (this is the exact mechanism Factorio ships and documents,
including the documented gotcha that cross-mod prototype edits belong in
the third stage to guarantee they run after every mod's second-stage
function). Cost: hardcoding exactly four passes with Factorio-specific
*semantics* ("configure your own settings first," "define your own content
second," "patch others' content third," "fix up conflicts last") bakes in
one genre's authoring discipline as if it were a structural requirement,
which sits uneasily next to this proposal's genre-agnostic-prototype
goal in part 1.

**Design option B — caller-declared ordered pass-name list.** The library
takes an ordered list of pass names as a parameter to the top-level runner
(e.g. `run_data_stage(mods, {"configure", "define", "patch", "finalize"})`),
with no fixed count or built-in meaning attached to any name. A Factorio-
paradigm genre core would declare exactly the four names above and get
identical behavior to option A; a different genre could declare two passes,
or six. More consistent with "genre-agnostic, not hardcoded to Factorio's
specific concepts," at the cost of pushing "how many passes, and what does
each mean" up to every caller — some documentation/convention has to fill
that gap or every genre core reinvents pass semantics independently.

### Cross-mod mutation mechanism

This is the load-bearing decision. Factorio's actual mechanism: a single
global `data` table, mutated in place by every mod's chunk
(`data:extend{...}`, `data.raw.item.foo.icon = "bar"`). Crescent's
caps-first convention (`CLAUDE.md`: "no ambient globals," "caps-first,
everywhere") argues against an ambient global specifically, but doesn't
by itself resolve whether *shared mutable state* (injected explicitly
rather than ambient) is acceptable, or whether the mechanism should be
pure-functional instead. Three options, genuinely different in authoring
ergonomics, conflict-visibility, and fit with a future conflict-arbitration
layer:

**Design option A — injected shared mutable table, Factorio-faithful.**
Each mod's per-pass function receives the shared prototypes table as an
explicit argument (via `lib/sandbox`-style cap injection into the chunk's
environment, not a Lua global) and mutates it directly —
`prototypes.raw.foo.bar.field = value`. Ergonomically identical to
Factorio; every existing Factorio mod-author habit transfers directly.
Cost: this is Factorio's actual mechanism, including its actual
weaknesses — two mods writing the same field in the same pass is silently
"last one wins," with no record of who wrote what, and load-order-
sensitive nil derefs are a documented real Factorio gotcha this option
inherits unchanged. Produces no structured record for a future conflict-
arbitration layer to consume — that layer would have to reconstruct "who
wrote what" after the fact, which direct table mutation does not preserve.

**Design option B — pure patch-returning functions.** Each mod's per-pass
function receives a read-only snapshot of the current prototype state and
returns a list of structured patch operations (`{op = "set_field", type=,
name=, field=, value=}`, `{op = "add_prototype", ...}`,
`{op = "remove_prototype", ...}`) or `(nil, errmsg)` on failure. The engine
applies each mod's returned patches in order before moving to the next mod
(or the next pass sees the newly-applied state as its snapshot). No shared
mutable table exists at any point; each mod's function is a pure
transform, testable in isolation by calling it with a snapshot and
inspecting its return value. This is the natural fit for a future
conflict-arbitration layer: patches are already structured data tagged
with their origin mod, exactly the shape such a layer would want to
arbitrate over. Cost: a real authoring-ergonomics departure from Factorio's
in-place-mutation idiom — mod authors write `return {{op="set_field", ...}}`
instead of `data.raw.item.foo.field = value`, which is a bigger deviation
from the prior art this whole proposal is modeled on than option A.

**Design option C — mutable-in-appearance, recorded under the hood.** Each
mod receives what looks like a plain mutable shared table (preserving
Factorio's exact authoring idiom, same as option A) but the table is
actually a thin proxy — structurally similar to `lib/fuse/readonly.lua`'s
pattern of wrapping an ops table and intercepting specific operations,
except intercepting `__newindex` to *record* each write (which mod, which
pass, which field, old value, new value) rather than reject it — before
applying it to the underlying real table. After the data stage, the
recorded write log is available for a conflict-arbitration layer to
inspect, without changing the authoring idiom at all. Cost: proxy/
metatable overhead on every write, for the entire data stage, across every
prototype table; only catches direct field assignment through the proxy —
a mod that grabs a nested sub-table reference and hands it to a helper
function for multi-level mutation several calls deep bypasses the
recording unless every nested table is proxied too (recursive proxying:
more overhead, more complexity, and metatables nested arbitrarily deep
interacting with the freeze step in part 3 needs its own care).

Options A and C share identical authoring ergonomics; B differs. Options B
and C share good conflict-arbitration fit; A does not. No combination of
"most Factorio-faithful" and "best future-integration fit" exists among
these three — that is the actual tradeoff, not an oversight in any one
option.

## 3. Freeze boundary and control-stage read access

After the last data-stage pass, the prototype set is frozen: control-stage
code gets read access but must not be able to mutate it. Crescent's
caps-first convention favors capability injection (mechanism) over
documented convention ("don't mutate this, please") wherever a real
mechanism is available.

**Design option A — recursive immutable metatable wrapper.** At freeze
time, walk the full prototype tree and wrap every nested table (transitively)
in a proxy whose `__newindex` errors (or, to stay within the `(nil,errmsg)`
convention — see part 4's tension on this point — returns an error through
whatever access surface is used) and whose `__index` reads through to the
real data. True mechanism-level enforcement: a control-stage bug or a
malicious mod genuinely cannot write through this wrapper. Cost: wrapping
is O(total node count) once at freeze time, and every subsequent read for
the entire control-stage lifetime goes through an extra metatable
indirection — a permanent per-access tax in what may be a hot per-tick game
loop reading prototype data frequently.

**Design option B — deep-copy at the freeze boundary, plain tables
afterward.** At freeze time, deep-copy the entire prototype tree (e.g. via
`lib/deepcopy`) into a fresh set of ordinary Lua tables with no metatables
at all, and hand control-stage code that copy. Reads are native-speed plain
table access, zero indirection cost. Cost: "frozen" is enforcement by
convention only, past this point — nothing in this library stops
control-stage code that holds a reference from writing to it; the property
holds only because the (separately designed, not-yet-existing) sandboxing
layer is trusted to keep control-stage code well-behaved, or because
control-stage mutations to its own private copy are harmless in practice
(a copy, not the canonical set) — that latter point is itself something
this document is not certain of and does not resolve.

**Design option C — persistent-structure freeze via `lib/persistent`.**
At freeze time, convert the prototype tree into `lib/persistent`'s Map/
Vector structures (already implemented in this repo: path-copying,
structurally-sharing, genuinely immutable by construction — there is no
mutating operation on a persistent Map that changes the version a holder
already has; "modifying" produces a new value). Control-stage code holding
a reference to the frozen persistent Map cannot mutate the version it
holds, full stop, with no metatable-interception trick needed. Cost: read
ergonomics differ from plain Lua tables — `map:get(key)` rather than
`t[key]`, `lib/persistent`'s cons-list/trie/AVL API rather than `pairs()`
— a thin read-only accessor veneer would be needed so control-stage code
gets something closer to `t[key]`-shaped ergonomics; and every data-stage
author's plain-table prototype needs a one-time conversion cost at the
freeze boundary, proportional to total prototype data size.

None of the three is a strict improvement on the others: A pays a
permanent per-read tax for true enforcement without ergonomics cost; B has
zero read cost and zero enforcement (relies on the sandboxing layer); C
gets true enforcement with zero per-read metatable tax but requires an
ergonomics veneer and a genre-agnostic library already present in this
repo, unlike A/B which need nothing beyond `lib/deepcopy` (B) or nothing
extra at all (A, beyond the wrapping code itself).

### How control-stage code receives the frozen prototypes (not a tradeoff — applying an existing convention)

Regardless of which of A/B/C above is chosen, control-stage code should
receive the frozen prototypes the same way `lib/sandbox` already injects
any other capability: as a value passed into the sandboxed environment via
`M.env(cap, ...)` (e.g. a cap bundle `{ globals = { prototypes = frozen } }`
or an accessor-function cap `{ globals = { get_prototype = fn } }`), never
as a global reaching outside the injected env. This part is not a
three-way design choice — it's applying `CLAUDE.md`'s settled caps-first
rule and `lib/sandbox`'s existing mechanism to this specific cap. The
runtime mutable API (separate from prototypes) is injected the same way,
as a second, independent cap — the two must be separate caps so that
holding read access to prototypes never implies write access to runtime
state or vice versa.

## 4. Error handling

Per `docs/conventions.md`: `(nil, errmsg)` on failure, never throw except
for genuine programming errors. Concretely, this library needs
`(nil, errmsg)` at least at:

- A prototype table missing a required identity field (`type`/`name` or
  `type`/`id`, depending on which option from part 1 is chosen).
- A mod's data-stage pass function itself throwing a Lua error — the pass
  runner must `pcall` each mod's function and convert a thrown error into
  `(nil, errmsg)` tagged with which mod, which pass, and the original
  message, rather than letting one mod's bug crash the entire data stage
  for every other mod.
- A conflict the engine itself can detect and must refuse to silently
  resolve — e.g., under mutation-model option B (part 2), two mods'
  patches both attempting `add_prototype` for the same identity in the
  same pass is an unambiguous conflict this library can reject outright
  with `(nil, errmsg)` without needing a conflict-arbitration policy to
  decide it (arbitration matters for *field-level* conflicts on an
  existing prototype, not for two mods both trying to originate the same
  identity from nothing).

**Open tension, not resolved here:** freeze enforcement (part 3) and the
`(nil, errmsg)` convention pull in different directions. A plain Lua
assignment statement (`prototypes.foo.bar = 1`) has no return value for a
`(nil, errmsg)` pair to occupy — the only way to signal failure from inside
`__newindex` is to `error()`, which is exactly the pattern `CLAUDE.md`
says to avoid for data errors. Two ways to resolve this, not adjudicated
here:
  - Expose the frozen prototypes only through accessor *functions*
    (`get(type, name)`, no raw indexing at all) so there is never a bare
    assignment statement to intercept, and any would-be "mutate" path is
    simply absent from the API rather than present-but-blocked — control-
    stage code cannot even attempt `t.x = v` because `t` was never handed
    out as an indexable table with a settable field, only as an opaque cap
    with `get`/`list`-style methods. This fits `(nil, errmsg)` cleanly
    (there'd be no mutating method to fail) but is a bigger ergonomics
    departure from plain-table Factorio-style prototype access
    (`data.raw.item.foo`) than any of the three freeze options in part 3
    individually implies.
  - Accept that the *specific* case of "control-stage code attempted to
    mutate a frozen prototype via assignment syntax" is one of the narrow
    cases `docs/conventions.md` already carves out ("Never throw ... unless
    the call is a programming error") — attempting to write through a
    read-only capability could be classified as a programming error (the
    control-stage code holding a read-only cap and trying to write through
    it is itself the bug, not a data error), in which case `error()` from
    `__newindex` is within the stated exception rather than a violation of
    it.
This choice affects the public API shape materially (plain-table-with-
metatable vs. accessor-object-only) and is named here as a genuine open
question rather than picked, per this document's own charter.

## 5. Integration with sandboxing and conflict-arbitration (not designed here)

Both `docs/genre-battery/sandboxing.md` and `docs/genre-battery/conflict-
arbitration.md` are absent from the repo as of this writing (verified:
`docs/genre-battery/` contains only this file). This proposal names the
seams rather than guessing at either document's eventual content:

- **Sandboxing seam:** this library defines *what* gets injected into
  control-stage code (a read-only prototypes cap, plus a separate mutable
  runtime-API cap) but not *how* control-stage Lua is executed safely —
  that's `lib/sandbox`'s existing job (or whatever sandboxing.md eventually
  specifies as the "sandboxed properly" mechanism `docs/genre-battery-
  design.md`'s "Explicitly open questions" section still marks
  undesigned). This proposal is a producer of two caps; the sandboxing
  document is the consumer that decides how those caps reach untrusted
  code safely.
- **Conflict-arbitration seam:** whichever mutation-model option from part
  2 is chosen determines how easy conflict-arbitration.md's eventual job
  is. Options B and C in part 2 both naturally produce a structured record
  of "which mod changed which field" as a byproduct of normal operation;
  option A does not, and would need conflict-arbitration.md to either
  accept "no visibility into per-field authorship, only final state" as a
  real limitation, or require this library to add something like option
  C's recording proxy after the fact. This is named as a factor relevant
  to the part 2 decision, not as a reason to force that decision here —
  conflict-arbitration.md's actual requirements aren't known yet.

## Open questions for owner sign-off

Every one of these is a genuine branch point with real tradeoffs on both
sides, not a gap this document is unsure how to fill:

1. Prototype identity shape (part 1): `(type, name: string)` pair,
   `(type, id: any key)` pair, or `(type, name: any key)` hybrid.
2. Pass structure (part 2): fixed four-stage Factorio-named list, or
   caller-declared ordered pass-name list of arbitrary length/naming.
3. Cross-mod mutation mechanism (part 2): injected shared mutable table
   (Factorio-faithful), pure patch-returning functions, or a
   recording-proxy hybrid.
4. Freeze enforcement (part 3): recursive immutable metatable wrapper,
   deep-copy-then-plain-tables, or conversion to `lib/persistent`
   structures with a read-only accessor veneer.
5. How control-stage failure-to-mutate is signaled (part 4): accessor-
   function-only API (fits `(nil, errmsg)` cleanly, bigger ergonomics
   departure) vs. plain-table-with-metatable API that throws on write
   attempts (closer to Factorio ergonomics, requires treating "wrote
   through a read-only cap" as the conventions doc's "programming error"
   exception rather than a data error).

None of these five is resolved by this document. Each is presented with
its real costs on every side; picking among them is an owner decision this
proposal exists to inform, not preempt.
