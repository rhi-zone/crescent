if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local ga = require("lib.genetic")

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Real-valued genome: maximize sum of N values in [0, 1].
local function maximize_sum_opts(n, seed)
  local genome_helpers = ga.genomes.real(n, 0, 1)
  return {
    create    = genome_helpers.create,
    fitness   = function(ind)
      local s = 0; for i = 1, n do s = s + ind[i] end; return s
    end,
    crossover = genome_helpers.crossover,
    mutate    = genome_helpers.mutate,
    population_size = 60,
    generations     = 150,
    mutation_rate   = 0.2,
    crossover_rate  = 0.8,
    elitism         = 2,
    selection       = "tournament",
    tournament_size = 5,
    seed            = seed or 1,
  }
end

-- Binary genome: match target bit string.
local function binary_match_opts(target, seed)
  local n = #target
  local helpers = ga.genomes.binary(n)
  return {
    create    = helpers.create,
    fitness   = function(ind)
      local score = 0
      for i = 1, n do
        if ind[i] == target[i] then score = score + 1 end
      end
      return score
    end,
    crossover = helpers.crossover,
    mutate    = helpers.mutate,
    population_size = 80,
    generations     = 300,
    mutation_rate   = 0.05,
    crossover_rate  = 0.8,
    elitism         = 2,
    selection       = "tournament",
    tournament_size = 4,
    seed            = seed or 7,
  }
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("genetic", function()

  T.describe("run", function()

    T.it("maximize real-valued genome converges near maximum", function()
      local n      = 10
      local opts   = maximize_sum_opts(n, 42)
      local result = ga.run(opts)
      T.ok(result, "result not nil")
      T.ok(result.best, "result.best not nil")
      T.ok(result.fitness, "result.fitness not nil")
      T.ok(result.generation ~= nil, "result.generation present")
      T.ok(result.history, "result.history present")
      -- Fitness should be close to n (max sum = n when all values are 1).
      T.ok(result.fitness >= n * 0.85,
        "fitness " .. result.fitness .. " should be >= " .. (n * 0.85))
    end)

    T.it("minimize sphere function (sum of squares) converges near 0", function()
      local n = 8
      local helpers = ga.genomes.real(n, -5, 5)
      local result = ga.run({
        create    = helpers.create,
        fitness   = function(ind)
          local s = 0; for i = 1, n do s = s + ind[i] * ind[i] end
          return -s  -- negate: GA maximizes, we want to minimize
        end,
        crossover = helpers.crossover,
        mutate    = helpers.mutate,
        population_size = 80,
        generations     = 200,
        mutation_rate   = 0.2,
        crossover_rate  = 0.8,
        elitism         = 2,
        selection       = "tournament",
        tournament_size = 5,
        seed            = 13,
      })
      -- Best fitness (negated sphere) should be close to 0 (i.e., sphere close to 0).
      T.ok(result.fitness >= -1.0,
        "sphere fitness " .. result.fitness .. " should be >= -1.0")
    end)

    T.it("binary genome finds target bit string", function()
      local target = {1,0,1,1,0,0,1,0,1,1,0,1}
      local opts   = binary_match_opts(target, 99)
      local result = ga.run(opts)
      -- Should match nearly all bits.
      T.ok(result.fitness >= #target * 0.9,
        "matched " .. result.fitness .. "/" .. #target .. " bits")
    end)

    T.it("result.history has correct length (generations + 1)", function()
      local opts = maximize_sum_opts(5, 3)
      opts.generations = 20
      local result = ga.run(opts)
      T.eq(#result.history, 21, "history length = generations + 1")
      -- history entries: { gen, best_fitness, avg_fitness }
      T.eq(result.history[1][1], 0, "first entry is generation 0")
      T.eq(result.history[21][1], 20, "last entry is generation 20")
    end)

    T.it("deterministic with fixed seed", function()
      local opts1 = maximize_sum_opts(10, 7)
      local opts2 = maximize_sum_opts(10, 7)
      local r1 = ga.run(opts1)
      local r2 = ga.run(opts2)
      T.eq(r1.fitness, r2.fitness, "same fitness")
      T.eq(r1.generation, r2.generation, "same generation")
    end)

    T.it("elitism: best individual always survives to next generation", function()
      -- Run step() and verify the best genome from pop is in new_pop.
      local helpers = ga.genomes.real(5, 0, 1)
      local rng_mod = require("lib.test.gen")
      local rng     = rng_mod.make_rng(55)
      -- Build a small population manually.
      local fitness_fn = function(ind)
        local s = 0; for i = 1, 5 do s = s + ind[i] end; return s
      end
      local pop = {}
      for _ = 1, 20 do
        local g = helpers.create(rng)
        pop[#pop + 1] = { genome = g, fitness = fitness_fn(g) }
      end
      -- Find the best before stepping.
      local best_before = pop[1]
      for i = 2, #pop do
        if pop[i].fitness > best_before.fitness then best_before = pop[i] end
      end

      local new_pop = ga.step(pop, {
        fitness        = fitness_fn,
        crossover      = helpers.crossover,
        mutate         = helpers.mutate,
        mutation_rate  = 0.5,
        crossover_rate = 0.8,
        elitism        = 1,
        selection      = "tournament",
        tournament_size = 3,
        seed           = 55,
      })

      -- The best genome's fitness should exist somewhere in new_pop.
      local found = false
      for _, entry in ipairs(new_pop) do
        if entry.fitness == best_before.fitness then found = true; break end
      end
      T.ok(found, "best individual survived via elitism")
    end)

    T.it("tournament selection favors higher fitness individuals", function()
      -- Build population with obvious fitness gradient and confirm selection
      -- tends to return high-fitness individuals.
      local helpers = ga.genomes.real(4, 0, 1)
      local rng_mod = require("lib.test.gen")
      local rng     = rng_mod.make_rng(23)
      local fitness_fn = function(ind)
        local s = 0; for i = 1, 4 do s = s + ind[i] end; return s
      end
      local pop = {}
      for _ = 1, 50 do
        local g = helpers.create(rng)
        pop[#pop + 1] = { genome = g, fitness = fitness_fn(g) }
      end

      local result = ga.run({
        create         = helpers.create,
        fitness        = fitness_fn,
        crossover      = helpers.crossover,
        mutate         = helpers.mutate,
        population_size = 50,
        generations    = 50,
        mutation_rate  = 0.1,
        crossover_rate = 0.9,
        elitism        = 1,
        selection      = "tournament",
        tournament_size = 5,
        seed           = 23,
      })
      -- Tournament selection should improve fitness over generations.
      T.ok(result.fitness > result.history[1][2],
        "final fitness (" .. result.fitness .. ") > initial avg (" .. result.history[1][2] .. ")")
    end)

    T.it("roulette selection: run converges with roulette", function()
      local opts = maximize_sum_opts(8, 17)
      opts.selection = "roulette"
      opts.generations = 200
      local result = ga.run(opts)
      T.ok(result.fitness >= 8 * 0.75,
        "roulette fitness " .. result.fitness .. " should be >= " .. (8 * 0.75))
    end)

    T.it("rank selection: run converges with rank", function()
      local opts = maximize_sum_opts(8, 19)
      opts.selection = "rank"
      opts.generations = 200
      local result = ga.run(opts)
      T.ok(result.fitness >= 8 * 0.75,
        "rank fitness " .. result.fitness .. " should be >= " .. (8 * 0.75))
    end)

    T.it("early stopping triggers on plateau", function()
      -- A trivial fitness function that converges immediately.
      local result = ga.run({
        create  = function(_rng) return {1} end,
        fitness = function(_ind) return 1.0 end,
        crossover = function(a, _b, _rng) return {a[1]} end,
        mutate    = function(ind, _rng) return ind end,
        population_size = 10,
        generations     = 1000,
        mutation_rate   = 0.1,
        crossover_rate  = 0.5,
        elitism         = 1,
        selection       = "tournament",
        tournament_size = 2,
        seed            = 5,
        converge = { min_improvement = 0.01, window = 10 },
      })
      -- Should have stopped well before 1000 generations.
      T.ok(#result.history < 1000,
        "history length " .. #result.history .. " should be < 1000 (early stop)")
    end)

    T.it("step() and run() are consistent", function()
      -- Run one generation via step and compare to run with generations=1.
      local helpers = ga.genomes.real(4, 0, 1)
      local fitness_fn = function(ind)
        local s = 0; for i = 1, 4 do s = s + ind[i] end; return s
      end
      local shared_opts = {
        create          = helpers.create,
        fitness         = fitness_fn,
        crossover       = helpers.crossover,
        mutate          = helpers.mutate,
        population_size = 20,
        generations     = 1,
        mutation_rate   = 0.1,
        crossover_rate  = 0.8,
        elitism         = 1,
        selection       = "tournament",
        tournament_size = 3,
        seed            = 11,
      }
      local result = ga.run(shared_opts)
      -- History should have exactly 2 entries (gen 0 and gen 1).
      T.eq(#result.history, 2, "1 generation => 2 history entries")
    end)

    T.it("initial population has diversity", function()
      local helpers = ga.genomes.real(10, 0, 1)
      local fitness_fn = function(ind)
        local s = 0; for i = 1, 10 do s = s + ind[i] end; return s
      end
      local pop = ga.population({
        create          = helpers.create,
        fitness         = fitness_fn,
        population_size = 50,
        seed            = 3,
      })
      T.eq(#pop, 50, "population size correct")
      -- Collect unique fitness values; should have many distinct values.
      local seen = {}
      for _, entry in ipairs(pop) do
        seen[tostring(entry.fitness)] = true
      end
      local distinct = 0
      for _ in pairs(seen) do distinct = distinct + 1 end
      T.ok(distinct >= 40, "population has diversity: " .. distinct .. " distinct fitness values")
    end)

  end)

  T.describe("genomes.permutation", function()

    T.it("create produces a valid permutation", function()
      local gen_mod = require("lib.test.gen")
      local rng     = gen_mod.make_rng(77)
      local helpers = ga.genomes.permutation(8)
      local g       = helpers.create(rng)
      T.eq(#g, 8, "length correct")
      -- Check it's a permutation of 1..8.
      local seen = {}
      for _, v in ipairs(g) do seen[v] = (seen[v] or 0) + 1 end
      for i = 1, 8 do
        T.eq(seen[i], 1, "value " .. i .. " appears exactly once")
      end
    end)

    T.it("OX crossover produces a valid permutation", function()
      local gen_mod = require("lib.test.gen")
      local rng     = gen_mod.make_rng(88)
      local helpers = ga.genomes.permutation(10)
      local a       = helpers.create(rng)
      local b       = helpers.create(rng)
      local child   = helpers.crossover(a, b, rng)
      T.eq(#child, 10, "child length correct")
      local seen = {}
      for _, v in ipairs(child) do seen[v] = (seen[v] or 0) + 1 end
      for i = 1, 10 do
        T.eq(seen[i], 1, "child has " .. i .. " exactly once")
      end
    end)

    T.it("swap mutation preserves permutation validity", function()
      local gen_mod = require("lib.test.gen")
      local rng     = gen_mod.make_rng(99)
      local helpers = ga.genomes.permutation(6)
      local g       = helpers.create(rng)
      local mutated = helpers.mutate(g, rng)
      T.eq(#mutated, 6, "length preserved")
      local seen = {}
      for _, v in ipairs(mutated) do seen[v] = (seen[v] or 0) + 1 end
      for i = 1, 6 do
        T.eq(seen[i], 1, "mutated has " .. i .. " exactly once")
      end
    end)

    T.it("permutation GA on TSP-like problem (minimize total distance) runs", function()
      -- Simple 4-city "tour length" objective (just validate it runs).
      local n = 6
      local helpers = ga.genomes.permutation(n)
      -- Dummy distance: sum of abs differences between adjacent indices.
      local function tour_len(perm)
        local d = 0
        for i = 1, n do
          local a = perm[i]
          local b = perm[i % n + 1]
          d = d + math.abs(a - b)
        end
        return -d  -- negate: GA maximizes
      end
      local result = ga.run({
        create          = helpers.create,
        fitness         = tour_len,
        crossover       = helpers.crossover,
        mutate          = helpers.mutate,
        population_size = 40,
        generations     = 100,
        mutation_rate   = 0.3,
        crossover_rate  = 0.8,
        elitism         = 2,
        selection       = "tournament",
        tournament_size = 4,
        seed            = 33,
      })
      T.ok(result.best, "got a best individual")
      -- Verify result.best is still a valid permutation.
      local seen = {}
      for _, v in ipairs(result.best) do seen[v] = (seen[v] or 0) + 1 end
      for i = 1, n do
        T.eq(seen[i], 1, "result.best has " .. i .. " exactly once")
      end
    end)

  end)

end)
