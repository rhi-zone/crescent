-- lib/type/v10_kernel/replayer/replay.lua
--
-- Replay engine for the v10 kernel replayer
-- (docs/decisions/typechecker-v10-core-design.md, "Replayer: certificates,
-- taint, discharge"). One bottom-up pass per certificate node (certificate.lua),
-- memoized, computing three things per node: conclusion (never stored on the
-- certificate — computed), taint set, open-hypothesis set. Root acceptance
-- additionally requires the conclusion be closed and the open-hypothesis set
-- empty.
--
-- A replayer instance is built over an injected term_algebra tier instance
-- (`k`, from term_algebra.new({tier=...})) — caps-first: the tier is a
-- deliberate trust decision (run-level axiom exposure), never reached for
-- ambiently. Kernel-config axioms are carved out of node taint into a
-- run-level trust label derived from `k.trust_label`
-- ({eq=..., subst=...}); node taint sets stay reserved for in-derivation
-- axiom citations. Memo entries are guarded by a config-hash check (the
-- anti-laundering rule: a fast-config result must never be served into a
-- reference-config run) — each replayer instance already owns its own memo
-- table (so cross-instance leakage cannot happen structurally), and each
-- entry additionally records the config hash it was computed under so a
-- hypothetically-shared/persisted memo cannot silently launder results
-- either.
--
-- Discharge (owner-ratified explicit-id form, resolving the brief's
-- flagged gap): a rule schema's discharge slot is (premise_index,
-- hypothesis_pattern); the CITING node names, per slot, which open
-- hypothesis ids it discharges there. For each named id: it must be
-- present in that premise's own open-hypothesis set (citing a non-open id
-- is a rejection), and its carried judgment must equal
-- instantiate(hypothesis_pattern, shared bindings) (mismatch is a
-- rejection). Valid named ids are removed from the node's open set; every
-- hypothesis NOT named by any slot stays open and propagates upward
-- untouched — this is what lets nested/unrelated hypothetical contexts
-- compose without interference (docs/decisions note: "ALL unnamed
-- hypotheses stay open and bubble upward untouched").

local M = {}

--:: TrustLabel = { eq: string, subst: string }
--:: Binding = { term: unknown, depth: integer }
--:: Bindings = { [string]: Binding }
--:: TermAlgebra = { equal: (unknown, unknown) -> boolean, shift: (unknown, integer, integer) -> (unknown | nil, string | nil), match: (unknown, unknown) -> (Bindings | nil, string | nil), instantiate: (unknown, Bindings) -> (unknown | nil, string | nil), is_ground: (unknown) -> boolean, is_closed: (unknown) -> boolean, tier: string, trust_label: TrustLabel }

--:: TaintSet = { [string]: boolean }
--:: OpenSet = { [string]: unknown }
--:: ReplayResult = { conclusion: unknown, taint: TaintSet, open: OpenSet }
--:: TrustReport = { taint: TaintSet, run_label: TrustLabel }
--:: RootResult = { conclusion: unknown, trust: TrustReport }

--:: MemoEntry = { config_hash: string, result: ReplayResult }
--:: DischargeSlot = { premise: integer, pattern: unknown }
--:: RuleDecl = { name: string, version: integer, premises: unknown[], conclusion: unknown, discharges: DischargeSlot[] }
--:: AxiomDecl = { name: string, version: integer, pattern: unknown }
--:: IdSet = { [string]: boolean }
--:: HypNode = { kind: "hyp", id: string, judgment: unknown }
--:: AxiomNode = { kind: "axiom", axiom: AxiomDecl, bindings: Bindings }
--:: RuleNode = { kind: "rule", rule: RuleDecl, premises: unknown[], discharges: IdSet[] }
--:: Visiting = { [unknown]: boolean | nil }
--:: Replayer = { k: TermAlgebra, config_hash: string, memo: { [unknown]: MemoEntry }, replay: (self: Replayer, node: unknown) -> (ReplayResult | nil, string | nil), trust_report: (self: Replayer, result: ReplayResult) -> TrustReport, replay_root: (self: Replayer, node: unknown) -> (RootResult | nil, string | nil) }
--:: ReplayNodeFn = (self: Replayer, node: unknown, visiting: Visiting) -> (ReplayResult | nil, string | nil)

--: (axiom: AxiomDecl) -> string
local function axiom_key(axiom)
	return axiom.name .. "@v" .. axiom.version
end

--: (label: TrustLabel) -> string
local function config_hash_of(label)
	return label.eq .. ":" .. label.subst
end

-- Merge one premise's local match bindings into the shared cross-premise
-- environment, using the same non-linear equal-check semantics
-- term_algebra's match uses within a single pattern: a metavariable bound
-- by an earlier premise and re-occurring in a later one must denote the
-- same term once shift-adjusted from its recorded binding depth to the
-- later occurrence's depth. Built entirely from term_algebra's public
-- primitives (equal, shift) — no term_algebra internals touched.
--: (k: TermAlgebra, global: Bindings, incoming: Bindings) -> (Bindings | nil, string | nil)
local function merge_bindings(k, global, incoming)
	for id, b in pairs(incoming) do
		local existing = global[id]
		if not existing then
			global[id] = b
		else
			local shifted, err = k.shift(existing.term, b.depth - existing.depth, 0)
			if not shifted then
				return nil, "metavariable " .. id .. " conflict across premises: " .. (err or "shift failed")
			end
			if not k.equal(shifted, b.term) then
				return nil, "metavariable " .. id .. " bound to conflicting terms across premises"
			end
		end
	end
	return global
end

local Replayer = {}
Replayer.__index = Replayer

-- Build a replayer over an injected term_algebra tier instance.
--: (k: unknown) -> (Replayer | nil, string | nil)
function M.new(k)
	if type(k) ~= "table" then return nil, "replayer.new: k (a term_algebra instance) is required" end
	local kt = k --[[: { [string]: unknown } ]]
	if type(kt.match) ~= "function" or type(kt.instantiate) ~= "function"
		or type(kt.is_ground) ~= "function" or type(kt.is_closed) ~= "function"
		or type(kt.equal) ~= "function" or type(kt.shift) ~= "function" then
		return nil, "replayer.new: k must be a term_algebra tier instance (from term_algebra.new)"
	end
	local trust_label_raw = kt.trust_label
	if type(trust_label_raw) ~= "table" then return nil, "replayer.new: k.trust_label is required" end
	local trust_label = trust_label_raw --[[: TrustLabel ]]
	if type(trust_label.eq) ~= "string" then return nil, "replayer.new: k.trust_label must be {eq, subst}" end
	if type(trust_label.subst) ~= "string" then return nil, "replayer.new: k.trust_label must be {eq, subst}" end

	local self = {
		k = k --[[: TermAlgebra ]],
		config_hash = config_hash_of(trust_label),
		memo = setmetatable({}, { __mode = "k" }) --[[: { [unknown]: MemoEntry } ]],
	}
	return setmetatable(self, Replayer)
end

local replay_node --: ReplayNodeFn | nil

--: (hyp: HypNode) -> (ReplayResult | nil, string | nil)
local function replay_hyp(hyp)
	return { conclusion = hyp.judgment, taint = {}, open = { [hyp.id] = hyp.judgment } }
end

--: (self: Replayer, an: AxiomNode) -> (ReplayResult | nil, string | nil)
local function replay_axiom(self, an)
	local conclusion, ierr = self.k.instantiate(an.axiom.pattern, an.bindings)
	if not conclusion then
		return nil, "replay: axiom " .. an.axiom.name .. ": " .. (ierr or "instantiate failed")
	end
	if not self.k.is_ground(conclusion) then
		return nil, "replay: axiom " .. an.axiom.name .. ": conclusion is not ground"
	end
	return { conclusion = conclusion, taint = { [axiom_key(an.axiom)] = true }, open = {} }
end

--: (self: Replayer, rn: RuleNode, visiting: Visiting) -> (ReplayResult | nil, string | nil)
local function replay_rule(self, rn, visiting)
	local rule = rn.rule

	if not replay_node then return nil, "replay: internal error: replay_node not initialized" end

	local premise_results = {} --[[: ReplayResult[] ]]
	for i, pnode in ipairs(rn.premises) do
		local pr, perr = replay_node(self, pnode, visiting)
		if not pr then
			return nil, "replay: rule " .. rule.name .. " premise " .. i .. ": " .. (perr or "replay failed")
		end
		premise_results[i] = pr
	end

	local bindings = {} --[[: Bindings ]]
	for i, pat in ipairs(rule.premises) do
		local local_bindings, merr = self.k.match(pat, premise_results[i].conclusion)
		if not local_bindings then
			return nil, "replay: rule " .. rule.name .. " premise " .. i .. " match failed: " .. (merr or "no match")
		end
		local merged, mgerr = merge_bindings(self.k, bindings, local_bindings)
		if not merged then
			return nil, "replay: rule " .. rule.name .. ": " .. (mgerr or "binding merge failed")
		end
		bindings = merged
	end

	local conclusion, ierr = self.k.instantiate(rule.conclusion, bindings)
	if not conclusion then
		return nil, "replay: rule " .. rule.name .. " conclusion: " .. (ierr or "instantiate failed")
	end
	if not self.k.is_ground(conclusion) then
		return nil, "replay: rule " .. rule.name .. " conclusion is not ground"
	end

	local taint = {} --[[: TaintSet ]]
	local open = {} --[[: OpenSet ]]
	for _, pr in ipairs(premise_results) do
		for key in pairs(pr.taint) do taint[key] = true end
		for id, judgment in pairs(pr.open) do open[id] = judgment end
	end

	for slot_idx, slot in ipairs(rule.discharges) do
		local id_set = rn.discharges[slot_idx] or {}
		local premise_open = premise_results[slot.premise].open
		local expected, eerr = self.k.instantiate(slot.pattern, bindings)
		if not expected then
			return nil, "replay: rule " .. rule.name .. " discharge slot " .. slot_idx .. ": "
				.. (eerr or "instantiate failed")
		end
		for id_raw in pairs(id_set) do
			if type(id_raw) == "string" then
				local id = id_raw
				local judgment = premise_open[id]
				if judgment == nil then
					return nil, "replay: rule " .. rule.name .. " discharge slot " .. slot_idx
						.. ": hypothesis " .. id .. " is not open in premise " .. slot.premise
				end
				if not self.k.equal(judgment, expected) then
					return nil, "replay: rule " .. rule.name .. " discharge slot " .. slot_idx
						.. ": hypothesis " .. id .. " judgment does not match discharge pattern"
				end
				open[id] = nil
			end
		end
	end

	return { conclusion = conclusion, taint = taint, open = open }
end

--: ReplayNodeFn
replay_node = function(self, node, visiting)
	if type(node) ~= "table" then return nil, "replay: not a certificate node" end
	local n = node --[[: { [string]: unknown } ]]

	-- TYPECHECKER WORKAROUND: indexing a `{ [unknown]: T }`-shaped map
	-- (memo/visiting are keyed by certificate-node table identity, which is
	-- exactly why they're `[unknown]`-keyed rather than `[string]`/
	-- `[integer]`-keyed) with a `table`-narrowed key falls back to `any`
	-- inference even with an explicit read-site cast immediately after —
	-- the natural code is the bare `self.memo[node]` / `visiting[node]`
	-- reads below with `MemoEntry | nil` / `boolean | nil` inferred
	-- directly. See TODO.md.
	local cached = self.memo[node] --[[: MemoEntry | nil ]]
	if cached and cached.config_hash == self.config_hash then
		return cached.result
	end

	local already_visiting = visiting[node] --[[: boolean | nil ]]
	if already_visiting then return nil, "replay: cycle detected in certificate DAG" end
	visiting[node] = true

	local result --[[: ReplayResult | nil ]]
	local err --[[: string | nil ]]
	local kind = n.kind
	if kind == "hyp" then
		result, err = replay_hyp(node --[[: HypNode ]])
	elseif kind == "axiom" then
		result, err = replay_axiom(self, node --[[: AxiomNode ]])
	elseif kind == "rule" then
		result, err = replay_rule(self, node --[[: RuleNode ]], visiting)
	else
		result, err = nil, "replay: unrecognized certificate node kind " .. tostring(kind)
	end

	visiting[node] = false

	if not result then return nil, err end

	self.memo[node] = { config_hash = self.config_hash, result = result }
	return result
end

-- Replay a node; does NOT apply root acceptance criteria (see replay_root).
--: (self: Replayer, node: unknown) -> (ReplayResult | nil, string | nil)
function Replayer:replay(node)
	local visiting = {} --[[: Visiting ]]
	return replay_node(self, node, visiting)
end

-- Effective trust for an already-computed replay result: node taint union
-- run-level label (per the ratified trust-query API). Usable on any
-- result, not only root results.
--: (self: Replayer, result: ReplayResult) -> TrustReport
function Replayer:trust_report(result)
	return { taint = result.taint, run_label = self.k.trust_label }
end

-- Replay a node and apply root acceptance: conclusion must be ground (checked
-- at every node already) AND closed (empty free-variable context), and the
-- open-hypothesis set must be empty.
--: (self: Replayer, node: unknown) -> (RootResult | nil, string | nil)
function Replayer:replay_root(node)
	local result, err = self:replay(node)
	if not result then return nil, err end
	if not self.k.is_closed(result.conclusion) then
		return nil, "replay_root: conclusion is not closed (has free variables)"
	end
	if next(result.open) ~= nil then
		local ids = {} --[[: Arr<string> ]]
		local n = 0
		for id in pairs(result.open) do
			if type(id) == "string" then
				n = n + 1
				ids[n] = id
			end
		end
		table.sort(ids)
		return nil, "replay_root: undischarged hypothesis(es): " .. table.concat(ids, ", ")
	end
	return { conclusion = result.conclusion, trust = self:trust_report(result) }
end

return M
