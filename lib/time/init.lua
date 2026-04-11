if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/time — time and duration arithmetic for crescent.
-- Builds on the existing FFI-based mod.time() (microsecond wall clock).
-- Duration: stored as integer nanoseconds (Lua double; safe ~104 days at ns).
-- Timestamp: stored as integer Unix seconds + integer nanosecond sub-second.
-- Pure Lua; no FFI beyond the existing gettimeofday block.
-- M._tier = "ffi"  (for mod.time); duration/timestamp are pure Lua.

local ffi = require("ffi")

local M = {}
M._tier = "ffi"

-- ── FFI wall-clock (preserved from original) ─────────────────────────────────

if jit and jit.os == "Windows" then
  ffi.cdef [[
    typedef unsigned long DWORD;
    typedef struct _FILETIME {
      DWORD dwLowDateTime;
      DWORD dwHighDateTime;
    } FILETIME, *PFILETIME, *LPFILETIME;
    void GetSystemTimeAsFileTime(LPFILETIME lpSystemTimeAsFileTime);
  ]]
  local time_ffi = ffi.C
  local _tv = ffi.new("FILETIME[1]")
  --: () -> number
  M.time = function()
    time_ffi.GetSystemTimeAsFileTime(_tv)
    return tonumber((_tv[0].dwHighDateTime * 0x100000000ULL + _tv[0].dwLowDateTime) / 10000000ULL - 11644473600ULL)
  end
else
  -- Linux / macOS / BSD
  local ok = pcall(ffi.cdef, [[
    struct timeval {
      long tv_sec;
      long tv_usec;
    };
    struct timezone {
      int tz_minuteswest;
      int tz_dsttime;
    };
    void gettimeofday(struct timeval *tv, struct timezone *tz);
  ]])
  if ok then
    local time_ffi = ffi.C
    local _tv = ffi.new("struct timeval [1]")
    --: () -> number
    M.time = function()
      time_ffi.gettimeofday(_tv, nil)
      return tonumber(_tv[0].tv_sec) + tonumber(_tv[0].tv_usec) / 1000000
    end
  else
    -- Fallback: os.time() (integer seconds only)
    --: () -> number
    M.time = function() return os.time() + 0.0 end
  end
end

-- ── Constants ─────────────────────────────────────────────────────────────────

local NS_PER_US  = 1000
local NS_PER_MS  = 1000000
local NS_PER_S   = 1000000000
local NS_PER_MIN = 60000000000
local NS_PER_H   = 3600000000000
local NS_PER_DAY = 86400000000000

-- Unit name → nanoseconds multiplier
local UNIT_NS = {
  nanoseconds  = 1,        ns  = 1,
  microseconds = NS_PER_US, us  = NS_PER_US,
  milliseconds = NS_PER_MS, ms  = NS_PER_MS,
  seconds      = NS_PER_S,  s   = NS_PER_S,
  minutes      = NS_PER_MIN, min = NS_PER_MIN,
  hours        = NS_PER_H,  h   = NS_PER_H,  hr = NS_PER_H,
  days         = NS_PER_DAY, d   = NS_PER_DAY,
  -- singular forms
  nanosecond   = 1,
  microsecond  = NS_PER_US,
  millisecond  = NS_PER_MS,
  second       = NS_PER_S,
  minute       = NS_PER_MIN,
  hour         = NS_PER_H,
  day          = NS_PER_DAY,
}

-- ── Duration ──────────────────────────────────────────────────────────────────

local Duration = {}
Duration.__index = Duration

--: () -> number
function Duration:to_ns()    return self._ns end
--: () -> number
function Duration:to_us()    return self._ns / NS_PER_US end
--: () -> number
function Duration:to_ms()    return self._ns / NS_PER_MS end
--: () -> number
function Duration:to_s()     return self._ns / NS_PER_S end
--: () -> number
function Duration:to_minutes() return self._ns / NS_PER_MIN end
--: () -> number
function Duration:to_hours()   return self._ns / NS_PER_H end
--: () -> number
function Duration:to_days()    return self._ns / NS_PER_DAY end

--: () -> { days: number, hours: number, minutes: number, seconds: number, ms: number }
function Duration:components()
  local total_ns = math.abs(self._ns)
  local days    = math.floor(total_ns / NS_PER_DAY)
  local rem     = total_ns - days * NS_PER_DAY
  local hours   = math.floor(rem / NS_PER_H)
  rem = rem - hours * NS_PER_H
  local minutes = math.floor(rem / NS_PER_MIN)
  rem = rem - minutes * NS_PER_MIN
  local seconds = math.floor(rem / NS_PER_S)
  rem = rem - seconds * NS_PER_S
  local ms      = math.floor(rem / NS_PER_MS)
  return { days = days, hours = hours, minutes = minutes, seconds = seconds, ms = ms }
end

--: () -> Duration
function Duration:abs()
  return setmetatable({ _ns = math.abs(self._ns) }, Duration)
end

-- __unm
function Duration:__unm()
  return setmetatable({ _ns = -self._ns }, Duration)
end

-- __add
function Duration.__add(a, b)
  return setmetatable({ _ns = a._ns + b._ns }, Duration)
end

-- __sub
function Duration.__sub(a, b)
  return setmetatable({ _ns = a._ns - b._ns }, Duration)
end

-- __mul  (Duration * number  or  number * Duration)
function Duration.__mul(a, b)
  if type(a) == "number" then
    return setmetatable({ _ns = math.floor(a * b._ns) }, Duration)
  end
  return setmetatable({ _ns = math.floor(a._ns * b) }, Duration)
end

-- __div  (Duration / number)
function Duration.__div(a, b)
  return setmetatable({ _ns = math.floor(a._ns / b) }, Duration)
end

-- __eq
function Duration.__eq(a, b)
  return a._ns == b._ns
end

-- __lt
function Duration.__lt(a, b)
  return a._ns < b._ns
end

-- __le
function Duration.__le(a, b)
  return a._ns <= b._ns
end

-- format helpers
--: (number) -> string
local function fmt_int(n) return tostring(math.floor(n)) end

--: () -> string
function Duration:format()
  local c = self:components()
  local parts = {}
  if c.days > 0 then parts[#parts+1] = fmt_int(c.days) .. "d" end
  parts[#parts+1] = fmt_int(c.hours)   .. "h"
  parts[#parts+1] = fmt_int(c.minutes) .. "m"
  parts[#parts+1] = fmt_int(c.seconds) .. "s"
  local s = table.concat(parts, " ")
  if self._ns < 0 then s = "-" .. s end
  return s
end

--: () -> string
function Duration:format_short()
  local c = self:components()
  local parts = {}
  if c.days    > 0 then parts[#parts+1] = fmt_int(c.days)    .. "d" end
  if c.hours   > 0 then parts[#parts+1] = fmt_int(c.hours)   .. "h" end
  if c.minutes > 0 then parts[#parts+1] = fmt_int(c.minutes) .. "m" end
  if c.seconds > 0 then parts[#parts+1] = fmt_int(c.seconds) .. "s" end
  if c.ms      > 0 then parts[#parts+1] = fmt_int(c.ms)      .. "ms" end
  if #parts == 0 then
    -- sub-millisecond or exactly zero
    if self._ns == 0 then return "0s" end
    return fmt_int(self._ns) .. "ns"
  end
  local s = table.concat(parts, " ")
  if self._ns < 0 then s = "-" .. s end
  return s
end

--: () -> string
function Duration:format_precise()
  local c = self:components()
  local parts = {}
  if c.days > 0 then parts[#parts+1] = fmt_int(c.days) .. "d" end
  parts[#parts+1] = fmt_int(c.hours)   .. "h"
  parts[#parts+1] = fmt_int(c.minutes) .. "m"
  -- seconds with ms precision
  local sec_frac = string.format("%d.%03d", c.seconds, c.ms) .. "s"
  parts[#parts+1] = sec_frac
  local s = table.concat(parts, " ")
  if self._ns < 0 then s = "-" .. s end
  return s
end

Duration.__tostring = Duration.format

-- ── Duration constructors ─────────────────────────────────────────────────────

--: (number, string) -> Duration?, string?
function M.duration(amount, unit)
  local mul = UNIT_NS[unit]
  if not mul then return nil, "unknown duration unit: " .. tostring(unit) end
  return setmetatable({ _ns = math.floor(amount * mul) }, Duration)
end

--: (number) -> Duration
function M.duration_ns(ns)
  return setmetatable({ _ns = math.floor(ns) }, Duration)
end

--: (number) -> Duration
function M.duration_us(us)
  return setmetatable({ _ns = math.floor(us * NS_PER_US) }, Duration)
end

--: (number) -> Duration
function M.duration_ms(ms)
  return setmetatable({ _ns = math.floor(ms * NS_PER_MS) }, Duration)
end

--: (number) -> Duration
function M.duration_s(s)
  return setmetatable({ _ns = math.floor(s * NS_PER_S) }, Duration)
end

-- ── Duration parser ───────────────────────────────────────────────────────────
-- Parses strings like "5h30m15s", "1d 2h 30m", "500ms", "1.5h"

-- Token pattern: optional number (int or float) followed by a unit abbreviation
-- Supported tokens: d, h, hr, min, m, s, ms, us, ns
local PARSE_UNIT = {
  d   = NS_PER_DAY, day  = NS_PER_DAY, days  = NS_PER_DAY,
  h   = NS_PER_H,   hr   = NS_PER_H,   hour  = NS_PER_H,  hours = NS_PER_H,
  min = NS_PER_MIN, mins = NS_PER_MIN, minute = NS_PER_MIN, minutes = NS_PER_MIN,
  m   = NS_PER_MIN,
  s   = NS_PER_S,   sec  = NS_PER_S,   secs  = NS_PER_S,  second = NS_PER_S, seconds = NS_PER_S,
  ms  = NS_PER_MS,  millisecond = NS_PER_MS, milliseconds = NS_PER_MS,
  us  = NS_PER_US,  microsecond = NS_PER_US, microseconds = NS_PER_US,
  ns  = 1,          nanosecond  = 1,         nanoseconds  = 1,
}

--: (string) -> Duration?, string?
function M.duration_parse(s)
  if type(s) ~= "string" then return nil, "expected string" end
  local total_ns = 0
  local pos = 1
  local len = #s
  local matched_any = false

  while pos <= len do
    -- skip whitespace
    local _, e = s:find("^%s+", pos)
    if e then pos = e + 1 end
    if pos > len then break end

    -- optional sign
    local sign = 1
    if s:sub(pos, pos) == "-" then sign = -1; pos = pos + 1
    elseif s:sub(pos, pos) == "+" then pos = pos + 1 end

    -- number (integer or float)
    local num_s, ne = s:match("^(%d+%.?%d*)()", pos)
    if not num_s then
      return nil, "expected number at position " .. pos .. " in: " .. s
    end
    pos = ne
    local num = tonumber(num_s)

    -- skip optional whitespace between number and unit
    local _, ue = s:find("^%s*", pos)
    if ue then pos = ue + 1 end

    -- unit: greedy match longest first
    local unit_mul = nil
    local unit_len = 0
    -- try lengths 12 down to 1
    for ulen = 12, 1, -1 do
      if pos + ulen - 1 <= len then
        local candidate = s:sub(pos, pos + ulen - 1):lower()
        if PARSE_UNIT[candidate] then
          unit_mul = PARSE_UNIT[candidate]
          unit_len = ulen
          break
        end
      end
    end
    if not unit_mul then
      return nil, "unknown unit at position " .. pos .. " in: " .. s
    end
    pos = pos + unit_len

    total_ns = total_ns + sign * math.floor(num * unit_mul)
    matched_any = true
  end

  if not matched_any then
    return nil, "empty duration string"
  end

  return setmetatable({ _ns = total_ns }, Duration)
end

-- ── Timestamp ─────────────────────────────────────────────────────────────────
-- Stored as { _sec = integer Unix seconds, _ns = integer [0, 999999999] }

local Timestamp = {}
Timestamp.__index = Timestamp

--: (number, number?) -> Timestamp
local function make_ts(sec, ns)
  ns = ns or 0
  -- normalise: _ns must be in [0, NS_PER_S)
  if ns < 0 or ns >= NS_PER_S then
    local extra_s = math.floor(ns / NS_PER_S)
    ns = ns - extra_s * NS_PER_S
    sec = sec + extra_s
  end
  return setmetatable({ _sec = math.floor(sec), _ns = math.floor(ns) }, Timestamp)
end

--: () -> number
function Timestamp:to_unix()    return self._sec end
--: () -> number
function Timestamp:to_unix_ms() return self._sec * 1000 + math.floor(self._ns / NS_PER_MS) end
--: () -> { secs: number, ns: number }
function Timestamp:to_unix_ns() return { secs = self._sec, ns = self._ns } end

-- Timestamp + Duration → Timestamp
-- Timestamp - Duration → Timestamp
-- Timestamp - Timestamp → Duration
function Timestamp.__add(a, b)
  -- a: Timestamp, b: Duration
  local new_ns = a._ns + b._ns
  local extra_s = math.floor(new_ns / NS_PER_S)
  return make_ts(a._sec + extra_s, new_ns - extra_s * NS_PER_S)
end

function Timestamp.__sub(a, b)
  if getmetatable(b) == Duration then
    -- Timestamp - Duration → Timestamp
    local new_ns = a._ns - b._ns
    local extra_s = math.floor(new_ns / NS_PER_S)
    -- extra_s may be negative; make_ts normalises
    return make_ts(a._sec + extra_s, new_ns - extra_s * NS_PER_S)
  else
    -- Timestamp - Timestamp → Duration
    local diff_s  = a._sec - b._sec
    local diff_ns = a._ns  - b._ns
    return setmetatable({ _ns = diff_s * NS_PER_S + diff_ns }, Duration)
  end
end

function Timestamp.__eq(a, b)
  return a._sec == b._sec and a._ns == b._ns
end

function Timestamp.__lt(a, b)
  if a._sec ~= b._sec then return a._sec < b._sec end
  return a._ns < b._ns
end

function Timestamp.__le(a, b)
  if a._sec ~= b._sec then return a._sec < b._sec end
  return a._ns <= b._ns
end

-- Calendar decomposition (UTC) using os.date
--: (Timestamp) -> table
local function ts_utc(t)
  return os.date("!*t", t._sec)
end

-- Formatting helpers
--: (number, number) -> string
local function p2(n)  return string.format("%02d", n) end
--: (number, number) -> string
local function p4(n)  return string.format("%04d", n) end

--: () -> string
function Timestamp:format_rfc3339()
  local t = ts_utc(self)
  return p4(t.year) .. "-" .. p2(t.month) .. "-" .. p2(t.day)
      .. "T" .. p2(t.hour) .. ":" .. p2(t.min) .. ":" .. p2(t.sec) .. "Z"
end

--: () -> string
function Timestamp:format_date()
  local t = ts_utc(self)
  return p4(t.year) .. "-" .. p2(t.month) .. "-" .. p2(t.day)
end

--: () -> string
function Timestamp:format_time()
  local t = ts_utc(self)
  return p2(t.hour) .. ":" .. p2(t.min) .. ":" .. p2(t.sec)
end

-- strftime-style format: %Y %m %d %H %M %S %Z (always "UTC")
--: (string) -> string
function Timestamp:format(fmt)
  local t = ts_utc(self)
  return (fmt:gsub("%%(.)", function(c)
    if     c == "Y" then return p4(t.year)
    elseif c == "m" then return p2(t.month)
    elseif c == "d" then return p2(t.day)
    elseif c == "H" then return p2(t.hour)
    elseif c == "M" then return p2(t.min)
    elseif c == "S" then return p2(t.sec)
    elseif c == "Z" then return "UTC"
    elseif c == "%" then return "%"
    else return "%" .. c
    end
  end))
end

Timestamp.__tostring = Timestamp.format_rfc3339

-- ── Timestamp constructors ────────────────────────────────────────────────────

--: () -> Timestamp
function M.now()
  local t = M.time()
  local sec = math.floor(t)
  local ns  = math.floor((t - sec) * NS_PER_S)
  return make_ts(sec, ns)
end

--: (number) -> Timestamp
function M.from_unix(sec)
  return make_ts(sec, 0)
end

--: (number) -> Timestamp
function M.from_unix_ms(ms)
  local sec = math.floor(ms / 1000)
  local ns  = (math.floor(ms) % 1000) * NS_PER_MS
  return make_ts(sec, ns)
end

-- ── RFC 3339 / ISO 8601 parser ────────────────────────────────────────────────
-- Returns Timestamp or nil, errmsg

-- Days since Unix epoch for a proleptic Gregorian date (Howard Hinnant algorithm)
--: (number, number, number) -> number
local function ymd_to_days(y, mo, d)
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo <= 2 and mo + 9 or mo - 3) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--: (string) -> Timestamp?, string?
function M.parse_rfc3339(s)
  if type(s) ~= "string" then return nil, "expected string" end
  -- Full: 2024-01-15T10:30:00Z  or  2024-01-15T10:30:00+05:30
  -- Date-only: 2024-01-15
  local y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not y then return nil, "invalid RFC 3339: " .. s end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)

  local h, mi, sc, frac_ns, off_s = 0, 0, 0, 0, 0
  local rest = s:sub(11)

  if rest ~= "" then
    local sep = rest:sub(1,1)
    if sep ~= "T" and sep ~= "t" and sep ~= " " then
      return nil, "invalid separator: " .. sep
    end
    rest = rest:sub(2)

    local th, tm, ts, after = rest:match("^(%d%d):(%d%d):(%d%d)(.*)")
    if not th then
      th, tm, after = rest:match("^(%d%d):(%d%d)(.*)")
      if not th then return nil, "invalid time in RFC 3339: " .. rest end
      ts = "00"
    end
    h, mi, sc = tonumber(th), tonumber(tm), tonumber(ts)

    -- Fractional seconds
    if after and after:sub(1,1) == "." then
      local frac_str
      frac_str, after = after:match("^%.(%d+)(.*)")
      if frac_str then
        -- pad or truncate to 9 digits for nanoseconds
        local padded = (frac_str .. "000000000"):sub(1, 9)
        frac_ns = tonumber(padded)
      end
    end

    -- Offset
    if after and after ~= "" then
      local a = after
      if a == "Z" or a == "z" then
        off_s = 0
      else
        local sign, oh, om = a:match("^([+-])(%d%d):?(%d%d)$")
        if not sign then return nil, "invalid offset: " .. a end
        off_s = tonumber(oh) * 3600 + tonumber(om) * 60
        if sign == "-" then off_s = -off_s end
      end
    end
  end

  local days = ymd_to_days(y, mo, d)
  local sec  = days * 86400 + h * 3600 + mi * 60 + sc - off_s
  return make_ts(sec, frac_ns)
end

return M
