if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local exec = require("lib.exec")

T.describe("exec.run", function()
	T.it("captures stdout", function()
		local out, err = exec.run("printf", { "%s", "hello" }, { popen = io.popen })
		T.eq(err, nil)
		T.eq(out, "hello")
	end)

	T.it("captures stdout with newline", function()
		local out, err = exec.run("echo", { "hello" }, { popen = io.popen })
		T.eq(err, nil)
		T.eq(out, "hello\n")
	end)

	T.it("returns nil + errmsg on non-zero exit", function()
		local out, err = exec.run("false", {}, { popen = io.popen })
		T.eq(out, nil)
		T.ok(err ~= nil)
		T.ok(err:find("false"), "error should mention command")
	end)

	T.it("passes multiple args", function()
		local out, err = exec.run("printf", { "%s %s", "foo", "bar" }, { popen = io.popen })
		T.eq(err, nil)
		T.eq(out, "foo bar")
	end)

	T.it("handles args with spaces and quotes", function()
		local out, err = exec.run("printf", { "%s", "hello world" }, { popen = io.popen })
		T.eq(err, nil)
		T.eq(out, "hello world")
	end)

	T.it("merges stderr into stdout with opts.stderr='merge'", function()
		local out, err = exec.run(
			"sh", { "-c", "echo out; echo err >&2" },
			{ popen = io.popen, stderr = "merge" }
		)
		T.eq(err, nil)
		T.ok(out:find("out"), "stdout should contain 'out'")
		T.ok(out:find("err"), "merged stderr should contain 'err'")
	end)

	T.it("discards stderr with opts.stderr='discard'", function()
		local out, err = exec.run(
			"sh", { "-c", "echo out; echo err >&2" },
			{ popen = io.popen, stderr = "discard" }
		)
		T.eq(err, nil)
		T.eq(out, "out\n")
	end)

	T.it("uses injected popen", function()
		local called_with
		local function fake_popen(cmd, mode)
			called_with = cmd
			local lines = { "fake output\n" }
			local i = 0
			return {
				read  = function(_, fmt)
					if fmt == "*a" then return "fake output\n" end
				end,
				close = function() return true, "exit", 0 end,
			}
		end
		local out, err = exec.run("mytool", { "arg1" }, { popen = fake_popen })
		T.eq(err, nil)
		T.eq(out, "fake output\n")
		T.ok(called_with:find("mytool"), "popen was called with the command")
	end)
end)

T.describe("exec.run_ex", function()
	T.it("returns stdout, stderr, and exit code", function()
		local stdout, stderr, code = exec.run_ex(
			"sh", { "-c", "echo out; echo err >&2; exit 0" },
			{ popen = io.popen }
		)
		T.eq(code, 0)
		T.eq(stdout, "out\n")
		T.eq(stderr, "err\n")
	end)

	T.it("returns nil + errmsg on non-zero exit", function()
		local stdout, stderr, code = exec.run_ex(
			"sh", { "-c", "echo err >&2; exit 2" },
			{ popen = io.popen }
		)
		T.eq(stdout, nil)
		T.ok(stderr == nil or type(stderr) == "string")
		T.ok(code == nil or code == 2)
	end)
end)
