-- lib/type/v10_cleanroom/replayer.lua
-- v10 kernel certificate replayer — REFERENCE TIER (cleanroom).
--
-- Implements the ratified replayer spec from
-- docs/decisions/typechecker-v10-core-design.md plus the owner-adjudicated
-- rulings F8..F12 (adjudicated 2026-07-29; authoritative over any
-- transient doc state):
--   F8  hypothesis identity = leaf object identity; hypothesis nodes
--       carry no id field; the "ids" cited by discharge are the leaf
--       node references themselves. The same judgment in two distinct
--       leaves is two hypotheses; a shared leaf is one.
--   F9  STRICT closedness: every node's computed conclusion must be
--       ground AND closed (the root check is retained as a redundant
--       belt).
--   F10 hypothesis leaf judgments must be ground AND closed; judgments
--       containing metavariables are rejected.
--   F11 declaration-time rejections: discharge-slot premise index out of
--       range; conclusion/slot-pattern metavariables not a subset of the
--       premise metavariables; (name, version) unique per registry.
--       Taint identity is the declaration object; (name, version) is the
--       citation/display key.
--   F12 axiom-citation bindings are plain terms at depth 0, each ground
--       AND closed; bindings for metavariables not in the axiom's
--       pattern are rejected.
--
-- Certificate grammar — exactly three node kinds (plain tables; DAG by
-- reference; the replayer validates, never trusts):
--   rule       { kind = "rule", rule = <RuleDecl>, premises = {node...},
--                discharge = { [slot index] = {hyp node...} }?,
--                conclusion = <Term>? }
--   axiom      { kind = "axiom", axiom = <AxiomDecl>,
--                bindings = { [meta id] = <Term> }?, conclusion = <Term>? }
--   hypothesis { kind = "hypothesis", judgment = <Term>,
--                conclusion = <Term>? }
-- Axiom citations admit NO discharge form (enforced here and at
-- declaration). Optional conclusion annotations are verified when
-- present and never needed. Derivation nodes carry no other content —
-- conclusions are computed bottom-up; nothing inside a certificate can
-- lie about content.
--
-- Replay = one memoized bottom-up pass per node computing
-- (conclusion, taint set, open-hypothesis set). Root acceptance =
-- conclusion ground AND closed (already per-node under F9) + empty open
-- set. Run-level trust label derived from the kernel config; caches are
-- keyed by config hash (anti-laundering). Reference config
-- { eq = "reference", subst = "eager" } carries an empty kernel-axiom
-- label — the always-available escape to kernel-axiom-free status.

local ta = require("lib.type.v10_cleanroom.term_algebra")

local M = {}

--:: DischargeSlot = { premise: integer, hypothesis: Term }
--:: RuleDecl = { kind: "rule", name: string, version: integer, premises: Term[], conclusion: Term, discharges: DischargeSlot[] }
--:: AxiomDecl = { kind: "axiom", name: string, version: integer, pattern: Term }
--:: Registry = { decls: { [string]: RuleDecl | AxiomDecl } }
-- CertNode citation slots are typed as the declaration union: certificates
-- are untrusted input, so a slot may cite the wrong declaration kind — the
-- replayer validates and rejects (resolve_citation + kind narrow).
--:: CertNode = { kind: string, rule?: RuleDecl | AxiomDecl, axiom?: AxiomDecl | RuleDecl, premises?: CertNode[], discharge?: { [integer]: CertNode[] }, bindings?: { [string]: Term }, judgment?: Term, conclusion?: Term }
--:: TaintSet = { [string]: RuleDecl | AxiomDecl }
--:: NodeResult = { conclusion: Term, taint: TaintSet, open: CertNode[] }
--:: MemoTable = { nodes: CertNode[], results: NodeResult[] }
--:: VisitLink = { node: CertNode, prev: VisitLink | nil }
--:: KernelConfig = { eq: string, subst: string }
--:: ReplayResult = { conclusion: Term, taint: TaintSet, trust_label: string[], config_hash: string }
--:: Observation = { conclusion: Term, taint: TaintSet, open: CertNode[] }
--:: RuleSpec = { name: string, version: integer, premises: Term[], conclusion: Term, discharges?: DischargeSlot[] }
--:: AxiomSpec = { name: string, version: integer, pattern: Term, discharges?: unknown, discharge?: unknown }
--:: Replayer = { registry: Registry, config: KernelConfig, config_hash: string, trust_label: string[], cache: { [string]: MemoTable } }

-- ── shape predicates ──────────────────────────────────────────────────────────
-- TYPECHECKER WORKAROUND: same as term_algebra.lua — runtime guards are
-- named predicates over `unknown` because a direct inline `type(x)` guard
-- widens an annotated value to `unknown`. See TODO.md.

--: (v: unknown) -> boolean
local function is_table(v)
	return type(v) == "table"
end

--: (v: unknown) -> boolean
local function is_nonempty_string(v)
	return type(v) == "string" and v ~= ""
end

--: (v: unknown) -> boolean
local function is_integer(v)
	return type(v) == "number" and v == math.floor(v)
end

-- ── immutability fence ────────────────────────────────────────────────────────
-- Registry declarations are immutable by contract (same enforcement
-- boundary as term_algebra's signature objects: new-key addition is
-- trapped; existing-field writes are out-of-contract and unsupported —
-- Lua 5.1 cannot trap them without breaking pairs/# iteration).

local FROZEN_MT = {
	--: (t: unknown, k: unknown, v: unknown) -> nil
	__newindex = function(t, k, v)
		error("attempt to modify an immutable registry declaration object", 2)
	end,
}

--: (t: unknown) -> nil
local function freeze(t)
	if type(t) == "table" then
		setmetatable(t, FROZEN_MT)
	end
end

-- ── registry ──────────────────────────────────────────────────────────────────

--- Fresh, empty declaration registry. (name, version) is unique per
--- registry across rules and axioms (F11).
--: () -> Registry
M.new_registry = function()
	return { decls = {} }
end

--- Citation/display key for a declaration: "name@version" (F11 — taint
--- identity remains the declaration object; this key names it).
--: (name: string, version: integer) -> string
local function citation_key(name, version)
	return name .. "@" .. tostring(version)
end

M.citation_key = citation_key

--: (registry: Registry, spec: RuleSpec | AxiomSpec, what: string) -> (string | nil, string | nil)
local function validate_decl_header(registry, spec, what)
	if not is_table(registry) or not is_table(registry.decls) then
		return nil, what .. ": registry is not a registry object"
	end
	if not is_table(spec) then return nil, what .. ": spec must be a table" end
	if not is_nonempty_string(spec.name) then
		return nil, what .. ": name must be a non-empty string"
	end
	if not is_integer(spec.version) then
		return nil, what .. ": version must be an integer"
	end
	local key = citation_key(spec.name, spec.version)
	if registry.decls[key] ~= nil then
		return nil, ("%s: '%s' is already declared in this registry"):format(what, key)
	end
	return key
end

--- Declare a schematic axiom: a named, versioned registry object
--- carrying a judgment pattern. Ground axioms are the zero-metavariable
--- special case. Axioms admit NO discharge form — a spec carrying one is
--- rejected here (schema-level enforcement).
--: (registry: Registry, spec: AxiomSpec) -> (AxiomDecl | nil, string | nil)
M.declare_axiom = function(registry, spec)
	local key, err = validate_decl_header(registry, spec, "declare_axiom")
	if key == nil then return nil, err end
	if spec.discharges ~= nil or spec.discharge ~= nil then
		return nil, "declare_axiom: axioms admit no discharge form"
	end
	if not ta.is_term(spec.pattern) then
		return nil, "declare_axiom: pattern must be a term"
	end
	local decl = {
		kind = "axiom",
		name = spec.name,
		version = spec.version,
		pattern = spec.pattern,
	}
	freeze(decl)
	registry.decls[key] = decl
	return decl
end

--- Declare a rule schema: premise patterns + conclusion pattern in the
--- one term grammar, plus discharge slots (premise index, hypothesis
--- pattern). Declaration-time rejections per F11.
--: (registry: Registry, spec: RuleSpec) -> (RuleDecl | nil, string | nil)
M.declare_rule = function(registry, spec)
	local key, err = validate_decl_header(registry, spec, "declare_rule")
	if key == nil then return nil, err end
	if not is_table(spec.premises) then
		return nil, "declare_rule: premises must be a list of pattern terms"
	end
	local premise_metas = {} --[[: { [string]: boolean } ]]
	for i = 1, #spec.premises do
		local p = spec.premises[i]
		if not ta.is_term(p) then
			return nil, ("declare_rule: premise %d is not a term"):format(i)
		end
		for id in pairs(p.metas) do
			premise_metas[id] = true
		end
	end
	if not ta.is_term(spec.conclusion) then
		return nil, "declare_rule: conclusion must be a term"
	end
	for id in pairs(spec.conclusion.metas) do
		if not premise_metas[id] then
			return nil, ("declare_rule: conclusion metavariable '%s' does not occur in any premise")
				:format(id)
		end
	end
	local slots = {} --[[: DischargeSlot[] ]]
	local dspec = spec.discharges
	if dspec ~= nil then
		if not is_table(dspec) then
			return nil, "declare_rule: discharges must be a list of slots"
		end
		for i = 1, #dspec do
			local s = dspec[i]
			if not is_table(s) then
				return nil, ("declare_rule: discharge slot %d is malformed"):format(i)
			end
			if not is_integer(s.premise) then
				return nil, ("declare_rule: discharge slot %d premise index out of range"):format(i)
			end
			if s.premise < 1 or s.premise > #spec.premises then
				return nil, ("declare_rule: discharge slot %d premise index out of range"):format(i)
			end
			if not ta.is_term(s.hypothesis) then
				return nil, ("declare_rule: discharge slot %d hypothesis pattern is not a term"):format(i)
			end
			for id in pairs(s.hypothesis.metas) do
				if not premise_metas[id] then
					return nil, ("declare_rule: discharge slot %d metavariable '%s' does not occur in any premise")
						:format(i, id)
				end
			end
			local slot = { premise = s.premise, hypothesis = s.hypothesis }
			freeze(slot)
			slots[i] = slot
		end
	end
	local decl = {
		kind = "rule",
		name = spec.name,
		version = spec.version,
		premises = spec.premises,
		conclusion = spec.conclusion,
		discharges = slots,
	}
	freeze(slots)
	freeze(decl)
	registry.decls[key] = decl
	return decl
end

-- ── replayer instance / kernel config ─────────────────────────────────────────

--- Kernel-axiom names contributed by a kernel config. The reference
--- config contributes none (the ratified free property: an all-reference
--- run carries no kernel axioms). This build implements the reference
--- tier only; any other tier value is rejected at construction.
--: (config: KernelConfig) -> (string[] | nil, string | nil)
local function trust_label_for_config(config)
	if config.eq ~= "reference" then
		return nil, ("kernel eq tier '%s' is not available in the reference build"):format(tostring(config.eq))
	end
	if config.subst ~= "eager" then
		return nil, ("kernel subst tier '%s' is not available in the reference build"):format(tostring(config.subst))
	end
	return {}
end

--- Construct a replayer bound to one registry and one kernel config.
--- Citations replay only against declarations present in this registry
--- (declared-object identity — forged declaration tables are rejected).
--- The memo cache is keyed by config hash (anti-laundering): a result
--- computed under one config is never served into a run under another.
--: (opts: { registry: Registry, config?: KernelConfig }) -> (Replayer | nil, string | nil)
M.new_replayer = function(opts)
	if not is_table(opts) then return nil, "new_replayer: opts must be a table" end
	local registry = opts.registry
	if not is_table(registry) or not is_table(registry.decls) then
		return nil, "new_replayer: opts.registry must be a registry object"
	end
	local config = opts.config
	if config == nil then
		config = { eq = "reference", subst = "eager" }
	end
	if not is_table(config) or not is_nonempty_string(config.eq) or not is_nonempty_string(config.subst) then
		return nil, "new_replayer: config must be { eq = string, subst = string }"
	end
	local label, lerr = trust_label_for_config(config)
	if label == nil then return nil, "new_replayer: " .. tostring(lerr) end
	local config_hash = "eq=" .. config.eq .. ";subst=" .. config.subst
	return {
		registry = registry,
		config = config,
		config_hash = config_hash,
		trust_label = label,
		cache = { [config_hash] = { nodes = {}, results = {} } },
	}
end

-- ── replay ────────────────────────────────────────────────────────────────────

--: (list: CertNode[], x: unknown) -> boolean
local function contains(list, x)
	for i = 1, #list do
		if list[i] == x then return true end
	end
	return false
end

-- TYPECHECKER WORKAROUND: memoization and the visiting/discharged sets are
-- naturally Lua tables keyed by certificate node objects, but the
-- typechecker's index signatures only admit primitive key types
-- (`{ [string]: T }` / `{ [integer]: T }`), not `{ [CertNode]: T }`. The
-- memo is therefore a typed parallel-array association (node -> result by
-- identity, linear scan), the open/discharged sets are node lists, and
-- the cycle-detection path is an immutable linked list — semantics
-- identical (each node still computed exactly once per run), lookup O(n)
-- instead of O(1), acceptable in the reference tier whose doctrine is
-- simplicity over speed. Revert to node-keyed tables when the checker
-- supports non-primitive index-signature keys. See TODO.md.

--: () -> MemoTable
local function memo_new()
	return { nodes = {}, results = {} }
end

--: (memo: MemoTable, node: CertNode) -> (NodeResult | nil)
local function memo_get(memo, node)
	local nodes = memo.nodes
	for i = 1, #nodes do
		if nodes[i] == node then return memo.results[i] end
	end
	return nil
end

--: (memo: MemoTable, node: CertNode, res: NodeResult) -> nil
local function memo_put(memo, node, res)
	local n = #memo.nodes + 1
	memo.nodes[n] = node
	memo.results[n] = res
end

-- The in-progress path for cycle detection is an immutable linked list
-- (extended per recursion step, never mutated).
--: (link: VisitLink | nil, node: CertNode) -> boolean
local function on_path(link, node)
	while link ~= nil do
		if link.node == node then return true end
		link = link.prev
	end
	return false
end

--- Resolve a cited declaration against the replayer's registry by
--- declared-object identity; reject anything not declared there.
--: (rp: Replayer, decl: RuleDecl | AxiomDecl | nil, want_kind: string, what: string) -> (string | nil, string | nil)
local function resolve_citation(rp, decl, want_kind, what)
	if decl == nil then
		return nil, what .. ": citation is not a declaration object"
	end
	if not is_nonempty_string(decl.name) then
		return nil, what .. ": citation is not a declaration object"
	end
	if not is_integer(decl.version) then
		return nil, what .. ": citation is not a declaration object"
	end
	local key = citation_key(decl.name, decl.version)
	if rp.registry.decls[key] ~= decl then
		return nil, ("%s: '%s' is not declared in this replayer's registry"):format(what, key)
	end
	if decl.kind ~= want_kind then
		return nil, ("%s: '%s' is a %s, not a %s"):format(what, key, tostring(decl.kind), want_kind)
	end
	return key
end

local replay_node

--: (node: CertNode) -> (NodeResult | nil, string | nil)
local function replay_hypothesis(node)
	if node.premises ~= nil or node.discharge ~= nil or node.bindings ~= nil then
		return nil, "replay: hypothesis nodes carry only their assumed judgment"
	end
	local j = node.judgment
	if j == nil or not ta.is_term(j) then
		return nil, "replay: hypothesis node judgment must be a term"
	end
	if not ta.is_ground(j) then
		return nil, "replay: hypothesis judgment contains a metavariable"
	end
	if not ta.is_closed(j) then
		return nil, "replay: hypothesis judgment must be closed"
	end
	local annot = node.conclusion
	if annot ~= nil then
		if not ta.is_term(annot) or not ta.equal(annot, j) then
			return nil, "replay: hypothesis conclusion annotation does not match its judgment"
		end
	end
	return { conclusion = j, taint = {}, open = { node } }
end

--: (rp: Replayer, node: CertNode) -> (NodeResult | nil, string | nil)
local function replay_axiom(rp, node)
	local decl = node.axiom
	local key, err = resolve_citation(rp, decl, "axiom", "replay")
	if key == nil or decl == nil then return nil, err end
	-- static narrow of the citation union; resolve_citation already
	-- verified the kind at runtime
	if decl.kind ~= "axiom" then
		return nil, ("replay: '%s' is not an axiom"):format(key)
	end
	if node.discharge ~= nil then
		return nil, "replay: axiom citations admit no discharge form"
	end
	if node.premises ~= nil or node.judgment ~= nil then
		return nil, "replay: axiom citations carry only bindings"
	end
	local supplied = node.bindings
	if supplied == nil then supplied = {} end
	if not is_table(supplied) then
		return nil, "replay: axiom bindings must be a table"
	end
	local pattern = decl.pattern
	if pattern == nil or not ta.is_term(pattern) then
		return nil, ("replay: axiom '%s' pattern is not a term"):format(key)
	end
	local wrapped = {} --[[: Bindings ]]
	for id, t in pairs(supplied) do
		if not is_nonempty_string(id) then
			return nil, "replay: axiom binding keys must be metavariable ids"
		end
		if pattern.metas[id] == nil then
			return nil, ("replay: axiom binding for '%s' — no such metavariable in the axiom pattern")
				:format(id)
		end
		if not ta.is_term(t) then
			return nil, ("replay: axiom binding for '%s' is not a term"):format(id)
		end
		if not ta.is_ground(t) then
			return nil, ("replay: axiom binding for '%s' contains a metavariable"):format(id)
		end
		if not ta.is_closed(t) then
			return nil, ("replay: axiom binding for '%s' must be closed"):format(id)
		end
		wrapped[id] = { term = t, depth = 0 }
	end
	local concl, ierr = ta.instantiate(pattern, wrapped)
	if concl == nil then return nil, "replay: axiom '" .. key .. "': " .. tostring(ierr) end
	if not ta.is_ground(concl) then
		return nil, ("replay: axiom '%s' conclusion is not ground"):format(key)
	end
	if not ta.is_closed(concl) then
		return nil, ("replay: axiom '%s' conclusion is not closed"):format(key)
	end
	local annot = node.conclusion
	if annot ~= nil then
		if not ta.is_term(annot) or not ta.equal(annot, concl) then
			return nil, ("replay: axiom '%s' conclusion annotation mismatch"):format(key)
		end
	end
	return { conclusion = concl, taint = { [key] = decl }, open = {} }
end

--: (rp: Replayer, node: CertNode, memo: MemoTable, visiting: VisitLink | nil) -> (NodeResult | nil, string | nil)
local function replay_rule(rp, node, memo, visiting)
	local decl = node.rule
	local key, err = resolve_citation(rp, decl, "rule", "replay")
	if key == nil or decl == nil then return nil, err end
	-- static narrow of the citation union; resolve_citation already
	-- verified the kind at runtime
	if decl.kind ~= "rule" then
		return nil, ("replay: '%s' is not a rule"):format(key)
	end
	if node.bindings ~= nil or node.judgment ~= nil then
		return nil, "replay: rule citations carry premises and discharge citations only"
	end
	local premises = node.premises
	if premises == nil then premises = {} end
	if not is_table(premises) then
		return nil, "replay: rule premises must be a list of nodes"
	end
	local decl_premises = decl.premises
	local decl_slots = decl.discharges
	local decl_conclusion = decl.conclusion
	if decl_premises == nil or decl_slots == nil or decl_conclusion == nil then
		return nil, ("replay: rule '%s' declaration is malformed"):format(key)
	end
	if #premises ~= #decl_premises then
		return nil, ("replay: rule '%s' expects %d premise(s), got %d")
			:format(key, #decl_premises, #premises)
	end
	local results = {} --[[: NodeResult[] ]]
	for i = 1, #premises do
		local r, rerr = replay_node(rp, premises[i], memo, visiting)
		if r == nil then return nil, rerr end
		results[i] = r
	end
	-- one shared binding environment across all premises (non-linearity
	-- across premises = the same mechanism as within one pattern)
	local bindings = {} --[[: Bindings ]]
	for i = 1, #decl_premises do
		local ok, merr = ta.match_into(decl_premises[i], results[i].conclusion, bindings)
		if not ok then
			return nil, ("replay: rule '%s' premise %d does not match: %s")
				:format(key, i, tostring(merr))
		end
	end
	-- discharge: explicit citation of open hypothesis leaves, per slot
	local cited_sets = node.discharge
	if cited_sets ~= nil then
		if not is_table(cited_sets) then
			return nil, "replay: discharge must map slot indices to hypothesis node lists"
		end
		for k, v in pairs(cited_sets) do
			local k_ok = false
			if is_integer(k) then
				if k >= 1 and k <= #decl_slots then k_ok = true end
			end
			if not k_ok then
				return nil, ("replay: rule '%s' discharge cites undeclared slot %s")
					:format(key, tostring(k))
			end
			if not is_table(v) then
				return nil, ("replay: rule '%s' discharge slot %s citation must be a list of hypothesis nodes")
					:format(key, tostring(k))
			end
		end
	end
	local discharged = {} --[[: CertNode[] ]]
	for si = 1, #decl_slots do
		local slot = decl_slots[si]
		local cited = nil --[[: CertNode[] | nil ]]
		if cited_sets ~= nil then cited = cited_sets[si] end
		if cited ~= nil and #cited > 0 then
			local expected, ierr = ta.instantiate(slot.hypothesis, bindings)
			if expected == nil then
				return nil, ("replay: rule '%s' discharge slot %d: %s"):format(key, si, tostring(ierr))
			end
			local prem_open = results[slot.premise].open
			for ci = 1, #cited do
				local h = cited[ci]
				if not contains(prem_open, h) then
					return nil, ("replay: rule '%s' discharge slot %d cites a hypothesis not open in premise %d")
						:format(key, si, slot.premise)
				end
				-- h is open in a replayed premise, hence a validated hypothesis leaf
				local hj = h.judgment
				if hj == nil then
					return nil, ("replay: rule '%s' discharge slot %d cites a non-hypothesis node"):format(key, si)
				end
				if not ta.equal(hj, expected) then
					return nil, ("replay: rule '%s' discharge slot %d: hypothesis judgment does not match the slot pattern instance")
						:format(key, si)
				end
				if not contains(discharged, h) then
					discharged[#discharged + 1] = h
				end
			end
		end
		-- an absent or empty citation set is legal: vacuous discharge
	end
	-- open set = union of premises' open sets MINUS the discharged leaves;
	-- nothing is ever globally marked discharged (DAG sharing safe)
	local open = {} --[[: CertNode[] ]]
	local taint = {} --[[: TaintSet ]]
	for i = 1, #results do
		local r = results[i]
		for j = 1, #r.open do
			local h = r.open[j]
			if not contains(open, h) and not contains(discharged, h) then
				open[#open + 1] = h
			end
		end
		for tk, tdecl in pairs(r.taint) do
			taint[tk] = tdecl
		end
	end
	local concl, cerr = ta.instantiate(decl_conclusion, bindings)
	if concl == nil then
		return nil, ("replay: rule '%s' conclusion: %s"):format(key, tostring(cerr))
	end
	if not ta.is_ground(concl) then
		return nil, ("replay: rule '%s' conclusion is not ground"):format(key)
	end
	if not ta.is_closed(concl) then
		return nil, ("replay: rule '%s' conclusion is not closed"):format(key)
	end
	local annot = node.conclusion
	if annot ~= nil then
		if not ta.is_term(annot) or not ta.equal(annot, concl) then
			return nil, ("replay: rule '%s' conclusion annotation mismatch"):format(key)
		end
	end
	return { conclusion = concl, taint = taint, open = open }
end

--: (rp: Replayer, node: CertNode, memo: MemoTable, visiting: VisitLink | nil) -> (NodeResult | nil, string | nil)
replay_node = function(rp, node, memo, visiting)
	if not is_table(node) then
		return nil, "replay: certificate node must be a table"
	end
	local cached = memo_get(memo, node)
	if cached ~= nil then return cached end
	if on_path(visiting, node) then
		return nil, "replay: certificate contains a cycle"
	end
	local path = { node = node, prev = visiting }
	local res = nil --[[: NodeResult | nil ]]
	local err = nil --[[: string | nil ]]
	if node.kind == "hypothesis" then
		res, err = replay_hypothesis(node)
	elseif node.kind == "axiom" then
		res, err = replay_axiom(rp, node)
	elseif node.kind == "rule" then
		res, err = replay_rule(rp, node, memo, path)
	else
		err = ("replay: unknown certificate node kind '%s'"):format(tostring(node.kind))
	end
	if res == nil then return nil, err end
	memo_put(memo, node, res)
	return res
end

--- Replay a certificate root: one memoized bottom-up pass computing
--- (conclusion, taint, open set) per node. Acceptance requires the
--- root's open-hypothesis set empty; every node's conclusion is already
--- required ground AND closed (F9). The result carries the run-level
--- trust label; a node's effective axiom set = taint union trust label.
--: (rp: Replayer, root: CertNode) -> (ReplayResult | nil, string | nil)
M.replay = function(rp, root)
	if not is_table(rp) or not is_table(rp.cache) or not is_nonempty_string(rp.config_hash) then
		return nil, "replay: rp is not a replayer instance"
	end
	local memo = rp.cache[rp.config_hash]
	if memo == nil then
		memo = memo_new()
		rp.cache[rp.config_hash] = memo
	end
	local res, err = replay_node(rp, root, memo, nil)
	if res == nil then return nil, err end
	if #res.open > 0 then
		return nil, ("replay: %d undischarged hypothesis(es) at root"):format(#res.open)
	end
	-- redundant belt (F9 makes these per-node invariants already)
	if not ta.is_ground(res.conclusion) or not ta.is_closed(res.conclusion) then
		return nil, "replay: root conclusion is not ground and closed"
	end
	return {
		conclusion = res.conclusion,
		taint = res.taint,
		trust_label = rp.trust_label,
		config_hash = rp.config_hash,
	}
end

--- Read-only OBSERVATION entry point (owner-ratified; design doc
--- "Read-only observation entry point"): computes the already-ratified
--- per-node triple (conclusion, taint set, open-hypothesis set) for a
--- node, open set in plain view. Carries NO acceptance signal — the
--- result exposes `open` and has no trust_label/config_hash, so it is
--- structurally distinct from a ReplayResult and cannot be laundered
--- into a root-strict verdict; M.replay remains the sole acceptance
--- channel. Same memoized bottom-up computation as M.replay (same
--- per-config-hash cache — anti-laundering keying unchanged), stopped
--- before the root checks. Per-node data errors (F9/F10 violations,
--- cycles, failed matches) still reject — observation relaxes only the
--- root's open-set-empty acceptance criterion, never node validity.
--: (rp: Replayer, node: CertNode) -> (Observation | nil, string | nil)
M.observe = function(rp, node)
	if not is_table(rp) or not is_table(rp.cache) or not is_nonempty_string(rp.config_hash) then
		return nil, "observe: rp is not a replayer instance"
	end
	local memo = rp.cache[rp.config_hash]
	if memo == nil then
		memo = memo_new()
		rp.cache[rp.config_hash] = memo
	end
	local res, err = replay_node(rp, node, memo, nil)
	if res == nil then return nil, err end
	return { conclusion = res.conclusion, taint = res.taint, open = res.open }
end

--- Trust query: a judgment's effective axiom set = node taint (citation
--- keys of in-derivation axiom declarations) union the run-level trust
--- label (kernel-axiom names). Returned as a set of strings.
--: (result: ReplayResult) -> { [string]: boolean }
M.effective_axiom_set = function(result)
	local out = {} --[[: { [string]: boolean } ]]
	for k in pairs(result.taint) do
		out[k] = true
	end
	for i = 1, #result.trust_label do
		out[result.trust_label[i]] = true
	end
	return out
end

return M
