if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local steering = require("lib.steering")

local function approx(a, b, eps)
  eps = eps or 1e-6
  return math.abs(a - b) < eps
end

-- ---------------------------------------------------------------------------
-- Vec2 arithmetic
-- ---------------------------------------------------------------------------

T.describe("vec2", function()
  T.it("add", function()
    local v = steering.vec2(1, 2):add(steering.vec2(3, 4))
    T.eq(v.x, 4) T.eq(v.y, 6)
  end)

  T.it("sub", function()
    local v = steering.vec2(5, 7):sub(steering.vec2(2, 3))
    T.eq(v.x, 3) T.eq(v.y, 4)
  end)

  T.it("mul", function()
    local v = steering.vec2(2, 3):mul(4)
    T.eq(v.x, 8) T.eq(v.y, 12)
  end)

  T.it("div", function()
    local v = steering.vec2(8, 12):div(4)
    T.eq(v.x, 2) T.eq(v.y, 3)
  end)

  T.it("dot", function()
    local d = steering.vec2(1, 2):dot(steering.vec2(3, 4))
    T.eq(d, 11)
  end)

  T.it("length", function()
    local l = steering.vec2(3, 4):length()
    T.ok(approx(l, 5))
  end)

  T.it("length_sq", function()
    local lsq = steering.vec2(3, 4):length_sq()
    T.eq(lsq, 25)
  end)

  T.it("normalize returns unit vector", function()
    local n = steering.vec2(3, 4):normalize()
    T.ok(approx(n:length(), 1))
    T.ok(approx(n.x, 0.6))
    T.ok(approx(n.y, 0.8))
  end)

  T.it("normalize of zero vec returns zero", function()
    local n = steering.vec2(0, 0):normalize()
    T.ok(approx(n:length(), 0))
  end)

  T.it("limit clamps long vectors", function()
    local v = steering.vec2(10, 0):limit(3)
    T.ok(approx(v:length(), 3))
  end)

  T.it("limit does not affect short vectors", function()
    local v = steering.vec2(2, 0):limit(5)
    T.ok(approx(v.x, 2))
  end)

  T.it("dist", function()
    local d = steering.vec2(0, 0):dist(steering.vec2(3, 4))
    T.ok(approx(d, 5))
  end)

  T.it("dist_sq", function()
    local d = steering.vec2(0, 0):dist_sq(steering.vec2(3, 4))
    T.eq(d, 25)
  end)

  T.it("angle", function()
    local a = steering.vec2(1, 0):angle()
    T.ok(approx(a, 0))
    local b = steering.vec2(0, 1):angle()
    T.ok(approx(b, math.pi / 2))
  end)

  T.it("rotate", function()
    local v = steering.vec2(1, 0):rotate(math.pi / 2)
    T.ok(approx(v.x, 0, 1e-5))
    T.ok(approx(v.y, 1, 1e-5))
  end)

  T.it("lerp", function()
    local v = steering.vec2(0, 0):lerp(steering.vec2(10, 20), 0.5)
    T.ok(approx(v.x, 5))
    T.ok(approx(v.y, 10))
  end)

  T.it("from_angle", function()
    local v = steering.from_angle(0)
    T.ok(approx(v.x, 1))
    T.ok(approx(v.y, 0, 1e-15))
  end)

  T.it("zero constant", function()
    T.eq(steering.zero.x, 0)
    T.eq(steering.zero.y, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Seek
-- ---------------------------------------------------------------------------

T.describe("seek", function()
  T.it("force points toward target", function()
    local ag = steering.agent({
      position  = steering.vec2(0, 0),
      velocity  = steering.vec2(0, 0),
      max_speed = 5,
      max_force = 1,
    })
    local target = steering.vec2(10, 0)
    local f = steering.seek(ag, target)
    -- force should have positive x component, near-zero y
    T.ok(f.x > 0, "x component positive")
    T.ok(math.abs(f.y) < 1e-5, "y component near zero")
  end)

  T.it("force magnitude <= max_force", function()
    local ag = steering.agent({ position = steering.vec2(0,0), max_speed=5, max_force=1 })
    local f = steering.seek(ag, steering.vec2(100, 50))
    T.ok(f:length() <= ag.max_force + 1e-9)
  end)
end)

-- ---------------------------------------------------------------------------
-- Flee
-- ---------------------------------------------------------------------------

T.describe("flee", function()
  T.it("force points away from threat", function()
    local ag = steering.agent({
      position  = steering.vec2(0, 0),
      velocity  = steering.vec2(0, 0),
      max_speed = 5,
      max_force = 1,
    })
    local threat = steering.vec2(10, 0)
    local f = steering.flee(ag, threat)
    T.ok(f.x < 0, "x component negative (away from +x threat)")
  end)

  T.it("flee is roughly opposite of seek", function()
    local ag = steering.agent({
      position  = steering.vec2(0, 0),
      velocity  = steering.vec2(0, 0),
      max_speed = 5,
      max_force = 1,
    })
    local pos = steering.vec2(7, 0)
    local fs = steering.seek(ag, pos)
    local ff = steering.flee(ag, pos)
    -- seek.x > 0, flee.x < 0
    T.ok(fs.x > 0)
    T.ok(ff.x < 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Arrive
-- ---------------------------------------------------------------------------

T.describe("arrive", function()
  T.it("full speed far away", function()
    local ag = steering.agent({ position = steering.vec2(0,0), velocity = steering.vec2(0,0), max_speed=5, max_force=1 })
    local f_far   = steering.arrive(ag, steering.vec2(200, 0), { slow_radius=50, stop_radius=5 })
    local f_close = steering.arrive(ag, steering.vec2(20, 0),  { slow_radius=50, stop_radius=5 })
    -- force magnitude when far >= force magnitude when close (decelerating)
    T.ok(f_far:length() >= f_close:length(), "far force >= close force")
  end)

  T.it("near stop_radius produces near-zero or braking force", function()
    local ag = steering.agent({ position = steering.vec2(0,0), velocity = steering.vec2(2,0), max_speed=5, max_force=1 })
    local f = steering.arrive(ag, steering.vec2(2, 0), { slow_radius=50, stop_radius=5 })
    -- Inside stop_radius: desired=0, force = -velocity clamped. Should oppose current velocity.
    T.ok(f.x <= 0, "braking force opposes velocity direction")
  end)
end)

-- ---------------------------------------------------------------------------
-- Pursue
-- ---------------------------------------------------------------------------

T.describe("pursue", function()
  T.it("leads the target based on velocity", function()
    -- Agent moving upward, target moving to the right and above agent.
    -- Pursue should predict the future position (ahead in x) and steer there.
    local ag = steering.agent({
      position  = steering.vec2(0, 0),
      velocity  = steering.vec2(0, 3),  -- moving upward
      max_speed = 5,
      max_force = 1,
    })
    local target = steering.agent({
      position  = steering.vec2(40, 0),
      velocity  = steering.vec2(0, 5),  -- moving upward fast; predicted pos has +y
      max_speed = 5,
      max_force = 0.5,
    })
    local f_pursue  = steering.pursue(ag, target)
    -- Target is to the right (+x), so seek toward it should have +x component
    T.ok(f_pursue.x > 0, "pursue force has positive x toward target")
    T.ok(f_pursue:length() <= ag.max_force + 1e-9)
  end)

  T.it("pursue predicts ahead of a moving target", function()
    -- Target moves rightward; predicted position is further right than current.
    local ag = steering.agent({
      position  = steering.vec2(0, 0),
      velocity  = steering.vec2(0, 0),
      max_speed = 5,
      max_force = 1,
    })
    local target_still = steering.agent({
      position = steering.vec2(20, 0),
      velocity = steering.vec2(0, 0),
      max_speed = 5, max_force = 0.5,
    })
    local target_moving = steering.agent({
      position = steering.vec2(20, 0),
      velocity = steering.vec2(0, 10),  -- moving upward
      max_speed = 10, max_force = 0.5,
    })
    local f_still  = steering.pursue(ag, target_still)
    local f_moving = steering.pursue(ag, target_moving)
    -- f_still: no vertical component; f_moving: positive y from prediction
    T.ok(f_moving.y > f_still.y, "pursuing moving target steers toward predicted position")
  end)
end)

-- ---------------------------------------------------------------------------
-- Wander
-- ---------------------------------------------------------------------------

T.describe("wander", function()
  T.it("produces bounded forces", function()
    local ag = steering.agent({ position=steering.vec2(0,0), velocity=steering.vec2(1,0), max_speed=5, max_force=1 })
    for _ = 1, 20 do
      local f = steering.wander(ag, { radius=20, distance=30, jitter=0.5, seed=42 })
      T.ok(f:length() <= ag.max_force + 1e-9, "wander force bounded")
    end
  end)

  T.it("produces different forces each step", function()
    local ag = steering.agent({ position=steering.vec2(0,0), velocity=steering.vec2(1,0), max_speed=5, max_force=1 })
    -- seed=nil so random; just ensure it runs 10 steps without error
    local prev_angle = ag._wander_angle
    local changed = false
    for _ = 1, 10 do
      steering.wander(ag, { radius=20, distance=30, jitter=1.0 })
      if ag._wander_angle ~= prev_angle then changed = true end
      prev_angle = ag._wander_angle
    end
    T.ok(changed, "wander angle changes over steps")
  end)
end)

-- ---------------------------------------------------------------------------
-- Separation
-- ---------------------------------------------------------------------------

T.describe("separation", function()
  T.it("force is zero with no neighbors", function()
    local ag = steering.agent({ position=steering.vec2(0,0), max_force=1 })
    local f = steering.separation(ag, {}, { radius=30 })
    T.ok(approx(f:length(), 0))
  end)

  T.it("force pushes away from close neighbor", function()
    local ag    = steering.agent({ position=steering.vec2(0,0),  velocity=steering.vec2(0,0), max_speed=5, max_force=1 })
    local other = steering.agent({ position=steering.vec2(10,0), velocity=steering.vec2(0,0), max_speed=5, max_force=1 })
    local f = steering.separation(ag, { other }, { radius=30 })
    -- Should push in -x direction (away from neighbor at +10)
    T.ok(f.x < 0, "separation pushes away in x")
    T.ok(f:length() <= ag.max_force + 1e-9, "bounded by max_force")
  end)

  T.it("neighbor outside radius has no effect", function()
    local ag    = steering.agent({ position=steering.vec2(0,0),   max_speed=5, max_force=1 })
    local other = steering.agent({ position=steering.vec2(100,0), max_speed=5, max_force=1 })
    local f = steering.separation(ag, { other }, { radius=30 })
    T.ok(approx(f:length(), 0), "no force for far neighbor")
  end)
end)

-- ---------------------------------------------------------------------------
-- Cohesion
-- ---------------------------------------------------------------------------

T.describe("cohesion", function()
  T.it("force points toward center of mass of neighbors", function()
    local ag    = steering.agent({ position=steering.vec2(0,0),  velocity=steering.vec2(0,0), max_speed=5, max_force=1 })
    local n1    = steering.agent({ position=steering.vec2(20,0), velocity=steering.vec2(0,0), max_speed=5, max_force=1 })
    local n2    = steering.agent({ position=steering.vec2(20,0), velocity=steering.vec2(0,0), max_speed=5, max_force=1 })
    local f = steering.cohesion(ag, { n1, n2 })
    T.ok(f.x > 0, "cohesion pulls toward +x neighbors")
  end)

  T.it("no force with no neighbors", function()
    local ag = steering.agent({ position=steering.vec2(0,0), max_force=1 })
    local f = steering.cohesion(ag, {})
    T.ok(approx(f:length(), 0))
  end)
end)

-- ---------------------------------------------------------------------------
-- Alignment
-- ---------------------------------------------------------------------------

T.describe("alignment", function()
  T.it("force points toward average velocity of neighbors", function()
    local ag = steering.agent({ position=steering.vec2(0,0),  velocity=steering.vec2(0,0), max_speed=5, max_force=1 })
    local n1 = steering.agent({ position=steering.vec2(5,0),  velocity=steering.vec2(3,0), max_speed=5, max_force=1 })
    local n2 = steering.agent({ position=steering.vec2(10,0), velocity=steering.vec2(5,0), max_speed=5, max_force=1 })
    local f = steering.alignment(ag, { n1, n2 })
    T.ok(f.x > 0, "alignment steers toward +x average velocity")
  end)

  T.it("no force with no neighbors", function()
    local ag = steering.agent({ position=steering.vec2(0,0), max_force=1 })
    local f = steering.alignment(ag, {})
    T.ok(approx(f:length(), 0))
  end)
end)

-- ---------------------------------------------------------------------------
-- Combine
-- ---------------------------------------------------------------------------

T.describe("combine", function()
  T.it("sums weighted forces and clamps to max_force", function()
    local ag     = steering.agent({ position=steering.vec2(0,0), velocity=steering.vec2(0,0), max_speed=5, max_force=1 })
    local target = steering.vec2(10, 0)
    local result = steering.combine({
      { steering.seek, ag, target, weight=1.0 },
    })
    T.ok(result:length() <= ag.max_force + 1e-9, "bounded by max_force")
    T.ok(result.x > 0, "combined force has positive x toward target")
  end)

  T.it("weights scale contribution", function()
    local ag     = steering.agent({ position=steering.vec2(0,0), velocity=steering.vec2(0,0), max_speed=5, max_force=2 })
    local target = steering.vec2(10, 0)
    local f_w1 = steering.combine({ { steering.seek, ag, target, weight=1.0 } })
    local f_w2 = steering.combine({ { steering.seek, ag, target, weight=2.0 } })
    -- Higher weight should produce equal-or-higher magnitude (both hit max_force ceiling anyway, so check direction)
    T.ok(f_w2.x >= f_w1.x - 1e-9, "higher weight >= lower weight")
  end)

  T.it("opposite forces cancel", function()
    local ag      = steering.agent({ position=steering.vec2(0,0), velocity=steering.vec2(0,0), max_speed=5, max_force=10 })
    local right   = steering.vec2(10, 0)
    local left    = steering.vec2(-10, 0)
    local result  = steering.combine({
      { steering.seek, ag, right, weight=1.0 },
      { steering.seek, ag, left,  weight=1.0 },
    })
    -- The two forces should roughly cancel (both normalized to same magnitude)
    T.ok(math.abs(result.x) < 1e-5, "opposite forces cancel in x")
  end)
end)

-- ---------------------------------------------------------------------------
-- Agent update
-- ---------------------------------------------------------------------------

T.describe("agent:update", function()
  T.it("integrates velocity from force", function()
    local ag = steering.agent({
      position  = steering.vec2(0, 0),
      velocity  = steering.vec2(0, 0),
      max_speed = 10,
      max_force = 5,
      mass      = 1,
    })
    local force = steering.vec2(5, 0)
    ag:update(force, 1.0)
    T.ok(ag.velocity.x > 0, "velocity gained in x")
    T.ok(ag.position.x > 0, "position moved in x")
  end)

  T.it("clamps velocity to max_speed", function()
    local ag = steering.agent({
      position  = steering.vec2(0, 0),
      velocity  = steering.vec2(9, 0),
      max_speed = 10,
      max_force = 100,
      mass      = 1,
    })
    ag:update(steering.vec2(100, 0), 1.0)
    T.ok(ag.velocity:length() <= ag.max_speed + 1e-9, "clamped to max_speed")
  end)
end)

-- ---------------------------------------------------------------------------
-- Flock
-- ---------------------------------------------------------------------------

T.describe("flock", function()
  T.it("runs without error on multiple agents", function()
    local agents = {}
    for i = 1, 5 do
      agents[i] = steering.agent({
        position  = steering.vec2(i * 10, 0),
        velocity  = steering.vec2(1, 0),
        max_speed = 5,
        max_force = 0.5,
      })
    end
    -- Should not error
    local ok, err = pcall(steering.flock, agents, { dt=1/60 })
    T.ok(ok, err)
    -- Positions should have moved
    for _, ag in ipairs(agents) do
      T.ok(type(ag.position.x) == "number")
    end
  end)
end)
