if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local exec = require("lib.exec")

local io_caps = { popen = io.popen }
local io_ex_caps = { popen = io.popen, open = io.open, remove = os.remove, tmpname = os.tmpname }

T.describe("exec.run", function()
	T.it("captures stdout", function()
		local out, err = exec.run("printf", { "%s", "hello" }, io_caps)
		T.eq(err, nil)
		T.eq(out, "hello")
	end)

	T.it("captures stdout with newline", function()
		local out, err = exec.run("echo", { "hello" }, io_caps)
		T.eq(err, nil)
		T.eq(out, "hello\n")
	end)

	T.it("returns nil + errmsg on non-zero exit", function()
		local out, err = exec.run("false", {}, io_caps)
		T.eq(out, nil)
		T.ok(err ~= nil)
		T.ok(err:find("false"), "error should mention command")
	end)

	T.it("passes multiple args", function()
		local out, err = exec.run("printf", { "%s %s", "foo", "bar" }, io_caps)
		T.eq(err, nil)
		T.eq(out, "foo bar")
	end)

	T.it("handles args with spaces and quotes", function()
		local out, err = exec.run("printf", { "%s", "hello world" }, io_caps)
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
		local function fake_popen(cmd, _mode)
			called_with = cmd
			return {
				read  = function(_, fmt) if fmt == "*a" then return "fake output\n__EXEC_EXIT__0\n" end end,
				close = function() return true, "exit", 0 end,
			}
		end
		local out, err = exec.run("mytool", { "arg1" }, { popen = fake_popen })
		T.eq(err, nil)
		T.eq(out, "fake output")
		T.ok(called_with:find("mytool"), "popen was called with the command")
	end)
end)

T.describe("exec.run_ex", function()
	T.it("returns stdout, stderr, and exit code", function()
		local stdout, stderr, code = exec.run_ex(
			"sh", { "-c", "echo out; echo err >&2; exit 0" },
			io_ex_caps
		)
		T.eq(code, 0)
		T.eq(stdout, "out\n")
		T.eq(stderr, "err\n")
	end)

	T.it("returns nil + errmsg on non-zero exit", function()
		local stdout, stderr_val, code_val = exec.run_ex(
			"sh", { "-c", "echo err >&2; exit 2" },
			io_ex_caps
		)
		T.eq(stdout, nil)
		T.ok(stderr_val == nil or type(stderr_val) == "string")
		T.ok(code_val == nil or code_val == 2)
	end)
end)
