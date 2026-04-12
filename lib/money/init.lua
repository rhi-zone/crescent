if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Monetary arithmetic library with exact decimal representation.
-- Amounts are stored as integers in minor units (e.g. cents for USD).
-- No floating-point is used for amount storage — all arithmetic is exact.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Currency metadata (ISO 4217 subset)
-- ---------------------------------------------------------------------------

M.CURRENCIES = {
  USD = { name = "US Dollar",         symbol = "$",  decimals = 2, symbol_before = true  },
  EUR = { name = "Euro",              symbol = "€",  decimals = 2, symbol_before = true  },
  GBP = { name = "British Pound",     symbol = "£",  decimals = 2, symbol_before = true  },
  JPY = { name = "Japanese Yen",      symbol = "¥",  decimals = 0, symbol_before = true  },
  CHF = { name = "Swiss Franc",       symbol = "Fr", decimals = 2, symbol_before = true  },
  CAD = { name = "Canadian Dollar",   symbol = "$",  decimals = 2, symbol_before = true  },
  AUD = { name = "Australian Dollar", symbol = "$",  decimals = 2, symbol_before = true  },
  CNY = { name = "Chinese Yuan",      symbol = "¥",  decimals = 2, symbol_before = true  },
  INR = { name = "Indian Rupee",      symbol = "₹",  decimals = 2, symbol_before = true  },
  KRW = { name = "South Korean Won",  symbol = "₩",  decimals = 0, symbol_before = true  },
  BRL = { name = "Brazilian Real",    symbol = "R$", decimals = 2, symbol_before = true  },
  MXN = { name = "Mexican Peso",      symbol = "$",  decimals = 2, symbol_before = true  },
  SGD = { name = "Singapore Dollar",  symbol = "$",  decimals = 2, symbol_before = true  },
  HKD = { name = "Hong Kong Dollar",  symbol = "$",  decimals = 2, symbol_before = true  },
  SEK = { name = "Swedish Krona",     symbol = "kr", decimals = 2, symbol_before = false },
  NOK = { name = "Norwegian Krone",   symbol = "kr", decimals = 2, symbol_before = false },
  DKK = { name = "Danish Krone",      symbol = "kr", decimals = 2, symbol_before = false },
}

-- Return currency metadata or nil.
M.currency = function(code)
  return M.CURRENCIES[code]
end

-- Return true if code is a known currency.
M.is_valid_currency = function(code)
  return M.CURRENCIES[code] ~= nil
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- 10^n as an exact integer.
local function pow10(n)
  local r = 1
  for _ = 1, n do r = r * 10 end
  return r
end

-- Round x to nearest integer (half-up).
local function round(x)
  return math.floor(x + 0.5)
end

-- ---------------------------------------------------------------------------
-- Money value metatable
-- ---------------------------------------------------------------------------

local money_mt = {}
money_mt.__index = money_mt

local function make_money(amount_minor, currency)
  return setmetatable({ amount_minor = amount_minor, currency = currency }, money_mt)
end

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

-- M.new(amount, currency) -> money
-- amount: integer (minor units) OR string "12.34"
M.new = function(amount, currency)
  if not M.is_valid_currency(currency) then
    return nil, "money: unknown currency: " .. tostring(currency)
  end
  if type(amount) == "number" then
    if amount ~= math.floor(amount) then
      return nil, "money: amount must be integer minor units; use from_string or from_float for decimal values"
    end
    return make_money(amount, currency)
  elseif type(amount) == "string" then
    return M.from_string(amount, currency)
  end
  return nil, "money: amount must be a number or string"
end

-- M.of(major, minor_part, currency) -> money  e.g. M.of(12, 34, "USD") -> $12.34
M.of = function(major, minor_part, currency)
  if not M.is_valid_currency(currency) then
    return nil, "money: unknown currency: " .. tostring(currency)
  end
  local meta = M.CURRENCIES[currency]
  local scale = pow10(meta.decimals)
  if minor_part < 0 or minor_part >= scale then
    return nil, "money: minor_part out of range for " .. currency
  end
  local sign = 1
  if major < 0 then sign = -1; major = -major end
  return make_money(sign * (major * scale + minor_part), currency)
end

-- M.from_string("12.34", "USD") -> money or (nil, err)
M.from_string = function(s, currency)
  if not M.is_valid_currency(currency) then
    return nil, "money: unknown currency: " .. tostring(currency)
  end
  local meta = M.CURRENCIES[currency]
  local decimals = meta.decimals

  s = s:match("^%s*(.-)%s*$")

  local sign = 1
  if s:sub(1, 1) == "-" then
    sign = -1
    s = s:sub(2)
  end

  local int_part, frac_part = s:match("^(%d+)%.(%d*)$")
  if not int_part then
    int_part = s:match("^(%d+)$")
    if not int_part then
      return nil, "money: invalid amount string: " .. tostring(s)
    end
    frac_part = ""
  end

  -- Pad or truncate frac_part to exactly `decimals` digits, rounding last.
  if #frac_part < decimals then
    frac_part = frac_part .. string.rep("0", decimals - #frac_part)
  elseif #frac_part > decimals then
    local kept = frac_part:sub(1, decimals)
    local next_digit = tonumber(frac_part:sub(decimals + 1, decimals + 1)) or 0
    local minor = tonumber(kept) or 0
    if next_digit >= 5 then minor = minor + 1 end
    frac_part = string.format("%0" .. decimals .. "d", minor)
  end

  local major = tonumber(int_part) or 0
  local minor_val = (decimals > 0) and (tonumber(frac_part) or 0) or 0
  local scale = pow10(decimals)
  return make_money(sign * (major * scale + minor_val), currency)
end

-- M.from_float(12.34, "USD") -> money (rounds to minor units)
M.from_float = function(f, currency)
  if not M.is_valid_currency(currency) then
    return nil, "money: unknown currency: " .. tostring(currency)
  end
  local meta = M.CURRENCIES[currency]
  local scale = pow10(meta.decimals)
  return make_money(round(f * scale), currency)
end

-- ---------------------------------------------------------------------------
-- Arithmetic operators (throw on currency mismatch — callers use pcall or
-- the M.add/sub/mul/div safe wrappers for (nil, err) style)
-- ---------------------------------------------------------------------------

money_mt.__add = function(a, b)
  if a.currency ~= b.currency then
    error("money: currency mismatch: " .. a.currency .. " vs " .. b.currency, 2)
  end
  return make_money(a.amount_minor + b.amount_minor, a.currency)
end

money_mt.__sub = function(a, b)
  if a.currency ~= b.currency then
    error("money: currency mismatch: " .. a.currency .. " vs " .. b.currency, 2)
  end
  return make_money(a.amount_minor - b.amount_minor, a.currency)
end

-- money * number  (commutative)
money_mt.__mul = function(a, b)
  if type(a) == "number" then a, b = b, a end
  return make_money(round(a.amount_minor * b), a.currency)
end

money_mt.__div = function(a, b)
  return make_money(round(a.amount_minor / b), a.currency)
end

money_mt.__unm = function(a)
  return make_money(-a.amount_minor, a.currency)
end

-- Safe wrappers returning (nil, err) on currency mismatch.
M.add = function(a, b)
  if a.currency ~= b.currency then
    return nil, "money: currency mismatch: " .. a.currency .. " vs " .. b.currency
  end
  return make_money(a.amount_minor + b.amount_minor, a.currency)
end

M.sub = function(a, b)
  if a.currency ~= b.currency then
    return nil, "money: currency mismatch: " .. a.currency .. " vs " .. b.currency
  end
  return make_money(a.amount_minor - b.amount_minor, a.currency)
end

M.mul = function(a, n)
  return make_money(round(a.amount_minor * n), a.currency)
end

M.div = function(a, n)
  return make_money(round(a.amount_minor / n), a.currency)
end

-- ---------------------------------------------------------------------------
-- Instance arithmetic methods
-- ---------------------------------------------------------------------------

money_mt.negate = function(self)
  return make_money(-self.amount_minor, self.currency)
end

money_mt.abs = function(self)
  local v = self.amount_minor
  return make_money(v < 0 and -v or v, self.currency)
end

-- ---------------------------------------------------------------------------
-- Comparison
-- ---------------------------------------------------------------------------

money_mt.eq = function(self, other)
  return self.currency == other.currency and self.amount_minor == other.amount_minor
end

money_mt.lt = function(self, other)
  if self.currency ~= other.currency then
    error("money: currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return self.amount_minor < other.amount_minor
end

money_mt.le = function(self, other)
  if self.currency ~= other.currency then
    error("money: currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return self.amount_minor <= other.amount_minor
end

money_mt.gt = function(self, other)
  if self.currency ~= other.currency then
    error("money: currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return self.amount_minor > other.amount_minor
end

money_mt.ge = function(self, other)
  if self.currency ~= other.currency then
    error("money: currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return self.amount_minor >= other.amount_minor
end

money_mt.is_zero     = function(self) return self.amount_minor == 0 end
money_mt.is_positive = function(self) return self.amount_minor > 0 end
money_mt.is_negative = function(self) return self.amount_minor < 0 end

-- ---------------------------------------------------------------------------
-- Allocation
-- ---------------------------------------------------------------------------

-- money:allocate(ratios) -> { money }
-- Largest-remainder method so that sum(result) == self exactly.
money_mt.allocate = function(self, ratios)
  local total = self.amount_minor
  local n = #ratios
  local ratio_sum = 0
  for i = 1, n do ratio_sum = ratio_sum + ratios[i] end

  local floored = {}
  local remainders = {}
  local sum_floored = 0
  for i = 1, n do
    local exact = total * ratios[i] / ratio_sum
    local f = math.floor(exact)
    floored[i] = f
    remainders[i] = { idx = i, rem = exact - f }
    sum_floored = sum_floored + f
  end

  local leftover = total - sum_floored
  table.sort(remainders, function(a, b)
    if a.rem ~= b.rem then return a.rem > b.rem end
    return a.idx < b.idx
  end)

  local step = leftover >= 0 and 1 or -1
  local count = math.abs(leftover)
  for i = 1, count do
    floored[remainders[i].idx] = floored[remainders[i].idx] + step
  end

  local result = {}
  for i = 1, n do
    result[i] = make_money(floored[i], self.currency)
  end
  return result
end

-- money:split(n) -> { money }  (equal n-way split, remainder to first slices)
money_mt.split = function(self, n)
  local ratios = {}
  for i = 1, n do ratios[i] = 1 end
  return self:allocate(ratios)
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function add_thousands(s, sep)
  sep = sep or ","
  local result = ""
  local len = #s
  local offset = len % 3
  if offset == 0 then offset = 3 end
  result = s:sub(1, offset)
  for i = offset + 1, len, 3 do
    result = result .. sep .. s:sub(i, i + 2)
  end
  return result
end

-- money:format(opts) -> string
-- opts: { symbol=true, thousands=true, locale="en_US" }
money_mt.format = function(self, opts)
  opts = opts or {}
  local meta = M.CURRENCIES[self.currency]
  local decimals = meta.decimals
  local scale = pow10(decimals)

  local amount = self.amount_minor
  local neg = amount < 0
  if neg then amount = -amount end

  local major = math.floor(amount / scale)
  local minor_val = amount % scale

  local major_str = tostring(major)
  if opts.thousands ~= false and opts.thousands then
    major_str = add_thousands(major_str)
  end

  local formatted
  if decimals > 0 then
    formatted = major_str .. "." .. string.format("%0" .. decimals .. "d", minor_val)
  else
    formatted = major_str
  end

  if opts.symbol ~= false then
    local sym = meta.symbol
    if meta.symbol_before then
      formatted = sym .. formatted
    else
      formatted = formatted .. " " .. sym
    end
  end

  if neg then formatted = "-" .. formatted end
  return formatted
end

-- money:to_string() -> "12.34 USD"
money_mt.to_string = function(self)
  local meta = M.CURRENCIES[self.currency]
  local decimals = meta.decimals
  local scale = pow10(decimals)

  local amount = self.amount_minor
  local neg = amount < 0
  if neg then amount = -amount end

  local major = math.floor(amount / scale)
  local minor_val = amount % scale

  local s
  if decimals > 0 then
    s = tostring(major) .. "." .. string.format("%0" .. decimals .. "d", minor_val)
  else
    s = tostring(major)
  end

  if neg then s = "-" .. s end
  return s .. " " .. self.currency
end

money_mt.__tostring = money_mt.to_string

-- money:to_float() -> number (lossy)
money_mt.to_float = function(self)
  local meta = M.CURRENCIES[self.currency]
  local scale = pow10(meta.decimals)
  return self.amount_minor / scale
end

-- money:to_minor() -> integer
money_mt.to_minor = function(self)
  return self.amount_minor
end

-- ---------------------------------------------------------------------------
-- Exchange
-- ---------------------------------------------------------------------------

-- M.convert(money, target_currency, rate) -> money
-- rate: units of target per 1 unit of source (e.g. 1.08 for USD->EUR at 1.08 EUR/USD)
M.convert = function(src, target_currency, rate)
  if not M.is_valid_currency(target_currency) then
    return nil, "money: unknown currency: " .. tostring(target_currency)
  end
  local src_meta = M.CURRENCIES[src.currency]
  local tgt_meta = M.CURRENCIES[target_currency]
  local src_scale = pow10(src_meta.decimals)
  local tgt_scale = pow10(tgt_meta.decimals)
  -- (amount_minor / src_scale) * rate * tgt_scale
  local result_minor = round(src.amount_minor * rate * tgt_scale / src_scale)
  return make_money(result_minor, target_currency)
end

return M
