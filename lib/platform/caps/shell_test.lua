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

T.describe("caps.shell run_stream", function()
	T.it("yields stdout lines then EOF", function()
		local cap = shell.shell_cap()
		local iter, err = cap.run_stream("printf 'a\\nb\\nc\\n'")
		T.ok(iter, "iter created: " .. tostring(err))
		local frames = {}
		while true do
			local line, lerr = iter()
			T.eq(lerr, nil)
			if line == nil then break end
			frames[#frames + 1] = line
			if #frames > 10 then break end -- safety
		end
		T.eq(#frames, 3)
		T.eq(frames[1], "a")
		T.eq(frames[2], "b")
		T.eq(frames[3], "c")
	end)

	T.it("iter:close() is idempotent", function()
		local cap = shell.shell_cap()
		local iter = cap.run_stream("printf 'x\\ny\\n'")
		T.ok(iter)
		iter:close()
		iter:close() -- second close must not error
		-- After close, calling iter() returns (nil, nil) without erroring.
		local line, lerr = iter()
		T.eq(line, nil)
		T.eq(lerr, nil)
	end)

	T.it("rejects non-string command", function()
		local cap = shell.shell_cap()
		local iter, err = cap.run_stream(42)
		T.eq(iter, nil)
		T.ok(err and err:find("string"), "err mentions string requirement")
	end)

	T.it("returns capability revoked after revoke", function()
		local cap, revoke = shell.shell_cap()
		revoke()
		local iter, err = cap.run_stream("echo x")
		T.eq(iter, nil)
		T.ok(err and err:find("revoked"), "err mentions revoked")
	end)

	T.it("attenuated sub_cap has run_stream", function()
		local cap = shell.shell_cap()
		local sub = cap.attenuate({ type = "shell" })
		T.eq(type(sub.run_stream), "function")
		local iter = sub.run_stream("printf 'one\\n'")
		T.ok(iter)
		local line = iter()
		T.eq(line, "one")
		iter:close()
	end)
end)
