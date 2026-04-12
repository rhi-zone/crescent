if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Duration library: parse, format, and arithmetic for time spans.
-- All durations are stored internally as a single float of seconds.
-- Negative durations are supported throughout.

local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal constructor
-- ---------------------------------------------------------------------------

local Duration = {}
Duration.__index = Duration

local function new_raw(secs)
  return setmetatable({ _secs = secs }, Duration)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- D.new(seconds) — create from a number of seconds (float ok).
function M.new(seconds)
  return new_raw(seconds or 0)
end

-- D.from_parts({ days, hours, minutes, seconds, milliseconds }) — named parts.
-- All fields optional, default 0. Negative parts are summed as-is.
function M.from_parts(parts)
  parts = parts or {}
  local secs = 0
  secs = secs + (parts.weeks        or 0) * 604800
  secs = secs + (parts.days         or 0) * 86400
  secs = secs + (parts.hours        or 0) * 3600
  secs = secs + (parts.minutes      or 0) * 60
  secs = secs + (parts.seconds      or 0)
  secs = secs + (parts.milliseconds or 0) * 0.001
  return new_raw(secs)
end

-- ---------------------------------------------------------------------------
-- Parse helpers
-- ---------------------------------------------------------------------------

-- Unit multipliers (to seconds).
local UNIT = {
  w = 604800, week = 604800, weeks = 604800,
  d = 86400,  day  = 86400,  days  = 86400,
  h = 3600,   hour = 3600,   hours = 3600,
  m = 60,     min  = 60,     minute = 60, minutes = 60,
  s = 1,      sec  = 1,      second = 1, seconds = 1,
  ms = 0.001, millisecond = 0.001, milliseconds = 0.001,
}

-- Parse a human string like "1h30m45s", "1:30:45", "90m", "1.5h", "-30s", "90".
-- Returns (duration) or (nil, errmsg).
function M.parse(s)
  if type(s) ~= "string" then
    return nil, "duration.parse: expected string, got " .. type(s)
  end

  local orig = s
  s = s:match("^%s*(.-)%s*$")  -- trim

  -- Sign prefix.
  local sign = 1
  if s:sub(1, 1) == "-" then
    sign = -1
    s = s:sub(2)
  elseif s:sub(1, 1) == "+" then
    s = s:sub(2)
  end

  -- Bare number → seconds.
  if s:match("^%d+%.?%d*$") then
    return new_raw(sign * tonumber(s))
  end

  -- HH:MM:SS[.mmm] or MM:SS[.mmm] — colon format.
  do
    local h, m, sec_s = s:match("^(%d+):(%d+):(%d+%.?%d*)$")
    if h then
      local total = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec_s)
      return new_raw(sign * total)
    end
    local m2, sec_s2 = s:match("^(%d+):(%d+%.?%d*)$")
    if m2 then
      local total = tonumber(m2) * 60 + tonumber(sec_s2)
      return new_raw(sign * total)
    end
  end

  -- Composite unit string: "1h 30m 45s", "2d4h30m", "500ms", etc.
  -- Accept optional spaces between tokens.
  local total = 0
  local pos = 1
  local matched_any = false
  local lower = s:lower()

  while pos <= #lower do
    -- Skip optional spaces.
    local sp = lower:match("^%s+", pos)
    if sp then pos = pos + #sp end
    if pos > #lower then break end

    -- Number (int or decimal).
    local num_s = lower:match("^%d+%.?%d*", pos)
    if not num_s then
      return nil, "duration.parse: unexpected character at position " .. pos .. " in '" .. orig .. "'"
    end
    local num = tonumber(num_s)
    pos = pos + #num_s

    -- Optional space before unit.
    local sp2 = lower:match("^%s*", pos)
    pos = pos + #sp2

    -- Unit (longest match first to handle "ms" before "m").
    local unit_mult = nil
    -- Try multi-char units first (longest).
    for _, try in ipairs({ "milliseconds", "millisecond", "minutes", "minute", "seconds", "second", "hours", "hour", "weeks", "week", "days", "day", "min", "ms" }) do
      if lower:sub(pos, pos + #try - 1) == try then
        unit_mult = UNIT[try]
        pos = pos + #try
        break
      end
    end
    if not unit_mult then
      -- Single-char units.
      local uc = lower:sub(pos, pos)
      if UNIT[uc] then
        unit_mult = UNIT[uc]
        pos = pos + 1
      else
        return nil, "duration.parse: unknown unit '" .. lower:sub(pos) .. "' in '" .. orig .. "'"
      end
    end

    total = total + num * unit_mult
    matched_any = true
  end

  if not matched_any then
    return nil, "duration.parse: empty duration string"
  end

  return new_raw(sign * total)
end

-- ---------------------------------------------------------------------------
-- Access — total values
-- ---------------------------------------------------------------------------

function Duration:total_seconds()      return self._secs end
function Duration:total_milliseconds() return self._secs * 1000 end
function Duration:total_minutes()      return self._secs / 60 end
function Duration:total_hours()        return self._secs / 3600 end
function Duration:total_days()         return self._secs / 86400 end

-- ---------------------------------------------------------------------------
-- Component decomposition
-- ---------------------------------------------------------------------------

-- Returns { sign=1|-1, weeks=.., days=.., hours=.., minutes=.., seconds=.., milliseconds=.. }
-- All component fields are non-negative integers except milliseconds (non-negative integer ms).
function Duration:parts()
  local s = self._secs
  local sign = 1
  if s < 0 then
    sign = -1
    s = -s
  end

  -- Split into integer and fractional seconds.
  local isecs = math.floor(s + 0.5e-9)  -- avoid float noise
  local ms = math.floor((s - isecs) * 1000 + 0.5)
  if ms >= 1000 then ms = ms - 1000; isecs = isecs + 1 end

  local days    = math.floor(isecs / 86400); isecs = isecs - days * 86400
  local hours   = math.floor(isecs / 3600);  isecs = isecs - hours * 3600
  local minutes = math.floor(isecs / 60);    isecs = isecs - minutes * 60
  local seconds = isecs

  return {
    sign         = sign,
    days         = days,
    hours        = hours,
    minutes      = minutes,
    seconds      = seconds,
    milliseconds = ms,
  }
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function pad2(n) return string.format("%02d", n) end
local function pad3(n) return string.format("%03d", n) end

local function plural(n, word)
  if n == 1 then return "1 " .. word else return n .. " " .. word .. "s" end
end

-- format(fmt) — format the duration.
-- fmt: nil/"default", "HH:MM:SS", "compact", "long", "iso", "clock"
function Duration:format(fmt)
  fmt = fmt or "default"
  local p = self:parts()
  local sign_str = (p.sign < 0) and "-" or ""

  if fmt == "HH:MM:SS" then
    local total_h = p.days * 24 + p.hours
    local s = p.seconds
    if p.milliseconds > 0 then
      return sign_str .. string.format("%02d:%02d:%02d.%03d", total_h, p.minutes, s, p.milliseconds)
    end
    return sign_str .. string.format("%02d:%02d:%02d", total_h, p.minutes, s)

  elseif fmt == "clock" then
    local total_h = p.days * 24 + p.hours
    return sign_str .. string.format("%d:%02d:%02d", total_h, p.minutes, p.seconds)

  elseif fmt == "compact" then
    local parts = {}
    if p.days > 0    then parts[#parts+1] = p.days    .. "d" end
    if p.hours > 0   then parts[#parts+1] = p.hours   .. "h" end
    if p.minutes > 0 then parts[#parts+1] = p.minutes .. "m" end
    if p.seconds > 0 then parts[#parts+1] = p.seconds .. "s" end
    if p.milliseconds > 0 then parts[#parts+1] = p.milliseconds .. "ms" end
    if #parts == 0 then return "0s" end
    return sign_str .. table.concat(parts, "")

  elseif fmt == "long" then
    local parts = {}
    if p.days > 0    then parts[#parts+1] = plural(p.days,    "day") end
    if p.hours > 0   then parts[#parts+1] = plural(p.hours,   "hour") end
    if p.minutes > 0 then parts[#parts+1] = plural(p.minutes, "minute") end
    if p.seconds > 0 then parts[#parts+1] = plural(p.seconds, "second") end
    if p.milliseconds > 0 then parts[#parts+1] = plural(p.milliseconds, "millisecond") end
    if #parts == 0 then return "0 seconds" end
    local joined
    if #parts == 1 then
      joined = parts[1]
    elseif #parts == 2 then
      joined = parts[1] .. " and " .. parts[2]
    else
      local last = table.remove(parts)
      joined = table.concat(parts, ", ") .. ", and " .. last
    end
    return sign_str .. joined

  elseif fmt == "iso" then
    -- ISO 8601: PT1H30M45S, P1DT2H, etc.
    local out = "P"
    if p.days > 0 then out = out .. p.days .. "D" end
    local time_part = ""
    if p.hours > 0   then time_part = time_part .. p.hours   .. "H" end
    if p.minutes > 0 then time_part = time_part .. p.minutes .. "M" end
    if p.seconds > 0 or p.milliseconds > 0 then
      if p.milliseconds > 0 then
        time_part = time_part .. p.seconds .. "." .. pad3(p.milliseconds) .. "S"
      else
        time_part = time_part .. p.seconds .. "S"
      end
    end
    if time_part ~= "" then out = out .. "T" .. time_part end
    if out == "P" then out = "PT0S" end
    return sign_str .. out

  else  -- "default": space-separated non-zero parts
    local parts = {}
    if p.days > 0    then parts[#parts+1] = p.days    .. "d" end
    if p.hours > 0   then parts[#parts+1] = p.hours   .. "h" end
    if p.minutes > 0 then parts[#parts+1] = p.minutes .. "m" end
    if p.seconds > 0 then parts[#parts+1] = p.seconds .. "s" end
    if p.milliseconds > 0 then parts[#parts+1] = p.milliseconds .. "ms" end
    if #parts == 0 then return "0s" end
    return sign_str .. table.concat(parts, " ")
  end
end

-- ---------------------------------------------------------------------------
-- Arithmetic
-- ---------------------------------------------------------------------------

function Duration:add(other)  return new_raw(self._secs + other._secs) end
function Duration:sub(other)  return new_raw(self._secs - other._secs) end
function Duration:mul(n)      return new_raw(self._secs * n) end
function Duration:div(n)      return new_raw(self._secs / n) end
function Duration:neg()       return new_raw(-self._secs) end
function Duration:abs()       return new_raw(math.abs(self._secs)) end

-- ---------------------------------------------------------------------------
-- Comparison
-- ---------------------------------------------------------------------------

function Duration:eq(other)  return self._secs == other._secs end
function Duration:lt(other)  return self._secs <  other._secs end
function Duration:lte(other) return self._secs <= other._secs end
function Duration:gt(other)  return self._secs >  other._secs end
function Duration:gte(other) return self._secs >= other._secs end

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

function M.since(epoch_seconds)
  return new_raw(os.time() - epoch_seconds)
end

function M.between(t1, t2)
  return new_raw(t2 - t1)
end

function M.zero()
  return new_raw(0)
end

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

M.SECOND = new_raw(1)
M.MINUTE = new_raw(60)
M.HOUR   = new_raw(3600)
M.DAY    = new_raw(86400)
M.WEEK   = new_raw(604800)

return M
