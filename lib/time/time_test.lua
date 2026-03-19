if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local time = require("lib.time")

-- ── mod.time ────────────────────────────────────────────────────────────────

T.describe("time.time", function()
	T.it("returns a number", function()
		local t = time.time()
		T.ok(type(t) == "number", "time() should return a number, got " .. type(t))
	end)

	T.it("returns a positive value", function()
		local t = time.time()
		T.ok(t > 0, "time() should be positive, got " .. tostring(t))
	end)

	T.it("returns a value resembling unix epoch seconds", function()
		local t = time.time()
		-- Should be after 2020-01-01 (1577836800) and before 2100-01-01 (4102444800)
		T.ok(t > 1577836800, "time() too small: " .. tostring(t))
		T.ok(t < 4102444800, "time() too large: " .. tostring(t))
	end)

	T.it("has sub-second precision", function()
		-- gettimeofday provides microsecond precision; the fractional part should
		-- be non-zero at least sometimes across a few samples.
		local found_frac = false
		for _ = 1, 100 do
			local t = time.time()
			if t % 1 ~= 0 then
				found_frac = true
				break
			end
		end
		T.ok(found_frac, "time() should have sub-second precision")
	end)

	T.it("is monotonically non-decreasing across calls", function()
		local t1 = time.time()
		local t2 = time.time()
		T.ok(t2 >= t1, "second call should be >= first: " .. tostring(t1) .. " vs " .. tostring(t2))
	end)

	T.it("advances over a busy loop", function()
		local t1 = time.time()
		-- Burn a little time
		local sum = 0
		for i = 1, 1e5 do sum = sum + i end
		local t2 = time.time()
		T.ok(t2 > t1, "time should advance after work: " .. tostring(t1) .. " vs " .. tostring(t2))
		-- Suppress unused warning
		local _ = sum
	end)
end)
