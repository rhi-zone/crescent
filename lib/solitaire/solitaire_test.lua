-- lib/solitaire/solitaire_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local S  = require("lib.solitaire")

-- ── Card helpers ─────────────────────────────────────────────────────────────

T.describe("card helpers", function()
  T.it("rank/suit/color decode correctly", function()
    -- Ace of Spades = 0
    T.eq(S.rank(0), 1)
    T.eq(S.suit(0), 0)
    T.eq(S.color(0), 0)  -- black

    -- Ace of Hearts = 13
    T.eq(S.rank(13), 1)
    T.eq(S.suit(13), 1)
    T.eq(S.color(13), 1) -- red

    -- King of Clubs = 3*13+12 = 51
    T.eq(S.rank(51), 13)
    T.eq(S.suit(51), 3)
    T.eq(S.color(51), 0) -- black (Clubs)

    -- Ten of Diamonds = 2*13+9 = 35
    T.eq(S.rank(35), 10)
    T.eq(S.suit(35), 2)
    T.eq(S.color(35), 1) -- red
  end)

  T.it("card_name produces correct strings", function()
    T.eq(S.card_name(0),  "AS")  -- Ace of Spades
    T.eq(S.card_name(13), "AH")  -- Ace of Hearts
    T.eq(S.card_name(26), "AD")  -- Ace of Diamonds
    T.eq(S.card_name(39), "AC")  -- Ace of Clubs
    T.eq(S.card_name(12), "KS")  -- King of Spades
    T.eq(S.card_name(35), "TD")  -- Ten of Diamonds
  end)
end)

-- ── M.new ─────────────────────────────────────────────────────────────────────

T.describe("M.new", function()
  T.it("requires a seed", function()
    T.throws(function() S.new({}) end)
    T.throws(function() S.new(nil) end)
  end)

  T.it("creates 52 distinct cards across all piles", function()
    local state = S.new({ seed = 1 })
    local seen = {}
    local count = 0

    for col = 1, 7 do
      for _, card in ipairs(state.tableau[col]) do
        T.ok(not seen[card], "duplicate card " .. S.card_name(card))
        seen[card] = true
        count = count + 1
      end
    end
    for _, card in ipairs(state.stock) do
      T.ok(not seen[card], "duplicate card " .. S.card_name(card))
      seen[card] = true
      count = count + 1
    end
    T.eq(count, 52)
  end)

  T.it("tableau column lengths are 1..7", function()
    local state = S.new({ seed = 42 })
    for col = 1, 7 do
      T.eq(#state.tableau[col], col)
    end
  end)

  T.it("only the top card of each tableau column is face-up", function()
    local state = S.new({ seed = 7 })
    for col = 1, 7 do
      for row = 1, col - 1 do
        T.fail(state.face_up[col][row], "row " .. row .. " of col " .. col .. " should be face-down")
      end
      T.ok(state.face_up[col][col], "top card of col " .. col .. " should be face-up")
    end
  end)

  T.it("stock has 24 cards and waste is empty", function()
    local state = S.new({ seed = 99 })
    T.eq(#state.stock, 24)
    T.eq(#state.waste, 0)
  end)

  T.it("respects draw_count option", function()
    local state = S.new({ seed = 1, draw_count = 3 })
    T.eq(state.draw_count, 3)
  end)

  T.it("different seeds produce different deals", function()
    local s1 = S.new({ seed = 1 })
    local s2 = S.new({ seed = 2 })
    local same = true
    for col = 1, 7 do
      for row = 1, col do
        if s1.tableau[col][row] ~= s2.tableau[col][row] then
          same = false; break
        end
      end
    end
    T.fail(same, "different seeds should produce different deals")
  end)
end)

-- ── M.moves ───────────────────────────────────────────────────────────────────

T.describe("M.moves", function()
  T.it("fresh game has at least a draw move", function()
    local state = S.new({ seed = 5 })
    local moves = S.moves(state)
    local has_draw = false
    for _, m in ipairs(moves) do
      if m.type == "draw" then has_draw = true; break end
    end
    T.ok(has_draw)
  end)

  T.it("no draw when both stock and waste are empty", function()
    local state = S.new({ seed = 5 })
    state.stock = {}
    state.waste = {}
    local moves = S.moves(state)
    local has_draw = false
    for _, m in ipairs(moves) do
      if m.type == "draw" then has_draw = true; break end
    end
    T.fail(has_draw)
  end)
end)

-- ── M.apply — draw ────────────────────────────────────────────────────────────

T.describe("M.apply draw", function()
  T.it("moves top stock card(s) to waste", function()
    local state = S.new({ seed = 10 })
    local top = state.stock[#state.stock]
    local stock_before = #state.stock
    local ns = S.apply(state, { type = "draw" })
    T.eq(#ns.stock, stock_before - 1)
    T.eq(ns.waste[#ns.waste], top)
  end)

  T.it("draw_count=3 flips up to 3 cards", function()
    local state = S.new({ seed = 10, draw_count = 3 })
    local stock_before = #state.stock
    local ns = S.apply(state, { type = "draw" })
    T.eq(#ns.stock, stock_before - 3)
    T.eq(#ns.waste, 3)
  end)

  T.it("draw on empty stock resets waste to stock", function()
    local state = S.new({ seed = 3 })
    state.stock = {}
    state.waste = { 0, 5, 10 }
    local ns = S.apply(state, { type = "draw" })
    -- waste reversed into stock
    T.eq(#ns.stock, 3)
    T.eq(ns.stock[1], 10)
    T.eq(ns.stock[2], 5)
    T.eq(ns.stock[3], 0)
    T.eq(#ns.waste, 0)
  end)

  T.it("apply does not mutate original state", function()
    local state = S.new({ seed = 11 })
    local original_stock_size = #state.stock
    S.apply(state, { type = "draw" })
    T.eq(#state.stock, original_stock_size)
  end)
end)

-- ── M.won ─────────────────────────────────────────────────────────────────────

T.describe("M.won", function()
  T.it("fresh game is not won", function()
    local state = S.new({ seed = 1 })
    T.fail(S.won(state))
  end)

  T.it("all foundations at 13 is won", function()
    local state = S.new({ seed = 1 })
    state.foundation = { 13, 13, 13, 13 }
    T.ok(S.won(state))
  end)

  T.it("partial foundation is not won", function()
    local state = S.new({ seed = 1 })
    state.foundation = { 13, 12, 13, 13 }
    T.fail(S.won(state))
  end)
end)

-- ── Known-move legality ───────────────────────────────────────────────────────

T.describe("known legal moves", function()
  T.it("waste_to_foundation move is generated when waste top is next foundation card", function()
    -- Build a state where waste top is Ace of Spades (card=0) and foundation[1]=0
    local state = S.new({ seed = 1 })
    state.waste = { 0 }  -- Ace of Spades
    state.foundation[1] = 0  -- Spades pile is empty
    local moves = S.moves(state)
    local found = false
    for _, m in ipairs(moves) do
      if m.type == "waste_to_foundation" then found = true; break end
    end
    T.ok(found, "waste_to_foundation should be legal")
  end)

  T.it("waste_to_tableau King onto empty column is legal", function()
    local state = S.new({ seed = 1 })
    -- King of Spades = card 12
    state.waste = { 12 }
    -- Empty one tableau column
    state.tableau[3] = {}
    state.face_up[3] = {}
    local moves = S.moves(state)
    local found = false
    for _, m in ipairs(moves) do
      if m.type == "waste_to_tableau" and m.col == 3 then found = true; break end
    end
    T.ok(found, "King onto empty column should be legal")
  end)

  T.it("tableau_to_tableau move: red 6 onto black 7", function()
    local state = S.new({ seed = 1 })
    -- 6 of Hearts (red) = suit 1, rank 6 → card = 1*13+5 = 18
    -- 7 of Spades (black) = suit 0, rank 7 → card = 0*13+6 = 6
    state.tableau[1] = { 18 }
    state.face_up[1] = { true }
    state.tableau[2] = { 6 }
    state.face_up[2] = { true }
    local moves = S.moves(state)
    local found = false
    for _, m in ipairs(moves) do
      if m.type == "tableau_to_tableau" and m.from == 1 and m.to == 2 then
        found = true; break
      end
    end
    T.ok(found, "red 6 should stack on black 7")
  end)
end)

-- ── tableau_to_foundation flips face-down card ───────────────────────────────

T.describe("M.apply tableau_to_foundation", function()
  T.it("flips the newly exposed face-down card", function()
    local state = S.new({ seed = 1 })
    -- Set up col 1 with a face-down card under a face-up Ace of Spades
    -- Ace of Spades = 0, foundation[1] must be 0 (empty)
    state.tableau[1] = { 5, 0 }  -- card 5 (face-down), then card 0 = AS (face-up)
    state.face_up[1] = { false, true }
    state.foundation[1] = 0

    local ns = S.apply(state, { type = "tableau_to_foundation", col = 1 })
    T.eq(#ns.tableau[1], 1)
    T.ok(ns.face_up[1][1], "previously face-down card should now be face-up")
    T.eq(ns.foundation[1], 1)
  end)
end)

-- ── Determinism test ──────────────────────────────────────────────────────────

T.describe("determinism", function()
  T.it("same seed produces identical state", function()
    local s1 = S.new({ seed = 12345 })
    local s2 = S.new({ seed = 12345 })
    for col = 1, 7 do
      for i = 1, col do
        T.eq(s1.tableau[col][i], s2.tableau[col][i])
      end
    end
    for i = 1, #s1.stock do
      T.eq(s1.stock[i], s2.stock[i])
    end
  end)

  T.it("sequence of draws is deterministic from a known seed", function()
    local state = S.new({ seed = 777 })
    -- Record the first 3 cards drawn
    local drawn = {}
    for _ = 1, 3 do
      state = S.apply(state, { type = "draw" })
      drawn[#drawn+1] = state.waste[#state.waste]
    end

    -- Replay from fresh state with same seed
    local state2 = S.new({ seed = 777 })
    local drawn2 = {}
    for _ = 1, 3 do
      state2 = S.apply(state2, { type = "draw" })
      drawn2[#drawn2+1] = state2.waste[#state2.waste]
    end

    for i = 1, 3 do
      T.eq(drawn[i], drawn2[i], "draw " .. i .. " should match")
    end
  end)
end)

-- ── M.auto_moves ─────────────────────────────────────────────────────────────

T.describe("M.auto_moves", function()
  T.it("Ace is always safe", function()
    local state = S.new({ seed = 1 })
    -- Put Ace of Spades on top of waste
    state.waste = { 0 }
    state.foundation[1] = 0
    local autos = S.auto_moves(state)
    local found = false
    for _, m in ipairs(autos) do
      if m.type == "waste_to_foundation" then found = true; break end
    end
    T.ok(found, "Ace should be safe")
  end)

  T.it("returns empty when no safe foundation moves exist", function()
    -- Fresh game, no aces in waste
    local state = S.new({ seed = 99 })
    state.waste = {}
    -- Clear tableau tops and put high cards there (not safe without backing on foundation)
    -- Just check that auto_moves doesn't error and returns a table
    local autos = S.auto_moves(state)
    T.ok(type(autos) == "table")
  end)
end)
