if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: PidOpts = { kp: number | nil, ki: number | nil, kd: number | nil, dt: number | nil, output_min: number | nil, output_max: number | nil, integral_min: number | nil, integral_max: number | nil, setpoint: number | nil }
--:: RateLimiterOpts = { rate: number | nil, dt: number | nil }
--:: LowPassOpts = { alpha: number | nil, cutoff: number | nil, dt: number | nil }
--:: MovingAverageOpts = { window: integer | nil }

--- PID controller
-- opts.kp, opts.ki, opts.kd, opts.dt
-- opts.output_min, opts.output_max (clamping)
-- opts.integral_min, opts.integral_max (anti-windup)
-- opts.setpoint
--: (opts: PidOpts | nil) -> { update: (self: unknown, measurement: number) -> number, set_setpoint: (self: unknown, sp: number) -> nil, reset: (self: unknown) -> nil, state: (self: unknown) -> { error: number, integral: number, derivative: number, output: number } }
function M.pid(opts)
  local o = opts or {} --[[:! PidOpts]]
  local kp           = (o.kp or 1.0) --[[:! number]]
  local ki           = (o.ki or 0.0) --[[:! number]]
  local kd           = (o.kd or 0.0) --[[:! number]]
  local dt           = (o.dt or 1.0) --[[:! number]]
  local output_min   = o.output_min --[[:! number | nil]]
  local output_max   = o.output_max --[[:! number | nil]]
  local integral_min = o.integral_min --[[:! number | nil]]
  local integral_max = o.integral_max --[[:! number | nil]]
  local setpoint     = (o.setpoint or 0.0) --[[:! number]]

  local integral    = 0.0 --: number
  local prev_error  = nil --: number | nil
  local last_output = 0.0 --: number
  local last_error  = 0.0 --: number
  local last_deriv  = 0.0 --: number

  local self = {}

  --: (unknown, measurement: number) -> number
  function self:update(measurement)
    local err = setpoint - measurement
    integral = integral + err * dt

    -- Anti-windup: clamp integral
    if integral_min and integral < integral_min then
      integral = integral_min
    end
    if integral_max and integral > integral_max then
      integral = integral_max
    end

    local deriv = 0.0 --: number
    if prev_error ~= nil then
      deriv = (err - prev_error) / dt
    end
    prev_error = err

    local output = kp * err + ki * integral + kd * deriv

    -- Output clamping
    if output_min and output < output_min then
      output = output_min
    end
    if output_max and output > output_max then
      output = output_max
    end

    last_output = output
    last_error  = err
    last_deriv  = deriv
    return output
  end

  --: (unknown, sp: number) -> nil
  function self:set_setpoint(sp)
    setpoint = sp
  end

  --: (unknown) -> nil
  function self:reset()
    integral    = 0.0
    prev_error  = nil
    last_output = 0.0
    last_error  = 0.0
    last_deriv  = 0.0
  end

  --: (unknown) -> { error: number, integral: number, derivative: number, output: number }
  function self:state()
    return {
      error      = last_error,
      integral   = integral,
      derivative = last_deriv,
      output     = last_output,
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

  --: (unknown, measurement: number, inner_measurement: number) -> number
  function self:update(measurement, inner_measurement)
    local inner_sp = outer:update(measurement)
    inner:set_setpoint(inner_sp)
    return inner:update(inner_measurement)
  end

  --: (unknown, sp: number) -> nil
  function self:set_setpoint(sp)
    outer:set_setpoint(sp)
  end

  --: (unknown) -> nil
  function self:reset()
    outer:reset()
    inner:reset()
  end

  return self
end

--- Rate limiter: limits the rate of change of a signal.
-- opts.rate = max change per time step
-- opts.dt   = time step
--: (opts: RateLimiterOpts | nil) -> { update: (self: unknown, target: number) -> number, reset: (self: unknown) -> nil }
function M.rate_limiter(opts)
  local o = opts or {} --[[:! RateLimiterOpts]]
  local rate   = (o.rate or 1.0) --[[:! number]]
  local dt     = (o.dt or 1.0) --[[:! number]]
  local output = nil --: number | nil

  local self = {}

  --: (unknown, target: number) -> number
  function self:update(target)
    if output == nil then
      output = target
      return target
    end
    local max_change = rate * dt
    local delta = target - output
    if delta > max_change then
      delta = max_change
    elseif delta < -max_change then
      delta = -max_change
    end
    output = output + delta
    return output
  end

  --: (unknown) -> nil
  function self:reset()
    output = nil
  end

  return self
end

--- Low-pass filter (exponential moving average).
-- opts.alpha: smoothing factor in (0,1]; lower = more smoothing
-- OR opts.cutoff + opts.dt: alpha = 2π*cutoff*dt / (1 + 2π*cutoff*dt)
--: (opts: LowPassOpts | nil) -> { alpha: number, update: (self: unknown, measurement: number) -> number, reset: (self: unknown) -> nil }
function M.low_pass(opts)
  local o = opts or {} --[[:! LowPassOpts]]
  local alpha = 0.0 --: number
  if o.alpha then
    alpha = o.alpha --[[:! number]]
  elseif o.cutoff and o.dt then
    local cutoff = o.cutoff --[[:! number]]
    local lp_dt  = o.dt --[[:! number]]
    local rc = 2.0 * math.pi * cutoff * lp_dt
    alpha = rc / (1.0 + rc)
  else
    alpha = 0.1
  end

  local lp_output = nil --: number | nil

  local self = { alpha = alpha }

  --: (unknown, measurement: number) -> number
  function self:update(measurement)
    if lp_output == nil then
      lp_output = measurement
      return measurement
    end
    lp_output = lp_output + alpha * (measurement - lp_output)
    return lp_output
  end

  --: (unknown) -> nil
  function self:reset()
    lp_output = nil
  end

  return self
end

--- Moving average filter over a sliding window.
-- opts.window = number of samples (default 10)
--: (opts: MovingAverageOpts | nil) -> { update: (self: unknown, value: number) -> number, reset: (self: unknown) -> nil }
function M.moving_average(opts)
  local o = opts or {} --[[:! MovingAverageOpts]]
  local window = (o.window or 10) --[[:! integer]]
  local buf    = {} --: { [integer]: number }
  local sum    = 0.0 --: number
  local count  = 0 --: integer
  local head   = 1 --: integer

  local self = {}

  --: (unknown, value: number) -> number
  function self:update(value)
    if count < window then
      count = count + 1
      buf[count] = value
      sum = sum + value
    else
      -- Ring buffer: overwrite oldest
      local old = buf[head]
      sum = sum - old + value
      buf[head] = value
      head = head % window + 1
    end
    return sum / count
  end

  --: (unknown) -> nil
  function self:reset()
    buf   = {}
    sum   = 0.0
    count = 0
    head  = 1
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
