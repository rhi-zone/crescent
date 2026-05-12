if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/genetic — genetic algorithm optimization framework.
--
-- Usage:
--   local ga = require("lib.genetic")
--   local result = ga.run({ create=..., fitness=..., crossover=..., mutate=..., ... })
--
-- Individuals are wrapped in population entries:
--   { genome = any, fitness = number }
--
-- Error convention: (nil, errmsg) returns, never throw.

local M = {}

M._tier = "pure"

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, number, number) -> number, bool: (self: Rng) -> boolean, pick: (self: Rng, { [integer]: unknown }) -> unknown }
--:: Individual = { genome: unknown, fitness: number }
--:: Population = { [integer]: Individual }
--:: ConvergeOpts = { window?: integer, min_improvement?: number }
--:: GeneticOpts = { create: (Rng) -> unknown, fitness: (unknown) -> number, crossover?: (unknown, unknown, Rng) -> unknown, mutate?: (unknown, Rng) -> unknown, population_size?: integer, generations?: integer, mutation_rate?: number, crossover_rate?: number, elitism?: integer, selection?: string, tournament_size?: integer, seed?: number, rng?: Rng, converge?: ConvergeOpts }

-- ── PRNG (LCG, same as lib/test/gen) ────────────────────────────────────────

local LCG_MOD = 2^32
local LCG_A   = 1664525
local LCG_C   = 1013904223

local function make_rng(seed)
  if not seed then error("genetic: seed is required") end
  local state = math.floor(seed) % LCG_MOD
  if state == 0 then state = 12345 end
  local rng = { seed = seed }
  function rng:next()
    state = (state * LCG_A + LCG_C) % LCG_MOD
    return state
  end
  function rng:float()
    return self:next() / LCG_MOD
  end
  function rng:int(lo, hi)
    if lo >= hi then return lo end
    return lo + (self:next() % (hi - lo + 1))
  end
  function rng:bool() return self:next() % 2 == 0 end
  function rng:pick(t) return t[1 + (self:next() % #t)] end
  return rng
end

-- ── Selection strategies ─────────────────────────────────────────────────────

-- Tournament selection: pick `k` individuals at random, return the best.
local function select_tournament(pop, rng, k)
  local best = pop[rng:int(1, #pop)]
  for _ = 2, k do
    local candidate = pop[rng:int(1, #pop)]
    if candidate.fitness > best.fitness then
      best = candidate
    end
  end
  return best
end

-- Roulette wheel (fitness-proportionate) selection.
-- Returns a selector function that accepts (pop, rng).
--: (Population, Rng) -> Individual
local function select_roulette(pop, rng)
  -- Compute total fitness. If all fitness <= 0, fall back to uniform.
  local total = 0.0 --[[: number]]
  for i = 1, #pop do
    local f = pop[i].fitness
    if f > 0 then total = total + f end
  end
  if total <= 0 then
    return pop[rng:int(1, #pop)] --[[:! Individual]]
  end
  local r = rng:float() * total
  local cumulative = 0.0 --[[: number]]
  for i = 1, #pop do
    local f = pop[i].fitness
    if f > 0 then cumulative = cumulative + f end
    if cumulative >= r then return pop[i] end
  end
  return pop[#pop]
end

-- Rank-based selection: rank individuals by fitness (1 = worst, N = best),
-- select proportionally to rank.
local function select_rank(pop, rng, ranked)
  -- ranked is a sorted (ascending) copy of pop indices by fitness
  -- rank[i] = i (1-based), total = N*(N+1)/2
  local n = #ranked
  local total = n * (n + 1) / 2
  local r = math.floor(rng:float() * total)
  local cumulative = 0
  for rank = 1, n do
    cumulative = cumulative + rank
    if cumulative > r then
      return ranked[rank]
    end
  end
  return ranked[n]
end

-- Build rank index (ascending fitness order) for rank selection.
local function build_rank_index(pop)
  local indices = {}
  for i = 1, #pop do indices[i] = pop[i] end
  table.sort(indices, function(a, b) return a.fitness < b.fitness end)
  return indices
end

-- ── Population creation ──────────────────────────────────────────────────────

--- Create an initial population.
--- opts: { create, fitness, population_size, seed }
--- Returns array of { genome, fitness }.
--: (GeneticOpts) -> (Population | nil, string | nil)
function M.population(opts)
  if not opts then return nil, "opts required" end
  if not opts.create then return nil, "opts.create required" end
  if not opts.fitness then return nil, "opts.fitness required" end

  local n    = opts.population_size or 100
  local rng  = make_rng(opts.seed)
  local pop  = {}

  for i = 1, n do
    local genome = opts.create(rng)
    pop[i] = { genome = genome, fitness = opts.fitness(genome) }
  end

  return pop
end

-- ── One generation step ──────────────────────────────────────────────────────

--- Advance one generation.
--- pop: array of { genome, fitness }
--- opts: { fitness, crossover, mutate, mutation_rate, crossover_rate, elitism,
---          selection, tournament_size }
--- Returns new population (same size as input).
--: (Population | nil, GeneticOpts) -> (Population | nil, string | nil)
function M.step(pop, opts)
  if not pop then return nil, "pop required" end
  if not opts then return nil, "opts required" end
  if not opts.fitness then return nil, "opts.fitness required" end

  local n              = #pop
  local mutation_rate  = opts.mutation_rate  or 0.1
  local crossover_rate = opts.crossover_rate or 0.8
  local elitism        = opts.elitism        or 0
  local selection      = opts.selection      or "tournament"
  local tournament_k   = opts.tournament_size or 3
  local rng            = opts.rng or make_rng(opts.seed)

  -- Sort descending by fitness for elitism.
  local sorted = {}
  for i = 1, n do sorted[i] = pop[i] end
  table.sort(sorted, function(a, b) return a.fitness > b.fitness end)

  -- Build rank index if needed.
  local rank_index
  if selection == "rank" then
    rank_index = build_rank_index(pop)
  end

  -- Selection function.
  local function select_one()
    if selection == "tournament" then
      return select_tournament(pop, rng, tournament_k)
    elseif selection == "roulette" then
      return select_roulette(pop, rng)
    elseif selection == "rank" then
      return select_rank(pop, rng, rank_index)
    else
      return nil, "unknown selection strategy: " .. tostring(selection)
    end
  end

  local new_pop = {}

  -- Elitism: carry top individuals unchanged.
  local elite_count = math.min(elitism, n)
  for i = 1, elite_count do
    new_pop[i] = sorted[i]
  end

  -- Fill the rest via crossover + mutation.
  local i = elite_count + 1
  while i <= n do
    local parent_a = select_one()
    local genome

    if opts.crossover and rng:float() < crossover_rate then
      local parent_b = select_one()
      genome = opts.crossover(parent_a.genome, parent_b.genome, rng)
    else
      -- Clone (shallow copy for tables).
      if type(parent_a.genome) == "table" then
        genome = {}
        for k, v in ipairs(parent_a.genome) do genome[k] = v end
      else
        genome = parent_a.genome
      end
    end

    if opts.mutate and rng:float() < mutation_rate then
      genome = opts.mutate(genome, rng)
    end

    new_pop[i] = { genome = genome, fitness = opts.fitness(genome) }
    i = i + 1
  end

  return new_pop
end

-- ── Full run ─────────────────────────────────────────────────────────────────

--- Run the genetic algorithm.
--- opts: all of step opts, plus:
---   generations, converge = { min_improvement, window }
--- Returns { best, fitness, generation, history }.
--: (GeneticOpts) -> ({ best: unknown, fitness: number, generation: integer, history: { [integer]: unknown } } | nil, string | nil)
function M.run(opts)
  if not opts then return nil, "opts required" end
  if not opts.create  then return nil, "opts.create required" end
  if not opts.fitness then return nil, "opts.fitness required" end

  local generations  = opts.generations or 100
  local converge     = opts.converge
  local rng          = make_rng(opts.seed)

  -- Share the rng across steps so seed is deterministic end-to-end.
  local step_opts = {} --[[:! GeneticOpts]]
  for k, v in pairs(opts) do step_opts[k] = v end --[[ safe: GeneticOpts has string keys ]]
  step_opts.rng = rng

  -- Initial population.
  local pop_opts = {}
  for k, v in pairs(opts) do pop_opts[k] = v end
  pop_opts.rng  = nil  -- population() creates its own from seed when no rng
  -- Pass the shared rng to population creation by inlining it here.
  local n   = opts.population_size or 100
  local pop = {}
  for i = 1, n do
    local genome = opts.create(rng)
    pop[i] = { genome = genome, fitness = opts.fitness(genome) }
  end

  -- Find initial best.
  local function pop_stats(p)
    local best     = p[1]
    local sum      = 0
    for i = 1, #p do
      if p[i].fitness > best.fitness then best = p[i] end
      sum = sum + p[i].fitness
    end
    return best, sum / #p
  end

  local history       = {}
  local best_ind, avg = pop_stats(pop)
  history[1]          = { 0, best_ind.fitness, avg }

  -- Convergence window buffer.
  local plateau_buf = {} --[[: { [integer]: number }]]
  local buf_size      = converge and (converge.window or 20) or 0
  local min_improve   = converge and (converge.min_improvement or 0.001) or 0

  local found_gen = 0

  for gen = 1, generations do
    local next_pop = M.step(pop, step_opts)
    if not next_pop then break end
    pop = next_pop

    local cur_best, cur_avg = pop_stats(pop)
    history[gen + 1] = { gen, cur_best.fitness, cur_avg }

    if cur_best.fitness > best_ind.fitness then
      best_ind  = cur_best
      found_gen = gen
    end

    -- Early stopping: check plateau.
    if converge then
      plateau_buf[#plateau_buf + 1] = cur_best.fitness
      if #plateau_buf > buf_size then
        table.remove(plateau_buf, 1)
      end
      if #plateau_buf == buf_size then
        local oldest = plateau_buf[1]
        local newest = plateau_buf[buf_size]
        local improvement = math.abs(newest - oldest)
        if improvement < min_improve then
          break
        end
      end
    end
  end

  return {
    best       = best_ind.genome,
    fitness    = best_ind.fitness,
    generation = found_gen,
    history    = history,
  }
end

-- ── Built-in genome helpers ──────────────────────────────────────────────────

M.genomes = {}

--- Binary genome helpers (bit arrays as tables of 0/1).
--- length: integer
--- Returns { create, crossover, mutate }.
function M.genomes.binary(length)
  return {
    create = function(rng)
      local g = {}
      for i = 1, length do
        g[i] = rng:int(0, 1)
      end
      return g
    end,

    -- Single-point crossover.
    crossover = function(a, b, rng)
      local child = {}
      local point = rng:int(1, length)
      for i = 1, length do
        child[i] = i <= point and a[i] or b[i]
      end
      return child
    end,

    -- Flip a random bit.
    mutate = function(individual, rng)
      local idx = rng:int(1, length)
      local copy = {}
      for i = 1, length do copy[i] = individual[i] end
      copy[idx] = 1 - copy[idx]
      return copy
    end,
  }
end

--- Real-valued genome helpers (arrays of floats in [min, max]).
--- length: integer, lo: number, hi: number
--- Returns { create, crossover, mutate }.
function M.genomes.real(length, lo, hi)
  lo = lo or 0
  hi = hi or 1
  local range = hi - lo
  return {
    create = function(rng)
      local g = {}
      for i = 1, length do
        g[i] = lo + rng:float() * range
      end
      return g
    end,

    -- Arithmetic crossover (blend).
    crossover = function(a, b, rng)
      local child = {}
      local alpha = rng:float()
      for i = 1, length do
        child[i] = alpha * a[i] + (1 - alpha) * b[i]
      end
      return child
    end,

    -- Gaussian-like mutation: replace one gene with a random value in range.
    --: ({ [integer]: number }, Rng) -> { [integer]: number }
    mutate = function(individual, rng)
      local idx  = rng:int(1, length)
      local copy = {} --[[: { [integer]: number }]]
      for i = 1, length do copy[i] = individual[i] end
      copy[idx] = lo + rng:float() * range
      return copy
    end,
  }
end

--- Permutation genome helpers (arrays that are permutations of 1..length).
--- Uses Order Crossover (OX1) which produces valid permutations.
--- Returns { create, crossover, mutate }.
function M.genomes.permutation(length)
  return {
    create = function(rng)
      local g = {}
      for i = 1, length do g[i] = i end
      -- Fisher-Yates shuffle using rng.
      for i = length, 2, -1 do
        local j = rng:int(1, i)
        g[i], g[j] = g[j], g[i]
      end
      return g
    end,

    -- Order crossover (OX1): preserves relative order from parent B
    -- for genes not in the copied segment from parent A.
    crossover = function(a, b, rng)
      local p1 = rng:int(1, length)
      local p2 = rng:int(1, length)
      if p1 > p2 then p1, p2 = p2, p1 end

      local child    = {}
      local in_child = {}

      -- Copy segment from A.
      for i = p1, p2 do
        child[i]          = a[i]
        in_child[a[i]]    = true
      end

      -- Fill remaining positions in order from B.
      local pos = p2 % length + 1  -- position after p2 (wraps around)
      local bi  = p2 % length + 1
      local filled = p2 - p1 + 1
      while filled < length do
        local gene = b[bi]
        if not in_child[gene] then
          child[pos]      = gene
          in_child[gene]  = true
          pos             = pos % length + 1
          filled          = filled + 1
        end
        bi = bi % length + 1
      end

      return child
    end,

    -- Swap mutation: swap two random positions.
    mutate = function(individual, rng)
      local i    = rng:int(1, length)
      local j    = rng:int(1, length)
      local copy = {}
      for k = 1, length do copy[k] = individual[k] end
      copy[i], copy[j] = copy[j], copy[i]
      return copy
    end,
  }
end

return M
