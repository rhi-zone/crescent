-- lib/type/v10_kernel/pilot/prover_test.lua
--
-- End-to-end tests for the pilot certificate-emitting prover
-- (prover_narrow.lua pass 1 + prover.lua pass 2): source text in, replayed
-- judgments + honest stats out. One fixture per in-scope guard form, a
-- nested/chained guard, a skipped-construct case (counted, not dropped),
-- and a real lib/ file run end-to-end.

local T = require("lib.test.assert")
local prover = require("lib.type.v10_kernel.pilot.prover")

T.describe("prover.analyze_file", function()
	T.it("type(x) == \"string\" guard: both branches replay to green judgments", function()
		local result, err = prover.analyze_file([[
local x --: string | nil
if type(x) == "string" then
  local y = 1
else
  local z = 2
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_handled, 1)
		T.eq(result.stats.certificates_emitted, 2) -- match + rest
		T.eq(result.stats.replay_pass, 2)
		T.eq(result.stats.replay_fail, 0)
		T.eq(#result.judgments, 2)
	end)

	T.it("x == nil guard: then-branch (no else) replays to one green judgment", function()
		local result, err = prover.analyze_file([[
local x --: string | nil
if x == nil then
  local y = 1
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.certificates_emitted, 1)
		T.eq(result.stats.replay_pass, 1)
		T.eq(result.stats.replay_fail, 0)
	end)

	T.it("x ~= nil guard: then-branch replays to one green judgment", function()
		local result, err = prover.analyze_file([[
local x --: string | nil
if x ~= nil then
  local y = 1
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.certificates_emitted, 1)
		T.eq(result.stats.replay_pass, 1)
	end)

	T.it("bare truthiness `if x then`: replays to one green judgment", function()
		local result, err = prover.analyze_file([[
local x --: string | nil
if x then
  local y = 1
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.certificates_emitted, 1)
		T.eq(result.stats.replay_pass, 1)
	end)

	T.it("`if not x then`: replays to one green judgment", function()
		local result, err = prover.analyze_file([[
local x --: string | nil
if not x then
  return nil
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.certificates_emitted, 1)
		T.eq(result.stats.replay_pass, 1)
	end)

	T.it("while loop guard: body replays to one green judgment", function()
		local result, err = prover.analyze_file([[
local x --: string | nil
while x do
  x = nil
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.certificates_emitted, 1)
		T.eq(result.stats.replay_pass, 1)
	end)

	T.it("nested/chained guard: truthiness outer, type() inner -- two chained green judgments", function()
		local result, err = prover.analyze_file([[
local x --: string | table | nil
if not x then
  return nil
else
  if type(x) == "string" then
    local y = 1
  end
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_handled, 2)
		-- outer (if/else): match(falsy)+rest(truthy) = 2;
		-- inner (if, no else): match(string) only = 1 (no else branch to
		-- address a "rest" certificate against).
		T.eq(result.stats.certificates_emitted, 3)
		T.eq(result.stats.replay_pass, 3)
		T.eq(result.stats.replay_fail, 0)
	end)

	T.it("elseif chain: three clauses replay to four green judgments (match+rest per clause)", function()
		local result, err = prover.analyze_file([[
local x --: string | number | boolean
if type(x) == "string" then
  local y = 1
elseif type(x) == "number" then
  local z = 2
else
  local w = 3
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_handled, 2)
		-- clause 0: match(string) + rest -> chains into clause 1's own test;
		-- clause 1: match(number) + rest -> chains into the trailing else.
		T.eq(result.stats.certificates_emitted, 4)
		T.eq(result.stats.replay_pass, 4)
		T.eq(result.stats.replay_fail, 0)
		T.eq(#result.judgments, 4)
	end)

	T.it("elseif chain: an ineligible middle clause is conservatively skipped by pass 2 "
		.. "(not chained through), not silently mishandled", function()
		local result, err = prover.analyze_file([[
local x --: string | number | table
if type(x) == "string" then
  local y = 1
elseif x.foo == 1 then
  local z = 2
elseif type(x) == "table" then
  local w = 3
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_handled, 2)
		-- clause 0: match+rest (2, both green). clause 2 (last, no else): a
		-- lone match citation, whose union ordering wasn't positioned by
		-- the (ineligible, hence non-chaining) clause 1 -- replay correctly
		-- REJECTS it (structural TA mismatch), recorded via
		-- emission_skipped, not silently dropped or accepted unsoundly.
		T.eq(result.stats.certificates_emitted, 3)
		T.eq(result.stats.replay_pass, 2)
		T.eq(result.stats.replay_fail, 1)
		local total_emission_skipped = 0
		for _, n in pairs(result.stats.emission_skipped) do total_emission_skipped = total_emission_skipped + n end
		T.eq(total_emission_skipped, 1)
	end)

	T.it("skipped construct: truthiness guard over a plain 'boolean' union is counted, not silently dropped", function()
		local result, err = prover.analyze_file([[
local ok --: boolean | nil
if ok then
  local y = 1
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_found, 1)
		T.eq(result.stats.guards_handled, 0)
		local total_skipped = 0
		for _, n in pairs(result.stats.guards_skipped) do total_skipped = total_skipped + n end
		T.eq(total_skipped, 1)
		T.eq(result.stats.certificates_emitted, 0)
	end)

	T.it("skipped construct: unsupported annotation member is counted, not silently dropped", function()
		local result, err = prover.analyze_file([[
local x --: integer | nil
]], "<test>")
		T.ok(result, err)
		local total = 0
		for _, n in pairs(result.stats.annotations_skipped) do total = total + n end
		T.eq(total, 1)
	end)

	T.it("parameter fact: type(x) == \"string\" guard on a function's own parameter replays green", function()
		local result, err = prover.analyze_file([[
--: (string | nil) -> nil
local function f(x)
  if type(x) == "string" then
    local y = 1
  else
    local z = 2
  end
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_handled, 1)
		T.eq(result.stats.certificates_emitted, 2)
		T.eq(result.stats.replay_pass, 2)
		T.eq(result.stats.replay_fail, 0)
	end)

	T.it("parameter fact: nil-check guard on the SECOND (non-zero-index) parameter replays green -- "
		.. "regression test for the addressing fix (a hardcoded index-0 identity path would either "
		.. "misaddress this parameter or fail replay outright)", function()
		local result, err = prover.analyze_file([[
--: (integer, string | nil) -> nil
local function g(n, s)
  if s == nil then
    local y = 1
  end
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_handled, 1)
		T.eq(result.stats.certificates_emitted, 1)
		T.eq(result.stats.replay_pass, 1)
		T.eq(result.stats.replay_fail, 0)
	end)

	T.it("nested-function shadowing: outer and inner parameters of the same name replay independently, "
		.. "each against its own innermost fact", function()
		local result, err = prover.analyze_file([[
--: (string | nil) -> nil
local function outer(x)
  --: (number | boolean) -> nil
  local function inner(x)
    if type(x) == "number" then
      local y = 1
    end
  end
  if x == nil then
    local z = 2
  end
end
]], "<test>")
		T.ok(result, err)
		T.eq(result.stats.guards_handled, 2)
		T.eq(result.stats.certificates_emitted, 2) -- outer: match(nil) only (no else); inner: match(number) only (no else)
		T.eq(result.stats.replay_pass, 2)
		T.eq(result.stats.replay_fail, 0)
	end)

	T.it("real file end-to-end: lib/roman_numeral/init.lua yields nonzero judgments, all replay green", function()
		local f = io.open("lib/roman_numeral/init.lua", "r")
		T.ok(f)
		if not f then return end
		local src = f:read("*a")
		f:close()
		T.ok(src)
		if not src then return end
		local result, err = prover.analyze_file(src, "lib/roman_numeral/init.lua", { clock_fn = os.clock })
		T.ok(result, err)
		if not result then return end
		T.ok(#result.judgments > 0, "expected at least one emitted judgment")
		T.eq(result.stats.replay_fail, 0)
		T.ok(result.stats.replay_pass > 0)
		T.ok(result.stats.timing.analyze_ms >= 0)
		T.ok(result.stats.timing.emit_ms >= 0)
	end)
end)

return {}
