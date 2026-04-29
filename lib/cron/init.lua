if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- field bounds: {min, max}
local FIELD_BOUNDS = {
  { 0, 59 },  -- minute
  { 0, 23 },  -- hour
  { 1, 31 },  -- day of month
  { 1, 12 },  -- month
  { 0, 6 },   -- day of week (0=Sun, 6=Sat)
}

local FIELD_NAMES = { "minute", "hour", "day-of-month", "month", "day-of-week" }

local MONTH_NAMES = {
  jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
  jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

local DOW_NAMES = {
  sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6,
}

local SHORTHANDS = {
  ["@yearly"]  = "0 0 1 1 *",
  ["@annually"] = "0 0 1 1 *",
  ["@monthly"] = "0 0 1 * *",
  ["@weekly"]  = "0 0 * * 0",
  ["@daily"]   = "0 0 * * *",
  ["@midnight"] = "0 0 * * *",
  ["@hourly"]  = "0 * * * *",
}

-- Resolve a name to a number for month/dow fields
local function resolve_name(s, field_idx)
  local low = s:lower()
  if field_idx == 4 then
    local v = MONTH_NAMES[low]
    if v then return v end
  elseif field_idx == 5 then
    local v = DOW_NAMES[low]
    if v then return v end
  end
  return nil
end

-- Parse a single value (number or name), return number or nil+err
local function parse_value(s, field_idx)
  local n = tonumber(s)
  if n then
    -- day-of-week 7 maps to 0 (Sunday)
    if field_idx == 5 and n == 7 then n = 0 end
    return n
  end
  local named = resolve_name(s, field_idx)
  if named then return named end
  return nil, "invalid value '" .. s .. "' in " .. FIELD_NAMES[field_idx] .. " field"
end

-- Parse a single field token into a set of valid values (as keys in a table)
-- Supports: *, N, N-M, */S, N-M/S, and comma-separated lists of any of these
local function parse_field(token, field_idx)
  local lo = FIELD_BOUNDS[field_idx][1]
  local hi = FIELD_BOUNDS[field_idx][2]
  local set = {}

  -- Split on commas
  for part in token:gmatch("[^,]+") do
    -- Check for step: X/S
    local base, step_str = part:match("^(.+)/(%d+)$")
    local step
    if step_str then
      step = tonumber(step_str)
      if not step or step == 0 then
        return nil, "invalid step '/" .. step_str .. "' in " .. FIELD_NAMES[field_idx] .. " field"
      end
    else
      base = part
    end

    if base == "*" then
      -- Wildcard, optionally with step
      local s = step or 1
      for v = lo, hi, s do
        set[v] = true
      end
    elseif base:find("-", 1, true) then
      -- Range: N-M
      local a_str, b_str = base:match("^([^-]+)-(.+)$")
      if not a_str then
        return nil, "invalid range '" .. base .. "' in " .. FIELD_NAMES[field_idx] .. " field"
      end
      local a, err = parse_value(a_str, field_idx)
      if not a then return nil, err end
      local b
      b, err = parse_value(b_str, field_idx)
      if not b then return nil, err end
      if a < lo or a > hi then
        return nil, "value " .. a .. " out of range for " .. FIELD_NAMES[field_idx] .. " field"
      end
      if b < lo or b > hi then
        return nil, "value " .. b .. " out of range for " .. FIELD_NAMES[field_idx] .. " field"
      end
      local s = step or 1
      if a <= b then
        for v = a, b, s do set[v] = true end
      else
        -- Wrap-around range (e.g., FRI-MON for dow)
        for v = a, hi, s do set[v] = true end
        for v = lo, b, s do set[v] = true end
      end
    else
      -- Single value
      if step then
        -- e.g. "5/2" means starting at 5, step 2
        local a, err = parse_value(base, field_idx)
        if not a then return nil, err end
        if a < lo or a > hi then
          return nil, "value " .. a .. " out of range for " .. FIELD_NAMES[field_idx] .. " field"
        end
        for v = a, hi, step do set[v] = true end
      else
        local a, err = parse_value(base, field_idx)
        if not a then return nil, err end
        if a < lo or a > hi then
          return nil, "value " .. a .. " out of range for " .. FIELD_NAMES[field_idx] .. " field"
        end
        set[a] = true
      end
    end
  end

  return set
end

-- Sorted array of keys from a set
local function sorted_keys(set)
  local arr = {}
  for k in pairs(set) do arr[#arr + 1] = k end
  table.sort(arr)
  return arr
end

-- Days in a given month/year
local function days_in_month(month, year)
  if month == 2 then
    if (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0) then
      return 29
    end
    return 28
  elseif month == 4 or month == 6 or month == 9 or month == 11 then
    return 30
  else
    return 31
  end
end

-- Expr methods
local Expr = {}
Expr.__index = Expr

--: (self: Expr, time: number) -> boolean
function Expr:matches(time)
  local t = self._date_fn("*t", time)
  local dow = t.wday - 1  -- os.date wday: 1=Sun, we use 0=Sun
  return self.minutes[t.min]
    and self.hours[t.hour]
    and self.doms[t.day]
    and self.months[t.month]
    and self.dows[dow]
    or false
end

--: (self: Expr) -> boolean
function Expr:matches_now()
  return self:matches(self._time_fn())
end

-- Find next valid value >= val in sorted array, or nil if none
local function next_valid(sorted, val)
  for i = 1, #sorted do
    if sorted[i] >= val then return sorted[i] end
  end
  return nil
end

-- Find previous valid value <= val in sorted array, or nil if none
local function prev_valid(sorted, val)
  for i = #sorted, 1, -1 do
    if sorted[i] <= val then return sorted[i] end
  end
  return nil
end

--: (self: Expr, time: number) -> number | nil
function Expr:next(time)
  -- Start from the next minute boundary
  local t = self._date_fn("*t", time)
  t.sec = 0
  -- Advance one minute
  local base = self._time_fn(t) + 60

  local sorted_min = sorted_keys(self.minutes)
  local sorted_hour = sorted_keys(self.hours)
  local sorted_dom = sorted_keys(self.doms)
  local sorted_month = sorted_keys(self.months)

  -- Limit: 4 years from base
  local limit = base + 4 * 366 * 86400

  local t2 = self._date_fn("*t", base)
  local year = t2.year
  local month = t2.month
  local day = t2.day
  local hour = t2.hour
  local min = t2.min

  -- Iterate through valid combinations
  local max_year = year + 4
  while year <= max_year do
    local m = next_valid(sorted_month, month)
    if not m then
      year = year + 1
      month = 1
      day = 1
      hour = 0
      min = 0
      goto continue_year
    end
    if m > month then
      day = 1
      hour = 0
      min = 0
    end
    month = m

    local d = next_valid(sorted_dom, day)
    if not d then
      month = month + 1
      day = 1
      hour = 0
      min = 0
      goto continue_year
    end
    if d > day then
      hour = 0
      min = 0
    end
    day = d

    -- Check day is valid for this month
    if day > days_in_month(month, year) then
      month = month + 1
      day = 1
      hour = 0
      min = 0
      goto continue_year
    end

    local h = next_valid(sorted_hour, hour)
    if not h then
      day = day + 1
      hour = 0
      min = 0
      goto continue_year
    end
    if h > hour then
      min = 0
    end
    hour = h

    do
      local mn = next_valid(sorted_min, min)
      if not mn then
        hour = hour + 1
        min = 0
        goto continue_year
      end
      min = mn

      -- Check day-of-week
      local candidate = self._time_fn({ year = year, month = month, day = day, hour = hour, min = min, sec = 0 })
      if candidate and candidate >= base and candidate <= limit then
        local ct = self._date_fn("*t", candidate)
        local dow = ct.wday - 1
        if self.dows[dow] then
          return candidate
        end
      elseif candidate and candidate > limit then
        return nil
      end

      -- This minute didn't match dow, try next minute
      min = min + 1
      if min > 59 then
        min = 0
        hour = hour + 1
        if hour > 23 then
          hour = 0
          day = day + 1
        end
      end
    end

    ::continue_year::
  end

  return nil
end

--: (self: Expr, time: number) -> number | nil
function Expr:prev(time)
  -- Start from the previous minute boundary
  local t = self._date_fn("*t", time)
  t.sec = 0
  local base = self._time_fn(t) - 60

  local sorted_min = sorted_keys(self.minutes)
  local sorted_hour = sorted_keys(self.hours)
  local sorted_dom = sorted_keys(self.doms)
  local sorted_month = sorted_keys(self.months)

  -- Limit: 4 years back
  local limit = base - 4 * 366 * 86400

  local t2 = self._date_fn("*t", base)
  local year = t2.year
  local month = t2.month
  local day = t2.day
  local hour = t2.hour
  local min = t2.min

  local min_year = year - 4
  while year >= min_year do
    local m = prev_valid(sorted_month, month)
    if not m then
      year = year - 1
      month = 12
      day = 31
      hour = 23
      min = 59
      goto continue_year
    end
    if m < month then
      day = 31
      hour = 23
      min = 59
    end
    month = m

    -- Clamp day to max for this month
    local max_day = days_in_month(month, year)
    if day > max_day then day = max_day end

    local d = prev_valid(sorted_dom, day)
    if not d then
      month = month - 1
      day = 31
      hour = 23
      min = 59
      goto continue_year
    end
    if d < day then
      hour = 23
      min = 59
    end
    day = d

    -- Check day is valid for this month
    if day > max_day then
      day = max_day
      goto continue_year
    end

    local h = prev_valid(sorted_hour, hour)
    if not h then
      day = day - 1
      hour = 23
      min = 59
      goto continue_year
    end
    if h < hour then
      min = 59
    end
    hour = h

    do
      local mn = prev_valid(sorted_min, min)
      if not mn then
        hour = hour - 1
        min = 59
        goto continue_year
      end
      min = mn

      local candidate = self._time_fn({ year = year, month = month, day = day, hour = hour, min = min, sec = 0 })
      if candidate and candidate <= base and candidate >= limit then
        local ct = self._date_fn("*t", candidate)
        local dow = ct.wday - 1
        if self.dows[dow] then
          return candidate
        end
      elseif candidate and candidate < limit then
        return nil
      end

      -- This minute didn't match dow, try previous minute
      min = min - 1
      if min < 0 then
        min = 59
        hour = hour - 1
        if hour < 0 then
          hour = 23
          day = day - 1
        end
      end
    end

    ::continue_year::
  end

  return nil
end

--: (self: Expr, time: number, n: number) -> { [number]: number }
function Expr:next_n(time, n)
  local results = {}
  local t = time
  for _ = 1, n do
    t = self:next(t)
    if not t then break end
    results[#results + 1] = t
  end
  return results
end

-- Human-readable descriptions

local DOW_LABELS = { [0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTH_LABELS = { "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December" }

local function is_star(set, lo, hi)
  for v = lo, hi do
    if not set[v] then return false end
  end
  return true
end

local function set_values(set)
  local arr = {}
  for k in pairs(set) do arr[#arr + 1] = k end
  table.sort(arr)
  return arr
end

-- Detect step pattern: values from lo to hi with constant step
local function detect_step(vals, lo, hi)
  if #vals < 2 then return nil end
  local step = vals[2] - vals[1]
  if step <= 0 then return nil end
  -- Verify all values match the pattern
  local expected = {}
  for v = lo, hi, step do expected[#expected + 1] = v end
  if #expected ~= #vals then return nil end
  for i = 1, #vals do
    if vals[i] ~= expected[i] then return nil end
  end
  return step
end

--: (self: Expr) -> string
function Expr:describe()
  local parts = {}

  local min_star = is_star(self.minutes, 0, 59)
  local hour_star = is_star(self.hours, 0, 23)
  local dom_star = is_star(self.doms, 1, 31)
  local month_star = is_star(self.months, 1, 12)
  local dow_star = is_star(self.dows, 0, 6)

  local min_vals = set_values(self.minutes)
  local hour_vals = set_values(self.hours)
  local dom_vals = set_values(self.doms)
  local dow_vals = set_values(self.dows)

  -- Time part
  if min_star and hour_star then
    parts[#parts + 1] = "every minute"
  elseif min_star and not hour_star then
    local min_step = detect_step(min_vals, 0, 59)
    if min_step then
      parts[#parts + 1] = "every " .. min_step .. " minutes"
    else
      parts[#parts + 1] = "every minute"
    end
    if #hour_vals == 1 then
      parts[#parts + 1] = "past hour " .. hour_vals[1]
    end
  elseif not min_star and hour_star then
    local min_step = detect_step(min_vals, 0, 59)
    if min_step then
      parts[#parts + 1] = "every " .. min_step .. " minutes"
    elseif #min_vals == 1 then
      parts[#parts + 1] = string.format("at %d minutes past every hour", min_vals[1])
    else
      local strs = {}
      for _, v in ipairs(min_vals) do strs[#strs + 1] = tostring(v) end
      parts[#parts + 1] = "at minutes " .. table.concat(strs, ", ") .. " past every hour"
    end
  else
    -- Specific time(s)
    local min_step = detect_step(min_vals, 0, 59)
    if min_step and #hour_vals > 0 then
      parts[#parts + 1] = "every " .. min_step .. " minutes"
    elseif #min_vals == 1 and #hour_vals == 1 then
      parts[#parts + 1] = string.format("at %02d:%02d", hour_vals[1], min_vals[1])
    elseif #hour_vals == 1 then
      local strs = {}
      for _, v in ipairs(min_vals) do strs[#strs + 1] = string.format(":%02d", v) end
      parts[#parts + 1] = string.format("at %02d", hour_vals[1]) .. table.concat(strs, ", ")
    else
      parts[#parts + 1] = "at specified times"
    end
  end

  -- Day-of-month
  if not dom_star then
    if #dom_vals == 1 then
      parts[#parts + 1] = "on day " .. dom_vals[1]
    else
      local strs = {}
      for _, v in ipairs(dom_vals) do strs[#strs + 1] = tostring(v) end
      parts[#parts + 1] = "on days " .. table.concat(strs, ", ")
    end
  end

  -- Month
  if not month_star then
    local month_vals = set_values(self.months)
    if #month_vals == 1 then
      parts[#parts + 1] = "in " .. MONTH_LABELS[month_vals[1]]
    else
      local strs = {}
      for _, v in ipairs(month_vals) do strs[#strs + 1] = MONTH_LABELS[v] end
      parts[#parts + 1] = "in " .. table.concat(strs, ", ")
    end
  end

  -- Day-of-week
  if not dow_star then
    if #dow_vals == 5 and not self.dows[0] and not self.dows[6] then
      parts[#parts + 1] = "on weekdays"
    elseif #dow_vals == 2 and self.dows[0] and self.dows[6] then
      parts[#parts + 1] = "on weekends"
    elseif #dow_vals == 1 then
      parts[#parts + 1] = "on " .. DOW_LABELS[dow_vals[1]]
    else
      local strs = {}
      for _, v in ipairs(dow_vals) do strs[#strs + 1] = DOW_LABELS[v] end
      parts[#parts + 1] = "on " .. table.concat(strs, ", ")
    end
  end

  return table.concat(parts, " ")
end

--- Parse a 5-field cron expression.
-- opts.date_fn: function compatible with os.date (required)
-- opts.time_fn: function compatible with os.time (required)
--: (expr: string, opts: { date_fn: (string, (number | nil)) -> unknown, time_fn: ((unknown | nil)) -> number }) -> (Expr | nil, string | nil)
function M.parse(expr, opts)
  if type(expr) ~= "string" then
    return nil, "expected string, got " .. type(expr)
  end

  expr = expr:match("^%s*(.-)%s*$")  -- trim

  -- Check shorthands
  local expanded = SHORTHANDS[expr:lower()]
  if expanded then expr = expanded end

  -- Split into fields
  local fields = {}
  for field in expr:gmatch("%S+") do
    fields[#fields + 1] = field
  end

  if #fields ~= 5 then
    return nil, "expected 5 fields, got " .. #fields
  end

  local minutes, err = parse_field(fields[1], 1)
  if not minutes then return nil, err end

  local hours
  hours, err = parse_field(fields[2], 2)
  if not hours then return nil, err end

  local doms
  doms, err = parse_field(fields[3], 3)
  if not doms then return nil, err end

  local months
  months, err = parse_field(fields[4], 4)
  if not months then return nil, err end

  local dows
  dows, err = parse_field(fields[5], 5)
  if not dows then return nil, err end

  local self = setmetatable({
    minutes = minutes,
    hours = hours,
    doms = doms,
    months = months,
    dows = dows,
    _expr = expr,
    _date_fn = opts.date_fn,
    _time_fn = opts.time_fn,
  }, Expr)

  return self
end

M.Expr = Expr

return M
