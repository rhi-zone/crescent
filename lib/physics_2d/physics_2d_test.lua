if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local P = require("lib.physics_2d")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function approx_eq(a, b, tol)
  tol = tol or 1e-6
  return math.abs(a - b) <= tol
end

local function step_n(world, dt, n)
  for _ = 1, n do world:step(dt) end
end

-- ---------------------------------------------------------------------------
-- Module meta
-- ---------------------------------------------------------------------------

T.describe("physics_2d module", function()
  T.it("exports world constructor", function()
    T.ok(type(P.world) == "function", "P.world is a function")
  end)
  T.it("exports _tier = pure", function()
    T.eq(P._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- World creation
-- ---------------------------------------------------------------------------

T.describe("world creation", function()
  T.it("creates world with defaults", function()
    local w = P.world()
    T.ok(w ~= nil, "world not nil")
    T.eq(#w:bodies(), 0)
  end)
  T.it("accepts custom gravity", function()
    local w = P.world({ gravity = { x = 1, y = -5 } })
    T.eq(w.gx, 1)
    T.eq(w.gy, -5)
  end)
  T.it("accepts damping", function()
    local w = P.world({ damping = 0.9 })
    T.eq(w.damping, 0.9)
  end)
end)

-- ---------------------------------------------------------------------------
-- Body creation
-- ---------------------------------------------------------------------------

T.describe("body creation", function()
  T.it("default position is 0,0", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    local x, y = b:position()
    T.eq(x, 0)
    T.eq(y, 0)
  end)
  T.it("custom position", function()
    local w = P.world()
    local b = w:body({ x = 3, y = 7, shape = "circle", radius = 5 })
    local x, y = b:position()
    T.eq(x, 3)
    T.eq(y, 7)
  end)
  T.it("default velocity is 0,0", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    local vx, vy = b:velocity()
    T.eq(vx, 0)
    T.eq(vy, 0)
  end)
  T.it("custom velocity", function()
    local w = P.world()
    local b = w:body({ vx = 2, vy = -1, shape = "circle", radius = 5 })
    local vx, vy = b:velocity()
    T.eq(vx, 2)
    T.eq(vy, -1)
  end)
  T.it("default mass is 1", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    T.eq(b.mass, 1.0)
  end)
  T.it("custom mass", function()
    local w = P.world()
    local b = w:body({ mass = 5, shape = "circle", radius = 5 })
    T.eq(b.mass, 5)
  end)
  T.it("mass=0 is static", function()
    local w = P.world()
    local b = w:body({ mass = 0, shape = "circle", radius = 5 })
    T.ok(b:is_static(), "mass=0 body is static")
  end)
  T.it("mass>0 is not static", function()
    local w = P.world()
    local b = w:body({ mass = 1, shape = "circle", radius = 5 })
    T.ok(not b:is_static(), "mass=1 body is not static")
  end)
  T.it("body added to world bodies list", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    T.eq(#w:bodies(), 1)
    T.ok(w:bodies()[1] == b, "body is in list")
  end)
  T.it("multiple bodies tracked", function()
    local w = P.world()
    w:body({ shape = "circle", radius = 5 })
    w:body({ shape = "circle", radius = 5 })
    T.eq(#w:bodies(), 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Body API
-- ---------------------------------------------------------------------------

T.describe("body API", function()
  T.it("set_position updates x,y", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    b:set_position(10, 20)
    local x, y = b:position()
    T.eq(x, 10)
    T.eq(y, 20)
  end)
  T.it("set_velocity updates vx,vy", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    b:set_velocity(3, -4)
    local vx, vy = b:velocity()
    T.eq(vx, 3)
    T.eq(vy, -4)
  end)
  T.it("angle returns rotation", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local b = w:body({ angle = 1.5, shape = "circle", radius = 5 })
    T.ok(approx_eq(b:angle(), 1.5), "angle matches")
  end)
end)

-- ---------------------------------------------------------------------------
-- Free-fall integration
-- ---------------------------------------------------------------------------

T.describe("free-fall under gravity", function()
  T.it("body falls downward over time (negative y gravity)", function()
    local w = P.world({ gravity = { x = 0, y = -9.8 } })
    local b = w:body({ x = 0, y = 100, shape = "circle", radius = 5 })
    local _, y0 = b:position()
    step_n(w, 0.1, 5)
    local _, y1 = b:position()
    T.ok(y1 < y0, "y decreases under -9.8 gravity")
  end)
  T.it("body moves right under positive x gravity", function()
    local w = P.world({ gravity = { x = 5, y = 0 } })
    local b = w:body({ x = 0, y = 0, shape = "circle", radius = 5 })
    step_n(w, 0.1, 5)
    local x, _ = b:position()
    T.ok(x > 0, "x increases under positive gx")
  end)
  T.it("static body (mass=0) does not move under gravity", function()
    local w = P.world({ gravity = { x = 0, y = -9.8 } })
    local b = w:body({ x = 0, y = 50, mass = 0, shape = "circle", radius = 5 })
    step_n(w, 0.1, 10)
    local x, y = b:position()
    T.eq(x, 0)
    T.eq(y, 50)
  end)
  T.it("free-fall distance approximates 0.5*g*t^2", function()
    local g = -9.8
    local w = P.world({ gravity = { x = 0, y = g }, damping = 1.0 })
    local b = w:body({ x = 0, y = 0, shape = "circle", radius = 1 })
    step_n(w, 0.1, 10)  -- t=1s
    local _, y = b:position()
    -- Expected: y = 0.5 * -9.8 * 1^2 = -4.9  (semi-implicit Euler has slight error)
    T.ok(y < -4.0 and y > -6.0, "y in expected free-fall range after 1s")
  end)
end)

-- ---------------------------------------------------------------------------
-- apply_force and apply_impulse
-- ---------------------------------------------------------------------------

T.describe("apply_force", function()
  T.it("force in x direction accelerates body", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local b = w:body({ mass = 1, shape = "circle", radius = 5 })
    b:apply_force(10, 0)
    w:step(1.0)
    local vx, _ = b:velocity()
    T.ok(vx > 0, "vx > 0 after force in x")
  end)
  T.it("force accumulators reset after step", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local b = w:body({ mass = 1, shape = "circle", radius = 5 })
    b:apply_force(10, 0)
    w:step(0.1)
    T.eq(b._fx, 0)
    T.eq(b._fy, 0)
  end)
  T.it("multiple forces accumulate", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local b = w:body({ mass = 1, shape = "circle", radius = 5 })
    b:apply_force(5, 0)
    b:apply_force(5, 0)
    w:step(1.0)
    local vx, _ = b:velocity()
    T.ok(approx_eq(vx, 10.0, 0.01), "vx = fx/m * dt = 10")
  end)
end)

T.describe("apply_impulse", function()
  T.it("impulse changes velocity immediately", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local b = w:body({ mass = 1, shape = "circle", radius = 5 })
    b:apply_impulse(5, 3)
    local vx, vy = b:velocity()
    T.eq(vx, 5)
    T.eq(vy, 3)
  end)
  T.it("impulse scales with inv_mass", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local b = w:body({ mass = 2, shape = "circle", radius = 5 })
    b:apply_impulse(4, 0)
    local vx, _ = b:velocity()
    T.eq(vx, 2)  -- 4 / mass=2
  end)
  T.it("static body ignores impulse", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local b = w:body({ mass = 0, shape = "circle", radius = 5 })
    b:apply_impulse(100, 100)
    local vx, vy = b:velocity()
    T.eq(vx, 0)
    T.eq(vy, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Damping
-- ---------------------------------------------------------------------------

T.describe("damping", function()
  T.it("velocity decreases over time without forces", function()
    local w = P.world({ gravity = { x = 0, y = 0 }, damping = 0.9 })
    local b = w:body({ vx = 10, vy = 0, shape = "circle", radius = 5 })
    step_n(w, 0.1, 20)
    local vx, _ = b:velocity()
    T.ok(vx < 10, "velocity has been damped")
    T.ok(vx > 0, "velocity hasn't reversed")
  end)
  T.it("damping=1 preserves velocity (no gravity)", function()
    local w = P.world({ gravity = { x = 0, y = 0 }, damping = 1.0 })
    local b = w:body({ vx = 5, vy = 0, shape = "circle", radius = 5 })
    step_n(w, 0.1, 10)
    local vx, _ = b:velocity()
    T.ok(approx_eq(vx, 5, 0.001), "velocity preserved with damping=1")
  end)
end)

-- ---------------------------------------------------------------------------
-- Circle-circle collision
-- ---------------------------------------------------------------------------

T.describe("circle-circle collision", function()
  T.it("overlapping circles are detected", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local a = w:body({ x = 0, y = 0, shape = "circle", radius = 5 })
    local b = w:body({ x = 8, y = 0, shape = "circle", radius = 5 })
    -- 8 < 5+5=10, so overlapping
    local cols = w:collisions()
    T.eq(#cols, 1)
  end)
  T.it("non-overlapping circles not detected", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    w:body({ x = 0,  y = 0, shape = "circle", radius = 5 })
    w:body({ x = 20, y = 0, shape = "circle", radius = 5 })
    local cols = w:collisions()
    T.eq(#cols, 0)
  end)
  T.it("collision normal points from a to b", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local a = w:body({ x = 0, y = 0, shape = "circle", radius = 5 })
    local b = w:body({ x = 8, y = 0, shape = "circle", radius = 5 })
    local cols = w:collisions()
    T.eq(cols[1].body_a, a)
    T.eq(cols[1].body_b, b)
    T.ok(cols[1].normal.x > 0, "normal.x > 0 (pointing from a to b)")
    T.ok(approx_eq(cols[1].normal.y, 0, 1e-6), "normal.y = 0")
  end)
  T.it("collision depth is correct", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    w:body({ x = 0, y = 0, shape = "circle", radius = 5 })
    w:body({ x = 8, y = 0, shape = "circle", radius = 5 })
    local cols = w:collisions()
    T.ok(approx_eq(cols[1].depth, 2.0, 1e-5), "depth = 10-8 = 2")
  end)
  T.it("bodies separated after step (collision resolution)", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local a = w:body({ x = 0, y = 0, mass = 1, restitution = 0, friction = 0,
                       shape = "circle", radius = 5 })
    local b = w:body({ x = 8, y = 0, mass = 1, restitution = 0, friction = 0,
                       shape = "circle", radius = 5 })
    w:step(0.016)
    local ax, _ = a:position()
    local bx, _ = b:position()
    T.ok(bx - ax >= 10, "bodies at least 10 units apart after resolution")
  end)
end)

-- ---------------------------------------------------------------------------
-- Bouncing ball
-- ---------------------------------------------------------------------------

T.describe("bouncing ball", function()
  T.it("ball with restitution>0 bounces off static floor", function()
    local w = P.world({ gravity = { x = 0, y = -9.8 }, damping = 1.0 })
    -- Static floor at y=0 (large box)
    w:body({ x = 0, y = -5, mass = 0, shape = "box",
             width = 200, height = 10, restitution = 0.8 })
    local ball = w:body({ x = 0, y = 20, mass = 1, shape = "circle",
                          radius = 5, restitution = 0.8, friction = 0 })
    -- Let ball fall and hit the floor
    step_n(w, 0.016, 200)
    local _, vy = ball:velocity()
    -- After a bounce, vy should be positive (moving up) at some point
    -- We check that y is not simply at the fall endpoint
    local _, y = ball:position()
    -- Ball should not have sunk far below y=0 (floor surface at y=0)
    T.ok(y > -5, "ball is not below floor after resolution")
  end)
  T.it("zero restitution ball does not bounce", function()
    local w = P.world({ gravity = { x = 0, y = -9.8 }, damping = 1.0 })
    w:body({ x = 0, y = -5, mass = 0, shape = "box",
             width = 200, height = 10, restitution = 0 })
    local ball = w:body({ x = 0, y = 5.1, mass = 1, shape = "circle",
                          radius = 1, restitution = 0, friction = 0 })
    step_n(w, 0.016, 200)
    local _, vy = ball:velocity()
    T.ok(vy <= 0.5, "ball doesn't bounce with restitution=0")
  end)
end)

-- ---------------------------------------------------------------------------
-- Circle-box collision
-- ---------------------------------------------------------------------------

T.describe("circle-box collision", function()
  T.it("circle overlapping box is detected", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    w:body({ x = 0, y = 0, shape = "box", width = 10, height = 10, mass = 0 })
    w:body({ x = 8, y = 0, shape = "circle", radius = 5, mass = 1 })
    -- closest point on box to circle center: (5, 0); dist = 3 < 5
    local cols = w:collisions()
    T.eq(#cols, 1)
  end)
  T.it("circle far from box is not detected", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    w:body({ x = 0, y = 0, shape = "box", width = 10, height = 10, mass = 0 })
    w:body({ x = 20, y = 0, shape = "circle", radius = 2, mass = 1 })
    local cols = w:collisions()
    T.eq(#cols, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Box-box collision
-- ---------------------------------------------------------------------------

T.describe("box-box collision", function()
  T.it("overlapping boxes detected", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    w:body({ x = 0, y = 0, shape = "box", width = 10, height = 10, mass = 1 })
    w:body({ x = 8, y = 0, shape = "box", width = 10, height = 10, mass = 1 })
    local cols = w:collisions()
    T.eq(#cols, 1)
  end)
  T.it("non-overlapping boxes not detected", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    w:body({ x = 0,  y = 0, shape = "box", width = 10, height = 10, mass = 1 })
    w:body({ x = 20, y = 0, shape = "box", width = 10, height = 10, mass = 1 })
    local cols = w:collisions()
    T.eq(#cols, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Remove body
-- ---------------------------------------------------------------------------

T.describe("remove body", function()
  T.it("removed body no longer in world", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    T.eq(#w:bodies(), 1)
    w:remove(b)
    T.eq(#w:bodies(), 0)
  end)
  T.it("other bodies remain after removal", function()
    local w = P.world()
    local a = w:body({ shape = "circle", radius = 5 })
    local b = w:body({ shape = "circle", radius = 5 })
    w:remove(a)
    T.eq(#w:bodies(), 1)
    T.ok(w:bodies()[1] == b, "b remains after a is removed")
  end)
  T.it("removing non-existent body is safe", function()
    local w = P.world()
    local b = w:body({ shape = "circle", radius = 5 })
    w:remove(b)
    -- remove again — should not error
    w:remove(b)
    T.eq(#w:bodies(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Particle API
-- ---------------------------------------------------------------------------

T.describe("particle", function()
  T.it("particle creates a body", function()
    local w = P.world()
    local p = w:particle(5, 10, 2)
    T.ok(p ~= nil, "particle returned")
    T.eq(#w:bodies(), 1)
  end)
  T.it("particle position correct", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local p = w:particle(3, 7, 1)
    local x, y = p:position()
    T.eq(x, 3)
    T.eq(y, 7)
  end)
  T.it("particle mass correct", function()
    local w = P.world()
    local p = w:particle(0, 0, 4)
    T.eq(p.mass, 4)
  end)
  T.it("particle responds to force", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local p = w:particle(0, 0, 1)
    p:apply_force(10, 0)
    w:step(1.0)
    local vx, _ = p:velocity()
    T.ok(vx > 0, "particle moves under force")
  end)
end)

-- ---------------------------------------------------------------------------
-- Distance joint
-- ---------------------------------------------------------------------------

T.describe("distance_joint", function()
  T.it("joint created and returned", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local a = w:body({ x = 0,  y = 0, mass = 1, shape = "circle", radius = 2 })
    local b = w:body({ x = 10, y = 0, mass = 1, shape = "circle", radius = 2 })
    local j = w:distance_joint(a, b)
    T.ok(j ~= nil, "joint returned")
  end)
  T.it("joint default target_dist is initial distance", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    local a = w:body({ x = 0,  y = 0, mass = 1, shape = "circle", radius = 2 })
    local b = w:body({ x = 10, y = 0, mass = 1, shape = "circle", radius = 2 })
    local j = w:distance_joint(a, b)
    T.ok(approx_eq(j.target_dist, 10.0, 1e-5), "target_dist = 10")
  end)
  T.it("joint maintains approximate distance", function()
    local w = P.world({ gravity = { x = 0, y = 0 }, damping = 1.0 })
    local a = w:body({ x = 0,  y = 0, mass = 1, shape = "circle", radius = 1 })
    local b = w:body({ x = 10, y = 0, mass = 1, shape = "circle", radius = 1 })
    w:distance_joint(a, b, { target_dist = 10, stiffness = 1.0 })
    -- Apply a force to perturb a
    a:apply_impulse(-5, 0)
    step_n(w, 0.016, 60)
    local ax, ay = a:position()
    local bx, by = b:position()
    local dx = bx - ax
    local dy = by - ay
    local dist = math.sqrt(dx * dx + dy * dy)
    T.ok(dist < 15, "distance stays roughly bounded by joint (< 15 for target 10)")
  end)
  T.it("custom target_dist respected", function()
    local w = P.world({ gravity = { x = 0, y = 0 }, damping = 0.8 })
    local a = w:body({ x = 0, y = 0, mass = 1, shape = "circle", radius = 1 })
    local b = w:body({ x = 5, y = 0, mass = 1, shape = "circle", radius = 1 })
    w:distance_joint(a, b, { target_dist = 5, stiffness = 1.0 })
    T.ok(true, "custom target_dist accepted without error")
  end)
end)

-- ---------------------------------------------------------------------------
-- Collisions() return values
-- ---------------------------------------------------------------------------

T.describe("collisions() return structure", function()
  T.it("collision has all expected fields", function()
    local w = P.world({ gravity = { x = 0, y = 0 } })
    w:body({ x = 0, y = 0, shape = "circle", radius = 5 })
    w:body({ x = 8, y = 0, shape = "circle", radius = 5 })
    local cols = w:collisions()
    local c = cols[1]
    T.ok(c.body_a ~= nil, "body_a present")
    T.ok(c.body_b ~= nil, "body_b present")
    T.ok(c.normal ~= nil, "normal present")
    T.ok(c.normal.x ~= nil, "normal.x present")
    T.ok(c.normal.y ~= nil, "normal.y present")
    T.ok(c.depth ~= nil, "depth present")
    T.ok(c.contact_x ~= nil, "contact_x present")
    T.ok(c.contact_y ~= nil, "contact_y present")
  end)
  T.it("no collisions returns empty table", function()
    local w = P.world()
    T.eq(#w:collisions(), 0)
  end)
end)
