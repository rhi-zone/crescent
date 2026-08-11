# Genre battery design: Factorio-model direction for game/simulation libraries

**Status: forward-looking direction, not a committed implementation plan.**
Consistent with how `docs/overview.md` already frames the game-engine
ambition ("long-term direction... distinct from, and well beyond, current
scope... nothing about this is committed or built yet"), everything in this
document is direction, not done. Two things are kept structurally distinct
throughout:

- **Owner-directed, settled direction** — the ambition itself and the
  Factorio-inspired data/control-stage split. These are decisions the owner
  has made, not proposals this doc is debating. Marked explicitly where they
  appear.
- **Not built** — no code exists for any of this. No library changes, no
  mod-loader, no reference core. This doc does not propose fixes to any
  library issue it mentions.

Don't read a "settled direction" statement as "implemented." They're
different claims.

## The ambition (owner-directed, settled)

Crescent should grow batteries-included library coverage for genres:
Terraria, Minecraft, Factorio, Zachtronics-style puzzle games ("zachlikes"),
and incremental/idle games. Three explicit success criteria:

1. **Library shelf, not a unified engine-core object.** No single
   abstraction ties everything together. Composability comes from
   independent libraries combining via plain data, per crescent's existing
   conventions (each lib copy-paste-ownable, no framework code in `lib/`,
   per `CLAUDE.md`).
2. **Gluing existing libraries into a working genre prototype should take
   ~1000 lines of code or less.**
3. **Crescent should also ship complete, playable "Factorio-style" reference
   cores per genre** — not just raw libraries — that modders/game-authors can
   fork and build on top of.

## The architectural steer (owner-directed, settled)

Follow Factorio's "everything is a mod, including the base game itself"
model, mostly. Factorio's own base-game content is defined through the same
mod API mods use, via a two-stage lifecycle:

- **Data stage** — declarative prototype definitions (items, recipes,
  entities, technologies) built by running all mods' `data.lua`,
  `data-updates.lua`, `data-final-fixes.lua` in sequential passes, so mods
  can patch each other's prototypes with no strict load order. The
  prototype set is frozen after this stage.
- **Control stage** — runtime imperative code, full API access, but cannot
  touch prototypes.

The owner's explicit qualifier: "obviously some (if not most) custom/exotic
behavior stuff would need to be code" — the data stage covers
configuration/definition; real gameplay logic legitimately lives in
control-stage code, and that is expected, not a failure of the data-driven
ideal.

## Prior art synthesis

Confidence note up front: **no platform researched publishes a canonical
"here's what's built-in vs. what you build" doc**, and **no platform has a
citable official "how much code for a simple thing" figure**. Every LOC
number below (including Factorio/Minecraft/Terraria) is a researcher's
estimate from tutorial snippets, not a measured canonical figure. Treated as
such throughout — not upgraded to fact.

### Terraria (tModLoader)

Pure C# code mods hooking a closed, non-data-driven engine. No code/data
split. Forced into version-pinned build forks (`1.4.4-stable`,
`1.4.3-legacy`, etc.) on every major engine change — took ~9 months to catch
up after Journey's End. Minimal item+tile mod: ~100-150 lines across two
files (estimate).

### Minecraft (Forge/Fabric vs. datapacks)

Two non-interoperable tracks:

- Forge/Fabric: full Java bytecode-level code mods. Forge is a broad
  abstraction API plus coremods/ATs; Fabric is a thin core plus Mixins for
  surgical bytecode patches. Both break routinely across MC versions because
  they hook concrete internals.
- Datapacks: first-party, sandboxed, JSON-only, no arbitrary code, can only
  reconfigure existing systems (recipes/loot tables/advancements/tags).
  Comparatively stable because they only reference stable data concepts.

Mojang keeps both because datapacks structurally can't add new block/item/
entity types. Minimal datapack recipe: ~10-20 lines of JSON (estimate).

### Factorio

The closest existing precedent to the owner's stated direction. Data stage
(`settings.lua` → `data.lua` → `data-updates.lua` → `data-final-fixes.lua`,
prototypes frozen after) vs. control stage (game/rendering/events API,
cannot touch prototypes). Documented gotcha: cross-mod prototype edits
belong in `data-updates.lua` (guaranteed to run after all mods' `data.lua`)
to avoid load-order nil errors. Minimal item+recipe mod: ~30-60 lines
(estimate).

### Cross-genre-game synthesis

Terraria's and Minecraft's code-mod tracks both pay for lack of data/code
separation in constant breakage. Minecraft's datapack layer is the one other
precedent for a code/data split, but it's a bolted-on reduced sandbox, not
integrated with the code track. Factorio is the only one of the three with a
first-party, single-language, staged separation with a documented
cross-mod-conflict-resolution mechanism.

### Platform prior art (VRChat/Udon, Resonite/ProtoFlux, Roblox, Hytale, GMod/Source/S&box)

- **Visual-node vs. text-scripting is a live, contested choice.**
  VRChat/Resonite chose visual graphs specifically as an
  untrusted-multiplayer-content sandbox. Hytale explicitly *rejected*
  embedded text scripting even for accessibility — "script languages like
  Lua are still programming languages... less inclusive and increases
  complexity for both sides" (Technical Director Slikey, official post,
  November 2025 — the clearest design-rationale document found across all
  platforms researched). Roblox and GMod went full scripting language and
  each grew a distinct, documented security/conflict problem as a result:
  Roblox had roughly 7 years of client-trust exploits before
  FilteringEnabled became mandatory; GMod has a documented recurring problem
  of `hook.Add` ID collisions between addons.
- **Every visual-node platform that cared about performance ended up
  compiling to bytecode/acceleration structures rather than tree-walking**
  (Resonite's ProtoFlux, VRChat's Udon VM) — and still paid a steep
  sandboxing tax. Udon measured 200-1000x slower than native C#. VRChat
  announced then cancelled a "Udon 2" rewrite after concluding the
  marshalling overhead would erase the win — a rare public engineering
  post-mortem.
- **S&box** (Source 2-based, not from scratch) replaced Source's
  client/server entity split with a GameObject+Component model. Garry
  Newman's stated rationale for building it was economic ("GMod was a dead
  end for developers — skills aren't transferable"), not technical — no
  sourced link to GMod's specific hook/perf pain points.

### Relevance to crescent

Crescent is Lua-native already — all libs are Lua — which is directly
relevant: Factorio's own mod API is Lua, so crescent doesn't face the "which
language" question other platforms did. But the visual-node-vs-text-scripting
question these platforms grappled with is still real for crescent's
*control stage* specifically: should exotic per-entity/per-recipe behavior
be authored as Lua functions directly, or via some higher-level authoring
layer? Flagged as open in "Explicitly open questions" below — prior art
shows real, divergent outcomes from this choice on other platforms, but
none of it resolves the question for crescent.

## Internal audit

### Corrections to earlier casual inventory claims

`lib/chess` and `lib/mahjong` **do not exist**. `TODO.md` (~5110-5114) lists
them unchecked; `docs/batteries.md` (~2141-2153) describes them
aspirationally, not as shipped. Only `lib/solitaire` is a real working
instance of the "headless rules + multi-frontend" pattern — a proven pattern
with exactly one real example, not three.

### Genre gap map

Verified against `lib/` and `docs/batteries.md` (~2156-2176).

- **Terraria** — `lib/tilemap`, `lib/physics_2d`, `lib/behavior_tree`,
  `lib/steering`, `lib/cellular_automata` are reusable-ish (see quality
  caveats below). Inventory/items and crafting/recipes are flat gaps — no
  library found.
- **Minecraft** — same inventory/crafting gaps. Additionally, no voxel/3D-grid
  library exists at all: `lib/geometry_3d` is continuous-space math only, no
  voxel representation. `lib/noise_gen` exists but wasn't read in depth
  (unverified).
- **Factorio** — `lib/tilemap` is too narrow for multi-tile/rotation/footprint.
  Item/inventory, recipe/crafting-graph, belt/conveyor, and power-network are
  all flat gaps. `lib/network_sim` is a distributed-systems consensus
  simulator, **not** a power/logistics network despite the name — a real
  naming-collision trap for future readers. `lib/flow_network` could underlie
  throughput math but is single-commodity only (see quality caveats) and
  isn't wired to any game concept.
- **Zachlikes** — strong fits exist: `lib/constraint_solver` (CSP), `lib/sat`
  (DPLL), `lib/vm` (a TIS-100-shaped stack VM), `lib/logic_circuit`
  (gates/flip-flops/Quine-McCluskey) — but see quality caveats below, several
  have closed extension surfaces that block genre use. No chemistry/bonding-
  graph library for Opus-Magnum/SpaceChem-style molecule rules. No
  scripted-input/replay/scenario-fixture library for puzzle validation
  (`docs/batteries.md` confirms "playtesting tooling: not started").
- **Incrementals** — `docs/batteries.md` (~2161-2162) explicitly states
  resource-accumulation curves, offline-progress calc, unlock/prestige
  trees, cost-scaling formulas are "not started." `lib/decimal`, `lib/bigint`,
  `lib/bignum` are plausible numeric building blocks but weren't read in
  depth (unverified). No offline-catchup computation exists anywhere.

### Duplication status

`lib/ecs` (SQLite-backed, persistence-shaped) vs. `lib/entity_component`
(in-memory ECS) have genuinely overlapping claims. This is already an open,
unresolved question in `docs/roadmap.md` (~169-173) and
`docs/sprint-2026-04-10.md` (~159-165) — not resolved here. The genre-core
ambition raises the stakes: see "Prerequisites" below.

Five parallel FSM implementations exist (`lib/fsm`, `lib/state_machine`,
`lib/statemachine`, `lib/state_machine_hsm`, `lib/state`) — confirmed
orthogonal to every genre's needs. Not a blocker, existing debt.

### Quality audit of the libraries flagged reusable above

Read from actual source, not just descriptions.

- **`lib/tilemap`** — solid foundation. One fixable bug: throws via `error()`
  on bad seed/opts instead of `(nil, errmsg)`, inconsistent with the rest of
  the same file. Flat rectangular grid only, hardcoded 4/8-dir neighbors and
  a hardcoded diagonal-cost literal — no hex/iso path without a parallel
  library.
- **`lib/physics_2d`** — usable but needs rework. Body rotation is integrated
  but never actually used in box-box or circle-box collision — boxes always
  collide axis-aligned regardless of simulated spin, a correctness bug
  hiding behind a feature that looks implemented. Unconditional O(n²)
  all-pairs collision detection, no broad-phase tier at all — violates
  crescent's own tiering principle at any scale beyond a few dozen bodies.
  Only circle/box shapes.
- **`lib/ecs`** — not usable as claimed for genre work. SQLite-backed
  persistence (every op is a SQL statement plus JSON encode/decode, full
  table scan per query) — a fine persistence layer, mislabeled as a
  genre-reusable ECS.
- **`lib/entity_component`** — solid foundation for small/moderate entity
  counts. Query/run always uses the first named component's store as
  candidate set with linear membership checks on the rest — no
  archetype/bitset indexing, won't scale to Factorio-density sims without
  real indexing work. Real landmine: component defaults are shallow-copied
  "one level deep" per its own comment — nested-table defaults get shared by
  reference across entities, an undisclosed mutation bug.
- **`lib/vm`** (TIS-100-like) — usable but needs rework. Correctly
  implements its instruction set, but `handlers` is a closed module-local
  table with no registration API (extending opcodes means forking source),
  and it has no I/O ports or multi-node linking at all — TIS-100's defining
  feature (inter-node communication) doesn't exist; this is an isolated
  single-VM stepper, not a TIS-100-like system. Throws via bare `error()` on
  stack underflow/unknown label/div-by-zero/unknown opcode — exactly the
  inputs a puzzle player's authored program would trigger, and exactly the
  case needing `(nil, errmsg)` instead. `PRINT` calls `print()` directly — no
  injected output cap.
- **`lib/constraint_solver`** — solid foundation for binary CSPs only.
  Ternary constraints are hardcoded to arity-exactly-3 via a
  documented-as-workaround special case, forking the search into
  near-duplicate backtrack functions selected by a boolean flag; AC-3
  pruning never sees ternary constraints at all. No n-ary path exists.
- **`lib/logic_circuit`** — usable but needs rework. Tested core (8 real gate
  types, Quine-McCluskey) is solid, but `GATE_FNS` is a closed
  non-extensible table with no `register_gate`, `DEMUX` is a stub that just
  returns its first input (doesn't demultiplex), `gate_n` and `bus` are
  vestigial passthroughs whose own comments admit they don't do multi-bit
  evaluation — and all of this broken/vestigial surface is exactly the
  untested surface. Blocks Minecraft-redstone/Factorio-circuit-style genres
  specifically.
- **`lib/flow_network`** — solid foundation for single-commodity flow only.
  Every edge carries one scalar capacity — multi-resource Factorio-style
  logistics needs a different edge/residual structure, not N parallel
  instances. `bipartite_matching` encodes node identity via string-prefix
  concatenation parsed back by substring — collides if caller IDs already
  start with `"L:"`/`"R:"`.
- **`lib/geometry_3d`** — usable but needs rework for the genre claim
  specifically. Solid continuous-3D math (ray/triangle/sphere/AABB/plane
  intersection), but has zero voxel/grid representation or grid-DDA
  traversal — "Minecraft-like voxel raycasting" doesn't exist in this file
  despite being a natural-seeming fit. Mesh functions assume triangles
  unconditionally, silently wrong on quads/n-gons.
- **`lib/game_math`** — solid foundation in isolation. `vec2`/`vec3`
  `__mul`/`__div` throw via `error()` on ambiguous ops instead of
  `(nil, errmsg)`, undocumented as a deliberate convention exception. Its
  `mat4` is column-major while `lib/geometry_3d`'s `mat4` is row-major — the
  two "3D math" libraries in the same repo are not composable without manual
  transposition and metatable-stripping. A real interoperability trap, not a
  hypothetical.

### Cross-cutting pattern

Three libraries — `lib/vm`, `lib/constraint_solver`, `lib/logic_circuit` —
share the same structural flaw: a closed, module-local dispatch table or
hardcoded arity with no public registration/extension API, undisclosed in
headers. This is directly relevant to the "everything is a mod" direction: a
data/control-stage split is worthless if the underlying libraries a mod's
control-stage code would call are themselves closed to extension.
Extensibility of the substrate libraries themselves is a prerequisite this
doc names explicitly (below), not just the mod-loader architecture on top.

## Prerequisites the genre-core ambition surfaces

Named, not resolved — none of these are proposals for a fix in this doc.

- **ecs/entity_component duplication.** Already open in
  `docs/roadmap.md`/`docs/sprint-2026-04-10.md`. Genre work adds a concrete
  forcing function: it needs a real per-tick component store, and neither
  existing library is it as-is (`lib/ecs` is SQL-per-op persistence,
  `lib/entity_component` has no archetype indexing and a shared-reference
  mutation bug on nested defaults).
- **Closed-dispatch-table libraries.** `lib/vm`, `lib/constraint_solver`,
  `lib/logic_circuit` need an extension mechanism before they're usable as
  mod-extensible substrate, if the "everything is a mod" model is meant to
  extend that deep into the library layer.
- **game_math/geometry_3d convention divergence.** Row-major vs.
  column-major `mat4` needs resolving before either is safely used as the
  base math layer for a 3D genre core.

## Explicitly open questions

Not to be guessed at in this document.

- What exactly does "1000 lines" measure? Control-stage glue code only?
  Including data-stage prototype definitions? Per whole genre prototype, or
  per individual mod?
- Which genre gets the first reference core? The audit found zachlikes has
  the strongest existing library fits and Factorio the most flat gaps — this
  is an observation about current library coverage, not a recommendation.
  The owner picks.
- Does the data-stage/control-stage split become a new dedicated library (a
  "mod loader"/"prototype registry"), or a convention documented for library
  authors to follow?
- Does crescent's control-stage authoring stay plain Lua functions (the
  natural fit given crescent is Lua-native and Factorio itself uses Lua), or
  does it need a higher-level authoring layer? Prior art shows this exact
  choice caused real, divergent problems on other platforms — Roblox/GMod
  security and conflict issues from full scripting, Hytale's explicit
  rejection of text scripting, visual-node platforms paying a steep
  performance tax. No recommendation follows from that; it's a live
  tradeoff, not a settled answer.

## Out of scope for this document

No fixes to any flagged library issue. No mod-loader implementation. No
reference-core implementation. No resolution of the open questions above.
