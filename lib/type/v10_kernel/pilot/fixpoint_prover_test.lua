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

	T.it("skips: call-expression RHS whose callee is not a same-file top-level declaration", function()
		-- `foo` is not declared anywhere in this file at all (v4:
		-- assignment transfer from an annotated-call RHS is now attempted
		-- for a call-expression RHS -- this is the "unresolvable callee"
		-- taxonomy reason, not the old generic "RHS out of scope" one).
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
		T.ok((result.stats.loop_skipped["callee is not a same-file top-level function declaration (unresolvable)"] or 0) >= 1)
	end)

	T.it("ROOT-REPLAYS: else-less if with a literal reassignment, joined against the pre-if fact", function()
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
		T.eq(result.stats.loop_vars_certified, 1)
		T.eq(#result.judgments, 1)
	end)

	T.it("ROOT-REPLAYS: if/else with a literal reassignment in one branch, persistence in the other (union join)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while true do
		if true then
			x = nil
		else
			noop()
		end
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 1)
		T.eq(#result.judgments, 1)
	end)

	T.it("ROOT-REPLAYS: guard-narrowed branches (type(x)==\"number\" on the structurally-first declared member)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while true do
		if type(x) == "number" then
			noop()
		else
			x = nil
		end
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 1)
		T.eq(#result.judgments, 1)
	end)

	T.it("skips: a NESTED `if` (two levels) inside the loop body breaks persistence chaining", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		if true then
			if true then
				x = nil
			end
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

	T.it("skips: an elseif chain (2+ clauses) is out of scope for branch-join chaining", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		if true then
			x = nil
		elseif false then
			x = nil
		end
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["elseif chain in loop body not yet supported for branch-join chaining (out of scope)"] or 0) >= 1)
	end)

	T.it("does NOT certify a false invariant: a branch reassigns a type outside the declared union", function()
		local source = [[
local function outer()
	local x --: number | nil
	while true do
		if true then
			x = "oops"
		end
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["reassigned type not a member of the declared invariant"] or 0) >= 1)
	end)

	T.it("ROOT-REPLAYS: full mutation-class loop invariant with a join inside the body, "
		.. "preceded and followed by ordinary persisting statements", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		noop()
		if type(x) == "number" then
			x = nil
		else
			noop()
		end
		noop()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 1)
		T.eq(#result.judgments, 1)
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
		T.ok((result.stats.loop_skipped[
			"assignment RHS out of scope (not literal, bare-identifier copy, or annotated same-file call)"] or 0) >= 1)
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

	-- ── v4: assignment transfer from an annotated-call RHS ─────────────────
	-- Every taxonomy reason the module header enumerates, exercised once.

	T.it("ROOT-REPLAYS a mutation-class loop-invariant certificate (call-RHS, single-tag return)", function()
		local source = [[
--: () -> number
local function get_num()
	return 1
end

local function outer()
	local x --: number | nil
	while x do
		x = get_num()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_attempted, 1)
		T.eq(result.stats.loop_vars_certified, 1)
		T.eq(#result.judgments, 1)
	end)

	T.it("ROOT-REPLAYS a mutation-class certificate (call-RHS, multi-member union return, "
		.. "exercising the ty-sub-union-of-subsets combinator)", function()
		local source = [[
--: () -> string | nil
local function get_opt()
	return nil
end

local function outer()
	local y --: string | nil | number
	while y do
		y = get_opt()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_attempted, 1)
		T.eq(result.stats.loop_vars_certified, 1)
		T.eq(#result.judgments, 1)
	end)

	T.it("skips: method-call RHS (not statically resolvable)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		x = obj:get_num()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["method call callee out of scope (not statically resolvable)"] or 0) >= 1)
	end)

	T.it("skips: computed callee (a field expression, not a bare identifier)", function()
		local source = [[
local function outer()
	local x --: number | nil
	while x do
		x = t.get_num()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["computed callee (not a bare identifier, not statically resolvable)"] or 0) >= 1)
	end)

	T.it("skips: callee identifier locally shadowed within the loop body", function()
		local source = [[
--: () -> number
local function get_num()
	return 1
end

local function outer()
	local x --: number | nil
	while x do
		local get_num = 1
		x = get_num()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped[
			"callee identifier locally shadowed within the loop body "
			.. "(not statically resolvable to a single same-file declaration)"] or 0) >= 1)
	end)

	T.it("skips: callee name has multiple same-file top-level declarations (ambiguous)", function()
		local source = [[
--: () -> number
local function dup()
	return 1
end

--: () -> string
local function dup()
	return "s"
end

local function outer()
	local x --: number | nil
	while x do
		x = dup()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped[
			"callee name has multiple same-file top-level declarations (ambiguous, not resolvable)"] or 0) >= 1)
	end)

	T.it("skips: callee has no resolvable function-type annotation (unannotated callee)", function()
		local source = [[
local function get_num()
	return 1
end

local function outer()
	local x --: number | nil
	while x do
		x = get_num()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["callee has no resolvable function-type annotation"] or 0) >= 1)
	end)

	T.it("skips: callee has an ambiguous overload (2+ preceding annotation lines)", function()
		local source = [[
--: (number) -> number
--: (string) -> string
local function over(v)
	return v
end

local function outer()
	local x --: number | nil
	while x do
		x = over(1)
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped[
			"callee has multiple preceding function-type annotations (overload) -- return type not resolvable"] or 0) >= 1)
	end)

	T.it("skips: callee annotation is not in '(T1, ...) -> R' form (bare-arrow sugar)", function()
		local source = [[
--: string -> integer
local function weird()
	return 1
end

local function outer()
	local x --: number | nil
	while x do
		x = weird()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["callee annotation is not in '(T1, ...) -> R' form"] or 0) >= 1)
	end)

	T.it("skips: callee return annotation is out of the six-tag vocabulary (a table-shape return)", function()
		local source = [[
--: () -> { x: number }
local function get_rec()
	return { x = 1 }
end

local function outer()
	local x --: number | nil
	while x do
		x = get_rec()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		local skips = result.stats.loop_skipped
		local found = false
		for reason in pairs(skips) do
			if reason:find("callee return annotation: unsupported annotation member", 1, true) then found = true end
		end
		T.ok(found, "expected an 'unsupported annotation member' callee-return-annotation skip")
	end)

	T.it("skips: callee return annotation declares multiple return values (first-value-only scope)", function()
		local source = [[
--: () -> (string, string)
local function get_pair()
	return "a", "b"
end

local function outer()
	local x --: number | nil
	while x do
		x = get_pair()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped[
			"callee return annotation declares multiple return values (first-value-only scope)"] or 0) >= 1)
	end)

	T.it("skips: callee's declared return type is not a member of the declared invariant", function()
		local source = [[
--: () -> string
local function get_str()
	return "s"
end

local function outer()
	local x --: number | nil
	while x do
		x = get_str()
	end
end
]]
		local result, err = fp.analyze_file(source, "fixture.lua")
		T.ok(result, err)
		if result == nil then return end
		T.eq(result.stats.loop_vars_certified, 0)
		T.ok((result.stats.loop_skipped["reassigned type not a member of the declared invariant"] or 0) >= 1)
	end)
end)

return {}
