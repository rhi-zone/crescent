-- lib/minimax/init.lua
-- Game tree search: minimax with alpha-beta pruning, negamax, iterative
-- deepening, and Monte Carlo Tree Search (MCTS).
--
-- Game interface:
--   game.moves(state)         -> array of legal moves
--   game.apply(state, move)   -> new state
--   game.terminal(state)      -> bool
--   game.evaluate(state)      -> score from maximizing player's perspective
-- Optional:
--   game.hash(state)          -> string/number key for transposition table

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: minimax_game = { moves: (unknown) -> unknown[], apply: (unknown, unknown) -> unknown, terminal: (unknown) -> boolean, evaluate: (unknown) -> number, hash?: (unknown) -> unknown, ... }
--:: minimax_ttable = { [unknown]: { depth: integer, move: unknown, score: number } } | nil
--:: minimax_order_fn = (state: unknown, moves: { [number]: unknown }) -> { [number]: unknown }
--:: minimax_order = (minimax_order_fn) | nil
--:: mcts_node = { state: unknown, parent: mcts_node | nil, move: unknown, visits: number, wins: number, children: { [number]: mcts_node }, expanded: boolean }
--:: minimax_rng = { next: (minimax_rng) -> integer, float: (minimax_rng) -> number, int: (minimax_rng, integer) -> integer }

local INF = math.huge

-- ── Minimax with alpha-beta pruning ─────────────────────────────────────────

-- Internal recursive alpha-beta search.
-- Returns (best_move, best_score, nodes_visited).
--: (minimax_game, unknown, integer, number, number, boolean, minimax_ttable, minimax_order) -> (unknown, number, integer)
local function ab_search(game, state, depth, alpha, beta, maximize, ttable, order)
  -- Transposition table lookup
  local hash_key
  if ttable and game.hash then
    hash_key = game.hash(state)
    local cached = ttable[hash_key]
    if cached and cached.depth >= depth then
      return cached.move, cached.score, 0
    end
  end

  if depth == 0 or game.terminal(state) then
    return nil, game.evaluate(state), 1
  end

  local moves = game.moves(state)
  if #moves == 0 then
    return nil, game.evaluate(state), 1
  end

  if order then
    local order_fn = order
    moves = order_fn(state, moves)
  end

  local best_move = moves[1]
  local best_score = maximize and -INF or INF
  local nodes = 0

  for i = 1, #moves do
    local move = moves[i]
    local child = game.apply(state, move)
    local _, score, n = ab_search(game, child, depth - 1, alpha, beta, not maximize, ttable, order)
    nodes = nodes + n

    if maximize then
      if score > best_score then
        best_score = score
        best_move = move
      end
      if score > alpha then alpha = score end
    else
      if score < best_score then
        best_score = score
        best_move = move
      end
      if score < beta then beta = score end
    end

    if alpha >= beta then break end -- cutoff
  end

  if ttable and hash_key then
    ttable[hash_key] = { move = best_move, score = best_score, depth = depth }
  end

  return best_move, best_score, nodes
end

-- Minimax with alpha-beta pruning.
-- opts: { depth, maximize, order, transposition_table }
-- Returns best_move, score.
--: (minimax_game, unknown, { depth?: integer, maximize?: boolean, order?: minimax_order_fn, transposition_table?: { [unknown]: { depth: integer, move: unknown, score: number } } } | nil) -> (unknown, number)
function M.search(game, state, opts)
  opts = opts or {}
  local depth    = opts.depth or 4
  local maximize = opts.maximize
  if maximize == nil then maximize = true end
  local order  = opts.order
  local ttable = opts.transposition_table or (game.hash and {} or nil)

  local best_move, score = ab_search(game, state, depth, -INF, INF, maximize, ttable, order)
  return best_move, score
end

-- ── Negamax with alpha-beta pruning ─────────────────────────────────────────

-- Negamax: symmetric formulation where evaluate() always returns score for
-- the current player (positive = good for current mover).
-- The game's evaluate() must return from the perspective of the player to move.

--: (minimax_game, unknown, integer, number, number, minimax_ttable, minimax_order) -> (unknown, number, integer)
local function negamax_ab(game, state, depth, alpha, beta, ttable, order)
  local hash_key
  if ttable and game.hash then
    hash_key = game.hash(state)
    local cached = ttable[hash_key]
    if cached and cached.depth >= depth then
      return cached.move, cached.score, 0
    end
  end

  if depth == 0 or game.terminal(state) then
    return nil, game.evaluate(state), 1
  end

  local moves = game.moves(state)
  if #moves == 0 then
    return nil, game.evaluate(state), 1
  end

  if order then
    local order_fn = order
    moves = order_fn(state, moves)
  end

  local best_move = moves[1]
  local best_score = -INF
  local nodes = 0

  for i = 1, #moves do
    local move = moves[i]
    local child = game.apply(state, move)
    local _, raw_score, n = negamax_ab(game, child, depth - 1, -beta, -alpha, ttable, order)
    local score = -raw_score
    nodes = nodes + n

    if score > best_score then
      best_score = score
      best_move = move
    end
    if score > alpha then alpha = score end
    if alpha >= beta then break end
  end

  if ttable and hash_key then
    ttable[hash_key] = { move = best_move, score = best_score, depth = depth }
  end

  return best_move, best_score, nodes
end

-- Negamax variant. game.evaluate(state) must score for the current mover.
-- opts: { depth, order, transposition_table }
-- Returns best_move, score.
--: (minimax_game, unknown, { depth?: integer, order?: minimax_order_fn, transposition_table?: { [unknown]: { depth: integer, move: unknown, score: number } } } | nil) -> (unknown, number)
function M.negamax(game, state, opts)
  opts = opts or {}
  local depth  = opts.depth or 4
  local order  = opts.order
  local ttable = opts.transposition_table or (game.hash and {} or nil)
  local best_move, score = negamax_ab(game, state, depth, -INF, INF, ttable, order)
  return best_move, score
end

-- ── Iterative deepening ──────────────────────────────────────────────────────

-- Iterative deepening minimax (IDA*-style).
-- Searches depth 1, 2, ..., max_depth; stops early on time_limit.
-- opts: { max_depth, time_limit, maximize, order, transposition_table }
-- Returns best_move, score.
--: (minimax_game, unknown, { max_depth?: integer, time_limit?: number, maximize?: boolean, order?: minimax_order_fn, transposition_table?: { [unknown]: { depth: integer, move: unknown, score: number } }, clock_fn?: () -> number } | nil) -> (unknown, number)
function M.iterative_deepening(game, state, opts)
  opts = opts or {}
  local max_depth  = opts.max_depth or 6
  local time_limit = opts.time_limit
  local clock_fn   = opts.clock_fn or error("minimax.iterative_deepening: opts.clock_fn is required")
  local maximize   = opts.maximize
  if maximize == nil then maximize = true end
  local order      = opts.order
  local ttable     = opts.transposition_table or (game.hash and {} or nil)

  local start = time_limit and clock_fn() or nil
  local best_move, best_score

  for depth = 1, max_depth do
    local move, score = ab_search(game, state, depth, -INF, INF, maximize, ttable, order)
    best_move = move
    best_score = score

    if time_limit and start and (clock_fn() - start) >= time_limit then
      break
    end
  end

  return best_move, best_score
end

-- ── Monte Carlo Tree Search ──────────────────────────────────────────────────

-- Simple LCG for reproducible random sequences without external deps.
local function make_rng(seed)
  if not seed then error("minimax: seed is required for MCTS") end
  local s = seed
  return {
    next = function(self)
      s = (s * 1664525 + 1013904223) % 0x100000000
      return s
    end,
    float = function(self)
      return self:next() / 0x100000000
    end,
    int = function(self, n)
      return self:next() % n
    end,
  }
end

-- MCTS node structure (stored in flat tables for LuaJIT friendliness).
-- nodes[i] = { state, parent, move, visits, wins, children={} }
--: (unknown, mcts_node | nil, unknown) -> mcts_node
local function mcts_new_node(state, parent, move)
  return {
    state    = state,
    parent   = parent,
    move     = move,
    visits   = 0,
    wins     = 0.0,
    children = {},
    expanded = false,
  }
end

-- UCB1 score: wins/visits + c * sqrt(ln(parent_visits) / visits)
--: (mcts_node, number, number) -> number
local function ucb1(node, parent_visits, c)
  if node.visits == 0 then return INF end
  return node.wins / node.visits + c * math.sqrt(math.log(parent_visits) / node.visits)
end

-- Select best child by UCB1.
--: (mcts_node, number) -> mcts_node | nil
local function mcts_select(node, c)
  local best, best_score = nil, -INF
  local children = node.children
  for i = 1, #children do
    local child = children[i]
    local s = ucb1(child, node.visits, c)
    if s > best_score then
      best_score = s
      best = child
    end
  end
  return best
end

-- Tree policy: descend using UCB1 until unexpanded or terminal.
--: (mcts_node, minimax_game, number) -> mcts_node
local function mcts_tree_policy(node, game, c)
  while not game.terminal(node.state) do
    if not node.expanded then
      -- Expand: create all children
      local moves = game.moves(node.state)
      for i = 1, #moves do
        local child = mcts_new_node(game.apply(node.state, moves[i]), node, moves[i])
        node.children[#node.children + 1] = child
      end
      node.expanded = true
      if #node.children == 0 then break end
      return node.children[1] -- pick first unvisited child
    end
    -- All children exist; select by UCB1
    local next_node = mcts_select(node, c)
    if not next_node then break end
    node = next_node
  end
  return node
end

-- Default rollout policy: random play to terminal, return evaluate().
--: (minimax_game, unknown, minimax_rng) -> number
local function mcts_rollout(game, state, rng)
  local depth = 0
  local max_rollout = 200 -- prevent infinite loops on non-terminal games
  while not game.terminal(state) and depth < max_rollout do
    local moves = game.moves(state)
    if #moves == 0 then break end
    local idx = rng:int(#moves) + 1
    state = game.apply(state, moves[idx])
    depth = depth + 1
  end
  return game.evaluate(state)
end

-- Backpropagate result up to root. result > 0 counts as a win for even depths
-- (root player), loss for odd depths (opponent). We use the raw score as the
-- win value so the tree can be used with continuous evaluations.
--: (mcts_node | nil, number) -> nil
local function mcts_backprop(node, result)
  local sign = 1
  while node do
    node.visits = node.visits + 1
    node.wins   = node.wins + result * sign
    sign = -sign
    node = node.parent
  end
end

-- Monte Carlo Tree Search.
-- opts: { iterations, c, seed, rollout }
--   c          — UCB1 exploration constant (default 1.414 ≈ sqrt(2))
--   seed       — RNG seed (required)
--   rollout    — custom rollout fn(game, state, rng) -> score (optional)
-- Returns best_move.
--: (minimax_game, unknown, { iterations?: integer, c?: number, seed: integer, rollout?: (minimax_game, unknown, unknown) -> number }) -> unknown
function M.mcts(game, state, opts)
  if not opts or not opts.seed then error("minimax.mcts: opts.seed is required") end
  local iterations = opts.iterations or 1000
  local c          = opts.c or 1.414
  local rng        = make_rng(opts.seed)
  local rollout_fn = opts.rollout or mcts_rollout

  local root = mcts_new_node(state, nil, nil)

  for _ = 1, iterations do
    -- 1. Selection + Expansion
    local node = mcts_tree_policy(root, game, c)

    -- 2. Simulation (rollout)
    local result = rollout_fn(game, node.state, rng)

    -- 3. Backpropagation
    mcts_backprop(node, result)
  end

  -- Pick child with most visits (robust child selection).
  local best_move, best_visits = nil, -1
  local children = root.children
  for i = 1, #children do
    local child = children[i]
    if child.visits > best_visits then
      best_visits = child.visits
      best_move   = child.move
    end
  end

  return best_move
end

-- ── Node counter helper ──────────────────────────────────────────────────────

-- search_with_stats: like search but also returns node count.
-- Useful for verifying transposition table effectiveness.
--: (minimax_game, unknown, { depth?: integer, maximize?: boolean, order?: minimax_order_fn, transposition_table?: { [unknown]: { depth: integer, move: unknown, score: number } } } | nil) -> (unknown, number, integer)
function M.search_with_stats(game, state, opts)
  opts = opts or {}
  local depth    = opts.depth or 4
  local maximize = opts.maximize
  if maximize == nil then maximize = true end
  local order  = opts.order
  local ttable = opts.transposition_table

  local best_move, score, nodes = ab_search(game, state, depth, -INF, INF, maximize, ttable, order)
  return best_move, score, nodes
end

return M
