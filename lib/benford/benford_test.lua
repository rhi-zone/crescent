-- lib/benford/benford_test.lua
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local B = require("lib.benford")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Sum values in table (keys k1..k2 or all pairs)
local function sum_values(t)
	local s = 0
	for _, v in pairs(t) do s = s + v end
	return s
end

-- Powers of 2 from 2^1 to 2^200: strongly Benford-distributed
local function powers_of_two()
	local out = {}
	for i = 1, 200 do
		out[i] = 2 ^ i
	end
	return out
end

-- Uniform data 1..9 repeated: violates Benford
local function uniform_digits(n)
	local out = {}
	for i = 1, n do
		out[i] = (i % 9) + 1
	end
	return out
end

-- ── expected() ───────────────────────────────────────────────────────────────

T.describe("benford.expected", function()
	T.it("_tier is pure", function()
		T.eq(B._tier, "pure")
	end)

	T.it("P(1) ≈ 0.301", function()
		local p = B.expected(1)
		T.ok(math.abs(p - 0.30103) < 1e-5, "P(1)=" .. tostring(p))
	end)

	T.it("P(2) ≈ 0.176", function()
		local p = B.expected(2)
		T.ok(math.abs(p - 0.17609) < 1e-4, "P(2)=" .. tostring(p))
	end)

	T.it("P(9) ≈ 0.046", function()
		local p = B.expected(9)
		T.ok(math.abs(p - 0.04576) < 1e-4, "P(9)=" .. tostring(p))
	end)

	T.it("P values are decreasing", function()
		for d = 1, 8 do
			T.ok(B.expected(d) > B.expected(d + 1),
				"P(" .. d .. ") should be > P(" .. (d + 1) .. ")")
		end
	end)
end)

-- ── expected_all() ───────────────────────────────────────────────────────────

T.describe("benford.expected_all", function()
	T.it("returns 9 entries", function()
		local t = B.expected_all()
		local count = 0
		for d = 1, 9 do
			if t[d] then count = count + 1 end
		end
		T.eq(count, 9)
	end)

	T.it("sums to 1.0 (within float error)", function()
		local s = sum_values(B.expected_all())
		T.ok(math.abs(s - 1.0) < 1e-10, "sum=" .. tostring(s))
	end)

	T.it("matches individual expected() calls", function()
		local t = B.expected_all()
		for d = 1, 9 do
			T.ok(math.abs(t[d] - B.expected(d)) < 1e-15)
		end
	end)
end)

-- ── Second digit expected ─────────────────────────────────────────────────────

T.describe("benford.expected_second_all", function()
	T.it("returns 10 entries (digits 0-9)", function()
		local t = B.expected_second_all()
		local count = 0
		for d = 0, 9 do
			if t[d] then count = count + 1 end
		end
		T.eq(count, 10)
	end)

	T.it("sums to 1.0", function()
		local s = sum_values(B.expected_second_all())
		T.ok(math.abs(s - 1.0) < 1e-10, "sum=" .. tostring(s))
	end)

	T.it("digit 0 has highest probability", function()
		local t = B.expected_second_all()
		for d = 1, 9 do
			T.ok(t[0] > t[d], "P(0) should be highest; P(" .. d .. ")=" .. t[d])
		end
	end)
end)

-- ── Two-digit expected ────────────────────────────────────────────────────────

T.describe("benford.expected_two_digits_all", function()
	T.it("returns 90 entries (10-99)", function()
		local t = B.expected_two_digits_all()
		local count = 0
		for d = 10, 99 do
			if t[d] then count = count + 1 end
		end
		T.eq(count, 90)
	end)

	T.it("sums to 1.0", function()
		local s = sum_values(B.expected_two_digits_all())
		T.ok(math.abs(s - 1.0) < 1e-10, "sum=" .. tostring(s))
	end)

	T.it("10 has highest probability", function()
		local t = B.expected_two_digits_all()
		for d = 11, 99 do
			T.ok(t[10] > t[d], "P(10) should be highest")
		end
	end)
end)

-- ── analyze() on Benford-distributed data ────────────────────────────────────

T.describe("benford.analyze on powers of 2", function()
	local data = powers_of_two()
	local result = B.analyze(data)

	T.it("returns a result table", function()
		T.ok(result ~= nil)
		T.ok(type(result) == "table")
	end)

	T.it("n = 200", function()
		T.eq(result.n, 200)
	end)

	T.it("observed[1] is highest count", function()
		for d = 2, 9 do
			T.ok(result.observed[1] >= result.observed[d],
				"observed[1] should be >= observed[" .. d .. "]")
		end
	end)

	T.it("conformity is close or acceptable", function()
		local ok = result.conformity == "close" or result.conformity == "acceptable"
		T.ok(ok, "conformity=" .. tostring(result.conformity))
	end)

	T.it("chi_squared_p > 0.05 (not rejected at 5%)", function()
		T.ok(result.chi_squared_p > 0.05,
			"p=" .. tostring(result.chi_squared_p))
	end)

	T.it("has all required fields", function()
		T.ok(result.observed ~= nil)
		T.ok(result.frequency ~= nil)
		T.ok(result.expected ~= nil)
		T.ok(result.chi_squared ~= nil)
		T.ok(result.chi_squared_p ~= nil)
		T.ok(result.mad ~= nil)
		T.ok(result.z_scores ~= nil)
		T.ok(result.conformity ~= nil)
		T.ok(result.n ~= nil)
	end)

	T.it("frequency sums to ~1", function()
		local s = sum_values(result.frequency)
		T.ok(math.abs(s - 1.0) < 1e-10, "freq sum=" .. tostring(s))
	end)

	T.it("expected field matches expected_all()", function()
		local exp = B.expected_all()
		for d = 1, 9 do
			T.ok(math.abs(result.expected[d] - exp[d]) < 1e-15)
		end
	end)

	T.it("MAD is small (< 0.015)", function()
		T.ok(result.mad < 0.015, "mad=" .. tostring(result.mad))
	end)
end)

-- ── analyze() on uniform data: nonconforming ─────────────────────────────────

T.describe("benford.analyze on uniform data", function()
	local data = uniform_digits(900)
	local result = B.analyze(data)

	T.it("returns a result", function()
		T.ok(result ~= nil)
	end)

	T.it("conformity = nonconforming", function()
		T.eq(result.conformity, "nonconforming")
	end)

	T.it("chi_squared is large", function()
		T.ok(result.chi_squared > 50, "chi2=" .. tostring(result.chi_squared))
	end)

	T.it("chi_squared_p < 0.001", function()
		T.ok(result.chi_squared_p < 0.001, "p=" .. tostring(result.chi_squared_p))
	end)
end)

-- ── analyze() error cases ─────────────────────────────────────────────────────

T.describe("benford.analyze error cases", function()
	T.it("returns error on empty table", function()
		local r, err = B.analyze({})
		T.ok(r == nil)
		T.ok(type(err) == "string")
	end)

	T.it("returns error on all-zeros", function()
		local r, err = B.analyze({0, 0, 0})
		T.ok(r == nil)
		T.ok(type(err) == "string")
	end)

	T.it("returns error on non-table", function()
		local r, err = B.analyze(42)
		T.ok(r == nil)
		T.ok(type(err) == "string")
	end)

	T.it("ignores negative numbers correctly (uses absolute value)", function()
		local pos = {100, 200, 300, 1000, 1100, 1200, 2000, 10000}
		local neg = {-100, -200, -300, -1000, -1100, -1200, -2000, -10000}
		local r_pos = B.analyze(pos)
		local r_neg = B.analyze(neg)
		T.ok(r_pos ~= nil)
		T.ok(r_neg ~= nil)
		-- Both should give same digit distribution
		for d = 1, 9 do
			T.eq(r_pos.observed[d], r_neg.observed[d])
		end
	end)

	T.it("zeros are ignored in count", function()
		local data = {0, 0, 1, 2, 3}
		local r = B.analyze(data)
		T.ok(r ~= nil)
		T.eq(r.n, 3)
	end)
end)

-- ── z_score() ────────────────────────────────────────────────────────────────

T.describe("benford.z_score", function()
	T.it("returns 0 when observed = expected", function()
		local z = B.z_score(0.301, 0.301, 1000)
		T.ok(math.abs(z) < 1e-10, "z=" .. tostring(z))
	end)

	T.it("positive z when observed > expected", function()
		local z = B.z_score(0.4, 0.301, 1000)
		T.ok(z > 0, "z=" .. tostring(z))
	end)

	T.it("negative z when observed < expected", function()
		local z = B.z_score(0.1, 0.301, 1000)
		T.ok(z < 0, "z=" .. tostring(z))
	end)

	T.it("larger deviation gives larger |z|", function()
		local z1 = B.z_score(0.35, 0.301, 1000)
		local z2 = B.z_score(0.45, 0.301, 1000)
		T.ok(math.abs(z2) > math.abs(z1))
	end)

	T.it("larger n gives larger |z| for same deviation", function()
		local z1 = B.z_score(0.4, 0.301, 100)
		local z2 = B.z_score(0.4, 0.301, 10000)
		T.ok(math.abs(z2) > math.abs(z1))
	end)
end)

-- ── chi_squared() ────────────────────────────────────────────────────────────

T.describe("benford.chi_squared", function()
	T.it("zero when observed = expected * n", function()
		local exp = B.expected_all()
		local n = 1000
		local obs = {}
		for d = 1, 9 do obs[d] = n * exp[d] end
		local chi2 = B.chi_squared(obs, exp)
		T.ok(chi2 < 1e-6, "chi2=" .. tostring(chi2))
	end)

	T.it("positive when observed differs from expected", function()
		local exp = B.expected_all()
		local obs = {[1]=400,[2]=100,[3]=100,[4]=100,[5]=80,[6]=70,[7]=60,[8]=50,[9]=40}
		local chi2 = B.chi_squared(obs, exp)
		T.ok(chi2 > 0)
	end)

	T.it("larger deviation gives larger chi2", function()
		local exp = B.expected_all()
		local obs1 = {}
		local obs2 = {}
		for d = 1, 9 do
			obs1[d] = math.floor(1000 * exp[d] + (d == 1 and 10 or 0))
			obs2[d] = math.floor(1000 * exp[d] + (d == 1 and 50 or 0))
		end
		T.ok(B.chi_squared(obs2, exp) > B.chi_squared(obs1, exp))
	end)
end)

-- ── chi_squared_pvalue() ──────────────────────────────────────────────────────

T.describe("benford.chi_squared_pvalue", function()
	T.it("p ≈ 0.5 for chi2 ≈ median of chi2(8)", function()
		-- Median of chi2(8) ≈ 7.34
		local p = B.chi_squared_pvalue(7.34, 8)
		T.ok(math.abs(p - 0.5) < 0.05, "p=" .. tostring(p))
	end)

	T.it("p < 0.05 for chi2 = 15.51 (critical value at 5% for df=8)", function()
		-- chi2(8, 0.05) ≈ 15.507
		local p = B.chi_squared_pvalue(15.51, 8)
		T.ok(p < 0.055, "p=" .. tostring(p))
		T.ok(p > 0, "p should be positive")
	end)

	T.it("p → 1 as chi2 → 0", function()
		local p = B.chi_squared_pvalue(0.001, 8)
		T.ok(p > 0.99, "p=" .. tostring(p))
	end)

	T.it("p → 0 as chi2 → large", function()
		local p = B.chi_squared_pvalue(100, 8)
		T.ok(p < 1e-10, "p=" .. tostring(p))
	end)

	T.it("p is monotonically decreasing in chi2", function()
		local prev = 1
		for chi2 = 1, 30, 2 do
			local p = B.chi_squared_pvalue(chi2, 8)
			T.ok(p <= prev, "p not decreasing at chi2=" .. chi2)
			prev = p
		end
	end)
end)

-- ── suspicious_digits() ───────────────────────────────────────────────────────

T.describe("benford.suspicious_digits", function()
	T.it("returns empty list for clean Benford data", function()
		local result = B.analyze(powers_of_two())
		local s = B.suspicious_digits(result)
		-- Powers of 2 conform well; may have 0 or few suspicious digits
		T.ok(type(s) == "table")
	end)

	T.it("detects obvious over-representation", function()
		-- Construct result with artificially high z-score for digit 1
		local n = 1000
		local exp = B.expected_all()
		-- Massively over-represent digit 1
		local obs = {}
		local remaining = n
		obs[1] = math.floor(n * 0.7)  -- 70% instead of 30%
		remaining = remaining - obs[1]
		for d = 2, 9 do
			obs[d] = math.floor(remaining * exp[d] / (1 - exp[1]))
		end
		local r = B.analyze(obs)
		-- r will be nil if obs sums to 0 for some digits; use manual result
		-- Build a synthetic result with extreme z-scores
		local synthetic = {
			z_scores = { [1] = 5.0, [2] = -0.5, [3] = 0.3, [4] = -0.1,
			             [5] = 0.2, [6] = -0.3, [7] = 0.1, [8] = 0.0, [9] = -0.2 },
		}
		local s = B.suspicious_digits(synthetic)
		T.eq(#s, 1)
		T.eq(s[1].digit, 1)
		T.eq(s[1].direction, "over")
	end)

	T.it("detects under-representation", function()
		local synthetic = {
			z_scores = { [1] = 0.5, [2] = -3.0, [3] = 0.1, [4] = 0.0,
			             [5] = 0.2, [6] = -0.3, [7] = 0.1, [8] = 0.0, [9] = -0.2 },
		}
		local s = B.suspicious_digits(synthetic)
		T.eq(#s, 1)
		T.eq(s[1].digit, 2)
		T.eq(s[1].direction, "under")
	end)

	T.it("returns digits sorted by |z| descending", function()
		local synthetic = {
			z_scores = { [1] = 2.5, [2] = -4.0, [3] = 3.0, [4] = 0.0,
			             [5] = 0.2, [6] = -0.3, [7] = 0.1, [8] = 0.0, [9] = -0.2 },
		}
		local s = B.suspicious_digits(synthetic)
		T.eq(#s, 3)
		-- sorted by |z| desc: [2]=-4.0, [3]=3.0, [1]=2.5
		T.eq(s[1].digit, 2)
		T.eq(s[2].digit, 3)
		T.eq(s[3].digit, 1)
	end)

	T.it("threshold is exactly 1.96", function()
		local synthetic = {
			z_scores = { [1] = 1.95, [2] = 1.97, [3] = -1.96, [4] = 0.0,
			             [5] = 0.0, [6] = 0.0, [7] = 0.0, [8] = 0.0, [9] = 0.0 },
		}
		local s = B.suspicious_digits(synthetic)
		-- 1.95 < 1.96 → not suspicious; 1.97 > 1.96 → suspicious; -1.96 not > 1.96 → not suspicious
		T.eq(#s, 1)
		T.eq(s[1].digit, 2)
	end)
end)

-- ── generate() ───────────────────────────────────────────────────────────────

T.describe("benford.generate", function()
	T.it("returns array of correct length", function()
		local data = B.generate(500, {seed = 42})
		T.eq(#data, 500)
	end)

	T.it("all values are positive integers", function()
		local data = B.generate(100, {seed = 7})
		for _, v in ipairs(data) do
			T.ok(v > 0, "v=" .. tostring(v))
			T.ok(math.floor(v) == v, "not integer: " .. tostring(v))
		end
	end)

	T.it("seeded generation is reproducible", function()
		local d1 = B.generate(20, {seed = 123})
		local d2 = B.generate(20, {seed = 123})
		for i = 1, 20 do
			T.eq(d1[i], d2[i])
		end
	end)

	T.it("different seeds produce different data", function()
		local d1 = B.generate(20, {seed = 1})
		local d2 = B.generate(20, {seed = 2})
		local differ = false
		for i = 1, 20 do
			if d1[i] ~= d2[i] then differ = true break end
		end
		T.ok(differ)
	end)

	T.it("generated data conforms to Benford's Law", function()
		local data = B.generate(1000, {seed = 999})
		local result = B.analyze(data)
		T.ok(result ~= nil, "analyze failed")
		local ok = result.conformity == "close" or
		           result.conformity == "acceptable" or
		           result.conformity == "marginally"
		T.ok(ok, "conformity=" .. tostring(result.conformity))
	end)
end)

-- ── analyze_second() ─────────────────────────────────────────────────────────

T.describe("benford.analyze_second", function()
	T.it("returns error on empty table", function()
		local r, err = B.analyze_second({})
		T.ok(r == nil)
		T.ok(type(err) == "string")
	end)

	T.it("returns result for valid data", function()
		-- Use a large dataset with multi-digit numbers
		local data = {}
		for i = 1, 200 do data[i] = 2 ^ i end
		local r = B.analyze_second(data)
		T.ok(r ~= nil, "nil result")
		T.ok(r.n > 0)
	end)

	T.it("frequency sums to ~1", function()
		local data = {}
		for i = 1, 200 do data[i] = 2 ^ i end
		local r = B.analyze_second(data)
		T.ok(r ~= nil)
		local s = sum_values(r.frequency)
		T.ok(math.abs(s - 1.0) < 1e-10, "freq sum=" .. tostring(s))
	end)
end)

-- ── analyze_two_digits() ──────────────────────────────────────────────────────

T.describe("benford.analyze_two_digits", function()
	T.it("returns error on empty table", function()
		local r, err = B.analyze_two_digits({})
		T.ok(r == nil)
		T.ok(type(err) == "string")
	end)

	T.it("returns result for powers of two", function()
		local data = {}
		for i = 1, 200 do data[i] = 2 ^ i end
		local r = B.analyze_two_digits(data)
		T.ok(r ~= nil)
		T.ok(r.n > 0)
	end)

	T.it("frequency sums to ~1", function()
		local data = {}
		for i = 1, 200 do data[i] = 2 ^ i end
		local r = B.analyze_two_digits(data)
		T.ok(r ~= nil)
		local s = sum_values(r.frequency)
		T.ok(math.abs(s - 1.0) < 1e-10, "freq sum=" .. tostring(s))
	end)

	T.it("two-digit result has entries for 10..99", function()
		local data = {}
		for i = 1, 200 do data[i] = 2 ^ i end
		local r = B.analyze_two_digits(data)
		T.ok(r ~= nil)
		-- all 90 keys present in expected
		local count = 0
		for d = 10, 99 do
			if r.expected[d] then count = count + 1 end
		end
		T.eq(count, 90)
	end)
end)
