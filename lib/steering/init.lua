if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/steering/init.lua
-- Craig Reynolds-style 2D steering behaviors for game agents.
-- All behaviors return a force vec2. Error convention: (nil, errmsg).

local M = {}
M._tier = "pure"

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

function vec2_mt:add(b)  return M.vec2(self.x + b.x, self.y + b.y) end
function vec2_mt:sub(b)  return M.vec2(self.x - b.x, self.y - b.y) end
function vec2_mt:mul(s)  return M.vec2(self.x * s,   self.y * s)   end
function vec2_mt:div(s)  return M.vec2(self.x / s,   self.y / s)   end
function vec2_mt:dot(b)  return self.x * b.x + self.y * b.y        end

function vec2_mt:length_sq()
  return self.x * self.x + self.y * self.y
end

function vec2_mt:length()
  return math_sqrt(self.x * self.x + self.y * self.y)
end

function vec2_mt:normalize()
  local len = self:length()
  if len < 1e-12 then return M.vec2(0, 0) end
  return M.vec2(self.x / len, self.y / len)
end

function vec2_mt:limit(max_len)
  local lsq = self:length_sq()
  if lsq > max_len * max_len then
    return self:normalize():mul(max_len)
  end
  return M.vec2(self.x, self.y)
end

function vec2_mt:dist(b)
  local dx = self.x - b.x
  local dy = self.y - b.y
  return math_sqrt(dx * dx + dy * dy)
end

function vec2_mt:dist_sq(b)
  local dx = self.x - b.x
  local dy = self.y - b.y
  return dx * dx + dy * dy
end

function vec2_mt:angle()
  return math_atan2(self.y, self.x)
end

function vec2_mt:rotate(theta)
  local c = math_cos(theta)
  local s = math_sin(theta)
  return M.vec2(self.x * c - self.y * s, self.x * s + self.y * c)
end

function vec2_mt:lerp(b, t)
  return M.vec2(self.x + (b.x - self.x) * t, self.y + (b.y - self.y) * t)
end

function vec2_mt:__tostring()
  return "vec2(" .. self.x .. ", " .. self.y .. ")"
end

--- Construct a vec2.
function M.vec2(x, y)
  return setmetatable({ x = x or 0, y = y or 0 }, vec2_mt)
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
function agent_mt:update(force, dt)
  -- acceleration = force / mass
  local mass = self.mass or 1.0
  local acc = force:mul(dt / mass)
  self.velocity = self.velocity:add(acc):limit(self.max_speed)
  self.position = self.position:add(self.velocity:mul(dt))
end

--- Construct an agent.
-- opts: { position, velocity, max_speed, max_force, mass }
function M.agent(opts)
  opts = opts or {}
  return setmetatable({
    position  = opts.position  or M.vec2(0, 0),
    velocity  = opts.velocity  or M.vec2(0, 0),
    max_speed = opts.max_speed or 5.0,
    max_force = opts.max_force or 0.5,
    mass      = opts.mass      or 1.0,
    -- wander state
    _wander_angle = 0,
  }, agent_mt)
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function desired_velocity_toward(agent, target_pos, speed)
  local d = target_pos:sub(agent.position)
  local len = d:length()
  if len < 1e-12 then return M.vec2(0, 0) end
  return d:mul(speed / len)
end

local function steering_force(agent, desired)
  return desired:sub(agent.velocity):limit(agent.max_force)
end

-- ---------------------------------------------------------------------------
-- Seek
-- ---------------------------------------------------------------------------

--- Steer toward target_pos at full speed.
function M.seek(agent, target_pos)
  local desired = desired_velocity_toward(agent, target_pos, agent.max_speed)
  return steering_force(agent, desired)
end

-- ---------------------------------------------------------------------------
-- Flee
-- ---------------------------------------------------------------------------

--- Steer away from threat_pos at full speed.
function M.flee(agent, threat_pos)
  local d = agent.position:sub(threat_pos)
  local len = d:length()
  if len < 1e-12 then return M.vec2(0, 0) end
  local desired = d:mul(agent.max_speed / len)
  return steering_force(agent, desired)
end

-- ---------------------------------------------------------------------------
-- Arrive
-- ---------------------------------------------------------------------------

--- Seek with deceleration inside slow_radius; stop inside stop_radius.
-- opts: { slow_radius=50, stop_radius=5 }
function M.arrive(agent, target_pos, opts)
  opts = opts or {}
  local slow_radius = opts.slow_radius or 50
  local stop_radius = opts.stop_radius or 5

  local d = target_pos:sub(agent.position)
  local dist = d:length()

  if dist < stop_radius then
    -- Brake: desired velocity = zero (steer toward zero)
    return steering_force(agent, M.vec2(0, 0))
  end

  local speed
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
function M.wander(agent, opts)
  opts = opts or {}
  local radius   = opts.radius   or 20
  local distance = opts.distance or 30
  local jitter   = opts.jitter   or 0.5

  -- Optionally seed once; thereafter use math.random
  if opts.seed and not agent._wander_seeded then
    math.randomseed(opts.seed)
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
function M.obstacle_avoidance(agent, obstacles, opts)
  opts = opts or {}
  local lookahead = opts.lookahead or 40

  local speed = agent.velocity:length()
  if speed < 1e-12 then return M.vec2(0, 0) end

  local ahead = agent.position:add(agent.velocity:normalize():mul(lookahead))

  -- Find the closest obstacle that intersects the lookahead ray
  local most_threatening = nil
  local min_dist = math_huge

  for _, obs in ipairs(obstacles) do
    -- Approximate: check if obstacle center is within (obs.radius) of the ahead point
    local d = ahead:dist(obs.position)
    if d < obs.radius then
      local dist_to_agent = agent.position:dist(obs.position)
      if dist_to_agent < min_dist then
        min_dist = dist_to_agent
        most_threatening = obs
      end
    end
  end

  if not most_threatening then return M.vec2(0, 0) end

  -- Avoidance force: push directly away from obstacle center
  local away = ahead:sub(most_threatening.position):normalize():mul(agent.max_force)
  return away
end

-- ---------------------------------------------------------------------------
-- Wall follow
-- ---------------------------------------------------------------------------

--- Steer to follow walls (stay near them without colliding).
-- walls: array of line segments { a=vec2, b=vec2, normal=vec2 }
--   normal points away from the wall surface (into the open space).
-- The agent tries to maintain a distance of ~opts.desired_dist from the wall.
-- opts: { desired_dist=20, lookahead=30 }
function M.wall_follow(agent, walls, opts)
  opts = opts or {}
  local desired_dist = opts.desired_dist or 20
  local lookahead    = opts.lookahead    or 30

  if not walls or #walls == 0 then return M.vec2(0, 0) end

  -- Find the wall closest to the agent
  local closest_wall = nil
  local min_dist     = math_huge

  for _, wall in ipairs(walls) do
    -- Project agent position onto the wall segment
    local ab  = wall.b:sub(wall.a)
    local ap  = agent.position:sub(wall.a)
    local len_sq = ab:dot(ab)
    local t   = 0
    if len_sq > 1e-12 then
      t = math_max(0, math_min(1, ap:dot(ab) / len_sq))
    end
    local closest_pt = wall.a:add(ab:mul(t))
    local dist = agent.position:dist(closest_pt)
    if dist < min_dist then
      min_dist     = dist
      closest_wall = wall
      -- store closest_pt for use below
      closest_wall._closest_pt = closest_pt
    end
  end

  if not closest_wall then return M.vec2(0, 0) end

  -- Steer parallel to wall but corrected toward desired_dist
  local n    = closest_wall.normal:normalize()
  local diff = min_dist - desired_dist
  -- Correction: push toward or away from wall
  local correction = n:mul(diff * agent.max_force / (desired_dist + 1e-12))
  return correction:limit(agent.max_force)
end

-- ---------------------------------------------------------------------------
-- Path follow
-- ---------------------------------------------------------------------------

--- Follow a path (array of vec2 waypoints).
-- opts: { radius=10 }  -- radius within which a waypoint is considered reached
function M.path_follow(agent, path, opts)
  opts = opts or {}
  local radius = opts.radius or 10

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
function M.separation(agent, neighbors, opts)
  opts = opts or {}
  local radius = opts.radius or 30

  local force = M.vec2(0, 0)
  local count = 0

  for _, other in ipairs(neighbors) do
    if other ~= agent then
      local dsq = agent.position:dist_sq(other.position)
      if dsq < radius * radius and dsq > 1e-12 then
        local d   = math_sqrt(dsq)
        local away = agent.position:sub(other.position):mul(1 / d)
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
function M.cohesion(agent, neighbors)
  if not neighbors or #neighbors == 0 then return M.vec2(0, 0) end

  local cx, cy = 0, 0
  local count  = 0

  for _, other in ipairs(neighbors) do
    if other ~= agent then
      cx    = cx + other.position.x
      cy    = cy + other.position.y
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
function M.alignment(agent, neighbors)
  if not neighbors or #neighbors == 0 then return M.vec2(0, 0) end

  local vx, vy = 0, 0
  local count  = 0

  for _, other in ipairs(neighbors) do
    if other ~= agent then
      vx    = vx + other.velocity.x
      vy    = vy + other.velocity.y
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
  if not behaviors or #behaviors == 0 then return M.vec2(0, 0) end

  -- Extract agent from first entry to get max_force
  local agent = behaviors[1][2]
  local force = M.vec2(0, 0)

  for _, entry in ipairs(behaviors) do
    local fn     = entry[1]
    local weight = entry.weight or 1.0
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
  opts = opts or {}
  local dt         = opts.dt         or (1 / 60)
  local sep_radius = opts.sep_radius or 30
  local sw         = opts.sep_weight or 1.5
  local cw         = opts.coh_weight or 1.0
  local aw         = opts.ali_weight or 1.0

  -- Compute forces for all agents first, then integrate (avoid order dependency)
  local forces = {}
  for i, ag in ipairs(agents) do
    local sep = M.separation(ag, agents, { radius = sep_radius })
    local coh = M.cohesion(ag, agents)
    local ali = M.alignment(ag, agents)
    forces[i] = sep:mul(sw):add(coh:mul(cw)):add(ali:mul(aw)):limit(ag.max_force)
  end

  for i, ag in ipairs(agents) do
    ag:update(forces[i], dt)
  end
end

return M
