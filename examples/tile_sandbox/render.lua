-- examples/tile_sandbox/render.lua
-- Pure projection of world state -> terminal text lines. No I/O: takes a
-- map and world/player, returns an array of strings. main.lua is the only
-- place that touches stdin/stdout caps.
--
-- TYPECHECKER WORKAROUND: `render_lines` below takes `map`/`world` without
-- a `--:` signature, for the same reason as lib/tilemap+lib/entity_component
-- usage in world.lua being unannotated -- see world.lua's file-level
-- TYPECHECKER WORKAROUND comment for the confirmed repro. Everything else
-- in this file (the char tables, the returned `{ [number]: string }`) is
-- fully annotated.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local world_mod = require("examples.tile_sandbox.world")

local M = {}

--: { [integer]: string }
local TILE_CHARS = {
  [1] = ".", -- floor
  [2] = "#", -- wall
  [3] = "B", -- block
}

--- Facing arrow keyed by "dx,dy" of the four cardinal unit vectors.
--: { [string]: string }
local FACING_CHARS = {
  ["0,-1"] = "^",
  ["0,1"]  = "v",
  ["-1,0"] = "<",
  ["1,0"]  = ">",
}

--- Render the map + player to an array of lines: one line per map row,
--- a blank separator, then a help line.
function M.render_lines(map, world, player)
  local pos = world_mod.player_position(world, player)
  local w, h = world_mod.MAP_W, world_mod.MAP_H
  local lines = {} --: { [integer]: string }
  for y = 0, h - 1 do
    local row = {} --: { [integer]: string }
    for x = 0, w - 1 do
      if x == pos.x and y == pos.y then
        local facing_key = pos.facing_dx .. "," .. pos.facing_dy
        row[#row + 1] = FACING_CHARS[facing_key] or "@"
      else
        local tile = map:get(x, y)
        row[#row + 1] = TILE_CHARS[tile] or "?"
      end
    end
    lines[#lines + 1] = table.concat(row)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "wasd move, e place/remove block ahead, q quit"
  return lines
end

return M
