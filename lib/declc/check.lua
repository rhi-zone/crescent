-- lib/declc/check.lua
-- The hypothesis/obligation check law, per the [OWNER-CERTIFIED] formulation
-- in docs/artifacts/2026-07-05-typechecker-declarative-core/
-- declarative-design.md:
--
--   "a pool of graded assumptions (grade = credence, three generation
--    sources, no source special-cased) + mutual-consistency checking with
--    three-valued verdicts (finding strength = witness-status × credence of
--    what it contradicts) + one law: a claim used as a hypothesis must
--    independently survive as an obligation."
--
-- Operational reading used here (this chunk has no semantic derivation
-- engine -- Hole H1, open-threads.md -- so "independently survive as an
-- obligation" is realized the only way this substrate supports: by
-- INDEPENDENT SOURCING, not by re-deriving against the operational
-- semantics):
--
--   Every claim admitted to the pool is, by construction, a hypothesis (it
--   came from one generation source: harvest_stated / harvest_axiom /
--   harvest_mined). It "independently survives as an obligation" iff a
--   SECOND, differently-provenanced claim in the pool asserts the identical
--   proposition about the same TOPIC (site+slot+stratum+modal -- e.g. "what
--   does slot k at site s range over") -- i.e. an independent source
--   re-derived the same obligation. That is the strongest re-derivation this
--   substrate can perform without the missing H1 layer: cross-checking
--   sources against each other rather than against the semantics.
--
--   Claims are grouped by TOPIC (site+slot+stratum+modal), deliberately NOT
--   by claim.key(c) (which also folds in schema_key) -- grouping by
--   claim.key would put two disagreeing claims in two different singleton
--   groups (they'd never share a key), and this law could never observe the
--   disagreement it exists to catch. See group_by_topic below.
--
--   (Proved)  >=2 distinct provenances agree on the same topic AND the same
--             schema_key -- the hypothesis was independently re-derived and
--             it matches.
--   (Refuted) >=2 claims share a topic but disagree on schema_key -- two
--             independent sources assert incompatible propositions about
--             the same site/slot/stratum/modal. This is a real finding (a
--             lying annotation) OR a harvester bug -- check.lua cannot tell
--             which; the trace carries both claims so a human can.
--   (Open)    exactly one provenance produced claims for this topic
--             (however many times) -- no independent obligation-side
--             re-derivation exists. Receipt says so explicitly and cites
--             Hole H1. This is expected to be the common case in this first
--             slice (an Open flood is the finding, not a bug -- see
--             open-threads.md and the task instructions for this chunk).
--
-- No branching on grade/credence anywhere below: declarative-design.md's
-- "Grade axis: operationally inert" finding says checking machinery never
-- branches on grade, and this file doesn't either -- every provenance is
-- treated identically by topic_key() and by the corroborate/contradict
-- logic (no special-casing of stated vs axiom vs mined).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local claim = require("lib.declc.claim")
--:: require "lib.declc.claim"
local kernel = require("lib.declc.kernel")
--:: require "lib.declc.kernel"

local M = {}

--:: ClaimList = { [integer]: Claim, ... }

--:: CheckEntry = {
--::   key: string,
--::   claims: ClaimList,
--::   verdict: unknown,
--::   reason: string,
--:: }

--:: CheckResult = { [string]: CheckEntry, ... }

-- Groups claims by TOPIC -- site+slot+stratum+modal, deliberately NOT
-- claim.key(c) (which also folds in schema_key). Two independent sources
-- disagreeing about what a slot's value ranges over (schema_key) is
-- exactly the contradiction this check law exists to catch -- grouping by
-- claim.key() would silently partition those into two singleton groups
-- (they'd never share a key), and the law could never detect the conflict.
-- Grouping by topic instead asks "do all sources agree on what this site's
-- slot ranges over", which is the actual question in
-- declarative-design.md's "mutual-consistency checking".
local SEP = "\1"

--: (Claim) -> string
local function topic_key(c)
	return table.concat({ claim.stratum(c), claim.modal(c), claim.site(c), claim.slot(c) }, SEP)
end

--: (ClaimList) -> { [string]: ClaimList, ... }
local function group_by_topic(claims)
	local groups = {} --: { [string]: ClaimList, ... }
	for _, c in ipairs(claims) do
		local k = topic_key(c)
		local g = groups[k]
		if g == nil then
			g = {} --: ClaimList
			groups[k] = g
		end
		g[#g + 1] = c
	end
	return groups
end

-- Distinct schema_keys and distinct provenances present within one topic
-- group. A group is internally consistent iff it has exactly one distinct
-- schema_key (all sources that produced a claim for this topic agree on
-- what the claim actually says).
--: (ClaimList) -> ({ [string]: boolean, ... }, { [string]: boolean, ... })
local function distinct_schemas_and_provenances(g)
	local schemas = {} --: { [string]: boolean, ... }
	local provenances = {} --: { [string]: boolean, ... }
	for _, c in ipairs(g) do
		schemas[claim.schema_key(c)] = true
		provenances[claim.provenance(c)] = true
	end
	return schemas, provenances
end

--: ({ [string]: boolean, ... }) -> integer
local function count_keys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- Runs the hypothesis/obligation law over a claim pool. Every claim in
-- `claims` is treated identically regardless of provenance (no
-- special-casing per declarative-design.md).
--: (ClaimList) -> CheckResult
function M.check(claims)
	local groups = group_by_topic(claims)
	local result = {} --: CheckResult

	for key, g in pairs(groups) do
		local schemas, provenances = distinct_schemas_and_provenances(g)
		local n_schemas = count_keys(schemas)
		local n_provenances = count_keys(provenances)

		local verdict
		local reason = "" --: string
		if n_schemas > 1 then
			-- Two-or-more independent sources assert INCOMPATIBLE
			-- propositions for the same site/slot/stratum/modal. Real
			-- finding or harvester bug -- the trace names both so a human
			-- can tell which.
			reason = "conflicting schema_key across independent claim sources for the same topic (site+slot+stratum+modal)"
			verdict = kernel.refuted({ reason = reason, key = key, claims = g })
		elseif n_provenances >= 2 then
			-- The hypothesis was independently re-derived by a second
			-- source and it agrees: the obligation-side check the law
			-- requires has been performed and it survived.
			reason = "claim topic independently re-derived by >=2 distinct provenances with agreeing schema_key"
			verdict = kernel.proved({ reason = reason, key = key, claims = g })
		else
			-- Exactly one provenance produced this claim.key: there is no
			-- second, independent obligation-side derivation to check the
			-- hypothesis against. This is Hole H1 (open-threads.md): the
			-- missing middle derivation layer between the semantics and
			-- solver machinery. Do NOT hardcode a decision here to reduce
			-- this count -- an Open flood at this substrate layer is
			-- data, not failure.
			reason = "no independent obligation-side re-derivation available for this claim "
				.. "(exactly one generation source produced it); this is Hole H1 -- "
				.. "the missing middle derivation layer between the semantics and solver "
				.. "machinery, open-threads.md -- not a decision this check law can make"
			verdict = kernel.open({ reason = reason, key = key, claims = g })
		end

		-- `reason` is also exposed as a plain string field on CheckEntry
		-- (not just buried inside the kernel verdict's opaque payload) so
		-- callers can read WHY without narrowing `unknown` -- kernel.lua's
		-- cert/trace/receipt accessors remain the only way to get the full
		-- payload back out of a Verdict, per the kernel's trust boundary;
		-- this is a convenience duplicate of one field, not a bypass of it.
		result[key] = { key = key, claims = g, verdict = verdict, reason = reason }
	end

	return result
end

-- Convenience: tallies verdict kinds across a CheckResult. Grade-independent
-- (declarative-design.md: grade lives in the reporting layer, not checking
-- machinery) -- this only counts kinds, never weighs by provenance/grade.
--: (CheckResult) -> { proved: number, refuted: number, open: number }
function M.tally(result)
	local counts = { proved = 0, refuted = 0, open = 0 } --: { proved: number, refuted: number, open: number }
	for _, entry in pairs(result) do
		local kind = kernel.kind(entry.verdict)
		if kind == "proved" then
			counts.proved = counts.proved + 1
		elseif kind == "refuted" then
			counts.refuted = counts.refuted + 1
		elseif kind == "open" then
			counts.open = counts.open + 1
		end
	end
	return counts
end

return M
