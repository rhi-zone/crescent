-- lib/platform/caps/time_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local time_mod = require("lib.platform.caps.time")

T.describe("caps.time", function()
	T.it("factory returns cap table and revoke function", function()
		local cap, revoke = time_mod.time_cap()
		T.ok(type(cap) == "table")
		T.ok(type(cap.now) == "function")
		T.ok(type(revoke) == "function")
	end)

	T.it("now() returns an integer", function()
		local cap = time_mod.time_cap()
		local t = cap.now()
		T.ok(type(t) == "number")
		T.eq(t, math.floor(t))  -- integer
	end)

	T.it("now() returns a plausible Unix timestamp", function()
		local cap = time_mod.time_cap()
		local t = cap.now()
		-- After 2020-01-01 and before 2100-01-01
		T.ok(t > 1577836800, "timestamp too small: " .. tostring(t))
		T.ok(t < 4102444800, "timestamp too large: " .. tostring(t))
	end)

	T.it("revocation makes now() return nil + error", function()
		local cap, revoke = time_mod.time_cap()
		T.ok(cap.now() ~= nil)
		revoke()
		local val, err = cap.now()
		T.eq(val, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("separate caps are independent", function()
		local cap1, revoke1 = time_mod.time_cap()
		local cap2 = time_mod.time_cap()
		revoke1()
		-- cap1 revoked, cap2 still works
		T.eq(cap1.now(), nil)
		T.ok(cap2.now() ~= nil)
	end)
end)
