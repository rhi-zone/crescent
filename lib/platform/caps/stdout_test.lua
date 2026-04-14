-- lib/platform/caps/stdout_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local stdout_mod = require("lib.platform.caps.stdout")

T.describe("caps.stdout", function()
	T.it("factory returns cap table and revoke function", function()
		local cap, revoke = stdout_mod.stdout_cap()
		T.ok(type(cap) == "table")
		T.ok(type(cap.write) == "function")
		T.ok(type(cap.flush) == "function")
		T.ok(type(revoke) == "function")
	end)

	T.it("factory accepts opts table", function()
		local cap, revoke = stdout_mod.stdout_cap({})
		T.ok(type(cap) == "table")
		T.ok(type(revoke) == "function")
	end)

	T.it("write() returns true on success", function()
		local cap = stdout_mod.stdout_cap()
		-- This will print to stdout but that's fine in tests
		local ok = cap.write("")
		T.eq(ok, true)
	end)

	T.it("flush() returns true on success", function()
		local cap = stdout_mod.stdout_cap()
		local ok = cap.flush()
		T.eq(ok, true)
	end)

	T.it("revocation makes write() return nil + error", function()
		local cap, revoke = stdout_mod.stdout_cap()
		revoke()
		local val, err = cap.write("hello")
		T.eq(val, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("revocation makes flush() return nil + error", function()
		local cap, revoke = stdout_mod.stdout_cap()
		revoke()
		local val, err = cap.flush()
		T.eq(val, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("separate caps are independent", function()
		local cap1, revoke1 = stdout_mod.stdout_cap()
		local cap2 = stdout_mod.stdout_cap()
		revoke1()
		T.eq(cap1.write("x"), nil)
		local ok = cap2.write("")
		T.eq(ok, true)
	end)
end)
