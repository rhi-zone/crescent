if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ========================
-- LCG RNG
-- ========================

local function lcg_new(seed)
  local state = seed or 0
  return {
    next = function(self)
      -- LCG constants from Numerical Recipes
      state = (state * 1664525 + 1013904223) % 4294967296
      return state
    end,
    float = function(self)
      state = (state * 1664525 + 1013904223) % 4294967296
      return state / 4294967296
    end,
    range = function(self, lo, hi)
      -- returns float in [lo, hi]
      state = (state * 1664525 + 1013904223) % 4294967296
      local f = state / 4294967296
      return lo + f * (hi - lo)
    end,
  }
end

-- ========================
-- HELPERS
-- ========================

local function resolve_range(v, rng)
  if type(v) == "table" then
    if v.min ~= nil then
      return rng:range(v.min, v.max)
    end
    return v
  end
  return v
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local DEG_TO_RAD = math.pi / 180

-- Emit a particle from the given emitter opts, writing into slot `p`.
local function init_particle(p, opts, rng)
  -- Position based on shape
  local shape = opts.shape or "point"
  local px, py = opts.position and opts.position.x or 0,
                 opts.position and opts.position.y or 0

  if shape == "point" then
    p.x = px
    p.y = py
  elseif shape == "circle" then
    local r = opts.radius or 10
    local angle = rng:float() * math.pi * 2
    local dist = math.sqrt(rng:float()) * r
    p.x = px + math.cos(angle) * dist
    p.y = py + math.sin(angle) * dist
  elseif shape == "rect" then
    local w = opts.width or 20
    local h = opts.height or 10
    p.x = px + (rng:float() - 0.5) * w
    p.y = py + (rng:float() - 0.5) * h
  elseif shape == "line" then
    local w = opts.width or 20
    p.x = px + (rng:float() - 0.5) * w
    p.y = py
  else
    p.x = px
    p.y = py
  end

  -- Lifetime
  local lt = opts.lifetime
  if type(lt) == "table" and lt.min ~= nil then
    p.lifetime = rng:range(lt.min, lt.max)
  elseif type(lt) == "number" then
    p.lifetime = lt
  else
    p.lifetime = 1.0
  end
  p.age = 0

  -- Velocity from speed + angle
  local speed_range = opts.speed or { min = 50, max = 100 }
  local angle_range = opts.angle or { min = 0, max = 360 }
  local speed = resolve_range(speed_range, rng)
  local angle_deg = resolve_range(angle_range, rng)
  local angle_rad = angle_deg * DEG_TO_RAD
  p.vx = math.cos(angle_rad) * speed
  p.vy = math.sin(angle_rad) * speed

  -- Size (start value; interpolation happens in update)
  local size_opts = opts.size or { start = 10, ["end"] = 2 }
  if type(size_opts) == "number" then
    p.size = size_opts
    p._size_start = size_opts
    p._size_end = size_opts
  else
    p._size_start = size_opts.start or 10
    p._size_end = size_opts["end"] or size_opts.end_ or 2
    p.size = p._size_start
  end

  -- Color
  local color_opts = opts.color or {}
  local cs = color_opts.start or { r = 1, g = 1, b = 1, a = 1 }
  local ce = color_opts["end"] or color_opts.end_ or { r = 1, g = 1, b = 1, a = 0 }
  p._cr_start = cs.r or 1
  p._cg_start = cs.g or 1
  p._cb_start = cs.b or 1
  p._ca_start = cs.a or 1
  p._cr_end   = ce.r or 1
  p._cg_end   = ce.g or 1
  p._cb_end   = ce.b or 1
  p._ca_end   = ce.a or 0
  p.r = p._cr_start
  p.g = p._cg_start
  p.b = p._cb_start
  p.a = p._ca_start

  -- Rotation
  local rot_speed_range = opts.rotation_speed or { min = 0, max = 0 }
  p.rotation = 0
  p.rot_speed = resolve_range(rot_speed_range, rng)

  p.alive = true
end

-- ========================
-- EMITTER
-- ========================

function M.emitter(opts)
  opts = opts or {}
  local seed = opts.seed or 0
  local rng = lcg_new(seed)
  local max_particles = opts.max_particles or 500
  local rate = opts.rate or 20
  local burst_count = opts.burst or 50

  -- Particle pool: pre-allocate all slots
  local pool = {}
  for i = 1, max_particles do
    pool[i] = { alive = false }
  end

  -- _emit_acc: fractional accumulator for rate-based emission
  local e = {
    _pool = pool,
    _max = max_particles,
    _rate = rate,
    _burst_count = burst_count,
    _opts = opts,
    _rng = rng,
    _emit_acc = 0,
    _running = true,
    _affectors = {},
    _live_count = 0,
  }

  -- Built-in affectors from opts
  if opts.gravity then
    local gx = opts.gravity.x or 0
    local gy = opts.gravity.y or -9.8
    e._affectors[#e._affectors + 1] = M.affectors.gravity(gx, gy)
  end
  if opts.drag and opts.drag ~= 0 then
    e._affectors[#e._affectors + 1] = M.affectors.drag(opts.drag)
  end

  -- Find a free slot in the pool, or nil if full.
  local function alloc_slot()
    for i = 1, max_particles do
      if not pool[i].alive then return pool[i] end
    end
    return nil
  end

  -- Emit exactly one particle.
  local function emit_one()
    local p = alloc_slot()
    if not p then return false end
    init_particle(p, opts, rng)
    e._live_count = e._live_count + 1
    return true
  end

  function e:update(dt)
    -- Emit new particles based on rate
    if self._running then
      self._emit_acc = self._emit_acc + self._rate * dt
      local to_emit = math.floor(self._emit_acc)
      self._emit_acc = self._emit_acc - to_emit
      for _ = 1, to_emit do
        if not emit_one() then break end
      end
    end

    -- Update all live particles
    local affectors = self._affectors
    local naffectors = #affectors
    for i = 1, max_particles do
      local p = pool[i]
      if p.alive then
        -- Apply affectors
        for j = 1, naffectors do
          affectors[j](p, dt)
        end
        -- Integrate position
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt
        -- Rotation
        p.rotation = p.rotation + p.rot_speed * dt
        -- Age
        p.age = p.age + dt
        -- Interpolate size and color
        local t = p.age / p.lifetime
        if t > 1 then t = 1 end
        p.size = lerp(p._size_start, p._size_end, t)
        p.r = lerp(p._cr_start, p._cr_end, t)
        p.g = lerp(p._cg_start, p._cg_end, t)
        p.b = lerp(p._cb_start, p._cb_end, t)
        p.a = lerp(p._ca_start, p._ca_end, t)
        -- Kill if expired
        if p.age >= p.lifetime then
          p.alive = false
          self._live_count = self._live_count - 1
        end
      end
    end
  end

  function e:burst(n)
    n = n or self._burst_count
    for _ = 1, n do
      if not emit_one() then break end
    end
  end

  function e:count()
    return self._live_count
  end

  function e:each(fn)
    for i = 1, max_particles do
      local p = pool[i]
      if p.alive then fn(p) end
    end
  end

  function e:start()
    self._running = true
  end

  function e:stop()
    self._running = false
  end

  function e:reset()
    for i = 1, max_particles do
      pool[i].alive = false
    end
    self._live_count = 0
    self._emit_acc = 0
  end

  function e:add_affector(fn)
    self._affectors[#self._affectors + 1] = fn
  end

  return e
end

-- ========================
-- BUILT-IN AFFECTORS
-- ========================

M.affectors = {}

function M.affectors.gravity(gx, gy)
  gx = gx or 0
  gy = gy or -9.8
  return function(p, dt)
    p.vx = p.vx + gx * dt
    p.vy = p.vy + gy * dt
  end
end

function M.affectors.drag(coeff)
  coeff = coeff or 0.1
  return function(p, dt)
    local factor = 1 - coeff * dt
    if factor < 0 then factor = 0 end
    p.vx = p.vx * factor
    p.vy = p.vy * factor
  end
end

function M.affectors.attractor(ax, ay, strength)
  strength = strength or 100
  return function(p, dt)
    local dx = ax - p.x
    local dy = ay - p.y
    local dist2 = dx * dx + dy * dy
    if dist2 < 0.0001 then return end
    local dist = math.sqrt(dist2)
    local force = strength / dist2
    p.vx = p.vx + (dx / dist) * force * dt
    p.vy = p.vy + (dy / dist) * force * dt
  end
end

function M.affectors.turbulence(strength, seed)
  strength = strength or 10
  local s = seed or 1
  -- Seeded LCG noise: advance state per call using particle address trick (use p.x/p.y)
  return function(p, dt)
    -- Simple hash of position + seed for pseudo-random per-particle noise
    local hx = math.floor(p.x * 0.1 + s * 17) % 65536
    local hy = math.floor(p.y * 0.1 + s * 31) % 65536
    local h = (hx * 1664525 + hy * 1013904223 + s) % 4294967296
    local nx = ((h % 256) / 128) - 1      -- [-1, 1]
    local h2 = (h * 1664525 + 1013904223) % 4294967296
    local ny = ((h2 % 256) / 128) - 1
    p.vx = p.vx + nx * strength * dt
    p.vy = p.vy + ny * strength * dt
  end
end

return M
