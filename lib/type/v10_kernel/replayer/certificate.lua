-- lib/type/v10_kernel/replayer/certificate.lua
--
-- Certificate/derivation node constructors for the v10 kernel replayer
-- (docs/decisions/typechecker-v10-core-design.md, "Replayer: certificates,
-- taint, discharge"). Exactly three node kinds, matching the ratified
-- grammar:
--
--   hypothesis(id, judgment)         — leaf; the ONLY content-carrying node
--                                       kind. Its judgment is unchecked at
--                                       construction ("not trusted"); it is
--                                       validated only when discharged
--                                       (replay.lua), never here.
--
--   cite_axiom(axiom, bindings)      — cites a declared axiom (registry.lua
--                                       declare_axiom result) + bindings;
--                                       carries no conclusion of its own —
--                                       replay computes it via instantiate.
--
--   cite_rule(rule, premises,
--             discharges)            — cites a declared rule schema
--                                       (registry.lua declare_rule result)
--                                       + premise nodes +, per discharge
--                                       slot, the set of hypothesis ids
--                                       that citation discharges at that
--                                       slot (owner-ratified explicit-id
--                                       discharge: schema-level slots stay
--                                       pattern-only; the certificate names
--                                       WHICH open hypothesis ids satisfy
--                                       each slot — ids only, no content,
--                                       so nothing here can lie about a
--                                       hypothesis's judgment; that is
--                                       checked at replay against the open
--                                       hypothesis's own carried term).
--                                       An empty (or omitted) id-set for a
--                                       slot is legal: vacuous discharge.
--
-- Node kind is tier-agnostic: constructors here never call term_algebra
-- primitives, only structurally validate arity/shape of what they're
-- handed (patterns/judgments are whatever tier's terms the caller already
-- built). Replay (replay.lua) is where a term_algebra instance is used.

local M = {}

--:: HypNode = { kind: "hyp", id: string, judgment: unknown }
--:: AxiomNode = { kind: "axiom", axiom: unknown, bindings: unknown }
--:: IdSet = { [string]: boolean }
--:: RuleNode = { kind: "rule", rule: unknown, premises: unknown[], discharges: IdSet[] }
--:: CertNode = HypNode | AxiomNode | RuleNode

--:: RuleDecl = { name: string, version: integer, premises: unknown[], conclusion: unknown, discharges: unknown[] }
--:: AxiomDecl = { name: string, version: integer, pattern: unknown }

-- ── Hypothesis leaf ───────────────────────────────────────────────────────────

--: (id: string, judgment: unknown) -> (HypNode | nil, string | nil)
function M.hypothesis(id, judgment)
	if type(id) ~= "string" then return nil, "hypothesis: id must be a string" end
	if id == "" then return nil, "hypothesis: id must not be empty" end
	if type(judgment) ~= "table" then return nil, "hypothesis: judgment must be a term_algebra term" end
	local j = judgment --[[: { [string]: unknown } ]]
	if type(j.tag) ~= "string" then return nil, "hypothesis: judgment must be a term_algebra term" end
	return { kind = "hyp", id = id, judgment = judgment }
end

-- ── Axiom citation ────────────────────────────────────────────────────────────

--: (axiom: unknown, bindings: unknown) -> (AxiomNode | nil, string | nil)
function M.cite_axiom(axiom, bindings)
	if type(axiom) ~= "table" then return nil, "cite_axiom: axiom must be a declared axiom" end
	local a = axiom --[[: { [string]: unknown } ]]
	if type(a.name) ~= "string" or type(a.pattern) ~= "table" then
		return nil, "cite_axiom: axiom must be a declared axiom (see registry.declare_axiom)"
	end
	if bindings == nil then bindings = {} end
	if type(bindings) ~= "table" then return nil, "cite_axiom: bindings must be a table" end
	return { kind = "axiom", axiom = axiom, bindings = bindings }
end

-- ── Rule citation ─────────────────────────────────────────────────────────────
--
-- discharges: an array parallel to the rule schema's discharges array; each
-- entry is an array of hypothesis-id strings discharged by that slot
-- (omitted or {} = vacuous discharge for that slot). Length must match the
-- schema's discharge-slot count, or be omitted entirely when the schema has
-- zero discharge slots.

--: (rule: unknown, premises: unknown, discharges: unknown) -> (RuleNode | nil, string | nil)
function M.cite_rule(rule, premises, discharges)
	if type(rule) ~= "table" then return nil, "cite_rule: rule must be a declared rule schema" end
	local r = rule --[[: RuleDecl ]]
	if type(r.name) ~= "string" or type(r.premises) ~= "table" or type(r.discharges) ~= "table" then
		return nil, "cite_rule: rule must be a declared rule schema (see registry.declare_rule)"
	end

	if type(premises) ~= "table" then return nil, "cite_rule: premises must be an array of certificate nodes" end
	local premises_t = premises --[[: unknown[] ]]
	if #premises_t ~= #r.premises then
		return nil, "cite_rule: rule " .. r.name .. " expects " .. #r.premises
			.. " premise(s), got " .. #premises_t
	end
	for i, p in ipairs(premises_t) do
		if type(p) ~= "table" then return nil, "cite_rule: premise " .. i .. " is not a certificate node" end
		local pn = p --[[: { [string]: unknown } ]]
		if type(pn.kind) ~= "string" then return nil, "cite_rule: premise " .. i .. " is not a certificate node" end
	end

	local n_slots = #r.discharges

	-- Omitting `discharges` entirely means vacuous discharge for every slot
	-- (the common case for rules with zero discharge slots, and a legal
	-- shorthand for rules that DO have slots too). Supplying it explicitly
	-- requires exactly one id-list per schema slot, even if some/all of
	-- those lists are empty — this catches citation authoring mistakes
	-- (wrong slot count) that a silent per-slot default would hide.
	local discharges_spec_t = {} --[[: unknown[] ]]
	if discharges ~= nil then
		if type(discharges) ~= "table" then
			return nil, "cite_rule: discharges must be an array of per-slot hypothesis-id lists"
		end
		discharges_spec_t = discharges --[[: unknown[] ]]
		if #discharges_spec_t ~= n_slots then
			return nil, "cite_rule: rule " .. r.name .. " expects discharge id-lists for " .. n_slots
				.. " slot(s), got " .. #discharges_spec_t
		end
	end

	local id_sets = {} --[[: IdSet[] ]]
	for i = 1, n_slots do
		local list_raw = discharges_spec_t[i]
		if list_raw == nil then list_raw = {} end
		if type(list_raw) ~= "table" then
			return nil, "cite_rule: rule " .. r.name .. " discharge slot " .. i .. " ids must be an array"
		end
		local list = list_raw --[[: unknown[] ]]
		local set = {} --[[: IdSet ]]
		for _, id_raw in ipairs(list) do
			if type(id_raw) ~= "string" then
				return nil, "cite_rule: rule " .. r.name .. " discharge slot " .. i .. " id must be a string"
			end
			if set[id_raw] then
				return nil, "cite_rule: rule " .. r.name .. " discharge slot " .. i
					.. " lists hypothesis id " .. id_raw .. " twice"
			end
			set[id_raw] = true
		end
		id_sets[i] = set
	end

	return { kind = "rule", rule = rule, premises = premises_t, discharges = id_sets }
end

return M
