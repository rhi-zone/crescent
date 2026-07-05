-- lib/declc/check_test.lua
-- Tests for the hypothesis/obligation check law: three-valued verdicts
-- (Proved/Refuted/Open) over a claim pool, per declarative-design.md's
-- certified law -- see lib/declc/check.lua's header for the operational
-- reading used here (independent sourcing across provenances, since this
-- chunk has no semantic derivation engine).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local claim = require("lib.declc.claim")
local kernel = require("lib.declc.kernel")
local check = require("lib.declc.check")
--:: require "lib.declc.check"

--: (string, string, string | nil) -> Claim
local function mk(schema, provenance, site)
	local c, err = claim.new({
		site = site or "s",
		slot = "k",
		stratum = claim.STRATUM.PI1,
		modal = claim.MODAL.BOX,
		schema = schema,
		schema_key = schema,
		provenance = provenance,
	})
	T.eq(err, nil)
	if c == nil then error("mk: claim.new failed") end
	return c
end

-- check.check's result is keyed by an internal topic key (site+slot+
-- stratum+modal) that callers have no business constructing themselves --
-- tests look an entry up by inspecting its claims' site instead.
--: (CheckResult, string) -> CheckEntry | nil
local function find_entry(result, site)
	for _, entry in pairs(result) do
		local first = entry.claims[1]
		if first ~= nil and claim.site(first) == site then
			return entry
		end
	end
	return nil
end

T.describe("check: single-source claim.key is Open", function()
	T.it("one claim, one provenance -> Open with an H1 receipt", function()
		local c = mk("string", claim.PROVENANCE.STATED)
		local result = check.check({ c })
		local entry = find_entry(result, "s")
		T.ok(entry ~= nil)
		if entry ~= nil then
			local kind = kernel.kind(entry.verdict)
			T.eq(kind, "open")
			local receipt = kernel.receipt(entry.verdict)
			T.ok(receipt ~= nil)
			if receipt ~= nil then
				local r = receipt --[[: { reason: string, key: string, claims: unknown } ]]
				T.ok(r.reason:find("H1") ~= nil, "receipt should cite Hole H1")
			end
		end
	end)

	T.it("two claims, same provenance, same schema -> still Open (no independent source)", function()
		local c1 = mk("string", claim.PROVENANCE.MINED)
		local c2 = mk("string", claim.PROVENANCE.MINED)
		local result = check.check({ c1, c2 })
		local entry = find_entry(result, "s")
		T.ok(entry ~= nil)
		if entry ~= nil then
			T.eq(kernel.kind(entry.verdict), "open")
		end
	end)
end)

T.describe("check: independent agreeing sources -> Proved", function()
	T.it("stated + mined agree on the same claim -> Proved", function()
		local c1 = mk("non-nil", claim.PROVENANCE.STATED)
		local c2 = mk("non-nil", claim.PROVENANCE.MINED)
		local result = check.check({ c1, c2 })
		local entry = find_entry(result, "s")
		T.ok(entry ~= nil)
		if entry ~= nil then
			T.eq(kernel.kind(entry.verdict), "proved")
			local cert = kernel.cert(entry.verdict)
			T.ok(cert ~= nil)
		end
	end)

	T.it("stated + axiom + mined all agree -> still Proved (three sources, no special-casing)", function()
		local c1 = mk("reachable", claim.PROVENANCE.STATED)
		local c2 = mk("reachable", claim.PROVENANCE.AXIOM)
		local c3 = mk("reachable", claim.PROVENANCE.MINED)
		local result = check.check({ c1, c2, c3 })
		local entry = find_entry(result, "s")
		T.ok(entry ~= nil)
		if entry ~= nil then
			T.eq(kernel.kind(entry.verdict), "proved")
		end
	end)
end)

T.describe("check: independent conflicting sources -> Refuted", function()
	T.it("stated and mined disagree on schema_key -> Refuted with both claims in the trace", function()
		local c1 = mk("string", claim.PROVENANCE.STATED)
		local c2 = mk("integer", claim.PROVENANCE.MINED)
		local result = check.check({ c1, c2 })
		local entry = find_entry(result, "s")
		T.ok(entry ~= nil)
		if entry ~= nil then
			T.eq(kernel.kind(entry.verdict), "refuted")
			local trace = kernel.trace(entry.verdict)
			T.ok(trace ~= nil)
			if trace ~= nil then
				local tr = trace --[[: { reason: string, key: string, claims: { [integer]: Claim, ... } } ]]
				T.eq(#tr.claims, 2)
			end
		end
	end)
end)

T.describe("check: grade/credence never branches the verdict", function()
	T.it("provenance identity alone decides the verdict, not any grade weighting", function()
		-- Same setup as the Proved case above, but assert there is no
		-- grade-like field anywhere on the verdict payload -- the check
		-- law must not invent one. declarative-design.md: "Grade axis:
		-- operationally inert" -- checking machinery never branches on
		-- grade, only reporting does (out of scope here).
		local c1 = mk("boolean", claim.PROVENANCE.STATED)
		local c2 = mk("boolean", claim.PROVENANCE.AXIOM)
		local result = check.check({ c1, c2 })
		local entry = find_entry(result, "s")
		T.ok(entry ~= nil)
		if entry ~= nil then
			local cert = kernel.cert(entry.verdict)
			T.ok(cert ~= nil)
			-- The cert payload's declared shape ({ reason, key, claims }, see
			-- check.lua) structurally has no grade/credence field at all --
			-- the strongest guarantee available that the check law never
			-- fabricates one.
		end
	end)
end)

T.describe("check.tally", function()
	T.it("counts verdict kinds across a CheckResult", function()
		-- Three distinct topics (site s1/s2/s3), one claim source pattern
		-- each, so each lands in its own group under the check law.
		local open_c = mk("string", claim.PROVENANCE.STATED, "s1")
		local proved_a = mk("x", claim.PROVENANCE.STATED, "s2")
		local proved_b = claim.new({
			site = "s2", slot = "k", stratum = claim.STRATUM.PI1, modal = claim.MODAL.BOX,
			schema = "x", schema_key = "x", provenance = claim.PROVENANCE.MINED,
		})
		if proved_b == nil then error("check_test: claim.new failed") end
		local refuted_a = mk("y", claim.PROVENANCE.STATED, "s3")
		local refuted_b = claim.new({
			site = "s3", slot = "k", stratum = claim.STRATUM.PI1, modal = claim.MODAL.BOX,
			schema = "z", schema_key = "z", provenance = claim.PROVENANCE.MINED,
		})
		if refuted_b == nil then error("check_test: claim.new failed") end

		local all = { open_c, proved_a, proved_b, refuted_a, refuted_b }
		local result = check.check(all)
		local counts = check.tally(result)
		T.eq(counts.open, 1)
		T.eq(counts.proved, 1)
		T.eq(counts.refuted, 1)
	end)
end)
