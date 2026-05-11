if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/steering/init.lua
-- Craig Reynolds-style 2D steering behaviors for game agents.
-- All behaviors return a force vec2. Error convention: (nil, errmsg).

local M = {}
--: string
M._tier = "pure"

--:: Vec2 = { x: number, y: number, add: (Vec2, Vec2) -> Vec2, sub: (Vec2, Vec2) -> Vec2, mul: (Vec2, number) -> Vec2, div: (Vec2, number) -> Vec2, dot: (Vec2, Vec2) -> number, length_sq: (Vec2) -> number, length: (Vec2) -> number, normalize: (Vec2) -> Vec2, limit: (Vec2, number) -> Vec2, dist: (Vec2, Vec2) -> number, dist_sq: (Vec2, Vec2) -> number, angle: (Vec2) -> number, rotate: (Vec2, number) -> Vec2, lerp: (Vec2, Vec2, number) -> Vec2 }
--:: Agent = { position: Vec2, velocity: Vec2, max_speed: number, max_force: number, mass: number, _wander_angle: number, _wander_seeded: boolean | nil, update: (Agent, Vec2, number) -> nil }

local math_sqrt  = math.sqrt
local math_atan2 = math.atan2
local math_cos   = math.cos
local math_sin   = math.sin
local math_huge  = math.huge
local math_pi    = math.pi
local math_min   = math.min
local math_max   = math.max
local math_abs   = math.abs
local math_random = math.random

-- ---------------------------------------------------------------------------
-- Vec2
-- ---------------------------------------------------------------------------

local vec2_mt = {}
vec2_mt.__index = vec2_mt

--: (Vec2, Vec2) -> Vec2
function vec2_mt:add(b)
  return M.vec2(self.x + b.x, self.y + b.y)
end
--: (Vec2, Vec2) -> Vec2
function vec2_mt:sub(b)
  return M.vec2(self.x - b.x, self.y - b.y)
end
--: (Vec2, number) -> Vec2
function vec2_mt:mul(s)
  return M.vec2(self.x * s, self.y * s)
end
--: (Vec2, number) -> Vec2
function vec2_mt:div(s)
  return M.vec2(self.x / s, self.y / s)
end
--: (Vec2, Vec2) -> number
function vec2_mt:dot(b)
  return self.x * b.x + self.y * b.y
end

--: (Vec2) -> number
function vec2_mt:length_sq()
  return self.x * self.x + self.y * self.y
end

--: (Vec2) -> number
function vec2_mt:length()
  return math_sqrt(self.x * self.x + self.y * self.y)
end

--: (Vec2) -> Vec2
function vec2_mt:normalize()
  local len = self:length()
  if len < 1e-12 then return M.vec2(0, 0) end
  return M.vec2(self.x / len, self.y / len)
end

--: (Vec2, number) -> Vec2
function vec2_mt:limit(max_len)
  local lsq = self:length_sq()
  if lsq > max_len * max_len then
    return self:normalize():mul(max_len)
  end
  return M.vec2(self.x, self.y)
end

--: (Vec2, Vec2) -> number
function vec2_mt:dist(b)
  local dx = self.x - b.x
  local dy = self.y - b.y
  return math_sqrt(dx * dx + dy * dy)
end

--: (Vec2, Vec2) -> number
function vec2_mt:dist_sq(b)
  local dx = self.x - b.x
  local dy = self.y - b.y
  return dx * dx + dy * dy
end

--: (Vec2) -> number
function vec2_mt:angle()
  return math_atan2(self.y, self.x)
end

--: (Vec2, number) -> Vec2
function vec2_mt:rotate(theta)
  local c = math_cos(theta)
  local s = math_sin(theta)
  return M.vec2(self.x * c - self.y * s, self.x * s + self.y * c)
end

--: (Vec2, Vec2, number) -> Vec2
function vec2_mt:lerp(b, t)
  return M.vec2(self.x + (b.x - self.x) * t, self.y + (b.y - self.y) * t)
end

--: (Vec2) -> string
function vec2_mt:__tostring()
  return "vec2(" .. self.x .. ", " .. self.y .. ")"
end

--- Construct a vec2.
--: (number, number) -> Vec2
function M.vec2(x, y)
  local v = { x = x or 0, y = y or 0 }
  return (setmetatable(v, vec2_mt) --[[: unknown]]) --[[:! Vec2]]
end


--- Zero constant.
M.zero = M.vec2(0, 0)

--- Construct a vec2 from an angle (radians).
function M.from_angle(theta)
  return M.vec2(math_cos(theta), math_sin(theta))
end

-- ---------------------------------------------------------------------------
-- Agent
-- ---------------------------------------------------------------------------

local agent_mt = {}
agent_mt.__index = agent_mt

--- Integrate force over dt, clamp velocity to max_speed.
--: (Agent, Vec2, number) -> nil
function agent_mt:update(force, dt)
  -- acceleration = force / mass
  local acc = force:mul(dt / self.mass)
  self.velocity = self.velocity:add(acc):limit(self.max_speed)
  self.position = self.position:add(self.velocity:mul(dt))
end

--- Construct an agent.
-- opts: { position, velocity, max_speed, max_force, mass }
--: ({ position: Vec2 | nil, velocity: Vec2 | nil, max_speed: number | nil, max_force: number | nil, mass: number | nil } | nil) -> Agent
function M.agent(opts)
  local opts_ = (opts or {}) --[[:! { position: Vec2 | nil, velocity: Vec2 | nil, max_speed: number | nil, max_force: number | nil, mass: number | nil }]]
  return setmetatable({
    position  = opts_.position  or M.vec2(0, 0),
    velocity  = opts_.velocity  or M.vec2(0, 0),
    max_speed = opts_.max_speed or 5.0,
    max_force = opts_.max_force or 0.5,
    mass      = opts_.mass      or 1.0,
    -- wander state
    _wander_angle = 0,
    _wander_seeded = nil,
  }, agent_mt) --[[:! Agent]]
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--: (Agent, Vec2, number) -> Vec2
local function desired_velocity_toward(agent, target_pos, speed)
  local d = target_pos:sub(agent.position)
  local len = d:length()
  if len < 1e-12 then return M.vec2(0, 0) end
  return d:mul(speed / len)
end

--: (Agent, Vec2) -> Vec2
local function steering_force(agent, desired)
  return desired:sub(agent.velocity):limit(agent.max_force)
end

-- ---------------------------------------------------------------------------
-- Seek
-- ---------------------------------------------------------------------------

--- Steer toward target_pos at full speed.
--: (Agent, Vec2) -> Vec2
function M.seek(agent, target_pos)
  local desired = desired_velocity_toward(agent, target_pos, agent.max_speed)
  return steering_force(agent, desired)
end

-- ---------------------------------------------------------------------------
-- Flee
-- ---------------------------------------------------------------------------

--- Steer away from threat_pos at full speed.
--: (Agent, Vec2) -> Vec2
function M.flee(agent, threat_pos)
  local d = agent.position:sub(threat_pos) --[[:! Vec2]]
  local len = d:length()
  if len < 1e-12 then return M.vec2(0, 0) end
  local desired = d:mul(agent.max_speed / len) --[[:! Vec2]]
  return steering_force(agent, desired)
end

-- ---------------------------------------------------------------------------
-- Arrive
-- ---------------------------------------------------------------------------

--- Seek with deceleration inside slow_radius; stop inside stop_radius.
-- opts: { slow_radius=50, stop_radius=5 }
--: (Agent, Vec2, { slow_radius: number | nil, stop_radius: number | nil } | nil) -> Vec2
function M.arrive(agent, target_pos, opts)
  local opts_ = (opts or {}) --[[:! { slow_radius: number | nil, stop_radius: number | nil }]]
  local slow_radius = opts_.slow_radius or 50
  local stop_radius = opts_.stop_radius or 5

  local d = target_pos:sub(agent.position)
  local dist = d:length()

  if dist < stop_radius then
    -- Brake: desired velocity = zero (steer toward zero)
    return steering_force(agent, M.vec2(0, 0))
  end

  local speed = agent.max_speed
  if dist < slow_radius then
    speed = agent.max_speed * (dist / slow_radius)
  else
    speed = agent.max_speed
  end

  local desired = d:mul(speed / dist)
  return steering_force(agent, desired)
end

-- ---------------------------------------------------------------------------
-- Pursue
-- ---------------------------------------------------------------------------

--- Steer toward the predicted future position of target_agent.
--: (Agent, Agent) -> Vec2
function M.pursue(agent, target_agent)
  local to_target = target_agent.position:sub(agent.position)
  local dist      = to_target:length()
  -- prediction horizon: time to close gap at max_speed, capped
  local ahead     = dist / (agent.max_speed + 1e-12)
  local future    = target_agent.position:add(target_agent.velocity:mul(ahead))
  return M.seek(agent, future)
end

-- ---------------------------------------------------------------------------
-- Evade
-- ---------------------------------------------------------------------------

--- Flee from the predicted future position of threat_agent.
--: (Agent, Agent) -> Vec2
function M.evade(agent, threat_agent)
  local to_threat = threat_agent.position:sub(agent.position)
  local dist      = to_threat:length()
  local ahead     = dist / (agent.max_speed + 1e-12)
  local future    = threat_agent.position:add(threat_agent.velocity:mul(ahead))
  return M.flee(agent, future)
end

-- ---------------------------------------------------------------------------
-- Wander
-- ---------------------------------------------------------------------------

--- Wander: random steering on a circle projected ahead of the agent.
-- opts: { radius=20, distance=30, jitter=0.5, seed=42 }
-- NOTE: mutates agent._wander_angle for continuity.
--: (Agent, { radius: number | nil, distance: number | nil, jitter: number | nil, seed: integer | nil } | nil) -> Vec2
function M.wander(agent, opts)
  local opts_ = (opts or {}) --[[:! { radius: number | nil, distance: number | nil, jitter: number | nil, seed: integer | nil }]]
  local radius   = opts_.radius   or 20
  local distance = opts_.distance or 30
  local jitter   = opts_.jitter   or 0.5

  -- Optionally seed once; thereafter use math.random
  if opts_.seed and not agent._wander_seeded then
    math.randomseed(opts_.seed)
    agent._wander_seeded = true
  end

  -- Displace the wander angle by a random amount
  agent._wander_angle = agent._wander_angle + (math_random() * 2 - 1) * jitter

  -- Point on wander circle in local space, translated to world space
  local ahead = agent.velocity:normalize():mul(distance)
  if ahead:length() < 1e-12 then
    ahead = M.vec2(distance, 0)
  end
  local circle_center = agent.position:add(ahead)
  local displacement = M.from_angle(agent._wander_angle):mul(radius)
  local target = circle_center:add(displacement)

  return M.seek(agent, target)
end

-- ---------------------------------------------------------------------------
-- Obstacle avoidance
-- ---------------------------------------------------------------------------

--- Steer to avoid circular obstacles.
-- obstacles: array of { position=vec2, radius=number }
-- opts: { lookahead=40 }
--: (Agent, { [integer]: { position: Vec2, radius: number } }, { lookahead: number | nil } | nil) -> Vec2
function M.obstacle_avoidance(agent, obstacles, opts)
  local opts_ = (opts or {}) --[[:! { lookahead: number | nil }]]
  local lookahead = opts_.lookahead or 40

  local speed = agent.velocity:length()
  if speed < 1e-12 then return M.vec2(0, 0) end

  local vel_norm = agent.velocity:normalize() --[[:! Vec2]]
  local ahead = agent.position:add(vel_norm:mul(lookahead) --[[:! Vec2]]) --[[:! Vec2]]

  -- Find the closest obstacle that intersects the lookahead ray
  --: { position: Vec2, radius: number } | nil
  local most_threatening = nil
  local min_dist = math_huge

  for _, obs in ipairs(obstacles) do
    local obs_ = obs --[[:! { position: Vec2, radius: number }]]
    -- Approximate: check if obstacle center is within (obs.radius) of the ahead point
    local d = ahead:dist(obs_.position)
    if d < obs_.radius then
      local dist_to_agent = agent.position:dist(obs_.position)
      if dist_to_agent < min_dist then
        min_dist = dist_to_agent
        most_threatening = obs_
      end
    end
  end

  if not most_threatening then return M.vec2(0, 0) end
  local mt_ = most_threatening --[[:! { position: Vec2, radius: number }]]

  -- Avoidance force: push directly away from obstacle center
  local away = ahead:sub(mt_.position) --[[:! Vec2]]
  return away:normalize():mul(agent.max_force) --[[:! Vec2]]
end

-- ---------------------------------------------------------------------------
-- Wall follow
-- ---------------------------------------------------------------------------

--- Steer to follow walls (stay near them without colliding).
-- walls: array of line segments { a=vec2, b=vec2, normal=vec2 }
--   normal points away from the wall surface (into the open space).
-- The agent tries to maintain a distance of ~opts.desired_dist from the wall.
-- opts: { desired_dist=20, lookahead=30 }
--: (Agent, { [integer]: { a: Vec2, b: Vec2, normal: Vec2, _closest_pt: Vec2 | nil } }, { desired_dist: number | nil, lookahead: number | nil } | nil) -> Vec2
function M.wall_follow(agent, walls, opts)
  local opts_ = (opts or {}) --[[:! { desired_dist: number | nil, lookahead: number | nil }]]
  local desired_dist = opts_.desired_dist or 20
  local lookahead    = opts_.lookahead    or 30

  if not walls or #walls == 0 then return M.vec2(0, 0) end

  -- Find the wall closest to the agent
  --: { a: Vec2, b: Vec2, normal: Vec2, _closest_pt: Vec2 | nil } | nil
  local closest_wall = nil
  local min_dist     = math_huge

  for _, wall in ipairs(walls) do
    local wall_ = wall --[[:! { a: Vec2, b: Vec2, normal: Vec2, _closest_pt: Vec2 | nil }]]
    -- Project agent position onto the wall segment
    local ab  = wall_.b:sub(wall_.a) --[[:! Vec2]]
    local ap  = agent.position:sub(wall_.a) --[[:! Vec2]]
    local len_sq = ab:dot(ab)
    --: number
    local t   = 0.0
    if len_sq > 1e-12 then
      t = math_max(0, math_min(1, ap:dot(ab) / len_sq))
    end
    local closest_pt = wall_.a:add(ab:mul(t) --[[:! Vec2]])
    local dist = agent.position:dist(closest_pt)
    if dist < min_dist then
      min_dist     = dist
      closest_wall = wall_
      -- store closest_pt for use below
      wall_._closest_pt = closest_pt
    end
  end

  if not closest_wall then return M.vec2(0, 0) end

  -- Steer parallel to wall but corrected toward desired_dist
  local n    = closest_wall.normal:normalize() --[[:! Vec2]]
  local diff = min_dist - desired_dist
  -- Correction: push toward or away from wall
  local correction = n:mul(diff * agent.max_force / (desired_dist + 1e-12)) --[[:! Vec2]]
  return correction:limit(agent.max_force) --[[:! Vec2]]
end

-- ---------------------------------------------------------------------------
-- Path follow
-- ---------------------------------------------------------------------------

--- Follow a path (array of vec2 waypoints).
-- opts: { radius=10 }  -- radius within which a waypoint is considered reached
--: (Agent, { [integer]: Vec2 }, { radius: number | nil } | nil) -> Vec2
function M.path_follow(agent, path, opts)
  local opts_ = (opts or {}) --[[:! { radius: number | nil }]]
  local radius = opts_.radius or 10

  if not path or #path == 0 then return M.vec2(0, 0) end

  -- Find the current target: first waypoint outside the radius
  local target = path[#path]  -- default to last
  for i = 1, #path do
    if agent.position:dist(path[i]) > radius then
      target = path[i]
      break
    end
  end

  return M.seek(agent, target)
end

-- ---------------------------------------------------------------------------
-- Separation
-- ---------------------------------------------------------------------------

--- Steer away from nearby neighbors.
-- neighbors: array of agents
-- opts: { radius=30 }
--: (Agent, { [integer]: Agent }, { radius: number | nil } | nil) -> Vec2
function M.separation(agent, neighbors, opts)
  local opts_ = (opts or {}) --[[:! { radius: number | nil }]]
  local radius = opts_.radius or 30

  local force = M.vec2(0, 0)
  local count = 0 --: integer

  for _, other in ipairs(neighbors) do
    local other_ = other --[[:! Agent]]
    if other_ ~= agent then
      local dsq = agent.position:dist_sq(other_.position)
      if dsq < radius * radius and dsq > 1e-12 then
        local d   = math_sqrt(dsq)
        local away = agent.position:sub(other_.position):mul(1 / d) --[[: Vec2]]
        -- Weight by inverse distance
        force = force:add(away:mul(radius / d))
        count = count + 1
      end
    end
  end

  if count == 0 then return M.vec2(0, 0) end
  force = force:mul(1 / count)
  return force:limit(agent.max_force)
end

-- ---------------------------------------------------------------------------
-- Cohesion
-- ---------------------------------------------------------------------------

--- Steer toward the average position of neighbors.
--: (Agent, { [integer]: Agent }) -> Vec2
function M.cohesion(agent, neighbors)
  if not neighbors or #neighbors == 0 then return M.vec2(0, 0) end

  --: number
  local cx = 0
  --: number
  local cy = 0
  local count = 0 --: integer

  for _, other in ipairs(neighbors) do
    local other_ = other --[[:! Agent]]
    if other_ ~= agent then
      cx    = cx + other_.position.x
      cy    = cy + other_.position.y
      count = count + 1
    end
  end

  if count == 0 then return M.vec2(0, 0) end
  local center = M.vec2(cx / count, cy / count)
  return M.seek(agent, center)
end

-- ---------------------------------------------------------------------------
-- Alignment
-- ---------------------------------------------------------------------------

--- Steer toward the average heading of neighbors.
--: (Agent, { [integer]: Agent }) -> Vec2
function M.alignment(agent, neighbors)
  if not neighbors or #neighbors == 0 then return M.vec2(0, 0) end

  --: number
  local vx = 0
  --: number
  local vy = 0
  local count = 0 --: integer

  for _, other in ipairs(neighbors) do
    local other_ = other --[[:! Agent]]
    if other_ ~= agent then
      vx    = vx + other_.velocity.x
      vy    = vy + other_.velocity.y
      count = count + 1
    end
  end

  if count == 0 then return M.vec2(0, 0) end

  local avg_vel = M.vec2(vx / count, vy / count)
  local len     = avg_vel:length()
  if len < 1e-12 then return M.vec2(0, 0) end
  local desired = avg_vel:mul(agent.max_speed / len)
  return steering_force(agent, desired)
end

-- ---------------------------------------------------------------------------
-- Combine
-- ---------------------------------------------------------------------------

--- Combine multiple behaviors with weights.
-- behaviors: array of { fn, agent, ..., weight=number }
-- Each entry is called as fn(agent, ...) and the result is weighted.
-- The sum is clamped to agent.max_force.
function M.combine(behaviors)
  --: { [integer]: { [integer]: unknown, weight: number | nil } }
  local behaviors_ = behaviors --[[:! { [integer]: { [integer]: unknown, weight: number | nil } }]]
  if not behaviors_ or #behaviors_ == 0 then return M.vec2(0, 0) end

  -- Extract agent from first entry to get max_force
  local agent = behaviors_[1][2] --[[:! Agent]]
  local force = M.vec2(0, 0)

  for _, entry in ipairs(behaviors_) do
    local fn     = (entry[1] --[[:! (...unknown) -> Vec2 | nil]])
    local weight = (entry.weight or 1.0)
    -- entry[2] is agent, entry[3..n] are additional args
    local args = {}
    for i = 2, #entry do
      args[#args + 1] = entry[i]
    end
    local f = fn(unpack(args))
    force = force:add(f:mul(weight))
  end

  return force:limit(agent.max_force)
end

-- ---------------------------------------------------------------------------
-- Flock
-- ---------------------------------------------------------------------------

--- Update all agents with separation + cohesion + alignment, then integrate.
-- opts: { dt=1/60, sep_radius=30, sep_weight=1.5, coh_weight=1.0, ali_weight=1.0 }
function M.flock(agents, opts)
  --: { dt: number | nil, sep_radius: number | nil, sep_weight: number | nil, coh_weight: number | nil, ali_weight: number | nil }
  local opts_ = opts or {}
  local dt         = opts_.dt         or (1 / 60)
  local sep_radius = opts_.sep_radius or 30
  local sw         = opts_.sep_weight or 1.5
  local cw         = opts_.coh_weight or 1.0
  local aw         = opts_.ali_weight or 1.0

  -- Compute forces for all agents first, then integrate (avoid order dependency)
  --: { [integer]: Vec2 }
  local forces = {}
  for i, ag in ipairs(agents) do
    local ag_ = ag --[[:! Agent]]
    local sep = M.separation(ag_, agents --[[:! { [integer]: Agent }]], { radius = sep_radius })
    local coh = M.cohesion(ag_, agents --[[:! { [integer]: Agent }]])
    local ali = M.alignment(ag_, agents --[[:! { [integer]: Agent }]])
    forces[i] = sep:mul(sw):add(coh:mul(cw)):add(ali:mul(aw)):limit(ag_.max_force)
  end

  for i, ag in ipairs(agents) do
    local ag_ = ag --[[:! Agent]]
    ag_:update(forces[i], dt)
  end
end

return M
