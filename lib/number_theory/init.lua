if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Modular multiplication that avoids double-precision overflow for n < 2^26.
-- For larger values we rely on the fact that LuaJIT doubles have 53-bit mantissa
-- and use a double-precision multiply directly (exact up to 2^53).
--: (a: number, b: number, m: number) -> number
local function mulmod(a, b, m)
  return (a * b) % m
end

-- Fast modular exponentiation: base^exp mod m
--: (base: number, exp: number, mod: number) -> number
function M.mod_pow(base, exp, mod)
  if mod == 1 then return 0 end
  local result = 1 --[[: number ]]
  base = base % mod
  while exp > 0 do
    if exp % 2 == 1 then
      result = mulmod(result, base, mod)
    end
    base = mulmod(base, base, mod)
    exp = math.floor(exp / 2)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Miller-Rabin primality test
-- ---------------------------------------------------------------------------

-- Write n-1 as 2^r * d, return r, d
--: (n: number) -> (number, number)
local function factor_out_twos(n)
  local r, d = 0, n
  while d % 2 == 0 do
    r = r + 1
    d = math.floor(d / 2)
  end
  return r, d
end

-- Single Miller-Rabin round with witness a for n
--: (n: number, a: number, r: number, d: number) -> boolean
local function miller_rabin_witness(n, a, r, d)
  local x = M.mod_pow(a, d, n)
  if x == 1 or x == n - 1 then return true end
  for _ = 1, r - 1 do
    x = mulmod(x, x, n)
    if x == n - 1 then return true end
  end
  return false
end

--- Probabilistic primality test with given witnesses.
-- Deterministic for n < 3,215,031,751 with witnesses {2,3,5,7}.
-- Deterministic for n < ~3.3e24 with the full 12-witness set.
--: (n: number, witnesses: number[]) -> boolean
function M.miller_rabin(n, witnesses)
  if n < 2 then return false end
  if n == 2 or n == 3 then return true end
  if n % 2 == 0 then return false end
  local r, d = factor_out_twos(n - 1)
  for _, a in ipairs(witnesses) do
    if a >= n then
      -- skip witness >= n (n is very small)
    elseif not miller_rabin_witness(n, a, r, d) then
      return false
    end
  end
  return true
end

local SMALL_WITNESSES = {2, 3, 5, 7}
local LARGE_WITNESSES = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37}

--- Primality test using trial division for small n, Miller-Rabin otherwise.
--: (n: number) -> boolean
function M.is_prime(n)
  n = math.floor(n)
  if n < 2 then return false end
  if n == 2 or n == 3 or n == 5 or n == 7 then return true end
  if n % 2 == 0 or n % 3 == 0 or n % 5 == 0 then return false end
  if n < 49 then return true end
  -- For small n use the 4-witness set (deterministic up to ~3.2e9)
  if n < 3215031751 then
    return M.miller_rabin(n, SMALL_WITNESSES)
  end
  return M.miller_rabin(n, LARGE_WITNESSES)
end

--- Deterministic trial division primality test.
--: (n: number) -> boolean
function M.is_prime_trial(n)
  n = math.floor(n)
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
--: (n: number) -> number
function M.next_prime(n)
  n = math.floor(n)
  if n < 2 then return 2 end
  local c = n + 1
  if c % 2 == 0 then c = c + 1 end
  while not M.is_prime(c) do
    c = c + 2
  end
  return c
end

--- Largest prime strictly less than n. Returns nil if n <= 2.
--: (n: number) -> (number | nil)
function M.prev_prime(n)
  n = math.floor(n)
  if n <= 2 then return nil end
  if n == 3 then return 2 end
  local c = n - 1
  if c % 2 == 0 then c = c - 1 end
  while c > 2 and not M.is_prime(c) do
    c = c - 2
  end
  if c < 2 then return nil end
  return c
end

-- ---------------------------------------------------------------------------
-- GCD / LCM
-- ---------------------------------------------------------------------------

--- Greatest common divisor (Euclidean algorithm).
--: (a: number, b: number) -> number
function M.gcd(a, b)
  a = math.abs(math.floor(a))
  b = math.abs(math.floor(b))
  while b ~= 0 do
    local prev_b = b
    b = a % b
    a = prev_b
  end
  return a
end

--- Least common multiple.
--: (a: number, b: number) -> number
function M.lcm(a, b)
  local g = M.gcd(a, b)
  if g == 0 then return 0 end
  return math.abs(math.floor(a)) * math.floor(math.abs(b) / g)
end

--- Extended GCD. Returns g, x, y such that a*x + b*y = g.
--: (a: number, b: number) -> (number, number, number)
function M.gcd_ext(a, b)
  if b == 0 then return a, 1, 0 end
  local g, x1, y1 = M.gcd_ext(b, a % b)
  return g, y1, x1 - math.floor(a / b) * y1
end

--- True if gcd(a, b) == 1.
--: (a: number, b: number) -> boolean
function M.coprime(a, b)
  return M.gcd(a, b) == 1
end

-- ---------------------------------------------------------------------------
-- Modular arithmetic
-- ---------------------------------------------------------------------------

--- Modular inverse of a mod m. Returns nil if gcd(a,m) != 1.
--: (a: number, m: number) -> (number | nil)
function M.mod_inv(a, m)
  local g, x = M.gcd_ext(a % m, m)
  if g ~= 1 then return nil end
  return (x % m + m) % m
end

--- Chinese Remainder Theorem. Takes varargs of {n, r} pairs.
-- Returns x, N where x ≡ r_i (mod n_i) for all i and 0 <= x < N.
-- Moduli must be pairwise coprime.
--: (...unknown) -> (number | nil, number | string)
function M.chinese_remainder(...)
  local pairs_list = {...} --[[:! { [number]: { [number]: number } } ]]
  if #pairs_list == 0 then return nil, "no congruences given" end
  local x = pairs_list[1][2]
  local N = pairs_list[1][1]
  for i = 2, #pairs_list do
    local ni, ri = pairs_list[i][1], pairs_list[i][2]
    local g, inv = M.gcd_ext(N % ni, ni)
    if g ~= 1 then return nil, "moduli not coprime" end
    local diff = (ri - x % ni + ni) % ni
    local step = (diff * inv) % ni
    x = x + N * step
    N = N * ni
    x = x % N
  end
  return x, N
end

--- Euler's totient function φ(n).
--: (n: number) -> number
function M.euler_phi(n)
  n = math.floor(n)
  if n <= 0 then return 0 end
  if n == 1 then return 1 end
  local result = n
  local temp = n
  local p = 2
  while p * p <= temp do
    if temp % p == 0 then
      while temp % p == 0 do
        temp = math.floor(temp / p)
      end
      result = result - math.floor(result / p)
    end
    p = p + 1
  end
  if temp > 1 then
    result = result - math.floor(result / temp)
  end
  return result
end

--- Carmichael's lambda function λ(n).
--: (n: number) -> number
function M.carmichael_lambda(n)
  n = math.floor(n)
  if n <= 0 then return 0 end
  if n == 1 then return 1 end
  -- Factorize n, then compute lambda using lcm
  local factors = M.factorize(n)
  local result = 1 --[[: number ]]
  for p, e in pairs(factors) do
    local pk = p ^ e
    local lam
    if p == 2 and e >= 3 then
      lam = math.floor(pk / 4)  -- 2^(e-2)
    else
      lam = (p - 1) * p ^ (e - 1)  -- phi(p^e)
    end
    result = M.lcm(result, lam)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Factorization
-- ---------------------------------------------------------------------------

--- Pollard's rho algorithm (Brent's variant). Returns a non-trivial factor of n,
-- or n itself if none found quickly. Assumes n is composite and odd.
--: (n: number) -> number
local function pollard_rho(n)
  if n % 2 == 0 then return 2 end
  local x = 2 --[[: number ]]
  local y = 2 --[[: number ]]
  local c = 1 --[[: number ]]
  local d = 1 --[[: number ]]
  while d == 1 do
    x = (mulmod(x, x, n) + c) % n
    y = (mulmod(y, y, n) + c) % n
    y = (mulmod(y, y, n) + c) % n
    d = M.gcd(math.abs(x - y), n)
  end
  if d == n then
    -- restart with different c
    for try_c = 2, 20 do
      x = 2 --[[: number ]]
      y = 2 --[[: number ]]
      c = try_c --[[: number ]]
      d = 1 --[[: number ]]
      local limit = 1000 --[[: number ]]
      local count = 0 --[[: number ]]
      while d == 1 and count < limit do
        x = (mulmod(x, x, n) + c) % n
        y = (mulmod(y, y, n) + c) % n
        y = (mulmod(y, y, n) + c) % n
        d = M.gcd(math.abs(x - y), n)
        count = count + 1
      end
      if d ~= 1 and d ~= n then return d end
    end
    -- fall back: trial division
    local i = 3
    while i * i <= n do
      if n % i == 0 then return i end
      i = i + 2
    end
    return n
  end
  return d
end

-- Internal: fully factorize n into {prime=exponent} table (recursive)
--: (n: number, result: { [number]: number }) -> nil
local function factorize_into(n, result)
  if n <= 1 then return end
  if M.is_prime(n) then
    result[n] = (result[n] or 0) + 1
    return
  end
  local d = pollard_rho(n)
  factorize_into(d, result)
  factorize_into(math.floor(n / d), result)
end

--- Prime factorization. Returns {p1=e1, p2=e2, ...}.
--: (n: number) -> { [number]: number }
function M.factorize(n)
  n = math.floor(n)
  if n <= 1 then return {} end
  local result = {}
  -- Trial division for small primes first
  local small = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47}
  for _, p in ipairs(small) do
    while n % p == 0 do
      result[p] = (result[p] or 0) + 1
      n = math.floor(n / p)
    end
  end
  -- Trial division up to 1000
  local p = 53
  while p <= 1000 and p * p <= n do
    if M.is_prime_trial(p) then
      while n % p == 0 do
        result[p] = (result[p] or 0) + 1
        n = math.floor(n / p)
      end
    end
    p = p + 2
  end
  if n > 1 then
    factorize_into(n, result)
  end
  return result
end

--- Sorted array of prime factors with repetition (e.g. 12 → {2,2,3}).
--: (n: number) -> number[]
function M.factors(n)
  local f = M.factorize(n)
  local result = {}
  for p, e in pairs(f) do
    for _ = 1, e do
      result[#result + 1] = p
    end
  end
  table.sort(result)
  return result
end

--- Sorted array of all positive divisors of n.
--: (n: number) -> number[]
function M.divisors(n)
  n = math.floor(n)
  if n <= 0 then return {} end
  local result = {} --[[: { [integer]: number } ]]
  local i = 1
  while i * i <= n do
    if n % i == 0 then
      result[#result + 1] = i
      if i ~= math.floor(n / i) then
        result[#result + 1] = math.floor(n / i)
      end
    end
    i = i + 1
  end
  table.sort(result)
  return result
end

--- Number of divisors of n.
--: (n: number) -> number
function M.num_divisors(n)
  local f = M.factorize(n)
  local count = 1 --[[: number ]]
  for _, e in pairs(f) do
    count = count * (e + 1)
  end
  return count
end

--- Sum of all divisors of n.
--: (n: number) -> number
function M.sum_divisors(n)
  local f = M.factorize(n)
  local total = 1 --[[: number ]]
  for p, e in pairs(f) do
    -- sum of p^0 + p^1 + ... + p^e = (p^(e+1) - 1) / (p - 1)
    local s = 0 --[[: number ]]
    local pk = 1 --[[: number ]]
    for _ = 0, e do
      s = s + pk
      pk = pk * p
    end
    total = total * s
  end
  return total
end

-- ---------------------------------------------------------------------------
-- Number properties
-- ---------------------------------------------------------------------------

--: (n: number) -> number
local function sum_proper_divisors(n)
  if n <= 1 then return 0 end
  return M.sum_divisors(n) - n
end

--- True if sum of proper divisors == n.
--: (n: number) -> boolean
function M.is_perfect(n)
  n = math.floor(n)
  if n <= 1 then return false end
  return sum_proper_divisors(n) == n
end

--- True if sum of proper divisors > n.
--: (n: number) -> boolean
function M.is_abundant(n)
  n = math.floor(n)
  if n <= 0 then return false end
  return sum_proper_divisors(n) > n
end

--- True if sum of proper divisors < n.
--: (n: number) -> boolean
function M.is_deficient(n)
  n = math.floor(n)
  if n <= 0 then return false end
  return sum_proper_divisors(n) < n
end

--- Integer square root (floor(sqrt(n))).
--: (n: number) -> (number | nil)
function M.isqrt(n)
  n = math.floor(n)
  if n < 0 then return nil end
  if n == 0 then return 0 end
  local x = math.floor(math.sqrt(n))
  -- Correct for floating-point inaccuracy
  while x * x > n do x = x - 1 end
  while (x + 1) * (x + 1) <= n do x = x + 1 end
  return x
end

--- True if n is a perfect square.
--: (n: number) -> boolean
function M.is_square(n)
  n = math.floor(n)
  if n < 0 then return false end
  local s = M.isqrt(n)
  if s == nil then return false end
  return s * s == n
end

--- If n = base^exp for integer base >= 2 and exp >= 2, returns base, exp.
-- Otherwise returns nil.
--: (n: number) -> (number | nil, number | nil)
function M.is_power(n)
  n = math.floor(n)
  if n < 4 then return nil end
  -- Try all exponents from 2 up to log2(n)
  local max_exp = math.floor(math.log(n) / math.log(2))
  for e = 2, max_exp do
    local b = math.floor(n ^ (1 / e) + 0.5)
    -- check b-1, b, b+1 to handle floating-point rounding
    for _, candidate in ipairs({b - 1, b, b + 1}) do
      if candidate >= 2 then
        local power = candidate ^ e
        if power == n then
          return candidate, e
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Sieve of Eratosthenes
-- ---------------------------------------------------------------------------

--- All primes <= n as a sorted array.
--: (n: number) -> number[]
function M.primes_up_to(n)
  n = math.floor(n)
  if n < 2 then return {} end
  local sieve = {} --[[: { [integer]: boolean } ]]
  for i = 2, n do sieve[i] = true end
  local i = 2
  while i * i <= n do
    if sieve[i] then
      local j = i * i
      while j <= n do
        sieve[j] = false
        j = j + i
      end
    end
    i = i + 1
  end
  local result = {}
  for k = 2, n do
    if sieve[k] then result[#result + 1] = k end
  end
  return result
end

--- Count of primes <= n (prime counting function π(n)).
--: (n: number) -> integer
function M.prime_pi(n)
  return #M.primes_up_to(n)
end

-- ---------------------------------------------------------------------------
-- Jacobi and Legendre symbols
-- ---------------------------------------------------------------------------

--- Jacobi symbol (a/n) where n is a positive odd integer. Returns -1, 0, or 1.
--: (a: number, n: number) -> integer
function M.jacobi(a, n)
  n = math.floor(n)
  a = math.floor(a)
  assert(n > 0 and n % 2 == 1, "jacobi: n must be a positive odd integer")
  a = a % n
  local result = 1
  while a ~= 0 do
    while a % 2 == 0 do
      a = math.floor(a / 2)
      local nm8 = n % 8
      if nm8 == 3 or nm8 == 5 then result = -result end
    end
    a, n = n, a
    if a % 4 == 3 and n % 4 == 3 then result = -result end
    a = a % n
  end
  if n == 1 then return result end
  return 0
end

--- Legendre symbol (a/p) for prime p. Returns -1, 0, or 1.
--: (a: number, p: number) -> integer
function M.legendre(a, p)
  p = math.floor(p)
  a = math.floor(a)
  assert(M.is_prime(p), "legendre: p must be prime")
  return M.jacobi(a, p)
end

return M
