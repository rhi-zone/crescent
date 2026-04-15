if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local cron = require("lib.cron_parser")

-- Wrap cron.parse to inject os.date for tests
local _cron_parse = cron.parse
cron.parse = function(expr, opts)
  opts = opts or {}
  if not opts.date_fn then opts.date_fn = os.date end
  return _cron_parse(expr, opts)
end

-- Deep equality for arrays/tables (T.eq only does reference equality)
local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function teq(a, b, msg)
  T.ok(deep_eq(a, b), (msg and msg .. ": " or "") ..
    "not equal: got " .. tostring(a) .. " expected " .. tostring(b))
end

-- ---------------------------------------------------------------------------
-- parse_field
-- ---------------------------------------------------------------------------

T.describe("cron_parser.parse_field", function()

  T.it("* expands to full range", function()
    local f = cron.parse_field("*", 0, 5)
    teq(f, {0, 1, 2, 3, 4, 5})
  end)

  T.it("single value", function()
    local f = cron.parse_field("3", 0, 59)
    teq(f, {3})
  end)

  T.it("range n-m", function()
    local f = cron.parse_field("2-5", 0, 59)
    teq(f, {2, 3, 4, 5})
  end)

  T.it("step */n", function()
    local f = cron.parse_field("*/15", 0, 59)
    teq(f, {0, 15, 30, 45})
  end)

  T.it("range with step n-m/n", function()
    local f = cron.parse_field("10-40/10", 0, 59)
    teq(f, {10, 20, 30, 40})
  end)

  T.it("comma list", function()
    local f = cron.parse_field("1,3,5", 0, 59)
    teq(f, {1, 3, 5})
  end)

  T.it("mixed list with ranges", function()
    local f = cron.parse_field("1,3-5,10", 0, 59)
    teq(f, {1, 3, 4, 5, 10})
  end)

  T.it("deduplicates values", function()
    local f = cron.parse_field("1,1,2", 0, 59)
    teq(f, {1, 2})
  end)

  T.it("sorts result", function()
    local f = cron.parse_field("5,2,8", 0, 59)
    teq(f, {2, 5, 8})
  end)

  T.it("month names without names table fail", function()
    local f, e = cron.parse_field("JAN", 1, 12, nil)
    T.eq(f, nil)
  end)

  T.it("month names with names table via parse()", function()
    local sched = cron.parse("0 0 1 JAN *")
    T.ok(sched ~= nil)
    teq(sched.fields.month, {1})
  end)

  T.it("month range with names", function()
    local sched = cron.parse("0 0 1 jan-mar *")
    T.ok(sched ~= nil)
    teq(sched.fields.month, {1, 2, 3})
  end)

  T.it("weekday names", function()
    local sched = cron.parse("0 0 * * MON")
    T.ok(sched ~= nil)
    teq(sched.fields.dow, {1})
  end)

  T.it("weekday range mon-fri", function()
    local sched = cron.parse("0 9 * * mon-fri")
    T.ok(sched ~= nil)
    teq(sched.fields.dow, {1, 2, 3, 4, 5})
  end)

  T.it("dow 7 normalized to 0 (Sunday)", function()
    local sched = cron.parse("0 0 * * 7")
    T.ok(sched ~= nil)
    teq(sched.fields.dow, {0})
  end)

  T.it("error on out-of-range value", function()
    local f, e = cron.parse_field("60", 0, 59)
    T.eq(f, nil)
    T.ok(e ~= nil)
  end)

  T.it("error on invalid step 0", function()
    local f, e = cron.parse_field("*/0", 0, 59)
    T.eq(f, nil)
    T.ok(e ~= nil)
  end)

  T.it("* for hours full range 0-23", function()
    local f = cron.parse_field("*", 0, 23)
    T.eq(#f, 24)
    T.eq(f[1], 0)
    T.eq(f[24], 23)
  end)

end)

-- ---------------------------------------------------------------------------
-- parse
-- ---------------------------------------------------------------------------

T.describe("cron_parser.parse", function()

  T.it("parses 5-field every-5-minutes", function()
    local s, e = cron.parse("*/5 * * * *")
    T.ok(s ~= nil, e)
    teq(s.fields.minute, {0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55})
    T.eq(#s.fields.hour, 24)
  end)

  T.it("parses 6-field expression with seconds", function()
    local s, e = cron.parse("0 */5 * * * *")
    T.ok(s ~= nil, e)
    T.ok(s.fields.second ~= nil)
    teq(s.fields.second, {0})
    teq(s.fields.minute, {0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55})
  end)

  T.it("parses 9am Mon-Fri", function()
    local s, e = cron.parse("0 9 * * 1-5")
    T.ok(s ~= nil, e)
    teq(s.fields.minute, {0})
    teq(s.fields.hour, {9})
    teq(s.fields.dow, {1, 2, 3, 4, 5})
  end)

  T.it("parses 1st and 15th midnight", function()
    local s, e = cron.parse("0 0 1,15 * *")
    T.ok(s ~= nil, e)
    teq(s.fields.dom, {1, 15})
    teq(s.fields.hour, {0})
    teq(s.fields.minute, {0})
  end)

  T.it("parses 2:30pm Friday", function()
    local s, e = cron.parse("30 14 * * 5")
    T.ok(s ~= nil, e)
    teq(s.fields.minute, {30})
    teq(s.fields.hour, {14})
    teq(s.fields.dow, {5})
  end)

  T.it("error on too few fields", function()
    local s, e = cron.parse("* * * *")
    T.eq(s, nil)
    T.ok(e ~= nil)
  end)

  T.it("error on too many fields", function()
    local s, e = cron.parse("* * * * * * *")
    T.eq(s, nil)
    T.ok(e ~= nil)
  end)

  T.it("error on non-string", function()
    local s, e = cron.parse(42)
    T.eq(s, nil)
    T.ok(e ~= nil)
  end)

  T.it("trims whitespace", function()
    local s, e = cron.parse("  * * * * *  ")
    T.ok(s ~= nil, e)
  end)

end)

-- ---------------------------------------------------------------------------
-- @aliases
-- ---------------------------------------------------------------------------

T.describe("cron_parser @aliases", function()

  T.it("@hourly: minute=0, all hours", function()
    local s = cron.parse("@hourly")
    T.ok(s ~= nil)
    teq(s.fields.minute, {0})
    T.eq(#s.fields.hour, 24)
  end)

  T.it("@daily: minute=0, hour=0", function()
    local s = cron.parse("@daily")
    T.ok(s ~= nil)
    teq(s.fields.minute, {0})
    teq(s.fields.hour, {0})
  end)

  T.it("@midnight: minute=0, hour=0", function()
    local s = cron.parse("@midnight")
    T.ok(s ~= nil)
    teq(s.fields.minute, {0})
    teq(s.fields.hour, {0})
  end)

  T.it("@weekly: Sunday midnight", function()
    local s = cron.parse("@weekly")
    T.ok(s ~= nil)
    teq(s.fields.minute, {0})
    teq(s.fields.hour, {0})
    teq(s.fields.dow, {0})
  end)

  T.it("@monthly: dom=1, midnight", function()
    local s = cron.parse("@monthly")
    T.ok(s ~= nil)
    teq(s.fields.dom, {1})
    teq(s.fields.minute, {0})
    teq(s.fields.hour, {0})
  end)

  T.it("@yearly: Jan 1 midnight", function()
    local s = cron.parse("@yearly")
    T.ok(s ~= nil)
    teq(s.fields.dom, {1})
    teq(s.fields.month, {1})
  end)

  T.it("@annually: same as @yearly", function()
    local s = cron.parse("@annually")
    T.ok(s ~= nil)
    teq(s.fields.month, {1})
    teq(s.fields.dom, {1})
  end)

  T.it("alias case-insensitive", function()
    local s = cron.parse("@HOURLY")
    T.ok(s ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
-- matches
-- ---------------------------------------------------------------------------

T.describe("cron_parser.matches", function()

  T.it("every-minute schedule matches at second=0", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local ts = now - t.sec
    T.ok(s:matches(ts))
  end)

  T.it("5-field: does not match at second != 0", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local ts = now - t.sec + 30
    T.ok(not s:matches(ts))
  end)

  T.it("specific minute: next result matches and has correct min/sec", function()
    local s = cron.parse("30 * * * *")
    local next_ts = s:next(os.time())
    T.ok(next_ts ~= nil)
    T.ok(s:matches(next_ts))
    local td = os.date("*t", next_ts)
    T.eq(td.min, 30)
    T.eq(td.sec, 0)
  end)

  T.it("specific hour: next result has correct hour", function()
    local s = cron.parse("0 14 * * *")
    local next_ts = s:next(os.time())
    T.ok(next_ts ~= nil)
    local td = os.date("*t", next_ts)
    T.eq(td.hour, 14)
    T.eq(td.min, 0)
  end)

  T.it("specific dow: next result is correct weekday", function()
    local s = cron.parse("0 0 * * 1")  -- Monday midnight
    local next_ts = s:next(os.time())
    T.ok(next_ts ~= nil)
    local td = os.date("*t", next_ts)
    T.eq(td.wday, 2)  -- 2=Monday in os.date
  end)

  T.it("does not match one minute after a match", function()
    local s = cron.parse("30 * * * *")
    local next_ts = s:next(os.time())
    T.ok(next_ts ~= nil)
    T.ok(not s:matches(next_ts + 60))
  end)

  T.it("6-field: matches at correct second", function()
    local s = cron.parse("30 * * * * *")
    local next_ts = s:next(os.time())
    T.ok(next_ts ~= nil)
    local td = os.date("*t", next_ts)
    T.eq(td.sec, 30)
    T.ok(s:matches(next_ts))
    T.ok(not s:matches(next_ts + 1))
  end)

end)

-- ---------------------------------------------------------------------------
-- next
-- ---------------------------------------------------------------------------

T.describe("cron_parser.next", function()

  T.it("every-minute: next is within 60 seconds", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local n = s:next(now)
    T.ok(n ~= nil)
    T.ok(n > now)
    T.ok(n <= now + 60)
  end)

  T.it("every-minute: sequential calls 60 seconds apart", function()
    local s = cron.parse("* * * * *")
    local t0 = os.time()
    local t1 = s:next(t0)
    local t2 = s:next(t1)
    local t3 = s:next(t2)
    T.ok(t1 ~= nil)
    T.ok(t2 ~= nil)
    T.ok(t3 ~= nil)
    T.eq(t2 - t1, 60)
    T.eq(t3 - t2, 60)
  end)

  T.it("every-5-minutes: gap is 300 seconds", function()
    local s = cron.parse("*/5 * * * *")
    local t0 = os.time()
    local t1 = s:next(t0)
    local t2 = s:next(t1)
    T.ok(t1 ~= nil)
    T.ok(t2 ~= nil)
    T.eq(t2 - t1, 300)
  end)

  T.it("hourly: gap is 3600 seconds", function()
    local s = cron.parse("@hourly")
    local t0 = os.time()
    local t1 = s:next(t0)
    local t2 = s:next(t1)
    T.ok(t1 ~= nil)
    T.ok(t2 ~= nil)
    T.eq(t2 - t1, 3600)
  end)

  T.it("daily: gap is 86400 seconds", function()
    local s = cron.parse("@daily")
    local t0 = os.time()
    local t1 = s:next(t0)
    local t2 = s:next(t1)
    T.ok(t1 ~= nil)
    T.ok(t2 ~= nil)
    T.eq(t2 - t1, 86400)
  end)

  T.it("n=2 returns 2nd occurrence, 60s after 1st", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t1 = s:next(now, 1)
    local t2 = s:next(now, 2)
    T.ok(t1 ~= nil)
    T.ok(t2 ~= nil)
    T.eq(t2 - t1, 60)
  end)

  T.it("result is strictly after input", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local n = s:next(now)
    T.ok(n > now)
  end)

  T.it("next result matches the schedule", function()
    local s = cron.parse("*/5 * * * *")
    local n = s:next(os.time())
    T.ok(s:matches(n))
  end)

end)

-- ---------------------------------------------------------------------------
-- prev
-- ---------------------------------------------------------------------------

T.describe("cron_parser.prev", function()

  T.it("every-minute: prev is before now and within 60 seconds", function()
    local s = cron.parse("* * * * *")
    -- ensure there is at least one minute-boundary behind us
    local now = os.time()
    local t = os.date("*t", now)
    -- snap to current minute boundary, then query 1 second after so prev is well-defined
    local snap = now - t.sec + 1
    local p = s:prev(snap)
    T.ok(p ~= nil)
    T.ok(p < snap)
  end)

  T.it("prev result matches the schedule", function()
    local s = cron.parse("*/5 * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    -- ensure we're past at least one 5-min mark
    local query = now - t.sec + 1
    local p = s:prev(query)
    if p ~= nil then
      T.ok(s:matches(p))
    end
  end)

  T.it("every-minute: consecutive prev calls 60 seconds apart", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local snap = now - t.sec + 1  -- 1 second past minute boundary
    local p1 = s:prev(snap)
    T.ok(p1 ~= nil)
    local p2 = s:prev(p1)
    T.ok(p2 ~= nil)
    T.ok(p2 < p1)
    T.eq(p1 - p2, 60)
  end)

end)

-- ---------------------------------------------------------------------------
-- range
-- ---------------------------------------------------------------------------

T.describe("cron_parser.range", function()

  T.it("every-minute in 10-minute window returns 10 entries", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local start = now - t.sec
    local stop  = start + 9 * 60
    local r = s:range(start, stop)
    T.eq(#r, 10)
  end)

  T.it("every-5-minutes in 1-hour window returns 12 entries", function()
    local s = cron.parse("*/5 * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local m = t.min - (t.min % 5)
    local start = now - t.sec - (t.min - m) * 60
    local stop  = start + 59 * 60
    local r = s:range(start, stop)
    T.eq(#r, 12)
  end)

  T.it("range is ordered ascending", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local start = now - t.sec
    local stop  = start + 5 * 60
    local r = s:range(start, stop)
    for i = 2, #r do
      T.ok(r[i] > r[i-1])
    end
  end)

  T.it("all results match the schedule", function()
    local s = cron.parse("*/15 * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local start = now - t.sec - t.min * 60
    local stop  = start + 3600 - 1
    local r = s:range(start, stop)
    for _, ts in ipairs(r) do
      T.ok(s:matches(ts))
    end
  end)

  T.it("empty range when window is mid-minute for 5-field", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local start = now - t.sec + 1   -- 1s past minute boundary
    local stop  = start + 58        -- 58s later, before next minute
    local r = s:range(start, stop)
    T.eq(#r, 0)
  end)

end)

-- ---------------------------------------------------------------------------
-- describe
-- ---------------------------------------------------------------------------

T.describe("cron_parser.describe", function()

  T.it("every 5 minutes", function()
    local s = cron.parse("*/5 * * * *")
    T.eq(s:describe(), "every 5 minutes")
  end)

  T.it("every minute", function()
    local s = cron.parse("* * * * *")
    T.eq(s:describe(), "every minute")
  end)

  T.it("every hour", function()
    local s = cron.parse("@hourly")
    T.eq(s:describe(), "every hour")
  end)

  T.it("every day at midnight", function()
    local s = cron.parse("@daily")
    T.eq(s:describe(), "every day at midnight")
  end)

  T.it("@midnight same as @daily", function()
    local s = cron.parse("@midnight")
    T.eq(s:describe(), "every day at midnight")
  end)

  T.it("@weekly: at midnight on Sunday", function()
    local s = cron.parse("@weekly")
    T.eq(s:describe(), "at midnight on Sunday")
  end)

  T.it("@monthly: at midnight on 1st", function()
    local s = cron.parse("@monthly")
    T.eq(s:describe(), "at midnight on the 1st of every month")
  end)

  T.it("@yearly: at midnight on January 1st", function()
    local s = cron.parse("@yearly")
    T.eq(s:describe(), "at midnight on January 1st")
  end)

  T.it("9am Mon-Fri", function()
    local s = cron.parse("0 9 * * 1-5")
    T.eq(s:describe(), "at 9:00 AM, Monday through Friday")
  end)

  T.it("2:30pm Friday", function()
    local s = cron.parse("30 14 * * 5")
    T.eq(s:describe(), "at 2:30 PM, Friday")
  end)

  T.it("midnight on 1st and 15th", function()
    local s = cron.parse("0 0 1,15 * *")
    T.eq(s:describe(), "at midnight on the 1st and 15th of every month")
  end)

  T.it("every 15 minutes", function()
    local s = cron.parse("*/15 * * * *")
    T.eq(s:describe(), "every 15 minutes")
  end)

end)

-- ---------------------------------------------------------------------------
-- validate
-- ---------------------------------------------------------------------------

T.describe("cron_parser.validate", function()

  T.it("valid expression returns true", function()
    local ok, e = cron.validate("*/5 * * * *")
    T.eq(ok, true)
    T.eq(e, nil)
  end)

  T.it("invalid expression returns nil + errmsg", function()
    local ok, e = cron.validate("not a cron")
    T.eq(ok, nil)
    T.ok(e ~= nil)
  end)

  T.it("out-of-range minute fails", function()
    local ok, e = cron.validate("60 * * * *")
    T.eq(ok, nil)
    T.ok(e ~= nil)
  end)

  T.it("out-of-range hour fails", function()
    local ok, e = cron.validate("0 24 * * *")
    T.eq(ok, nil)
    T.ok(e ~= nil)
  end)

  T.it("valid @alias passes", function()
    local ok, e = cron.validate("@hourly")
    T.eq(ok, true)
  end)

  T.it("invalid @alias fails", function()
    local ok, e = cron.validate("@invalid")
    T.eq(ok, nil)
    T.ok(e ~= nil)
  end)

end)

-- ---------------------------------------------------------------------------
-- Edge cases
-- ---------------------------------------------------------------------------

T.describe("cron_parser edge cases", function()

  T.it("dow 7 and dow 0 both normalize to Sunday=0", function()
    local s0 = cron.parse("0 0 * * 0")
    local s7 = cron.parse("0 0 * * 7")
    teq(s0.fields.dow, {0})
    teq(s7.fields.dow, {0})
  end)

  T.it("dow 0,7 deduplicates to single Sunday entry", function()
    local s = cron.parse("0 0 * * 0,7")
    teq(s.fields.dow, {0})
  end)

  T.it("month names case-insensitive: DEC=12", function()
    local s = cron.parse("0 0 1 DEC *")
    teq(s.fields.month, {12})
  end)

  T.it("month names case-insensitive mixed: Jan,Jun,Dec", function()
    local s = cron.parse("0 0 1 Jan,Jun,Dec *")
    teq(s.fields.month, {1, 6, 12})
  end)

  T.it("weekday SAT name = 6", function()
    local s = cron.parse("0 0 * * SAT")
    teq(s.fields.dow, {6})
  end)

  T.it("every-minute: matches at boundary, not +1s", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local base = now - t.sec
    T.ok(s:matches(base))
    T.ok(not s:matches(base + 1))
    T.ok(s:matches(base + 60))
  end)

  T.it("next is exclusive (doesn't return snap even if it matches)", function()
    local s = cron.parse("* * * * *")
    local now = os.time()
    local t = os.date("*t", now)
    local snap = now - t.sec
    T.ok(s:matches(snap))
    local n = s:next(snap)
    T.ok(n > snap)
  end)

  T.it("dom 31 parses correctly", function()
    local s = cron.parse("0 0 31 * *")
    T.ok(s ~= nil)
    teq(s.fields.dom, {31})
  end)

  T.it("parse_field * minute returns 60 values", function()
    local f = cron.parse_field("*", 0, 59)
    T.eq(#f, 60)
  end)

  T.it("parse_field */1 is same as *", function()
    local f1 = cron.parse_field("*", 0, 59)
    local f2 = cron.parse_field("*/1", 0, 59)
    T.ok(deep_eq(f1, f2))
  end)

  T.it("6-field seconds parsed correctly", function()
    local s = cron.parse("0 0 0 1 1 *")
    T.ok(s ~= nil)
    teq(s.fields.second, {0})
    teq(s.fields.minute, {0})
    teq(s.fields.hour, {0})
    teq(s.fields.dom, {1})
    teq(s.fields.month, {1})
  end)

end)
