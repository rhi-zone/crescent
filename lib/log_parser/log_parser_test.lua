if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.log_parser")

-- ── Sample log lines ──────────────────────────────────────────────────────────

local COMBINED_LINE =
  '127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif?foo=bar HTTP/1.0" 200 2326 "http://www.example.com/start.html" "Mozilla/4.08 [en] (Win98; I ;Nav)"'

local COMMON_LINE =
  '127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif HTTP/1.0" 200 2326'

local SYSLOG_LINE =
  'Oct 11 22:14:15 mymachine su[1234]: su root failed for lonvick on /dev/pts/8'

local JSON_LINE = '{"level":"info","msg":"started","port":8080,"debug":true}'

local LOGFMT_LINE = 'level=info msg="hello world" status=200 cached=true bytes=1024'

-- ── parse combined access log ─────────────────────────────────────────────────

T.describe("parse combined log", function()
  T.it("parses all fields", function()
    local e, err = M.parse(COMBINED_LINE, "combined")
    T.ok(e, err)
    T.eq(e.ip, "127.0.0.1")
    T.eq(e.ident, nil)         -- "-" becomes nil
    T.eq(e.user, "frank")
    T.eq(e.method, "GET")
    T.eq(e.path, "/apache_pb.gif")
    T.eq(e.query, "foo=bar")
    T.eq(e.protocol, "HTTP/1.0")
    T.eq(e.status, 200)
    T.eq(e.bytes, 2326)
    T.eq(e.referrer, "http://www.example.com/start.html")
    T.ok(e.user_agent:find("Mozilla"))
    T.ok(e.timestamp ~= nil, "timestamp should be parsed")
  end)

  T.it("parses common log (no referrer/ua)", function()
    local e, err = M.parse(COMMON_LINE, "common")
    T.ok(e, err)
    T.eq(e.ip, "127.0.0.1")
    T.eq(e.status, 200)
    T.eq(e.bytes, 2326)
    T.eq(e.referrer, nil)
    T.eq(e.user_agent, nil)
  end)

  T.it("returns nil+err on malformed line", function()
    local e, err = M.parse("not a log line", "combined")
    T.eq(e, nil)
    T.ok(err and err:find("log_parser"))
  end)
end)

-- ── parse syslog ──────────────────────────────────────────────────────────────

T.describe("parse syslog", function()
  T.it("parses timestamp, hostname, app, pid, message", function()
    local e, err = M.parse(SYSLOG_LINE, "syslog")
    T.ok(e, err)
    T.ok(e.timestamp:find("Oct"))
    T.eq(e.hostname, "mymachine")
    T.eq(e.app, "su")
    T.eq(e.pid, 1234)
    T.ok(e.message:find("su root failed"))
  end)

  T.it("parses syslog with priority prefix", function()
    local line = "<13>Oct 11 22:14:15 host app[42]: test message"
    local e, err = M.parse(line, "syslog")
    T.ok(e, err)
    T.eq(e.hostname, "host")
    T.eq(e.pid, 42)
    T.eq(e.message, "test message")
  end)

  T.it("parses syslog without pid", function()
    local line = "Oct 11 22:14:15 myhost kernel: OOM killer invoked"
    local e, err = M.parse(line, "syslog")
    T.ok(e, err)
    T.eq(e.hostname, "myhost")
    T.eq(e.app, "kernel")
    T.eq(e.pid, nil)
    T.ok(e.message:find("OOM"))
  end)
end)

-- ── parse logfmt ──────────────────────────────────────────────────────────────

T.describe("parse logfmt", function()
  T.it("parses quoted values, numbers, booleans", function()
    local e, err = M.parse(LOGFMT_LINE, "logfmt")
    T.ok(e, err)
    T.eq(e.level, "info")
    T.eq(e.msg, "hello world")
    T.eq(e.status, 200)
    T.eq(e.cached, true)
    T.eq(e.bytes, 1024)
  end)

  T.it("parses false boolean", function()
    local e = M.parse("ok=false count=0", "logfmt")
    T.eq(e.ok, false)
    T.eq(e.count, 0)
  end)

  T.it("parses empty string value", function()
    local e = M.parse('key="" other=val', "logfmt")
    T.eq(e.key, "")
    T.eq(e.other, "val")
  end)
end)

-- ── parse JSON ────────────────────────────────────────────────────────────────

T.describe("parse json", function()
  T.it("parses flat JSON object", function()
    local e, err = M.parse(JSON_LINE, "json")
    T.ok(e, err)
    T.eq(e.level, "info")
    T.eq(e.msg, "started")
    T.eq(e.port, 8080)
    T.eq(e.debug, true)
  end)

  T.it("returns nil+err for non-object JSON", function()
    local e, err = M.parse('"just a string"', "json")
    T.eq(e, nil)
    T.ok(err)
  end)

  T.it("parses null values as nil", function()
    local e = M.parse('{"key":null}', "json")
    T.ok(e)
    T.eq(e.key, nil)
  end)
end)

-- ── detect ────────────────────────────────────────────────────────────────────

T.describe("detect", function()
  T.it("detects combined log", function()
    T.eq(M.detect(COMBINED_LINE), "combined")
  end)
  T.it("detects syslog", function()
    T.eq(M.detect(SYSLOG_LINE), "syslog")
  end)
  T.it("detects json", function()
    T.eq(M.detect(JSON_LINE), "json")
  end)
  T.it("detects logfmt", function()
    T.eq(M.detect(LOGFMT_LINE), "logfmt")
  end)
  T.it("returns nil for empty string", function()
    T.eq(M.detect(""), nil)
  end)
end)

-- ── pattern() ────────────────────────────────────────────────────────────────

T.describe("pattern()", function()
  T.it("parses with custom pattern", function()
    -- brackets in format string are literal matchers; capture gets inner content
    local parser = M.pattern("%{ip:ip} [%{time:str}] %{status:int} %{bytes:int}")
    local result = parser('192.168.1.1 [2024-01-15T10:30:00Z] 404 512')
    T.ok(result)
    T.eq(result.ip, "192.168.1.1")
    T.eq(result.time, "2024-01-15T10:30:00Z")
    T.eq(result.status, 404)
    T.eq(result.bytes, 512)
  end)

  T.it("returns nil on non-matching line", function()
    local parser = M.pattern("%{ip:ip} %{status:int}")
    local result = parser("not-an-ip 200")
    T.eq(result, nil)
  end)

  T.it("parses float type", function()
    local parser = M.pattern("%{name:str} %{score:float}")
    local result = parser("alice 98.6")
    T.ok(result)
    T.eq(result.name, "alice")
    T.eq(result.score, 98.6)
  end)
end)

-- ── parse_lines ───────────────────────────────────────────────────────────────

T.describe("parse_lines", function()
  T.it("parses multiple lines and collects errors", function()
    local text = table.concat({
      COMBINED_LINE,
      "not a valid line here",
      '127.0.0.2 - - [10/Oct/2000:14:00:00 -0700] "POST /api HTTP/1.1" 201 0 "-" "-"',
    }, "\n")
    local entries, errors = M.parse_lines(text, "combined")
    T.eq(#entries, 2)
    T.eq(#errors, 1)
    T.eq(errors[1].line_num, 2)
    T.ok(errors[1].err:find("log_parser"))
  end)

  T.it("parses zero lines from empty text", function()
    local entries, errors = M.parse_lines("", "combined")
    T.eq(#entries, 0)
    T.eq(#errors, 0)
  end)
end)

-- ── filter_status ─────────────────────────────────────────────────────────────

local function make_entries(statuses)
  local out = {}
  for _, s in ipairs(statuses) do
    out[#out + 1] = { status = s, method = "GET", path = "/", timestamp = 1000 }
  end
  return out
end

T.describe("filter_status", function()
  local entries = make_entries({200, 201, 301, 404, 500, 503})

  T.it("exact match", function()
    local r = M.filter_status(entries, 200)
    T.eq(#r, 1)
    T.eq(r[1].status, 200)
  end)

  T.it("class 4xx", function()
    local r = M.filter_status(entries, "4xx")
    T.eq(#r, 1)
    T.eq(r[1].status, 404)
  end)

  T.it("range {400,499}", function()
    local r = M.filter_status(entries, {400, 499})
    T.eq(#r, 1)
    T.eq(r[1].status, 404)
  end)

  T.it("range {500,599}", function()
    local r = M.filter_status(entries, {500, 599})
    T.eq(#r, 2)
  end)
end)

-- ── filter_method ─────────────────────────────────────────────────────────────

T.describe("filter_method", function()
  local entries = {
    { method = "GET", status = 200 },
    { method = "POST", status = 201 },
    { method = "DELETE", status = 204 },
  }

  T.it("single method string", function()
    local r = M.filter_method(entries, "GET")
    T.eq(#r, 1)
    T.eq(r[1].method, "GET")
  end)

  T.it("multiple methods table", function()
    local r = M.filter_method(entries, {"GET", "POST"})
    T.eq(#r, 2)
  end)
end)

-- ── filter_path ───────────────────────────────────────────────────────────────

T.describe("filter_path", function()
  local entries = {
    { path = "/api/users", status = 200 },
    { path = "/api/orders", status = 200 },
    { path = "/static/style.css", status = 200 },
  }

  T.it("matches Lua pattern", function()
    local r = M.filter_path(entries, "^/api/")
    T.eq(#r, 2)
  end)

  T.it("matches specific path", function()
    local r = M.filter_path(entries, "%.css$")
    T.eq(#r, 1)
    T.eq(r[1].path, "/static/style.css")
  end)
end)

-- ── filter_time ───────────────────────────────────────────────────────────────

T.describe("filter_time", function()
  local entries = {
    { timestamp = 1000 },
    { timestamp = 2000 },
    { timestamp = 3000 },
    { timestamp = nil },
  }

  T.it("after filter", function()
    local r = M.filter_time(entries, 1500, nil)
    T.eq(#r, 2)
  end)

  T.it("before filter", function()
    local r = M.filter_time(entries, nil, 2500)
    T.eq(#r, 2)
  end)

  T.it("range filter", function()
    local r = M.filter_time(entries, 1500, 2500)
    T.eq(#r, 1)
    T.eq(r[1].timestamp, 2000)
  end)
end)

-- ── count_by ─────────────────────────────────────────────────────────────────

T.describe("count_by", function()
  T.it("counts entries by field", function()
    local entries = make_entries({200, 200, 404, 500, 200})
    local counts = M.count_by(entries, "status")
    T.eq(counts["200"], 3)
    T.eq(counts["404"], 1)
    T.eq(counts["500"], 1)
  end)
end)

-- ── top_n ────────────────────────────────────────────────────────────────────

T.describe("top_n", function()
  T.it("returns top n by frequency", function()
    local entries = make_entries({200, 200, 200, 404, 404, 500})
    local top = M.top_n(entries, "status", 2)
    T.eq(#top, 2)
    T.eq(top[1][1], "200")
    T.eq(top[1][2], 3)
    T.eq(top[2][2], 2)
  end)

  T.it("respects n limit", function()
    local entries = make_entries({200, 201, 202, 203, 204})
    local top = M.top_n(entries, "status", 3)
    T.eq(#top, 3)
  end)
end)

-- ── sum_by ───────────────────────────────────────────────────────────────────

T.describe("sum_by", function()
  T.it("sums numeric field total", function()
    local entries = {
      { bytes = 100 }, { bytes = 200 }, { bytes = 50 },
    }
    local total = M.sum_by(entries, "bytes")
    T.eq(total, 350)
  end)

  T.it("sums by group field", function()
    local entries = {
      { status = 200, bytes = 100 },
      { status = 200, bytes = 200 },
      { status = 404, bytes = 50 },
    }
    local sums = M.sum_by(entries, "bytes", "status")
    T.eq(sums["200"], 300)
    T.eq(sums["404"], 50)
  end)
end)

-- ── percentile ───────────────────────────────────────────────────────────────

T.describe("percentile", function()
  local values = {10, 20, 30, 40, 50, 60, 70, 80, 90, 100}

  T.it("p50 on known dataset", function()
    local p50 = M.percentile(values, 50)
    T.ok(p50 >= 40 and p50 <= 60, "p50 should be around 50, got " .. tostring(p50))
  end)

  T.it("p95 on known dataset", function()
    local p95 = M.percentile(values, 95)
    T.ok(p95 >= 90, "p95 should be >= 90, got " .. tostring(p95))
  end)

  T.it("p0 returns minimum", function()
    T.eq(M.percentile(values, 0), 10)
  end)

  T.it("p100 returns maximum", function()
    T.eq(M.percentile(values, 100), 100)
  end)

  T.it("returns nil for empty values", function()
    T.eq(M.percentile({}, 50), nil)
  end)
end)

-- ── parse_clf_time ────────────────────────────────────────────────────────────

T.describe("parse_clf_time", function()
  T.it("returns a unix timestamp number", function()
    local ts = M.parse_clf_time("[10/Oct/2000:13:55:36 -0700]")
    T.ok(type(ts) == "number", "expected number, got " .. type(ts))
    T.ok(ts > 0)
  end)

  T.it("returns nil for invalid string", function()
    T.eq(M.parse_clf_time("not a time"), nil)
  end)

  T.it("+0000 and -0000 produce same result", function()
    local t1 = M.parse_clf_time("[10/Oct/2000:13:55:36 +0000]")
    local t2 = M.parse_clf_time("[10/Oct/2000:13:55:36 -0000]")
    T.eq(t1, t2)
  end)
end)

-- ── parse_iso8601 ─────────────────────────────────────────────────────────────

T.describe("parse_iso8601", function()
  T.it("parses UTC Z suffix", function()
    local ts = M.parse_iso8601("2024-01-15T10:30:00Z")
    T.ok(type(ts) == "number")
    T.ok(ts > 0)
  end)

  T.it("parses positive offset", function()
    local ts_utc = M.parse_iso8601("2024-01-15T10:30:00Z")
    local ts_plus5 = M.parse_iso8601("2024-01-15T15:30:00+05:00")
    T.eq(ts_utc, ts_plus5)
  end)

  T.it("parses negative offset", function()
    local ts_utc = M.parse_iso8601("2024-01-15T10:30:00Z")
    local ts_neg5 = M.parse_iso8601("2024-01-15T05:30:00-05:00")
    T.eq(ts_utc, ts_neg5)
  end)

  T.it("returns nil for invalid string", function()
    T.eq(M.parse_iso8601("not a date"), nil)
  end)
end)

-- ── format_bytes ─────────────────────────────────────────────────────────────

T.describe("format_bytes", function()
  T.it("formats bytes", function()
    T.eq(M.format_bytes(512), "512 B")
  end)
  T.it("formats kilobytes", function()
    T.ok(M.format_bytes(1536):find("KB"))
  end)
  T.it("formats megabytes", function()
    T.ok(M.format_bytes(1.5 * 1024 * 1024):find("MB"))
  end)
  T.it("formats gigabytes", function()
    T.ok(M.format_bytes(2 * 1024 * 1024 * 1024):find("GB"))
  end)
end)

-- ── auto-detect parse ─────────────────────────────────────────────────────────

T.describe("parse with auto format", function()
  T.it("auto-detects and parses json", function()
    local e = M.parse(JSON_LINE, "auto")
    T.ok(e)
    T.eq(e.level, "info")
  end)

  T.it("returns error when format undetectable", function()
    local e, err = M.parse("   ", "auto")
    T.eq(e, nil)
    T.ok(err and err:find("detect"))
  end)
end)
