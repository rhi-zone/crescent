if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local Option = require("lib.option")

T.describe("Option", function()

	T.describe("construction", function()
		T.it("some() creates a Some value", function()
			local s = Option.some(42)
			T.ok(s:is_some())
			T.eq(s:unwrap(), 42)
		end)

		T.it("some() rejects nil", function()
			T.throws(function() Option.some(nil) end)
		end)

		T.it("none is a None singleton", function()
			T.ok(Option.none:is_none())
		end)

		T.it("of() returns Some for non-nil", function()
			local s = Option.of("hello")
			T.ok(s:is_some())
			T.eq(s:unwrap(), "hello")
		end)

		T.it("of() returns None for nil", function()
			T.ok(Option.of(nil):is_none())
		end)

		T.it("from_result() returns Some when value present", function()
			local s = Option.from_result(99, nil)
			T.ok(s:is_some())
			T.eq(s:unwrap(), 99)
		end)

		T.it("from_result() returns None when value is nil", function()
			T.ok(Option.from_result(nil, "err"):is_none())
		end)
	end)

	T.describe("predicates", function()
		T.it("is_some/is_none on Some", function()
			local s = Option.some(1)
			T.ok(s:is_some())
			T.ok(not s:is_none())
		end)

		T.it("is_some/is_none on None", function()
			T.ok(not Option.none:is_some())
			T.ok(Option.none:is_none())
		end)
	end)

	T.describe("unwrap", function()
		T.it("unwrap on Some returns value", function()
			T.eq(Option.some(7):unwrap(), 7)
		end)

		T.it("unwrap on None errors", function()
			T.throws(function() Option.none:unwrap() end)
		end)

		T.it("value() is an alias for unwrap()", function()
			T.eq(Option.some(3):value(), 3)
		end)

		T.it("unwrap_or returns value on Some", function()
			T.eq(Option.some(5):unwrap_or(0), 5)
		end)

		T.it("unwrap_or returns default on None", function()
			T.eq(Option.none:unwrap_or(0), 0)
		end)

		T.it("unwrap_or_else returns value on Some without calling fn", function()
			local called = false
			local v = Option.some(9):unwrap_or_else(function()
				called = true
				return 0
			end)
			T.eq(v, 9)
			T.ok(not called)
		end)

		T.it("unwrap_or_else calls fn on None", function()
			local v = Option.none:unwrap_or_else(function() return 42 end)
			T.eq(v, 42)
		end)
	end)

	T.describe("map", function()
		T.it("map transforms Some", function()
			local s = Option.some(4):map(function(v) return v * 2 end)
			T.ok(s:is_some())
			T.eq(s:unwrap(), 8)
		end)

		T.it("map passes None through", function()
			T.ok(Option.none:map(function(v) return v * 2 end):is_none())
		end)
	end)

	T.describe("and_then", function()
		T.it("and_then chains Some", function()
			local s = Option.some(5):and_then(function(v)
				return Option.some(v + 1)
			end)
			T.eq(s:unwrap(), 6)
		end)

		T.it("and_then can return None", function()
			local s = Option.some(-1):and_then(function(v)
				if v > 0 then return Option.some(v) end
				return Option.none
			end)
			T.ok(s:is_none())
		end)

		T.it("and_then on None is None", function()
			T.ok(Option.none:and_then(function(v) return Option.some(v) end):is_none())
		end)
	end)

	T.describe("filter", function()
		T.it("filter keeps Some when pred true", function()
			local s = Option.some(10):filter(function(v) return v > 0 end)
			T.ok(s:is_some())
			T.eq(s:unwrap(), 10)
		end)

		T.it("filter → None when pred false", function()
			T.ok(Option.some(-1):filter(function(v) return v > 0 end):is_none())
		end)

		T.it("filter on None stays None", function()
			T.ok(Option.none:filter(function() return true end):is_none())
		end)
	end)

	T.describe("or_ / or_else", function()
		T.it("or_ on Some returns self", function()
			local s = Option.some(1):or_(Option.some(2))
			T.eq(s:unwrap(), 1)
		end)

		T.it("or_ on None returns alternative", function()
			local s = Option.none:or_(Option.some(2))
			T.eq(s:unwrap(), 2)
		end)

		T.it("or_else on Some does not call fn", function()
			local called = false
			local s = Option.some(1):or_else(function()
				called = true
				return Option.some(0)
			end)
			T.eq(s:unwrap(), 1)
			T.ok(not called)
		end)

		T.it("or_else on None calls fn", function()
			local s = Option.none:or_else(function() return Option.some(99) end)
			T.eq(s:unwrap(), 99)
		end)
	end)

	T.describe("to_table", function()
		T.it("Some → {value}", function()
			local t = Option.some(7):to_table()
			T.eq(#t, 1)
			T.eq(t[1], 7)
		end)

		T.it("None → {}", function()
			local t = Option.none:to_table()
			T.eq(#t, 0)
		end)
	end)

	T.describe("to_result", function()
		T.it("Some → (value, nil)", function()
			local v, err = Option.some(3):to_result("missing")
			T.eq(v, 3)
			T.eq(err, nil)
		end)

		T.it("None → (nil, errmsg)", function()
			local v, err = Option.none:to_result("missing")
			T.eq(v, nil)
			T.eq(err, "missing")
		end)
	end)

	T.describe("to_bool", function()
		T.it("Some is truthy", function()
			T.ok(Option.some(1):to_bool())
		end)

		T.it("None is falsy", function()
			T.ok(not Option.none:to_bool())
		end)
	end)

	T.describe("all", function()
		T.it("all Some → Some with combined values", function()
			local r = Option.all({ Option.some(1), Option.some(2), Option.some(3) })
			T.ok(r:is_some())
			local t = r:unwrap()
			T.eq(t[1], 1)
			T.eq(t[2], 2)
			T.eq(t[3], 3)
		end)

		T.it("any None → None", function()
			local r = Option.all({ Option.some(1), Option.none, Option.some(3) })
			T.ok(r:is_none())
		end)

		T.it("empty list → Some({})", function()
			local r = Option.all({})
			T.ok(r:is_some())
			T.eq(#r:unwrap(), 0)
		end)
	end)

	T.describe("any", function()
		T.it("first Some wins", function()
			local r = Option.any({ Option.none, Option.some(2), Option.some(3) })
			T.ok(r:is_some())
			T.eq(r:unwrap(), 2)
		end)

		T.it("all None → None", function()
			T.ok(Option.any({ Option.none, Option.none }):is_none())
		end)

		T.it("empty list → None", function()
			T.ok(Option.any({}):is_none())
		end)
	end)

	T.describe("from_fn", function()
		T.it("wraps nil-returning function", function()
			local head = Option.from_fn(function(t) return t[1] end)
			T.ok(head({ 1, 2, 3 }):is_some())
			T.eq(head({ 1, 2, 3 }):unwrap(), 1)
			T.ok(head({}):is_none())
		end)
	end)

	T.describe("metamethods", function()
		T.it("__tostring Some", function()
			T.eq(tostring(Option.some(42)), "Some(42)")
		end)

		T.it("__tostring None", function()
			T.eq(tostring(Option.none), "None")
		end)

		T.it("__eq: some(5) == some(5)", function()
			T.ok(Option.some(5) == Option.some(5))
		end)

		T.it("__eq: some(5) ~= some(6)", function()
			T.ok(not (Option.some(5) == Option.some(6)))
		end)

		T.it("__eq: none == none", function()
			T.ok(Option.none == Option.none)
		end)

		T.it("__eq: some ~= none", function()
			T.ok(not (Option.some(1) == Option.none))
		end)

		-- LuaJIT uses bit.bor() for integers; | syntax is Lua 5.3+.
		-- __bor is defined on the metatables for forward-compat.
		-- Test or_() directly (same semantics).
		T.it("or_: none | some → some (via or_)", function()
			local r = Option.none:or_(Option.some(7))
			T.eq(r:unwrap(), 7)
		end)

		T.it("or_: some | other → self (via or_)", function()
			local r = Option.some(3):or_(Option.some(7))
			T.eq(r:unwrap(), 3)
		end)
	end)

end)
