-- lib/solitaire/init.lua
-- Headless pure-Lua Klondike Solitaire engine.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: SolitaireMove = { type: "draw" } | { type: "waste_to_foundation" } | { type: "waste_to_tableau", col: integer } | { type: "tableau_to_foundation", col: integer } | { type: "tableau_to_tableau", from: integer, to: integer, count: integer }
--:: SolitaireState = { tableau: { [integer]: { [integer]: integer | nil } }, face_up: { [integer]: { [integer]: boolean | nil } }, foundation: { [integer]: integer }, stock: { [integer]: integer | nil }, waste: { [integer]: integer | nil }, draw_count: integer }

-- ── Card helpers ─────────────────────────────────────────────────────────────

-- suit 0=Spades 1=Hearts 2=Diamonds 3=Clubs
-- rank 1-13 (Ace=1 King=13)
-- card = suit * 13 + (rank - 1)

function M.rank(card) return card % 13 + 1 end
function M.suit(card) return math.floor(card / 13) end
-- Spades(0) and Clubs(3) are black; Hearts(1) and Diamonds(2) are red
function M.color(card)
  local s = M.suit(card)
  return (s == 0 or s == 3) and 0 or 1
end

local SUIT_NAMES = { [0]="S", [1]="H", [2]="D", [3]="C" }
local RANK_NAMES = { [1]="A",[2]="2",[3]="3",[4]="4",[5]="5",[6]="6",[7]="7",
                     [8]="8",[9]="9",[10]="T",[11]="J",[12]="Q",[13]="K" }

function M.suit_name(card) return SUIT_NAMES[M.suit(card)] end
function M.rank_name(card) return RANK_NAMES[M.rank(card)] end
function M.card_name(card) return RANK_NAMES[M.rank(card)] .. SUIT_NAMES[M.suit(card)] end

-- ── LCG PRNG ─────────────────────────────────────────────────────────────────

-- Simple 32-bit LCG (Numerical Recipes parameters).
local function make_rng(seed)
  local state = seed % 0x100000000
  return function()
    state = (1664525 * state + 1013904223) % 0x100000000
    return state
  end
end

-- ── State construction ───────────────────────────────────────────────────────

--: (opts: { seed: integer, draw_count: integer | nil }) -> SolitaireState
function M.new(opts)
  if not opts or opts.seed == nil then
    error("seed required")
  end
  local draw_count = opts.draw_count or 1
  local rng = make_rng(opts.seed)

  -- Build ordered deck
  local deck = {}
  for i = 0, 51 do deck[i+1] = i end

  -- Fisher-Yates shuffle
  for i = 52, 2, -1 do
    local j = rng() % i + 1
    deck[i], deck[j] = deck[j], deck[i]
  end

  -- Deal to tableau: col i gets i cards, top card face-up
  local tableau = {}
  local face_up = {}
  local di = 1
  for col = 1, 7 do
    tableau[col] = {}
    face_up[col] = {}
    for row = 1, col do
      tableau[col][row] = deck[di]
      face_up[col][row] = (row == col)
      di = di + 1
    end
  end

  -- Remaining 24 cards go to stock
  local stock = {}
  for i = di, 52 do
    stock[#stock + 1] = deck[i]
  end

  -- foundation[suit+1] = top_rank (0 = empty)
  local foundation = { 0, 0, 0, 0 }

  return {
    tableau    = tableau,
    face_up    = face_up,
    foundation = foundation,
    stock      = stock,
    waste      = {},
    draw_count = draw_count,
  }
end

-- ── Deep copy ────────────────────────────────────────────────────────────────

--: (SolitaireState) -> SolitaireState
local function copy_state(s)
  local tableau = {} --: { [integer]: { [integer]: integer | nil } }
  local face_up = {} --: { [integer]: { [integer]: boolean | nil } }
  for col = 1, 7 do
    local tc = {} --: { [integer]: integer | nil }
    local fc = {} --: { [integer]: boolean | nil }
    local scol = s.tableau[col] --: { [integer]: integer | nil }
    local fcol = s.face_up[col] --: { [integer]: boolean | nil }
    for i = 1, #scol do tc[i] = scol[i] end
    for i = 1, #fcol do fc[i] = fcol[i] end
    tableau[col] = tc
    face_up[col] = fc
  end
  local foundation = { s.foundation[1], s.foundation[2], s.foundation[3], s.foundation[4] }
  local stock = {} --: { [integer]: integer | nil }
  local waste = {} --: { [integer]: integer | nil }
  local sstock = s.stock --: { [integer]: integer | nil }
  local swaste = s.waste --: { [integer]: integer | nil }
  for i = 1, #sstock do stock[i] = sstock[i] end
  for i = 1, #swaste do waste[i] = swaste[i] end
  return {
    tableau    = tableau,
    face_up    = face_up,
    foundation = foundation,
    stock      = stock,
    waste      = waste,
    draw_count = s.draw_count,
  }
end

-- ── Move legality helpers ─────────────────────────────────────────────────────

-- Returns index of first face-up card in column (or nil if all face-down / empty)
--: (SolitaireState, integer) -> integer | nil
local function first_faceup(state, col)
  local face_up = state.face_up --: { [integer]: { [integer]: boolean | nil } }
  local col_fu = face_up[col] --: { [integer]: boolean | nil }
  for i = 1, #col_fu do
    if col_fu[i] then return i end
  end
  return nil
end

-- Can `card` be placed on top of `dest_card` in tableau?
local function can_stack(card, dest_card)
  return M.color(card) ~= M.color(dest_card) and M.rank(card) == M.rank(dest_card) - 1
end

-- Can `card` go to its foundation pile?
--: (SolitaireState, integer) -> boolean
local function can_go_foundation(state, card)
  local suit = M.suit(card)
  return state.foundation[suit+1] == M.rank(card) - 1
end

-- ── Move generation ───────────────────────────────────────────────────────────

--: (SolitaireState) -> { [integer]: SolitaireMove }
function M.moves(state)
  local result = {} --: { [integer]: SolitaireMove }

  -- draw: always available if stock or waste non-empty
  local stock = state.stock --: { [integer]: integer | nil }
  local waste = state.waste --: { [integer]: integer | nil }
  if #stock > 0 or #waste > 0 then
    result[#result+1] = { type = "draw" }
  end

  -- waste moves
  if #waste > 0 then
    local wcard = waste[#waste] --[[:! integer]]

    -- waste_to_foundation
    if can_go_foundation(state, wcard) then
      result[#result+1] = { type = "waste_to_foundation" }
    end

    -- waste_to_tableau
    local wrank = M.rank(wcard)
    local tableau = state.tableau --: { [integer]: { [integer]: integer | nil } }
    local face_up = state.face_up --: { [integer]: { [integer]: boolean | nil } }
    for col = 1, 7 do
      local tcol = tableau[col] --: { [integer]: integer | nil }
      local fcol = face_up[col] --: { [integer]: boolean | nil }
      local tlen = #tcol
      if tlen == 0 then
        if wrank == 13 then
          result[#result+1] = { type = "waste_to_tableau", col = col }
        end
      else
        local top = tcol[tlen] --[[:! integer]]
        if fcol[tlen] and can_stack(wcard, top) then
          result[#result+1] = { type = "waste_to_tableau", col = col }
        end
      end
    end
  end

  -- tableau moves
  local tableau = state.tableau --: { [integer]: { [integer]: integer | nil } }
  local face_up = state.face_up --: { [integer]: { [integer]: boolean | nil } }
  for col = 1, 7 do
    local tcol = tableau[col] --: { [integer]: integer | nil }
    local fcol = face_up[col] --: { [integer]: boolean | nil }
    local tlen = #tcol
    if tlen == 0 then goto continue_col end

    local fi = first_faceup(state, col)
    if not fi then goto continue_col end

    local top_card = tcol[tlen] --[[:! integer]]

    -- tableau_to_foundation (only top card)
    if can_go_foundation(state, top_card) then
      result[#result+1] = { type = "tableau_to_foundation", col = col }
    end

    -- tableau_to_tableau: try all valid counts (1..tlen-fi+1)
    local faceup_count = tlen - fi + 1
    for count = 1, faceup_count do
      -- The bottom card of the moved sequence is at index tlen-count+1
      local bottom_idx  = tlen - count + 1
      local bottom_card = tcol[bottom_idx] --[[:! integer]]

      -- Verify sequence validity for moved cards
      local valid_seq = true
      for k = bottom_idx, tlen - 1 do
        local c1 = tcol[k] --[[:! integer]]
        local c2 = tcol[k+1] --[[:! integer]]
        if not can_stack(c2, c1) then
          valid_seq = false
          break
        end
      end
      if not valid_seq then goto continue_count end

      for dest = 1, 7 do
        if dest == col then goto continue_dest end
        local dtcol = tableau[dest] --: { [integer]: integer | nil }
        local dfcol = face_up[dest] --: { [integer]: boolean | nil }
        local dlen = #dtcol
        if dlen == 0 then
          if M.rank(bottom_card) == 13 then
            result[#result+1] = { type = "tableau_to_tableau", from = col, to = dest, count = count }
          end
        else
          local dtop = dtcol[dlen] --[[:! integer]]
          if dfcol[dlen] and can_stack(bottom_card, dtop) then
            result[#result+1] = { type = "tableau_to_tableau", from = col, to = dest, count = count }
          end
        end
        ::continue_dest::
      end

      ::continue_count::
    end

    ::continue_col::
  end

  return result
end

-- ── Move application ──────────────────────────────────────────────────────────

-- Flip topmost face-down card of col if any face-up cards were removed.
--: (SolitaireState, integer) -> nil
local function maybe_flip_top(ns, col)
  local tcol = ns.tableau[col] --: { [integer]: integer | nil }
  local fcol = ns.face_up[col] --: { [integer]: boolean | nil }
  local tlen = #tcol
  if tlen > 0 and not fcol[tlen] then
    fcol[tlen] = true
  end
end

--: (SolitaireState, SolitaireMove) -> SolitaireState
function M.apply(state, move)
  local ns = copy_state(state)
  local t = move.type

  if t == "draw" then
    local ns_stock = ns.stock --: { [integer]: integer | nil }
    local ns_waste = ns.waste --: { [integer]: integer | nil }
    if #ns_stock == 0 then
      -- Reset: reverse waste into stock
      for i = #ns_waste, 1, -1 do
        ns_stock[#ns_stock+1] = ns_waste[i]
      end
      ns.waste = {}
    else
      local count = math.min(ns.draw_count, #ns_stock)
      for i = 1, count do
        ns_waste[#ns_waste+1] = ns_stock[#ns_stock]
        ns_stock[#ns_stock] = nil
      end
    end

  elseif t == "waste_to_foundation" then
    local ns_waste = ns.waste --: { [integer]: integer | nil }
    local card = ns_waste[#ns_waste] --[[:! integer]]
    ns_waste[#ns_waste] = nil
    ns.foundation[M.suit(card)+1] = M.rank(card)

  elseif t == "waste_to_tableau" then
    local ns_waste = ns.waste --: { [integer]: integer | nil }
    local card = ns_waste[#ns_waste] --[[:! integer]]
    ns_waste[#ns_waste] = nil
    local m_wtab = move --[[:! { type: "waste_to_tableau", col: integer }]]
    local col = m_wtab.col
    local tcol = ns.tableau[col] --: { [integer]: integer | nil }
    local fcol = ns.face_up[col] --: { [integer]: boolean | nil }
    tcol[#tcol+1] = card
    fcol[#fcol+1] = true

  elseif t == "tableau_to_foundation" then
    local m_tf = move --[[:! { type: "tableau_to_foundation", col: integer }]]
    local col = m_tf.col
    local tcol = ns.tableau[col] --: { [integer]: integer | nil }
    local fcol = ns.face_up[col] --: { [integer]: boolean | nil }
    local tlen = #tcol
    local card = tcol[tlen] --[[:! integer]]
    tcol[tlen] = nil
    fcol[tlen] = nil
    ns.foundation[M.suit(card)+1] = M.rank(card)
    maybe_flip_top(ns, col)

  elseif t == "tableau_to_tableau" then
    local m_tt = move --[[:! { type: "tableau_to_tableau", from: integer, to: integer, count: integer }]]
    local from, to, count = m_tt.from, m_tt.to, m_tt.count
    local tfrom = ns.tableau[from] --: { [integer]: integer | nil }
    local ffrom = ns.face_up[from] --: { [integer]: boolean | nil }
    local flen = #tfrom
    -- Extract cards to move (bottom-first in the subsequence)
    local moving = {} --: { [integer]: integer | nil }
    local moving_fu = {} --: { [integer]: boolean | nil }
    for i = flen - count + 1, flen do
      moving[#moving+1] = tfrom[i]
      moving_fu[#moving_fu+1] = ffrom[i]
    end
    -- Remove from source
    for i = flen - count + 1, flen do
      tfrom[i] = nil
      ffrom[i] = nil
    end
    maybe_flip_top(ns, from)
    -- Append to destination
    local tto = ns.tableau[to] --: { [integer]: integer | nil }
    local fto = ns.face_up[to] --: { [integer]: boolean | nil }
    local dlen = #tto
    for i = 1, #moving do
      tto[dlen+i] = moving[i]
      fto[dlen+i] = moving_fu[i]
    end
  end

  return ns
end

-- ── Win detection ─────────────────────────────────────────────────────────────

function M.won(state)
  return state.foundation[1] == 13
     and state.foundation[2] == 13
     and state.foundation[3] == 13
     and state.foundation[4] == 13
end

-- ── Auto-complete heuristic ───────────────────────────────────────────────────

-- A card of rank R and suit S is safe to move to foundation if:
--   R <= 2 (Aces/2s never block tableau), OR
--   both R-1 cards of the OPPOSITE color are already on foundation
--   (meaning no card in tableau needs this card as a placement target)
--: (SolitaireState) -> { [integer]: SolitaireMove }
function M.auto_moves(state)
  local result = {} --: { [integer]: SolitaireMove }

  -- Check waste top
  local waste = state.waste --: { [integer]: integer | nil }
  if #waste > 0 then
    local card = waste[#waste] --[[:! integer]]
    if can_go_foundation(state, card) then
      local r = M.rank(card)
      local safe = false
      if r <= 2 then
        safe = true
      else
        -- opposite color suits
        local opp_suits = M.color(card) == 0 and {1, 2} or {0, 3}
        if state.foundation[opp_suits[1]+1] >= r-1 and state.foundation[opp_suits[2]+1] >= r-1 then
          safe = true
        end
      end
      if safe then
        result[#result+1] = { type = "waste_to_foundation" }
      end
    end
  end

  -- Check tableau tops
  local tableau = state.tableau --: { [integer]: { [integer]: integer | nil } }
  local face_up = state.face_up --: { [integer]: { [integer]: boolean | nil } }
  for col = 1, 7 do
    local tcol = tableau[col] --: { [integer]: integer | nil }
    local fcol = face_up[col] --: { [integer]: boolean | nil }
    local tlen = #tcol
    if tlen > 0 and fcol[tlen] then
      local card = tcol[tlen] --[[:! integer]]
      if can_go_foundation(state, card) then
        local r = M.rank(card)
        local safe = false
        if r <= 2 then
          safe = true
        else
          local opp_suits = M.color(card) == 0 and {1, 2} or {0, 3}
          if state.foundation[opp_suits[1]+1] >= r-1 and state.foundation[opp_suits[2]+1] >= r-1 then
            safe = true
          end
        end
        if safe then
          result[#result+1] = { type = "tableau_to_foundation", col = col }
        end
      end
    end
  end

  return result
end

return M
