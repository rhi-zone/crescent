if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local dt = require("lib.datetime")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function parse(s) return dt.parse_iso(s) end

-- ── is_leap ──────────────────────────────────────────────────────────────────

T.describe("datetime.is_leap", function()
  T.it("2000 is a leap year", function() T.ok(dt.is_leap(2000)) end)
  T.it("1900 is NOT a leap year", function() T.fail(dt.is_leap(1900)) end)
  T.it("2024 is a leap year", function() T.ok(dt.is_leap(2024)) end)
  T.it("2023 is NOT a leap year", function() T.fail(dt.is_leap(2023)) end)
  T.it("1600 is a leap year", function() T.ok(dt.is_leap(1600)) end)
end)

-- ── days_in_month ─────────────────────────────────────────────────────────────

T.describe("datetime.days_in_month", function()
  T.it("January has 31 days", function() T.eq(dt.days_in_month(2024, 1), 31) end)
  T.it("February 2024 (leap) has 29 days", function() T.eq(dt.days_in_month(2024, 2), 29) end)
  T.it("February 2023 (non-leap) has 28 days", function() T.eq(dt.days_in_month(2023, 2), 28) end)
  T.it("April has 30 days", function() T.eq(dt.days_in_month(2024, 4), 30) end)
  T.it("December has 31 days", function() T.eq(dt.days_in_month(2024, 12), 31) end)
end)

-- ── new ──────────────────────────────────────────────────────────────────────

T.describe("datetime.new", function()
  T.it("sets all fields", function()
    local d = dt.new(2024, 1, 15, 10, 30, 0, 0)
    T.eq(d.year, 2024)
    T.eq(d.month, 1)
    T.eq(d.day, 15)
    T.eq(d.hour, 10)
    T.eq(d.min, 30)
    T.eq(d.sec, 0)
    T.eq(d.offset, 0)
  end)

  T.it("defaults hour/min/sec to 0", function()
    local d = dt.new(2024, 6, 1)
    T.eq(d.hour, 0)
    T.eq(d.min, 0)
    T.eq(d.sec, 0)
  end)

  T.it("offset nil by default (local/unspecified)", function()
    local d = dt.new(2024, 1, 1)
    T.eq(d.offset, nil)
  end)
end)

-- ── is_valid ─────────────────────────────────────────────────────────────────

T.describe("datetime.is_valid", function()
  T.it("valid date", function()
    T.ok(dt.is_valid(dt.new(2024, 1, 15, 10, 30, 0, 0)))
  end)

  T.it("month 0 invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 0, 1, 0, 0, 0, 0)))
  end)

  T.it("month 13 invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 13, 1, 0, 0, 0, 0)))
  end)

  T.it("day 0 invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 1, 0, 0, 0, 0, 0)))
  end)

  T.it("day 32 for January invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 1, 32, 0, 0, 0, 0)))
  end)

  T.it("Feb 29 on leap year valid", function()
    T.ok(dt.is_valid(dt.new(2024, 2, 29, 0, 0, 0, 0)))
  end)

  T.it("Feb 29 on non-leap year invalid", function()
    T.fail(dt.is_valid(dt.new(2023, 2, 29, 0, 0, 0, 0)))
  end)

  T.it("Feb 28 on non-leap year valid", function()
    T.ok(dt.is_valid(dt.new(2023, 2, 28, 0, 0, 0, 0)))
  end)

  T.it("hour 24 invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 1, 1, 24, 0, 0, 0)))
  end)

  T.it("minute 60 invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 1, 1, 0, 60, 0, 0)))
  end)

  T.it("second 61 invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 1, 1, 0, 0, 61, 0)))
  end)

  T.it("second 60 valid (leap second)", function()
    T.ok(dt.is_valid(dt.new(2024, 1, 1, 0, 0, 60, 0)))
  end)

  T.it("non-table is invalid", function()
    T.fail(dt.is_valid("2024-01-01"))
    T.fail(dt.is_valid(nil))
    T.fail(dt.is_valid(42))
  end)

  T.it("April 31 invalid", function()
    T.fail(dt.is_valid(dt.new(2024, 4, 31, 0, 0, 0, 0)))
  end)
end)

-- ── parse_iso ─────────────────────────────────────────────────────────────────

T.describe("datetime.parse_iso — date only", function()
  T.it("parses YYYY-MM-DD", function()
    local d = parse("2024-01-15")
    T.eq(d.year, 2024)
    T.eq(d.month, 1)
    T.eq(d.day, 15)
    T.eq(d.hour, 0)
    T.eq(d.min, 0)
    T.eq(d.sec, 0)
    T.eq(d.offset, nil)
  end)
end)

T.describe("datetime.parse_iso — datetime without offset", function()
  T.it("parses YYYY-MM-DDTHH:MM:SS", function()
    local d = parse("2024-01-15T10:30:45")
    T.eq(d.year, 2024)
    T.eq(d.month, 1)
    T.eq(d.day, 15)
    T.eq(d.hour, 10)
    T.eq(d.min, 30)
    T.eq(d.sec, 45)
    T.eq(d.offset, nil)
  end)

  T.it("parses lowercase t separator", function()
    local d = parse("2024-06-20t08:00:00")
    T.eq(d.hour, 8)
    T.eq(d.offset, nil)
  end)

  T.it("parses space separator", function()
    local d = parse("2024-06-20 08:00:00")
    T.eq(d.hour, 8)
  end)
end)

T.describe("datetime.parse_iso — UTC (Z suffix)", function()
  T.it("parses Z suffix as offset 0", function()
    local d = parse("2024-01-15T10:30:00Z")
    T.eq(d.offset, 0)
    T.eq(d.hour, 10)
    T.eq(d.min, 30)
  end)

  T.it("parses lowercase z suffix", function()
    local d = parse("2024-01-15T10:30:00z")
    T.eq(d.offset, 0)
  end)
end)

T.describe("datetime.parse_iso — with timezone offset", function()
  T.it("parses +05:30 offset (IST)", function()
    local d = parse("2024-01-15T10:30:00+05:30")
    T.eq(d.offset, 5 * 3600 + 30 * 60)  -- 19800
    T.eq(d.hour, 10)
    T.eq(d.min, 30)
  end)

  T.it("parses -07:00 offset (PDT)", function()
    local d = parse("2024-01-15T10:30:00-07:00")
    T.eq(d.offset, -7 * 3600)
    T.eq(d.hour, 10)
  end)

  T.it("parses +00:00 as offset 0", function()
    local d = parse("2024-01-15T10:30:00+00:00")
    T.eq(d.offset, 0)
  end)

  T.it("parses -00:00 as offset 0", function()
    local d = parse("2024-01-15T10:30:00-00:00")
    T.eq(d.offset, 0)
  end)
end)

T.describe("datetime.parse_iso — fractional seconds", function()
  T.it("ignores fractional seconds", function()
    local d = parse("2024-01-15T10:30:00.123Z")
    T.eq(d.sec, 0)
    T.eq(d.offset, 0)
  end)

  T.it("ignores fractional seconds with offset", function()
    local d = parse("2024-01-15T10:30:00.999+05:30")
    T.eq(d.sec, 0)
    T.eq(d.offset, 19800)
  end)
end)

T.describe("datetime.parse_iso — error cases", function()
  T.it("returns nil, errmsg for non-string", function()
    local d, err = dt.parse_iso(42)
    T.eq(d, nil)
    T.ok(err ~= nil)
  end)

  T.it("returns nil for garbage string", function()
    local d = parse("not-a-date")
    T.eq(d, nil)
  end)

  T.it("returns nil for invalid month", function()
    local d = parse("2024-13-01")
    T.eq(d, nil)
  end)

  T.it("returns nil for Feb 30", function()
    local d = parse("2024-02-30")
    T.eq(d, nil)
  end)

  T.it("returns nil for invalid separator", function()
    local d = parse("2024-01-01X10:00:00")
    T.eq(d, nil)
  end)
end)

-- ── from_unix ────────────────────────────────────────────────────────────────

T.describe("datetime.from_unix", function()
  T.it("epoch 0 = 1970-01-01T00:00:00Z", function()
    local d = dt.from_unix(0)
    T.eq(d.year, 1970)
    T.eq(d.month, 1)
    T.eq(d.day, 1)
    T.eq(d.hour, 0)
    T.eq(d.min, 0)
    T.eq(d.sec, 0)
    T.eq(d.offset, 0)
  end)

  T.it("1000000000 = 2001-09-09T01:46:40Z", function()
    local d = dt.from_unix(1000000000)
    T.eq(d.year, 2001)
    T.eq(d.month, 9)
    T.eq(d.day, 9)
    T.eq(d.hour, 1)
    T.eq(d.min, 46)
    T.eq(d.sec, 40)
    T.eq(d.offset, 0)
  end)

  T.it("returns UTC (offset=0)", function()
    local d = dt.from_unix(0)
    T.eq(d.offset, 0)
  end)
end)

-- ── to_unix ──────────────────────────────────────────────────────────────────

T.describe("datetime.to_unix", function()
  T.it("1970-01-01T00:00:00Z = 0", function()
    local d = dt.new(1970, 1, 1, 0, 0, 0, 0)
    T.eq(dt.to_unix(d), 0)
  end)

  T.it("2001-09-09T01:46:40Z = 1000000000", function()
    local d = dt.new(2001, 9, 9, 1, 46, 40, 0)
    T.eq(dt.to_unix(d), 1000000000)
  end)

  T.it("offset shifts unix time: +05:30 means earlier UTC", function()
    -- 10:30 +05:30 = 05:00 UTC
    local d = dt.new(2024, 1, 1, 10, 30, 0, 19800)  -- +05:30
    local d_utc = dt.new(2024, 1, 1, 5, 0, 0, 0)
    T.eq(dt.to_unix(d), dt.to_unix(d_utc))
  end)
end)

-- ── Round-trip ────────────────────────────────────────────────────────────────

T.describe("round-trip: parse_iso → to_iso → parse_iso", function()
  local cases = {
    "2024-01-15T10:30:00Z",
    "2024-01-15T10:30:00+05:30",
    "2024-01-15T10:30:00-07:00",
    "2000-02-29T00:00:00Z",
    "1970-01-01T00:00:00Z",
  }
  for _, s in ipairs(cases) do
    T.it("round-trips " .. s, function()
      local d1 = parse(s)
      T.ok(d1 ~= nil, "parse failed for " .. s)
      local s2 = dt.to_iso(d1)
      local d2 = parse(s2)
      T.ok(d2 ~= nil, "re-parse failed for " .. s2)
      T.eq(dt.to_unix(d1), dt.to_unix(d2))
    end)
  end
end)

T.describe("round-trip: from_unix → to_unix", function()
  local cases = { 0, 1000000000, 1705312200, 946684800 }
  for _, ts in ipairs(cases) do
    T.it("round-trips unix " .. ts, function()
      local d = dt.from_unix(ts)
      T.eq(dt.to_unix(d), ts)
    end)
  end
end)

-- ── to_iso ────────────────────────────────────────────────────────────────────

T.describe("datetime.to_iso", function()
  T.it("UTC outputs Z", function()
    local d = dt.new(2024, 1, 15, 10, 30, 0, 0)
    T.eq(dt.to_iso(d), "2024-01-15T10:30:00Z")
  end)

  T.it("+05:30 offset", function()
    local d = dt.new(2024, 1, 15, 10, 30, 0, 19800)
    T.eq(dt.to_iso(d), "2024-01-15T10:30:00+05:30")
  end)

  T.it("-07:00 offset", function()
    local d = dt.new(2024, 1, 15, 10, 30, 0, -25200)
    T.eq(dt.to_iso(d), "2024-01-15T10:30:00-07:00")
  end)

  T.it("no offset (nil) omits Z", function()
    local d = dt.new(2024, 1, 15, 10, 30, 0)
    -- offset is nil, so no suffix
    T.eq(dt.to_iso(d), "2024-01-15T10:30:00")
  end)

  T.it("pads single-digit month/day", function()
    local d = dt.new(2024, 1, 5, 9, 7, 3, 0)
    T.eq(dt.to_iso(d), "2024-01-05T09:07:03Z")
  end)
end)

-- ── format ────────────────────────────────────────────────────────────────────

T.describe("datetime.format", function()
  local d = dt.new(2024, 3, 7, 9, 5, 42, 0)

  T.it("%Y = 4-digit year", function()
    T.eq(dt.format(d, "%Y"), "2024")
  end)

  T.it("%m = 2-digit month", function()
    T.eq(dt.format(d, "%m"), "03")
  end)

  T.it("%d = 2-digit day", function()
    T.eq(dt.format(d, "%d"), "07")
  end)

  T.it("%H = 2-digit hour", function()
    T.eq(dt.format(d, "%H"), "09")
  end)

  T.it("%M = 2-digit minute", function()
    T.eq(dt.format(d, "%M"), "05")
  end)

  T.it("%S = 2-digit second", function()
    T.eq(dt.format(d, "%S"), "42")
  end)

  T.it("%Z = UTC offset string", function()
    T.eq(dt.format(d, "%Z"), "Z")
  end)

  T.it("%Z nil offset = empty string", function()
    local d2 = dt.new(2024, 1, 1)
    T.eq(dt.format(d2, "%Z"), "")
  end)

  T.it("combined format", function()
    T.eq(dt.format(d, "%Y-%m-%d %H:%M:%S %Z"), "2024-03-07 09:05:42 Z")
  end)

  T.it("%% = literal percent", function()
    T.eq(dt.format(d, "100%%"), "100%")
  end)
end)

-- ── add ──────────────────────────────────────────────────────────────────────

T.describe("datetime.add — seconds/minutes/hours", function()
  T.it("adds seconds", function()
    local d = dt.new(2024, 1, 1, 0, 0, 50, 0)
    local r = dt.add(d, { seconds = 20 })
    T.eq(r.min, 1)
    T.eq(r.sec, 10)
  end)

  T.it("adds minutes", function()
    local d = dt.new(2024, 1, 1, 0, 55, 0, 0)
    local r = dt.add(d, { minutes = 10 })
    T.eq(r.hour, 1)
    T.eq(r.min, 5)
  end)

  T.it("adds hours crossing midnight", function()
    local d = dt.new(2024, 1, 1, 23, 0, 0, 0)
    local r = dt.add(d, { hours = 2 })
    T.eq(r.day, 2)
    T.eq(r.hour, 1)
  end)
end)

T.describe("datetime.add — days crossing month boundary", function()
  T.it("crosses January → February", function()
    local d = dt.new(2024, 1, 30, 0, 0, 0, 0)
    local r = dt.add(d, { days = 5 })
    T.eq(r.month, 2)
    T.eq(r.day, 4)
  end)

  T.it("crosses February → March on leap year", function()
    local d = dt.new(2024, 2, 28, 0, 0, 0, 0)
    local r = dt.add(d, { days = 1 })
    T.eq(r.month, 2)
    T.eq(r.day, 29)  -- leap day
  end)

  T.it("crosses February leap day → March", function()
    local d = dt.new(2024, 2, 29, 0, 0, 0, 0)
    local r = dt.add(d, { days = 1 })
    T.eq(r.month, 3)
    T.eq(r.day, 1)
  end)

  T.it("crosses February → March on non-leap year", function()
    local d = dt.new(2023, 2, 28, 0, 0, 0, 0)
    local r = dt.add(d, { days = 1 })
    T.eq(r.month, 3)
    T.eq(r.day, 1)
  end)

  T.it("crosses December → January (year boundary)", function()
    local d = dt.new(2023, 12, 31, 0, 0, 0, 0)
    local r = dt.add(d, { days = 1 })
    T.eq(r.year, 2024)
    T.eq(r.month, 1)
    T.eq(r.day, 1)
  end)

  T.it("adds 365 days to non-leap year", function()
    local d = dt.new(2023, 1, 1, 0, 0, 0, 0)
    local r = dt.add(d, { days = 365 })
    T.eq(r.year, 2024)
    T.eq(r.month, 1)
    T.eq(r.day, 1)
  end)

  T.it("adds 366 days to leap year", function()
    local d = dt.new(2024, 1, 1, 0, 0, 0, 0)
    local r = dt.add(d, { days = 366 })
    T.eq(r.year, 2025)
    T.eq(r.month, 1)
    T.eq(r.day, 1)
  end)
end)

T.describe("datetime.add — negative values (subtraction)", function()
  T.it("subtracts days crossing month boundary", function()
    local d = dt.new(2024, 3, 1, 0, 0, 0, 0)
    local r = dt.add(d, { days = -1 })
    T.eq(r.month, 2)
    T.eq(r.day, 29)  -- 2024 is leap
  end)

  T.it("subtracts days into previous year", function()
    local d = dt.new(2024, 1, 1, 0, 0, 0, 0)
    local r = dt.add(d, { days = -1 })
    T.eq(r.year, 2023)
    T.eq(r.month, 12)
    T.eq(r.day, 31)
  end)

  T.it("subtracts seconds crossing midnight backwards", function()
    local d = dt.new(2024, 3, 1, 0, 0, 30, 0)
    local r = dt.add(d, { seconds = -60 })
    T.eq(r.month, 2)
    T.eq(r.day, 29)
    T.eq(r.hour, 23)
    T.eq(r.min, 59)
    T.eq(r.sec, 30)
  end)
end)

T.describe("datetime.add — preserves offset", function()
  T.it("keeps offset from original", function()
    local d = dt.new(2024, 1, 1, 0, 0, 0, 19800)
    local r = dt.add(d, { days = 1 })
    T.eq(r.offset, 19800)
  end)
end)

-- ── diff ────────────────────────────────────────────────────────────────────

T.describe("datetime.diff", function()
  T.it("same datetime = 0", function()
    local d = dt.new(2024, 1, 1, 0, 0, 0, 0)
    T.eq(dt.diff(d, d), 0)
  end)

  T.it("1 day = 86400 seconds", function()
    local d1 = dt.new(2024, 1, 2, 0, 0, 0, 0)
    local d2 = dt.new(2024, 1, 1, 0, 0, 0, 0)
    T.eq(dt.diff(d1, d2), 86400)
  end)

  T.it("reversed gives negative", function()
    local d1 = dt.new(2024, 1, 1, 0, 0, 0, 0)
    local d2 = dt.new(2024, 1, 2, 0, 0, 0, 0)
    T.eq(dt.diff(d1, d2), -86400)
  end)

  T.it("accounts for offsets", function()
    -- 10:00+05:30 = 04:30 UTC; 10:00Z = 10:00 UTC
    local d1 = dt.new(2024, 1, 1, 10, 0, 0, 19800)   -- 04:30 UTC
    local d2 = dt.new(2024, 1, 1, 10, 0, 0, 0)        -- 10:00 UTC
    -- d1 is 5.5 hours earlier in UTC
    T.eq(dt.diff(d1, d2), -19800)
  end)
end)

-- ── compare ──────────────────────────────────────────────────────────────────

T.describe("datetime.compare", function()
  T.it("equal datetimes = 0", function()
    local d = dt.new(2024, 1, 1, 0, 0, 0, 0)
    T.eq(dt.compare(d, d), 0)
  end)

  T.it("earlier < later → -1", function()
    local d1 = dt.new(2024, 1, 1, 0, 0, 0, 0)
    local d2 = dt.new(2024, 1, 2, 0, 0, 0, 0)
    T.eq(dt.compare(d1, d2), -1)
  end)

  T.it("later > earlier → 1", function()
    local d1 = dt.new(2024, 1, 2, 0, 0, 0, 0)
    local d2 = dt.new(2024, 1, 1, 0, 0, 0, 0)
    T.eq(dt.compare(d1, d2), 1)
  end)

  T.it("different offsets, same UTC instant = 0", function()
    -- 10:00+05:30 == 04:30Z
    local d1 = dt.new(2024, 1, 1, 10, 0, 0, 19800)
    local d2 = dt.new(2024, 1, 1, 4, 30, 0, 0)
    T.eq(dt.compare(d1, d2), 0)
  end)
end)

-- ── now ──────────────────────────────────────────────────────────────────────

T.describe("datetime.now", function()
  T.it("returns a table with expected fields", function()
    local d = dt.now()
    T.ok(type(d.year) == "number")
    T.ok(type(d.month) == "number")
    T.ok(type(d.day) == "number")
    T.ok(type(d.hour) == "number")
    T.ok(type(d.min) == "number")
    T.ok(type(d.sec) == "number")
  end)

  T.it("year is plausible (>= 2024)", function()
    local d = dt.now()
    T.ok(d.year >= 2024)
  end)
end)

-- ── Edge cases ────────────────────────────────────────────────────────────────

T.describe("datetime — edge cases", function()
  T.it("year 2000 leap: Feb 29 valid", function()
    T.ok(dt.is_valid(dt.new(2000, 2, 29, 0, 0, 0, 0)))
  end)

  T.it("year 1900 non-leap: Feb 29 invalid", function()
    T.fail(dt.is_valid(dt.new(1900, 2, 29, 0, 0, 0, 0)))
  end)

  T.it("add 1 year via months=12", function()
    local d = dt.new(2023, 3, 15, 0, 0, 0, 0)
    local r = dt.add(d, { months = 12 })
    T.eq(r.year, 2024)
    T.eq(r.month, 3)
    T.eq(r.day, 15)
  end)

  T.it("unix 0 round-trips through to_iso and parse", function()
    local d = dt.from_unix(0)
    local s = dt.to_iso(d)
    T.eq(s, "1970-01-01T00:00:00Z")
    local d2 = parse(s)
    T.eq(dt.to_unix(d2), 0)
  end)

  T.it("add large number of seconds", function()
    local d = dt.new(2024, 1, 1, 0, 0, 0, 0)
    local r = dt.add(d, { seconds = 86400 * 365 })
    -- 2024 is leap (366 days), so 365 days later = 2024-12-31
    T.eq(r.year, 2024)
    T.eq(r.month, 12)
    T.eq(r.day, 31)
  end)
end)
