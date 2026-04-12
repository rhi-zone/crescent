if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--- PID controller
-- opts.kp, opts.ki, opts.kd, opts.dt
-- opts.output_min, opts.output_max (clamping)
-- opts.integral_min, opts.integral_max (anti-windup)
-- opts.setpoint
function M.pid(opts)
  opts = opts or {}
  local self = {
    kp           = opts.kp or 1.0,
    ki           = opts.ki or 0.0,
    kd           = opts.kd or 0.0,
    dt           = opts.dt or 1.0,
    output_min   = opts.output_min,
    output_max   = opts.output_max,
    integral_min = opts.integral_min,
    integral_max = opts.integral_max,
    setpoint     = opts.setpoint or 0.0,
    _integral    = 0.0,
    _prev_error  = nil,
    _last_output = 0.0,
    _last_error  = 0.0,
    _last_deriv  = 0.0,
  }

  function self:update(measurement)
    local err = self.setpoint - measurement
    self._integral = self._integral + err * self.dt

    -- Anti-windup: clamp integral
    if self.integral_min and self._integral < self.integral_min then
      self._integral = self.integral_min
    end
    if self.integral_max and self._integral > self.integral_max then
      self._integral = self.integral_max
    end

    local deriv = 0.0
    if self._prev_error ~= nil then
      deriv = (err - self._prev_error) / self.dt
    end
    self._prev_error = err

    local output = self.kp * err + self.ki * self._integral + self.kd * deriv

    -- Output clamping
    if self.output_min and output < self.output_min then
      output = self.output_min
    end
    if self.output_max and output > self.output_max then
      output = self.output_max
    end

    self._last_output = output
    self._last_error  = err
    self._last_deriv  = deriv
    return output
  end

  function self:set_setpoint(sp)
    self.setpoint = sp
  end

  function self:reset()
    self._integral   = 0.0
    self._prev_error = nil
    self._last_output = 0.0
    self._last_error  = 0.0
    self._last_deriv  = 0.0
  end

  function self:state()
    return {
      error      = self._last_error,
      integral   = self._integral,
      derivative = self._last_deriv,
      output     = self._last_output,
    }
  end

  return self
end

--- Ziegler-Nichols tuning from ultimate gain Ku and oscillation period Tu.
-- type: "P" | "PI" | "PI" | "PD" | "PID"
-- Returns {kp, ki, kd}
function M.ziegler_nichols(ku, tu, type)
  if type == "P" then
    return { kp = 0.5 * ku, ki = 0.0, kd = 0.0 }
  elseif type == "PI" then
    local kp = 0.45 * ku
    return { kp = kp, ki = kp / (0.85 * tu), kd = 0.0 }
  elseif type == "PD" then
    local kp = 0.8 * ku
    return { kp = kp, ki = 0.0, kd = kp * tu / 8.0 }
  elseif type == "PID" then
    local kp = 0.6 * ku
    return { kp = kp, ki = kp / (0.5 * tu), kd = kp * 0.125 * tu }
  else
    return nil, "unknown Ziegler-Nichols type: " .. tostring(type)
  end
end

--- Cascade PID: outer loop produces setpoint for inner loop.
-- cascade:update(outer_measurement, inner_measurement) -> output
function M.cascade(outer_opts, inner_opts)
  local outer = M.pid(outer_opts)
  local inner = M.pid(inner_opts)

  local self = {}

  function self:update(measurement, inner_measurement)
    local inner_sp = outer:update(measurement)
    inner:set_setpoint(inner_sp)
    return inner:update(inner_measurement)
  end

  function self:set_setpoint(sp)
    outer:set_setpoint(sp)
  end

  function self:reset()
    outer:reset()
    inner:reset()
  end

  return self
end

--- Rate limiter: limits the rate of change of a signal.
-- opts.rate = max change per time step
-- opts.dt   = time step
function M.rate_limiter(opts)
  opts = opts or {}
  local self = {
    rate    = opts.rate or 1.0,
    dt      = opts.dt or 1.0,
    _output = nil,
  }

  function self:update(target)
    if self._output == nil then
      self._output = target
      return target
    end
    local max_change = self.rate * self.dt
    local delta = target - self._output
    if delta > max_change then
      delta = max_change
    elseif delta < -max_change then
      delta = -max_change
    end
    self._output = self._output + delta
    return self._output
  end

  function self:reset()
    self._output = nil
  end

  return self
end

--- Low-pass filter (exponential moving average).
-- opts.alpha: smoothing factor in (0,1]; lower = more smoothing
-- OR opts.cutoff + opts.dt: alpha = 2π*cutoff*dt / (1 + 2π*cutoff*dt)
function M.low_pass(opts)
  opts = opts or {}
  local alpha
  if opts.alpha then
    alpha = opts.alpha
  elseif opts.cutoff and opts.dt then
    local rc = 2.0 * math.pi * opts.cutoff * opts.dt
    alpha = rc / (1.0 + rc)
  else
    alpha = 0.1
  end

  local self = {
    alpha   = alpha,
    _output = nil,
  }

  function self:update(measurement)
    if self._output == nil then
      self._output = measurement
      return measurement
    end
    self._output = self._output + self.alpha * (measurement - self._output)
    return self._output
  end

  function self:reset()
    self._output = nil
  end

  return self
end

--- Moving average filter over a sliding window.
-- opts.window = number of samples (default 10)
function M.moving_average(opts)
  opts = opts or {}
  local self = {
    window  = opts.window or 10,
    _buf    = {},
    _sum    = 0.0,
    _count  = 0,
    _head   = 1,
  }

  function self:update(value)
    if self._count < self.window then
      self._count = self._count + 1
      self._buf[self._count] = value
      self._sum = self._sum + value
    else
      -- Ring buffer: overwrite oldest
      local old = self._buf[self._head]
      self._sum = self._sum - old + value
      self._buf[self._head] = value
      self._head = self._head % self.window + 1
    end
    return self._sum / self._count
  end

  function self:reset()
    self._buf   = {}
    self._sum   = 0.0
    self._count = 0
    self._head  = 1
  end

  return self
end

--- Deadband: return 0 if |value| < band, else value unchanged.
function M.deadband(value, band)
  if value > -band and value < band then
    return 0.0
  end
  return value
end

return M
