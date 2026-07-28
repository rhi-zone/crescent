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
end)

return {}
