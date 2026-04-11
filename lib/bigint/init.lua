if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Arbitrary precision integer arithmetic.
-- Pure Lua, no dependencies. Stores digits in base 10^7 chunks (fits in doubles).
-- Least significant chunk first. Sign stored separately.

local M = {}
M._tier = "pure"

local BASE = 1e7       -- 10^7
local BASE_LOG10 = 7   -- digits per chunk
local HALF_BASE = 1e4  -- for Karatsuba split (unused for now, reserved)

local floor = math.floor
local abs = math.abs

-- ── Internal helpers ─────────────────────────────────────────────────────────

-- Strip trailing zero chunks and normalize negative zero.
local function normalize(self)
  local d = self.d
  local n = #d
  while n > 1 and d[n] == 0 do
    d[n] = nil
    n = n - 1
  end
  if n == 1 and d[1] == 0 then self.s = 1 end
  return self
end

-- Create a bigint from an already-populated digit array and sign.
local function from_raw(digits, sign)
  local self = { d = digits, s = sign }
  return setmetatable(normalize(self), M._mt)
end

-- Compare magnitudes. Returns -1, 0, or 1.
local function cmp_abs(a, b)
  local ad, bd = a.d, b.d
  local an, bn = #ad, #bd
  if an ~= bn then return an < bn and -1 or 1 end
  for i = an, 1, -1 do
    if ad[i] ~= bd[i] then return ad[i] < bd[i] and -1 or 1 end
  end
  return 0
end

-- Add magnitudes, return new digit array.
local function add_abs(a, b)
  local ad, bd = a.d, b.d
  local an, bn = #ad, #bd
  if an < bn then ad, bd, an, bn = bd, ad, bn, an end
  local r = {}
  local carry = 0
  for i = 1, an do
    local sum = ad[i] + (bd[i] or 0) + carry
    if sum >= BASE then
      r[i] = sum - BASE
      carry = 1
    else
      r[i] = sum
      carry = 0
    end
  end
  if carry > 0 then r[an + 1] = carry end
  return r
end

-- Subtract magnitudes (|a| >= |b| required), return new digit array.
local function sub_abs(a, b)
  local ad, bd = a.d, b.d
  local an = #ad
  local r = {}
  local borrow = 0
  for i = 1, an do
    local diff = ad[i] - (bd[i] or 0) - borrow
    if diff < 0 then
      r[i] = diff + BASE
      borrow = 1
    else
      r[i] = diff
      borrow = 0
    end
  end
  return r
end

-- Multiply magnitudes via schoolbook, return new digit array.
local function mul_abs(a, b)
  local ad, bd = a.d, b.d
  local an, bn = #ad, #bd
  local r = {}
  for i = 1, an + bn do r[i] = 0 end
  for i = 1, an do
    local ai = ad[i]
    if ai ~= 0 then
      local carry = 0
      for j = 1, bn do
        local pos = i + j - 1
        local prod = ai * bd[j] + r[pos] + carry
        -- Use floor division to split into chunk + carry.
        carry = floor(prod / BASE)
        r[pos] = prod - carry * BASE
      end
      if carry > 0 then
        r[i + bn] = r[i + bn] + carry
      end
    end
  end
  return r
end

-- Divide magnitudes via long division. Returns (quotient_digits, remainder_digits).
-- Assumes b is not zero.
local function divmod_abs(a, b)
  local ad, bd = a.d, b.d
  local an, bn = #ad, #bd
  -- Quick path: a < b
  if an < bn or (an == bn and cmp_abs(a, b) < 0) then
    local rc = {}
    for i = 1, an do rc[i] = ad[i] end
    return {0}, rc
  end
  -- Single-chunk divisor: simple loop
  if bn == 1 then
    local divisor = bd[1]
    local q = {}
    local rem = 0
    for i = an, 1, -1 do
      local cur = rem * BASE + ad[i]
      q[i] = floor(cur / divisor)
      rem = cur - q[i] * divisor
    end
    return q, {rem}
  end
  -- General long division, one chunk at a time from most significant.
  -- We build the quotient chunk by chunk.
  -- Use a working remainder as a bigint.
  local rem = from_raw({0}, 1)
  local q = {}
  for i = 1, an do q[i] = 0 end
  local b_obj = from_raw(bd, 1) -- share the digit array read-only
  for i = an, 1, -1 do
    -- Shift remainder left by one chunk and add a[i]
    local rd = rem.d
    local rn = #rd
    for j = rn, 1, -1 do rd[j + 1] = rd[j] end
    rd[1] = ad[i]
    normalize(rem)
    -- Binary search for the quotient digit q[i] such that q[i]*b <= rem < (q[i]+1)*b
    local lo, hi = 0, BASE - 1
    -- Upper bound: rem's top chunk(s) / b's top chunk
    local rn2 = #rem.d
    if rn2 > 0 then
      local est_num = rem.d[rn2]
      if rn2 > #bd then
        est_num = est_num * BASE + (rem.d[rn2 - 1] or 0)
        hi = floor(est_num / bd[#bd]) + 1
        if hi >= BASE then hi = BASE - 1 end
      end
    end
    while lo < hi do
      local mid = floor((lo + hi + 1) / 2)
      -- Compute mid * b manually to avoid allocation
      local carry = 0
      local fits = true
      local prod = {}
      for j = 1, bn do
        local p = mid * bd[j] + carry
        carry = floor(p / BASE)
        prod[j] = p - carry * BASE
      end
      if carry > 0 then prod[bn + 1] = carry end
      -- Compare prod with rem
      local pn = #prod
      while pn > 1 and prod[pn] == 0 do pn = pn - 1 end
      local rn3 = #rem.d
      local cmp
      if pn ~= rn3 then
        cmp = pn < rn3 and -1 or 1
      else
        cmp = 0
        for j = pn, 1, -1 do
          if prod[j] ~= rem.d[j] then
            cmp = prod[j] < rem.d[j] and -1 or 1
            break
          end
        end
      end
      if cmp <= 0 then
        lo = mid
      else
        hi = mid - 1
      end
    end
    q[i] = lo
    -- Subtract lo * b from rem
    if lo > 0 then
      local carry = 0
      local sub_arr = {}
      for j = 1, bn do
        local p = lo * bd[j] + carry
        carry = floor(p / BASE)
        sub_arr[j] = p - carry * BASE
      end
      if carry > 0 then sub_arr[bn + 1] = carry end
      -- rem = rem - sub_arr
      local borrow = 0
      local sn = #sub_arr
      local rn3 = #rem.d
      local mx = rn3
      if sn > mx then mx = sn end
      for j = 1, mx do
        local diff = (rem.d[j] or 0) - (sub_arr[j] or 0) - borrow
        if diff < 0 then
          rem.d[j] = diff + BASE
          borrow = 1
        else
          rem.d[j] = diff
          borrow = 0
        end
      end
      normalize(rem)
    end
  end
  return q, rem.d
end

-- ── Metatable ────────────────────────────────────────────────────────────────

local mt = {}
M._mt = mt
mt.__index = M

mt.__tostring = function(self)
  return self:to_string()
end

mt.__add = function(a, b)
  return a:add(b)
end

mt.__sub = function(a, b)
  return a:sub(b)
end

mt.__mul = function(a, b)
  return a:mul(b)
end

mt.__div = function(a, b)
  return a:div(b)
end

mt.__mod = function(a, b)
  return a:mod(b)
end

mt.__unm = function(a)
  return a:neg()
end

mt.__eq = function(a, b)
  return a:eq(b)
end

mt.__lt = function(a, b)
  return a:lt(b)
end

mt.__le = function(a, b)
  return a:le(b)
end

mt.__pow = function(a, n)
  return a:pow(n)
end

-- ── Constructors ─────────────────────────────────────────────────────────────

-- Create a bigint from a string or number.
function M.new(v)
  if type(v) == "table" and getmetatable(v) == mt then
    -- Clone
    local d = {}
    for i = 1, #v.d do d[i] = v.d[i] end
    return from_raw(d, v.s)
  end
  if type(v) == "number" then
    v = ("%.0f"):format(v)
  end
  if type(v) ~= "string" then
    return nil, "bigint.new: expected string or number, got " .. type(v)
  end
  local s = v:match("^%s*(.-)%s*$") -- trim
  if s == "" then return nil, "bigint.new: empty string" end
  local sign = 1
  if s:sub(1, 1) == "-" then
    sign = -1
    s = s:sub(2)
  elseif s:sub(1, 1) == "+" then
    s = s:sub(2)
  end
  -- Strip leading zeros
  s = s:match("^0*(.+)$") or "0"
  if not s:match("^%d+$") then
    return nil, "bigint.new: invalid digit string"
  end
  -- Parse into base-10^7 chunks, least significant first
  local d = {}
  local len = #s
  local idx = 1
  while len > 0 do
    local start = len - BASE_LOG10 + 1
    if start < 1 then start = 1 end
    local chunk = s:sub(start, len)
    d[idx] = tonumber(chunk)
    idx = idx + 1
    len = start - 1
  end
  return from_raw(d, sign)
end

-- Create a bigint from a hexadecimal string.
function M.from_hex(s)
  if type(s) ~= "string" then
    return nil, "bigint.from_hex: expected string, got " .. type(s)
  end
  s = s:match("^%s*(.-)%s*$") -- trim
  local sign = 1
  if s:sub(1, 1) == "-" then
    sign = -1
    s = s:sub(2)
  end
  -- Strip 0x/0X prefix
  if s:sub(1, 2) == "0x" or s:sub(1, 2) == "0X" then
    s = s:sub(3)
  end
  -- Strip leading zeros
  s = s:match("^0*(.+)$") or "0"
  if not s:match("^%x+$") then
    return nil, "bigint.from_hex: invalid hex string"
  end
  -- Convert hex to decimal string, then use M.new
  -- We process hex digits and accumulate into our base-10^7 representation directly.
  -- Each hex digit multiplies current value by 16 and adds the digit.
  local d = {0}
  for i = 1, #s do
    local c = s:byte(i)
    local digit
    if c >= 48 and c <= 57 then digit = c - 48
    elseif c >= 65 and c <= 70 then digit = c - 55
    elseif c >= 97 and c <= 102 then digit = c - 87
    end
    -- Multiply d by 16 and add digit
    local carry = digit
    for j = 1, #d do
      local v = d[j] * 16 + carry
      carry = floor(v / BASE)
      d[j] = v - carry * BASE
    end
    if carry > 0 then d[#d + 1] = carry end
  end
  return from_raw(d, sign)
end

-- ── Constants ────────────────────────────────────────────────────────────────

M.ZERO = M.new(0)
M.ONE  = M.new(1)

-- ── Arithmetic ───────────────────────────────────────────────────────────────

function M.add(a, b)
  if a.s == b.s then
    return from_raw(add_abs(a, b), a.s)
  end
  local c = cmp_abs(a, b)
  if c == 0 then return M.new(0) end
  if c > 0 then
    return from_raw(sub_abs(a, b), a.s)
  else
    return from_raw(sub_abs(b, a), b.s)
  end
end

function M.sub(a, b)
  -- a - b = a + (-b)
  local neg_b = from_raw(b.d, -b.s)
  return M.add(a, neg_b)
end

function M.mul(a, b)
  if a:is_zero() or b:is_zero() then return M.new(0) end
  return from_raw(mul_abs(a, b), a.s * b.s)
end

function M.div(a, b)
  if b:is_zero() then return nil, "bigint.div: division by zero" end
  local qd, _ = divmod_abs(a, b)
  local sign = a.s * b.s
  return from_raw(qd, sign)
end

function M.mod(a, b)
  if b:is_zero() then return nil, "bigint.mod: division by zero" end
  local _, rd = divmod_abs(a, b)
  -- Remainder has same sign as dividend
  return from_raw(rd, a.s)
end

function M.divmod(a, b)
  if b:is_zero() then return nil, "bigint.divmod: division by zero" end
  local qd, rd = divmod_abs(a, b)
  local q = from_raw(qd, a.s * b.s)
  local r = from_raw(rd, a.s)
  return q, r
end

function M.pow(a, n)
  if type(n) ~= "number" or n < 0 or n ~= floor(n) then
    return nil, "bigint.pow: exponent must be a non-negative integer"
  end
  if n == 0 then return M.new(1) end
  if n == 1 then return M.new(a) end
  -- Binary exponentiation
  local result = M.new(1)
  local base = M.new(a)
  while n > 0 do
    if n % 2 == 1 then
      result = result:mul(base)
    end
    base = base:mul(base)
    n = floor(n / 2)
  end
  return result
end

-- ── Unary ────────────────────────────────────────────────────────────────────

function M.abs(a)
  local d = {}
  for i = 1, #a.d do d[i] = a.d[i] end
  return from_raw(d, 1)
end

function M.neg(a)
  local d = {}
  for i = 1, #a.d do d[i] = a.d[i] end
  return from_raw(d, -a.s)
end

function M.sign(a)
  if a:is_zero() then return 0 end
  return a.s
end

-- ── Comparison ───────────────────────────────────────────────────────────────

function M.eq(a, b)
  if a.s ~= b.s then
    -- Both zero?
    if a:is_zero() and b:is_zero() then return true end
    return false
  end
  return cmp_abs(a, b) == 0
end

function M.lt(a, b)
  if a.s ~= b.s then
    if a:is_zero() and b:is_zero() then return false end
    return a.s < b.s
  end
  if a.s > 0 then
    return cmp_abs(a, b) < 0
  else
    return cmp_abs(a, b) > 0
  end
end

function M.le(a, b)
  return a:lt(b) or a:eq(b)
end

function M.gt(a, b)
  return b:lt(a)
end

function M.ge(a, b)
  return b:le(a)
end

-- ── Predicates ───────────────────────────────────────────────────────────────

function M.is_zero(a)
  return #a.d == 1 and a.d[1] == 0
end

function M.is_positive(a)
  return not a:is_zero() and a.s > 0
end

function M.is_negative(a)
  return not a:is_zero() and a.s < 0
end

function M.is_even(a)
  return a.d[1] % 2 == 0
end

function M.is_odd(a)
  return a.d[1] % 2 == 1
end

-- ── Conversion ───────────────────────────────────────────────────────────────

function M.to_string(a)
  local d = a.d
  local n = #d
  -- Most significant chunk: no leading zeros
  local parts = {}
  if a.s < 0 and not a:is_zero() then parts[1] = "-" end
  parts[#parts + 1] = tostring(d[n])
  -- Remaining chunks: zero-padded to BASE_LOG10 digits
  for i = n - 1, 1, -1 do
    local s = tostring(d[i])
    parts[#parts + 1] = ("0"):rep(BASE_LOG10 - #s) .. s
  end
  return table.concat(parts)
end

function M.to_number(a)
  -- Lossy conversion: only accurate up to 2^53
  local result = 0
  local d = a.d
  local mult = 1
  for i = 1, #d do
    result = result + d[i] * mult
    mult = mult * BASE
  end
  return result * a.s
end

function M.to_hex(a)
  if a:is_zero() then return "0" end
  -- Divide repeatedly by 16
  local hex_digits = {}
  local tmp = a:abs()
  local sixteen = M.new(16)
  while not tmp:is_zero() do
    local q, r = tmp:divmod(sixteen)
    local rv = r:to_number()
    if rv < 10 then
      hex_digits[#hex_digits + 1] = tostring(rv)
    else
      hex_digits[#hex_digits + 1] = string.char(55 + rv) -- A=65, 10+55=65
    end
    tmp = q
  end
  -- Reverse
  local n = #hex_digits
  for i = 1, floor(n / 2) do
    hex_digits[i], hex_digits[n - i + 1] = hex_digits[n - i + 1], hex_digits[i]
  end
  local prefix = ""
  if a.s < 0 then prefix = "-" end
  return prefix .. table.concat(hex_digits)
end

-- ── Number theory ────────────────────────────────────────────────────────────

function M.gcd(a, b)
  a = a:abs()
  b = b:abs()
  while not b:is_zero() do
    local _, r = a:divmod(b)
    a = b
    b = r
  end
  return a
end

function M.lcm(a, b)
  if a:is_zero() or b:is_zero() then return M.new(0) end
  local g = M.gcd(a, b)
  local q = a:abs():div(g)
  return q:mul(b:abs())
end

function M.max(a, b)
  if a:ge(b) then return M.new(a) end
  return M.new(b)
end

function M.min(a, b)
  if a:le(b) then return M.new(a) end
  return M.new(b)
end

function M.factorial(n)
  if type(n) == "number" then n = M.new(n) end
  if n:is_negative() then return nil, "bigint.factorial: negative argument" end
  if n:is_zero() then return M.new(1) end
  local result = M.new(1)
  local i = M.new(2)
  while i:le(n) do
    result = result:mul(i)
    i = i:add(M.ONE)
  end
  return result
end

return M
