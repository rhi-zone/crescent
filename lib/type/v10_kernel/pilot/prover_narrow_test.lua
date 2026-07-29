-- lib/type/v10_kernel/pilot/prover_narrow_test.lua
--
-- Pass-1 narrowing analysis tests: synthetic fixtures for each guard form,
-- a nested/chained guard, a skipped-construct case, and a smoke check
-- against a real crescent lib/ file.

local T = require("lib.test.assert")
local parse_mod = require("lib.type.static.parse")
local prover_narrow = require("lib.type.v10_kernel.pilot.prover_narrow")

local function analyze_src(src)
	local parser = parse_mod.parse(src, "<test>")
	local stats = prover_narrow.new_stats()
	local root, err = prover_narrow.analyze(parser, stats)
	return root, stats, err
end

local function find_guard(events)
	for _, ev in ipairs(events) do
		if ev.kind == "guard" then return ev end
	end
	return nil
end

T.describe("prover_narrow", function()
	T.it("type(x) == \"string\" guard: handled, then-branch match / else-branch rest", function()
		local root, stats = analyze_src([[
local x --: string | nil
if type(x) == "string" then
  local y = 1
else
  local z = 2
end
]])
		T.eq(stats.guards_found, 1)
		T.eq(stats.guards_handled, 1)
		local ge = find_guard(root.events)
		T.ok(ge)
		T.eq(ge.target, "string")
		T.eq(ge.then_is_match, true)
		T.ok(ge.else_events)
	end)

	T.it("x == nil guard: then-branch is match (nil)", function()
		local root, stats = analyze_src([[
local x --: string | nil
if x == nil then
  local y = 1
end
]])
		T.eq(stats.guards_handled, 1)
		local ge = find_guard(root.events)
		T.eq(ge.target, "nil")
		T.eq(ge.then_is_match, true)
		T.eq(ge.else_path, nil)
	end)

	T.it("x ~= nil guard: then-branch is rest (non-nil)", function()
		local root, stats = analyze_src([[
local x --: string | nil
if x ~= nil then
  local y = 1
end
]])
		T.eq(stats.guards_handled, 1)
		local ge = find_guard(root.events)
		T.eq(ge.target, "nil")
		T.eq(ge.then_is_match, false)
	end)

	T.it("bare truthiness `if x then`: then-branch is rest (truthy)", function()
		local root, stats = analyze_src([[
local x --: string | nil
if x then
  local y = 1
end
]])
		T.eq(stats.guards_handled, 1)
		local ge = find_guard(root.events)
		T.eq(ge.target, "falsy")
		T.eq(ge.then_is_match, false)
	end)

	T.it("`if not x then`: then-branch is match (falsy)", function()
		local root, stats = analyze_src([[
local x --: string | nil
if not x then
  return nil
end
]])
		T.eq(stats.guards_handled, 1)
		local ge = find_guard(root.events)
		T.eq(ge.target, "falsy")
		T.eq(ge.then_is_match, true)
		T.eq(ge.else_path, nil)
	end)

	T.it("while loop guard: body is the rest (truthy) branch, no else", function()
		local root, stats = analyze_src([[
local x --: string | nil
while x do
  x = nil
end
]])
		T.eq(stats.guards_handled, 1)
		local ge = find_guard(root.events)
		T.eq(ge.target, "falsy")
		T.eq(ge.then_is_match, false)
	end)

	T.it("nested/chained guard: truthiness outer, type() inner on the remainder", function()
		local root, stats = analyze_src([[
local x --: string | table | nil
if not x then
  return nil
else
  if type(x) == "string" then
    local y = 1
  end
end
]])
		T.eq(stats.guards_handled, 2)
		local outer = find_guard(root.events)
		T.ok(outer)
		T.eq(outer.target, "falsy")
		T.eq(outer.then_is_match, true)
		T.ok(outer.else_events)
		local inner = find_guard(outer.else_events)
		T.ok(inner)
		T.eq(inner.target, "string")
	end)

	T.it("elseif chain: each clause narrows its own body, rest chains to the next clause's test, "
		.. "final rest chains to the trailing else", function()
		local root, stats = analyze_src([[
local x --: string | number | boolean
if type(x) == "string" then
  local y = 1
elseif type(x) == "number" then
  local z = 2
else
  local w = 3
end
]])
		-- Only the two actual clause tests are "guards" in the stats sense --
		-- the trailing `else` has no test of its own to find/handle (see
		-- header, "Elseif chains").
		T.eq(stats.guards_found, 2)
		T.eq(stats.guards_handled, 2)

		local outer = find_guard(root.events)
		T.ok(outer)
		T.eq(outer.target, "string")
		T.eq(outer.then_is_match, true)
		T.ok(outer.else_events)
		T.eq(#outer.else_events, 1)

		-- Clause 1's own GuardEvent is the SOLE element of clause 0's "rest"
		-- events list -- this is what makes pass 2's chaining detection
		-- (`peek_next_target`, first-element-only) recognize it, exactly
		-- like a hand-nested if/else would.
		local inner = outer.else_events[1]
		T.eq(inner.kind, "guard")
		T.eq(inner.target, "number")
		T.eq(inner.then_is_match, true)
		T.ok(inner.else_events)
		-- Clause 1's "rest" chains to the trailing else block's OWN flat
		-- events (unwrapped -- pass 2's rule-citation fork isolates it,
		-- matching the single-clause if/else convention exactly).
		T.eq(#inner.else_events, 0) -- `local w = 3` has no `--:` annotation, so no event
	end)

	T.it("elseif chain: an ineligible middle clause falls back to nested_scope for its own body "
		.. "but does not break the surrounding clauses' own eligibility", function()
		local root, stats = analyze_src([[
local x --: string | number | table
if type(x) == "string" then
  local y = 1
elseif x.foo == 1 then
  local z = 2
elseif type(x) == "table" then
  local w = 3
end
]])
		T.eq(stats.guards_found, 2) -- `x.foo == 1` is not a recognized guard shape at all
		T.eq(stats.guards_handled, 2)
		local outer = find_guard(root.events)
		T.ok(outer)
		T.eq(outer.target, "string")
		T.ok(outer.else_events)
		-- The ineligible clause's own nested_scope wrapper occupies the
		-- FIRST slot (so pass 2 correctly does NOT treat clause 2 as
		-- chained through it -- see header, "Chaining"), with clause 2's
		-- own GuardEvent as a second, later sibling.
		T.eq(outer.else_events[1].kind, "nested_scope")
		local found_inner = false
		for _, e in ipairs(outer.else_events) do
			if e.kind == "guard" and e.target == "table" then found_inner = true end
		end
		T.ok(found_inner, "expected clause 2's own guard event to still be present")
	end)

	T.it("skipped construct: guard over a plain 'boolean' union is counted, not silently dropped", function()
		local root, stats = analyze_src([[
local ok --: boolean | nil
if ok then
  local y = 1
end
]])
		T.eq(stats.guards_found, 1)
		T.eq(stats.guards_handled, 0)
		local total_skipped = 0
		for _, n in pairs(stats.guards_skipped) do total_skipped = total_skipped + n end
		T.eq(total_skipped, 1)
		T.eq(find_guard(root.events), nil)
	end)

	T.it("skipped construct: unsupported annotation member is counted", function()
		local _, stats = analyze_src([[
local x --: integer | nil
]])
		local total = 0
		for _, n in pairs(stats.annotations_skipped) do total = total + n end
		T.eq(total, 1)
		T.eq(stats.annotations_parsed, 0)
	end)

	T.it("multi-name local declarations are skipped with a reason, not silently accepted", function()
		local _, stats = analyze_src([[
local a, b --: string | nil
]])
		local total = 0
		for _, n in pairs(stats.annotations_skipped) do total = total + n end
		T.eq(total, 1)
	end)

	T.it("real file smoke test: lib/roman_numeral/init.lua yields a handled guard", function()
		local f = io.open("lib/roman_numeral/init.lua", "r")
		T.ok(f)
		if not f then return end
		local src = f:read("*a")
		f:close()
		T.ok(src)
		if not src then return end
		local root, stats = analyze_src(src)
		T.ok(stats.guards_handled >= 1, "expected at least one handled guard in lib/roman_numeral/init.lua")
		T.ok(root)
	end)

	T.it("real file: lib/roman_numeral/init.lua no longer records any "
		.. "'elseif chain not supported' skip (elseif chains are now analyzed, not blanket-skipped)", function()
		local f = io.open("lib/roman_numeral/init.lua", "r")
		T.ok(f)
		if not f then return end
		local src = f:read("*a")
		f:close()
		T.ok(src)
		if not src then return end
		local _, stats = analyze_src(src)
		-- The file's 5 elseif chains (verified by direct inspection) never
		-- use one of the three recognized guard shapes on their clause
		-- tests (they compare plain values -- `mod10 == 1`, `style ==
		-- "additive"` -- not `type(x)`/nil-check/truthiness on a tracked
		-- annotated union local), so this drop is NOT accompanied by a
		-- guards_found/guards_handled increase for THIS file -- the skip
		-- reason simply no longer applies because the blanket
		-- clauses_len~=1 bump is gone, not because these particular
		-- clauses newly qualify.
		T.eq(stats.guards_skipped["elseif chain not supported (no single addressable rest-branch point)"], nil)
		T.eq(stats.guards_found, 11)
		T.eq(stats.guards_handled, 2)
	end)
end)

return {}
