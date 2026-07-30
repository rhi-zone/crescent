-- lib/type/v10_kernel/pilot/fixpoint_prover_test.lua
--
-- Tests for fixpoint_prover.lua (pilot step 4, Phase 3): the PROVER's
-- ANALYSIS + EMISSION over real Lua source strings, run through the full
-- pipeline (parse -> prover_narrow pass 1 -> this module's own pass 2 ->
-- replay) -- not hand-built certificates (those are fixpoint_v1_test.lua's
-- job, Phase 2, untouched).
--
-- The milestone's acceptance gate: a synthetic loop over a `--:`-annotated
-- tracked local, fully in scope, ROOT-REPLAYS via `M.replay` end-to-end
-- from real source text. Chosen shape: a `noop()` call (rule c, preserving)
-- followed by a LITERAL reassignment `x = nil` (`assign-literal-transfer`)
-- -- NOT a self-copy, per fixpoint_prover.lua's own documented scope
-- reduction (its header's "Known scope reduction" section): this module
-- does not attempt `assign-copy-transfer` at all (neither self- nor
-- cross-variable copy), so every negative test below involving a bare-
-- identifier RHS is expected to skip regardless of whether its source is
-- independently tracked.

local T = require("lib.test.assert")
local fp = require("lib.type.v10_kernel.pilot.fixpoint_prover")

-- TYPECHECKER WORKAROUND: `result.stats.loop_skipped[reason]` is read
-- inline at each call site below rather than through a small local helper
-- function, and no such helper is given a `--:` signature anywhere in
-- this file. Confirmed via a minimal repro: a `--:` ANNOTATED local
-- function in a file that merely REQUIRES fixpoint_prover.lua (even one
-- whose signature references NONE of fixpoint_prover.lua's own types,
-- e.g. `(unknown, string) -> integer`) causes the checker to re-validate
-- fixpoint_prover.lua's dependencies in a context where their `--::`
-- declarations (`Term`, `AxiomDecl`, `Replayer`, ...) are not visible,
-- reporting spurious "undefined type" errors AGAINST fixpoint_prover.lua
-- -- which checks clean standalone. The natural code would be a small
-- annotated `skip_count(result, reason)` helper (as this file originally
-- had). See TODO.md.

T.describe("fixpoint_prover", function()
	T.it("ROOT-REPLAYS a loop-invariant certificate for a real while-loop (literal reassignment)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		noop()
		x = nil
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loops_found, 1)
		T.eq(result.stats.loop_vars_attempted, 1)
		T.eq(result.stats.loop_vars_certified, 1)
		T.eq(#result.judgments, 1)
	end)

	T.it("skips: call-expression RHS reassignment (out of scope)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		x = foo()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["assignment RHS out of scope (not literal or bare-identifier copy)"] or 0) >= 1)
	end)

	T.it("skips: a nested `if` inside the loop body breaks persistence chaining", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		if true then
			x = nil
		end
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["control-flow statement breaks persistence chaining (out of scope)"] or 0) >= 1)
	end)

	T.it("skips: copy from another (untracked) variable is not independently established", function()
		local source = [[
local function outer()
	local x --: number | nil
	local y = 5
	while x do
		x = y
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["copy source not independently established at the assign point"] or 0) >= 1)
	end)

	T.it("skips: no tracked variable in scope at the loop", function()
		local source = [[
local function outer()
	local z = 5
	while z do
		z = z + 1
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loops_found, 1)
		T.eq(result.stats.loop_vars_attempted, 0)
		T.eq((result.stats.loop_skipped["no tracked variable in scope at this loop"] or 0), 1)
	end)

	T.it("skips: RHS is neither a literal nor a bare-identifier copy (binary expression)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		x = 1 + 2
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["assignment RHS out of scope (not literal or bare-identifier copy)"] or 0) >= 1)
	end)

	T.it("skips: self-copy `x = x` (documented scope reduction -- assign-copy-transfer not attempted)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		noop()
		x = x
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["copy source not independently established at the assign point"] or 0) >= 1)
	end)

	T.it("skips: multi-target assignment to the invariant variable", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		x, y = nil, 1
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["multi-target/multi-value assignment to the invariant variable (out of scope)"] or 0) >= 1)
	end)

	T.it("skips: empty loop body", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["empty loop body: no persistence chain from loop head to back edge under this theory"] or 0) >= 1)
	end)

	T.it("no while loops at all: zero loops found, zero judgments", function()
		local source = [[
local function outer()
	local x --: number | nil
	return x
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loops_found, 0)
		T.eq(#result.judgments, 0)
	end)
end)

return {}
