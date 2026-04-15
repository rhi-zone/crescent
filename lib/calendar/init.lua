if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Name tables
M.MONTH_NAMES = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
}
M.WEEKDAY_NAMES = {
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"
}
M.MONTH_ABBR = {
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
}
M.WEEKDAY_ABBR = {
  "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"
}

local DAYS_IN_MONTH = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

local function is_leap(y)
  return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

local function days_in_month(y, m)
  if m == 2 and is_leap(y) then return 29 end
  return DAYS_IN_MONTH[m]
end

local function day_of_year(y, m, d)
  local n = 0
  for i = 1, m - 1 do
    n = n + days_in_month(y, i)
  end
  return n + d
end

-- Ordinal: days since 0001-01-01, where that date = 1
local function to_ordinal(y, m, d)
  local doy = day_of_year(y, m, d)
  local y1 = y - 1
  return 365 * y1
    + math.floor(y1 / 4)
    - math.floor(y1 / 100)
    + math.floor(y1 / 400)
    + doy
end

local function from_ordinal(n)
  -- Estimate year (400-year cycle = 146097 days)
  local n0 = n - 1
  local y400 = math.floor(n0 / 146097)
  local rem = n0 % 146097

  local y100 = math.floor(rem / 36524)
  if y100 == 4 then y100 = 3 end  -- last day of 400-year cycle
  rem = rem - y100 * 36524

  local y4 = math.floor(rem / 1461)
  rem = rem % 1461

  local y1 = math.floor(rem / 365)
  if y1 == 4 then y1 = 3 end  -- last day of 4-year cycle
  rem = rem - y1 * 365

  local year = y400 * 400 + y100 * 100 + y4 * 4 + y1 + 1
  -- rem is now 0-based day of year
  local doy = rem + 1

  -- Find month
  local month = 1
  while month < 12 and doy > days_in_month(year, month) do
    doy = doy - days_in_month(year, month)
    month = month + 1
  end
  return year, month, doy
end

-- Date metatable
local date_mt = {}
date_mt.__index = date_mt

function date_mt:is_leap_year()
  return is_leap(self.year)
end

function date_mt:days_in_month()
  return days_in_month(self.year, self.month)
end

function date_mt:day_of_year()
  return day_of_year(self.year, self.month, self.day)
end

function date_mt:to_ordinal()
  return to_ordinal(self.year, self.month, self.day)
end

-- ISO weekday: 1=Mon .. 7=Sun
-- 0001-01-01 was a Monday (ordinal=1), so:
--   ordinal % 7 == 1 → Monday
--   ordinal % 7 == 2 → Tuesday ... 0 → Sunday
function date_mt:day_of_week()
  local r = self:to_ordinal() % 7
  if r == 0 then return 7 end
  return r
end

-- ISO week number
-- ISO week 1 contains Jan 4. Week starts on Monday.
function date_mt:week_of_year()
  local ord = self:to_ordinal()
  local dow = self:day_of_week()  -- 1=Mon..7=Sun
  -- Start of ISO week containing this date
  local week_start = ord - (dow - 1)
  -- Jan 4 of this year's ordinal
  local jan4 = to_ordinal(self.year, 1, 4)
  -- Start of week containing Jan 4
  local jan4_dow = jan4 % 7
  if jan4_dow == 0 then jan4_dow = 7 end
  local w1_start = jan4 - (jan4_dow - 1)

  local week = math.floor((week_start - w1_start) / 7) + 1

  if week < 1 then
    -- Belongs to last week of previous year
    local jan4_prev = to_ordinal(self.year - 1, 1, 4)
    local jan4_prev_dow = jan4_prev % 7
    if jan4_prev_dow == 0 then jan4_prev_dow = 7 end
    local w1_prev = jan4_prev - (jan4_prev_dow - 1)
    return math.floor((week_start - w1_prev) / 7) + 1
  elseif week > 52 then
    -- Check if week 53 exists; otherwise belongs to week 1 of next year
    local jan4_next = to_ordinal(self.year + 1, 1, 4)
    local jan4_next_dow = jan4_next % 7
    if jan4_next_dow == 0 then jan4_next_dow = 7 end
    local w1_next = jan4_next - (jan4_next_dow - 1)
    if week_start >= w1_next then
      return 1
    end
  end

  return week
end

function date_mt:to_iso()
  return string.format("%04d-%02d-%02d", self.year, self.month, self.day)
end

function date_mt:__tostring()
  return self:to_iso()
end

function date_mt:__eq(b)
  return self.year == b.year and self.month == b.month and self.day == b.day
end

function date_mt:__lt(b)
  if self.year ~= b.year then return self.year < b.year end
  if self.month ~= b.month then return self.month < b.month end
  return self.day < b.day
end

function date_mt:__le(b)
  return self == b or self < b
end

function date_mt:__sub(b)
  return self:to_ordinal() - b:to_ordinal()
end

-- Internal constructor (no validation)
local function make_date(y, m, d)
  return setmetatable({year = y, month = m, day = d}, date_mt)
end

-- Validated public constructor
function M.date(year, month, day)
  if type(year) ~= "number" or type(month) ~= "number" or type(day) ~= "number" then
    return nil, "year, month, day must be numbers"
  end
  year = math.floor(year)
  month = math.floor(month)
  day = math.floor(day)
  if month < 1 or month > 12 then
    return nil, "month out of range: " .. month
  end
  local dim = days_in_month(year, month)
  if day < 1 or day > dim then
    return nil, "day out of range: " .. day .. " for month " .. month
  end
  return make_date(year, month, day)
end

function M.today(time_fn)
  local t = time_fn()
  return make_date(t.year, t.month, t.day)
end

function M.from_ordinal(n)
  local y, m, d = from_ordinal(n)
  return make_date(y, m, d)
end

function M.from_iso(s)
  if type(s) ~= "string" then
    return nil, "expected string"
  end
  local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return nil, "invalid ISO date format: " .. s
  end
  return M.date(tonumber(y), tonumber(m), tonumber(d))
end

function date_mt:add_days(n)
  return M.from_ordinal(self:to_ordinal() + n)
end

function date_mt:add_months(n)
  local y = self.year
  local m = self.month + n
  -- Normalize month
  y = y + math.floor((m - 1) / 12)
  m = ((m - 1) % 12) + 1
  -- Clamp day to valid range
  local d = math.min(self.day, days_in_month(y, m))
  return make_date(y, m, d)
end

function date_mt:add_years(n)
  local y = self.year + n
  local d = math.min(self.day, days_in_month(y, self.month))
  return make_date(y, self.month, d)
end

function date_mt:diff_days(b)
  return self:to_ordinal() - b:to_ordinal()
end

-- Range iterator: inclusive [start, stop], step_days default 1
function M.range(start, stop, step_days)
  step_days = step_days or 1
  local current = start
  local stop_ord = stop:to_ordinal()
  local forward = step_days > 0
  return function()
    local ord = current:to_ordinal()
    if forward and ord > stop_ord then return nil end
    if not forward and ord < stop_ord then return nil end
    local ret = current
    current = current:add_days(step_days)
    return ret
  end
end

-- Recurrence
local recur_mt = {}
recur_mt.__index = recur_mt

function M.recur(opts)
  local r = setmetatable({}, recur_mt)
  r._start = opts.start
  r._freq = opts.freq or "daily"
  r._interval = opts.interval or 1
  r._count = opts.count
  r._until = opts["until"]
  r._by_day = opts.by_day
  r._by_month_day = opts.by_month_day
  r:reset()
  return r
end

function recur_mt:reset()
  self._current = self._start
  self._n = 0
end

-- Check if a date matches by_day / by_month_day filters
local function matches_filters(d, by_day, by_month_day)
  if by_day then
    local dow = d:day_of_week()
    local found = false
    for _, v in ipairs(by_day) do
      if v == dow then found = true; break end
    end
    if not found then return false end
  end
  if by_month_day then
    local dom = d.day
    local found = false
    for _, v in ipairs(by_month_day) do
      if v == dom then found = true; break end
    end
    if not found then return false end
  end
  return true
end

function recur_mt:next()
  local freq = self._freq
  local interval = self._interval

  while true do
    local d = self._current
    if d == nil then return nil end

    -- Check count limit
    if self._count and self._n >= self._count then return nil end

    -- Check until limit
    if self._until and d > self._until then return nil end

    -- Advance current for next call
    if freq == "daily" then
      self._current = d:add_days(interval)
    elseif freq == "weekly" then
      self._current = d:add_days(interval * 7)
    elseif freq == "monthly" then
      self._current = d:add_months(interval)
    elseif freq == "yearly" then
      self._current = d:add_years(interval)
    else
      self._current = nil
    end

    -- Check filters
    if matches_filters(d, self._by_day, self._by_month_day) then
      self._n = self._n + 1
      return d
    end
  end
end

function recur_mt:take(n)
  local result = {}
  for i = 1, n do
    local d = self:next()
    if d == nil then break end
    result[i] = d
  end
  return result
end

function recur_mt:all()
  if not self._count and not self._until then
    return nil, "all() requires count or until to be set"
  end
  local result = {}
  while true do
    local d = self:next()
    if d == nil then break end
    result[#result + 1] = d
  end
  return result
end

-- Holidays / utilities
function M.is_weekend(d)
  local dow = d:day_of_week()
  return dow == 6 or dow == 7
end

-- Anonymous Gregorian algorithm for Easter
function M.easter(year)
  local a = year % 19
  local b = math.floor(year / 100)
  local c = year % 100
  local d = math.floor(b / 4)
  local e = b % 4
  local f = math.floor((b + 8) / 25)
  local g = math.floor((b - f + 1) / 3)
  local h = (19 * a + b - d - g + 15) % 30
  local i = math.floor(c / 4)
  local k = c % 4
  local l = (32 + 2 * e + 2 * i - h - k) % 7
  local m2 = math.floor((a + 11 * h + 22 * l) / 451)
  local month = math.floor((h + l - 7 * m2 + 114) / 31)
  local day = ((h + l - 7 * m2 + 114) % 31) + 1
  return make_date(year, month, day)
end

return M
