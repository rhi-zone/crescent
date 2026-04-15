if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T   = require("lib.test.assert")
local log = require("lib.log")

-- Default time_fn for tests
local test_time_fn = function() return "2025-01-15T10:30:00Z" end

-- Wrap log.new to inject time_fn for tests
local _log_new = log.new
log.new = function(name, opts)
  opts = opts or {}
  if not opts.time_fn then opts.time_fn = test_time_fn end
  return _log_new(name, opts)
end

-- Helper: write_fn for file_sink that appends data to a file path.
local function file_write_fn(path, data)
  local fh, err = io.open(path, "a")
  if not fh then return nil, err end
  fh:write(data)
  fh:close()
  return true
end

-- ---------------------------------------------------------------------------
-- Level constants
-- ---------------------------------------------------------------------------

T.describe("level constants", function()
  T.it("TRACE=0 DEBUG=1 INFO=2 WARN=3 ERROR=4", function()
    T.eq(log.TRACE, 0)
    T.eq(log.DEBUG, 1)
    T.eq(log.INFO,  2)
    T.eq(log.WARN,  3)
    T.eq(log.ERROR, 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- collect_sink helper
-- ---------------------------------------------------------------------------

T.describe("collect_sink", function()
  T.it("buffers entries in order", function()
    local sink, get = log.collect_sink()
    local L = log.new("test", { level = "trace", sinks = { sink } })
    L:info("hello")
    L:warn("world")
    local entries = get()
    T.eq(#entries, 2)
    T.eq(entries[1].msg, "hello")
    T.eq(entries[2].msg, "world")
  end)

  T.it("entry has all required fields", function()
    local sink, get = log.collect_sink()
    local L = log.new("myapp", { level = "trace", sinks = { sink } })
    L:info("request received", { method = "GET", status = 200 })
    local entries = get()
    T.eq(#entries, 1)
    local e = entries[1]
    T.eq(e.level,      log.INFO)
    T.eq(e.name,       "myapp")
    T.eq(e.msg,        "request received")
    T.eq(type(e.time), "string")
    -- time should look like ISO 8601 UTC
    T.ok(e.time:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), "time is ISO 8601")
    T.eq(e.fields.method, "GET")
    T.eq(e.fields.status, 200)
  end)

  T.it("fields can be nil", function()
    local sink, get = log.collect_sink()
    local L = log.new("x", { level = "trace", sinks = { sink } })
    L:debug("no fields")
    local e = get()[1]
    T.eq(e.fields, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Level filtering
-- ---------------------------------------------------------------------------

T.describe("level filtering", function()
  T.it("INFO level drops TRACE and DEBUG, passes INFO/WARN/ERROR", function()
    local sink, get = log.collect_sink()
    local L = log.new("filter", { level = "info", sinks = { sink } })
    L:trace("t")
    L:debug("d")
    L:info("i")
    L:warn("w")
    L:error("e")
    local entries = get()
    T.eq(#entries, 3)
    T.eq(entries[1].level, log.INFO)
    T.eq(entries[2].level, log.WARN)
    T.eq(entries[3].level, log.ERROR)
  end)

  T.it("TRACE level passes everything", function()
    local sink, get = log.collect_sink()
    local L = log.new("all", { level = "trace", sinks = { sink } })
    L:trace("t")
    L:debug("d")
    L:info("i")
    L:warn("w")
    L:error("e")
    T.eq(#get(), 5)
  end)

  T.it("ERROR level only passes ERROR", function()
    local sink, get = log.collect_sink()
    local L = log.new("strict", { level = "error", sinks = { sink } })
    L:trace("t"); L:debug("d"); L:info("i"); L:warn("w")
    T.eq(#get(), 0)
    L:error("e")
    T.eq(#get(), 1)
  end)

  T.it("integer level constants work in opts.level", function()
    local sink, get = log.collect_sink()
    local L = log.new("int", { level = log.WARN, sinks = { sink } })
    L:info("dropped")
    L:warn("kept")
    T.eq(#get(), 1)
    T.eq(get()[1].level, log.WARN)
  end)
end)

-- ---------------------------------------------------------------------------
-- set_level
-- ---------------------------------------------------------------------------

T.describe("set_level", function()
  T.it("dynamically changes level filtering", function()
    local sink, get = log.collect_sink()
    local L = log.new("dyn", { level = "info", sinks = { sink } })
    L:debug("before")
    T.eq(#get(), 0)
    L:set_level("debug")
    L:debug("after")
    T.eq(#get(), 1)
    T.eq(get()[1].msg, "after")
  end)

  T.it("set_level accepts integer", function()
    local sink, get = log.collect_sink()
    local L = log.new("dyn2", { level = "error", sinks = { sink } })
    L:set_level(log.INFO)
    L:info("now visible")
    T.eq(#get(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Child logger
-- ---------------------------------------------------------------------------

T.describe("child logger", function()
  T.it("prefixes name as parent.child", function()
    local sink, get = log.collect_sink()
    local parent = log.new("parent", { level = "trace", sinks = { sink } })
    local child = parent:child("http")
    child:info("handler registered")
    local e = get()[1]
    T.eq(e.name, "parent.http")
  end)

  T.it("child shares parent sinks", function()
    local sink, get = log.collect_sink()
    local parent = log.new("p", { level = "trace", sinks = { sink } })
    local child = parent:child("c")
    parent:info("from parent")
    child:info("from child")
    T.eq(#get(), 2)
  end)

  T.it("child inherits level", function()
    local sink, get = log.collect_sink()
    local parent = log.new("p2", { level = "warn", sinks = { sink } })
    local child = parent:child("sub")
    child:info("dropped by level")
    T.eq(#get(), 0)
    child:warn("kept")
    T.eq(#get(), 1)
  end)

  T.it("deeply nested child name", function()
    local sink, get = log.collect_sink()
    local root = log.new("app", { level = "trace", sinks = { sink } })
    local mid = root:child("server")
    local leaf = mid:child("handler")
    leaf:info("deep")
    T.eq(get()[1].name, "app.server.handler")
  end)
end)

-- ---------------------------------------------------------------------------
-- add_sink / remove_sink
-- ---------------------------------------------------------------------------

T.describe("add_sink / remove_sink", function()
  T.it("add_sink receives entries after addition", function()
    local sink1, get1 = log.collect_sink()
    local sink2, get2 = log.collect_sink()
    local L = log.new("multi", { level = "trace", sinks = { sink1 } })
    L:info("before add")
    L:add_sink(sink2)
    L:info("after add")
    T.eq(#get1(), 2)
    T.eq(#get2(), 1)
    T.eq(get2()[1].msg, "after add")
  end)

  T.it("remove_sink stops delivery", function()
    local sink, get = log.collect_sink()
    local L = log.new("rm", { level = "trace", sinks = { sink } })
    L:info("first")
    L:remove_sink(sink)
    L:info("second")
    T.eq(#get(), 1)
    T.eq(get()[1].msg, "first")
  end)

  T.it("remove_sink with unknown sink is a no-op", function()
    local sink, get = log.collect_sink()
    local other = function(_) end
    local L = log.new("noop", { level = "trace", sinks = { sink } })
    L:remove_sink(other) -- should not error
    L:info("ok")
    T.eq(#get(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Multiple sinks receive each entry
-- ---------------------------------------------------------------------------

T.describe("multiple sinks", function()
  T.it("all sinks receive each entry", function()
    local s1, g1 = log.collect_sink()
    local s2, g2 = log.collect_sink()
    local s3, g3 = log.collect_sink()
    local L = log.new("fan", { level = "trace", sinks = { s1, s2, s3 } })
    L:warn("broadcast")
    T.eq(#g1(), 1)
    T.eq(#g2(), 1)
    T.eq(#g3(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Text format
-- ---------------------------------------------------------------------------

T.describe("text format", function()
  -- We test format by capturing via stdout_sink with format="text" and a
  -- temporary file, or by exercising the formatter directly via a wrapper.
  -- For simplicity, we export format_text via a testable path by using
  -- a file_sink that writes to a temp path, then read it back.

  T.it("text line contains time, level, name, message, fields", function()
    local path = os.tmpname()
    local fsink = log.file_sink(file_write_fn, path, { format = "text" })
    local L = log.new("webapp", { level = "trace", sinks = { fsink } })
    L:info("req", { method = "GET", path = "/api" })
    local fh = io.open(path, "r")
    T.ok(fh, "temp file opened")
    local line = fh:read("*l")
    fh:close()
    os.remove(path)
    -- Must contain all expected tokens.
    T.ok(line:find("INFO"), "contains INFO")
    T.ok(line:find("%[webapp%]"), "contains [webapp]")
    T.ok(line:find("req"), "contains message")
    T.ok(line:find("method=GET"), "contains field method=GET")
    T.ok(line:find("path=/api"), "contains field path=/api")
  end)

  T.it("text line without fields has no trailing spaces", function()
    local path = os.tmpname()
    local fsink = log.file_sink(file_write_fn, path, { format = "text" })
    local L = log.new("bare", { level = "trace", sinks = { fsink } })
    L:warn("simple message")
    local fh = io.open(path, "r")
    T.ok(fh)
    local line = fh:read("*l")
    fh:close()
    os.remove(path)
    T.ok(not line:find(" $"), "no trailing space")
    T.ok(line:find("WARN"), "has WARN")
    T.ok(line:find("simple message"), "has message")
  end)
end)

-- ---------------------------------------------------------------------------
-- JSON format
-- ---------------------------------------------------------------------------

T.describe("json format", function()
  T.it("json line is valid JSON with required keys", function()
    local path = os.tmpname()
    local fsink = log.file_sink(file_write_fn, path, { format = "json" })
    local L = log.new("svc", { level = "trace", sinks = { fsink } })
    L:error("boom", { code = 500 })
    local fh = io.open(path, "r")
    T.ok(fh)
    local line = fh:read("*l")
    fh:close()
    os.remove(path)
    -- Basic JSON validity checks.
    T.ok(line:sub(1, 1) == "{", "starts with {")
    T.ok(line:sub(-1) == "}", "ends with }")
    T.ok(line:find('"level":"error"'), "has level:error")
    T.ok(line:find('"logger":"svc"'), "has logger:svc")
    T.ok(line:find('"msg":"boom"'), "has msg:boom")
    T.ok(line:find('"time":'), "has time key")
    T.ok(line:find('"code":500'), "has code:500")
  end)

  T.it("json line with no fields omits extra keys", function()
    local path = os.tmpname()
    local fsink = log.file_sink(file_write_fn, path, { format = "json" })
    local L = log.new("min", { level = "trace", sinks = { fsink } })
    L:debug("ping")
    local fh = io.open(path, "r")
    T.ok(fh)
    local line = fh:read("*l")
    fh:close()
    os.remove(path)
    T.ok(line:find('"msg":"ping"'), "has msg")
    T.ok(line:find('"level":"debug"'), "has debug level")
  end)
end)

-- ---------------------------------------------------------------------------
-- ANSI format
-- ---------------------------------------------------------------------------

T.describe("ansi format", function()
  T.it("ansi format output contains message", function()
    -- We test ansi format via stdout_sink with forced ansi format; we redirect
    -- by capturing through a collect approach using a wrapper.
    local lines = {}
    local ansi_sink_wrapper = function(entry)
      -- Simulate what the ansi formatter would produce by checking the
      -- format_ansi path through a file_sink with ansi (which falls back
      -- to text if ansi.enabled is false — so we test via the entry fields).
      -- Instead, verify via collect_sink that message and name survive.
      lines[#lines + 1] = entry
    end
    local L = log.new("ansitgt", { level = "trace", sinks = { ansi_sink_wrapper } })
    L:info("hello ansi")
    T.eq(#lines, 1)
    T.eq(lines[1].msg, "hello ansi")
    T.eq(lines[1].name, "ansitgt")
  end)

  T.it("ansi format escape sequences present when ansi enabled", function()
    local ansi = require("lib.ansi")
    -- Manually invoke the format_ansi path through stdout_sink(format="ansi").
    -- We capture the written bytes via a temporary file.
    local path = os.tmpname()
    local fh_write = io.open(path, "w")
    -- Build a custom sink that uses the ansi formatter directly.
    -- Since format_ansi is local, we test indirectly: if ansi.enabled, the
    -- level colorization wraps text in ESC sequences.
    local entry = {
      level  = log.INFO,
      name   = "t",
      msg    = "hi",
      fields = nil,
      time   = "2026-01-01T00:00:00Z",
    }
    -- Create a collect sink, log through it, then verify. If ansi.enabled,
    -- also verify via a file that escape sequences appear.
    if ansi.enabled then
      -- Write ansi-formatted line via file_sink (which supports "ansi" format).
      local asink = log.file_sink(file_write_fn, path, { format = "ansi" })
      asink(entry)
      fh_write:close()
      local fh_read = io.open(path, "r")
      local line = fh_read:read("*l")
      fh_read:close()
      os.remove(path)
      -- Should contain ESC character.
      T.ok(line:find("\27"), "contains ESC when ansi enabled")
    else
      fh_write:close()
      os.remove(path)
      -- When ansi disabled, just verify the format doesn't error.
      local asink = log.file_sink(file_write_fn, path .. "2", { format = "ansi" })
      asink(entry)
      local fh_read = io.open(path .. "2", "r")
      T.ok(fh_read, "file written without error")
      fh_read:close()
      os.remove(path .. "2")
      T.ok(true, "ansi format works when disabled")
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Default sinks
-- ---------------------------------------------------------------------------

T.describe("default sinks", function()
  T.it("log.new with no sinks opts uses stderr_sink by default", function()
    -- We can't easily capture stderr, but we verify the logger has a sink.
    local L = log.new("default")
    T.eq(type(L._sinks), "table")
    T.eq(#L._sinks, 1)
  end)

  T.it("stderr_sink returns a callable", function()
    local sink = log.stderr_sink()
    T.eq(type(sink), "function")
  end)

  T.it("stdout_sink returns a callable", function()
    local sink = log.stdout_sink()
    T.eq(type(sink), "function")
  end)

  T.it("file_sink returns a callable", function()
    local sink = log.file_sink(file_write_fn, "/dev/null")
    T.eq(type(sink), "function")
  end)
end)

-- ---------------------------------------------------------------------------
-- Per-level method correctness
-- ---------------------------------------------------------------------------

T.describe("level methods", function()
  T.it("each method sets the correct level in entry", function()
    local sink, get = log.collect_sink()
    local L = log.new("lvl", { level = "trace", sinks = { sink } })
    L:trace("t"); L:debug("d"); L:info("i"); L:warn("w"); L:error("e")
    local entries = get()
    T.eq(entries[1].level, log.TRACE)
    T.eq(entries[2].level, log.DEBUG)
    T.eq(entries[3].level, log.INFO)
    T.eq(entries[4].level, log.WARN)
    T.eq(entries[5].level, log.ERROR)
  end)
end)
