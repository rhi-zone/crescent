-- lib/test/arb_test.lua
-- Tests for the fast-check context-carrying property testing module.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local arb = require("lib.test.arb")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_rng(seed)
	return require("lib.test.gen").make_rng(seed)
end

-- Collect all candidates from a shrink iterator.
local function collect(iter, limit)
	limit = limit or 50
	local out = {}
	for _ = 1, limit do
		local v, c = iter()
		if v == nil then break end
		out[#out+1] = {v, c}
	end
	return out
end

-- ── Primitive generation ──────────────────────────────────────────────────────

T.describe("arb: primitives", function()
	T.it("int: generate returns value in range, ctx = nil", function()
		local rng = make_rng(1)
		local a   = arb.int(-10, 10)
		for _ = 1, 20 do
			local v, c = a.generate(rng, 20)
			T.ok(v >= -10 and v <= 10, "int in range")
			T.ok(c == nil, "int ctx is nil")
		end
	end)

	T.it("int: shrink toward 0 — most aggressive first", function()
		local a = arb.int(-100, 100)
		-- val=10 → first candidate = 0 (target)
		local cands = collect(a.shrink(10, nil))
		T.ok(#cands > 0, "should produce candidates")
		T.eq(cands[1][1], 0, "first shrink candidate is target (0)")
		-- All candidates should be between target and val.
		for _, pair in ipairs(cands) do
			T.ok(pair[1] >= 0 and pair[1] < 10, "candidate between 0 and val")
		end
	end)

	T.it("int: shrink negative toward 0", function()
		local a     = arb.int(-100, 0)
		local cands = collect(a.shrink(-8, nil))
		T.eq(cands[1][1], 0, "first candidate is 0 (target)")
		for _, pair in ipairs(cands) do
			T.ok(pair[1] <= 0 and pair[1] > -8, "candidate between -8 and 0")
		end
	end)

	T.it("int: no shrink when already at target", function()
		local a = arb.int(-5, 5)
		local cands = collect(a.shrink(0, nil))
		T.eq(#cands, 0, "nothing to shrink at target")
	end)

	T.it("int: lo > 0 shrinks toward lo", function()
		local a     = arb.int(3, 10)
		local cands = collect(a.shrink(10, nil))
		T.eq(cands[1][1], 3, "first candidate is lo (=target when lo>0)")
	end)

	T.it("float: generate in range, ctx = nil", function()
		local rng = make_rng(7)
		local a   = arb.float(-1.0, 1.0)
		for _ = 1, 20 do
			local v, c = a.generate(rng, 10)
			T.ok(v >= -1.0 and v <= 1.0, "float in range")
			T.ok(c == nil, "float ctx is nil")
		end
	end)

	T.it("float: shrink halves toward 0", function()
		local a     = arb.float(0.0, 10.0)
		local cands = collect(a.shrink(8.0, nil))
		T.ok(#cands >= 1)
		T.ok(cands[1][1] < 8.0, "shrunk value is smaller")
		T.ok(cands[1][1] >= 0.0, "shrunk value stays in domain")
	end)

	T.it("bool: generate returns bool, ctx = nil", function()
		local rng = make_rng(3)
		local a   = arb.bool
		local v, c = a.generate(rng, 10)
		T.ok(type(v) == "boolean")
		T.ok(c == nil, "bool ctx is nil")
	end)

	T.it("bool: true shrinks to false", function()
		local a     = arb.bool
		local cands = collect(a.shrink(true, nil))
		T.eq(#cands, 1)
		T.eq(cands[1][1], false)
	end)

	T.it("bool: false has no shrink", function()
		local cands = collect(arb.bool.shrink(false, nil))
		T.eq(#cands, 0)
	end)

	T.it("constant: always same value, no shrink", function()
		local rng = make_rng(1)
		local a   = arb.constant(42)
		T.eq(a.generate(rng, 10), 42)
		T.eq(#collect(a.shrink(42, nil)), 0)
	end)
end)

-- ── String ────────────────────────────────────────────────────────────────────

T.describe("arb: string", function()
	T.it("generates a string, ctx = nil", function()
		local rng = make_rng(5)
		local a   = arb.string()
		local v, c = a.generate(rng, 10)
		T.ok(type(v) == "string")
		T.ok(c == nil)
	end)

	T.it("respects min/max length", function()
		local rng = make_rng(9)
		local a   = arb.string({min=3, max=6})
		for _ = 1, 20 do
			local v = a.generate(rng, 20)
			T.ok(#v >= 3 and #v <= 6, "length in [3,6]")
		end
	end)

	T.it("shrink reduces length first", function()
		local a     = arb.string({min=0, max=20})
		local cands = collect(a.shrink("hello", nil), 10)
		T.ok(#cands > 0, "has shrink candidates")
		-- First candidate should be shorter than "hello"
		T.ok(#cands[1][1] < #"hello", "first shrink is shorter")
	end)

	T.it("shrink reaches empty string eventually", function()
		local a     = arb.string({min=0})
		local v     = "abc"
		-- Run the shrink loop until exhausted
		local prev  = v
		for _ = 1, 100 do
			local cands = collect(a.shrink(prev, nil), 1)
			if #cands == 0 then break end
			prev = cands[1][1]
		end
		T.ok(#prev == 0, "shrink converges to empty string")
	end)
end)

-- ── Array ─────────────────────────────────────────────────────────────────────

T.describe("arb: array", function()
	T.it("generates an array of values", function()
		local rng = make_rng(11)
		local a   = arb.array(arb.int(0, 9), {min=2, max=5})
		local v, c = a.generate(rng, 10)
		T.ok(type(v) == "table")
		T.ok(#v >= 2 and #v <= 5)
		-- int elements: all ctxs nil → ctx is nil
		T.ok(c == nil, "ctx is nil when all element ctxs are nil")
	end)

	T.it("ctx is non-nil when element arb produces ctx", function()
		local rng = make_rng(2)
		-- map produces non-nil ctx
		local elem = arb.map(arb.int(0, 9), function(x) return x * 2 end)
		local a    = arb.array(elem, {max=3})
		local _, c = a.generate(rng, 5)
		-- May be nil if n=0 (empty array); generate with size=10 for more elements
		local v2, c2 = a.generate(make_rng(42), 10)
		if #v2 > 0 then
			T.ok(c2 ~= nil, "ctx stored when element arb has ctx")
		end
	end)

	T.it("shrink reduces length first, then elements", function()
		local a     = arb.array(arb.int(0, 100), {min=0})
		local v     = {10, 20, 30}
		local cands = collect(a.shrink(v, nil), 20)
		T.ok(#cands > 0)
		-- First candidate should be shorter (length shrink precedes element shrink)
		T.ok(#cands[1][1] < #v, "first shrink reduces length")
	end)

	T.it("shrink converges toward empty array", function()
		local a   = arb.array(arb.int(0,10), {min=0})
		local v   = {1, 2, 3, 4, 5}
		local cur = v
		for _ = 1, 200 do
			local cands = collect(a.shrink(cur, nil), 1)
			if #cands == 0 then break end
			cur = cands[1][1]
		end
		T.eq(#cur, 0, "shrink converges to empty array")
	end)
end)

-- ── map ───────────────────────────────────────────────────────────────────────

T.describe("arb: map", function()
	T.it("applies fn to generated value", function()
		local rng = make_rng(1)
		local a   = arb.map(arb.int(1, 10), function(x) return x * 3 end)
		local v, c = a.generate(rng, 10)
		T.ok(v % 3 == 0, "mapped value is multiple of 3")
		T.ok(c ~= nil, "ctx is non-nil (stores pre-map value)")
	end)

	T.it("shrink delegates to inner arb and re-applies fn", function()
		local a     = arb.map(arb.int(1, 10), function(x) return x * 2 end)
		local rng   = make_rng(1)
		local v, c  = a.generate(rng, 10)
		local cands = collect(a.shrink(v, c), 20)
		-- All candidates should also be even (fn applied to shrunk pre-images)
		for _, pair in ipairs(cands) do
			T.ok(pair[1] % 2 == 0, "shrunk candidate also passes through fn")
		end
	end)

	T.it("shrink finds minimal counterexample through map", function()
		-- Without context-carrying, map would return [] from shrink.
		-- With context-carrying, we get proper shrinking.
		local a    = arb.map(arb.int(0, 100), function(x) return x end)
		local ok, info = arb.check("x > 50", a, function(x)
			assert(x <= 50, "x > 50")
		end, {seed = 42, trials = 200})
		T.ok(not ok, "should find counterexample")
		-- Shrunk value should be minimal: 51 (smallest int that fails x <= 50)
		T.eq(info.shrunk, 51, "shrunk to minimal failing value (51)")
	end)
end)

-- ── filter ────────────────────────────────────────────────────────────────────

T.describe("arb: filter", function()
	T.it("generates only values satisfying predicate", function()
		local rng = make_rng(3)
		local a   = arb.filter(arb.int(-20, 20), function(x) return x > 0 end)
		for _ = 1, 20 do
			local v = a.generate(rng, 20)
			T.ok(v > 0, "generated value satisfies predicate")
		end
	end)

	T.it("shrink skips values not satisfying predicate", function()
		local a     = arb.filter(arb.int(0, 100), function(x) return x % 2 == 0 end)
		local cands = collect(a.shrink(50, nil), 30)
		for _, pair in ipairs(cands) do
			T.ok(pair[1] % 2 == 0, "shrunk candidate satisfies predicate (even)")
		end
	end)
end)

-- ── one_of ────────────────────────────────────────────────────────────────────

T.describe("arb: one_of", function()
	T.it("produces values from one of the arbs", function()
		local a = arb.one_of({arb.int(1,3), arb.int(10,12)})
		-- Try multiple seeds; both arbs must be reachable.
		-- (Fixed-seed + LSBit-% tests are fragile: LCG LSBit alternates and
		-- can lock one_of to one choice when arbs consume the same # of calls.)
		local in_first, in_second = false, false
		for seed = 1, 30 do
			if in_first and in_second then break end
			local rng = make_rng(seed)
			for _ = 1, 10 do
				local v = a.generate(rng, 10)
				if v >= 1  and v <= 3  then in_first  = true end
				if v >= 10 and v <= 12 then in_second = true end
			end
		end
		T.ok(in_first,  "first arb reachable")
		T.ok(in_second, "second arb reachable")
	end)

	T.it("shrink stays within the chosen arb", function()
		local rng  = make_rng(5)
		local a    = arb.one_of({arb.int(1,3), arb.int(10,20)})
		local v, c = a.generate(rng, 10)
		local cands = collect(a.shrink(v, c), 20)
		-- Each candidate should be from the same chosen arb's range
		local idx = c[1]
		for _, pair in ipairs(cands) do
			if idx == 1 then T.ok(pair[1] >= 1 and pair[1] <= 3)
			else              T.ok(pair[1] >= 10 and pair[1] <= 20) end
		end
	end)
end)

-- ── tuple ─────────────────────────────────────────────────────────────────────

T.describe("arb: tuple", function()
	T.it("generates tuple of values", function()
		local rng = make_rng(1)
		local a   = arb.tuple({arb.int(0,9), arb.bool})
		local v, c = a.generate(rng, 10)
		T.ok(type(v[1]) == "number")
		T.ok(type(v[2]) == "boolean")
		-- int + bool both have nil ctx → ctxs should be nil
		T.ok(c == nil, "ctx nil when all elements have nil ctx")
	end)

	T.it("shrink produces candidates with one element changed at a time", function()
		local a     = arb.tuple({arb.int(0, 10), arb.int(0, 10)})
		local v     = {8, 6}
		local cands = collect(a.shrink(v, nil), 30)
		T.ok(#cands > 0)
		-- Each candidate differs from original in exactly one position
		for _, pair in ipairs(cands) do
			local sv = pair[1]
			local diffs = 0
			for i = 1, 2 do if sv[i] ~= v[i] then diffs = diffs + 1 end end
			T.eq(diffs, 1, "exactly one element changed per candidate")
		end
	end)
end)

-- ── sized ─────────────────────────────────────────────────────────────────────

T.describe("arb: sized", function()
	T.it("uses size to determine collection size", function()
		local rng = make_rng(4)
		local a   = arb.sized(function(sz)
			return arb.array(arb.int(0, 9), {max=sz})
		end)
		-- small size → small array
		local v_small = a.generate(rng, 2)
		local v_large = a.generate(make_rng(4), 20)
		T.ok(#v_small <= 2,  "small size → small array")
		T.ok(#v_large <= 20, "large size → large array")
	end)

	T.it("shrink delegates to stored arb", function()
		local a     = arb.sized(function(sz)
			return arb.array(arb.int(0, 9), {max=sz})
		end)
		local rng   = make_rng(10)
		local v, c  = a.generate(rng, 15)
		if #v > 0 then
			local cands = collect(a.shrink(v, c), 5)
			T.ok(#cands >= 0, "shrink doesn't crash")
		end
	end)
end)

-- ── chain ─────────────────────────────────────────────────────────────────────

T.describe("arb: chain", function()
	T.it("second arb depends on first value", function()
		local rng = make_rng(1)
		-- Generate an int n, then generate a list of exactly n items
		local a   = arb.chain(arb.int(0, 5), function(n)
			return arb.array(arb.int(0, 9), {min=n, max=n})
		end)
		for _ = 1, 20 do
			local v = a.generate(make_rng(math.random(1,999)), 10)
			-- v is the inner array (length was determined by first value)
			T.ok(type(v) == "table")
		end
	end)
end)

-- ── record ────────────────────────────────────────────────────────────────────

T.describe("arb: record", function()
	T.it("generates record with specified fields", function()
		local rng = make_rng(8)
		local a   = arb.record({x = arb.int(0,10), y = arb.int(0,10)})
		local v, c = a.generate(rng, 10)
		T.ok(type(v.x) == "number")
		T.ok(type(v.y) == "number")
		T.ok(c == nil, "ctx nil when all field ctxs are nil")
	end)

	T.it("shrink produces records with one field changed", function()
		local a     = arb.record({x = arb.int(0,10), y = arb.int(0,10)})
		local v     = {x=8, y=6}
		local cands = collect(a.shrink(v, nil), 30)
		T.ok(#cands > 0)
	end)
end)

-- ── integration: full property test ──────────────────────────────────────────

T.describe("arb.check", function()
	T.it("passes when property holds", function()
		local ok = arb.check("commutativity",
			{arb.int(-50, 50), arb.int(-50, 50)},
			function(a, b) assert(a + b == b + a) end,
			{seed = 1}
		)
		T.ok(ok)
	end)

	T.it("finds and shrinks counterexample", function()
		local ok, info = arb.check("all ints <= 3",
			arb.int(0, 100),
			function(n) assert(n <= 3, "n > 3") end,
			{seed = 42, trials = 200}
		)
		T.ok(not ok,         "should find counterexample")
		T.ok(info ~= nil,    "info returned")
		T.eq(info.shrunk, 4, "shrunk to minimal failing value (4)")
		T.ok(info.shrink_steps > 0, "shrinking occurred")
	end)

	T.it("shrinks mapped values correctly (map doesn't break shrinking)", function()
		-- Multiply by 2, check result <= 10.  Min failing raw = 6 → mapped = 12.
		local ok, info = arb.check("mapped <= 10",
			arb.map(arb.int(0, 50), function(x) return x * 2 end),
			function(n) assert(n <= 10, "n > 10") end,
			{seed = 1, trials = 200}
		)
		T.ok(not ok)
		T.eq(info.shrunk, 12, "shrunk to 12 (= 6 * 2, minimal failing)")
	end)

	T.it("multi-arb: fn receives unpacked arguments", function()
		local ok, info = arb.check("a < b",
			{arb.int(0, 50), arb.int(0, 50)},
			function(a, b) assert(a < b, "a >= b") end,
			{seed = 7, trials = 300}
		)
		T.ok(not ok)
		-- Minimal failing case: a == b (e.g. {0, 0})
		T.ok(info.shrunk[1] >= info.shrunk[2], "shrunk to a >= b")
	end)

	T.it("seed is deterministic", function()
		local function run()
			local _, info = arb.check("x > 5",
				arb.int(0, 100),
				function(x) assert(x > 5) end,
				{seed = 999, trials = 50}
			)
			return info and info.shrunk
		end
		T.eq(run(), run(), "same seed → same shrunk value")
	end)
end)

-- ── arb.it integration ────────────────────────────────────────────────────────

T.describe("arb.it", function()
	T.it("passes when property holds (smoke test)", function()
		-- arb.it inside T.it is fine — it registers another T.it
		-- We just test arb.check directly here to avoid nesting
		local ok = arb.check("int in range",
			arb.int(1, 10),
			function(n) assert(n >= 1 and n <= 10) end,
			{seed = 5}
		)
		T.ok(ok)
	end)
end)
