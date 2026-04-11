-- lib/either/either_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.either")

local Right = M.Right
local Left  = M.Left
local Some  = M.Some
local None  = M.None

-- ── Either: constructors and predicates ──────────────────────────────────────

T.describe("Either constructors and predicates", function()
	T.it("Right:is_right() is true", function()
		T.ok(Right(42):is_right())
	end)
	T.it("Right:is_left() is false", function()
		T.ok(not Right(42):is_left())
	end)
	T.it("Left:is_left() is true", function()
		T.ok(Left("err"):is_left())
	end)
	T.it("Left:is_right() is false", function()
		T.ok(not Left("err"):is_right())
	end)
end)

-- ── Either: value extraction ─────────────────────────────────────────────────

T.describe("Either value extraction", function()
	T.it("Right:right() returns the value", function()
		T.eq(Right(42):right(), 42)
	end)
	T.it("Right:left() returns nil", function()
		T.eq(Right(42):left(), nil)
	end)
	T.it("Left:left() returns the value", function()
		T.eq(Left("oops"):left(), "oops")
	end)
	T.it("Left:right() returns nil", function()
		T.eq(Left("oops"):right(), nil)
	end)
	T.it("Right:value() returns the right value", function()
		T.eq(Right(99):value(), 99)
	end)
	T.it("Left:value() returns the left value", function()
		T.eq(Left("e"):value(), "e")
	end)
end)

-- ── Either: map ──────────────────────────────────────────────────────────────

T.describe("Either map", function()
	T.it("Right:map applies fn to value", function()
		local r = Right(5):map(function(x) return x * 2 end)
		T.ok(r:is_right())
		T.eq(r:right(), 10)
	end)
	T.it("Left:map is identity", function()
		local l = Left("err"):map(function(x) return x * 2 end)
		T.ok(l:is_left())
		T.eq(l:left(), "err")
	end)
end)

-- ── Either: map_left ─────────────────────────────────────────────────────────

T.describe("Either map_left", function()
	T.it("Left:map_left applies fn to left value", function()
		local l = Left("err"):map_left(function(e) return "Error: " .. e end)
		T.ok(l:is_left())
		T.eq(l:left(), "Error: err")
	end)
	T.it("Right:map_left is identity", function()
		local r = Right(5):map_left(function(e) return e .. "!" end)
		T.ok(r:is_right())
		T.eq(r:right(), 5)
	end)
end)

-- ── Either: and_then ─────────────────────────────────────────────────────────

T.describe("Either and_then", function()
	T.it("Right:and_then chains to Right", function()
		local r = Right(5):and_then(function(x) return Right(x + 1) end)
		T.ok(r:is_right())
		T.eq(r:right(), 6)
	end)
	T.it("Right:and_then chains to Left", function()
		local r = Right(5):and_then(function(_x) return Left("nope") end)
		T.ok(r:is_left())
		T.eq(r:left(), "nope")
	end)
	T.it("Left:and_then short-circuits", function()
		local r = Left("err"):and_then(function(x) return Right(x) end)
		T.ok(r:is_left())
		T.eq(r:left(), "err")
	end)
end)

-- ── Either: or_else ───────────────────────────────────────────────────────────

T.describe("Either or_else", function()
	T.it("Left:or_else applies recovery fn", function()
		local r = Left("err"):or_else(function(_e) return Right(0) end)
		T.ok(r:is_right())
		T.eq(r:right(), 0)
	end)
	T.it("Right:or_else is identity", function()
		local r = Right(5):or_else(function(_e) return Right(0) end)
		T.ok(r:is_right())
		T.eq(r:right(), 5)
	end)
end)

-- ── Either: fold ─────────────────────────────────────────────────────────────

T.describe("Either fold", function()
	T.it("Right:fold applies right branch", function()
		local v = Right(5):fold(
			function(l) return "left:" .. l end,
			function(r) return r * 2 end
		)
		T.eq(v, 10)
	end)
	T.it("Left:fold applies left branch", function()
		local v = Left("x"):fold(
			function(l) return "left:" .. l end,
			function(r) return r * 2 end
		)
		T.eq(v, "left:x")
	end)
end)

-- ── Either: unwrap ────────────────────────────────────────────────────────────

T.describe("Either unwrap", function()
	T.it("Right:unwrap returns value", function()
		T.eq(Right(42):unwrap(), 42)
	end)
	T.it("Left:unwrap raises error", function()
		local ok, err = pcall(function() Left("oops"):unwrap() end)
		T.ok(not ok)
		T.ok(err:find("oops") ~= nil)
	end)
	T.it("Right:unwrap_or returns value", function()
		T.eq(Right(42):unwrap_or(0), 42)
	end)
	T.it("Left:unwrap_or returns default", function()
		T.eq(Left("oops"):unwrap_or(0), 0)
	end)
	T.it("Right:unwrap_or_else returns value", function()
		T.eq(Right(42):unwrap_or_else(function(_l) return -1 end), 42)
	end)
	T.it("Left:unwrap_or_else applies fn", function()
		T.eq(Left("e"):unwrap_or_else(function(l) return #l end), 1)
	end)
end)

-- ── Either: to_pair / from_pair ───────────────────────────────────────────────

T.describe("Either to_pair / from_pair", function()
	T.it("Right:to_pair returns (value, nil)", function()
		local v, e = Right(42):to_pair()
		T.eq(v, 42)
		T.eq(e, nil)
	end)
	T.it("Left:to_pair returns (nil, err)", function()
		local v, e = Left("err"):to_pair()
		T.eq(v, nil)
		T.eq(e, "err")
	end)
	T.it("from_pair with value → Right", function()
		local r = M.from_pair(42, nil)
		T.ok(r:is_right())
		T.eq(r:right(), 42)
	end)
	T.it("from_pair with err → Left", function()
		local r = M.from_pair(nil, "e")
		T.ok(r:is_left())
		T.eq(r:left(), "e")
	end)
end)

-- ── Either: to_maybe ─────────────────────────────────────────────────────────

T.describe("Either to_maybe", function()
	T.it("Right:to_maybe → Some", function()
		local m = Right(42):to_maybe()
		T.ok(m:is_some())
		T.eq(m:value(), 42)
	end)
	T.it("Left:to_maybe → None", function()
		local m = Left("e"):to_maybe()
		T.ok(m:is_none())
	end)
end)

-- ── Maybe: constructors and predicates ───────────────────────────────────────

T.describe("Maybe constructors and predicates", function()
	T.it("Some:is_some() is true", function()
		T.ok(Some(42):is_some())
	end)
	T.it("Some:is_none() is false", function()
		T.ok(not Some(42):is_none())
	end)
	T.it("None:is_none() is true", function()
		T.ok(None:is_none())
	end)
	T.it("None:is_some() is false", function()
		T.ok(not None:is_some())
	end)
	T.it("None() returns the singleton", function()
		T.ok(None() == None)
	end)
end)

-- ── Maybe: value extraction ───────────────────────────────────────────────────

T.describe("Maybe value extraction", function()
	T.it("Some:value() returns the value", function()
		T.eq(Some(42):value(), 42)
	end)
	T.it("None:value() returns nil", function()
		T.eq(None:value(), nil)
	end)
end)

-- ── Maybe: map ───────────────────────────────────────────────────────────────

T.describe("Maybe map", function()
	T.it("Some:map applies fn", function()
		local m = Some(5):map(function(x) return x * 2 end)
		T.ok(m:is_some())
		T.eq(m:value(), 10)
	end)
	T.it("None:map is identity None", function()
		local m = None:map(function(x) return x * 2 end)
		T.ok(m:is_none())
	end)
end)

-- ── Maybe: and_then ───────────────────────────────────────────────────────────

T.describe("Maybe and_then", function()
	T.it("Some:and_then chains to Some", function()
		local m = Some(5):and_then(function(x) return Some(x + 1) end)
		T.ok(m:is_some())
		T.eq(m:value(), 6)
	end)
	T.it("Some:and_then chains to None", function()
		local m = Some(5):and_then(function(_x) return None end)
		T.ok(m:is_none())
	end)
	T.it("None:and_then short-circuits", function()
		local called = false
		local m = None:and_then(function(x)
			called = true
			return Some(x)
		end)
		T.ok(m:is_none())
		T.ok(not called)
	end)
end)

-- ── Maybe: or_else ────────────────────────────────────────────────────────────

T.describe("Maybe or_else", function()
	T.it("Some:or_else is identity", function()
		local m = Some(5):or_else(function() return Some(0) end)
		T.ok(m:is_some())
		T.eq(m:value(), 5)
	end)
	T.it("None:or_else returns fallback", function()
		local m = None:or_else(function() return Some(0) end)
		T.ok(m:is_some())
		T.eq(m:value(), 0)
	end)
end)

-- ── Maybe: filter ─────────────────────────────────────────────────────────────

T.describe("Maybe filter", function()
	T.it("Some:filter keeps value when predicate passes", function()
		local m = Some(5):filter(function(x) return x > 3 end)
		T.ok(m:is_some())
		T.eq(m:value(), 5)
	end)
	T.it("Some:filter returns None when predicate fails", function()
		local m = Some(2):filter(function(x) return x > 3 end)
		T.ok(m:is_none())
	end)
	T.it("None:filter is identity None", function()
		local m = None:filter(function(_x) return true end)
		T.ok(m:is_none())
	end)
end)

-- ── Maybe: unwrap ─────────────────────────────────────────────────────────────

T.describe("Maybe unwrap", function()
	T.it("Some:unwrap returns value", function()
		T.eq(Some(5):unwrap(), 5)
	end)
	T.it("None:unwrap raises error", function()
		local ok, err = pcall(function() None:unwrap() end)
		T.ok(not ok)
		T.ok(err:find("None") ~= nil)
	end)
	T.it("Some:unwrap_or returns value", function()
		T.eq(Some(5):unwrap_or(0), 5)
	end)
	T.it("None:unwrap_or returns default", function()
		T.eq(None:unwrap_or(0), 0)
	end)
	T.it("Some:unwrap_or_else returns value", function()
		T.eq(Some(5):unwrap_or_else(function() return -1 end), 5)
	end)
	T.it("None:unwrap_or_else applies fn", function()
		T.eq(None:unwrap_or_else(function() return 99 end), 99)
	end)
end)

-- ── Maybe: to_pair ────────────────────────────────────────────────────────────

T.describe("Maybe to_pair", function()
	T.it("Some:to_pair returns (value, nil)", function()
		local v, e = Some(42):to_pair()
		T.eq(v, 42)
		T.eq(e, nil)
	end)
	T.it("None:to_pair returns (nil, nil)", function()
		local v, e = None:to_pair()
		T.eq(v, nil)
		T.eq(e, nil)
	end)
end)

-- ── Maybe: maybe_from ─────────────────────────────────────────────────────────

T.describe("maybe_from", function()
	T.it("maybe_from(nil) → None", function()
		T.ok(M.maybe_from(nil):is_none())
	end)
	T.it("maybe_from(value) → Some", function()
		local m = M.maybe_from(42)
		T.ok(m:is_some())
		T.eq(m:value(), 42)
	end)
	T.it("maybe_from(false) → Some(false) (not None)", function()
		local m = M.maybe_from(false)
		T.ok(m:is_some())
		T.eq(m:value(), false)
	end)
end)

-- ── Maybe: to_right / to_either ───────────────────────────────────────────────

T.describe("Maybe to_right / to_either", function()
	T.it("Some:to_right → Right", function()
		local r = Some(42):to_right(function() return "missing" end)
		T.ok(r:is_right())
		T.eq(r:right(), 42)
	end)
	T.it("None:to_right → Left with err_fn result", function()
		local r = None:to_right(function() return "missing" end)
		T.ok(r:is_left())
		T.eq(r:left(), "missing")
	end)
	T.it("Some:to_either is alias for to_right", function()
		local r = Some(7):to_either(function() return "x" end)
		T.ok(r:is_right())
		T.eq(r:right(), 7)
	end)
	T.it("None:to_either is alias for to_right", function()
		local r = None:to_either(function() return "x" end)
		T.ok(r:is_left())
		T.eq(r:left(), "x")
	end)
end)
