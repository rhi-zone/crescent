-- lib/sandbox/sandbox_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.sandbox")

T.describe("sandbox.env", function()
	T.it("merges globals from multiple caps", function()
		local a = { globals = { x = 1 }, modules = {} }
		local b = { globals = { y = 2 }, modules = {} }
		local env = S.env(a, b)
		T.eq(env.x, 1)
		T.eq(env.y, 2)
	end)

	T.it("later cap overrides earlier on collision", function()
		local a = { globals = { x = 1 }, modules = {} }
		local b = { globals = { x = 99 }, modules = {} }
		local env = S.env(a, b)
		T.eq(env.x, 99)
	end)

	T.it("has a require function", function()
		local env = S.env(S.stdlib)
		T.eq(type(env.require), "function")
	end)

	T.it("require allows listed modules", function()
		local cap = { globals = {}, modules = { "lib.fp.maybe" } }
		local env = S.env(cap)
		local ok, result = pcall(env.require, "lib.fp.maybe")
		T.ok(ok)
		T.ok(result)
	end)

	T.it("require blocks unlisted modules", function()
		local env = S.env(S.stdlib)  -- no modules listed
		local ok, err = pcall(env.require, "lib.json")
		T.fail(ok)
		T.ok(err:find("not allowed"))
	end)

	T.it("require union covers all listed modules", function()
		local a = { globals = {}, modules = { "lib.fp.maybe" } }
		local b = { globals = {}, modules = { "lib.fp.either" } }
		local env = S.env(a, b)
		local ok1 = pcall(env.require, "lib.fp.maybe")
		local ok2 = pcall(env.require, "lib.fp.either")
		T.ok(ok1)
		T.ok(ok2)
	end)
end)

T.describe("sandbox.run", function()
	T.it("executes code in env", function()
		local env = S.env(S.stdlib)
		local ok, result = S.run("return 1 + 1", env)
		T.ok(ok)
		T.eq(result, 2)
	end)

	T.it("code can access env globals", function()
		local cap = { globals = { answer = 42 }, modules = {} }
		local env = S.env(cap)
		local ok, result = S.run("return answer", env)
		T.ok(ok)
		T.eq(result, 42)
	end)

	T.it("code cannot access globals not in env", function()
		local env = S.env(S.pure)  -- no io, os, ffi, etc.
		local ok, result = S.run("return io", env)
		T.ok(ok)
		T.eq(result, nil)  -- io is simply nil in this env
	end)

	T.it("code cannot reach ffi via require", function()
		local env = S.env(S.stdlib)  -- no ffi module listed
		local ok, err = S.run('require("ffi")', env)
		T.fail(ok)
		T.ok(err:find("not allowed"))
	end)

	T.it("code cannot reach os via require", function()
		local env = S.env(S.stdlib)
		local ok, err = S.run('require("os")', env)
		T.fail(ok)
		T.ok(err:find("not allowed"))
	end)

	T.it("syntax errors returned as (false, err)", function()
		local env = S.env(S.pure)
		local ok, err = S.run("this is not valid lua )(", env)
		T.fail(ok)
		T.ok(type(err) == "string")
	end)

	T.it("runtime errors returned as (false, err)", function()
		local env = S.env(S.stdlib)
		local ok, err = S.run('error("boom")', env)
		T.fail(ok)
		T.ok(err:find("boom"))
	end)

	T.it("global assignment writes to env, not host globals", function()
		local env = S.env(S.stdlib)
		S.run("x_sentinel = 999", env)
		T.eq(env.x_sentinel, 999)
		T.eq(rawget(_G, "x_sentinel"), nil)  -- host globals unchanged
	end)

	T.it("budget exceeded returns error", function()
		local env = S.env(S.pure)
		-- tight loop, will hit budget quickly
		local ok, err = S.run("local i = 0; while true do i = i + 1 end", env, { budget = 100 })
		T.fail(ok)
		T.ok(err:find("budget exceeded"))
	end)

	T.it("budget does not fire when code is fast enough", function()
		local env = S.env(S.pure)
		local ok, result = S.run("return 1 + 1", env, { budget = 10000 })
		T.ok(ok)
		T.eq(result, 2)
	end)

	T.it("nested budgeted run does not clobber the outer budget hook", function()
		-- Regression test: sandbox.run installs its instruction-budget hook
		-- via debug.sethook with no save/restore of whatever hook was
		-- already active on the thread. A nested budgeted sandbox.run used
		-- to unconditionally clear the hook on exit (both the normal
		-- cleanup and the budget-exceeded error path), silently disabling
		-- the outer call's budget enforcement for the remainder of its run.
		--
		-- lib.sandbox is not on any require whitelist, so the inner run()
		-- is exercised via a directly-injected global rather than through
		-- a sandboxed require.
		--
		-- Budgets (20 inner / 60 outer) are deliberately tiny — both stay
		-- under LuaJIT's ~56-back-edge hot-loop threshold. The instruction-
		-- budget count-hook does not reliably fire once a tight loop gets
		-- traced (see TODO.md), which is a separate, pre-existing gap; a
		-- realistic budget (e.g. 5000) here would let the outer loop get
		-- trace-compiled before its hook fires and hang the test on that
		-- gap instead of exercising the save/restore fix under test.
		local inner_env = S.env(S.pure)
		local function run_inner()
			return S.run("local i = 0; while true do i = i + 1 end", inner_env, { budget = 20 })
		end
		local inner_ok, inner_err

		local cap = { globals = { run_inner = function()
			inner_ok, inner_err = run_inner()
		end }, modules = {} }
		local outer_env = S.env(S.pure, cap)

		-- Outer code runs the inner budgeted sandbox first (which exhausts
		-- its own small budget and returns an error internally, without
		-- propagating), then keeps looping. If the outer hook survived,
		-- the outer budget below still fires; if the bug regresses, this
		-- loop runs forever instead.
		local ok, err = S.run([[
			run_inner()
			local i = 0
			while true do i = i + 1 end
		]], outer_env, { budget = 60 })

		-- The inner sandboxed run hit its own (much smaller) budget first.
		T.fail(inner_ok)
		T.ok(inner_err:find("budget exceeded"))

		-- The outer sandbox's budget enforcement must still be intact.
		T.fail(ok)
		T.ok(err:find("budget exceeded"))
	end)

	T.it("caps compose for run", function()
		local data_cap = { globals = { data = {1, 2, 3} }, modules = {} }
		local env = S.env(S.pure, data_cap)
		local ok, result = S.run("return #data", env)
		T.ok(ok)
		T.eq(result, 3)
	end)
end)

T.describe("sandbox.lock_string_metatable", function()
	T.it("makes getmetatable('') return false", function()
		S.lock_string_metatable()
		T.eq(getmetatable(""), false)
	end)

	T.it("string methods still work after locking", function()
		S.lock_string_metatable()
		T.eq(("hello"):upper(), "HELLO")
		T.eq(("world"):sub(1, 3), "wor")
		T.eq(("abc"):rep(2), "abcabc")
	end)
end)

T.describe("sandbox.stdlib bundle", function()
	T.it("has math", function()
		T.eq(S.stdlib.globals.math, math)
	end)

	T.it("has table", function()
		T.eq(S.stdlib.globals.table, table)
	end)

	T.it("does not have io", function()
		T.eq(S.stdlib.globals.io, nil)
	end)

	T.it("does not have os (timing attack surface; apps use caps.time)", function()
		T.eq(S.stdlib.globals.os, nil)
	end)

	T.it("has safe jit subset (no on/off/flush)", function()
		if not S.stdlib.globals.jit then return end  -- skip on PUC-Rio
		T.eq(S.stdlib.globals.jit.os, "Linux")
		T.ok(S.stdlib.globals.jit.arch ~= nil)
		T.eq(S.stdlib.globals.jit.on, nil)
		T.eq(S.stdlib.globals.jit.off, nil)
		T.eq(S.stdlib.globals.jit.flush, nil)
	end)

	T.it("has bit module", function()
		if not S.stdlib.globals.bit then return end  -- skip on PUC-Rio
		T.ok(S.stdlib.globals.bit.bor ~= nil)
	end)

	T.it("does not have ffi", function()
		T.eq(S.stdlib.globals.ffi, nil)
	end)

	T.it("does not have debug", function()
		T.eq(S.stdlib.globals.debug, nil)
	end)

	T.it("require blocks jit (real module has on/off/flush/attach — process-wide)", function()
		local env = S.env(S.stdlib)
		local ok = pcall(env.require, "jit")
		T.eq(ok, false)
	end)

	T.it("require allows bit (pure numeric functions, no shared state)", function()
		local env = S.env(S.stdlib)
		local ok, bit_mod = pcall(env.require, "bit")
		T.ok(ok)
		T.eq(bit_mod.bor(1, 2), 3)
	end)
end)
