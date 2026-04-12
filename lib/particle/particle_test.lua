if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local P = require("lib.particle")

T.describe("particle emitter", function()

  T.it("burst spawns exactly N particles", function()
    local e = P.emitter({ rate = 0, seed = 1 })
    e:burst(10)
    T.eq(e:count(), 10)
  end)

  T.it("particles expire by lifetime", function()
    local e = P.emitter({ rate = 0, seed = 2, lifetime = { min = 0.5, max = 0.5 } })
    e:burst(5)
    T.eq(e:count(), 5)
    -- advance past lifetime
    e:update(0.6)
    T.eq(e:count(), 0)
  end)

  T.it("rate-based emission spawns roughly rate*time particles", function()
    local e = P.emitter({ rate = 100, seed = 3, lifetime = { min = 5, max = 5 }, max_particles = 500 })
    -- update for 2 seconds in small steps
    for _ = 1, 20 do e:update(0.1) end
    local count = e:count()
    -- expect ~200 particles ±10%
    T.ok(count >= 180 and count <= 220,
      "expected ~200 particles, got " .. count)
  end)

  T.it("gravity affector accelerates particles downward", function()
    local e = P.emitter({
      rate = 0, seed = 4,
      lifetime = { min = 10, max = 10 },
      speed = { min = 0, max = 0 },
      angle = { min = 0, max = 0 },
      gravity = { x = 0, y = -9.8 },
    })
    e:burst(1)
    local vy_before
    e:each(function(p) vy_before = p.vy end)
    e:update(1.0)
    local vy_after
    e:each(function(p) vy_after = p.vy end)
    T.ok(vy_after < vy_before, "vy should decrease under negative gravity")
  end)

  T.it("drag affector decreases speed over time", function()
    local e = P.emitter({
      rate = 0, seed = 5,
      lifetime = { min = 10, max = 10 },
      speed = { min = 100, max = 100 },
      angle = { min = 0, max = 0 },
      drag = 0.5,
    })
    e:burst(1)
    local spd_before
    e:each(function(p) spd_before = math.sqrt(p.vx*p.vx + p.vy*p.vy) end)
    e:update(0.5)
    local spd_after
    e:each(function(p) spd_after = math.sqrt(p.vx*p.vx + p.vy*p.vy) end)
    T.ok(spd_after < spd_before, "speed should decrease under drag")
  end)

  T.it("size interpolates from start to end over lifetime", function()
    local e = P.emitter({
      rate = 0, seed = 6,
      lifetime = { min = 2, max = 2 },
      speed = { min = 0, max = 0 },
      angle = { min = 0, max = 0 },
      size = { start = 10, ["end"] = 2 },
    })
    e:burst(1)
    -- at t=0 size should be 10
    local s0
    e:each(function(p) s0 = p.size end)
    T.ok(math.abs(s0 - 10) < 0.01, "size at t=0 should be 10, got " .. tostring(s0))
    -- advance halfway
    e:update(1.0)
    local s_mid
    e:each(function(p) s_mid = p.size end)
    T.ok(math.abs(s_mid - 6) < 0.1, "size at t=0.5 should be ~6, got " .. tostring(s_mid))
    -- advance to end
    e:update(1.0)
    local s_end
    e:each(function(p) s_end = p.size end)
    -- particle is now expired (age >= lifetime)
    T.eq(e:count(), 0)
  end)

  T.it("color interpolates correctly at t=0, t=0.5, t=1", function()
    local e = P.emitter({
      rate = 0, seed = 7,
      lifetime = { min = 2, max = 2 },
      speed = { min = 0, max = 0 },
      angle = { min = 0, max = 0 },
      color = {
        start = { r = 1, g = 0, b = 0, a = 1 },
        end_  = { r = 0, g = 1, b = 0, a = 0 },
      },
    })
    e:burst(1)
    -- t=0: color should be start
    local r0, g0, a0
    e:each(function(p) r0 = p.r; g0 = p.g; a0 = p.a end)
    T.ok(math.abs(r0 - 1) < 0.01, "r at t=0 should be 1")
    T.ok(math.abs(g0 - 0) < 0.01, "g at t=0 should be 0")
    T.ok(math.abs(a0 - 1) < 0.01, "a at t=0 should be 1")
    -- t=0.5
    e:update(1.0)
    local r_mid, g_mid, a_mid
    e:each(function(p) r_mid = p.r; g_mid = p.g; a_mid = p.a end)
    T.ok(math.abs(r_mid - 0.5) < 0.01, "r at t=0.5 should be ~0.5, got " .. tostring(r_mid))
    T.ok(math.abs(g_mid - 0.5) < 0.01, "g at t=0.5 should be ~0.5, got " .. tostring(g_mid))
    T.ok(math.abs(a_mid - 0.5) < 0.01, "a at t=0.5 should be ~0.5, got " .. tostring(a_mid))
  end)

  T.it("max_particles cap respected", function()
    local e = P.emitter({ rate = 0, seed = 8, max_particles = 10 })
    e:burst(20)  -- try to emit 20 into a pool of 10
    T.eq(e:count(), 10)
  end)

  T.it("deterministic with fixed seed", function()
    local function run_sim(seed)
      local e = P.emitter({
        rate = 50, seed = seed,
        lifetime = { min = 1, max = 2 },
        speed = { min = 50, max = 100 },
        angle = { min = 0, max = 360 },
      })
      e:update(0.1)
      e:update(0.1)
      e:update(0.1)
      local positions = {}
      e:each(function(p)
        positions[#positions + 1] = { x = p.x, y = p.y }
      end)
      return positions
    end

    local pos1 = run_sim(42)
    local pos2 = run_sim(42)
    T.eq(#pos1, #pos2, "same seed => same count")
    for i = 1, #pos1 do
      T.ok(math.abs(pos1[i].x - pos2[i].x) < 1e-9, "x positions differ at " .. i)
      T.ok(math.abs(pos1[i].y - pos2[i].y) < 1e-9, "y positions differ at " .. i)
    end

    -- Different seeds should (very likely) differ
    local pos3 = run_sim(99)
    local differs = false
    for i = 1, math.min(#pos1, #pos3) do
      if math.abs(pos1[i].x - pos3[i].x) > 0.001 then differs = true; break end
    end
    T.ok(differs or #pos1 ~= #pos3, "different seeds should produce different results")
  end)

  T.it("reset clears all particles", function()
    local e = P.emitter({ rate = 0, seed = 9 })
    e:burst(20)
    T.ok(e:count() > 0, "should have particles before reset")
    e:reset()
    T.eq(e:count(), 0)
  end)

  T.it("each iterates all live particles", function()
    local e = P.emitter({ rate = 0, seed = 10 })
    e:burst(7)
    local count = 0
    e:each(function(_) count = count + 1 end)
    T.eq(count, 7)
  end)

  T.it("stop halts new emission; existing particles still age", function()
    local e = P.emitter({
      rate = 100, seed = 11,
      lifetime = { min = 10, max = 10 },
    })
    -- Let it emit some particles
    e:update(0.1)
    local initial = e:count()
    T.ok(initial > 0, "should have some particles")
    -- Stop emitter
    e:stop()
    -- Update: no new particles should be emitted
    e:update(0.1)
    -- Count should be same (lifetime=10s so none expire yet)
    T.eq(e:count(), initial)
    -- Age should have advanced (particles alive, just no new ones)
    local ages = {}
    e:each(function(p) ages[#ages + 1] = p.age end)
    T.ok(#ages == initial, "same particles still live")
    for _, age in ipairs(ages) do
      T.ok(age > 0, "age should be > 0")
    end
  end)

  T.it("attractor affector pulls particles toward point", function()
    -- Emit one particle moving away from attractor, measure it gets pulled
    local e = P.emitter({
      rate = 0, seed = 12,
      lifetime = { min = 10, max = 10 },
      speed = { min = 0, max = 0 },
      angle = { min = 0, max = 0 },
      position = { x = 100, y = 0 },
    })
    e:add_affector(P.affectors.attractor(0, 0, 10000))
    e:burst(1)
    -- Initial velocity is 0, position is (100, 0)
    local vx_before
    e:each(function(p) vx_before = p.vx end)
    T.ok(math.abs(vx_before) < 0.01, "initial vx should be ~0")
    e:update(0.1)
    local vx_after
    e:each(function(p) vx_after = p.vx end)
    -- attractor at (0,0), particle at (100,0): force pulls in -x direction
    T.ok(vx_after < 0, "attractor should pull particle toward origin, vx=" .. tostring(vx_after))
  end)

end)
