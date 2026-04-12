if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local C = require("lib.pid")

local function approx(a, b, tol)
  tol = tol or 1e-9
  return math.abs(a - b) <= tol
end

T.describe("pid._tier", function()
  T.it("is pure", function()
    T.eq(C._tier, "pure")
  end)
end)

-- ──────────────────────────────────────────
-- PID controller
-- ──────────────────────────────────────────

T.describe("pid: P-only controller", function()
  T.it("output proportional to error", function()
    local p = C.pid({ kp = 2.0, ki = 0.0, kd = 0.0, setpoint = 10.0 })
    local out = p:update(7.0) -- error = 3
    T.ok(approx(out, 6.0))    -- 2*3
  end)

  T.it("zero error → zero output", function()
    local p = C.pid({ kp = 3.0, setpoint = 5.0 })
    T.ok(approx(p:update(5.0), 0.0))
  end)

  T.it("negative error → negative output", function()
    local p = C.pid({ kp = 1.0, setpoint = 0.0 })
    T.ok(p:update(5.0) < 0)
  end)
end)

T.describe("pid: I term accumulation", function()
  T.it("integral grows over time", function()
    local p = C.pid({ kp = 0.0, ki = 1.0, kd = 0.0, dt = 1.0, setpoint = 10.0 })
    p:update(9.0)  -- integral = 1
    local out = p:update(9.0)  -- integral = 2
    T.ok(approx(out, 2.0))
  end)

  T.it("integral sums up correctly over multiple steps", function()
    local p = C.pid({ kp = 0.0, ki = 1.0, kd = 0.0, dt = 1.0, setpoint = 5.0 })
    for _ = 1, 5 do p:update(4.0) end  -- error=1 each step, integral=5
    local s = p:state()
    T.ok(approx(s.integral, 5.0))
    T.ok(approx(s.output, 5.0))
  end)

  T.it("dt scales integral", function()
    local p = C.pid({ kp = 0.0, ki = 1.0, kd = 0.0, dt = 0.5, setpoint = 2.0 })
    p:update(1.0) -- error=1, integral=0.5
    local s = p:state()
    T.ok(approx(s.integral, 0.5))
  end)
end)

T.describe("pid: D term", function()
  T.it("zero on first call (no prev error)", function()
    local p = C.pid({ kp = 0.0, ki = 0.0, kd = 10.0, dt = 1.0, setpoint = 5.0 })
    local out = p:update(4.0)
    T.ok(approx(out, 0.0))
  end)

  T.it("responds to rate of change", function()
    local p = C.pid({ kp = 0.0, ki = 0.0, kd = 2.0, dt = 1.0, setpoint = 10.0 })
    p:update(8.0)  -- error = 2, prev_error set
    local out = p:update(7.0)  -- error = 3, deriv = (3-2)/1 = 1, out = 2*1 = 2
    T.ok(approx(out, 2.0))
  end)

  T.it("negative derivative when error decreasing", function()
    local p = C.pid({ kp = 0.0, ki = 0.0, kd = 1.0, dt = 1.0, setpoint = 10.0 })
    p:update(8.0)  -- error = 2
    local out = p:update(9.0)  -- error = 1, deriv = (1-2)/1 = -1
    T.ok(approx(out, -1.0))
  end)
end)

T.describe("pid: setpoint tracking (simple integrator plant)", function()
  -- Plant: x[k+1] = x[k] + u[k]*dt
  -- Pure I controller should drive x to setpoint
  T.it("converges toward setpoint with PI controller", function()
    local p = C.pid({ kp = 0.5, ki = 0.1, kd = 0.0, dt = 0.1, setpoint = 1.0 })
    local x = 0.0
    for _ = 1, 200 do
      local u = p:update(x)
      x = x + u * 0.1
    end
    T.ok(math.abs(x - 1.0) < 0.05, "should converge close to setpoint, got " .. x)
  end)
end)

T.describe("pid: anti-windup (integral clamping)", function()
  T.it("integral clamped at max", function()
    local p = C.pid({
      kp = 0.0, ki = 1.0, kd = 0.0, dt = 1.0,
      setpoint = 10.0,
      integral_max = 3.0,
    })
    for _ = 1, 10 do p:update(0.0) end
    local s = p:state()
    T.ok(approx(s.integral, 3.0))
  end)

  T.it("integral clamped at min", function()
    local p = C.pid({
      kp = 0.0, ki = 1.0, kd = 0.0, dt = 1.0,
      setpoint = 0.0,
      integral_min = -3.0,
    })
    for _ = 1, 10 do p:update(10.0) end
    local s = p:state()
    T.ok(approx(s.integral, -3.0))
  end)
end)

T.describe("pid: output clamping", function()
  T.it("output clamped at max", function()
    local p = C.pid({ kp = 10.0, setpoint = 5.0, output_max = 2.0 })
    local out = p:update(0.0)  -- unclamped = 50
    T.ok(approx(out, 2.0))
  end)

  T.it("output clamped at min", function()
    local p = C.pid({ kp = 10.0, setpoint = 0.0, output_min = -2.0 })
    local out = p:update(5.0)  -- unclamped = -50
    T.ok(approx(out, -2.0))
  end)

  T.it("output unclamped when within bounds", function()
    local p = C.pid({ kp = 1.0, setpoint = 3.0, output_min = -10.0, output_max = 10.0 })
    local out = p:update(0.0)
    T.ok(approx(out, 3.0))
  end)
end)

T.describe("pid: reset", function()
  T.it("clears integral", function()
    local p = C.pid({ kp = 0.0, ki = 1.0, dt = 1.0, setpoint = 5.0 })
    for _ = 1, 5 do p:update(0.0) end
    p:reset()
    local s = p:state()
    T.ok(approx(s.integral, 0.0))
  end)

  T.it("first D after reset has zero derivative", function()
    local p = C.pid({ kp = 0.0, ki = 0.0, kd = 10.0, dt = 1.0, setpoint = 5.0 })
    p:update(0.0)  -- sets prev_error
    p:reset()
    local out = p:update(0.0)  -- no prev_error after reset → deriv = 0
    T.ok(approx(out, 0.0))
  end)
end)

T.describe("pid: state()", function()
  T.it("returns correct fields", function()
    local p = C.pid({ kp = 1.0, ki = 1.0, kd = 0.0, dt = 1.0, setpoint = 3.0 })
    p:update(1.0)
    local s = p:state()
    T.ok(s.error ~= nil)
    T.ok(s.integral ~= nil)
    T.ok(s.derivative ~= nil)
    T.ok(s.output ~= nil)
    T.ok(approx(s.error, 2.0))
    T.ok(approx(s.integral, 2.0))
    T.ok(approx(s.output, 4.0))  -- kp*2 + ki*2 = 4
  end)

  T.it("state output matches return from update", function()
    local p = C.pid({ kp = 2.0, setpoint = 10.0 })
    local out = p:update(6.0)
    T.ok(approx(p:state().output, out))
  end)
end)

T.describe("pid: set_setpoint", function()
  T.it("changes target", function()
    local p = C.pid({ kp = 1.0, setpoint = 5.0 })
    p:set_setpoint(10.0)
    local out = p:update(0.0)  -- error = 10
    T.ok(approx(out, 10.0))
  end)
end)

-- ──────────────────────────────────────────
-- Ziegler-Nichols
-- ──────────────────────────────────────────

T.describe("ziegler_nichols: P", function()
  T.it("kp = 0.5*Ku", function()
    local r = C.ziegler_nichols(4.0, 2.0, "P")
    T.ok(approx(r.kp, 2.0))
    T.ok(approx(r.ki, 0.0))
    T.ok(approx(r.kd, 0.0))
  end)
end)

T.describe("ziegler_nichols: PI", function()
  T.it("kp = 0.45*Ku, ki = kp/(0.85*Tu)", function()
    local ku, tu = 4.0, 2.0
    local r = C.ziegler_nichols(ku, tu, "PI")
    T.ok(approx(r.kp, 0.45 * ku))
    T.ok(approx(r.ki, 0.45 * ku / (0.85 * tu)))
    T.ok(approx(r.kd, 0.0))
  end)
end)

T.describe("ziegler_nichols: PD", function()
  T.it("kp = 0.8*Ku, kd = kp*Tu/8", function()
    local ku, tu = 4.0, 2.0
    local r = C.ziegler_nichols(ku, tu, "PD")
    T.ok(approx(r.kp, 0.8 * ku))
    T.ok(approx(r.kd, 0.8 * ku * tu / 8.0))
    T.ok(approx(r.ki, 0.0))
  end)
end)

T.describe("ziegler_nichols: PID", function()
  T.it("kp=0.6*Ku, ki=kp/(0.5*Tu), kd=kp*0.125*Tu", function()
    local ku, tu = 4.0, 2.0
    local r = C.ziegler_nichols(ku, tu, "PID")
    T.ok(approx(r.kp, 0.6 * ku))
    T.ok(approx(r.ki, 0.6 * ku / (0.5 * tu)))
    T.ok(approx(r.kd, 0.6 * ku * 0.125 * tu))
  end)
end)

T.describe("ziegler_nichols: unknown type", function()
  T.it("returns nil, errmsg", function()
    local r, err = C.ziegler_nichols(1.0, 1.0, "XX")
    T.eq(r, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ──────────────────────────────────────────
-- Cascade PID
-- ──────────────────────────────────────────

T.describe("cascade: basic wiring", function()
  T.it("outer output feeds inner setpoint", function()
    -- outer: kp=1, setpoint=5; outer measurement=3 → outer output=2
    -- inner: kp=1, setpoint=2 (from outer); inner measurement=2 → inner output=0
    local cas = C.cascade(
      { kp = 1.0, ki = 0.0, kd = 0.0, setpoint = 5.0 },
      { kp = 1.0, ki = 0.0, kd = 0.0 }
    )
    local out = cas:update(3.0, 2.0)
    T.ok(approx(out, 0.0))
  end)

  T.it("set_setpoint changes outer target", function()
    local cas = C.cascade(
      { kp = 1.0, setpoint = 0.0 },
      { kp = 1.0 }
    )
    cas:set_setpoint(10.0)
    -- outer measurement=10 → outer error=0 → inner setpoint=0
    -- inner measurement=0 → inner error=0 → output=0
    local out = cas:update(10.0, 0.0)
    T.ok(approx(out, 0.0))
  end)

  T.it("converges over iterations", function()
    local cas = C.cascade(
      { kp = 0.5, ki = 0.1, kd = 0.0, dt = 0.1, setpoint = 1.0 },
      { kp = 0.5, ki = 0.1, kd = 0.0, dt = 0.1 }
    )
    local x, y = 0.0, 0.0
    for _ = 1, 300 do
      local u = cas:update(x, y)
      y = y + u * 0.1
      x = x + y * 0.1
    end
    T.ok(math.abs(x - 1.0) < 0.2, "cascade should converge, x=" .. x)
  end)
end)

-- ──────────────────────────────────────────
-- Rate limiter
-- ──────────────────────────────────────────

T.describe("rate_limiter", function()
  T.it("first call passes through unchanged", function()
    local rl = C.rate_limiter({ rate = 1.0, dt = 1.0 })
    T.ok(approx(rl:update(5.0), 5.0))
  end)

  T.it("limits upward change", function()
    local rl = C.rate_limiter({ rate = 2.0, dt = 1.0 })
    rl:update(0.0)
    local out = rl:update(10.0)
    T.ok(approx(out, 2.0))
  end)

  T.it("limits downward change", function()
    local rl = C.rate_limiter({ rate = 3.0, dt = 1.0 })
    rl:update(10.0)
    local out = rl:update(0.0)
    T.ok(approx(out, 7.0))
  end)

  T.it("exact change within rate passes through", function()
    local rl = C.rate_limiter({ rate = 5.0, dt = 1.0 })
    rl:update(0.0)
    local out = rl:update(3.0)  -- 3 < 5 max
    T.ok(approx(out, 3.0))
  end)

  T.it("rate scales with dt", function()
    local rl = C.rate_limiter({ rate = 10.0, dt = 0.1 })  -- max change = 1.0/step
    rl:update(0.0)
    local out = rl:update(5.0)
    T.ok(approx(out, 1.0))
  end)

  T.it("reset allows re-initialization", function()
    local rl = C.rate_limiter({ rate = 1.0, dt = 1.0 })
    rl:update(5.0)
    rl:reset()
    local out = rl:update(99.0)  -- first call after reset passes through
    T.ok(approx(out, 99.0))
  end)
end)

-- ──────────────────────────────────────────
-- Low-pass filter
-- ──────────────────────────────────────────

T.describe("low_pass", function()
  T.it("first call passes through unchanged", function()
    local lp = C.low_pass({ alpha = 0.1 })
    T.ok(approx(lp:update(7.0), 7.0))
  end)

  T.it("alpha=1 is pass-through (no filtering)", function()
    local lp = C.low_pass({ alpha = 1.0 })
    lp:update(0.0)
    T.ok(approx(lp:update(5.0), 5.0))
    T.ok(approx(lp:update(3.0), 3.0))
  end)

  T.it("alpha=0.1 smooths output", function()
    local lp = C.low_pass({ alpha = 0.1 })
    lp:update(0.0)
    local out = lp:update(10.0)  -- 0 + 0.1*(10-0) = 1.0
    T.ok(approx(out, 1.0))
  end)

  T.it("output approaches input over many steps", function()
    local lp = C.low_pass({ alpha = 0.3 })
    local v = 0.0
    for _ = 1, 50 do v = lp:update(1.0) end
    T.ok(math.abs(v - 1.0) < 0.01, "should converge close to 1.0, got " .. v)
  end)

  T.it("cutoff + dt computes alpha correctly", function()
    local cutoff, dt = 1.0, 0.1
    local rc = 2.0 * math.pi * cutoff * dt
    local expected_alpha = rc / (1.0 + rc)
    local lp = C.low_pass({ cutoff = cutoff, dt = dt })
    T.ok(approx(lp.alpha, expected_alpha))
  end)

  T.it("reset clears state", function()
    local lp = C.low_pass({ alpha = 0.5 })
    lp:update(100.0)
    lp:reset()
    local out = lp:update(5.0)  -- after reset, first call passes through
    T.ok(approx(out, 5.0))
  end)
end)

-- ──────────────────────────────────────────
-- Moving average
-- ──────────────────────────────────────────

T.describe("moving_average", function()
  T.it("single value returns that value", function()
    local ma = C.moving_average({ window = 5 })
    T.ok(approx(ma:update(3.0), 3.0))
  end)

  T.it("average of partial window", function()
    local ma = C.moving_average({ window = 4 })
    ma:update(2.0)
    local out = ma:update(4.0)  -- avg of (2,4) = 3
    T.ok(approx(out, 3.0))
  end)

  T.it("correct full-window average", function()
    local ma = C.moving_average({ window = 3 })
    ma:update(1.0)
    ma:update(2.0)
    local out = ma:update(3.0)  -- avg = 2
    T.ok(approx(out, 2.0))
  end)

  T.it("slides correctly when window full", function()
    local ma = C.moving_average({ window = 3 })
    ma:update(1.0)
    ma:update(2.0)
    ma:update(3.0)
    local out = ma:update(4.0)  -- drops 1, window=(2,3,4), avg=3
    T.ok(approx(out, 3.0))
  end)

  T.it("uniform input → same value", function()
    local ma = C.moving_average({ window = 5 })
    local out
    for _ = 1, 10 do out = ma:update(7.0) end
    T.ok(approx(out, 7.0))
  end)

  T.it("reset clears buffer", function()
    local ma = C.moving_average({ window = 3 })
    for _ = 1, 3 do ma:update(9.0) end
    ma:reset()
    local out = ma:update(1.0)
    T.ok(approx(out, 1.0))
  end)
end)

-- ──────────────────────────────────────────
-- Deadband
-- ──────────────────────────────────────────

T.describe("deadband", function()
  T.it("zero is within band", function()
    T.ok(approx(C.deadband(0.0, 0.5), 0.0))
  end)

  T.it("value inside band returns 0", function()
    T.ok(approx(C.deadband(0.3, 0.5), 0.0))
    T.ok(approx(C.deadband(-0.3, 0.5), 0.0))
  end)

  T.it("value exactly at band edge passes through", function()
    -- band exclusive: |value| < band → 0; |value| >= band → value
    T.ok(approx(C.deadband(0.5, 0.5), 0.5))
    T.ok(approx(C.deadband(-0.5, 0.5), -0.5))
  end)

  T.it("value outside band passes through unchanged", function()
    T.ok(approx(C.deadband(2.0, 0.5), 2.0))
    T.ok(approx(C.deadband(-3.0, 0.5), -3.0))
  end)

  T.it("zero band passes everything", function()
    T.ok(approx(C.deadband(0.001, 0.0), 0.001))
  end)
end)
