-- lib/crescent_examples/solitaire_cli.lua
-- Interactive CLI for Klondike Solitaire.
-- Usage: luajit lib/crescent_examples/solitaire_cli.lua --seed N [--draw 1|3]
-- io.read and io.write are used here at the system boundary (CLI entry point).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local S = require("lib.solitaire")

-- ── Arg parsing ───────────────────────────────────────────────────────────────

local seed, draw_count = nil, 1
local i = 1
while i <= #arg do
  if arg[i] == "--seed" then
    seed = tonumber(arg[i+1])
    i = i + 2
  elseif arg[i] == "--draw" then
    draw_count = tonumber(arg[i+1])
    i = i + 2
  else
    i = i + 1
  end
end

if not seed then
  io.stderr:write("Error: --seed N is required. Example: luajit solitaire_cli.lua --seed 42\n")
  os.exit(1)
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local function card_str(card, face_up)
  if not face_up then return "[##]" end
  return "[" .. S.card_name(card) .. "]"
end

local function render(state)
  -- Stock and waste
  local stock_disp = #state.stock > 0 and "[##]" or "[  ]"
  local waste_disp = #state.waste > 0 and "[" .. S.card_name(state.waste[#state.waste]) .. "]" or "[  ]"
  io.write("Stock: " .. stock_disp .. "  Waste: " .. waste_disp .. "\n")

  -- Foundation (indexed by suit order: S H D C)
  local fd = {}
  for suit = 0, 3 do
    local top = state.foundation[suit+1]
    if top == 0 then
      fd[#fd+1] = "[  ]"
    else
      local card = suit * 13 + (top - 1)
      fd[#fd+1] = "[" .. S.card_name(card) .. "]"
    end
  end
  io.write("Foundation: " .. table.concat(fd, " ") .. "\n\n")

  -- Tableau: build a 2D grid
  local max_rows = 0
  for col = 1, 7 do
    if #state.tableau[col] > max_rows then max_rows = #state.tableau[col] end
  end

  io.write("Tableau:\n")
  -- Header
  local header = {}
  for col = 1, 7 do header[col] = " " .. col .. "   " end
  io.write(table.concat(header) .. "\n")

  for row = 1, math.max(max_rows, 1) do
    local line = {}
    for col = 1, 7 do
      local col_len = #state.tableau[col]
      if row <= col_len then
        line[#line+1] = card_str(state.tableau[col][row], state.face_up[col][row])
      else
        line[#line+1] = "    "
      end
    end
    io.write(table.concat(line, " ") .. "\n")
  end
  io.write("\n")
end

local function render_moves(moves)
  for idx, m in ipairs(moves) do
    local desc
    local t = m.type
    if t == "draw" then
      desc = "Draw from stock"
    elseif t == "waste_to_foundation" then
      desc = "Move waste top to foundation"
    elseif t == "waste_to_tableau" then
      desc = "Move waste top to column " .. m.col
    elseif t == "tableau_to_foundation" then
      desc = "Move column " .. m.col .. " top to foundation"
    elseif t == "tableau_to_tableau" then
      desc = "Move " .. m.count .. " card(s) from column " .. m.from .. " to column " .. m.to
    else
      desc = t
    end
    io.write(string.format("  %2d. %s\n", idx, desc))
  end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────

local state = S.new({ seed = seed, draw_count = draw_count })

while true do
  render(state)

  if S.won(state) then
    io.write("You win!\n")
    break
  end

  -- Check auto-moves first
  local autos = S.auto_moves(state)
  if #autos > 0 then
    io.write("Auto-completing safe foundation moves...\n")
    for _, m in ipairs(autos) do
      state = S.apply(state, m)
    end
    -- Re-render after auto
    goto continue
  end

  local moves = S.moves(state)
  if #moves == 0 then
    io.write("No moves available. Game over.\n")
    break
  end

  render_moves(moves)
  io.write("Enter move number (or 'q' to quit): ")
  local line = io.read("*l")
  if not line or line == "q" or line == "quit" then
    io.write("Goodbye.\n")
    break
  end

  local choice = tonumber(line)
  if not choice or choice < 1 or choice > #moves then
    io.write("Invalid choice.\n")
  else
    state = S.apply(state, moves[choice])
  end

  ::continue::
end
