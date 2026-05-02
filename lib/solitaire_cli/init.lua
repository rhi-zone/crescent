-- lib/solitaire_cli/init.lua
-- Interactive CLI renderer and runner for Klondike Solitaire.
-- Wraps lib.solitaire with injected I/O capabilities.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local S = require("lib.solitaire")

local M = {}

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Format a single card as a display string.  face_up=false shows "##".
--: (integer, boolean) -> string
local function card_str(card, face_up)
  if not face_up then return "[##]" end
  return "[" .. S.card_name(card) .. "]"
end

-- Render the full game state to a list of lines (no trailing newline per line).
-- Returns a table of strings suitable for concatenation with "\n".
--: (unknown) -> { [integer]: string }
M.render_lines = function(state)
  local s = state --[[:! { stock: { [integer]: unknown }, waste: { [integer]: unknown }, foundation: { [integer]: unknown }, tableau: { [integer]: unknown }, face_up: { [integer]: unknown } }]]
  local lines = {} --: { [integer]: string }

  -- Stock and waste
  local stock_disp = #s.stock > 0 and "[##]" or "[  ]"
  local waste_top = s.waste[#s.waste]
  local waste_disp = waste_top and "[" .. S.card_name(waste_top --[[:! integer]]) .. "]" or "[  ]"
  lines[#lines + 1] = "Stock: " .. stock_disp .. "  Waste: " .. waste_disp

  -- Foundation (indexed by suit order: S H D C)
  local fd = {} --: { [integer]: string }
  for suit = 0, 3 do
    local top = s.foundation[suit + 1] --[[:! integer]]
    if top == 0 then
      fd[#fd + 1] = "[  ]"
    else
      local card = suit * 13 + (top - 1)
      fd[#fd + 1] = "[" .. S.card_name(card) .. "]"
    end
  end
  lines[#lines + 1] = "Foundation: " .. table.concat(fd, " ")
  lines[#lines + 1] = ""

  -- Tableau: build a 2D grid
  local max_rows = 0
  for col = 1, 7 do
    local col_cards = s.tableau[col] --[[:! { [integer]: unknown }]]
    if #col_cards > max_rows then max_rows = #col_cards end
  end

  lines[#lines + 1] = "Tableau:"
  -- Column headers
  local header = {} --: { [integer]: string }
  for col = 1, 7 do header[col] = " " .. col .. "   " end
  lines[#lines + 1] = table.concat(header)

  for row = 1, math.max(max_rows, 1) do
    local line_parts = {} --: { [integer]: string }
    for col = 1, 7 do
      local col_cards = s.tableau[col] --[[:! { [integer]: unknown }]]
      local col_fu    = s.face_up[col]  --[[:! { [integer]: unknown }]]
      if row <= #col_cards then
        line_parts[#line_parts + 1] = card_str(col_cards[row] --[[:! integer]], col_fu[row] --[[:! boolean]])
      else
        line_parts[#line_parts + 1] = "    "
      end
    end
    lines[#lines + 1] = table.concat(line_parts, " ")
  end
  lines[#lines + 1] = ""
  return lines
end

-- Render the list of available moves as a list of lines.
--: ({ [integer]: unknown }) -> { [integer]: string }
M.render_move_lines = function(moves)
  local lines = {} --: { [integer]: string }
  for idx, raw_m in ipairs(moves) do
    local m = raw_m --[[:! { type: string, col: integer | nil, from: integer | nil, to: integer | nil, count: integer | nil }]]
    local desc = "" --: string
    local t = m.type
    if t == "draw" then
      desc = "Draw from stock"
    elseif t == "waste_to_foundation" then
      desc = "Move waste top to foundation"
    elseif t == "waste_to_tableau" then
      desc = "Move waste top to column " .. (m.col or "?")
    elseif t == "tableau_to_foundation" then
      desc = "Move column " .. (m.col or "?") .. " top to foundation"
    elseif t == "tableau_to_tableau" then
      desc = "Move " .. (m.count or "?") .. " card(s) from column " .. (m.from or "?") .. " to column " .. (m.to or "?")
    else
      desc = t
    end
    lines[#lines + 1] = string.format("  %2d. %s", idx, desc)
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

--:: solitaire_cli_opts = { seed: integer, draw_count: integer | nil, write_fn: (string) -> nil, read_fn: () -> string | nil, exit_fn: (integer) -> nil }

-- Run an interactive Klondike game session.
-- opts.seed       — random seed (required)
-- opts.draw_count — cards drawn per turn (default 1)
-- opts.write_fn   — output function (receives a line string including "\n")
-- opts.read_fn    — input function (returns a line or nil on EOF)
-- opts.exit_fn    — called with exit code on normal termination
--: (solitaire_cli_opts) -> nil
M.run = function(opts)
  local seed       = opts.seed
  local draw_count = opts.draw_count or 1
  local write_fn   = opts.write_fn
  local read_fn    = opts.read_fn
  local exit_fn    = opts.exit_fn

  if not seed then
    write_fn("Error: opts.seed is required\n")
    exit_fn(1)
    return
  end

  local state = S.new({ seed = seed, draw_count = draw_count })

  while true do
    -- Render current board
    local board_lines = M.render_lines(state)
    for _, line in ipairs(board_lines) do write_fn(line .. "\n") end

    -- Win check
    if S.won(state) then
      write_fn("You win!\n")
      break
    end

    -- Auto-complete safe foundation moves
    local autos = S.auto_moves(state)
    if #autos > 0 then
      write_fn("Auto-completing safe foundation moves...\n")
      for _, m in ipairs(autos) do
        state = S.apply(state, m)
      end
      -- Re-render without reading input
    else
      -- Show available moves
      local moves = S.moves(state)
      if #moves == 0 then
        write_fn("No moves available. Game over.\n")
        break
      end

      local move_lines = M.render_move_lines(moves)
      for _, line in ipairs(move_lines) do write_fn(line .. "\n") end
      write_fn("Enter move number (or 'q' to quit): ")

      local line = read_fn()
      if not line or line == "q" or line == "quit" then
        write_fn("Goodbye.\n")
        break
      end

      local choice = tonumber(line)
      local n_moves = #moves
      if choice and choice >= 1 and choice <= n_moves then
        state = S.apply(state, moves[choice --[[:! integer]]])
      else
        write_fn("Invalid choice.\n")
      end
    end
  end
end

return M
