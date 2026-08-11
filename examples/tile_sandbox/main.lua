-- examples/tile_sandbox/main.lua
-- Runnable entrypoint: `bin/cr run examples/tile_sandbox/main.lua`
--
-- Caps-first: stdin/stdout are constructed once here (via
-- lib/platform/caps/stdin and stdout -- the same cap factories
-- lib/platform apps use) and threaded through as explicit parameters.
-- Nothing below this file reaches for io/os directly.
--
-- Input is line-buffered: lib/platform/caps/stdin's cap.line() wraps
-- io.stdin:read("*l"), which returns once per Enter press. There is no
-- raw/cbreak-mode terminal cap in this repo (checked: no cbreak/ICANON/
-- termios handling anywhere under lib/), so single-keypress arrow-key
-- input is not achievable through any existing cap -- only whole lines.
-- This demo follows the same convention lib/platform/apps/finance/tui.lua
-- already uses (type a letter, press Enter) rather than inventing a new
-- raw-input mechanism: wasd + Enter to move, "e" + Enter to place/remove,
-- "q" + Enter to quit.
--
-- TYPECHECKER WORKAROUND: `M.run`'s `world`/`player`/`map` parameters
-- carry no `--:` types, for the same reason as world.lua/render.lua --
-- see world.lua's file-level TYPECHECKER WORKAROUND comment.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local tui        = require("lib.tui")
local ansi       = require("lib.ansi")
local stdin_mod  = require("lib.platform.caps.stdin")
local stdout_mod = require("lib.platform.caps.stdout")
local world_mod  = require("examples.tile_sandbox.world")
local render_mod = require("examples.tile_sandbox.render")

local M = {}

--- Drive the game loop until the user quits or stdin closes.
function M.run(world, player, map, stdin, stdout, getenv)
  local w, h = tui.size(getenv)
  while true do
    local lines = render_mod.render_lines(map, world, player)
    local text = table.concat(lines, "\n")
    local widget = tui.text(text, { align = "left", wrap = false })
    stdout.write(ansi.clear())
    stdout.write(tui.render(widget, 1, 1, w, h))
    stdout.write("\n> ")
    stdout.flush()

    local line = stdin.line()
    if line == nil then break end

    local cmd = line:sub(1, 1):lower()
    if cmd == "q" then
      break
    elseif cmd == "w" then
      world_mod.try_move(world, player, map, 0, -1)
    elseif cmd == "s" then
      world_mod.try_move(world, player, map, 0, 1)
    elseif cmd == "a" then
      world_mod.try_move(world, player, map, -1, 0)
    elseif cmd == "d" then
      world_mod.try_move(world, player, map, 1, 0)
    elseif cmd == "e" then
      world_mod.toggle_block(world, player, map)
    end
    -- any other input: ignored, just redraws
  end
end

-- ---------------------------------------------------------------------------
-- Entrypoint
-- ---------------------------------------------------------------------------

local stdin_cap  = stdin_mod.stdin_cap()
local stdout_cap = stdout_mod.stdout_cap()
local map            = world_mod.build_map()
local world, player  = world_mod.build_world()

--- No terminal-size cap exists outside lib/tui's own ioctl/env fallback
--- (see lib/platform/apps/finance/tui.lua's M.create for the same gap
--- inside the sandbox); this script isn't sandboxed, so os.getenv is used
--- directly here at the entrypoint boundary, same as bin/cr itself.
--: (string) -> string | nil
local function getenv(name) return os.getenv(name) end

M.run(world, player, map, stdin_cap, stdout_cap, getenv)

return M
