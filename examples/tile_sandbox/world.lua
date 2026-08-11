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
-- TYPECHECKER WORKAROUND: every function here that touches the
-- lib.entity_component World object, or the lib.tilemap TileMap object
-- past its documented alias surface, is deliberately left WITHOUT a `--:`
-- signature. The natural code would annotate each with its real
-- parameter/return types (a `World` alias for entity_component's world,
-- `TileMap` for tilemap's map). Two independent, confirmed typechecker
-- gaps prevent that:
--
--   1. lib/entity_component's `M.world()` has no return-type annotation.
--      Its returned object is `setmetatable({}, World)` with fields
--      assigned after the call; the checker's flow inference does not
--      carry those fields to the `return` point, so any `--:`-annotated
--      function whose parameter/return type mentions a restated `World`
--      alias sees the object as structurally disjoint from that alias
--      and rejects it -- even via `--[[:! T]]` force cast (the checker's
--      own overlap check refuses it as having "no overlap", and
--      `--[[: any]]` is separately rejected as "explicit any in
--      annotation"). Confirmed via minimal repro: identical
--      register/entity/add/get calls typecheck clean with 0 errors when
--      the enclosing function has no `--:` signature, and fail with 2
--      hard errors the moment one is added -- reproduced both at
--      top-level chunk scope and inside an annotated function.
--   2. lib/tilemap's `TileMap` alias only lists `in_bounds`, `get`,
--      `set`, `fill` -- it omits `fill_border`, `width`, `height`, and
--      most of the module's other public methods. A properly narrowed
--      `TileMap`-typed value therefore fails "field doesn't exist" for
--      any of those omitted methods. Worked around here by only calling
--      the four aliased methods (no fill_border/width/height) and
--      keeping our own MAP_W/MAP_H constants instead of querying the map
--      for its dimensions.
--
-- Both are lib/ gaps (entity_component's missing return annotation +
-- incomplete flow narrowing; tilemap's incomplete TileMap alias), not
-- bugs in this file's logic -- see TODO.md.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local tilemap = require("lib.tilemap")
local ecs     = require("lib.entity_component")

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
--- TYPECHECKER WORKAROUND comment (point 2).
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

--- Build the ECS world and the single player entity. See the file-level
--- TYPECHECKER WORKAROUND comment (point 1) for why this has no `--:`
--- signature.
function M.build_world()
  local world = ecs.world()
  world:register("position", { x = 1, y = 1, facing_dx = 1, facing_dy = 0 })
  local player = world:entity()
  world:add(player, "position", { x = 2, y = 2 })
  return world, player
end

--- Read the player's position component ({ x, y, facing_dx, facing_dy }).
function M.player_position(world, player)
  return world:get(player, "position")
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
