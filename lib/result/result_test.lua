if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local R = require("lib.result")

-- ── Constructors ────────────────────────────────────────────────────────────

T.describe("result: ok constructor", function()
  T.it("creates an Ok result with a value", function()
    local r = R.ok(42)
    T.ok(r, "result is truthy")
    T.eq(r:is_ok(), true)
    T.eq(r:is_err(), false)
    T.eq(r:unwrap(), 42)
  end)

  T.it("creates Ok with string value", function()
    local r = R.ok("hello")
    T.eq(r:unwrap(), "hello")
  end)

  T.it("creates Ok with nil value", function()
    local r = R.ok(nil)
    T.eq(r:is_ok(), true)
    T.eq(r:is_err(), false)
    T.eq(r:unwrap(), nil)
  end)

  T.it("creates Ok with false value", function()
    local r = R.ok(false)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), false)
  end)

  T.it("creates Ok with table value", function()
    local t = { a = 1 }
    local r = R.ok(t)
    T.eq(r:unwrap(), t)
  end)

  T.it("creates Ok with zero", function()
    local r = R.ok(0)
    T.eq(r:unwrap(), 0)
  end)
end)

T.describe("result: err constructor", function()
  T.it("creates an Err result", function()
    local r = R.err("something failed")
    T.ok(r, "result is truthy")
    T.eq(r:is_ok(), false)
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "something failed")
  end)

  T.it("creates Err with table value", function()
    local e = { code = 404, msg = "not found" }
    local r = R.err(e)
    T.eq(r:unwrap_err(), e)
  end)

  T.it("creates Err with nil error value", function()
    local r = R.err(nil)
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), nil)
  end)
end)

-- ── is_ok / is_err ─────────────────────────────────────────────────────────

T.describe("result: is_ok / is_err", function()
  T.it("is_ok returns true for Ok", function()
    T.eq(R.ok(1):is_ok(), true)
  end)

  T.it("is_ok returns false for Err", function()
    T.eq(R.err("e"):is_ok(), false)
  end)

  T.it("is_err returns true for Err", function()
    T.eq(R.err("e"):is_err(), true)
  end)

  T.it("is_err returns false for Ok", function()
    T.eq(R.ok(1):is_err(), false)
  end)
end)

-- ── unwrap ──────────────────────────────────────────────────────────────────

T.describe("result: unwrap", function()
  T.it("returns value for Ok", function()
    T.eq(R.ok(99):unwrap(), 99)
  end)

  T.it("errors for Err", function()
    T.throws(function() R.err("boom"):unwrap() end, "called unwrap on Err")
  end)

  T.it("unwrap on Ok(nil) returns nil", function()
    T.eq(R.ok(nil):unwrap(), nil)
  end)
end)

-- ── unwrap_or ───────────────────────────────────────────────────────────────

T.describe("result: unwrap_or", function()
  T.it("returns value for Ok", function()
    T.eq(R.ok(10):unwrap_or(0), 10)
  end)

  T.it("returns default for Err", function()
    T.eq(R.err("e"):unwrap_or(0), 0)
  end)

  T.it("returns Ok(nil) as nil, not default", function()
    T.eq(R.ok(nil):unwrap_or(42), nil)
  end)

  T.it("returns Ok(false) as false, not default", function()
    T.eq(R.ok(false):unwrap_or(true), false)
  end)
end)

-- ── unwrap_err ──────────────────────────────────────────────────────────────

T.describe("result: unwrap_err", function()
  T.it("returns error for Err", function()
    T.eq(R.err("bad"):unwrap_err(), "bad")
  end)

  T.it("errors for Ok", function()
    T.throws(function() R.ok(1):unwrap_err() end, "called unwrap_err on Ok")
  end)
end)

-- ── expect ──────────────────────────────────────────────────────────────────

T.describe("result: expect", function()
  T.it("returns value for Ok", function()
    T.eq(R.ok(5):expect("should not fail"), 5)
  end)

  T.it("errors with custom message for Err", function()
    T.throws(function() R.err("oops"):expect("custom msg") end, "custom msg")
  end)

  T.it("includes error value in message", function()
    T.throws(function() R.err("detail"):expect("failed") end, "detail")
  end)
end)

-- ── map ─────────────────────────────────────────────────────────────────────

T.describe("result: map", function()
  T.it("transforms Ok value", function()
    local r = R.ok(3):map(function(x) return x * 2 end)
    T.eq(r:unwrap(), 6)
  end)

  T.it("passes through Err unchanged", function()
    local r = R.err("e"):map(function(x) return x * 2 end)
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "e")
  end)

  T.it("chains multiple maps", function()
    local r = R.ok(1)
      :map(function(x) return x + 1 end)
      :map(function(x) return x * 10 end)
    T.eq(r:unwrap(), 20)
  end)

  T.it("map can return nil", function()
    local r = R.ok(1):map(function() return nil end)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), nil)
  end)
end)

-- ── map_err ─────────────────────────────────────────────────────────────────

T.describe("result: map_err", function()
  T.it("transforms Err value", function()
    local r = R.err("bad"):map_err(function(e) return "wrapped: " .. e end)
    T.eq(r:unwrap_err(), "wrapped: bad")
  end)

  T.it("passes through Ok unchanged", function()
    local r = R.ok(5):map_err(function(e) return "nope" end)
    T.eq(r:unwrap(), 5)
  end)

  T.it("returns same Ok object for Ok", function()
    local orig = R.ok(5)
    local mapped = orig:map_err(function(e) return "nope" end)
    T.eq(mapped, orig)
  end)
end)

-- ── and_then ────────────────────────────────────────────────────────────────

T.describe("result: and_then", function()
  T.it("chains Ok results", function()
    local r = R.ok(2):and_then(function(x) return R.ok(x + 10) end)
    T.eq(r:unwrap(), 12)
  end)

  T.it("short-circuits on Err", function()
    local called = false
    local r = R.err("e"):and_then(function(x)
      called = true
      return R.ok(x + 10)
    end)
    T.eq(r:is_err(), true)
    T.eq(called, false)
  end)

  T.it("chains multiple and_then calls", function()
    local r = R.ok(1)
      :and_then(function(x) return R.ok(x + 1) end)
      :and_then(function(x) return R.ok(x * 3) end)
    T.eq(r:unwrap(), 6)
  end)

  T.it("short-circuits mid-chain", function()
    local r = R.ok(1)
      :and_then(function() return R.err("stop") end)
      :and_then(function(x) return R.ok(x * 100) end)
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "stop")
  end)

  T.it("fn can return Err", function()
    local r = R.ok(5):and_then(function() return R.err("fail") end)
    T.eq(r:is_err(), true)
  end)
end)

-- ── or_else ─────────────────────────────────────────────────────────────────

T.describe("result: or_else", function()
  T.it("calls fn on Err", function()
    local r = R.err("e"):or_else(function(e) return R.ok("recovered") end)
    T.eq(r:unwrap(), "recovered")
  end)

  T.it("passes through Ok", function()
    local called = false
    local r = R.ok(1):or_else(function()
      called = true
      return R.ok(2)
    end)
    T.eq(r:unwrap(), 1)
    T.eq(called, false)
  end)

  T.it("fn receives error value", function()
    local received
    R.err("info"):or_else(function(e)
      received = e
      return R.ok(0)
    end)
    T.eq(received, "info")
  end)

  T.it("fn can return another Err", function()
    local r = R.err("a"):or_else(function() return R.err("b") end)
    T.eq(r:unwrap_err(), "b")
  end)

  T.it("chains or_else calls", function()
    local r = R.err("a")
      :or_else(function() return R.err("b") end)
      :or_else(function(e) return R.ok("recovered from " .. e) end)
    T.eq(r:unwrap(), "recovered from b")
  end)
end)

-- ── inspect / inspect_err ───────────────────────────────────────────────────

T.describe("result: inspect", function()
  T.it("calls fn on Ok value", function()
    local seen
    local r = R.ok(42):inspect(function(v) seen = v end)
    T.eq(seen, 42)
    T.eq(r:unwrap(), 42)
  end)

  T.it("does not call fn on Err", function()
    local called = false
    R.err("e"):inspect(function() called = true end)
    T.eq(called, false)
  end)

  T.it("returns same result for chaining", function()
    local r = R.ok(1)
    local r2 = r:inspect(function() end)
    T.eq(r2:unwrap(), 1)
  end)
end)

T.describe("result: inspect_err", function()
  T.it("calls fn on Err value", function()
    local seen
    R.err("bad"):inspect_err(function(e) seen = e end)
    T.eq(seen, "bad")
  end)

  T.it("does not call fn on Ok", function()
    local called = false
    R.ok(1):inspect_err(function() called = true end)
    T.eq(called, false)
  end)

  T.it("returns same result for chaining", function()
    local r = R.err("e"):inspect_err(function() end)
    T.eq(r:is_err(), true)
  end)
end)

-- ── from ────────────────────────────────────────────────────────────────────

T.describe("result: from", function()
  T.it("wraps (value, nil) as Ok", function()
    local r = R.from(42, nil)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), 42)
  end)

  T.it("wraps (nil, errmsg) as Err", function()
    local r = R.from(nil, "file not found")
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "file not found")
  end)

  T.it("wraps (value, errmsg) as Err (error takes priority)", function()
    local r = R.from("data", "but also error")
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "but also error")
  end)

  T.it("wraps (nil, nil) as Ok(nil)", function()
    local r = R.from(nil, nil)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), nil)
  end)

  T.it("wraps real function return", function()
    local function good() return 10, nil end
    local function bad() return nil, "err" end
    T.eq(R.from(good()):unwrap(), 10)
    T.eq(R.from(bad()):unwrap_err(), "err")
  end)
end)

-- ── try ─────────────────────────────────────────────────────────────────────

T.describe("result: try", function()
  T.it("wraps successful call as Ok", function()
    local r = R.try(function() return 99 end)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), 99)
  end)

  T.it("wraps error as Err", function()
    local r = R.try(function() error("boom") end)
    T.eq(r:is_err(), true)
    T.ok(tostring(r:unwrap_err()):find("boom"), "error contains 'boom'")
  end)

  T.it("wraps nil return as Ok(nil)", function()
    local r = R.try(function() return nil end)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), nil)
  end)

  T.it("wraps false return as Ok(false)", function()
    local r = R.try(function() return false end)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), false)
  end)
end)

-- ── to_pair ─────────────────────────────────────────────────────────────────

T.describe("result: to_pair", function()
  T.it("Ok returns (val, nil)", function()
    local val, err = R.ok(42):to_pair()
    T.eq(val, 42)
    T.eq(err, nil)
  end)

  T.it("Err returns (nil, errmsg)", function()
    local val, err = R.err("oops"):to_pair()
    T.eq(val, nil)
    T.eq(err, "oops")
  end)

  T.it("Ok(nil) returns (nil, nil)", function()
    local val, err = R.ok(nil):to_pair()
    T.eq(val, nil)
    T.eq(err, nil)
  end)

  T.it("round-trips with from", function()
    local r = R.ok(7)
    local r2 = R.from(r:to_pair())
    T.eq(r2:unwrap(), 7)
  end)
end)

-- ── tostring ────────────────────────────────────────────────────────────────

T.describe("result: tostring", function()
  T.it("Ok tostring", function()
    T.eq(tostring(R.ok(42)), "Ok(42)")
  end)

  T.it("Err tostring", function()
    T.eq(tostring(R.err("bad")), "Err(bad)")
  end)

  T.it("Ok(nil) tostring", function()
    T.eq(tostring(R.ok(nil)), "Ok(nil)")
  end)

  T.it("Ok(string) tostring", function()
    T.eq(tostring(R.ok("hi")), "Ok(hi)")
  end)

  T.it("Err(number) tostring", function()
    T.eq(tostring(R.err(404)), "Err(404)")
  end)
end)

-- ── all ─────────────────────────────────────────────────────────────────────

T.describe("result: all", function()
  T.it("all Ok returns Ok with values", function()
    local r = R.all({ R.ok(1), R.ok(2), R.ok(3) })
    T.eq(r:is_ok(), true)
    local vals = r:unwrap()
    T.eq(vals[1], 1)
    T.eq(vals[2], 2)
    T.eq(vals[3], 3)
  end)

  T.it("returns first Err", function()
    local r = R.all({ R.ok(1), R.err("second"), R.err("third") })
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "second")
  end)

  T.it("empty list returns Ok({})", function()
    local r = R.all({})
    T.eq(r:is_ok(), true)
    T.eq(#r:unwrap(), 0)
  end)

  T.it("single Ok", function()
    local r = R.all({ R.ok("x") })
    T.eq(r:unwrap()[1], "x")
  end)

  T.it("single Err", function()
    local r = R.all({ R.err("e") })
    T.eq(r:unwrap_err(), "e")
  end)
end)

-- ── any ─────────────────────────────────────────────────────────────────────

T.describe("result: any", function()
  T.it("returns first Ok", function()
    local r = R.any({ R.err("a"), R.ok(2), R.ok(3) })
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), 2)
  end)

  T.it("returns last Err if all Err", function()
    local r = R.any({ R.err("a"), R.err("b"), R.err("c") })
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "c")
  end)

  T.it("single Ok", function()
    T.eq(R.any({ R.ok(1) }):unwrap(), 1)
  end)

  T.it("single Err", function()
    T.eq(R.any({ R.err("e") }):unwrap_err(), "e")
  end)

  T.it("first element is Ok", function()
    local r = R.any({ R.ok(1), R.err("e") })
    T.eq(r:unwrap(), 1)
  end)
end)

-- ── Edge cases ──────────────────────────────────────────────────────────────

T.describe("result: edge cases", function()
  T.it("nested Result as value", function()
    local inner = R.ok(99)
    local outer = R.ok(inner)
    T.eq(outer:is_ok(), true)
    T.eq(outer:unwrap():unwrap(), 99)
  end)

  T.it("map preserves Err identity", function()
    local r = R.err("e")
    local r2 = r:map(function(x) return x end)
    T.eq(r, r2)
  end)

  T.it("and_then with identity", function()
    local r = R.ok(5):and_then(function(x) return R.ok(x) end)
    T.eq(r:unwrap(), 5)
  end)

  T.it("complex chain", function()
    local r = R.ok(10)
      :map(function(x) return x + 5 end)
      :and_then(function(x)
        if x > 10 then return R.ok(x) end
        return R.err("too small")
      end)
      :map(function(x) return x * 2 end)
    T.eq(r:unwrap(), 30)
  end)

  T.it("complex chain with error", function()
    local r = R.ok(3)
      :map(function(x) return x + 5 end)
      :and_then(function(x)
        if x > 10 then return R.ok(x) end
        return R.err("too small")
      end)
      :map(function(x) return x * 2 end)
    T.eq(r:is_err(), true)
    T.eq(r:unwrap_err(), "too small")
  end)

  T.it("or_else recovery after and_then failure", function()
    local r = R.ok(1)
      :and_then(function() return R.err("failed") end)
      :or_else(function() return R.ok(0) end)
    T.eq(r:unwrap(), 0)
  end)

  T.it("all preserves order", function()
    local r = R.all({ R.ok("a"), R.ok("b"), R.ok("c") })
    local vals = r:unwrap()
    T.eq(vals[1], "a")
    T.eq(vals[2], "b")
    T.eq(vals[3], "c")
  end)

  T.it("from with false value and nil error is Ok(false)", function()
    local r = R.from(false, nil)
    T.eq(r:is_ok(), true)
    T.eq(r:unwrap(), false)
  end)
end)
