if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Cron expression parser and scheduler.
-- Supports standard 5-field and extended 6-field cron expressions.
-- Fields: [second] minute hour day-of-month month day-of-week
-- Supports *, n, n-m, */n, n-m/n, lists, named months/weekdays, @aliases.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local MONTH_NAMES = {
  jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
  jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

local DOW_NAMES = {
  sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6,
}

-- Predefined @aliases expand to standard 5-field expressions
local ALIASES = {
  ["@yearly"]   = "0 0 1 1 *",
  ["@annually"] = "0 0 1 1 *",
  ["@monthly"]  = "0 0 1 * *",
  ["@weekly"]   = "0 0 * * 0",
  ["@daily"]    = "0 0 * * *",
  ["@midnight"] = "0 0 * * *",
  ["@hourly"]   = "0 * * * *",
}

-- ---------------------------------------------------------------------------
-- Field parsing
-- ---------------------------------------------------------------------------

-- Resolve a token that may be a name or number, within [min, max].
-- Returns integer value or nil, errmsg.
--: (string, integer, integer, { [string]: integer } | nil) -> (integer | nil, string | nil)
local function resolve_value(token, min, max, names)
  local n = tonumber(token)
  if n then
    n = math.floor(n)
    if n < min or n > max then
      return nil, "value " .. token .. " out of range [" .. min .. "," .. max .. "]"
    end
    return n
  end
  if names then
    local key = token:lower()
    local v = names[key]
    if v then
      return v
    end
  end
  return nil, "invalid value: " .. token
end

-- Expand a single segment (no commas) into a sorted set of values.
-- Returns array or nil, errmsg.
--: (string, integer, integer, { [string]: integer } | nil) -> ({ [integer]: integer } | nil, string | nil)
local function expand_segment(seg, min, max, names)
  -- step suffix: anything/step or range/step
  local base, step_str = seg:match("^(.+)/(%d+)$")
  local step = 1 --: integer
  if base then
    local step_n = tonumber(step_str)
    if not step_n then
      return nil, "invalid step in: " .. seg
    end
    step = math.floor(step_n)
    if step < 1 then
      return nil, "invalid step in: " .. seg
    end
  else
    base = seg
  end

  local base_s = base --[[:! string]]
  local from, to
  if base_s == "*" then
    from = min
    to = max
  else
    local a, b = base_s:match("^([^%-]+)%-([^%-]+)$")
    if a then
      local va, ea = resolve_value(a, min, max, names)
      if not va then return nil, ea end
      local vb, eb = resolve_value(b, min, max, names)
      if not vb then return nil, eb end
      if va > vb then
        return nil, "range start " .. a .. " > end " .. b
      end
      from = va
      to = vb
    else
      -- single value
      local v, e = resolve_value(base_s, min, max, names)
      if not v then return nil, e end
      from = v
      to = v
    end
  end

  local result = {}
  for i = from, to, step do
    result[#result + 1] = i
  end
  return result
end

-- Parse a cron field string into a sorted, deduplicated array of integers.
-- min and max are the inclusive bounds. names is optional table of name->int.
-- Returns array or nil, errmsg.
--: (string, integer, integer, { [string]: integer } | nil) -> ({ [integer]: integer } | nil, string | nil)
function M.parse_field(field, min, max, names)
  if type(field) ~= "string" then
    return nil, "field must be a string"
  end
  -- Split on commas
  local seen = {}
  local result = {}
  for seg in field:gmatch("[^,]+") do
    local vals, err = expand_segment(seg, min, max, names)
    if not vals then return nil, err end
    for _, v in ipairs(vals) do
      if not seen[v] then
        seen[v] = true
        result[#result + 1] = v
      end
    end
  end
  if #result == 0 then
    return nil, "empty field: " .. field
  end
  table.sort(result)
  return result
end

-- ---------------------------------------------------------------------------
-- Expression parsing
-- ---------------------------------------------------------------------------

-- Returns fields table: {second?, minute, hour, dom, month, dow}
-- or nil, errmsg.
--: (string) -> (CronFields | nil, string | nil)
local function parse_fields(expr)
  local parts = {}
  for p in expr:gmatch("%S+") do
    parts[#parts + 1] = p
  end

  local second_field, minute_f, hour_f, dom_f, month_f, dow_f
  local off = 0

  if #parts == 6 then
    -- 6-field: second minute hour dom month dow
    local s, e = M.parse_field(parts[1], 0, 59)
    if not s then return nil, "second: " .. (e or "?") end
    second_field = s
    off = 1
  elseif #parts == 5 then
    off = 0
  else
    return nil, "expected 5 or 6 fields, got " .. #parts
  end

  local m, em = M.parse_field(parts[1 + off], 0, 59)
  if not m then return nil, "minute: " .. (em or "?") end
  minute_f = m

  local h, eh = M.parse_field(parts[2 + off], 0, 23)
  if not h then return nil, "hour: " .. (eh or "?") end
  hour_f = h

  local dom, edom = M.parse_field(parts[3 + off], 1, 31)
  if not dom then return nil, "day-of-month: " .. (edom or "?") end
  dom_f = dom

  local mo, emo = M.parse_field(parts[4 + off], 1, 12, MONTH_NAMES)
  if not mo then return nil, "month: " .. (emo or "?") end
  month_f = mo

  -- DOW: 0-7 where both 0 and 7 = Sunday
  local dow_raw, edow = M.parse_field(parts[5 + off], 0, 7, DOW_NAMES)
  if not dow_raw then return nil, "day-of-week: " .. (edow or "?") end
  -- Normalize 7 -> 0
  local dow_seen = {}
  local dow = {}
  for _, v in ipairs(dow_raw) do
    local nv = (v == 7) and 0 or v
    if not dow_seen[nv] then
      dow_seen[nv] = true
      dow[#dow + 1] = nv
    end
  end
  table.sort(dow)
  dow_f = dow

  local fields = {
    minute = minute_f,
    hour   = hour_f,
    dom    = dom_f,
    month  = month_f,
    dow    = dow_f,
  }
  if second_field then
    fields.second = second_field
  end

  return fields
end

-- ---------------------------------------------------------------------------
-- Schedule object
-- ---------------------------------------------------------------------------

--:: DateFn = (fmt: string, ts: integer) -> { year: integer, month: integer, day: integer, hour: integer, min: integer, sec: integer, wday: integer, ... }
--:: CronFields = { minute: { [integer]: integer }, hour: { [integer]: integer }, dom: { [integer]: integer }, month: { [integer]: integer }, dow: { [integer]: integer }, second: { [integer]: integer } | nil }
--:: Schedule = { fields: CronFields, _date_fn: DateFn, matches: (Schedule, integer) -> boolean, next: (Schedule, integer, integer | nil) -> integer | nil, prev: (Schedule, integer) -> integer | nil, range: (Schedule, integer, integer) -> { [integer]: integer }, describe: (Schedule) -> string, ... }


local Schedule = {}
Schedule.__index = Schedule

-- Check whether a given Unix timestamp matches this schedule.
--: (Schedule, integer) -> boolean
function Schedule:matches(ts)
  local self = self --[[:! Schedule]]
  local t = self._date_fn("*t", ts)
  -- Check month
  local month_ok = false
  for _, v in ipairs(self.fields.month) do
    if v == t.month then month_ok = true; break end
  end
  if not month_ok then return false end

  -- Check dom
  local dom_ok = false
  for _, v in ipairs(self.fields.dom) do
    if v == t.day then dom_ok = true; break end
  end
  if not dom_ok then return false end

  -- Check dow (os.date wday: 1=Sun..7=Sat; cron: 0=Sun..6=Sat)
  local cron_dow = t.wday - 1  -- 0=Sun..6=Sat
  local dow_ok = false
  for _, v in ipairs(self.fields.dow) do
    if v == cron_dow then dow_ok = true; break end
  end
  if not dow_ok then return false end

  -- Check hour
  local hour_ok = false
  for _, v in ipairs(self.fields.hour) do
    if v == t.hour then hour_ok = true; break end
  end
  if not hour_ok then return false end

  -- Check minute
  local min_ok = false
  for _, v in ipairs(self.fields.minute) do
    if v == t.min then min_ok = true; break end
  end
  if not min_ok then return false end

  -- Check second (if present)
  if self.fields.second then
    local sec_ok = false
    for _, v in ipairs(self.fields.second) do
      if v == t.sec then sec_ok = true; break end
    end
    if not sec_ok then return false end
  else
    -- 5-field: second must be 0
    if t.sec ~= 0 then return false end
  end

  return true
end

-- Advance the timestamp to the start of the next minute (or second for 6-field).
-- Used internally in next/prev search.
--: (integer, boolean, DateFn) -> integer
local function snap_forward(ts, has_seconds, date_fn)
  if has_seconds then
    return ts + 1
  end
  -- Round up to next minute boundary
  local t = date_fn("*t", ts)
  -- Clear seconds, advance by 1 minute
  return ts - t.sec + 60
end

--: (integer, boolean, DateFn) -> integer
local function snap_backward(ts, has_seconds, date_fn)
  if has_seconds then
    return ts - 1
  end
  -- Go back to the start of the current minute; if ts is already at sec=0
  -- (i.e. t.sec == 0), we need the previous minute instead.
  local t = date_fn("*t", ts)
  if t.sec == 0 then
    -- already at a minute boundary; step back one full minute
    return ts - 60
  else
    -- strip seconds to land on the start of this minute
    return ts - t.sec
  end
end

-- Find the n-th next occurrence after ts (exclusive).
-- Returns timestamp or nil if not found within 4 years.
--: (Schedule, integer, integer | nil) -> integer | nil
function Schedule:next(ts, n)
  local self = self --[[:! Schedule]]
  n = n or 1
  local has_sec = self.fields.second ~= nil
  local limit = ts + 4 * 365 * 24 * 3600
  local cur = (snap_forward(ts, has_sec, self._date_fn) --[[:! integer]])
  local found = 0
  while cur <= limit do
    if self:matches(cur) then
      found = found + 1
      if found == n then return cur end
      cur = (snap_forward(cur, has_sec, self._date_fn) --[[:! integer]])
    else
      cur = (snap_forward(cur, has_sec, self._date_fn) --[[:! integer]])
    end
  end
  return nil
end

-- Find the previous occurrence before ts (exclusive).
-- Returns timestamp or nil if not found within 4 years.
--: (Schedule, integer) -> integer | nil
function Schedule:prev(ts)
  local self = self --[[:! Schedule]]
  local has_sec = self.fields.second ~= nil
  local limit = ts - 4 * 365 * 24 * 3600
  local cur = (snap_backward(ts, has_sec, self._date_fn) --[[:! integer]])
  while cur >= limit do
    if self:matches(cur) then
      return cur
    end
    cur = (snap_backward(cur, has_sec, self._date_fn) --[[:! integer]])
  end
  return nil
end

-- Return all matching timestamps in [start_ts, end_ts] inclusive.
--: (Schedule, integer, integer) -> { [integer]: integer }
function Schedule:range(start_ts, end_ts)
  local self = self --[[:! Schedule]]
  local has_sec = self.fields.second ~= nil
  local result = {} --[[:! { [integer]: integer }]]
  -- Snap start to a candidate boundary
  local t = self._date_fn("*t", start_ts)
  local cur = (has_sec and start_ts or start_ts - t.sec) --[[:! integer]]
  while cur <= end_ts do
    if cur >= start_ts and self:matches(cur) then
      result[#result + 1] = cur
    end
    cur = (snap_forward(cur, has_sec, self._date_fn) --[[:! integer]])
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Human-readable description
-- ---------------------------------------------------------------------------

local MONTH_NAMES_REV = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}

local DOW_NAMES_REV = {
  [0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
}

--: ({ [integer]: integer }, { [integer]: string } | nil, integer, integer) -> string | nil
local function list_words(arr, names, full_range_min, full_range_max)
  if #arr == (full_range_max - full_range_min + 1) then
    return nil  -- means "every"
  end
  local parts = {}
  for _, v in ipairs(arr) do
    parts[#parts + 1] = names and names[v] or tostring(v)
  end
  -- Check for consecutive (range)
  if #arr == 2 then
    if arr[2] == arr[1] + 1 then
      return parts[1] .. " and " .. parts[2]
    end
  end
  if #arr >= 3 then
    -- Check if all consecutive
    local consec = true
    for i = 2, #arr do
      if arr[i] ~= arr[i-1] + 1 then consec = false; break end
    end
    if consec then
      return parts[1] .. " through " .. parts[#parts]
    end
  end
  if #arr == 1 then return parts[1] end
  -- List: join with commas and "and"
  local out = {}
  for i = 1, #parts - 1 do out[#out+1] = parts[i] end
  return table.concat(out, ", ") .. " and " .. parts[#parts]
end

--: (integer) -> string
local function ordinal(n)
  if n == 1 then return "1st"
  elseif n == 2 then return "2nd"
  elseif n == 3 then return "3rd"
  else return n .. "th"
  end
end

local function describe_minutes(mins)
  if #mins == 60 then return "every minute" end
  if #mins == 1 then
    if mins[1] == 0 then return "on the hour" end
    return "at minute " .. mins[1]
  end
  -- Check step pattern
  if #mins > 1 then
    local step = mins[2] - mins[1]
    local is_step = true
    for i = 2, #mins do
      if mins[i] - mins[i-1] ~= step then is_step = false; break end
    end
    if is_step and mins[1] == 0 then
      return "every " .. step .. " minutes"
    end
  end
  local parts = {}
  for _, v in ipairs(mins) do parts[#parts+1] = tostring(v) end
  return "at minutes " .. table.concat(parts, ", ")
end

local function pad2(n) return n < 10 and "0" .. n or tostring(n) end

local function format_time(hour, min)
  local suffix = "AM"
  local h = hour
  if h == 0 then h = 12
  elseif h == 12 then suffix = "PM"
  elseif h > 12 then h = h - 12; suffix = "PM"
  end
  return h .. ":" .. pad2(min) .. " " .. suffix
end

--: (Schedule) -> string
function Schedule:describe()
  local self = self --[[:! Schedule]]
  local f = self.fields
  local all_min   = #f.minute == 60
  local all_hour  = #f.hour == 24
  local all_dom   = #f.dom == 31
  local all_month = #f.month == 12
  local all_dow   = #f.dow == 7

  -- @yearly / @annually
  if #f.minute == 1 and f.minute[1] == 0 and
     #f.hour == 1 and f.hour[1] == 0 and
     #f.dom == 1 and f.dom[1] == 1 and
     #f.month == 1 and f.month[1] == 1 and all_dow then
    return "at midnight on January 1st"
  end

  -- @monthly
  if #f.minute == 1 and f.minute[1] == 0 and
     #f.hour == 1 and f.hour[1] == 0 and
     #f.dom == 1 and all_month and all_dow then
    return "at midnight on the " .. ordinal(f.dom[1]) .. " of every month"
  end

  -- Multiple doms + all dow + single time
  if not all_dom and all_dow and #f.hour == 1 and #f.minute == 1 and all_month then
    local dom_parts = {} --[[:! { [integer]: string }]]
    for _, v in ipairs(f.dom) do dom_parts[#dom_parts+1] = ordinal(v) end
    local dom_str = "" --: string
    if #dom_parts == 1 then
      dom_str = dom_parts[1]
    elseif #dom_parts == 2 then
      dom_str = dom_parts[1] .. " and " .. dom_parts[2]
    else
      local tmp = {} --[[:! { [integer]: string }]]
      for i = 1, #dom_parts - 1 do tmp[#tmp+1] = dom_parts[i] end
      dom_str = table.concat(tmp, ", ") .. " and " .. dom_parts[#dom_parts]
    end
    local time_str = format_time(f.hour[1], f.minute[1])
    if f.hour[1] == 0 and f.minute[1] == 0 then time_str = "midnight" end
    return "at " .. time_str .. " on the " .. dom_str .. " of every month"
  end

  -- @weekly: specific dow, midnight, all else *
  if #f.minute == 1 and f.minute[1] == 0 and
     #f.hour == 1 and f.hour[1] == 0 and
     all_dom and all_month and not all_dow then
    local dow_str = list_words(f.dow, DOW_NAMES_REV, 0, 6)
    return "at midnight on " .. (dow_str or "every day")
  end

  -- @daily / @midnight
  if #f.minute == 1 and f.minute[1] == 0 and
     #f.hour == 1 and f.hour[1] == 0 and
     all_dom and all_month and all_dow then
    return "every day at midnight"
  end

  -- @hourly: every hour, minute 0, all else *
  if #f.minute == 1 and f.minute[1] == 0 and
     all_hour and all_dom and all_month and all_dow then
    return "every hour"
  end

  -- Every-N-minutes with * elsewhere
  if all_hour and all_dom and all_month and all_dow then
    return describe_minutes(f.minute)
  end

  -- Specific time + specific dow
  if #f.hour == 1 and #f.minute == 1 and all_dom and all_month and not all_dow then
    local time_str = format_time(f.hour[1], f.minute[1])
    local dow_str = list_words(f.dow, DOW_NAMES_REV, 0, 6)
    return "at " .. time_str .. ", " .. (dow_str or "every day")
  end

  -- Specific time + all days
  if #f.hour == 1 and #f.minute == 1 and all_dom and all_month and all_dow then
    local time_str = format_time(f.hour[1], f.minute[1])
    return "daily at " .. time_str
  end

  -- Generic fallback
  local parts = {}
  parts[#parts + 1] = describe_minutes(f.minute)
  if not all_hour then
    local h = list_words(f.hour, nil, 0, 23)
    if h then parts[#parts + 1] = "hour " .. h end
  end
  if not all_dom then
    local d = list_words(f.dom, nil, 1, 31)
    if d then parts[#parts + 1] = "day " .. d end
  end
  if not all_month then
    local mo = list_words(f.month, MONTH_NAMES_REV, 1, 12)
    if mo then parts[#parts + 1] = "in " .. mo end
  end
  if not all_dow then
    local dw = list_words(f.dow, DOW_NAMES_REV, 0, 6)
    if dw then parts[#parts + 1] = "on " .. dw end
  end
  return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Parse a cron expression. Returns a Schedule object or nil, errmsg.
-- opts.date_fn: function compatible with os.date (required)
function M.parse(expr, opts)
  if type(expr) ~= "string" then
    return nil, "expression must be a string"
  end
  expr = expr:match("^%s*(.-)%s*$") or expr  -- trim (pattern always matches)

  -- Resolve aliases
  local alias = ALIASES[expr:lower()]
  if alias then expr = alias end

  local fields, err = parse_fields(expr --[[:! string]])
  if not fields then
    return nil, "invalid cron expression: " .. (err or "?")
  end

  local sched = setmetatable({ fields = fields, _date_fn = opts.date_fn }, Schedule)
  return sched
end

-- Validate a cron expression. Returns true or nil, errmsg.
function M.validate(expr)
  local _, err = M.parse(expr)
  if err then return nil, err end
  return true
end

return M
