if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local reg = require("lib.platform.caps.registry")

T.describe("caps.registry risk", function()
	T.it("no allow_write has medium severity", function()
		local result = reg.risk({ type = "registry" })
		T.eq(result.severity, "medium")
	end)

	T.it("allow_write=false has medium severity", function()
		local result = reg.risk({ type = "registry", allow_write = false })
		T.eq(result.severity, "medium")
	end)

	T.it("allow_write=true has high severity", function()
		local result = reg.risk({ type = "registry", allow_write = true })
		T.eq(result.severity, "high")
	end)
end)
