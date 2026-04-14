-- lib/platform/caps/stdin_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local stdin_mod = require("lib.platform.caps.stdin")

T.describe("caps.stdin", function()
	T.it("factory returns cap table and revoke function", function()
		local cap, revoke = stdin_mod.stdin_cap()
		T.ok(type(cap) == "table")
		T.ok(type(cap.read) == "function")
		T.ok(type(cap.line) == "function")
		T.ok(type(revoke) == "function")
	end)

	T.it("factory accepts opts table", function()
		local cap, revoke = stdin_mod.stdin_cap({})
		T.ok(type(cap) == "table")
		T.ok(type(revoke) == "function")
	end)

	T.it("revocation makes read() return nil + error", function()
		local cap, revoke = stdin_mod.stdin_cap()
		revoke()
		local val, err = cap.read(1)
		T.eq(val, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("revocation makes line() return nil + error", function()
		local cap, revoke = stdin_mod.stdin_cap()
		revoke()
		local val, err = cap.line()
		T.eq(val, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("separate caps are independent", function()
		local cap1, revoke1 = stdin_mod.stdin_cap()
		local cap2 = stdin_mod.stdin_cap()
		revoke1()
		local v1, e1 = cap1.read(1)
		T.eq(v1, nil)
		T.eq(e1, "capability revoked")
		-- cap2 not revoked — has expected fields
		T.ok(type(cap2.read) == "function")
		T.ok(type(cap2.line) == "function")
	end)
end)
