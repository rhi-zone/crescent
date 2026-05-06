if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Arbitrary precision decimal floating-point arithmetic (BigDecimal style).
-- Pure Lua, no dependencies.
--
-- Representation:
--   { digits: string, exp: integer, s: -1|0|1 }
--
--   value = s * 0.digits * 10^exp
--
-- where `digits` is a non-empty string of '0'-'9'.
-- Normalization invariants:
--   • No leading zeros in `digits` (unless digits == "0").
--   • No trailing zeros in `digits` (unless digits == "0").
--   • If s == 0, then digits == "0" and exp == 0.
--
-- Exponent semantics: exp = "how many digits sit to the left of the decimal
-- point in the original number".  Equivalently, the most-significant digit
-- has place-value 10^(exp-1).
--
-- Examples:
--   "3.14"    → { digits="314",  exp=1,  s=1  }   (0.314 × 10^1   = 3.14)
--   "0.001"   → { digits="1",    exp=-2, s=1  }   (0.1   × 10^-2  = 0.001)
--   "-100"    → { digits="1",    exp=3,  s=-1 }   (0.1   × 10^3   = 100)
--   "0"       → { digits="0",    exp=0,  s=0  }

local M = {}
M._tier = "pure"

local math2 = require("lib.math")
local floor  = math.floor
local abs    = math.abs
local max    = math.max
local min    = math.min
local rep    = string.rep
local sub    = string.sub
local byte   = string.byte
local format = string.format

-- ── Global precision for division ────────────────────────────────────────────

local _default_prec = 50

function M.set_precision(p)
  _default_prec = p
end

function M.get_precision()
  return _default_prec
end

-- ── Metatable (forward-declared) ─────────────────────────────────────────────

--:: Bignum = { s: integer, digits: string, exp: integer }

local mt = {}
M._mt = mt
mt.__index = M

-- ── String utilities ─────────────────────────────────────────────────────────

-- Get a single byte at position i as integer.
--: (s: string, i: integer) -> integer
local function getbyte(s, i)
  return byte(s, i) or 0
end

-- Build a string from a table of byte values, handling LuaJIT's unpack limit.
local CHUNK = 200
--: (t: { [integer]: integer }) -> string
local function bytes_to_string(t)
  if #t == 0 then return "" end
  if #t <= CHUNK then
    return string.char(unpack(t))
  end
  local parts = {}
  local i = 1
  while i <= #t do
    local j = i + CHUNK - 1
    if j > #t then j = #t end
    local slice = {}
    for k = i, j do slice[#slice + 1] = t[k] end
    parts[#parts + 1] = string.char(unpack(slice))
    i = j + 1
  end
  return table.concat(parts)
end

-- ── Internal helpers ─────────────────────────────────────────────────────────

-- Construct and return a normalized bignum from raw fields.
-- Normalization:
--   1. Strip leading zeros from digits, decrementing exp accordingly.
--   2. Strip trailing zeros from digits (exp unchanged).
--   3. Canonicalize zero.
--: (s: integer, digits: string, exp: integer) -> Bignum
local function make(s, digits, exp)
  if digits == "" then digits = "0" end

  -- 1. Strip leading zeros
  local i = 1
  while i < #digits and sub(digits, i, i) == "0" do i = i + 1 end
  if i > 1 then
    exp = exp - (i - 1)
    digits = sub(digits, i)
  end

  -- 2. Strip trailing zeros (only if more than 1 digit)
  local j = #digits
  while j > 1 and sub(digits, j, j) == "0" do j = j - 1 end
  if j < #digits then
    digits = sub(digits, 1, j)
    -- exp unchanged: 0.150×10^1 = 0.15×10^1 = 1.5
  end

  -- 3. Canonicalize zero
  if digits == "0" or s == 0 then
    return setmetatable({ s = 0, digits = "0", exp = 0 }, mt)
  end

  return setmetatable({ s = s, digits = digits, exp = exp }, mt)
end

-- Return a new bignum that is zero.
--: () -> Bignum
local function zero()
  return setmetatable({ s = 0, digits = "0", exp = 0 }, mt)
end

-- Return string padded with leading zeros to length n.
--: (str: string, n: number) -> string
local function lpad(str, n)
  local pad = n - #str
  if pad <= 0 then return str end
  return rep("0", --[[:! integer]] pad) .. str
end

-- Add two unsigned digit strings (big-endian decimal).
--: (a: string, b: string) -> string
local function digits_add(a, b)
  local an, bn = #a, #b
  local n = max(an, bn)
  a = lpad(a, n)
  b = lpad(b, n)
  local result = {} --: { [integer]: integer }
  local carry = 0
  for i = n, 1, -1 do
    local ba = getbyte(a, i)
    local bb = getbyte(b, i)
    local sum = ba - 48 + bb - 48 + carry
    if sum >= 10 then
      carry = 1
      sum = sum - 10
    else
      carry = 0
    end
    result[n - i + 1] = sum + 48
  end
  if carry > 0 then result[#result + 1] = 49 end  -- ASCII '1'
  -- result is stored in reverse; reverse it
  local m = #result
  local out = {}
  for k = 1, m do out[k] = result[m - k + 1] end
  return bytes_to_string(out)
end

-- Subtract unsigned digit string b from a where a >= b.
--: (a: string, b: string) -> string
local function digits_sub(a, b)
  local n = max(#a, #b)
  a = lpad(a, n)
  b = lpad(b, n)
  local result = {} --: { [integer]: integer }
  local borrow = 0
  for i = n, 1, -1 do
    local ba = getbyte(a, i)
    local bb = getbyte(b, i)
    local d = ba - 48 - (bb - 48) - borrow
    if d < 0 then
      d = d + 10
      borrow = 1
    else
      borrow = 0
    end
    result[n - i + 1] = d + 48
  end
  local m = #result
  local out = {}
  for k = 1, m do out[k] = result[m - k + 1] end
  local s = bytes_to_string(out)
  return s:match("^0*(.+)$") or "0"
end

-- Compare two unsigned digit strings as integers.
--: (a: string, b: string) -> integer
local function digits_cmp(a, b)
  if #a ~= #b then return #a < #b and -1 or 1 end
  if a == b then return 0 end
  return a < b and -1 or 1
end

-- Multiply two unsigned digit strings. Returns result digit string.
--: (a: string, b: string) -> string
local function digits_mul(a, b)
  if a == "0" or b == "0" then return "0" end
  local an, bn = #a, #b
  local result = {} --: { [integer]: integer }
  for i = 1, an + bn do result[i] = 0 end
  for i = an, 1, -1 do
    local ba = getbyte(a, i)
    local ai = ba - 48
    if ai ~= 0 then
      local carry = 0
      for j = bn, 1, -1 do
        local bb = getbyte(b, j)
        local prod = ai * (bb - 48) + result[i + j] + carry
        carry = floor(prod / 10)
        result[i + j] = prod - carry * 10
      end
      result[i] = result[i] + carry
    end
  end
  local out = {} --: { [integer]: integer }
  for i = 1, #result do out[i] = result[i] + 48 end
  local s = bytes_to_string(out):match("^0*(.+)$") or "0"
  return s
end

-- Integer long division: returns floor(num * 10^extra / den) as a digit string,
-- where extra is chosen to produce at least `prec` significant digits in the result.
-- Also returns the shift used so the caller can reconstruct the exponent.
--: (num: string, den: string, prec: integer) -> (string, integer)
local function digits_div(num, den, prec)
  -- We want prec significant digits in the quotient.
  -- Let len_q = #num - #den + 1 (rough integer quotient digit count).
  -- We need to produce prec digits, so shift = prec + max(0, #den - #num).
  local shift = prec + --[[:! integer]] (max(0, #den - #num))
  local shifted_num = num .. rep("0", shift)
  local sn = #shifted_num

  -- Digit-by-digit long division
  local remainder = "0" --: string
  local q_digits = {} --: { [integer]: integer }
  for i = 1, sn do
    local d = sub(shifted_num, i, i)
    if remainder == "0" then
      remainder = d
    else
      remainder = remainder .. d
    end
    -- Strip leading zeros
    if #remainder > 1 then
      remainder = string.match(remainder, "^0*(.+)$") or "0"
    end
    -- Binary search for quotient digit 0..9
    local lo, hi = 0, 9
    while lo < hi do
      local mid = floor((lo + hi + 1) / 2)
      local prod = digits_mul(tostring(mid), den)
      local c = digits_cmp(prod, remainder)
      if c <= 0 then
        lo = mid
      else
        hi = mid - 1
      end
    end
    q_digits[#q_digits + 1] = lo + 48
    -- Subtract lo * den from remainder
    if lo > 0 then
      local sub_val = digits_mul(tostring(lo), den)
      remainder = digits_sub(remainder, sub_val)
    end
  end
  local s = bytes_to_string(q_digits):match("^0*(.+)$") or "0"
  return s, shift
end

-- ── Align two bignums to the same scale for add/sub ──────────────────────────

-- Returns (a_digits_aligned, b_digits_aligned, base_exp) where:
--   a = 0.a_digits_aligned * 10^base_exp_a and
--   b = 0.b_digits_aligned * 10^base_exp_b
-- and both digit strings represent the same-scale integers (base_exp is shared).
--
-- We align by padding with zeros so both have the same "span" of digit positions.
-- The digit at index k of the aligned string has place value 10^(base_exp - k).
--: (a: Bignum, b: Bignum) -> (string, string, integer)
local function align(a, b)
  -- a's most-significant digit is at position a.exp - 1 (0-indexed from decimal).
  -- a's least-significant digit is at position a.exp - #a.digits.
  -- Same for b. We cover [common_high, common_low] inclusive.
  local a_hi = a.exp          -- first digit position (exclusive upper bound)
  local a_lo = a.exp - #a.digits  -- last digit position (exclusive lower bound)
  local b_hi = b.exp
  local b_lo = b.exp - #b.digits

  local common_hi = max(a_hi, b_hi)
  local common_lo = min(a_lo, b_lo)

  -- a needs (common_hi - a_hi) leading zeros and (a_lo - common_lo) trailing zeros
  local ad = rep("0", --[[:! integer]] (common_hi - a_hi)) .. a.digits .. rep("0", --[[:! integer]] (a_lo - common_lo))
  local bd = rep("0", --[[:! integer]] (common_hi - b_hi)) .. b.digits .. rep("0", --[[:! integer]] (b_lo - common_lo))

  -- The aligned digit string represents an integer scaled by 10^common_lo.
  -- actual_value = s * 0.aligned_digits * 10^common_hi
  -- But we return the common exponent for the *integer representation*:
  -- integer = aligned_digits (the actual digits of the aligned number)
  -- value = s * integer * 10^common_lo
  -- In our 0.digits notation: value = s * 0.aligned_digits * 10^(common_lo + #aligned_digits)
  -- But we just need the aligned digit strings and the common_lo so the caller can
  -- reconstruct: result_exp = common_lo + #result_digits
  return ad, bd, common_lo
end

-- ── Constructors ─────────────────────────────────────────────────────────────

-- Parse a decimal string (including scientific notation) into a bignum.
-- Returns bignum or (nil, errmsg).
--: (v: number | string | Bignum) -> (Bignum | nil, string | nil)
function M.new(v)
  if type(v) == "table" and getmetatable(v) == mt then
    local bv = v --[[:! Bignum]]
    return setmetatable({ s = bv.s, digits = bv.digits, exp = bv.exp }, mt)
  end
  if type(v) == "number" then
    if v == floor(v) and abs(v) < 1e15 then
      v = format("%.0f", v)
    else
      v = format("%.17g", v)
    end
  end
  if type(v) ~= "string" then
    return nil, "bignum.new: expected string or number, got " .. type(v)
  end
  local vs = v --[[: string]]
  local str = string.match(vs, "^%s*(.-)%s*$") or ""
  if str == "" then return nil, "bignum.new: empty string" end

  local s = 1
  if sub(str, 1, 1) == "-" then
    s = -1
    str = sub(str, 2)
  elseif sub(str, 1, 1) == "+" then
    str = sub(str, 2)
  end

  -- Split off scientific-notation exponent
  local mantissa, exp_str = string.match(str, "^([^eE]+)[eE]([+-]?%d+)$")
  local exp_offset = 0 --: integer
  if mantissa then
    exp_offset = math2.tointeger(exp_str) or 0
    str = mantissa
  end

  -- Split integer and fractional parts at decimal point
  local int_part, frac_part = string.match(str, "^(%d*)%.(%d*)$")
  if not int_part then
    if string.match(str, "^%d+$") then
      int_part, frac_part = str, ""
    else
      return nil, "bignum.new: invalid number string: " .. v
    end
  end

  local ip = int_part --[[:! string]]
  local fp = frac_part --[[:! string]]
  local all_digits = ip .. fp
  if all_digits == "" then
    return nil, "bignum.new: no digits found in: " .. tostring(v)
  end
  if not all_digits:match("^%d+$") then
    return nil, "bignum.new: invalid digit string in: " .. tostring(v)
  end

  -- exp = number of digits before the decimal point + scientific exponent
  local exp = #ip + exp_offset
  return make(s, all_digits, exp)
end

M.parse = M.new

--: (n: number) -> (Bignum | nil, string | nil)
function M.from_number(n)
  if type(n) ~= "number" then
    return nil, "bignum.from_number: expected number, got " .. type(n)
  end
  return M.new(n)
end

-- ── Constants ────────────────────────────────────────────────────────────────

M.ZERO = zero()
--: Bignum
M.ONE = --[[:! Bignum]] select(1, M.new("1"))

-- ── Arithmetic ───────────────────────────────────────────────────────────────

--: (a: Bignum, b: Bignum) -> Bignum
function M.add(a, b)
  if a.s == 0 then return --[[:! Bignum]] select(1, M.new(b)) end
  if b.s == 0 then return --[[:! Bignum]] select(1, M.new(a)) end
  if a.s == b.s then
    local ad, bd, base_lo = align(a, b)
    local sum = digits_add(ad, bd)
    -- sum is an integer; value = s * sum * 10^base_lo
    -- In 0.digits form: value = s * 0.sum * 10^(base_lo + #sum)
    return make(a.s, sum, base_lo + #sum)
  end
  -- Different signs: |a| - |b| or |b| - |a|
  local ad, bd, base_lo = align(a, b)
  local c = digits_cmp(ad, bd)
  if c == 0 then return zero() end
  if c > 0 then
    local diff = digits_sub(ad, bd)
    return make(a.s, diff, base_lo + #diff)
  else
    local diff = digits_sub(bd, ad)
    return make(b.s, diff, base_lo + #diff)
  end
end

--: (a: Bignum, b: Bignum) -> Bignum
function M.sub(a, b)
  if b.s == 0 then
    return --[[:! Bignum]] select(1, M.new(a))
  end
  local neg_b = setmetatable({ s = -b.s, digits = b.digits, exp = b.exp }, mt)
  local r = M.add(a, neg_b)
  return r
end

--: (a: Bignum, b: Bignum) -> Bignum
function M.mul(a, b)
  if a.s == 0 or b.s == 0 then return zero() end
  local prod = digits_mul(a.digits, b.digits)
  -- a = 0.a.digits × 10^a.exp,  b = 0.b.digits × 10^b.exp
  -- a×b = (a.digits × b.digits) × 10^(a.exp+b.exp) / (10^#a.digits × 10^#b.digits)
  --     = 0.prod × 10^(a.exp + b.exp - #a.digits - #b.digits + #prod)
  local new_exp = a.exp + b.exp - #a.digits - #b.digits + #prod
  return make(a.s * b.s, prod, new_exp)
end

--: (a: Bignum, b: Bignum, prec: (integer | nil)) -> (Bignum | nil, string | nil)
function M.div(a, b, prec)
  if b.s == 0 then return nil, "bignum.div: division by zero" end
  if a.s == 0 then return zero() end
  prec = prec or _default_prec

  -- a = 0.a.digits × 10^a.exp,  b = 0.b.digits × 10^b.exp
  -- a/b = (a.digits/b.digits) × 10^(a.exp - b.exp)
  -- digits_div computes q = floor(a.digits × 10^shift / b.digits)
  -- => a.digits/b.digits ≈ q × 10^(-shift)
  -- => a/b ≈ q × 10^(a.exp - b.exp - shift)
  -- In 0.digits form: a/b ≈ 0.q × 10^(a.exp - b.exp - shift + #q)
  local q, shift = digits_div(a.digits, b.digits, prec)
  -- a = 0.a.digits × 10^a.exp = (a.digits_int / 10^#a.digits) × 10^a.exp
  -- b = 0.b.digits × 10^b.exp = (b.digits_int / 10^#b.digits) × 10^b.exp
  -- a/b = (a.digits_int / b.digits_int) × 10^(a.exp - b.exp + #b.digits - #a.digits)
  -- digits_div gives q ≈ a.digits_int × 10^shift / b.digits_int
  --   => a.digits_int / b.digits_int ≈ q × 10^(-shift)
  -- => a/b ≈ q × 10^(-shift + a.exp - b.exp + #b.digits - #a.digits)
  -- In 0.q notation: 0.q × 10^(-shift + a.exp - b.exp + #b.digits - #a.digits + #q)
  local new_exp = -shift + a.exp - b.exp + #b.digits - #a.digits + #q
  return make(a.s * b.s, q, new_exp)
end

--: (a: Bignum, b: Bignum) -> (Bignum | nil, string | nil)
function M.mod(a, b)
  if b.s == 0 then return nil, "bignum.mod: modulo by zero" end
  -- a % b = a - trunc(a/b) * b
  local q, err = M.div(a, b)
  if not q then return nil, err end
  q = M.trunc(q)
  return M.sub(a, M.mul(q, b))
end

--: (a: Bignum) -> Bignum
function M.neg(a)
  if a.s == 0 then return zero() end
  return setmetatable({ s = -a.s, digits = a.digits, exp = a.exp }, mt)
end

--: (a: Bignum) -> Bignum
function M.abs(a)
  if a.s == 0 then return zero() end
  return setmetatable({ s = 1, digits = a.digits, exp = a.exp }, mt)
end

-- ── Comparison ───────────────────────────────────────────────────────────────

--: (a: Bignum, b: Bignum) -> integer
local function cmp(a, b)
  if a.s ~= b.s then
    if a.s == 0 and b.s == 0 then return 0 end
    return a.s < b.s and -1 or 1
  end
  if a.s == 0 then return 0 end
  local ad, bd, _ = align(a, b)
  local c = digits_cmp(ad, bd)
  return a.s > 0 and c or -c
end

--: (a: Bignum, b: Bignum) -> boolean
function M.eq(a, b)  return cmp(a, b) == 0  end
--: (a: Bignum, b: Bignum) -> boolean
function M.lt(a, b)  return cmp(a, b) < 0   end
--: (a: Bignum, b: Bignum) -> boolean
function M.le(a, b)  return cmp(a, b) <= 0  end
--: (a: Bignum, b: Bignum) -> boolean
function M.gt(a, b)  return cmp(a, b) > 0   end
--: (a: Bignum, b: Bignum) -> boolean
function M.ge(a, b)  return cmp(a, b) >= 0  end

-- ── Predicates ───────────────────────────────────────────────────────────────

--: (a: Bignum) -> boolean
function M.is_zero(a)    return a.s == 0       end
--: (a: Bignum) -> integer
function M.sign(a)       return a.s            end

--: (a: Bignum) -> boolean
function M.is_integer(a)
  if a.s == 0 then return true end
  -- value = 0.digits × 10^exp
  -- Is integer when the value has no fractional part, i.e., exp >= #digits
  -- (all digits sit to the left of the decimal point)
  if a.exp >= #a.digits then return true end
  -- If exp <= 0, the entire number is fractional
  if a.exp <= 0 then return false end
  -- Fractional digits are those at index (exp+1) onwards in the digit string
  local frac = sub(a.digits, a.exp + 1)
  return frac:match("^0*$") ~= nil
end

-- ── Rounding ─────────────────────────────────────────────────────────────────

--: (a: Bignum) -> Bignum
function M.trunc(a)
  if a.s == 0 then return zero() end
  -- value = 0.digits × 10^exp
  -- Integer part: first `exp` digits of the digit string (if exp > 0)
  if a.exp <= 0 then return zero() end       -- entirely fractional
  if a.exp >= #a.digits then local r, _ = M.new(a); return --[[:! Bignum]] r end  -- entirely integer
  -- Keep only the first exp digits
  local int_digits = sub(a.digits, 1, a.exp)
  return make(a.s, int_digits, a.exp)
end

--: (a: Bignum) -> Bignum
function M.floor(a)
  if a.s == 0 then return zero() end
  local t = M.trunc(a)
  if a.s < 0 and not M.is_integer(a) then
    return M.sub(t, M.ONE)
  end
  return t
end

--: (a: Bignum) -> Bignum
function M.ceil(a)
  if a.s == 0 then return zero() end
  local t = M.trunc(a)
  if a.s > 0 and not M.is_integer(a) then
    return M.add(t, M.ONE)
  end
  return t
end

-- Round to `places` decimal places (round half away from zero).
--: (a: Bignum, places: (integer | nil)) -> Bignum
function M.round(a, places)
  places = places or 0
  if a.s == 0 then return zero() end
  -- We keep digits at positions 1 .. (exp + places) within a.digits,
  -- where position exp corresponds to the last integer digit.
  local keep = a.exp + places
  if keep <= 0 then
    -- All digits are beyond the rounding point
    if keep == 0 and #a.digits > 0 then
      local first = getbyte(a.digits, 1) - 48
      if first >= 5 then
        local one_at_place = make(1, "1", -places)
        return a.s > 0 and one_at_place or M.neg(one_at_place)
      end
    end
    return zero()
  end
  if keep >= #a.digits then
    local r, _ = M.new(a)
    return --[[:! Bignum]] r
  end
  local round_digit = getbyte(a.digits, keep + 1) - 48
  local kept = sub(a.digits, 1, keep)
  if round_digit >= 5 then
    kept = digits_add(kept, "1")
  end
  return make(a.s, kept, a.exp)
end

-- ── Conversion ───────────────────────────────────────────────────────────────

--: (a: Bignum) -> string
function M.to_string(a)
  if a.s == 0 then return "0" end
  local prefix = a.s < 0 and "-" or ""
  local d = a.digits
  local e = a.exp  -- digits before decimal point

  if e >= #d then
    -- All digits are integer digits (possibly with trailing zeros)
    return prefix .. d .. rep("0", e - #d)
  elseif e <= 0 then
    -- All digits are fractional
    return prefix .. "0." .. rep("0", -e) .. d
  else
    -- e digits before, rest after decimal
    return prefix .. sub(d, 1, e) .. "." .. sub(d, e + 1)
  end
end

--: (a: Bignum) -> number | nil
function M.to_number(a)
  return tonumber(M.to_string(a))
end

--: (a: Bignum) -> string
function M.to_integer(a)
  return M.to_string(M.trunc(a))
end

-- ── Math functions ────────────────────────────────────────────────────────────

--: (a: Bignum, n: number) -> (Bignum | nil, string | nil)
function M.pow(a, n)
  if type(n) ~= "number" or n ~= floor(n) then
    return nil, "bignum.pow: exponent must be an integer"
  end
  if n < 0 then
    return nil, "bignum.pow: negative exponent requires division"
  end
  if n == 0 then return M.ONE end
  if n == 1 then
    local r1, _ = M.new(a)
    return --[[:! Bignum]] r1
  end
  local result = M.ONE
  local baseb = --[[:! Bignum]] select(1, M.new(a))
  while n > 0 do
    if n % 2 == 1 then result = M.mul(result, baseb) end
    baseb = M.mul(baseb, baseb)
    n = floor(n / 2)
  end
  return result
end

-- Square root via Newton-Raphson to `prec` decimal places.
--: (a: Bignum, prec: (integer | nil)) -> (Bignum | nil, string | nil)
function M.sqrt(a, prec)
  prec = prec or _default_prec
  if a.s < 0 then return nil, "bignum.sqrt: negative argument" end
  if a.s == 0 then return zero() end

  -- Initial approximation
  local aton = M.to_number(a)
  local approx = math.sqrt(aton or 1)
  if approx ~= approx or approx <= 0 then approx = 1 end
  local x = --[[:! Bignum]] select(1, M.new(format("%.6g", approx)))
  local two = --[[:! Bignum]] select(1, M.new("2"))
  local wp = prec + 6

  for _ = 1, 200 do
    local axb = --[[:! Bignum]] select(1, M.div(a, x, wp))
    local x2add = M.add(x, axb)
    local x2 = --[[:! Bignum]] select(1, M.div(x2add, two, wp))
    local diff = M.abs(M.sub(x2, x))
    -- Converged when diff < 10^(-(prec+3))
    local threshold = make(1, "1", -(prec + 3))
    if M.lt(diff, threshold) or diff.s == 0 then
      x = x2
      break
    end
    x = x2
  end
  return M.round(x, prec)
end

-- Compute pi to `prec` decimal places using the Machin formula:
--   pi/4 = 4*arctan(1/5) - arctan(1/239)
-- Each arctan(1/x) computed via the Taylor series sum.
--: (prec: (integer | nil)) -> Bignum
function M.pi(prec)
  prec = prec or _default_prec
  local wp = prec + 10  -- extra working precision

  -- arctan(1/x_int) = 1/x - 1/(3x^3) + 1/(5x^5) - ...
  -- We accumulate in bignum arithmetic.
  local function arctan_inv(x_int)
    local x_bn = --[[:! Bignum]] select(1, M.new(tostring(x_int)))
    local x2_bn = --[[:! Bignum]] select(1, M.new(tostring(x_int * x_int)))
    -- First term: 1/x
    local term = --[[:! Bignum]] select(1, M.div(M.ONE, x_bn, wp + 5))
    local s    = term
    local k    = 1
    local neg  = true
    while true do
      -- term_{k} = term_{k-1} / x^2 × (2k-1)/(2k+1)
      local t1 = --[[:! Bignum]] select(1, M.div(term, x2_bn, wp + 5))
      local num_b = --[[:! Bignum]] select(1, M.new(tostring(2 * k - 1)))
      local den_b = --[[:! Bignum]] select(1, M.new(tostring(2 * k + 1)))
      term = --[[:! Bignum]] select(1, M.div(M.mul(t1, num_b), den_b, wp + 5))
      if neg then
        s = --[[:! Bignum]] M.sub(s, term)
      else
        s = --[[:! Bignum]] M.add(s, term)
      end
      neg = not neg
      k = k + 1
      -- Stop when term < 10^(-(wp+2))
      local threshold = make(1, "1", -(wp + 2))
      if M.lt(M.abs(term), threshold) or term.s == 0 then break end
      if k > 100000 then break end
    end
    return s
  end

  local four = --[[:! Bignum]] select(1, M.new("4"))
  local a5   = arctan_inv(5)
  local a239 = arctan_inv(239)
  -- pi = 4 * (4*arctan(1/5) - arctan(1/239))
  local pi_val = M.mul(four, M.sub(M.mul(four, a5), a239))
  return M.round(pi_val, prec)
end

-- ── Metamethods ──────────────────────────────────────────────────────────────

mt.__tostring = function(a)  return M.to_string(a) end
mt.__add      = function(a, b) return M.add(a, b) end
mt.__sub      = function(a, b) return M.sub(a, b) end
mt.__mul      = function(a, b) return M.mul(a, b) end
mt.__div      = function(a, b) return M.div(a, b) end
mt.__mod      = function(a, b) return M.mod(a, b) end
mt.__unm      = function(a)    return M.neg(a) end
mt.__eq       = function(a, b) return M.eq(a, b) end
mt.__lt       = function(a, b) return M.lt(a, b) end
mt.__le       = function(a, b) return M.le(a, b) end

return M
