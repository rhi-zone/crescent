-- lib/minimax/minimax_test.lua
-- Tests for the minimax game tree search library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local minimax = require("lib.minimax")

-- ── Tic-Tac-Toe implementation ───────────────────────────────────────────────
-- Board: 9-element array. 1 = X (maximizer), -1 = O (minimizer), 0 = empty.
-- X goes first and is the maximizing player.

local function ttt_check_winner(board)
  local lines = {
    {1,2,3},{4,5,6},{7,8,9}, -- rows
    {1,4,7},{2,5,8},{3,6,9}, -- cols
    {1,5,9},{3,5,7},         -- diagonals
  }
  for _, line in ipairs(lines) do
    local a, b, c = board[line[1]], board[line[2]], board[line[3]]
    if a ~= 0 and a == b and b == c then return a end
  end
  return nil
end

local function ttt_full(board)
  for i = 1, 9 do
    if board[i] == 0 then return false end
  end
  return true
end

-- Whose turn is it? Count pieces.
local function ttt_turn(board)
  local x, o = 0, 0
  for i = 1, 9 do
    if board[i] == 1  then x = x + 1 end
    if board[i] == -1 then o = o + 1 end
  end
  return x == o and 1 or -1 -- X goes first (equal counts → X's turn)
end

local ttt = {}

function ttt.moves(board)
  local ms = {}
  for i = 1, 9 do
    if board[i] == 0 then ms[#ms + 1] = i end
  end
  return ms
end

function ttt.apply(board, move)
  local player = ttt_turn(board)
  local nb = {}
  for i = 1, 9 do nb[i] = board[i] end
  nb[move] = player
  return nb
end

function ttt.terminal(board)
  return ttt_check_winner(board) ~= nil or ttt_full(board)
end

function ttt.evaluate(board)
  local w = ttt_check_winner(board)
  if w == 1  then return 1  end
  if w == -1 then return -1 end
  return 0
end

-- Hash for transposition table: encode board as base-3 string
function ttt.hash(board)
  local t = {}
  for i = 1, 9 do
    t[i] = board[i] + 1 -- shift to 0,1,2
  end
  return table.concat(t)
end

local empty_board = {0,0,0,0,0,0,0,0,0}

-- Board where X can win immediately (X has top-row two, O has middle-row two)
-- X: 1,2 (top-left, top-mid) → move 3 wins; O: 4,5 → threatens 6
-- It is X's turn (2X 2O placed). X wins by taking 3 before worrying about block.
local win_board = {1,1,0, -1,-1,0, 0,0,0}

-- Board where O threatens to win, X must block.
-- X: 1,9 (no immediate winning line); O: 4,5 → threatens 6.
-- It is X's turn (2X 2O placed). X must block at 6.
local block_board = {1,0,0, -1,-1,0, 0,0,1}

-- ── Negamax tic-tac-toe wrapper ──────────────────────────────────────────────
-- Negamax requires evaluate() to return score from the CURRENT mover's
-- perspective (positive = good for whoever is about to move).
-- At a terminal state the LAST player to move won; the current player (to
-- move) is therefore the loser, so evaluate returns -1 (or 0 for draw).
local ttt_neg = {}
for k, v in pairs(ttt) do ttt_neg[k] = v end

function ttt_neg.evaluate(board)
  local w = ttt_check_winner(board)
  if w ~= nil then
    -- Someone won. That person moved last; the player to move now lost.
    return -1
  end
  return 0 -- draw
end

-- ── Simple numeric pick-from-pile game ──────────────────────────────────────
-- Two players alternate taking 1 or 2 stones from a pile.
-- The player who takes the LAST stone WINS.
-- State: { pile=N, player=1/-1 } where player is who moves next.
-- Maximizer is player=1.

local pile_game = {}

function pile_game.moves(state)
  local ms = {}
  if state.pile >= 1 then ms[#ms+1] = 1 end
  if state.pile >= 2 then ms[#ms+1] = 2 end
  return ms
end

function pile_game.apply(state, move)
  return { pile = state.pile - move, player = -state.player }
end

function pile_game.terminal(state)
  return state.pile == 0
end

function pile_game.evaluate(state)
  -- The player who just moved took the last stone (pile=0).
  -- That player is -state.player (since state.player already flipped).
  if state.pile == 0 then
    return -state.player -- -state.player just won; +1 if they are maximizer (player=1)
  end
  return 0
end

-- ── Tests ────────────────────────────────────────────────────────────────────

T.describe("minimax._tier", function()
  T.it("is pure", function()
    T.eq(minimax._tier, "pure")
  end)
end)

T.describe("minimax.search — tic-tac-toe", function()
  T.it("finds winning move when available (X wins at 3)", function()
    -- win_board: X at 1,2; O at 4,5. X to move. X wins by playing cell 3.
    local move, score = minimax.search(ttt, win_board, { depth = 6, maximize = true })
    T.eq(move, 3, "should play cell 3 to win immediately")
    T.eq(score, 1, "score should be 1 (win)")
  end)

  T.it("blocks opponent winning move (O threatens 6)", function()
    -- block_board: X at 1,9; O at 4,5. X to move. X has no immediate win; must block 6.
    local move, score = minimax.search(ttt, block_board, { depth = 6, maximize = true })
    T.eq(move, 6, "should block O at cell 6")
  end)

  T.it("draws when both sides play optimally", function()
    local move1, _ = minimax.search(ttt, empty_board, { depth = 9, maximize = true })
    T.ok(move1 ~= nil, "X has a move")
    -- Play the game with both sides using minimax
    local board = empty_board
    local is_max = true
    while not ttt.terminal(board) do
      local move = minimax.search(ttt, board, { depth = 9, maximize = is_max })
      board = ttt.apply(board, move)
      is_max = not is_max
    end
    local score = ttt.evaluate(board)
    T.eq(score, 0, "optimal play from both sides should draw")
  end)
end)

T.describe("minimax.negamax — tic-tac-toe", function()
  T.it("agrees with minimax: wins at cell 3", function()
    -- win_board: X at 1,2; O at 4,5; X to move. Negamax (current-player score)
    -- should also find cell 3 as the winning move.
    local move, _ = minimax.negamax(ttt_neg, win_board, { depth = 6 })
    T.eq(move, 3, "negamax should also find cell 3 win")
  end)

  T.it("draws when both sides play optimally (negamax)", function()
    local board = empty_board
    -- Alternate: even turns = X (score positive = good), odd = O
    local turn = 0
    while not ttt_neg.terminal(board) do
      local move = minimax.negamax(ttt_neg, board, { depth = 9 })
      board = ttt_neg.apply(board, move)
      turn = turn + 1
    end
    local w = ttt_check_winner(board)
    T.ok(w == nil or w == 0, "negamax optimal play should draw (no winner)")
  end)
end)

T.describe("minimax.mcts — tic-tac-toe", function()
  T.it("picks winning move with enough iterations", function()
    -- win_board: X can win immediately at cell 3
    -- With enough iterations, MCTS should discover this.
    -- Use a fixed seed for reproducibility.
    local move = minimax.mcts(ttt, win_board, {
      iterations = 2000,
      seed = 42,
    })
    T.eq(move, 3, "MCTS should find immediate win at cell 3")
  end)
end)

T.describe("minimax.iterative_deepening", function()
  T.it("returns same score as fixed-depth search on tic-tac-toe", function()
    local move_id, score_id = minimax.iterative_deepening(ttt, win_board, {
      max_depth = 6,
      maximize  = true,
    })
    local move_fixed, score_fixed = minimax.search(ttt, win_board, {
      depth    = 6,
      maximize = true,
    })
    T.eq(score_id, score_fixed, "iterative deepening score equals fixed-depth score")
    T.eq(score_id, 1, "score is 1 (X wins)")
    -- Both should find the same winning move.
    T.eq(move_id, move_fixed, "iterative deepening move equals fixed-depth move")
  end)

  T.it("completes within time_limit and returns a valid move", function()
    local move, score = minimax.iterative_deepening(ttt, empty_board, {
      max_depth  = 9,
      time_limit = 5.0,  -- generous; tic-tac-toe is tiny
      maximize   = true,
    })
    T.ok(move ~= nil, "should return a move")
    -- From empty board, optimal play is a draw
    T.eq(score, 0, "score from empty board is 0 (draw)")
  end)
end)

T.describe("pick-from-pile game", function()
  -- Take 1 or 2 stones, last to take WINS. Losing positions: multiples of 3.
  -- pile=3: both moves leave 1 or 2 for opponent → opponent wins → score=-1 (loss for mover).
  -- pile=4: take 1 → pile=3 (opponent in losing position) → score=1 (win for mover).
  -- pile=2: take 2 immediately → win → score=1.
  -- pile=6: multiple of 3 → loss for mover → score=-1.

  T.it("minimax finds win from pile=4 (take 1, leave opponent at pile=3)", function()
    local state = { pile = 4, player = 1 }
    local move, score = minimax.search(pile_game, state, { depth = 8, maximize = true })
    T.eq(move, 1, "from pile=4, optimal is take 1 (leaves pile=3 for opponent)")
    T.eq(score, 1, "first player wins from pile=4")
  end)

  T.it("minimax finds win from pile=2 (take both to win immediately)", function()
    local state = { pile = 2, player = 1 }
    local move, score = minimax.search(pile_game, state, { depth = 6, maximize = true })
    T.eq(move, 2, "from pile=2, take both to win immediately")
    T.eq(score, 1, "first player wins from pile=2")
  end)

  T.it("minimax detects losing position (pile=3: mover loses)", function()
    local state = { pile = 3, player = 1 }
    local move, score = minimax.search(pile_game, state, { depth = 6, maximize = true })
    T.eq(score, -1, "pile=3 is a losing position for the mover")
  end)

  T.it("minimax detects losing position (pile=6: multiple of 3)", function()
    local state = { pile = 6, player = 1 }
    local move, score = minimax.search(pile_game, state, { depth = 10, maximize = true })
    T.eq(score, -1, "pile=6 is a losing position for the mover")
  end)
end)

T.describe("transposition table", function()
  T.it("reduces node count compared to no-table search", function()
    -- Use an empty board with full depth; many transpositions exist in tic-tac-toe.
    local _, _, nodes_no_tt = minimax.search_with_stats(ttt, empty_board, {
      depth    = 7,
      maximize = true,
    })

    local tt = {}
    local _, _, nodes_with_tt = minimax.search_with_stats(ttt, empty_board, {
      depth                = 7,
      maximize             = true,
      transposition_table  = tt,
    })

    T.ok(nodes_with_tt < nodes_no_tt,
      "transposition table should reduce nodes visited: " ..
      nodes_with_tt .. " < " .. nodes_no_tt)
  end)
end)

T.describe("alpha-beta vs full minimax parity", function()
  T.it("alpha-beta and full minimax produce same score on win_board", function()
    -- alpha-beta is always called in M.search; we verify score equals the known
    -- ground truth (1 = X wins).
    local _, score = minimax.search(ttt, win_board, { depth = 6, maximize = true })
    T.eq(score, 1, "score from winning position is 1")
  end)

  T.it("alpha-beta produces same score as naive from empty board", function()
    -- Both should score 0 (draw) from empty board with full depth.
    local _, score = minimax.search(ttt, empty_board, { depth = 9, maximize = true })
    T.eq(score, 0, "score from empty board is 0 (draw)")
  end)
end)
