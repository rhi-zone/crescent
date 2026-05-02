-- lib/solitaire_cli/solitaire_cli_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.solitaire")
local C = require("lib.solitaire_cli")

-- ---------------------------------------------------------------------------
-- render_lines
-- ---------------------------------------------------------------------------

T.describe("render_lines", function()
  T.it("renders stock and waste header", function()
    local state = S.new({ seed = 42, draw_count = 1 })
    local lines = C.render_lines(state)
    T.ok(type(lines) == "table", "returns a table")
    T.ok(#lines > 0, "returns non-empty lines")
    -- First line should mention Stock and Waste
    T.ok(lines[1]:find("Stock") ~= nil, "first line has Stock")
    T.ok(lines[1]:find("Waste") ~= nil, "first line has Waste")
  end)

  T.it("renders foundation header", function()
    local state = S.new({ seed = 42, draw_count = 1 })
    local lines = C.render_lines(state)
    local found_foundation = false
    for _, line in ipairs(lines) do
      if line:find("Foundation") then found_foundation = true end
    end
    T.ok(found_foundation, "lines contain Foundation")
  end)

  T.it("renders tableau header", function()
    local state = S.new({ seed = 42, draw_count = 1 })
    local lines = C.render_lines(state)
    local found_tableau = false
    for _, line in ipairs(lines) do
      if line:find("Tableau") then found_tableau = true end
    end
    T.ok(found_tableau, "lines contain Tableau")
  end)

  T.it("renders 7 column headers", function()
    local state = S.new({ seed = 42, draw_count = 1 })
    local lines = C.render_lines(state)
    local header = nil --: string | nil
    for _, line in ipairs(lines) do
      if line:find(" 1 ") and line:find(" 7 ") then header = line end
    end
    T.ok(header ~= nil, "column header line found")
  end)
end)

-- ---------------------------------------------------------------------------
-- render_move_lines
-- ---------------------------------------------------------------------------

T.describe("render_move_lines", function()
  T.it("returns empty list for no moves", function()
    local lines = C.render_move_lines({})
    T.eq(#lines, 0)
  end)

  T.it("formats draw move", function()
    local move = { type = "draw" }
    local lines = C.render_move_lines({ move })
    T.eq(#lines, 1)
    T.ok(lines[1]:find("Draw") ~= nil, "draw move description")
  end)

  T.it("formats waste_to_foundation move", function()
    local move = { type = "waste_to_foundation" }
    local lines = C.render_move_lines({ move })
    T.ok(lines[1]:find("foundation") ~= nil, "mentions foundation")
  end)

  T.it("formats waste_to_tableau move with col", function()
    local move = { type = "waste_to_tableau", col = 3 }
    local lines = C.render_move_lines({ move })
    T.ok(lines[1]:find("3") ~= nil, "mentions column 3")
  end)

  T.it("formats tableau_to_tableau move", function()
    local move = { type = "tableau_to_tableau", from = 2, to = 5, count = 3 }
    local lines = C.render_move_lines({ move })
    T.ok(lines[1]:find("3") ~= nil, "mentions count 3")
    T.ok(lines[1]:find("2") ~= nil, "mentions from col 2")
    T.ok(lines[1]:find("5") ~= nil, "mentions to col 5")
  end)

  T.it("numbers moves sequentially", function()
    local moves = {
      { type = "draw" },
      { type = "waste_to_foundation" },
    }
    local lines = C.render_move_lines(moves)
    T.eq(#lines, 2)
    T.ok(lines[1]:find("1") ~= nil, "first move numbered 1")
    T.ok(lines[2]:find("2") ~= nil, "second move numbered 2")
  end)
end)

-- ---------------------------------------------------------------------------
-- M.run
-- ---------------------------------------------------------------------------

T.describe("M.run (headless)", function()
  T.it("outputs initial board and quits on 'q'", function()
    local output = {} --: { [integer]: string }
    local inputs = { "q" } --: { [integer]: string }
    local input_idx = 0
    local exit_code = nil --: number | nil

    C.run({
      seed       = 42,
      draw_count = 1,
      write_fn   = function(s) output[#output + 1] = s end,
      --: () -> string | nil
      read_fn    = function()
        input_idx = input_idx + 1
        return inputs[input_idx] --[[:! string | nil]]
      end,
      exit_fn    = function(code) exit_code = code end,
    })

    -- Should have produced output
    T.ok(#output > 0, "produced output")
    -- Should have asked for input (Stock line in output)
    local found_stock = false
    for _, line in ipairs(output) do
      if line:find("Stock") then found_stock = true end
    end
    T.ok(found_stock, "board was rendered")
    -- Should have printed Goodbye
    local found_goodbye = false
    for _, line in ipairs(output) do
      if line:find("Goodbye") then found_goodbye = true end
    end
    T.ok(found_goodbye, "quit message on 'q'")
    -- exit_fn not called (normal quit, no error exit)
    T.eq(exit_code, nil)
  end)

  T.it("rejects invalid choice and continues", function()
    local output = {} --: { [integer]: string }
    local inputs = { "99", "q" } --: { [integer]: string }
    local input_idx = 0

    C.run({
      seed       = 1,
      draw_count = 1,
      write_fn   = function(s) output[#output + 1] = s end,
      --: () -> string | nil
      read_fn    = function()
        input_idx = input_idx + 1
        return inputs[input_idx] --[[:! string | nil]]
      end,
      exit_fn    = function(_) end,
    })

    local found_invalid = false
    for _, line in ipairs(output) do
      if line:find("Invalid") then found_invalid = true end
    end
    T.ok(found_invalid, "invalid choice message shown")
  end)
end)
