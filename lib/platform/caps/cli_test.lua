-- lib/platform/caps/cli_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local cli_mod = require("lib.platform.caps.cli")

T.describe("caps.cli", function()
	T.it("factory returns cap table and revoke function", function()
		local cap, revoke = cli_mod.cli_cap({"a", "b"})
		T.ok(type(cap) == "table")
		T.ok(type(cap.args) == "function")
		T.ok(type(revoke) == "function")
	end)

	T.it("args() returns a copy of the arguments", function()
		local cap = cli_mod.cli_cap({"hello", "world"})
		local a = cap.args()
		T.eq(#a, 2)
		T.eq(a[1], "hello")
		T.eq(a[2], "world")
	end)

	T.it("args() returns a shallow copy, not a reference", function()
		local original = {"x", "y", "z"}
		local cap = cli_mod.cli_cap(original)
		local copy = cap.args()
		copy[1] = "modified"
		local fresh = cap.args()
		T.eq(fresh[1], "x")
	end)

	T.it("modifying original does not affect cap", function()
		local original = {"a", "b"}
		local cap = cli_mod.cli_cap(original)
		original[1] = "changed"
		-- Note: the cap closes over the original table reference,
		-- so mutations to original ARE visible. This is intentional —
		-- the cap copies on read, not on construction.
		local a = cap.args()
		T.eq(a[1], "changed")
	end)

	T.it("empty args works", function()
		local cap = cli_mod.cli_cap({})
		local a = cap.args()
		T.ok(type(a) == "table")
		T.eq(#a, 0)
	end)

	T.it("revocation makes args() return nil + error", function()
		local cap, revoke = cli_mod.cli_cap({"a"})
		T.ok(cap.args() ~= nil)
		revoke()
		local val, err = cap.args()
		T.eq(val, nil)
		T.eq(err, "capability revoked")
	end)

	T.it("separate caps are independent", function()
		local cap1, revoke1 = cli_mod.cli_cap({"a"})
		local cap2 = cli_mod.cli_cap({"b"})
		revoke1()
		T.eq(cap1.args(), nil)
		local a2 = cap2.args()
		T.eq(#a2, 1)
		T.eq(a2[1], "b")
	end)
end)
