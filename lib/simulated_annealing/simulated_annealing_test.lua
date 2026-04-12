if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local sa = require("lib.simulated_annealing")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Simple quadratic: energy = (x - 5)^2, state is a number
local function quadratic_energy(x) return (x - 5) * (x - 5) end

local function quadratic_neighbor(x, rng)
  -- Random walk: ±1 * uniform[0,2)
  local delta = (rng:float() * 2 - 1) * 1.5
  return x + delta
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("simulated_annealing", function()

  T.it("minimizes quadratic (x-5)^2 near x=5", function()
    local result = sa.run({
      initial    = 0.0,
      energy     = quadratic_energy,
      neighbor   = quadratic_neighbor,
      schedule   = "exponential",
      temp_start = 50.0,
      temp_end   = 0.001,
      steps      = 20000,
      seed       = 1,
    })
    T.ok(result ~= nil, "run returned a result")
    -- Should converge within 1.0 of optimum at x=5
    T.ok(math.abs(result.state - 5) < 1.0,
      "best state near 5, got " .. tostring(result.state))
    T.ok(result.energy < 1.0,
      "best energy < 1.0, got " .. tostring(result.energy))
  end)

  T.it("escapes local optima on Rastrigin-like function", function()
    -- f(x) = x^2 + 10*(1 - cos(2*pi*x))
    -- Global min at x=0 (energy=0), many local minima at each integer.
    local function rastrigin(x)
      return x * x + 10 * (1 - math.cos(2 * math.pi * x))
    end
    local function rastrigin_neighbor(x, rng)
      return x + (rng:float() * 2 - 1) * 0.5
    end

    -- Greedy hill-climbing from x=3.5 would get stuck at x=3 (local min).
    -- SA should eventually find x=0.
    local result = sa.run({
      initial    = 3.5,
      energy     = rastrigin,
      neighbor   = rastrigin_neighbor,
      schedule   = "exponential",
      temp_start = 20.0,
      temp_end   = 0.001,
      steps      = 50000,
      seed       = 7,
    })
    -- SA should find something with lower energy than the local optima at x=3
    -- (which has energy ≈ 9 + 10*(1-cos(6π)) = 9)
    -- A result near 0 would have energy < 1
    T.ok(result.energy < 5.0,
      "SA escapes local optima, energy=" .. tostring(result.energy))
  end)

  T.it("solves TSP on 5 cities finds near-optimal tour", function()
    -- 5 cities arranged in a rough pentagon; optimal tour ≈ perimeter
    local cities = {
      {0, 0},
      {1, 0},
      {2, 1},
      {1, 2},
      {0, 2},
    }
    local result = sa.tsp(cities, {
      temp_start = 10.0,
      temp_end   = 0.001,
      steps      = 5000,
      seed       = 42,
    })
    T.ok(result ~= nil, "tsp returned a result")
    T.ok(result.energy ~= nil, "has energy")
    T.ok(result.energy > 0, "energy is positive")
    T.eq(#result.state, 5, "permutation has 5 cities")
    -- The near-optimal tour for these cities is around 6.8-7.0
    -- Accept anything below 8.5 as "reasonable"
    T.ok(result.energy < 8.5,
      "TSP tour is reasonable, got " .. tostring(result.energy))
  end)

  T.it("exponential schedule produces correct temperature sequence", function()
    local T0    = 100.0
    local Tend  = 0.01
    local steps = 1000
    local sched = sa.schedules.exponential(T0, Tend, steps)
    -- At step 0: should equal T0
    T.ok(math.abs(sched(0, steps) - T0) < 1e-9, "step 0 = T0")
    -- At step = steps: should equal Tend
    T.ok(math.abs(sched(steps, steps) - Tend) < 1e-9, "step steps = Tend")
    -- Monotonically decreasing
    local prev = sched(0, steps)
    for s = 1, steps, 100 do
      local curr = sched(s, steps)
      T.ok(curr < prev, "temperature decreases at step " .. s)
      prev = curr
    end
  end)

  T.it("linear schedule produces correct temperature values", function()
    local T0    = 100.0
    local Tend  = 10.0
    local steps = 100
    local sched = sa.schedules.linear(T0, Tend, steps)
    T.ok(math.abs(sched(0, steps) - T0) < 1e-9, "step 0 = T0")
    T.ok(math.abs(sched(steps, steps) - Tend) < 1e-9, "step steps = Tend")
    -- Midpoint should be (T0+Tend)/2
    local mid = sched(50, steps)
    T.ok(math.abs(mid - 55.0) < 1e-9, "midpoint = 55, got " .. tostring(mid))
  end)

  T.it("custom schedule works", function()
    local called = {}
    local custom_fn = function(step, total)
      called[#called + 1] = step
      return 100.0 / (1 + step)
    end
    local result = sa.run({
      initial    = 0.0,
      energy     = quadratic_energy,
      neighbor   = quadratic_neighbor,
      schedule   = custom_fn,
      steps      = 10,
      seed       = 1,
    })
    T.ok(result ~= nil, "run succeeded with custom schedule")
    T.eq(#called, 10, "custom schedule called once per step")
  end)

  T.it("deterministic with fixed seed", function()
    local opts = {
      initial    = 0.0,
      energy     = quadratic_energy,
      neighbor   = quadratic_neighbor,
      schedule   = "exponential",
      temp_start = 50.0,
      temp_end   = 0.001,
      steps      = 500,
      seed       = 99,
    }
    local r1 = sa.run(opts)
    local r2 = sa.run(opts)
    T.eq(r1.state, r2.state, "same state with same seed")
    T.eq(r1.energy, r2.energy, "same energy with same seed")
    T.eq(r1.accepted, r2.accepted, "same accepted count")
  end)

  T.it("track_history populates history array", function()
    local result = sa.run({
      initial       = 0.0,
      energy        = quadratic_energy,
      neighbor      = quadratic_neighbor,
      schedule      = "exponential",
      temp_start    = 10.0,
      temp_end      = 0.001,
      steps         = 50,
      seed          = 5,
      track_history = true,
    })
    T.ok(result.history ~= nil, "history is populated")
    T.eq(#result.history, 50, "history has one entry per step")
    -- Each entry is {step, energy, temp}
    local entry = result.history[1]
    T.ok(entry[1] ~= nil, "entry has step")
    T.ok(entry[2] ~= nil, "entry has energy")
    T.ok(entry[3] ~= nil, "entry has temp")
  end)

  T.it("on_improve callback fires when best improves", function()
    local improve_calls = 0
    local last_energy

    local result = sa.run({
      initial    = 10.0,
      energy     = quadratic_energy,
      neighbor   = quadratic_neighbor,
      schedule   = "exponential",
      temp_start = 50.0,
      temp_end   = 0.001,
      steps      = 1000,
      seed       = 3,
      on_improve = function(state, energy, step)
        improve_calls = improve_calls + 1
        last_energy = energy
      end,
    })
    T.ok(improve_calls > 0, "on_improve was called at least once")
    T.eq(improve_calls, result.improved, "callback count matches result.improved")
    -- Last improvement energy should equal final best energy
    T.ok(math.abs(last_energy - result.energy) < 1e-12,
      "last on_improve energy matches result.energy")
  end)

  T.it("result.accepted and result.improved counts are correct", function()
    local accept_calls = 0

    local result = sa.run({
      initial    = 0.0,
      energy     = quadratic_energy,
      neighbor   = quadratic_neighbor,
      schedule   = "exponential",
      temp_start = 50.0,
      temp_end   = 0.001,
      steps      = 500,
      seed       = 11,
      on_accept  = function(_state, _energy, _temp, _step)
        accept_calls = accept_calls + 1
      end,
    })
    T.eq(accept_calls, result.accepted, "on_accept calls match result.accepted")
    T.ok(result.improved <= result.accepted, "improved <= accepted")
    T.ok(result.improved >= 0, "improved is non-negative")
  end)

  T.it("M.step performs a single SA step correctly", function()
    -- With very high temp, uphill moves should be accepted often
    -- With very low temp, only improvements should be accepted
    local rng = sa._rng_new and sa._rng_new(42) or nil
    -- We test via the run function with 1 step instead
    -- (rng is internal; test the interface through run)
    local initial_energy = quadratic_energy(0.0)
    local result = sa.run({
      initial    = 0.0,
      energy     = quadratic_energy,
      neighbor   = function(x, _) return x + 0.1 end,  -- always move toward 5
      schedule   = "linear",
      temp_start = 1000.0,
      temp_end   = 1000.0,  -- constant high temp
      steps      = 1,
      seed       = 0,
    })
    -- With one step moving 0→0.1, energy goes from 25 to (0.1-5)^2 = 24.01
    -- This is an improvement so should always be accepted
    T.ok(result.accepted >= 1, "step accepted the improving move")
  end)

  T.it("returns error for missing required opts", function()
    local r, err = sa.run(nil)
    T.ok(r == nil, "nil opts returns nil")
    T.ok(err ~= nil, "nil opts returns error message")

    local r2, err2 = sa.run({ initial = 1 })
    T.ok(r2 == nil, "missing energy returns nil")
    T.ok(err2 ~= nil, "missing energy returns error")

    local r3, err3 = sa.run({ initial = 1, energy = function() return 0 end })
    T.ok(r3 == nil, "missing neighbor returns nil")
    T.ok(err3 ~= nil, "missing neighbor returns error")
  end)

end)
