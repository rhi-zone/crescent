-- lib/test/prop_test.lua
-- Tests for lib/test/prop.lua and lib/test/gen.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")   -- test-assertion helpers
local gen  = require("lib.test.gen")
local prop = require("lib.test.prop")
-- Note: 'assert' remains the Lua built-in here, available inside property lambdas.

-- ── PRNG smoke tests ──────────────────────────────────────────────────────────

T.describe("gen.make_rng", function()
	T.it("produces different values", function()
		local rng = gen.make_rng(42)
		local a, b = rng:next(), rng:next()
		T.neq(a, b)
	end)

	T.it("same seed produces same sequence", function()
		local r1 = gen.make_rng(12345)
		local r2 = gen.make_rng(12345)
		for _ = 1, 20 do T.eq(r1:next(), r2:next()) end
	end)

	T.it("different seeds produce different sequences", function()
		local r1 = gen.make_rng(1)
		local r2 = gen.make_rng(2)
		local same = true
		for _ = 1, 10 do
			if r1:next() ~= r2:next() then same = false; break end
		end
		T.fail(same, "seeds 1 and 2 should diverge")
	end)

	T.it("int stays in range", function()
		local rng = gen.make_rng(99)
		for _ = 1, 100 do
			local v = rng:int(3, 7)
			T.ok(v >= 3 and v <= 7, "out of range: " .. v)
		end
	end)

	T.it("float in [0,1)", function()
		local rng = gen.make_rng(7)
		for _ = 1, 100 do
			local v = rng:float()
			T.ok(v >= 0 and v < 1, "out of range: " .. v)
		end
	end)
end)

-- ── Generator: int ────────────────────────────────────────────────────────────

T.describe("gen.int", function()
	local rng = gen.make_rng(1)

	T.it("generates within bounds", function()
		local g = gen.int(-10, 10)
		for _ = 1, 50 do
			local v = g.generate(rng, 20)
			T.ok(v >= -10 and v <= 10)
		end
	end)

	T.it("shrinks toward 0 from positive", function()
		local g = gen.int(-100, 100)
		local s = g.shrink(50)
		T.ok(#s > 0, "no candidates")
		for _, c in ipairs(s) do
			T.ok(math.abs(c) < math.abs(50), "shrunk away from 0: " .. c)
		end
	end)

	T.it("shrinks toward 0 from negative", function()
		local g = gen.int(-100, 100)
		local s = g.shrink(-50)
		T.ok(#s > 0)
		for _, c in ipairs(s) do
			T.ok(math.abs(c) < math.abs(-50))
		end
	end)

	T.it("shrink of target is empty", function()
		local g = gen.int(0, 100)
		T.eq(#g.shrink(0), 0)
	end)

	T.it("shrink of lo (positive range) targets lo", function()
		local g = gen.int(5, 20)
		T.eq(#g.shrink(5), 0)   -- target = 5 (closest to 0 in [5,20])
		local s = g.shrink(15)
		T.ok(#s > 0)
		for _, c in ipairs(s) do T.ok(c < 15 and c >= 5) end
	end)
end)

-- ── Generator: bool ───────────────────────────────────────────────────────────

T.describe("gen.bool", function()
	T.it("produces both true and false", function()
		local rng  = gen.make_rng(3)
		local seen = {}
		for _ = 1, 40 do seen[tostring(gen.bool.generate(rng, 10))] = true end
		T.ok(seen["true"] and seen["false"])
	end)

	T.it("true shrinks to {false}", function()
		local s = gen.bool.shrink(true)
		T.eq(#s, 1)
		T.eq(s[1], false)
	end)

	T.it("false shrinks to nothing", function()
		T.eq(#gen.bool.shrink(false), 0)
	end)
end)

-- ── Generator: string ─────────────────────────────────────────────────────────

T.describe("gen.string", function()
	local rng = gen.make_rng(5)

	T.it("generates strings", function()
		local g = gen.string()
		for _ = 1, 20 do
			T.ok(type(g.generate(rng, 10)) == "string")
		end
	end)

	T.it("respects max length", function()
		local g = gen.string({ max = 5 })
		for _ = 1, 30 do
			T.ok(#g.generate(rng, 100) <= 5)
		end
	end)

	T.it("shrinks to shorter strings", function()
		local g = gen.string()
		local s = g.shrink("hello")
		T.ok(#s > 0)
		for _, c in ipairs(s) do T.ok(#c < #"hello") end
	end)

	T.it("empty string has no shrinks", function()
		T.eq(#gen.string().shrink(""), 0)
	end)
end)

-- ── Generator: list ───────────────────────────────────────────────────────────

T.describe("gen.list", function()
	local rng = gen.make_rng(11)

	T.it("generates lists with elements in range", function()
		local g = gen.list(gen.int(1, 9))
		for _ = 1, 20 do
			local v = g.generate(rng, 5)
			T.ok(type(v) == "table")
			for _, x in ipairs(v) do T.ok(x >= 1 and x <= 9) end
		end
	end)

	T.it("respects max length", function()
		local g = gen.list(gen.int(0, 1), { max = 3 })
		for _ = 1, 20 do T.ok(#g.generate(rng, 100) <= 3) end
	end)

	T.it("shrinks by removing elements", function()
		local g = gen.list(gen.int(0, 10))
		local s = g.shrink({1, 2, 3})
		local found_2elem = false
		for _, c in ipairs(s) do
			if #c == 2 then found_2elem = true; break end
		end
		T.ok(found_2elem)
	end)

	T.it("empty list has no shrinks", function()
		T.eq(#gen.list(gen.int(0, 10)).shrink({}), 0)
	end)
end)

-- ── Generator: one_of ─────────────────────────────────────────────────────────

T.describe("gen.one_of", function()
	T.it("picks from both generators", function()
		local rng  = gen.make_rng(7)
		local g    = gen.one_of({ gen.constant(1), gen.constant(2) })
		local seen = {}
		for _ = 1, 40 do seen[g.generate(rng, 10)] = true end
		T.ok(seen[1] and seen[2])
	end)
end)

-- ── Generator: tuple ─────────────────────────────────────────────────────────

T.describe("gen.tuple", function()
	T.it("generates an array of values", function()
		local rng = gen.make_rng(3)
		local g   = gen.tuple({ gen.int(0, 5), gen.bool, gen.string() })
		local v   = g.generate(rng, 10)
		T.eq(#v, 3)
		T.ok(type(v[1]) == "number")
		T.ok(type(v[2]) == "boolean")
		T.ok(type(v[3]) == "string")
	end)

	T.it("shrinks each component independently", function()
		local g = gen.tuple({ gen.int(0, 100), gen.int(0, 100) })
		local s = g.shrink({50, 50})
		T.ok(#s > 0)
		for _, c in ipairs(s) do
			T.ok(c[1] < 50 or c[2] < 50)
		end
	end)
end)

-- ── Generator: nil_or ────────────────────────────────────────────────────────

T.describe("gen.nil_or", function()
	T.it("sometimes generates nil", function()
		local rng      = gen.make_rng(99)
		local g        = gen.nil_or(gen.int(1, 100))
		local seen_nil = false
		for _ = 1, 80 do
			if g.generate(rng, 10) == nil then seen_nil = true; break end
		end
		T.ok(seen_nil)
	end)
end)

-- ── Generator: filter ────────────────────────────────────────────────────────

T.describe("gen.filter", function()
	T.it("only generates values satisfying pred", function()
		local rng = gen.make_rng(5)
		local g   = gen.filter(gen.int(0, 20), function(n) return n % 2 == 0 end)
		for _ = 1, 30 do T.eq(g.generate(rng, 20) % 2, 0) end
	end)
end)

-- ── prop.check ────────────────────────────────────────────────────────────────

T.describe("prop.check", function()
	T.it("passes a true property", function()
		local ok, info = prop.check("x*2 is even", gen.int(-1000, 1000), function(n)
			if n * 2 % 2 ~= 0 then error("not even") end
		end, { trials = 50, seed = 42 })
		T.ok(ok)
		T.ok(info == nil)
	end)

	T.it("detects a false property", function()
		local ok, info = prop.check("all ints >= 0 (false)", gen.int(-100, 100), function(n)
			if n < 0 then error("negative: " .. n) end
		end, { trials = 200, seed = 1 })
		T.fail(ok)
		T.ok(info ~= nil)
		T.ok(info.trial >= 1)
		T.eq(info.seed, 1)
	end)

	T.it("shrinks to minimal counterexample", function()
		-- Property: all ints < 10.  Minimal failing value should shrink to 10.
		local ok, info = prop.check("n < 10", gen.int(0, 100), function(n)
			if n >= 10 then error("too big: " .. n) end
		end, { trials = 200, seed = 1 })
		T.fail(ok)
		T.eq(info.shrunk[1], 10)
	end)

	T.it("seed is reproducible", function()
		local function run(seed)
			return prop.check("fail on > 50", gen.int(0, 100), function(n)
				if n > 50 then error("big") end
			end, { trials = 200, seed = seed })
		end
		local ok1, i1 = run(999)
		local ok2, i2 = run(999)
		T.eq(ok1, ok2)
		if not ok1 then
			T.eq(i1.trial, i2.trial)
			T.eq(i1.original[1], i2.original[1])
		end
	end)

	T.it("works with a tuple generator for multiple args", function()
		local ok, _ = prop.check("add commutes",
			gen.tuple({ gen.int(0, 50), gen.int(0, 50) }),
			function(pair)
				local a, b = pair[1], pair[2]
				if a + b ~= b + a then error("not commutative") end
			end,
			{ trials = 50, seed = 7 }
		)
		T.ok(ok)
	end)

	T.it("shrinks a list to minimal failing length", function()
		-- Property: all lists have length < 3.  Minimal should be length 3.
		local ok, info = prop.check("list len < 3",
			gen.list(gen.int(0, 10)),
			function(xs)
				if #xs >= 3 then error("too long") end
			end,
			{ trials = 200, seed = 55 }
		)
		T.fail(ok)
		T.eq(#info.shrunk[1], 3)
	end)
end)

-- ── prop.it integration ───────────────────────────────────────────────────────

T.describe("prop.it", function()
	prop.it("string reverse is involution", gen.string({ max = 15 }), function(s)
		local function rev(str)
			local t = {}
			for i = #str, 1, -1 do t[#t+1] = str:sub(i, i) end
			return table.concat(t)
		end
		if rev(rev(s)) ~= s then error("not involution for: " .. s) end
	end, { trials = 50, seed = 42 })

	prop.it("list length is non-negative",
		gen.list(gen.int(-10, 10)),
		function(xs)
			if #xs < 0 then error("negative length") end
		end,
		{ trials = 50, seed = 1 }
	)

	prop.it("int is in range [-50,50]", gen.int(-50, 50), function(n)
		if n < -50 or n > 50 then error("out of range: " .. n) end
	end, { trials = 100, seed = 3 })
end)
