-- examples/tile_sandbox/world.lua
-- Pure world/logic layer for the tile-sandbox demo: composes lib/tilemap
-- (grid storage) with lib/entity_component (player entity) into a tiny
-- walkable, block-placing world. No I/O here -- rendering and input live in
-- main.lua.
--
-- Player position/facing is stored as a FLAT component (x, y, facing_dx,
-- facing_dy -- all numbers). lib/entity_component's registered-component
-- defaults are shallow-copied one level deep, so a nested-table default
-- (e.g. { facing = { dx, dy } }) would alias across every entity that
-- takes the default. Flat scalar fields sidestep that bug entirely rather
-- than working around it with a per-entity deep copy.
--
-- TYPECHECKER WORKAROUND: functions here that touch the lib.tilemap
-- TileMap object past its documented alias surface are deliberately left
-- WITHOUT a `--:` signature. lib/tilemap's `TileMap` alias only lists
-- `in_bounds`, `get`, `set`, `fill` -- it omits `fill_border`, `width`,
-- `height`, and most of the module's other public methods. A properly
-- narrowed `TileMap`-typed value therefore fails "field doesn't exist"
-- for any of those omitted methods. Worked around here by only calling
-- the four aliased methods (no fill_border/width/height) and keeping our
-- own MAP_W/MAP_H constants instead of querying the map for its
-- dimensions. This is a lib/tilemap gap (incomplete `TileMap` alias),
-- not a bug in this file's logic -- see TODO.md.
--
-- (A previously-suspected second gap -- that entity_component's `M.world()`
-- return object was structurally disjoint from a hand-written `World`-style
-- alias -- turned out to be a different bug: colon-defined methods
-- (`function World:emit(...)`) desugar to a real `self` parameter, so their
-- field type on the table (read through the `__index` chain) legitimately
-- includes `self` as the first parameter -- exactly as the checker's own
-- colon-call sites supply it. The alias entity_component originally shipped
-- (`WorldObj`) omitted `self` from its method signatures, unlike every other
-- hand-written method-bearing alias in this codebase (`lib/db`, `lib/http`,
-- `lib/aho_corasick`, etc., which all write `self: T` explicitly). Fixed by
-- correcting `WorldObj` in lib/entity_component/init.lua to match that
-- convention -- see TODO.md and lib/entity_component/init.lua. `build_world`
-- and `player_position` below are annotated now that this is fixed.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local tilemap = require("lib.tilemap")
local ecs     = require("lib.entity_component")

--:: require "lib.entity_component"

-- Player position/facing component shape. entity_component's World:get is
-- generic (`<T>(WorldObj, integer, string) -> T | nil`) since component
-- storage is untyped from the ECS's point of view (registered defaults are
-- caller-supplied) -- this alias documents the concrete shape this demo
-- actually registers under "position", and player_position below is the
-- one boundary where that dynamic component data becomes typed demo data
-- via a checked cast plus a nil guard (not a force cast).
--:: Position = { x: number, y: number, facing_dx: number, facing_dy: number }

local M = {}

-- ---------------------------------------------------------------------------
-- Tile vocabulary
-- ---------------------------------------------------------------------------

--: number
M.TILE_FLOOR = 1
--: number
M.TILE_WALL = 2
--: number
M.TILE_BLOCK = 3

M.MAP_W = 12 --: number
M.MAP_H = 8  --: number

-- ---------------------------------------------------------------------------
-- Map construction
-- ---------------------------------------------------------------------------

--- Build the fixed, hand-authored demo map: a bordered room with a couple
--- of interior wall tiles to walk around. Deliberately not using
--- tilemap.random_rooms/cellular_automata -- both error() on missing/odd
--- opts.seed, and a fixed layout is all this demo needs. Border is built
--- with four `fill` calls rather than `fill_border` -- see the file-level
--- TYPECHECKER WORKAROUND comment.
function M.build_map()
  local map, err = tilemap.new(M.MAP_W, M.MAP_H, { default_tile = M.TILE_FLOOR, tile_size = nil })
  if map == nil then
    error("tile_sandbox: failed to build map: " .. tostring(err))
  end
  map:fill(0, 0, M.MAP_W, 1, M.TILE_WALL)
  map:fill(0, M.MAP_H - 1, M.MAP_W, 1, M.TILE_WALL)
  map:fill(0, 0, 1, M.MAP_H, M.TILE_WALL)
  map:fill(M.MAP_W - 1, 0, 1, M.MAP_H, M.TILE_WALL)
  map:set(4, 3, M.TILE_WALL)
  map:set(4, 4, M.TILE_WALL)
  map:set(7, 5, M.TILE_WALL)
  return map
end

-- ---------------------------------------------------------------------------
-- World / player construction
-- ---------------------------------------------------------------------------

--- Build the ECS world and the single player entity.
--: () -> (WorldObj, integer)
function M.build_world()
  local world = ecs.world()
  world:register("position", { x = 1, y = 1, facing_dx = 1, facing_dy = 0 })
  local player = world:entity()
  world:add(player, "position", { x = 2, y = 2 })
  return world, player
end

--- Read the player's position component. build_world() always registers
--- and adds "position" for the player right after creating it, so this
--- component is always present in practice -- the nil branch below covers
--- the case entity_component's `get` can't rule out statically (wrong
--- entity id, component never added), not a normal code path here.
--: (WorldObj, integer) -> Position
function M.player_position(world, player)
  local pos = world:get(player, "position") --[[: Position | nil]]
  if pos == nil then
    error("tile_sandbox: player " .. tostring(player) .. " has no position component")
  end
  return pos
end

-- ---------------------------------------------------------------------------
-- Movement
-- ---------------------------------------------------------------------------

--- Attempt to move the player by (dx, dy) (one of the four cardinal unit
--- vectors). Facing always updates to the attempted direction, even when
--- the move itself is blocked by a wall or the map edge -- so bumping into
--- a wall still turns the player to face it.
function M.try_move(world, player, map, dx, dy)
  local pos = M.player_position(world, player)
  pos.facing_dx = dx
  pos.facing_dy = dy
  local nx, ny = pos.x + dx, pos.y + dy
  if not map:in_bounds(nx, ny) then return end
  if map:get(nx, ny) == M.TILE_WALL then return end
  pos.x = nx
  pos.y = ny
end

-- ---------------------------------------------------------------------------
-- Block placement
-- ---------------------------------------------------------------------------

--- Toggle the placeable BLOCK tile on the tile the player is facing (the
--- tile one step in front of the player, not the player's own tile --
--- placing under yourself would immediately re-block your own position).
--- No-op on WALL tiles (can't place/remove the map boundary) and on
--- out-of-bounds facing (facing off the edge of the map).
function M.toggle_block(world, player, map)
  local pos = M.player_position(world, player)
  local fx, fy = pos.x + pos.facing_dx, pos.y + pos.facing_dy
  if not map:in_bounds(fx, fy) then return end
  local tile = map:get(fx, fy)
  if tile == M.TILE_BLOCK then
    map:set(fx, fy, M.TILE_FLOOR)
  elseif tile == M.TILE_FLOOR then
    map:set(fx, fy, M.TILE_BLOCK)
  end
end

return M
