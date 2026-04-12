-- lib/money: monetary arithmetic with exact decimal semantics
-- Representation: {amount=integer (minor units), currency=string}
-- No floating point in arithmetic paths.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ISO 4217 major currencies subset
M.currencies = {
  USD = { symbol = "$",  decimals = 2, name = "US Dollar"          },
  EUR = { symbol = "€",  decimals = 2, name = "Euro"               },
  GBP = { symbol = "£",  decimals = 2, name = "British Pound"      },
  JPY = { symbol = "¥",  decimals = 0, name = "Japanese Yen"       },
  CNY = { symbol = "¥",  decimals = 2, name = "Chinese Yuan"       },
  CHF = { symbol = "Fr", decimals = 2, name = "Swiss Franc"        },
  CAD = { symbol = "CA$",decimals = 2, name = "Canadian Dollar"    },
  AUD = { symbol = "A$", decimals = 2, name = "Australian Dollar"  },
  HKD = { symbol = "HK$",decimals = 2, name = "Hong Kong Dollar"   },
  SGD = { symbol = "S$", decimals = 2, name = "Singapore Dollar"   },
  SEK = { symbol = "kr", decimals = 2, name = "Swedish Krona"      },
  NOK = { symbol = "kr", decimals = 2, name = "Norwegian Krone"    },
  DKK = { symbol = "kr", decimals = 2, name = "Danish Krone"       },
  NZD = { symbol = "NZ$",decimals = 2, name = "New Zealand Dollar" },
  MXN = { symbol = "$",  decimals = 2, name = "Mexican Peso"       },
  BRL = { symbol = "R$", decimals = 2, name = "Brazilian Real"     },
  INR = { symbol = "₹",  decimals = 2, name = "Indian Rupee"       },
  KRW = { symbol = "₩",  decimals = 0, name = "South Korean Won"   },
  TRY = { symbol = "₺",  decimals = 2, name = "Turkish Lira"       },
  ZAR = { symbol = "R",  decimals = 2, name = "South African Rand" },
  RUB = { symbol = "₽",  decimals = 2, name = "Russian Ruble"      },
  SAR = { symbol = "﷼",  decimals = 2, name = "Saudi Riyal"        },
}

-- symbol → currency code lookup (built once)
local symbol_to_code = {}
for code, info in pairs(M.currencies) do
  -- only map unique symbols to avoid ambiguity; $ is USD by convention
  if not symbol_to_code[info.symbol] then
    symbol_to_code[info.symbol] = code
  end
end
-- ensure $ maps to USD (override CNY ¥ clash, etc.)
symbol_to_code["$"]  = "USD"
symbol_to_code["¥"]  = "JPY"
symbol_to_code["kr"] = "SEK"

-- ─── internal helpers ────────────────────────────────────────────────────────

local function decimals_for(currency)
  local info = M.currencies[currency]
  return info and info.decimals or 2
end

-- 10^n for small n (exact integer)
local function pow10(n)
  local r = 1
  for _ = 1, n do r = r * 10 end
  return r
end

-- Parse a decimal string like "10.99" into minor units (integer).
-- e.g. string_to_minor("10.99", 2) → 1099
--      string_to_minor("10",    2) → 1000
--      string_to_minor("10.9",  2) → 1090
local function string_to_minor(s, dec)
  local neg = false
  if s:sub(1,1) == "-" then neg = true; s = s:sub(2) end
  local int_part, frac_part = s:match("^(%d*)%.?(%d*)$")
  if not int_part then return nil, "invalid decimal string: " .. s end
  frac_part = frac_part or ""
  -- pad or truncate fraction to exactly `dec` digits
  if #frac_part < dec then
    frac_part = frac_part .. string.rep("0", dec - #frac_part)
  elseif #frac_part > dec then
    frac_part = frac_part:sub(1, dec)
  end
  local combined = (int_part == "" and "0" or int_part) .. frac_part
  local amount = tonumber(combined)
  if not amount then return nil, "invalid decimal string: " .. s end
  if neg then amount = -amount end
  return amount
end

-- Convert minor units → decimal string (e.g. 1099, 2 → "10.99")
local function minor_to_string(amount, dec)
  local neg = amount < 0
  if neg then amount = -amount end
  if dec == 0 then
    return (neg and "-" or "") .. tostring(amount)
  end
  local factor = pow10(dec)
  local int_part = math.floor(amount / factor)
  local frac_part = amount % factor
  local frac_str = string.format("%0" .. dec .. "d", frac_part)
  return (neg and "-" or "") .. tostring(int_part) .. "." .. frac_str
end

-- ─── money metatable ─────────────────────────────────────────────────────────

local money_mt = {}
money_mt.__index = money_mt

function money_mt:__tostring()
  return self:format()
end

function money_mt:__eq(other)
  return self.amount == other.amount and self.currency == other.currency
end

function money_mt:__lt(other)
  if self.currency ~= other.currency then
    error("currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return self.amount < other.amount
end

function money_mt:__le(other)
  if self.currency ~= other.currency then
    error("currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return self.amount <= other.amount
end

function money_mt:__add(other)
  if self.currency ~= other.currency then
    error("currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return M.money(self.amount + other.amount, self.currency)
end

function money_mt:__sub(other)
  if self.currency ~= other.currency then
    error("currency mismatch: " .. self.currency .. " vs " .. other.currency, 2)
  end
  return M.money(self.amount - other.amount, self.currency)
end

function money_mt:__mul(scalar)
  if type(scalar) ~= "number" then
    error("multiply operand must be a number", 2)
  end
  -- Use integer rounding: round half-up
  local raw = self.amount * scalar
  local rounded = math.floor(raw + 0.5)
  return M.money(rounded, self.currency)
end

function money_mt:__div(scalar)
  if type(scalar) ~= "number" then
    error("divide operand must be a number", 2)
  end
  if scalar == 0 then error("division by zero", 2) end
  local raw = self.amount / scalar
  local rounded = math.floor(raw + 0.5)
  return M.money(rounded, self.currency)
end

-- ─── rounding ────────────────────────────────────────────────────────────────
-- money:round(mode) returns a new money value in the same currency, normalised
-- to integer minor units (removing any sub-minor-unit fraction stored internally).
-- The internal representation is always integers so round() is a no-op on normal
-- values; it's exposed for completeness and for values derived from division that
-- may have been rounded by __div already.  The primary use is converting from a
-- "higher precision" amount (e.g. amount stored with extra decimal places).

function money_mt:round(mode)
  mode = mode or "half_up"
  local amt = self.amount
  -- amount is already an integer — round() is idempotent for normal values.
  -- For documentation, we implement all modes against the integer amount.
  local result
  if mode == "half_up" then
    result = math.floor(amt + 0.5)
  elseif mode == "half_even" then
    -- banker's rounding
    local fl = math.floor(amt)
    local frac = amt - fl
    if frac == 0.5 then
      result = (fl % 2 == 0) and fl or fl + 1
    else
      result = math.floor(amt + 0.5)
    end
  elseif mode == "ceil" then
    result = math.ceil(amt)
  elseif mode == "floor" then
    result = math.floor(amt)
  else
    error("unknown rounding mode: " .. tostring(mode), 2)
  end
  return M.money(result, self.currency)
end

-- ─── formatting ──────────────────────────────────────────────────────────────

function money_mt:format(opts)
  opts = opts or {}
  local dec = decimals_for(self.currency)
  local info = M.currencies[self.currency]
  local num_str = minor_to_string(self.amount, dec)

  -- thousands separator
  if opts.thousands then
    local neg = num_str:sub(1,1) == "-"
    local s = neg and num_str:sub(2) or num_str
    local int_s, frac_s = s:match("^(%d+)(%.?%d*)$")
    -- insert commas
    local out = {}
    local len = #int_s
    for i = 1, len do
      out[#out+1] = int_s:sub(i,i)
      local pos_from_right = len - i
      if pos_from_right > 0 and pos_from_right % 3 == 0 then
        out[#out+1] = ","
      end
    end
    num_str = (neg and "-" or "") .. table.concat(out) .. (frac_s or "")
  end

  if opts.symbol == false then
    return num_str .. " " .. self.currency
  else
    local sym = (info and info.symbol) or self.currency
    return sym .. num_str
  end
end

-- ─── split / allocate ────────────────────────────────────────────────────────

function money_mt:split(n)
  if type(n) ~= "number" or n < 1 or math.floor(n) ~= n then
    error("split: n must be a positive integer", 2)
  end
  local base = math.floor(self.amount / n)
  local remainder = self.amount - base * n
  local parts = {}
  for i = 1, n do
    -- distribute remainder one penny at a time to the first parts
    local extra = (i <= remainder) and 1 or 0
    parts[i] = M.money(base + extra, self.currency)
  end
  return parts
end

function money_mt:allocate(ratios)
  if type(ratios) ~= "table" or #ratios == 0 then
    error("allocate: ratios must be a non-empty array", 2)
  end
  local total_ratio = 0
  for _, r in ipairs(ratios) do total_ratio = total_ratio + r end
  if total_ratio == 0 then error("allocate: sum of ratios must be non-zero", 2) end

  local total = self.amount
  local parts = {}
  local allocated = 0
  for i, r in ipairs(ratios) do
    if i == #ratios then
      parts[i] = M.money(total - allocated, self.currency)
    else
      local share = math.floor(total * r / total_ratio)
      parts[i] = M.money(share, self.currency)
      allocated = allocated + share
    end
  end
  return parts
end

-- ─── predicates ──────────────────────────────────────────────────────────────

function money_mt:is_zero()     return self.amount == 0 end
function money_mt:is_positive() return self.amount > 0  end
function money_mt:is_negative() return self.amount < 0  end

-- ─── public constructors ─────────────────────────────────────────────────────

-- M.money(amount, currency)
-- amount: integer (minor units) or string decimal (e.g. "10.99")
function M.money(amount, currency)
  if type(currency) ~= "string" or currency == "" then
    error("money: currency must be a non-empty string", 2)
  end
  currency = currency:upper()
  local int_amount
  if type(amount) == "number" then
    if math.floor(amount) ~= amount then
      error("money: integer minor-unit amount required; got " .. tostring(amount) ..
            " (use a string for decimal input)", 2)
    end
    int_amount = amount
  elseif type(amount) == "string" then
    local dec = decimals_for(currency)
    local v, err = string_to_minor(amount, dec)
    if not v then error("money: " .. (err or "parse error"), 2) end
    int_amount = v
  else
    error("money: amount must be a number or string", 2)
  end
  return setmetatable({ amount = int_amount, currency = currency }, money_mt)
end

-- M.parse(str) — parses strings like "$10.99", "10.99 USD", "EUR 5.00", "€10.99"
function M.parse(str)
  if type(str) ~= "string" then return nil, "parse: expected string" end
  str = str:match("^%s*(.-)%s*$") -- trim

  -- Try: symbol prefix (e.g. "$10.99", "€5.00")
  -- Symbols can be multi-byte UTF-8; try each known symbol
  for sym, code in pairs(symbol_to_code) do
    if str:sub(1, #sym) == sym then
      local rest = str:sub(#sym + 1)
      local dec = decimals_for(code)
      local v, err = string_to_minor(rest, dec)
      if v then return M.money(v, code) end
      return nil, "parse: " .. (err or "bad amount")
    end
  end

  -- Try: "10.99 USD" or "USD 10.99"
  local amount_str, code = str:match("^([%d%.%-]+)%s+(%u%u%u)$")
  if not amount_str then
    code, amount_str = str:match("^(%u%u%u)%s+([%d%.%-]+)$")
  end
  if amount_str and code then
    local dec = decimals_for(code)
    local v, err = string_to_minor(amount_str, dec)
    if v then return M.money(v, code) end
    return nil, "parse: " .. (err or "bad amount")
  end

  return nil, "parse: unrecognised format: " .. str
end

-- M.currency(code) → info table or nil
function M.currency(code)
  return M.currencies[code:upper()]
end

-- M.convert(money, to_currency, {rate}) → money
-- rate is in units of: 1 from-currency = rate to-currency
function M.convert(mon, to_currency, opts)
  if type(opts) ~= "table" or not opts.rate then
    return nil, "convert: opts.rate required"
  end
  to_currency = to_currency:upper()
  local from_dec = decimals_for(mon.currency)
  local to_dec   = decimals_for(to_currency)
  -- Convert: to_minor = from_minor * rate * (10^to_dec / 10^from_dec)
  local raw = mon.amount * opts.rate * pow10(to_dec) / pow10(from_dec)
  local result = math.floor(raw + 0.5)
  return M.money(result, to_currency)
end

return M
