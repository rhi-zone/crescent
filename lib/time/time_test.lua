if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local time = require("lib.time")

-- ── mod.time (wall clock) ────────────────────────────────────────────────────

T.describe("time.time", function()
  T.it("returns a number", function()
    local t = time.time()
    T.ok(type(t) == "number", "time() should return a number, got " .. type(t))
  end)

  T.it("returns a positive value", function()
    local t = time.time()
    T.ok(t > 0, "time() should be positive, got " .. tostring(t))
  end)

  T.it("returns a value resembling unix epoch seconds", function()
    local t = time.time()
    T.ok(t > 1577836800, "time() too small: " .. tostring(t))
    T.ok(t < 4102444800, "time() too large: " .. tostring(t))
  end)

  T.it("has sub-second precision", function()
    local found_frac = false
    for _ = 1, 100 do
      local t = time.time()
      if t % 1 ~= 0 then
        found_frac = true
        break
      end
    end
    T.ok(found_frac, "time() should have sub-second precision")
  end)

  T.it("is monotonically non-decreasing across calls", function()
    local t1 = time.time()
    local t2 = time.time()
    T.ok(t2 >= t1, "second call should be >= first: " .. tostring(t1) .. " vs " .. tostring(t2))
  end)

  T.it("advances over a busy loop", function()
    local t1 = time.time()
    local sum = 0
    for i = 1, 1e5 do sum = sum + i end
    local t2 = time.time()
    T.ok(t2 > t1, "time should advance after work: " .. tostring(t1) .. " vs " .. tostring(t2))
    local _ = sum
  end)
end)

-- ── Duration construction ─────────────────────────────────────────────────────

T.describe("time.duration — construction", function()
  T.it("duration_ns", function()
    local d = time.duration_ns(1e9)
    T.eq(d:to_ns(), 1e9)
  end)

  T.it("duration_ms", function()
    local d = time.duration_ms(500)
    T.eq(d:to_ms(), 500)
    T.eq(d:to_ns(), 500 * 1000000)
  end)

  T.it("duration_s", function()
    local d = time.duration_s(3600)
    T.eq(d:to_s(), 3600)
  end)

  T.it("duration(5, 'hours')", function()
    local d = time.duration(5, "hours")
    T.eq(d:to_hours(), 5)
    T.eq(d:to_minutes(), 300)
  end)

  T.it("duration(30, 'minutes')", function()
    local d = time.duration(30, "minutes")
    T.eq(d:to_minutes(), 30)
    T.eq(d:to_s(), 1800)
  end)

  T.it("duration(1, 'day')", function()
    local d = time.duration(1, "day")
    T.eq(d:to_days(), 1)
    T.eq(d:to_hours(), 24)
  end)

  T.it("duration(1, 'ns')", function()
    local d = time.duration(1, "ns")
    T.eq(d:to_ns(), 1)
  end)

  T.it("duration(1, 'us')", function()
    local d = time.duration(1, "us")
    T.eq(d:to_ns(), 1000)
  end)

  T.it("duration(1, 'ms')", function()
    local d = time.duration(1, "ms")
    T.eq(d:to_ns(), 1000000)
  end)

  T.it("duration(1, 's')", function()
    local d = time.duration(1, "s")
    T.eq(d:to_ns(), 1000000000)
  end)

  T.it("duration(1, 'min')", function()
    local d = time.duration(1, "min")
    T.eq(d:to_ns(), 60000000000)
  end)

  T.it("duration(1, 'h')", function()
    local d = time.duration(1, "h")
    T.eq(d:to_ns(), 3600000000000)
  end)

  T.it("duration(1, 'd')", function()
    local d = time.duration(1, "d")
    T.eq(d:to_ns(), 86400000000000)
  end)

  T.it("duration returns nil on unknown unit", function()
    local d, err = time.duration(1, "fortnights")
    T.eq(d, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── Duration conversions ──────────────────────────────────────────────────────

T.describe("time.duration — conversions", function()
  T.it("to_ns, to_ms, to_s round-trip for 1h", function()
    local d = time.duration(1, "h")
    T.eq(d:to_ns(), 3600000000000)
    T.eq(d:to_ms(), 3600000)
    T.eq(d:to_s(),  3600)
  end)

  T.it("to_minutes for 1.5h", function()
    local d = time.duration_s(5400)  -- 90 minutes
    T.eq(d:to_minutes(), 90)
  end)

  T.it("to_hours for 2 days", function()
    local d = time.duration(2, "days")
    T.eq(d:to_hours(), 48)
  end)

  T.it("to_days for 72h", function()
    local d = time.duration(72, "hours")
    T.eq(d:to_days(), 3)
  end)

  T.it("components for 1d 2h 3m 4s", function()
    local ns = 1*86400e9 + 2*3600e9 + 3*60e9 + 4*1e9
    local d = time.duration_ns(ns)
    local c = d:components()
    T.eq(c.days,    1)
    T.eq(c.hours,   2)
    T.eq(c.minutes, 3)
    T.eq(c.seconds, 4)
    T.eq(c.ms,      0)
  end)

  T.it("components for 500ms", function()
    local d = time.duration_ms(500)
    local c = d:components()
    T.eq(c.days, 0)
    T.eq(c.hours, 0)
    T.eq(c.minutes, 0)
    T.eq(c.seconds, 0)
    T.eq(c.ms, 500)
  end)
end)

-- ── Duration arithmetic ───────────────────────────────────────────────────────

T.describe("time.duration — arithmetic", function()
  T.it("add two durations", function()
    local d1 = time.duration(5, "hours")
    local d2 = time.duration(30, "minutes")
    local sum = d1 + d2
    T.eq(sum:to_minutes(), 330)
  end)

  T.it("subtract durations", function()
    local d1 = time.duration(5, "hours")
    local d2 = time.duration(30, "minutes")
    local diff = d1 - d2
    T.eq(diff:to_minutes(), 270)
  end)

  T.it("multiply by scalar", function()
    local d = time.duration(2, "hours")
    local d2 = d * 3
    T.eq(d2:to_hours(), 6)
  end)

  T.it("scalar multiply left", function()
    local d = time.duration(2, "hours")
    local d2 = 3 * d
    T.eq(d2:to_hours(), 6)
  end)

  T.it("divide by scalar", function()
    local d = time.duration(10, "hours")
    local d2 = d / 4
    T.eq(d2:to_minutes(), 150)
  end)

  T.it("negate duration", function()
    local d = time.duration(1, "hours")
    local neg = -d
    T.eq(neg:to_ns(), -3600000000000)
  end)

  T.it("abs of negative duration", function()
    local d = time.duration_ns(-5000000000)
    T.eq(d:abs():to_s(), 5)
  end)

  T.it("equality", function()
    local d1 = time.duration(1, "hours")
    local d2 = time.duration(60, "minutes")
    T.ok(d1 == d2)
  end)

  T.it("inequality", function()
    local d1 = time.duration(1, "hours")
    local d2 = time.duration(59, "minutes")
    T.ok(d1 ~= d2)
  end)

  T.it("less than", function()
    local d1 = time.duration(1, "minutes")
    local d2 = time.duration(2, "minutes")
    T.ok(d1 < d2)
  end)

  T.it("greater than (via lt reversed)", function()
    local d1 = time.duration(3, "minutes")
    local d2 = time.duration(1, "minutes")
    T.ok(d2 < d1)
  end)
end)

-- ── Duration formatting ───────────────────────────────────────────────────────

T.describe("time.duration — formatting", function()
  T.it("format() for 5h", function()
    local d = time.duration(5, "hours")
    T.eq(d:format(), "5h 0m 0s")
  end)

  T.it("format() for 1d 2h 3m 4s", function()
    local ns = 1*86400e9 + 2*3600e9 + 3*60e9 + 4*1e9
    local d = time.duration_ns(ns)
    T.eq(d:format(), "1d 2h 3m 4s")
  end)

  T.it("tostring via __tostring", function()
    local d = time.duration(5, "hours")
    T.eq(tostring(d), "5h 0m 0s")
  end)

  T.it("format_short skips zero components", function()
    local d = time.duration(5, "hours")
    T.eq(d:format_short(), "5h")
  end)

  T.it("format_short for 0s", function()
    local d = time.duration_ns(0)
    T.eq(d:format_short(), "0s")
  end)

  T.it("format_short for 1d 30m", function()
    local ns = 1*86400e9 + 30*60e9
    local d = time.duration_ns(ns)
    T.eq(d:format_short(), "1d 30m")
  end)

  T.it("format_precise shows ms", function()
    local d = time.duration_ms(5500)  -- 5.5 seconds
    T.eq(d:format_precise(), "0h 0m 5.500s")
  end)

  T.it("format() for negative duration", function()
    local d = -time.duration(1, "hours")
    T.eq(d:format(), "-1h 0m 0s")
  end)
end)

-- ── Duration parsing ──────────────────────────────────────────────────────────

T.describe("time.duration_parse", function()
  T.it("parses '5h30m'", function()
    local d, err = time.duration_parse("5h30m")
    T.eq(err, nil)
    T.eq(d:to_minutes(), 330)
  end)

  T.it("parses '1d 2h 30m 15s'", function()
    local d, err = time.duration_parse("1d 2h 30m 15s")
    T.eq(err, nil)
    local c = d:components()
    T.eq(c.days,    1)
    T.eq(c.hours,   2)
    T.eq(c.minutes, 30)
    T.eq(c.seconds, 15)
  end)

  T.it("parses '500ms'", function()
    local d, err = time.duration_parse("500ms")
    T.eq(err, nil)
    T.eq(d:to_ms(), 500)
  end)

  T.it("parses '1h' (no suffix separation)", function()
    local d, err = time.duration_parse("1h")
    T.eq(err, nil)
    T.eq(d:to_hours(), 1)
  end)

  T.it("parses '90min'", function()
    local d, err = time.duration_parse("90min")
    T.eq(err, nil)
    T.eq(d:to_minutes(), 90)
  end)

  T.it("parses '2d'", function()
    local d, err = time.duration_parse("2d")
    T.eq(err, nil)
    T.eq(d:to_days(), 2)
  end)

  T.it("returns error on empty string", function()
    local d, err = time.duration_parse("")
    T.eq(d, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns error on unknown unit", function()
    local d, err = time.duration_parse("5fortnights")
    T.eq(d, nil)
    T.ok(type(err) == "string")
  end)

  T.it("roundtrip: parse then to_ns", function()
    local d1 = time.duration_parse("1h 30m")
    local d2 = time.duration(90, "minutes")
    T.ok(d1 ~= nil)
    T.eq(d1:to_ns(), d2:to_ns())
  end)
end)

-- ── Timestamp construction ────────────────────────────────────────────────────

T.describe("time.from_unix / from_unix_ms", function()
  T.it("from_unix round-trips", function()
    local t = time.from_unix(1700000000)
    T.eq(t:to_unix(), 1700000000)
  end)

  T.it("from_unix_ms stores ms", function()
    local t = time.from_unix_ms(1700000000500)
    T.eq(t:to_unix(), 1700000000)
    T.eq(t:to_unix_ms(), 1700000000500)
  end)

  T.it("to_unix_ns returns table with secs and ns", function()
    local t = time.from_unix(1700000000)
    local r = t:to_unix_ns()
    T.eq(r.secs, 1700000000)
    T.eq(r.ns,   0)
  end)

  T.it("now() returns Timestamp with reasonable value", function()
    local t = time.now()
    -- after 2020 and before 2100
    T.ok(t:to_unix() > 1577836800)
    T.ok(t:to_unix() < 4102444800)
  end)
end)

-- ── Timestamp arithmetic ──────────────────────────────────────────────────────

T.describe("Timestamp arithmetic", function()
  T.it("timestamp + duration = new timestamp", function()
    local t = time.from_unix(1700000000)
    local d = time.duration(1, "hours")
    local t2 = t + d
    T.eq(t2:to_unix(), 1700000000 + 3600)
  end)

  T.it("timestamp - duration = new timestamp", function()
    local t = time.from_unix(1700003600)
    local d = time.duration(1, "hours")
    local t2 = t - d
    T.eq(t2:to_unix(), 1700000000)
  end)

  T.it("timestamp - timestamp = duration", function()
    local t1 = time.from_unix(1700003600)
    local t2 = time.from_unix(1700000000)
    local d = t1 - t2
    T.eq(d:to_hours(), 1)
  end)

  T.it("timestamp - timestamp (negative diff)", function()
    local t1 = time.from_unix(1700000000)
    local t2 = time.from_unix(1700003600)
    local d = t1 - t2
    T.eq(d:to_hours(), -1)
  end)

  T.it("equality", function()
    local t1 = time.from_unix(1700000000)
    local t2 = time.from_unix(1700000000)
    T.ok(t1 == t2)
  end)

  T.it("less than", function()
    local t1 = time.from_unix(1700000000)
    local t2 = time.from_unix(1700000001)
    T.ok(t1 < t2)
  end)
end)

-- ── Timestamp formatting ──────────────────────────────────────────────────────

T.describe("Timestamp formatting", function()
  -- 2023-11-14T22:13:20Z
  local known = time.from_unix(1700000000)

  T.it("format_rfc3339", function()
    T.eq(known:format_rfc3339(), "2023-11-14T22:13:20Z")
  end)

  T.it("format_date", function()
    T.eq(known:format_date(), "2023-11-14")
  end)

  T.it("format_time", function()
    T.eq(known:format_time(), "22:13:20")
  end)

  T.it("format with strftime codes", function()
    T.eq(known:format("%Y/%m/%d"), "2023/11/14")
  end)

  T.it("tostring via __tostring", function()
    T.eq(tostring(known), "2023-11-14T22:13:20Z")
  end)
end)

-- ── parse_rfc3339 ─────────────────────────────────────────────────────────────

T.describe("time.parse_rfc3339", function()
  T.it("parses UTC Z suffix", function()
    local t, err = time.parse_rfc3339("2023-11-14T22:13:20Z")
    T.eq(err, nil)
    T.eq(t:to_unix(), 1700000000)
  end)

  T.it("parses positive offset", function()
    -- +05:30 is 5.5h ahead of UTC → UTC time = 22:13:20 - 5:30 = 16:43:20
    local t, err = time.parse_rfc3339("2023-11-15T03:43:20+05:30")
    T.eq(err, nil)
    T.eq(t:to_unix(), 1700000000)
  end)

  T.it("parses negative offset", function()
    -- -05:00 is 5h behind UTC → UTC = wall + 5h
    local t, err = time.parse_rfc3339("2023-11-14T17:13:20-05:00")
    T.eq(err, nil)
    T.eq(t:to_unix(), 1700000000)
  end)

  T.it("parses date-only (no time)", function()
    local t, err = time.parse_rfc3339("1970-01-01")
    T.eq(err, nil)
    T.eq(t:to_unix(), 0)
  end)

  T.it("parses fractional seconds", function()
    local t, err = time.parse_rfc3339("1970-01-01T00:00:00.500Z")
    T.eq(err, nil)
    T.eq(t:to_unix(), 0)
    T.eq(t:to_unix_ms(), 500)
  end)

  T.it("roundtrip: parse → format_rfc3339", function()
    local s = "2023-11-14T22:13:20Z"
    local t, err = time.parse_rfc3339(s)
    T.eq(err, nil)
    T.eq(t:format_rfc3339(), s)
  end)

  T.it("returns error on garbage", function()
    local t, err = time.parse_rfc3339("not-a-date")
    T.eq(t, nil)
    T.ok(type(err) == "string")
  end)

  T.it("epoch 0 = 1970-01-01T00:00:00Z", function()
    local t = time.from_unix(0)
    T.eq(t:format_rfc3339(), "1970-01-01T00:00:00Z")
  end)
end)
