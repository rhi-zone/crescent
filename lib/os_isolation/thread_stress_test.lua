-- lib/os_isolation/thread_stress_test.lua
--
-- Empirical stress test for thread.lua's open safety question (see its
-- module header and docs/genre-battery/sandboxing.md): whether a
-- pthread-created FFI callback's FIRST-EVER invocation, happening on a
-- brand-new OS thread LuaJIT's runtime has never seen, has a GC-phase or
-- reentrancy hazard. No primary source confirms or rules this out (see
-- module header). This file cannot prove safety -- absence of a crash in N
-- runs is not a formal guarantee -- but it is a real, repeatable, adversarial
-- exercise of exactly the mechanism in question, deliberately combined with
-- GC pressure on BOTH sides of the spawn (parent and child), and it asserts
-- per-thread result correctness (not just "didn't crash") so cross-thread
-- state corruption -- e.g. one child's callback somehow reading/writing
-- another child's lua_State -- would show up as a wrong value, not require a
-- segfault to be detected.
--
-- Kept as a permanent regression check, not a throwaway script: if a future
-- LuaJIT upgrade, platform, or refactor of thread.lua introduces the hazard
-- the open question names, this is the test most likely to catch it.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local thread = require("lib.os_isolation.thread")

-- Child workload: allocate garbage on the CHILD side (forces the child's own
-- GC to run during the callback's first-ever invocation on its new OS
-- thread -- the exact window the open safety question is about), then
-- return a value derived from the input index so the caller can detect
-- cross-thread result corruption (not just crashes).
local CHILD_CODE = [[
	local idx = ...
	local garbage = {}
	local acc = 0
	for i = 1, 20000 do
		-- Force real allocation (fresh table each iteration, not reused) so
		-- the child's GC actually has work to do, not just a idle heap.
		garbage[i % 512] = { idx = idx, i = i, s = tostring(i) .. "_" .. tostring(idx) }
		acc = acc + i
		if i % 2000 == 0 then
			collectgarbage("step")
		end
	end
	return idx * 1000003 + (acc % 97)
]]

--: (integer) -> integer
local function expected_for(idx)
	local acc = 0
	for i = 1, 20000 do
		acc = acc + i
	end
	return idx * 1000003 + (acc % 97)
end

T.describe("thread.lua stress: many concurrent spawns under deliberate GC pressure", function()
	T.it("N concurrent threads, each under GC pressure, all return correct uncorrupted results", function()
		local N = 40
		local handles = {}

		-- Fire all spawns first (maximizes the window where multiple
		-- brand-new pthreads are each invoking their callback's first-ever
		-- invocation concurrently -- the precise scenario the open safety
		-- question is about, multiplied N-fold).
		for i = 1, N do
			local h, err = thread.spawn(CHILD_CODE, i)
			T.ok(h, err)
			handles[i] = h
		end

		-- Deliberate GC pressure on the PARENT side too, concurrent (from the
		-- parent thread's perspective) with all N children running: allocate
		-- heavily and force explicit full collections while children are
		-- still in flight.
		local parent_garbage = {}
		for round = 1, 200 do
			for i = 1, 200 do
				parent_garbage[i] = { round = round, i = i, big = string.rep("x", 64) }
			end
			collectgarbage("collect")
		end

		-- Join in a different order than spawned (reverse) -- avoids
		-- accidentally relying on FIFO join order to mask any cross-thread
		-- mixup.
		for i = N, 1, -1 do
			local ok, result = handles[i].join()
			T.ok(ok, "thread " .. i .. " join failed: " .. tostring(result))
			T.eq(result, expected_for(i), "thread " .. i .. " returned a corrupted/wrong result")
		end
	end)

	T.it("repeated spawn/join cycles (serial) survive sustained GC pressure without drift", function()
		-- Serial repetition, not concurrent breadth: exercises many
		-- first-ever-callback-invocations back to back, each on a fresh
		-- pthread/lua_State pair, checking nothing degrades (leaks, wrong
		-- results, hangs) over repetition.
		for i = 1, 60 do
			collectgarbage("collect")
			local h, err = thread.spawn(CHILD_CODE, i)
			T.ok(h, err)
			local ok, result = h.join()
			T.ok(ok, "cycle " .. i .. " join failed: " .. tostring(result))
			T.eq(result, expected_for(i), "cycle " .. i .. " returned a corrupted/wrong result")
		end
	end)
end)
