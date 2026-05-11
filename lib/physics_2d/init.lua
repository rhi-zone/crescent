if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- 2D rigid body physics simulation.
-- Semi-implicit Euler integration, AABB/circle collision detection,
-- impulse-based resolution, distance joints.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Math helpers
-- ---------------------------------------------------------------------------

local sqrt = math.sqrt
local abs  = math.abs
local max  = math.max

--: (number, number) -> number
local function vec_len(x, y)
  return sqrt(x * x + y * y)
end

--: (number, number) -> (number, number, number)
local function vec_normalize(x, y)
  local len = sqrt(x * x + y * y)
  if len < 1e-10 then return 0, 0, 0 end
  return x / len, y / len, len
end

--: (number, number, number) -> number
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ---------------------------------------------------------------------------
-- Body
-- ---------------------------------------------------------------------------

--:: BodyOpts = { x: number | nil, y: number | nil, vx: number | nil, vy: number | nil, mass: number | nil, angle: number | nil, angular_vel: number | nil, restitution: number | nil, friction: number | nil, shape: string | nil, radius: number | nil, width: number | nil, height: number | nil, ... }
--:: BodyShape = { x: number, y: number, vx: number, vy: number, mass: number, inv_mass: number, _angle: number, angular_vel: number, restitution: number, friction: number, shape: string, radius: number, width: number, height: number, _fx: number, _fy: number, _torque: number, inertia: number, inv_inertia: number, _world: unknown, ... }
--:: JointShape = { body_a: BodyShape, body_b: BodyShape, target_dist: number, stiffness: number, _world: unknown, ... }
--:: CollInfo = { nx: number, ny: number, depth: number, cx: number, cy: number }
--:: WorldOpts = { gravity: { x: number, y: number } | nil, damping: number | nil, ... }
--:: WorldShape = { gx: number, gy: number, damping: number, _bodies: { [integer]: BodyShape }, _joints: { [integer]: JointShape }, ... }

local Body = {}
Body.__index = Body

--: (unknown, (BodyOpts | nil)) -> BodyShape
local function new_body(world, opts)
  opts = (opts or {}) --[[:! BodyOpts]]
  local b = setmetatable({}, Body) --[[: unknown]]
  b._world        = world
  b.x             = opts.x or 0
  b.y             = opts.y or 0
  b.vx            = opts.vx or 0
  b.vy            = opts.vy or 0
  b.mass          = opts.mass ~= nil and opts.mass or 1.0
  b.inv_mass      = (b.mass == 0) and 0 or (1.0 / b.mass)
  b._angle        = opts.angle or 0
  b.angular_vel   = opts.angular_vel or 0
  b.restitution   = opts.restitution ~= nil and opts.restitution or 0.5
  b.friction      = opts.friction ~= nil and opts.friction or 0.3
  b.shape         = opts.shape or "circle"
  b.radius        = opts.radius or 10
  b.width         = opts.width or 10
  b.height        = opts.height or 10
  b._fx           = 0  -- force accumulator
  b._fy           = 0
  b._torque       = 0
  -- Moment of inertia (simplified)
  if b.shape == "circle" then
    b.inertia     = (b.mass == 0) and 0 or (0.5 * b.mass * b.radius * b.radius)
  else
    b.inertia     = (b.mass == 0) and 0 or (b.mass * (b.width * b.width + b.height * b.height) / 12)
  end
  b.inv_inertia   = (b.inertia == 0) and 0 or (1.0 / b.inertia)
  return b --[[:! BodyShape]]
end

function Body:position()
  return self.x, self.y
end

function Body:velocity()
  return self.vx, self.vy
end

function Body:angle()
  return self._angle
end

function Body:set_position(x, y)
  self.x, self.y = x, y
end

function Body:set_velocity(vx, vy)
  self.vx, self.vy = vx, vy
end

function Body:apply_force(fx, fy)
  self._fx = self._fx + fx
  self._fy = self._fy + fy
end

function Body:apply_impulse(fx, fy)
  self.vx = self.vx + fx * self.inv_mass
  self.vy = self.vy + fy * self.inv_mass
end

function Body:is_static()
  return self.mass == 0
end

-- ---------------------------------------------------------------------------
-- Collision detection helpers
-- ---------------------------------------------------------------------------

-- Circle vs circle
-- Returns nil or {nx, ny, depth, cx, cy}
--: (BodyShape, BodyShape) -> (CollInfo | nil)
local function collide_circle_circle(a, b)
  local dx = b.x - a.x
  local dy = b.y - a.y
  local dist_sq = dx * dx + dy * dy
  local r_sum = a.radius + b.radius
  if dist_sq >= r_sum * r_sum then return nil end
  local dist = sqrt(dist_sq)
  local nx, ny
  if dist < 1e-10 then
    nx, ny = 1, 0
    dist = 0
  else
    nx, ny = dx / dist, dy / dist
  end
  local depth = r_sum - dist
  local cx = a.x + nx * a.radius
  local cy = a.y + ny * a.radius
  return { nx = nx, ny = ny, depth = depth, cx = cx, cy = cy }
end

-- Circle vs AABB box
-- Returns nil or {nx, ny, depth, cx, cy}
--: (BodyShape, BodyShape) -> (CollInfo | nil)
local function collide_circle_box(circle, box)
  -- Half-extents of the box
  local hw = box.width  * 0.5
  local hh = box.height * 0.5
  -- Closest point on box to circle center
  local closest_x = clamp(circle.x, box.x - hw, box.x + hw)
  local closest_y = clamp(circle.y, box.y - hh, box.y + hh)
  local dx = circle.x - closest_x
  local dy = circle.y - closest_y
  local dist_sq = dx * dx + dy * dy
  if dist_sq >= circle.radius * circle.radius then return nil end
  local dist = sqrt(dist_sq)
  local nx, ny
  if dist < 1e-10 then
    -- Circle center inside box — push out on shortest axis
    local ox = (circle.x - box.x)
    local oy = (circle.y - box.y)
    if abs(ox) / hw < abs(oy) / hh then
      nx, ny = (ox >= 0) and 1 or -1, 0
      dist = hw - abs(ox)
    else
      nx, ny = 0, (oy >= 0) and 1 or -1
      dist = hh - abs(oy)
    end
    local depth2 = circle.radius + dist
    local cx2 = circle.x - nx * circle.radius
    local cy2 = circle.y - ny * circle.radius
    return { nx = nx, ny = ny, depth = depth2, cx = cx2, cy = cy2 }
  end
  nx, ny = dx / dist, dy / dist
  local depth = circle.radius - dist
  local cx = closest_x
  local cy = closest_y
  return { nx = nx, ny = ny, depth = depth, cx = cx, cy = cy }
end

-- AABB vs AABB
-- Returns nil or {nx, ny, depth, cx, cy}
--: (BodyShape, BodyShape) -> (CollInfo | nil)
local function collide_box_box(a, b)
  local hw_a = a.width  * 0.5
  local hh_a = a.height * 0.5
  local hw_b = b.width  * 0.5
  local hh_b = b.height * 0.5
  local dx = b.x - a.x
  local dy = b.y - a.y
  local ox = (hw_a + hw_b) - abs(dx)
  local oy = (hh_a + hh_b) - abs(dy)
  if ox <= 0 or oy <= 0 then return nil end
  local nx, ny, depth
  if ox < oy then
    nx = (dx >= 0) and 1 or -1
    ny = 0
    depth = ox
  else
    nx = 0
    ny = (dy >= 0) and 1 or -1
    depth = oy
  end
  local cx = (a.x + b.x) * 0.5
  local cy = (a.y + b.y) * 0.5
  return { nx = nx, ny = ny, depth = depth, cx = cx, cy = cy }
end

--: (BodyShape, BodyShape) -> (CollInfo | nil)
local function detect_collision(a, b)
  local info
  if a.shape == "circle" and b.shape == "circle" then
    info = collide_circle_circle(a, b)
  elseif a.shape == "circle" and b.shape == "box" then
    info = collide_circle_box(a, b)
    -- normal points from box to circle; we want from a to b (a=circle, b=box)
    -- so flip to point from a toward b: normal should push a away from b
    -- collide_circle_box returns normal pointing from box surface toward circle
    -- that's from b toward a, so flip
    if info then
      info.nx, info.ny = -info.nx, -info.ny
    end
  elseif a.shape == "box" and b.shape == "circle" then
    info = collide_circle_box(b, a)
    -- normal points from a's surface toward b (circle)
    -- collide_circle_box returns normal pointing toward circle = toward b, correct
  elseif a.shape == "box" and b.shape == "box" then
    info = collide_box_box(a, b)
  end
  return info
end

-- ---------------------------------------------------------------------------
-- Impulse resolution
-- ---------------------------------------------------------------------------

--: (BodyShape, BodyShape, CollInfo) -> nil
local function resolve_collision(a, b, info)
  local nx, ny = info.nx, info.ny
  local depth   = info.depth

  -- Positional correction (pushes apart)
  local total_inv_mass = a.inv_mass + b.inv_mass
  if total_inv_mass < 1e-10 then return end  -- both static

  local correction = depth / total_inv_mass
  a.x = a.x - nx * correction * a.inv_mass
  a.y = a.y - ny * correction * a.inv_mass
  b.x = b.x + nx * correction * b.inv_mass
  b.y = b.y + ny * correction * b.inv_mass

  -- Relative velocity along normal
  local rvx = b.vx - a.vx
  local rvy = b.vy - a.vy
  local vn = rvx * nx + rvy * ny

  -- Don't resolve if velocities are separating
  if vn > 0 then return end

  local e = math.min(a.restitution, b.restitution)
  local j = -(1 + e) * vn / total_inv_mass

  a.vx = a.vx - j * nx * a.inv_mass
  a.vy = a.vy - j * ny * a.inv_mass
  b.vx = b.vx + j * nx * b.inv_mass
  b.vy = b.vy + j * ny * b.inv_mass

  -- Friction
  local tx = rvx - vn * nx
  local ty = rvy - vn * ny
  local tlen = vec_len(tx, ty)
  if tlen > 1e-10 then
    tx, ty = tx / tlen, ty / tlen
    local vt = rvx * tx + rvy * ty
    local mu = (a.friction + b.friction) * 0.5
    local jt = clamp(-vt / total_inv_mass, -abs(j) * mu, abs(j) * mu)
    a.vx = a.vx - jt * tx * a.inv_mass
    a.vy = a.vy - jt * ty * a.inv_mass
    b.vx = b.vx + jt * tx * b.inv_mass
    b.vy = b.vy + jt * ty * b.inv_mass
  end
end

-- ---------------------------------------------------------------------------
-- Distance joint
-- ---------------------------------------------------------------------------

local Joint = {}
Joint.__index = Joint

--: (unknown, BodyShape, BodyShape, ({ target_dist: number | nil, stiffness: number | nil, ... } | nil)) -> JointShape
local function new_joint(world, body_a, body_b, opts)
  opts = (opts or {}) --[[:! { target_dist: number | nil, stiffness: number | nil, ... }]]
  local j = setmetatable({}, Joint) --[[: unknown]]
  j._world   = world
  j.body_a   = body_a
  j.body_b   = body_b
  local dx = body_b.x - body_a.x
  local dy = body_b.y - body_a.y
  j.target_dist = opts.target_dist or sqrt(dx * dx + dy * dy)
  j.stiffness   = opts.stiffness ~= nil and opts.stiffness or 1.0
  return j --[[:! JointShape]]
end

--: (JointShape, number) -> nil
local function step_joint(j, dt)
  local a, b = j.body_a, j.body_b
  local dx = b.x - a.x
  local dy = b.y - a.y
  local nx, ny, dist = vec_normalize(dx, dy)
  if dist < 1e-10 then return end

  local delta = dist - j.target_dist
  if abs(delta) < 1e-10 then return end

  local total_inv_mass = a.inv_mass + b.inv_mass
  if total_inv_mass < 1e-10 then return end

  -- Correct positions
  local correction = delta * j.stiffness / total_inv_mass * 0.5
  a.x = a.x + nx * correction * a.inv_mass
  a.y = a.y + ny * correction * a.inv_mass
  b.x = b.x - nx * correction * b.inv_mass
  b.y = b.y - ny * correction * b.inv_mass

  -- Velocity correction along the constraint axis
  local rvx = b.vx - a.vx
  local rvy = b.vy - a.vy
  local vn = rvx * nx + rvy * ny
  local impulse = -vn * j.stiffness / total_inv_mass * 0.5
  a.vx = a.vx - nx * impulse * a.inv_mass
  a.vy = a.vy - ny * impulse * a.inv_mass
  b.vx = b.vx + nx * impulse * b.inv_mass
  b.vy = b.vy + ny * impulse * b.inv_mass
end

-- ---------------------------------------------------------------------------
-- World
-- ---------------------------------------------------------------------------

local World = {}
World.__index = World

--: ((WorldOpts | nil)) -> WorldShape
local function new_world(opts)
  opts = (opts or {}) --[[:! WorldOpts]]
  local grav = opts.gravity or { x = 0.0, y = -9.8 }
  local w = setmetatable({}, World) --[[: unknown]]
  w.gx      = grav.x
  w.gy      = grav.y
  w.damping = opts.damping ~= nil and opts.damping or 0.999
  w._bodies = {}
  w._joints = {}
  return w --[[:! WorldShape]]
end

function World:body(opts)
  local b = new_body(self, opts)
  self._bodies[#self._bodies + 1] = b
  return b
end

function World:particle(x, y, mass)
  return self:body({
    x = x, y = y, mass = mass,
    shape = "circle", radius = 1,
    restitution = 0, friction = 0,
  })
end

function World:distance_joint(body_a, body_b, opts)
  local j = new_joint(self, body_a, body_b, opts)
  self._joints[#self._joints + 1] = j
  return j
end

function World:remove(body)
  local bs = self._bodies
  for i = 1, #bs do
    if bs[i] == body then
      table.remove(bs, i)
      return
    end
  end
end

function World:bodies()
  return self._bodies
end

function World:collisions()
  local bs = self._bodies
  local result = {}
  for i = 1, #bs do
    for k = i + 1, #bs do
      local a, b = bs[i], bs[k]
      local info = detect_collision(a, b)
      if info then
        result[#result + 1] = {
          body_a    = a,
          body_b    = b,
          normal    = { x = info.nx, y = info.ny },
          depth     = info.depth,
          contact_x = info.cx,
          contact_y = info.cy,
        }
      end
    end
  end
  return result
end

function World:step(dt)
  local self_ = self --[[:! WorldShape]]
  local bs  = self_._bodies
  local gx  = self_.gx
  local gy  = self_.gy
  local dmp = self_.damping

  -- Integrate velocity and position (semi-implicit Euler)
  for i = 1, #bs do
    local b = bs[i]
    if b.inv_mass > 0 then
      -- Gravity + accumulated forces
      b.vx = (b.vx + (b._fx * b.inv_mass + gx) * dt) * dmp
      b.vy = (b.vy + (b._fy * b.inv_mass + gy) * dt) * dmp
      b.x  = b.x + b.vx * dt
      b.y  = b.y + b.vy * dt
      -- Angular
      b.angular_vel = (b.angular_vel + b._torque * b.inv_inertia * dt) * dmp
      b._angle      = b._angle + b.angular_vel * dt
    end
    -- Reset force accumulators
    b._fx, b._fy, b._torque = 0, 0, 0
  end

  -- Detect and resolve collisions
  for i = 1, #bs do
    for k = i + 1, #bs do
      local a, b = bs[i], bs[k]
      local info = detect_collision(a, b)
      if info then
        resolve_collision(a, b, info)
      end
    end
  end

  -- Step joints
  for i = 1, #self_._joints do
    step_joint(self_._joints[i], dt)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.world(opts)
  return new_world(opts)
end

return M
