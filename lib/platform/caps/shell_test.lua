if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local shell = require("lib.platform.caps.shell")

T.describe("caps.shell risk", function()
	T.it("shell has critical severity", function()
		local result = shell.risk({ type = "shell" })
		T.eq(result.severity, "critical")
		T.ok(result.text:find("arbitrary shell"), "text mentions arbitrary shell")
	end)
end)
