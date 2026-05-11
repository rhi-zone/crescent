if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Simulated annealing optimization library.
-- Minimizes an energy function over a state space by accepting worse solutions
-- with a probability that decreases with temperature.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- LCG random number generator (seeded, portable)
-- ---------------------------------------------------------------------------

--:: RNG = { state: number, next: (self: RNG) -> number, float: (self: RNG) -> number, int: (self: RNG, number, number) -> number }
local RNG = {}
RNG.__index = RNG

-- LCG constants (Numerical Recipes)
local LCG_A = 1664525
local LCG_C = 1013904223
local LCG_M = 2^32

--: (number) -> RNG
function RNG.new(seed)
  local seed_ = seed --[[:! number]]
  local obj = setmetatable({ state = seed_ % LCG_M }, RNG) --[[: unknown]]
  return obj --[[:! RNG]]
end

function RNG:next()
  self.state = (LCG_A * self.state + LCG_C) % LCG_M
  return self.state
end

-- Returns float in [0, 1)
function RNG:float()
  return self:next() / LCG_M
end

-- Returns integer in [lo, hi] inclusive
function RNG:int(lo, hi)
  return lo + math.floor(self:float() * (hi - lo + 1))
end

-- ---------------------------------------------------------------------------
-- Temperature schedules
-- ---------------------------------------------------------------------------

M.schedules = {}

-- Exponential cooling: T(k) = T0 * (Tend/T0)^(k/steps)
function M.schedules.exponential(T0, Tend, steps)
  local ratio = Tend / T0
  return function(step, _total)
    return T0 * (ratio ^ (step / steps))
  end
end

-- Linear cooling: T(k) = T0 - (T0 - Tend) * (k/steps)
function M.schedules.linear(T0, Tend, steps)
  local range = T0 - Tend
  return function(step, _total)
    local t = step / steps
    if t > 1 then t = 1 end
    return T0 - range * t
  end
end

-- Logarithmic cooling: T(k) = T0 / log(1 + k)  (slow, theoretically optimal)
-- Scaled so T(steps) ≈ Tend.
function M.schedules.logarithmic(T0, Tend, steps)
  -- T(steps) = T0 / log(1+steps) => scale = T0 / log(1+steps)
  -- Then clamp to Tend as floor.
  local scale = T0 / math.log(1 + steps)
  return function(step, _total)
    local t = scale / math.log(1 + step + 1)  -- +1 so step=0 is finite
    if t < Tend then t = Tend end
    return t
  end
end

-- Geometric cooling: like exponential but with configurable alpha per step
-- T(k) = T0 * alpha^k; alpha chosen so T(steps) = Tend
function M.schedules.geometric(T0, Tend, steps)
  local alpha = (Tend / T0) ^ (1 / steps)
  return function(step, _total)
    return T0 * (alpha ^ step)
  end
end

-- Wrap a user-supplied function as a schedule
function M.schedules.custom(fn)
  return fn
end

--:: SAOpts = { initial: unknown, energy: (unknown) -> number, neighbor: (unknown, RNG) -> unknown, schedule: unknown, temp_start: number | nil, temp_end: number | nil, steps: integer | nil, accept: ((number, number) -> number) | nil, seed: number | nil, on_accept: ((unknown, number, number, integer) -> nil) | nil, on_improve: ((unknown, number, integer) -> nil) | nil, track_history: boolean | nil, ... }

-- Resolve a schedule name or function into a callable temperature function
local function resolve_schedule(opts)
  local opts_ = opts --[[:! SAOpts]]
  local name = opts_.schedule or "exponential"
  local T0   = opts_.temp_start or 100.0
  local Tend = opts_.temp_end   or 0.01
  local steps = opts_.steps     or 10000
  if type(name) == "function" then
    return name
  end
  local builder = M.schedules[name]
  if not builder then
    return nil, "unknown schedule: " .. tostring(name)
  end
  return builder(T0, Tend, steps)
end

-- Default Boltzmann acceptance criterion
-- P(accept) = exp(-delta_e / temp) when delta_e > 0
local function boltzmann(delta_e, temp)
  if temp <= 0 then return 0 end
  return math.exp(-delta_e / temp)
end

-- ---------------------------------------------------------------------------
-- Single step
-- ---------------------------------------------------------------------------

-- Perform one SA step.
-- state      : current state
-- energy     : current energy (number)
-- temp       : current temperature
-- opts.energy    : energy function
-- opts.neighbor  : neighbor generator function(state, rng) -> new_state
-- opts.accept    : acceptance function(delta_e, temp) -> probability (optional)
-- rng        : RNG object
-- Returns: new_state, new_energy, accepted (bool)
--: (unknown, number, number, SAOpts, RNG) -> (unknown, number, boolean)
function M.step(state, energy, temp, opts, rng)
  local opts_ = opts --[[:! SAOpts]]
  local neighbor_fn = opts_.neighbor
  local energy_fn   = opts_.energy
  local accept_fn   = opts_.accept or boltzmann

  local candidate        = neighbor_fn(state, rng)
  local candidate_energy = energy_fn(candidate)
  local delta_e          = candidate_energy - energy

  local accepted
  if delta_e < 0 then
    -- Always accept improvements
    accepted = true
  else
    local p = accept_fn(delta_e, temp)
    accepted = rng:float() < p
  end

  if accepted then
    return candidate, candidate_energy, true
  else
    return state, energy, false
  end
end

-- ---------------------------------------------------------------------------
-- Full run
-- ---------------------------------------------------------------------------

-- Run simulated annealing.
-- opts fields:
--   initial      : starting state
--   energy       : function(state) -> number
--   neighbor     : function(state, rng) -> new_state
--   schedule     : "exponential"|"linear"|"logarithmic"|"geometric"|fn (default "exponential")
--   temp_start   : initial temperature (default 100.0)
--   temp_end     : final temperature (default 0.01)
--   steps        : number of steps (default 10000)
--   accept       : function(delta_e, temp) -> probability (optional, default Boltzmann)
--   seed         : RNG seed (default 0)
--   on_accept    : function(state, energy, temp, step) (optional callback)
--   on_improve   : function(state, energy, step) (optional callback)
--   track_history: bool — if true, record {step, energy, temp} each step
--
-- Returns result table or (nil, errmsg).
--: (SAOpts) -> ({ state: unknown, energy: number, steps: integer, accepted: integer, improved: integer, history: { [integer]: { [integer]: number } } | nil } | nil, string | nil)
function M.run(opts)
  if not opts then return nil, "opts required" end
  local opts_ = opts --[[:! SAOpts]]
  if not opts_.initial then return nil, "opts.initial required" end
  if not opts_.energy then return nil, "opts.energy required" end
  if not opts_.neighbor then return nil, "opts.neighbor required" end

  local steps = opts_.steps or 10000
  local rng = RNG.new(opts_.seed or 0)

  local temp_fn, err = resolve_schedule(opts_)
  if not temp_fn then return nil, err end

  local state  = opts_.initial
  local energy = opts_.energy(state)

  -- Track best
  local best_state  = state
  local best_energy = energy

  local accepted_count = 0
  local improved_count = 0
  local history --: { [integer]: { [integer]: number } } | nil
  if opts_.track_history then history = {} end

  local on_accept  = opts_.on_accept
  local on_improve = opts_.on_improve

  for step = 0, steps - 1 do
    local temp = temp_fn(step, steps)

    local new_state, new_energy, was_accepted =
      M.step(state, energy, temp, opts_, rng)

    if was_accepted then
      state  = new_state
      energy = new_energy
      accepted_count = accepted_count + 1

      if on_accept then
        local on_accept_ = on_accept --[[:! (unknown, number, number, integer) -> nil]]
        on_accept_(state, energy, temp, step)
      end

      if energy < best_energy then
        best_state  = state
        best_energy = energy
        improved_count = improved_count + 1

        if on_improve then
          local on_improve_ = on_improve --[[:! (unknown, number, integer) -> nil]]
          on_improve_(state, energy, step)
        end
      end
    end

    if history then
      local h = history --[[:! { [integer]: { [integer]: number } }]]
      h[#h + 1] = { step, energy, temp }
    end
  end

  return {
    state    = best_state,
    energy   = best_energy,
    steps    = steps,
    accepted = accepted_count,
    improved = improved_count,
    history  = history,
  }
end

-- ---------------------------------------------------------------------------
-- TSP helper
-- ---------------------------------------------------------------------------

-- Compute Euclidean tour length for a permutation of cities.
local function tour_length(perm, cities)
  local n   = #perm
  local len = 0 --: number
  for i = 1, n do
    local a = cities[perm[i]]
    local b = cities[perm[(i % n) + 1]]
    local dx = a[1] - b[1]
    local dy = a[2] - b[2]
    len = len + math.sqrt(dx * dx + dy * dy)
  end
  return len
end

-- Perform a 2-opt swap: reverse the segment [i+1 .. j] in the permutation.
local function two_opt_swap(perm, i, j)
  local new_perm = {}
  for k = 1, #perm do new_perm[k] = perm[k] end
  -- Reverse segment i+1 .. j
  local lo, hi = i + 1, j
  while lo < hi do
    new_perm[lo], new_perm[hi] = new_perm[hi], new_perm[lo]
    lo = lo + 1
    hi = hi - 1
  end
  return new_perm
end

-- Solve TSP with simulated annealing.
-- cities: array of {x, y} (1-indexed)
-- opts:   any SA opts (schedule, steps, seed, etc.)
-- Returns the same result table as M.run, with state being the best permutation.
function M.tsp(cities, opts)
  opts = opts or {}
  local n = #cities

  -- Build initial tour: [1, 2, ..., n]
  local initial = {}
  for i = 1, n do initial[i] = i end

  opts.initial = opts.initial or initial

  opts.energy = opts.energy or function(perm)
    return tour_length(perm, cities)
  end

  opts.neighbor = opts.neighbor or function(perm, rng)
    -- Pick two distinct indices for 2-opt swap
    local i = rng:int(1, n - 1)
    local j = rng:int(i + 1, n)
    return two_opt_swap(perm, i, j)
  end

  return M.run(opts)
end

return M
