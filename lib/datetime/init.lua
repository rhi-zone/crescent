if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Date/time parsing, formatting, and arithmetic.
-- Pure Lua implementation. No FFI required.
-- Internal representation: { year, month, day, hour, min, sec, offset }
-- offset = seconds from UTC (0 for UTC, nil for local/unspecified)

local M = {}

-- ── Leap year ────────────────────────────────────────────────────────────────

--: (number) -> boolean
local function is_leap(year)
  return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

M.is_leap = is_leap

-- Days in each month for a given year
--: (number, number) -> number
local function days_in_month(year, month)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and is_leap(year) then return 29 end
  return days[month]
end

M.days_in_month = days_in_month

-- ── Construction ─────────────────────────────────────────────────────────────

--: (number, number, number, number?, number?, number?, number?) -> { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }
function M.new(year, month, day, hour, min, sec, offset)
  return {
    year   = year   or 1970,
    month  = month  or 1,
    day    = day    or 1,
    hour   = hour   or 0,
    min    = min    or 0,
    sec    = sec    or 0,
    offset = offset,  -- nil = unspecified/local; 0 = UTC; else seconds east of UTC
  }
end

-- ── Current time ─────────────────────────────────────────────────────────────

--: (time_fn: () -> { year: number, month: number, day: number, hour: number, min: number, sec: number }) -> { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }
function M.now(time_fn)
  local t = time_fn()
  return {
    year   = t.year,
    month  = t.month,
    day    = t.day,
    hour   = t.hour,
    min    = t.min,
    sec    = t.sec,
    offset = nil,  -- local time, offset unspecified
  }
end

-- ── Validation ───────────────────────────────────────────────────────────────

--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }) -> boolean
function M.is_valid(dt)
  if type(dt) ~= "table" then return false end
  local y, mo, d = dt.year, dt.month, dt.day
  local h, mi, s = dt.hour, dt.min, dt.sec
  if type(y) ~= "number" or type(mo) ~= "number" or type(d) ~= "number" then return false end
  if type(h) ~= "number" or type(mi) ~= "number" or type(s) ~= "number" then return false end
  if mo < 1 or mo > 12 then return false end
  if d < 1 or d > days_in_month(y, mo) then return false end
  if h < 0 or h > 23 then return false end
  if mi < 0 or mi > 59 then return false end
  if s < 0 or s > 60 then return false end  -- 60 allows leap seconds
  if dt.offset ~= nil then
    if type(dt.offset) ~= "number" then return false end
    -- Offsets range: -14h to +14h in seconds
    if dt.offset < -50400 or dt.offset > 50400 then return false end
  end
  return true
end

-- ── Parsing ──────────────────────────────────────────────────────────────────

-- Parse a UTC offset string like "+05:30", "-07:00", "Z"
-- Returns offset in seconds, or nil, errmsg on failure
--: (string) -> number?, string?
local function parse_offset(s)
  if s == "Z" or s == "z" then return 0 end
  local sign, h, m = s:match("^([+-])(%d%d):?(%d%d)$")
  if not sign then return nil, "invalid offset: " .. s end
  local offset = (tonumber(h) * 3600 + tonumber(m) * 60)
  if sign == "-" then offset = -offset end
  return offset
end

-- Parse ISO 8601 date/datetime string.
-- Accepts:
--   2024-01-15
--   2024-01-15T10:30:00
--   2024-01-15T10:30:00Z
--   2024-01-15T10:30:00+05:30
--   2024-01-15 10:30:00  (space separator)
--: (string) -> { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }?, string?
function M.parse_iso(s)
  if type(s) ~= "string" then return nil, "expected string" end

  -- Date portion
  local y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not y then return nil, "invalid ISO 8601 date: " .. s end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)

  -- Time portion (optional)
  local h, mi, sc = 0, 0, 0
  local offset = nil
  local rest = s:sub(11)  -- after "YYYY-MM-DD"

  if rest ~= "" then
    -- Separator: T, t, or space
    local sep = rest:sub(1, 1)
    if sep ~= "T" and sep ~= "t" and sep ~= " " then
      return nil, "invalid ISO 8601 separator: " .. sep
    end
    rest = rest:sub(2)

    -- Time: HH:MM:SS or HH:MM:SS.frac
    local th, tm, ts, frac_rest = rest:match("^(%d%d):(%d%d):(%d%d)(.*)")
    if not th then
      -- Try HH:MM without seconds
      th, tm, frac_rest = rest:match("^(%d%d):(%d%d)(.*)")
      if not th then return nil, "invalid ISO 8601 time: " .. rest end
      ts = "00"
    end
    h, mi, sc = tonumber(th), tonumber(tm), tonumber(ts)

    -- Skip fractional seconds if present
    if frac_rest and frac_rest:sub(1,1) == "." then
      frac_rest = frac_rest:match("^%.[%d]+(.*)")
    end

    -- Offset
    if frac_rest and frac_rest ~= "" then
      local off, err = parse_offset(frac_rest)
      if not off then return nil, err end
      offset = off
    end
  end

  local dt = M.new(y, mo, d, h, mi, sc, offset)
  if not M.is_valid(dt) then
    return nil, "date out of range: " .. s
  end
  return dt
end

-- Parse a Unix timestamp (integer or float seconds since 1970-01-01T00:00:00Z).
--: (number, date_fn: (string, number) -> { year: number, month: number, day: number, hour: number, min: number, sec: number }) -> { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number }
function M.from_unix(ts, date_fn)
  -- Use date_fn with "!*t" to get UTC broken-down time
  local t = date_fn("!*t", math.floor(ts))
  return {
    year   = t.year,
    month  = t.month,
    day    = t.day,
    hour   = t.hour,
    min    = t.min,
    sec    = t.sec,
    offset = 0,  -- UTC
  }
end

-- ── Conversion to Unix timestamp ─────────────────────────────────────────────

-- Days since a proleptic Gregorian epoch — used for to_unix.
-- This is Julian Day Number-based arithmetic; avoids os.time quirks.
--: (number, number, number) -> number
local function ymd_to_days(y, m, d)
  -- Algorithm: civil date to serial day (days since 1970-01-01)
  -- From Howard Hinnant's date algorithms (public domain)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400                             -- [0, 399]
  local doy = math.floor((153 * (m <= 2 and m + 9 or m - 3) + 2) / 5) + d - 1  -- [0, 365]
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy    -- [0, 146096]
  return era * 146097 + doe - 719468  -- days since 1970-01-01
end

-- Convert datetime table to Unix timestamp (UTC seconds since epoch).
-- If offset is nil (local time), uses the dt fields as-is interpreted as UTC.
--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }) -> number
function M.to_unix(dt)
  local days = ymd_to_days(dt.year, dt.month, dt.day)
  local secs = days * 86400 + dt.hour * 3600 + dt.min * 60 + dt.sec
  -- Subtract offset: if offset=+05:30, wall clock is 5.5h ahead of UTC
  if dt.offset then
    secs = secs - dt.offset
  end
  return secs
end

-- ── Formatting ───────────────────────────────────────────────────────────────

--: (number, number) -> string
local function pad2(n) return string.format("%02d", n) end
--: (number, number) -> string
local function pad4(n) return string.format("%04d", n) end

-- Format offset as "+HH:MM", "-HH:MM", or "Z"
--: (number?) -> string
local function fmt_offset(offset)
  if offset == nil then return "" end
  if offset == 0 then return "Z" end
  local sign = offset >= 0 and "+" or "-"
  local abs = math.abs(offset)
  local h = math.floor(abs / 3600)
  local m = math.floor((abs % 3600) / 60)
  return sign .. pad2(h) .. ":" .. pad2(m)
end

-- ISO 8601 output.
--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }) -> string
function M.to_iso(dt)
  local date = pad4(dt.year) .. "-" .. pad2(dt.month) .. "-" .. pad2(dt.day)
  local time = pad2(dt.hour) .. ":" .. pad2(dt.min) .. ":" .. pad2(dt.sec)
  return date .. "T" .. time .. fmt_offset(dt.offset)
end

-- strftime-style formatting.
-- Supported: %Y %m %d %H %M %S %Z
-- %Z: "+HH:MM" / "-HH:MM" / "Z" / "" (unspecified)
--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }, string) -> string
function M.format(dt, fmt)
  return (fmt:gsub("%%(.)", function(c)
    if c == "Y" then return pad4(dt.year)
    elseif c == "m" then return pad2(dt.month)
    elseif c == "d" then return pad2(dt.day)
    elseif c == "H" then return pad2(dt.hour)
    elseif c == "M" then return pad2(dt.min)
    elseif c == "S" then return pad2(dt.sec)
    elseif c == "Z" then return fmt_offset(dt.offset)
    elseif c == "%" then return "%"
    else return "%" .. c
    end
  end))
end

-- ── Arithmetic ───────────────────────────────────────────────────────────────

-- Normalize a datetime: carry seconds/minutes/hours/days across field boundaries.
-- Operates on a mutable copy of dt (table).
--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }) -> { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }
local function normalize(dt)
  -- Normalize seconds -> minutes
  local carry = math.floor(dt.sec / 60)
  dt.sec = dt.sec % 60
  dt.min = dt.min + carry

  -- Normalize minutes -> hours
  carry = math.floor(dt.min / 60)
  dt.min = dt.min % 60
  dt.hour = dt.hour + carry

  -- Normalize hours -> days
  carry = math.floor(dt.hour / 24)
  dt.hour = dt.hour % 24
  dt.day = dt.day + carry

  -- Normalize months first so days_in_month is correct
  -- (handles negative months from subtraction)
  carry = math.floor((dt.month - 1) / 12)
  dt.month = ((dt.month - 1) % 12) + 1
  dt.year = dt.year + carry

  -- Normalize days (can be > or <= 0)
  -- Positive overflow: advance months
  while dt.day > days_in_month(dt.year, dt.month) do
    dt.day = dt.day - days_in_month(dt.year, dt.month)
    dt.month = dt.month + 1
    if dt.month > 12 then dt.month = 1; dt.year = dt.year + 1 end
  end
  -- Negative/zero underflow: retreat months
  while dt.day < 1 do
    dt.month = dt.month - 1
    if dt.month < 1 then dt.month = 12; dt.year = dt.year - 1 end
    dt.day = dt.day + days_in_month(dt.year, dt.month)
  end

  return dt
end

-- Add a duration to a datetime. Returns a new datetime.
-- Duration fields: years, months, days, hours, minutes, seconds (all optional, can be negative)
--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }, { years: number?, months: number?, days: number?, hours: number?, minutes: number?, seconds: number? }) -> { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }
function M.add(dt, dur)
  local result = {
    year   = dt.year   + (dur.years   or 0),
    month  = dt.month  + (dur.months  or 0),
    day    = dt.day    + (dur.days    or 0),
    hour   = dt.hour   + (dur.hours   or 0),
    min    = dt.min    + (dur.minutes or 0),
    sec    = dt.sec    + (dur.seconds or 0),
    offset = dt.offset,
  }
  return normalize(result)
end

-- Difference in seconds: dt1 - dt2.
-- If offsets are present, converts both to UTC before subtracting.
-- If offsets are absent (nil), treats both as being in the same timezone.
--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }, { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }) -> number
function M.diff(dt1, dt2)
  return M.to_unix(dt1) - M.to_unix(dt2)
end

-- Compare two datetimes. Returns -1, 0, or 1.
--: ({ year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }, { year: number, month: number, day: number, hour: number, min: number, sec: number, offset: number? }) -> number
function M.compare(dt1, dt2)
  local d = M.diff(dt1, dt2)
  if d < 0 then return -1
  elseif d > 0 then return 1
  else return 0
  end
end

return M
