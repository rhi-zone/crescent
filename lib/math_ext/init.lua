if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Extended math utilities beyond Lua's built-in math.*.
local M = {}

M._tier = "pure"

local floor = math.floor
local ceil  = math.ceil
local abs   = math.abs
local sqrt  = math.sqrt
local sin   = math.sin
local cos   = math.cos
local atan2 = math.atan2
local pi    = math.pi
local huge  = math.huge

-- ---------------------------------------------------------------------------
-- Number utilities
-- ---------------------------------------------------------------------------

--- Clamp x to [min, max].
function M.clamp(x, mn, mx)
  if x < mn then return mn end
  if x > mx then return mx end
  return x
end

--- Linear interpolation: a + t*(b-a).
function M.lerp(a, b, t)
  return a + t * (b - a)
end

--- Inverse lerp: (v-a)/(b-a). Returns nil,"division by zero" when a==b.
function M.lerp_inv(a, b, v)
  if a == b then return nil, "division by zero" end
  return (v - a) / (b - a)
end

--- Remap x from [a1,b1] to [a2,b2].
function M.remap(x, a1, b1, a2, b2)
  if a1 == b1 then return nil, "division by zero" end
  return a2 + (x - a1) * (b2 - a2) / (b1 - a1)
end

--- Smooth Hermite interpolation over [edge0, edge1].
function M.smoothstep(edge0, edge1, x)
  local t = M.clamp((x - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
end

--- Ken Perlin's smoother step.
function M.smootherstep(e0, e1, x)
  local t = M.clamp((x - e0) / (e1 - e0), 0, 1)
  return t * t * t * (t * (t * 6 - 15) + 10)
end

--- Returns -1, 0, or 1.
function M.sign(x)
  if x > 0 then return 1 end
  if x < 0 then return -1 end
  return 0
end

--- Round to n decimal places (default 0).
function M.round(x, decimals)
  local m = 10 ^ (decimals or 0)
  return floor(x * m + 0.5) / m
end

--- Round x to nearest multiple.
function M.round_to(x, multiple)
  if multiple == 0 then return nil, "multiple must not be zero" end
  return floor(x / multiple + 0.5) * multiple
end

--- Floor x down to multiple.
function M.floor_to(x, multiple)
  if multiple == 0 then return nil, "multiple must not be zero" end
  return floor(x / multiple) * multiple
end

--- Ceil x up to multiple.
function M.ceil_to(x, multiple)
  if multiple == 0 then return nil, "multiple must not be zero" end
  return ceil(x / multiple) * multiple
end

--- Truncate toward zero.
function M.trunc(x)
  if x >= 0 then return floor(x) else return ceil(x) end
end

--- Fractional part: x - floor(x).
function M.frac(x)
  return x - floor(x)
end

--- Wrap x into [min, max) cyclically.
function M.wrap(x, mn, mx)
  local range = mx - mn
  if range == 0 then return mn end
  return mn + (x - mn) % range
end

--- Snap to nearest step.
function M.snap(x, step)
  if step == 0 then return nil, "step must not be zero" end
  return floor(x / step + 0.5) * step
end

--- Approximately equal: |a-b| < eps (default 1e-9).
function M.approx_eq(a, b, eps)
  return abs(a - b) < (eps or 1e-9)
end

-- ---------------------------------------------------------------------------
-- Number theory
-- ---------------------------------------------------------------------------

--- Greatest common divisor (Euclidean).
function M.gcd(a, b)
  a = abs(floor(a)); b = abs(floor(b))
  while b ~= 0 do a, b = b, a % b end
  return a
end

--- Least common multiple.
function M.lcm(a, b)
  if a == 0 or b == 0 then return 0 end
  return abs(a * b) / M.gcd(a, b)
end

--- Trial division primality test.
function M.is_prime(n)
  n = floor(n)
  if n < 2 then return false end
  if n == 2 then return true end
  if n % 2 == 0 then return false end
  local i = 3
  while i * i <= n do
    if n % i == 0 then return false end
    i = i + 2
  end
  return true
end

--- Smallest prime strictly greater than n.
function M.next_prime(n)
  local k = floor(n) + 1
  if k <= 2 then return 2 end
  if k % 2 == 0 then k = k + 1 end
  while not M.is_prime(k) do k = k + 2 end
  return k
end

--- Array of primes ≤ n (Sieve of Eratosthenes).
function M.primes(n)
  n = floor(n)
  if n < 2 then return {} end
  local sieve = {} --: { [integer]: boolean }
  for i = 2, n do sieve[i] = true end
  local i = 2
  while i * i <= n do
    if sieve[i] then
      local j = i * i
      while j <= n do sieve[j] = false; j = j + i end
    end
    i = i + 1
  end
  local result = {}
  for k = 2, n do
    if sieve[k] then result[#result + 1] = k end
  end
  return result
end

--- Prime factorization as {prime → exponent} map.
function M.factorize(n)
  n = floor(abs(n))
  local factors = {}
  if n <= 1 then return factors end
  local d = 2
  while d * d <= n do
    while n % d == 0 do
      factors[d] = (factors[d] or 0) + 1
      n = n / d
    end
    d = d + 1
  end
  if n > 1 then factors[n] = (factors[n] or 0) + 1 end
  return factors
end

local bit_band = bit and bit.band

--- True if n is a positive power of 2.
function M.is_power_of_two(n)
  n = floor(n)
  if n <= 0 then return false end
  if bit_band then
    return bit_band(n, n - 1) == 0
  end
  -- fallback: check that n has exactly one factor of 2 dividing it cleanly
  local k = n
  while k > 1 do
    if k % 2 ~= 0 then return false end
    k = floor(k / 2)
  end
  return true
end

--- Smallest power of 2 ≥ n.
function M.next_power_of_two(n)
  n = floor(n)
  if n <= 1 then return 1 end
  local p = 1
  while p < n do p = p * 2 end
  return p
end

--- Array of digits in given base (default 10), LSB first.
function M.digits(n, base)
  base = base or 10
  n = floor(abs(n))
  if n == 0 then return {0} end
  local result = {}
  while n > 0 do
    result[#result + 1] = n % base
    n = floor(n / base)
  end
  return result
end

--- Reconstruct number from digit array (LSB first).
function M.from_digits(arr, base)
  base = base or 10
  local result = 0
  local mult = 1
  for i = 1, #arr do
    result = result + arr[i] * mult
    mult = mult * base
  end
  return result
end

--- Sum of digits in given base (default 10).
function M.sum_digits(n, base)
  local d = M.digits(n, base)
  local s = 0
  for i = 1, #d do s = s + d[i] end
  return s
end

--- Number of digits in given base (default 10).
function M.digit_count(n, base)
  return #M.digits(n, base)
end

-- ---------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------

--- Arithmetic mean.
function M.mean(arr)
  if #arr == 0 then return nil, "empty array" end
  local s = 0
  for i = 1, #arr do s = s + arr[i] end
  return s / #arr
end

--- Median value.
function M.median(arr)
  if #arr == 0 then return nil, "empty array" end
  local sorted = {}
  for i = 1, #arr do sorted[i] = arr[i] end
  table.sort(sorted)
  local n = #sorted
  local mid = floor(n / 2)
  if n % 2 == 1 then
    return sorted[mid + 1]
  else
    return (sorted[mid] + sorted[mid + 1]) / 2
  end
end

--- Most frequent value(s) — returns array (may have multiple if tied).
function M.mode(arr)
  if #arr == 0 then return nil, "empty array" end
  local counts = {}
  local max_count = 0
  for i = 1, #arr do
    local v = arr[i]
    counts[v] = (counts[v] or 0) + 1
    if counts[v] > max_count then max_count = counts[v] end
  end
  local result = {}
  for v, c in pairs(counts) do
    if c == max_count then result[#result + 1] = v end
  end
  table.sort(result)
  return result
end

--- Population variance.
function M.variance(arr)
  if #arr == 0 then return nil, "empty array" end
  local m = M.mean(arr)
  local s = 0
  for i = 1, #arr do
    local d = arr[i] - m
    s = s + d * d
  end
  return s / #arr
end

--- Population standard deviation.
function M.stddev(arr)
  local v, err = M.variance(arr)
  if not v then return nil, err end
  return sqrt(v)
end

--- p-th percentile (0-100), linear interpolation.
function M.percentile(arr, p)
  if #arr == 0 then return nil, "empty array" end
  local sorted = {}
  for i = 1, #arr do sorted[i] = arr[i] end
  table.sort(sorted)
  local idx = p / 100 * (#sorted - 1)
  local lo = floor(idx)
  local frac = idx - lo
  if lo + 2 > #sorted then return sorted[#sorted] end
  return sorted[lo + 1] + frac * (sorted[lo + 2] - sorted[lo + 1])
end

--- Bin counts for histogram.
function M.histogram(arr, bins)
  if #arr == 0 then return nil, "empty array" end
  bins = bins or 10
  local mn, mx = arr[1], arr[1]
  for i = 2, #arr do
    if arr[i] < mn then mn = arr[i] end
    if arr[i] > mx then mx = arr[i] end
  end
  local result = {} --: { [integer]: integer }
  for i = 1, bins do result[i] = 0 end
  local range = mx - mn
  for i = 1, #arr do
    local bin
    if range == 0 then
      bin = 1
    else
      bin = floor((arr[i] - mn) / range * bins)
      if bin >= bins then bin = bins - 1 end
      bin = bin + 1
    end
    result[bin] = result[bin] + 1
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Easing functions (t in [0,1])
-- ---------------------------------------------------------------------------

function M.ease_in_quad(t)  return t * t end
function M.ease_out_quad(t) local u = 1 - t; return 1 - u * u end
function M.ease_in_out_quad(t)
  if t < 0.5 then return 2 * t * t else local u = -2*t+2; return 1 - u*u/2 end
end

function M.ease_in_cubic(t)  return t * t * t end
function M.ease_out_cubic(t) local u = 1 - t; return 1 - u*u*u end
function M.ease_in_out_cubic(t)
  if t < 0.5 then return 4*t*t*t else local u = -2*t+2; return 1 - u*u*u/2 end
end

function M.ease_in_sine(t)     return 1 - cos(t * pi / 2) end
function M.ease_out_sine(t)    return sin(t * pi / 2) end
function M.ease_in_out_sine(t) return -(cos(pi * t) - 1) / 2 end

-- ---------------------------------------------------------------------------
-- Geometry helpers
-- ---------------------------------------------------------------------------

--- Degrees to radians.
function M.deg_to_rad(d) return d * pi / 180 end

--- Radians to degrees.
function M.rad_to_deg(r) return r * 180 / pi end

--- Polar (r, theta) to Cartesian (x, y).
function M.polar_to_cart(r, theta)
  return r * cos(theta), r * sin(theta)
end

--- Cartesian (x, y) to polar (r, theta).
function M.cart_to_polar(x, y)
  return sqrt(x*x + y*y), atan2(y, x)
end

--- Euclidean distance.
function M.distance(x1, y1, x2, y2)
  local dx = x2 - x1; local dy = y2 - y1
  return sqrt(dx*dx + dy*dy)
end

--- Squared Euclidean distance (no sqrt).
function M.distance_sq(x1, y1, x2, y2)
  local dx = x2 - x1; local dy = y2 - y1
  return dx*dx + dy*dy
end

--- Angle between two 2D vectors (in radians).
function M.angle_between(ax, ay, bx, by)
  return atan2(ax*by - ay*bx, ax*bx + ay*by)
end

--- 2D cross product (scalar).
function M.cross2d(ax, ay, bx, by) return ax*by - ay*bx end

--- 2D dot product.
function M.dot2d(ax, ay, bx, by) return ax*bx + ay*by end

return M
