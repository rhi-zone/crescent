-- lib/fp/adt/adt_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local ADT = require("lib.fp.adt")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- A dummy typeclass table used to test typeclass delegation.
local Dummy = {}

-- ── Single-value constructors: Maybe-style ────────────────────────────────────

T.describe("ADT.define — Maybe-style (Nothing/Just)", function()
	local Maybe = ADT.define({ "Nothing", 0 }, { "Just", 1 })

	T.it("Nothing is a singleton value (0-arity)", function()
		-- 0-arity constructor returns a singleton directly, not a function
		T.ok(type(Maybe.nothing) == "table")
		T.eq(Maybe.nothing.tag, "nothing")
		T.eq(Maybe.nothing.n, 0)
	end)

	T.it("Just constructor produces a value with correct tag and inner value", function()
		local v = Maybe.just(42)
		T.eq(v.tag, "just")
		T.eq(v.n, 1)
		T.eq(v[1], 42)
	end)

	T.it("Just with a string", function()
		local v = Maybe.just("hello")
		T.eq(v[1], "hello")
	end)

	T.it("ADT.is identifies values from this ADT", function()
		T.ok(Maybe.is(Maybe.nothing))
		T.ok(Maybe.is(Maybe.just(99)))
		T.ok(not Maybe.is({}))
		T.ok(not Maybe.is(42))
		T.ok(not Maybe.is(nil))
	end)

	T.it("ADT._constructors contains ordered lowercased names", function()
		T.eq(Maybe._constructors[1], "nothing")
		T.eq(Maybe._constructors[2], "just")
		T.eq(#Maybe._constructors, 2)
	end)

	T.it("match dispatches to nothing handler", function()
		local result = Maybe.match(Maybe.nothing, {
			nothing = function() return "got nothing" end,
			just    = function(v) return "got " .. tostring(v) end,
		})
		T.eq(result, "got nothing")
	end)

	T.it("match dispatches to just handler with inner value unpacked", function()
		local result = Maybe.match(Maybe.just(7), {
			nothing = function() return 0 end,
			just    = function(v) return v * 2 end,
		})
		T.eq(result, 14)
	end)

	T.it("match errors on missing handler without catch-all", function()
		T.throws(function()
			Maybe.match(Maybe.just(1), {
				nothing = function() return "x" end,
				-- no `just` handler, no `_`
			})
		end)
	end)

	T.it("match _ catch-all is used when specific handler is absent", function()
		local result = Maybe.match(Maybe.just(5), {
			nothing = function() return "nothing" end,
			_       = function(...) return "catch-all" end,
		})
		T.eq(result, "catch-all")
	end)

	T.it("match _ catch-all receives no args for 0-arity", function()
		local called_with_n
		Maybe.match(Maybe.nothing, {
			_ = function(...) called_with_n = select("#", ...) end,
		})
		T.eq(called_with_n, 0)
	end)

	T.it("typeclass delegation: value[Key] → ADT[Key]", function()
		local instance = { map = function() return "mapped" end }
		Maybe[Dummy] = instance

		local v = Maybe.just(10)
		T.eq(v[Dummy], instance)
		T.eq(Maybe.nothing[Dummy], instance)
	end)

	T.it("ADT.is returns false for values from a different ADT", function()
		local Other = ADT.define({ "Foo", 1 })
		T.ok(not Maybe.is(Other.foo("x")))
	end)
end)

-- ── Multi-value constructors: Pair ────────────────────────────────────────────

T.describe("ADT.define — multi-value constructors (Pair)", function()
	local Pair = ADT.define({ "Pair", 2 })

	T.it("Pair constructor stores both inner values", function()
		local p = Pair.pair("a", "b")
		T.eq(p.tag, "pair")
		T.eq(p.n, 2)
		T.eq(p[1], "a")
		T.eq(p[2], "b")
	end)

	T.it("match receives both inner values unpacked", function()
		local fst, snd
		Pair.match(Pair.pair(10, 20), {
			pair = function(a, b)
				fst = a
				snd = b
			end,
		})
		T.eq(fst, 10)
		T.eq(snd, 20)
	end)

	T.it("ADT.is works for Pair values", function()
		T.ok(Pair.is(Pair.pair(1, 2)))
		T.ok(not Pair.is({ tag = "pair" }))   -- plain table, no _adt
	end)

	T.it("_constructors has correct single entry", function()
		T.eq(#Pair._constructors, 1)
		T.eq(Pair._constructors[1], "pair")
	end)
end)

-- ── 3-constructor ADT ─────────────────────────────────────────────────────────

T.describe("ADT.define — three constructors", function()
	local Shape = ADT.define({ "Circle", 1 }, { "Rect", 2 }, { "Point", 0 })

	T.it("_constructors lists all three in order", function()
		T.eq(Shape._constructors[1], "circle")
		T.eq(Shape._constructors[2], "rect")
		T.eq(Shape._constructors[3], "point")
		T.eq(#Shape._constructors, 3)
	end)

	T.it("each constructor produces values with correct tags", function()
		T.eq(Shape.circle(5).tag, "circle")
		T.eq(Shape.rect(3, 4).tag, "rect")
		T.eq(Shape.point.tag, "point")
	end)

	T.it("match works for all three branches", function()
		local function area(s)
			return Shape.match(s, {
				circle = function(r) return r * r end,   -- simplified π=1
				rect   = function(w, h) return w * h end,
				point  = function() return 0 end,
			})
		end
		T.eq(area(Shape.circle(3)), 9)
		T.eq(area(Shape.rect(4, 5)), 20)
		T.eq(area(Shape.point), 0)
	end)

	T.it("ADT.is cross-check: point from Shape is not in Pair ADT", function()
		local Pair = ADT.define({ "Pair", 2 })
		T.ok(Shape.is(Shape.point))
		T.ok(not Pair.is(Shape.point))
	end)
end)

-- ── Typeclass instance delegation (dedicated test) ────────────────────────────

T.describe("ADT typeclass delegation", function()
	-- Two different typeclass table keys
	local TC1 = {}
	local TC2 = {}

	local Box = ADT.define({ "Empty", 0 }, { "Full", 1 })

	local impl1 = { foo = "bar" }
	local impl2 = { baz = 99 }
	Box[TC1] = impl1
	Box[TC2] = impl2

	T.it("Full value delegates TC1 to the ADT table", function()
		local v = Box.full("contents")
		T.eq(v[TC1], impl1)
	end)

	T.it("Full value delegates TC2 to the ADT table", function()
		local v = Box.full("x")
		T.eq(v[TC2], impl2)
	end)

	T.it("Empty singleton delegates TC1 to the ADT table", function()
		T.eq(Box.empty[TC1], impl1)
	end)

	T.it("Two ADTs with same key name don't bleed instances", function()
		local Other = ADT.define({ "Wrap", 1 })
		Other[TC1] = { foo = "different" }
		-- Box values should still see the original impl1
		T.eq(Box.full("y")[TC1], impl1)
		T.eq(Other.wrap("z")[TC1].foo, "different")
	end)
end)
