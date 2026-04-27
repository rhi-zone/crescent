if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local fs = require("lib.platform.caps.fs")

T.describe("caps.fs risk", function()
	T.it("readonly fs has medium severity", function()
		local result = fs.risk({ type = "fs", root = "/tmp/data", readonly = true })
		T.eq(result.severity, "medium")
		T.ok(result.text:find("/tmp/data"), "text includes root path")
	end)

	T.it("writable fs has high severity", function()
		local result = fs.risk({ type = "fs", root = "/tmp/data" })
		T.eq(result.severity, "high")
		T.ok(result.text:find("/tmp/data"), "text includes root path")
	end)

	T.it("missing root uses fallback text", function()
		local result = fs.risk({ type = "fs" })
		T.ok(result ~= nil)
		T.ok(result.text:find("a configured directory"), "text mentions configured directory")
	end)
end)
