if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Easing functions for animation (Robert Penner style).
-- Each function maps t ∈ [0, 1] → progress value (usually in [0, 1]).
-- Three variants per family: in, out, in_out.
-- Pure Lua, no dependencies.

local M = {}

M._tier = "pure"

local sin  = math.sin
local cos  = math.cos
local sqrt = math.sqrt
local pi   = math.pi
local pow  = math.pow or function(b, e) return b ^ e end

-- ---------------------------------------------------------------------------
-- linear
-- ---------------------------------------------------------------------------

--: (number) -> number
M.linear = function(t) return t end

-- ---------------------------------------------------------------------------
-- quad
-- ---------------------------------------------------------------------------

--: (number) -> number
M.in_quad = function(t) return t * t end

--: (number) -> number
M.out_quad = function(t)
  local u = 1 - t
  return 1 - u * u
end

--: (number) -> number
M.in_out_quad = function(t)
  if t < 0.5 then
    return 2 * t * t
  end
  local u = -2 * t + 2
  return 1 - u * u / 2
end

-- ---------------------------------------------------------------------------
-- cubic
-- ---------------------------------------------------------------------------

--: (number) -> number
M.in_cubic = function(t) return t * t * t end

--: (number) -> number
M.out_cubic = function(t)
  local u = 1 - t
  return 1 - u * u * u
end

--: (number) -> number
M.in_out_cubic = function(t)
  if t < 0.5 then
    return 4 * t * t * t
  end
  local u = -2 * t + 2
  return 1 - u * u * u / 2
end

-- ---------------------------------------------------------------------------
-- quart
-- ---------------------------------------------------------------------------

--: (number) -> number
M.in_quart = function(t) return t * t * t * t end

--: (number) -> number
M.out_quart = function(t)
  local u = 1 - t
  return 1 - u * u * u * u
end

--: (number) -> number
M.in_out_quart = function(t)
  if t < 0.5 then
    return 8 * t * t * t * t
  end
  local u = -2 * t + 2
  return 1 - u * u * u * u / 2
end

-- ---------------------------------------------------------------------------
-- quint
-- ---------------------------------------------------------------------------

--: (number) -> number
M.in_quint = function(t) return t * t * t * t * t end

--: (number) -> number
M.out_quint = function(t)
  local u = 1 - t
  return 1 - u * u * u * u * u
end

--: (number) -> number
M.in_out_quint = function(t)
  if t < 0.5 then
    return 16 * t * t * t * t * t
  end
  local u = -2 * t + 2
  return 1 - u * u * u * u * u / 2
end

-- ---------------------------------------------------------------------------
-- sine
-- ---------------------------------------------------------------------------

--: (number) -> number
M.in_sine = function(t)
  return 1 - cos(t * pi / 2)
end

--: (number) -> number
M.out_sine = function(t)
  return sin(t * pi / 2)
end

--: (number) -> number
M.in_out_sine = function(t)
  return -(cos(pi * t) - 1) / 2
end

-- ---------------------------------------------------------------------------
-- expo
-- ---------------------------------------------------------------------------

--: (number) -> number
M.in_expo = function(t)
  if t == 0 then return 0 end
  return 2 ^ (10 * t - 10)
end

--: (number) -> number
M.out_expo = function(t)
  if t == 1 then return 1 end
  return 1 - 2 ^ (-10 * t)
end

--: (number) -> number
M.in_out_expo = function(t)
  if t == 0 then return 0 end
  if t == 1 then return 1 end
  if t < 0.5 then
    return 2 ^ (20 * t - 10) / 2
  end
  return (2 - 2 ^ (-20 * t + 10)) / 2
end

-- ---------------------------------------------------------------------------
-- circ
-- ---------------------------------------------------------------------------

--: (number) -> number
M.in_circ = function(t)
  return 1 - sqrt(1 - t * t)
end

--: (number) -> number
M.out_circ = function(t)
  local u = t - 1
  return sqrt(1 - u * u)
end

--: (number) -> number
M.in_out_circ = function(t)
  if t < 0.5 then
    local u = 2 * t
    return (1 - sqrt(1 - u * u)) / 2
  end
  local u = -2 * t + 2
  return (sqrt(1 - u * u) + 1) / 2
end

-- ---------------------------------------------------------------------------
-- back  (s = 1.70158 standard overshoot; s2 = 2.5949095 for in_out)
-- ---------------------------------------------------------------------------

local BACK_S  = 1.70158
local BACK_S2 = 2.5949095

--: (number) -> number
M.in_back = function(t)
  return t * t * ((BACK_S + 1) * t - BACK_S)
end

--: (number) -> number
M.out_back = function(t)
  local u = t - 1
  return 1 - u * u * ((BACK_S + 1) * (-u) - BACK_S)
end

--: (number) -> number
M.in_out_back = function(t)
  if t < 0.5 then
    local u = 2 * t
    return u * u * ((BACK_S2 + 1) * u - BACK_S2) / 2
  end
  local u = 2 * t - 2
  return (u * u * ((BACK_S2 + 1) * u + BACK_S2) + 2) / 2
end

-- ---------------------------------------------------------------------------
-- elastic
-- ---------------------------------------------------------------------------

local ELASTIC_P_IN     = 0.3
local ELASTIC_P_IN_OUT = 0.45

--: (number) -> number
M.in_elastic = function(t)
  if t == 0 then return 0 end
  if t == 1 then return 1 end
  return -(2 ^ (10 * t - 10)) * sin((10 * t - 10.75) * 2 * pi / ELASTIC_P_IN)
end

--: (number) -> number
M.out_elastic = function(t)
  if t == 0 then return 0 end
  if t == 1 then return 1 end
  return (2 ^ (-10 * t)) * sin((10 * t - 0.75) * 2 * pi / ELASTIC_P_IN) + 1
end

--: (number) -> number
M.in_out_elastic = function(t)
  if t == 0 then return 0 end
  if t == 1 then return 1 end
  if t < 0.5 then
    return -(2 ^ (20 * t - 10) * sin((20 * t - 11.125) * 2 * pi / ELASTIC_P_IN_OUT)) / 2
  end
  return (2 ^ (-20 * t + 10) * sin((20 * t - 11.125) * 2 * pi / ELASTIC_P_IN_OUT)) / 2 + 1
end

-- ---------------------------------------------------------------------------
-- bounce
-- ---------------------------------------------------------------------------

local BOUNCE_N1 = 7.5625
local BOUNCE_D1 = 2.75

--: (number) -> number
local function bounce_out(t)
  if t < 1 / BOUNCE_D1 then
    return BOUNCE_N1 * t * t
  elseif t < 2 / BOUNCE_D1 then
    t = t - 1.5 / BOUNCE_D1
    return BOUNCE_N1 * t * t + 0.75
  elseif t < 2.5 / BOUNCE_D1 then
    t = t - 2.25 / BOUNCE_D1
    return BOUNCE_N1 * t * t + 0.9375
  else
    t = t - 2.625 / BOUNCE_D1
    return BOUNCE_N1 * t * t + 0.984375
  end
end

--: (number) -> number
M.in_bounce = function(t)
  return 1 - bounce_out(1 - t)
end

--: (number) -> number
M.out_bounce = bounce_out

--: (number) -> number
M.in_out_bounce = function(t)
  if t < 0.5 then
    return (1 - bounce_out(1 - 2 * t)) / 2
  end
  return (1 + bounce_out(2 * t - 1)) / 2
end

-- ---------------------------------------------------------------------------
-- Registry helpers
-- ---------------------------------------------------------------------------

-- Ordered list built once at module load so names() is deterministic.
local _names = {
  "linear",
  "in_quad",    "out_quad",    "in_out_quad",
  "in_cubic",   "out_cubic",   "in_out_cubic",
  "in_quart",   "out_quart",   "in_out_quart",
  "in_quint",   "out_quint",   "in_out_quint",
  "in_sine",    "out_sine",    "in_out_sine",
  "in_expo",    "out_expo",    "in_out_expo",
  "in_circ",    "out_circ",    "in_out_circ",
  "in_back",    "out_back",    "in_out_back",
  "in_elastic", "out_elastic", "in_out_elastic",
  "in_bounce",  "out_bounce",  "in_out_bounce",
}

-- Returns the easing function for a given name, or nil.
--: (string) -> (((number) -> number) | nil)
M.get = function(name)
  return M[name] --[[:! ((number) -> number) | nil]]
end

-- Returns an array of all easing function names.
--: () -> { [number]: string }
M.names = function()
  local result = {}
  for i, name in ipairs(_names) do
    result[i] = name
  end
  return result
end

-- Interpolates between `from` and `to` using easing.
-- `ease_fn` may be a function or a name string (default "linear").
--: (number, number, number, (((number) -> number) | string | nil)) -> number
M.interpolate = function(t, from, to, ease_fn)
  local fn --: ((number) -> number) | nil
  if type(ease_fn) == "function" then
    fn = ease_fn --[[:! (number) -> number]]
  elseif type(ease_fn) == "string" then
    fn = M[ease_fn] --[[:! ((number) -> number) | nil]]
  else
    fn = M.linear
  end
  return from + (to - from) * (fn or M.linear)(t)
end

return M
