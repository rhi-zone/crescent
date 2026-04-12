if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.testing_utils")

-- ---------------------------------------------------------------------------
-- spy
-- ---------------------------------------------------------------------------

T.describe("spy", function()
  T.it("starts with zero call_count", function()
    local s = M.spy()
    T.eq(s.call_count, 0)
    T.eq(#s.calls, 0)
  end)

  T.it("records each call's args and return values", function()
    local s = M.spy(function(a, b) return a + b end)
    local result = s(3, 4)
    T.eq(result, 7)
    T.eq(s.call_count, 1)
    T.eq(s.calls[1].args[1], 3)
    T.eq(s.calls[1].args[2], 4)
    T.eq(s.calls[1].return_values[1], 7)
  end)

  T.it("accumulates multiple calls", function()
    local s = M.spy(function(x) return x * 2 end)
    s(1)
    s(2)
    s(3)
    T.eq(s.call_count, 3)
    T.eq(#s.calls, 3)
    T.eq(s.calls[3].args[1], 3)
  end)

  T.it("works as no-op when no fn given", function()
    local s = M.spy()
    local r = s("hello")
    T.eq(s.call_count, 1)
    -- no-op returns nothing
    T.eq(r, nil)
  end)

  T.it("restore is a no-op (standalone spy)", function()
    local s = M.spy()
    s:restore()  -- should not error
    T.ok(true)
  end)
end)

-- ---------------------------------------------------------------------------
-- stub
-- ---------------------------------------------------------------------------

T.describe("stub", function()
  T.it("always returns the configured value", function()
    local s = M.stub(42)
    T.eq(s("anything"), 42)
    T.eq(s("else"),     42)
    T.eq(s.call_count,  2)
  end)

  T.it("returns false stub value correctly", function()
    local s = M.stub(false)
    -- stub(false) wraps function() return false end
    -- The spy returns whatever fn returns; false is a valid return.
    local r = s()
    T.eq(r, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- mock
-- ---------------------------------------------------------------------------

T.describe("mock", function()
  T.it("replaces a method and records calls", function()
    local obj = { greet = function(name) return "hello " .. name end }
    local s = M.mock(obj, "greet")
    local result = obj.greet("world")
    T.eq(result, "hello world")
    T.eq(s.call_count, 1)
    T.eq(s.calls[1].args[1], "world")
  end)

  T.it("accepts a replacement function", function()
    local obj = { add = function(a, b) return a + b end }
    local s   = M.mock(obj, "add", function(a, b) return a * b end)
    T.eq(obj.add(3, 4), 12)
    T.eq(s.call_count, 1)
  end)

  T.it("restore puts original method back", function()
    local obj = { value = function() return 1 end }
    local original = obj.value
    local s = M.mock(obj, "value", function() return 99 end)
    T.eq(obj.value(), 99)
    s:restore()
    T.eq(obj.value, original)
    T.eq(obj.value(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.each
-- ---------------------------------------------------------------------------

T.describe("each", function()
  T.it("runs all cases", function()
    local ran = {}
    local cases = { {1, 2, 3}, {0, 0, 0}, {-1, 1, 0} }
    local body = M.each(cases, function(a, b, expected)
      ran[#ran + 1] = a + b
      T.eq(a + b, expected)
    end)
    body()
    T.eq(#ran, 3)
    T.eq(ran[1], 3)
    T.eq(ran[2], 0)
    T.eq(ran[3], 0)
  end)

  T.it("propagates failures", function()
    -- Use a raw error (not T.eq) so we don't corrupt global assertion counts.
    local body = M.each({{1, 2, 999}}, function(a, b, expected)
      if a + b ~= expected then
        error("mismatch")
      end
    end)
    local ok = pcall(body)
    T.eq(ok, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- deep_eq
-- ---------------------------------------------------------------------------

T.describe("deep_eq", function()
  T.it("equal flat tables", function()
    local ok, diff = M.deep_eq({1, 2, 3}, {1, 2, 3})
    T.ok(ok)
    T.eq(diff, "")
  end)

  T.it("equal nested tables", function()
    local ok = M.deep_eq({ a = { b = 1 } }, { a = { b = 1 } })
    T.ok(ok)
  end)

  T.it("detects value difference", function()
    local ok, diff = M.deep_eq({ name = "bob" }, { name = "alice" })
    T.eq(ok, false)
    T.ok(diff:find("name") ~= nil)
    T.ok(diff:find("alice") ~= nil)
    T.ok(diff:find("bob") ~= nil)
  end)

  T.it("detects nested path", function()
    local ok, diff = M.deep_eq(
      { users = { { name = "bob" } } },
      { users = { { name = "alice" } } }
    )
    T.eq(ok, false)
    T.ok(diff:find("users") ~= nil)
  end)

  T.it("detects extra key in actual", function()
    local ok, diff = M.deep_eq({ a = 1, b = 2 }, { a = 1 })
    T.eq(ok, false)
    T.ok(diff ~= "")
  end)

  T.it("detects missing key in actual", function()
    local ok, diff = M.deep_eq({ a = 1 }, { a = 1, b = 2 })
    T.eq(ok, false)
    T.ok(diff ~= "")
  end)

  T.it("detects type mismatch", function()
    local ok, diff = M.deep_eq("hello", 42)
    T.eq(ok, false)
    T.ok(diff:find("type") ~= nil)
  end)

  T.it("equal primitives", function()
    local ok = M.deep_eq(42, 42)
    T.ok(ok)
  end)
end)

-- ---------------------------------------------------------------------------
-- contains matcher
-- ---------------------------------------------------------------------------

T.describe("contains matcher", function()
  T.it("passes when actual has all subset keys", function()
    local m = M.contains({ x = 1, y = 2 })
    local ok, reason = m:test({ x = 1, y = 2, z = 3 })
    T.ok(ok)
    T.eq(reason, "")
  end)

  T.it("fails when a key is missing", function()
    local m = M.contains({ x = 1, z = 9 })
    local ok = m:test({ x = 1 })
    T.eq(ok, false)
  end)

  T.it("fails when a value differs", function()
    local m = M.contains({ x = 5 })
    local ok = m:test({ x = 99 })
    T.eq(ok, false)
  end)

  T.it("fails for non-table", function()
    local m = M.contains({ x = 1 })
    local ok = m:test("string")
    T.eq(ok, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- matches matcher
-- ---------------------------------------------------------------------------

T.describe("matches matcher", function()
  T.it("plain value equality", function()
    local m = M.matches({ name = "alice", age = 30 })
    local ok = m:test({ name = "alice", age = 30 })
    T.ok(ok)
  end)

  T.it("predicate functions", function()
    local m = M.matches({
      score = function(v) return v > 50, "score must be > 50" end,
    })
    local ok = m:test({ score = 80 })
    T.ok(ok)
    local ok2, reason2 = m:test({ score = 30 })
    T.eq(ok2, false)
    T.ok(reason2 ~= nil)
  end)

  T.it("fails when predicate returns false", function()
    local m = M.matches({ n = function(v) return v < 0 end })
    local ok = m:test({ n = 5 })
    T.eq(ok, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- any_of matcher
-- ---------------------------------------------------------------------------

T.describe("any_of matcher", function()
  T.it("matches one of plain values", function()
    local m = M.any_of(1, 2, 3)
    T.ok(m:test(2))
    T.eq(m:test(4), false)
  end)

  T.it("matches one of sub-matchers", function()
    local m = M.any_of(M.contains({ x = 1 }), M.contains({ y = 2 }))
    T.ok(m:test({ x = 1, z = 9 }))
    T.ok(m:test({ y = 2, z = 9 }))
    T.eq(m:test({ z = 9 }), false)
  end)
end)

-- ---------------------------------------------------------------------------
-- instance_of matcher
-- ---------------------------------------------------------------------------

T.describe("instance_of matcher", function()
  T.it("passes for correct metatable", function()
    local MT = {}
    MT.__index = MT
    local obj = setmetatable({}, MT)
    local m = M.instance_of(MT)
    T.ok(m:test(obj))
  end)

  T.it("fails for wrong metatable", function()
    local MT1 = {}
    local MT2 = {}
    local obj = setmetatable({}, MT2)
    local m = M.instance_of(MT1)
    T.eq(m:test(obj), false)
  end)
end)

-- ---------------------------------------------------------------------------
-- fake_clock
-- ---------------------------------------------------------------------------

T.describe("fake_clock", function()
  T.it("starts at given time", function()
    local c = M.fake_clock(100)
    T.eq(c.time, 100)
  end)

  T.it("defaults to 0", function()
    local c = M.fake_clock()
    T.eq(c.time, 0)
  end)

  T.it("advance increases time", function()
    local c = M.fake_clock(0)
    c:advance(10)
    T.eq(c.time, 10)
    c:advance(5)
    T.eq(c.time, 15)
  end)

  T.it("tick is alias for advance", function()
    local c = M.fake_clock(0)
    c:tick(7)
    T.eq(c.time, 7)
  end)

  T.it("advance returns clock for chaining", function()
    local c = M.fake_clock(0)
    local ret = c:advance(1)
    T.eq(ret, c)
  end)

  T.it("freeze returns clock", function()
    local c = M.fake_clock(5)
    local ret = c:freeze()
    T.eq(ret, c)
    T.eq(c.time, 5)
  end)

  T.it("as_fn returns function reading time", function()
    local c  = M.fake_clock(42)
    local fn = c:as_fn()
    T.eq(fn(), 42)
    c:advance(8)
    T.eq(fn(), 50)
  end)
end)

-- ---------------------------------------------------------------------------
-- http_recorder
-- ---------------------------------------------------------------------------

T.describe("http_recorder", function()
  T.it("responds to a matching expectation", function()
    local rec    = M.http_recorder()
    rec:expect("GET", "/hello"):respond(200, {}, "world")
    local client = rec:as_client()
    local status, _, body = client("GET", "/hello")
    T.eq(status, 200)
    T.eq(body, "world")
  end)

  T.it("assert_all_called passes when expectation met", function()
    local rec = M.http_recorder()
    rec:expect("POST", "/submit"):respond(201, {}, "ok")
    local client = rec:as_client()
    client("POST", "/submit")
    rec:assert_all_called()  -- should not error
    T.ok(true)
  end)

  T.it("assert_all_called fails when expectation not met", function()
    local rec = M.http_recorder()
    rec:expect("DELETE", "/item"):respond(204, {}, "")
    local ok = pcall(function() rec:assert_all_called() end)
    T.eq(ok, false)
  end)

  T.it("times(n) requires n calls", function()
    local rec = M.http_recorder()
    rec:expect("GET", "/ping"):respond(200, {}, "pong"):times(2)
    local client = rec:as_client()
    client("GET", "/ping")
    client("GET", "/ping")
    rec:assert_all_called()  -- both calls made
    T.ok(true)
  end)

  T.it("times(n) fails assert when only partial calls made", function()
    local rec = M.http_recorder()
    rec:expect("GET", "/ping"):respond(200, {}, ""):times(3)
    local client = rec:as_client()
    client("GET", "/ping")
    local ok = pcall(function() rec:assert_all_called() end)
    T.eq(ok, false)
  end)

  T.it("multiple expectations matched independently", function()
    local rec = M.http_recorder()
    rec:expect("GET",  "/a"):respond(200, {}, "a-body")
    rec:expect("POST", "/b"):respond(201, {}, "b-body")
    local client = rec:as_client()
    local s1, _, body1 = client("GET",  "/a")
    local s2, _, body2 = client("POST", "/b")
    T.eq(s1,    200)
    T.eq(body1, "a-body")
    T.eq(s2,    201)
    T.eq(body2, "b-body")
    rec:assert_all_called()
  end)

  T.it("strips scheme+host from url", function()
    local rec = M.http_recorder()
    rec:expect("GET", "/api/v1"):respond(200, {}, "ok")
    local client = rec:as_client()
    local status = client("GET", "http://example.com/api/v1")
    T.eq(status, 200)
  end)

  T.it("returns nil + error for unmatched request", function()
    local rec    = M.http_recorder()
    local client = rec:as_client()
    local status, err = client("GET", "/unknown")
    T.eq(status, nil)
    T.ok(err ~= nil)
  end)

  T.it("reset clears all expectations", function()
    local rec = M.http_recorder()
    rec:expect("GET", "/x"):respond(200, {}, "")
    rec:reset()
    T.eq(#rec._expectations, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- bench (smoke test — just check return shape)
-- ---------------------------------------------------------------------------

T.describe("bench", function()
  T.it("returns a result with expected fields", function()
    local result = M.bench(function() end, { iterations = 10, warmup = 2, min_ms = 0 })
    T.ok(result.iterations   >= 10)
    T.ok(result.total_ms     >= 0)
    T.ok(result.per_iter_ms  >= 0)
    T.ok(result.ops_per_sec  >  0)
  end)
end)
