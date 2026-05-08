if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Human-readable formatting and parsing for numbers, durations, sizes, and more.
local M = {}
M._tier = "pure"

-- ── bytes ──────────────────────────────────────────────────────────────────

local BINARY_UNITS = { "B", "KB", "MB", "GB", "TB", "PB" }
local SI_UNITS     = { "B", "kB", "MB", "GB", "TB", "PB" }

function M.bytes(n, opts)
  local si    = opts and opts.si
  local base  = si and 1000 or 1024
  local units = si and SI_UNITS or BINARY_UNITS
  if n < base then
    return tostring(math.floor(n)) .. " B"
  end
  local exp = math.floor(math.log(n) / math.log(base))
  if exp >= #units then exp = #units - 1 end
  local val = n / (base ^ exp)
  return string.format("%.1f %s", val, units[exp + 1])
end

-- Parse a bytes string back to a number.
-- Accepts: "1.5 MB", "512B", "1 KiB", "2GiB" etc.
function M.parse_bytes(s)
  if type(s) ~= "string" then return nil, "expected string" end
  local num, unit = s:match("^%s*([%d%.]+)%s*([A-Za-z]*)%s*$")
  if not num then return nil, "invalid bytes string: " .. s end
  local v = tonumber(num)
  if not v then return nil, "invalid number in: " .. s end
  unit = unit:upper()
  if unit == "" or unit == "B" then
    return math.floor(v)
  end
  -- binary IEC (KiB, MiB, GiB, TiB) and traditional (KB, MB, GB, TB)
  local prefix = unit:sub(1, 1)
  --: { [string]: integer }
  local exp_map = { K = 1, M = 2, G = 3, T = 4, P = 5 }
  local exp = exp_map[prefix]
  if not exp then return nil, "unknown unit: " .. unit end
  -- KiB/MiB = binary base 1024; kB/MB = SI base 1000 (but parse_bytes treats
  -- KB/MB as binary for symmetry with bytes() default)
  local base = 1024
  if unit:find("I") or unit:find("i") then base = 1024 end
  return math.floor(v * (base ^ exp))
end

-- ── duration ───────────────────────────────────────────────────────────────

local DURATION_PARTS = {
  { "w",    "week",   604800 },
  { "d",    "day",    86400  },
  { "h",    "hour",   3600   },
  { "m",    "minute", 60     },
  { "s",    "second", 1      },
}

local LONG_PLURAL = {
  week = "weeks", day = "days", hour = "hours", minute = "minutes", second = "seconds",
}

function M.duration(secs, opts)
  opts = opts or {}
  if secs == 0 then
    if opts.long then return "0 seconds" end
    return "0s"
  end

  local parts = {}
  local remaining = secs
  -- fill_zeros: once we start emitting, include zero units for intermediate gaps
  -- (needed so max_parts truncation lands on the right unit boundary)
  local fill_zeros = opts.max_parts ~= nil
  local started = false
  for _, p in ipairs(DURATION_PARTS) do
    local short, long, div = p[1], p[2], p[3]
    local count = math.floor(remaining / div)
    remaining = remaining - count * div
    if count > 0 or (fill_zeros and started) then
      started = true
      if opts.long then
        local word = count == 1 and long or LONG_PLURAL[long]
        parts[#parts + 1] = count .. " " .. word
      elseif opts.compact then
        parts[#parts + 1] = count .. short
      else
        parts[#parts + 1] = count .. short
      end
    end
  end

  -- sub-second milliseconds
  if remaining > 0 and #parts == 0 then
    local ms = math.floor(remaining * 1000 + 0.5)
    if opts.long then
      parts[#parts + 1] = ms .. (ms == 1 and " millisecond" or " milliseconds")
    elseif opts.compact then
      parts[#parts + 1] = ms .. "ms"
    else
      parts[#parts + 1] = ms .. "ms"
    end
  end

  if opts.max_parts and #parts > opts.max_parts then
    local trimmed = {}
    for i = 1, opts.max_parts do trimmed[i] = parts[i] end
    parts = trimmed
  end

  if opts.compact then
    return table.concat(parts, "")
  else
    return table.concat(parts, " ")
  end
end

-- Parse a duration string to seconds.
-- Accepts: "1h 30m", "2d 4h", "500ms", "1.5s", "1w 2d"
function M.parse_duration(s)
  if type(s) ~= "string" then return nil, "expected string" end
  local total = 0.0 --: number
  local found = false
  -- match optional milliseconds suffix first (500ms)
  for num, unit in s:gmatch("([%d%.]+)%s*([a-zA-Z]+)") do
    local v = tonumber(num)
    if not v then return nil, "invalid number: " .. num end
    unit = unit:lower()
    if unit == "ms" then
      total = total + v / 1000
      found = true
    elseif unit == "s" or unit == "sec" or unit == "second" or unit == "seconds" then
      total = total + v
      found = true
    elseif unit == "m" or unit == "min" or unit == "minute" or unit == "minutes" then
      total = total + v * 60
      found = true
    elseif unit == "h" or unit == "hr" or unit == "hour" or unit == "hours" then
      total = total + v * 3600
      found = true
    elseif unit == "d" or unit == "day" or unit == "days" then
      total = total + v * 86400
      found = true
    elseif unit == "w" or unit == "week" or unit == "weeks" then
      total = total + v * 604800
      found = true
    else
      return nil, "unknown unit: " .. unit
    end
  end
  if not found then return nil, "invalid duration string: " .. s end
  return total
end

-- ── ordinal ────────────────────────────────────────────────────────────────

function M.ordinal(n)
  local abs = math.abs(n)
  local last2 = abs % 100
  local last1 = abs % 10
  local suffix
  if last2 >= 11 and last2 <= 13 then
    suffix = "th"
  elseif last1 == 1 then
    suffix = "st"
  elseif last1 == 2 then
    suffix = "nd"
  elseif last1 == 3 then
    suffix = "rd"
  else
    suffix = "th"
  end
  return tostring(n) .. suffix
end

-- ── number ─────────────────────────────────────────────────────────────────

function M.number(n, opts)
  opts = opts or {}
  local sep = opts.sep or ","
  -- Split into integer and fractional parts
  local fmt_str = tostring(n)
  -- Handle scientific notation from tostring
  if fmt_str:find("[eE]") then
    -- format with enough precision to avoid scientific notation
    fmt_str = string.format("%.0f", n)
  end
  local sign = ""
  if fmt_str:sub(1, 1) == "-" then
    sign = "-"
    fmt_str = fmt_str:sub(2)
  end
  local int_part, frac_part = (fmt_str --[[:! string]]):match("^(%d+)(%.?.*)$")
  if not int_part then return tostring(n) end
  -- Insert thousands separators
  local result = int_part:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
  -- Remove leading separator if present
  if result:sub(1, #sep) == sep then result = result:sub(#sep + 1) end
  return sign .. result .. (frac_part or "")
end

--: (ratio: number, decimals: integer | nil) -> string
function M.percentage(ratio, decimals)
  local d = decimals or 1 --: integer
  local pct = ratio * 100
  if d == 0 then
    return string.format("%d%%", math.floor(pct + 0.5))
  end
  return string.format("%." .. d .. "f%%", pct)
end

-- ── relative time ──────────────────────────────────────────────────────────

function M.relative(secs)
  local future = secs < 0
  local abs = math.abs(secs)
  local str
  if abs < 45 then
    local s = math.floor(abs + 0.5)
    str = s .. (s == 1 and " second" or " seconds")
  elseif abs < 90 then
    str = "a minute"
  elseif abs < 2700 then -- 45 min
    str = math.floor(abs / 60 + 0.5) .. " minutes"
  elseif abs < 5400 then -- 90 min → "an hour" (future) / "1 hour" (past)
    local hrs = math.floor(abs / 3600 + 0.5)
    if future and hrs == 1 then
      str = "an hour"
    else
      str = hrs .. (hrs == 1 and " hour" or " hours")
    end
  elseif abs < 79200 then -- 22 hours
    str = math.floor(abs / 3600 + 0.5) .. " hours"
  elseif abs < 86400 * 1.5 then
    str = future and "tomorrow" or "yesterday"
    return future and "in " .. str or str
  elseif abs < 86400 * 25.5 then
    str = math.floor(abs / 86400 + 0.5) .. " days"
  elseif abs < 86400 * 45 then
    str = "a month"
  elseif abs < 86400 * 319 then
    str = math.floor(abs / (86400 * 30) + 0.5) .. " months"
  elseif abs < 86400 * 547 then
    str = "a year"
  else
    str = math.floor(abs / (86400 * 365) + 0.5) .. " years"
  end
  if future then
    return "in " .. str
  else
    return str .. " ago"
  end
end

-- ── plural ─────────────────────────────────────────────────────────────────

function M.plural(n, singular, plural_form)
  if n == 1 then
    return n .. " " .. singular
  else
    return n .. " " .. (plural_form or singular .. "s")
  end
end

-- ── list ───────────────────────────────────────────────────────────────────

function M.list(items, opts)
  opts = opts or {}
  local n = #items
  if n == 0 then return "" end
  if n == 1 then return items[1] end
  if n == 2 then
    local conj = opts.sep or " and "
    -- For sep like " or ", strip leading/trailing space for two-item join
    return items[1] .. conj .. items[2]
  end
  -- 3+ items
  local conj = opts.sep or " and "
  -- Build: "a, b, and c" — the Oxford comma uses the conjunction from sep
  -- Extract the conjunction word from sep (strip spaces)
  local conj_word = conj:match("^%s*(.-)%s*$")
  local buf = {}
  for i = 1, n - 1 do
    buf[i] = items[i]
  end
  return table.concat(buf, ", ") .. ", " .. conj_word .. " " .. items[n]
end

return M
