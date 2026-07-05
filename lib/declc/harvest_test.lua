-- lib/declc/harvest_test.lua
-- Tests for the three claim harvesters: stated (annotations), axiom (fixed
-- catalog), mined (the two H5-catalogued presupposing forms).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local harvest = require("lib.declc.harvest")
local claim = require("lib.declc.claim")

--: ({ [integer]: Claim, ... }, string, string) -> Claim | nil
local function find_slot(claims, site_suffix, slot)
	for _, c in ipairs(claims) do
		local site = claim.site(c)
		if site:sub(-#site_suffix) == site_suffix and claim.slot(c) == slot then
			return c
		end
	end
	return nil
end

T.describe("harvest_stated: (S-param)/(S-return) from --: annotations", function()
	T.it("emits one claim per param slot and one per return slot", function()
		local src = table.concat({
			"--: (string, integer) -> (boolean, string | nil)",
			"local function foo(a, b)",
			"	return true, nil",
			"end",
		}, "\n")
		local claims, err = harvest.harvest_stated(src, "fix.lua")
		T.eq(err, nil)
		T.ok(claims ~= nil)
		local n = claims ~= nil and #claims or 0
		T.eq(n, 4) -- entry:a, entry:b, exit:1, exit:2

		local ca = find_slot(claims, ":2:foo", "entry:a")
		T.ok(ca ~= nil, "expected entry:a claim")
		if ca ~= nil then
			T.eq(claim.schema(ca), "string")
			T.eq(claim.stratum(ca), claim.STRATUM.PI1)
			T.eq(claim.modal(ca), claim.MODAL.BOX)
			T.eq(claim.provenance(ca), claim.PROVENANCE.STATED)
		end

		local cb = find_slot(claims, ":2:foo", "entry:b")
		T.ok(cb ~= nil, "expected entry:b claim")
		if cb ~= nil then T.eq(claim.schema(cb), "integer") end

		local cr1 = find_slot(claims, ":2:foo", "exit:1")
		T.ok(cr1 ~= nil, "expected exit:1 claim")
		if cr1 ~= nil then T.eq(claim.schema(cr1), "boolean") end

		local cr2 = find_slot(claims, ":2:foo", "exit:2")
		T.ok(cr2 ~= nil, "expected exit:2 claim")
		if cr2 ~= nil then T.eq(claim.schema(cr2), "string | nil") end
	end)

	T.it("skips definitions with no preceding annotation", function()
		local src = "local function bar(x)\n\treturn x\nend\n"
		local claims, err = harvest.harvest_stated(src, "fix.lua")
		T.eq(err, nil)
		T.ok(claims ~= nil)
		T.eq(claims ~= nil and #claims or -1, 0)
	end)

	T.it("finds `name = function(...) end` assignment-style definitions", function()
		local src = table.concat({
			"local M = {}",
			"--: (integer) -> integer",
			"M.double = function(n)",
			"	return n * 2",
			"end",
			"return M",
		}, "\n")
		local claims, err = harvest.harvest_stated(src, "fix.lua")
		T.eq(err, nil)
		T.ok(claims ~= nil)
		local cn = find_slot(claims, ":3:M.double", "entry:n")
		T.ok(cn ~= nil, "expected entry:n claim on M.double")
		if cn ~= nil then T.eq(claim.schema(cn), "integer") end
	end)
end)

T.describe("harvest_axiom: fixed universal catalog", function()
	T.it("returns exactly the five catalogued axioms, provenance=axiom, site=*", function()
		local claims, err = harvest.harvest_axiom()
		T.eq(err, nil)
		T.eq(#claims, 5)
		local seen = {}
		for _, c in ipairs(claims) do
			T.eq(claim.site(c), "*")
			T.eq(claim.provenance(c), claim.PROVENANCE.AXIOM)
			seen[claim.slot(c)] = true
		end
		T.ok(seen["err-unintended"])
		T.ok(seen["reachable"])
		T.ok(seen["consumed"])
		T.ok(seen["paired"])
		T.ok(seen["house"])
	end)
end)

T.describe("harvest_mined: EXACTLY the two H5 forms", function()
	T.it("mines a dereference (x.f) as non-nil, provenance=mined", function()
		local src = "local function f(x)\n\treturn x.field\nend\n"
		local claims, err = harvest.harvest_mined(src, "fix.lua")
		T.eq(err, nil)
		T.ok(claims ~= nil)
		local found = false
		for _, c in ipairs(claims) do
			if claim.slot(c) == "deref:x" then
				found = true
				T.eq(claim.schema(c), "non-nil")
				T.eq(claim.stratum(c), claim.STRATUM.PI1)
				T.eq(claim.modal(c), claim.MODAL.BOX)
				T.eq(claim.provenance(c), claim.PROVENANCE.MINED)
			end
		end
		T.ok(found, "expected a deref:x claim")
	end)

	T.it("mines index access (x[k]) as non-nil too", function()
		local src = "local function f(x, k)\n\treturn x[k]\nend\n"
		local claims = harvest.harvest_mined(src, "fix.lua")
		local found = false
		for _, c in ipairs(claims) do
			if claim.slot(c) == "deref:x" then found = true end
		end
		T.ok(found, "expected a deref:x claim from index access")
	end)

	T.it("mines a method-call receiver (x:m()) as a dereference too", function()
		local src = "local function f(conn)\n\tconn:close()\nend\n"
		local claims = harvest.harvest_mined(src, "fix.lua")
		local found = false
		for _, c in ipairs(claims) do
			if claim.slot(c) == "deref:conn" then found = true end
		end
		T.ok(found, "expected a deref:conn claim from method call")
	end)

	T.it("mines both-branches-reachable for an if/else guard", function()
		local src = table.concat({
			"local function f(x)",
			"	if x then",
			"		return 1",
			"	else",
			"		return 2",
			"	end",
			"end",
		}, "\n")
		local claims = harvest.harvest_mined(src, "fix.lua")
		local saw_then, saw_else = false, false
		for _, c in ipairs(claims) do
			if claim.slot(c) == "branch:then" then
				saw_then = true
				T.eq(claim.stratum(c), claim.STRATUM.SIGMA1)
				T.eq(claim.modal(c), claim.MODAL.DIAMOND)
			end
			if claim.slot(c) == "branch:else" then saw_else = true end
		end
		T.ok(saw_then, "expected branch:then claim")
		T.ok(saw_else, "expected branch:else claim")
	end)

	T.it("mines only branch:then when no else is present", function()
		local src = "local function f(x)\n\tif x then\n\t\treturn 1\n\tend\nend\n"
		local claims = harvest.harvest_mined(src, "fix.lua")
		local saw_then, saw_else = false, false
		for _, c in ipairs(claims) do
			if claim.slot(c) == "branch:then" then saw_then = true end
			if claim.slot(c) == "branch:else" then saw_else = true end
		end
		T.ok(saw_then)
		T.fail(saw_else)
	end)
end)
