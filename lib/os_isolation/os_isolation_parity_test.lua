-- lib/os_isolation/os_isolation_parity_test.lua
-- Parity across the three independent isolation implementations
-- (fork_direct, fork_supervisor, thread) for the shared spec each one
-- implements: "run this unit of work in isolation, hand back its (ok,
-- result) pcall-shaped outcome." Per this repo's CLAUDE.md convention
-- ("Multiple implementations of the same spec require parity tests...
-- not optional polish"), this file is not about testing each
-- implementation's own extra surface (fork_direct's COW closures,
-- fork_supervisor's concurrent-children lifecycle, thread's tid
-- reporting) -- those are covered in each implementation's own *_test.lua.
-- This file only exercises the shape all three share: success, error, and
-- JSON-representable-args-in / result-out, asserting byte-identical
-- observable outcomes across implementations for the same logical program.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local fork_direct = require("lib.os_isolation.fork_direct")
local fork_supervisor = require("lib.os_isolation.fork_supervisor")
local thread = require("lib.os_isolation.thread")

-- Each implementation's spawn() takes a different shape of "the work"
-- (fork_direct: a Lua function/closure; fork_supervisor/thread: Lua source
-- text plus JSON args) -- that difference is real and documented per
-- implementation, not something parity should paper over. This table
-- expresses the SAME three logical programs against each implementation's
-- own native calling convention, and asserts the three converge on the
-- same (ok, result) pair.
local CASES = {
	{
		name = "success: arithmetic on injected input",
		fork_direct_fn = function() return 20 + 22 end,
		code = "return 20 + 22",
		args = nil,
		expect_ok = true,
		expect_result = 42,
	},
	{
		name = "success: table arg round-trips through JSON",
		fork_direct_fn = function() return ({ x = 2, y = 3 }).x + ({ x = 2, y = 3 }).y end,
		code = "local t = ...; return t.x + t.y",
		args = { x = 2, y = 3 },
		expect_ok = true,
		expect_result = 5,
	},
	{
		name = "error: runtime error propagates as (false, message containing the error text)",
		fork_direct_fn = function() error("shared boom") end,
		code = "error('shared boom')",
		args = nil,
		expect_ok = false,
		expect_result = "shared boom", -- substring match, not equality
	},
}

T.describe("os_isolation parity: fork_direct vs fork_supervisor vs thread", function()
	for _, case in ipairs(CASES) do
		T.it(case.name, function()
			local d_handle = fork_direct.spawn(case.fork_direct_fn, {})
			local d_ok, d_result = d_handle.join()

			local sup = fork_supervisor.start()
			local s_handle = sup:spawn(case.code, case.args)
			local s_ok, s_result = s_handle.join()
			sup:stop()

			local t_handle = thread.spawn(case.code, case.args)
			local t_ok, t_result = t_handle.join()

			T.eq(d_ok, case.expect_ok, "fork_direct ok")
			T.eq(s_ok, case.expect_ok, "fork_supervisor ok")
			T.eq(t_ok, case.expect_ok, "thread ok")

			if case.expect_ok then
				T.eq(d_result, case.expect_result, "fork_direct result")
				T.eq(s_result, case.expect_result, "fork_supervisor result")
				T.eq(t_result, case.expect_result, "thread result")
			else
				T.ok(tostring(d_result):find(case.expect_result, 1, true), "fork_direct error text")
				T.ok(tostring(s_result):find(case.expect_result, 1, true), "fork_supervisor error text")
				T.ok(tostring(t_result):find(case.expect_result, 1, true), "thread error text")
			end
		end)
	end
end)

T.describe("os_isolation parity: each implementation actually isolates (not merely returns correct values)", function()
	T.it("fork_direct's child does not leak writes back into the caller's globals", function()
		_G.parity_sentinel = "before" --[[: string | nil]]
		local h = fork_direct.spawn(function()
			_G.parity_sentinel = "mutated"
			return true
		end, {})
		h.join()
		T.eq(_G.parity_sentinel, "before")
		_G.parity_sentinel = nil
	end)

	T.it("fork_supervisor's child runs in a separate process (distinct pid from the supervisor)", function()
		local sup = fork_supervisor.start()
		local h = sup:spawn("return 1")
		T.ok(h.pid ~= sup.pid)
		h.join()
		sup:stop()
	end)

	T.it("thread's child does not leak global writes back into the caller (separate lua_State)", function()
		_G.parity_sentinel = "before" --[[: string | nil]]
		local h = thread.spawn([[parity_sentinel = "mutated"; return true]])
		h.join()
		T.eq(_G.parity_sentinel, "before")
		_G.parity_sentinel = nil
	end)
end)
