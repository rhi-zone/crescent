if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

-- Agnostic static-analysis substrate.
--
-- Mechanizes docs/agnostic-static-analysis-object-model.md. The substrate is a
-- claim database + dependency tracker that routes checking to per-semantics
-- hosted checkers (open question 2 in the design doc). It knows NOTHING about
-- props, lambda terms, types, binders, or substitution: claim predicates and
-- args are opaque, and args are compared structurally for claim identity.
--
-- No name-keyed special cases. If a hosted semantics needs something the
-- substrate cannot express, that is a finding to record in the docs, never a
-- hardcoded workaround (repo hard constraint).
--
-- Errors are returned as (nil, errmsg); the substrate never throws for data
-- errors.

local M = {}

-- ── Identity ────────────────────────────────────────────────────────────────
--
-- Every persistent referenceable object has an Id { space, local }. `local` is
-- a reserved Lua word, so the field is named `key` here; the object model's
-- `local` slot maps to `key`. The substrate never interprets `key` as a source
-- name, path, AST index, or binder identity.

--:: Id = { space: string, key: string }

-- Opaque claim/observation/evidence-result data. The substrate treats these as
-- DATA it can serialize and compare structurally — never as functions, threads,
-- or userdata. It does NOT interpret the shape; a hosted semantics owns the
-- grammar and force-casts `ArgValue` to its own type (e.g. `Prop`, `LamTerm`).
--
-- This is the honest substrate type for the object model's "opaque claim args":
-- not TS-`unknown` (which the typechecker forbids both checked- and
-- force-casting away from), but "arbitrary serializable data". The arg-schema
-- gap recorded in the object-model doc is exactly that the substrate stops here
-- and does not validate against a hosted grammar.
--:: ArgValue = nil | boolean | number | string | { [string]: ArgValue } | { [integer]: ArgValue }

--: (string, string) -> Id
function M.id(space, key)
	return { space = space, key = key }
end

-- ── Structural identity of opaque values ─────────────────────────────────────
--
-- The substrate's notion of claim identity is structural equality of the
-- (semantics, predicate, args) triple. Args are arbitrary opaque values — the
-- hosted semantics owns their grammar. We serialize them to a canonical string
-- so two structurally-identical arg trees hash to the same key.
--
-- DECISION (mechanization finding, recorded in the object-model doc's
-- arg-schema open item): identity is purely structural. The substrate does NOT
-- consult a hosted semantics for a finer/coarser identity (alpha-equality being
-- the canonical case). `alpha_eq(t1,t2)` and `alpha_eq(t2,t1)` are DISTINCT
-- claims at the substrate level; symmetry is the hosted semantics' business.

local serialize_value

--: (unknown) -> string
serialize_value = function(value)
	if type(value) == "nil" then return "n" end
	if type(value) == "boolean" then return value and "bT" or "bF" end
	if type(value) == "number" then return "#" .. tostring(value) end
	if type(value) == "string" then
		return "s" .. tostring(#value) .. ":" .. value
	end
	if type(value) ~= "table" then
		-- functions/userdata/threads are not serializable as data; the
		-- substrate refuses them as claim args.
		return "?" .. type(value)
	end
	local t = value
	-- Collect keys deterministically: integer keys in order, then sorted
	-- string keys. Mixed/other keys are stringified for stability.
	local parts = {} --[[: { [integer]: string } ]]
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	-- gather string keys
	local skeys = {} --[[: { [integer]: string } ]]
	for k in pairs(t) do
		if type(k) == "string" then skeys[#skeys + 1] = k end
	end
	table.sort(skeys)
	-- array part first (1..#t), then sorted string keys, then any leftover
	local arr_len = #t
	parts[#parts + 1] = "{" .. tostring(n)
	for i = 1, arr_len do
		parts[#parts + 1] = "[" .. tostring(i) .. "]" .. serialize_value(t[i])
	end
	for _, k in ipairs(skeys) do
		parts[#parts + 1] = "<" .. k .. ">" .. serialize_value(t[k])
	end
	parts[#parts + 1] = "}"
	return table.concat(parts)
end

M._serialize = serialize_value

-- Canonical key for a claim: semantics + predicate + serialized args. Accepts
-- any structure with these three fields (a full Claim, or a bare descriptor).
--: ({ semantics: string, predicate: string, args: ArgValue, ... }) -> string
local function claim_key(claim)
	return claim.semantics .. "|" .. claim.predicate .. "|" .. serialize_value(claim.args)
end

M.claim_key = claim_key

-- ── Result classes ────────────────────────────────────────────────────────
-- accepted / rejected / unknown classify EVIDENCE OUTCOMES, not hosted truth.
-- `unknown` can never be consumed as proof. `rejected` evidence ≠ rejected
-- claim truth.

M.ACCEPTED = "accepted"
M.REJECTED = "rejected"
M.UNKNOWN = "unknown"

-- ── Object constructors ───────────────────────────────────────────────────
-- These build plain data records. Construction puts all fields in the literal
-- (hidden-class discipline, docs/lua-gotchas.md).

--:: Artifact = { id: Id, kind: string, content_ref: unknown, digest: string | nil, meta: unknown }

--: ({ id: Id, kind: string, content_ref: unknown, digest?: string, meta?: unknown }) -> Artifact
function M.artifact(spec)
	return {
		id = spec.id,
		kind = spec.kind,
		content_ref = spec.content_ref,
		digest = spec.digest,
		meta = spec.meta,
	}
end

--:: Observation = { id: Id, predicate: string, args: ArgValue, source_artifacts: Id[], support: string }

--: ({ id: Id, predicate: string, args: ArgValue, source_artifacts: Id[], support: string }) -> Observation
function M.observation(spec)
	return {
		id = spec.id,
		predicate = spec.predicate,
		args = spec.args,
		source_artifacts = spec.source_artifacts,
		support = spec.support,
	}
end

--:: Claim = { id: Id, semantics: string, predicate: string, args: ArgValue, subject_artifacts: Id[] }

--: ({ id: Id, semantics: string, predicate: string, args: ArgValue, subject_artifacts?: Id[] }) -> Claim
function M.claim(spec)
	return {
		id = spec.id,
		semantics = spec.semantics,
		predicate = spec.predicate,
		args = spec.args,
		subject_artifacts = spec.subject_artifacts or {},
	}
end

--:: Evidence = { id: Id, claim: Id, method: string, inputs: Id[], result: ArgValue }

--: ({ id: Id, claim: Id, method: string, inputs?: Id[], result?: ArgValue }) -> Evidence
function M.evidence(spec)
	return {
		id = spec.id,
		claim = spec.claim,
		method = spec.method,
		inputs = spec.inputs or {},
		result = spec.result,
	}
end

--:: Dependency = { from_claim: Id, kind: string, target: Id, invalidation: unknown }

--: ({ from_claim: Id, kind: string, target: Id, invalidation?: unknown }) -> Dependency
function M.dependency(spec)
	return {
		from_claim = spec.from_claim,
		kind = spec.kind,
		target = spec.target,
		invalidation = spec.invalidation,
	}
end

--:: TrustBoundary = { id: Id, kind: string, issuer: string, covers: unknown, payload_digest: string | nil, policy: unknown }

--: ({ id: Id, kind: string, issuer: string, covers?: unknown, payload_digest?: string, policy?: unknown }) -> TrustBoundary
function M.trust_boundary(spec)
	return {
		id = spec.id,
		kind = spec.kind,
		issuer = spec.issuer,
		covers = spec.covers,
		payload_digest = spec.payload_digest,
		policy = spec.policy,
	}
end

-- Dependency kind classes the substrate reserves (object model).
M.DEP_ARTIFACT_CONTENT = "artifact_content"
M.DEP_OBSERVATION = "observation"
M.DEP_ACCEPTED_CLAIM = "accepted_claim"
M.DEP_TRUSTED_BOUNDARY = "trusted_boundary"
M.DEP_ASSUMPTION = "assumption"
M.DEP_EXTERNAL_TOOL_RESULT = "external_tool_result"

-- ── Analysis state ────────────────────────────────────────────────────────

--:: AnalysisState = {
--::   artifacts: { [string]: Artifact },
--::   observations: { [string]: Observation },
--::   claims: { [string]: Claim },
--::   evidence: { [string]: Evidence },
--::   trust_boundaries: { [string]: TrustBoundary }
--:: }

--: () -> AnalysisState
function M.new_state()
	return {
		artifacts = {},
		observations = {},
		claims = {},
		evidence = {},
		trust_boundaries = {},
	}
end

-- An Id key into a state table. We key by space + key so different spaces never
-- collide.
--: (Id) -> string
local function idk(id)
	return id.space .. "/" .. id.key
end

M.idk = idk

--: (AnalysisState, Artifact) -> nil
function M.add_artifact(state, artifact) state.artifacts[idk(artifact.id)] = artifact end
--: (AnalysisState, Observation) -> nil
function M.add_observation(state, observation) state.observations[idk(observation.id)] = observation end
--: (AnalysisState, Claim) -> nil
function M.add_claim(state, claim) state.claims[idk(claim.id)] = claim end
--: (AnalysisState, Evidence) -> nil
function M.add_evidence(state, evidence) state.evidence[idk(evidence.id)] = evidence end
--: (AnalysisState, TrustBoundary) -> nil
function M.add_trust_boundary(state, tb) state.trust_boundaries[idk(tb.id)] = tb end

-- ── Semantics registry ────────────────────────────────────────────────────

--:: SemanticsEntry = {
--::   id: string,
--::   version: string,
--::   claim_predicates: { [string]: boolean },
--::   observation_predicates: { [string]: boolean },
--::   evidence_methods: { [string]: boolean },
--::   trusted_methods: { [string]: boolean },
--::   checker: unknown
--:: }

--:: SemanticsRegistry = { entries: { [string]: SemanticsEntry } }

--: () -> SemanticsRegistry
function M.new_registry()
	return { entries = {} }
end

-- Turn an array of strings into a set { [s] = true }.
--: (string[]) -> { [string]: boolean }
local function set_of(list)
	local s = {} --[[: { [string]: boolean } ]]
	for _, name in ipairs(list or {}) do s[name] = true end
	return s
end

-- Register a hosted semantics. `spec.checker` is the hosted checker function:
--   (CheckContext, Claim, Evidence) -> (result, diagnostic, deps, trust)
-- where result is "accepted" | "rejected" | "unknown".
--: (SemanticsRegistry, { id: string, version: string, claim_predicates: string[], observation_predicates?: string[], evidence_methods: string[], trusted_methods?: string[], checker: unknown }) -> (boolean, string | nil)
function M.register(registry, spec)
	if registry.entries[spec.id] then
		return false, "semantics already registered: " .. spec.id
	end
	registry.entries[spec.id] = {
		id = spec.id,
		version = spec.version,
		claim_predicates = set_of(spec.claim_predicates),
		observation_predicates = set_of(spec.observation_predicates or {}),
		evidence_methods = set_of(spec.evidence_methods),
		trusted_methods = set_of(spec.trusted_methods or {}),
		checker = spec.checker,
	}
	return true
end

--: (SemanticsRegistry, string) -> (SemanticsEntry | nil, string | nil)
function M.lookup(registry, id)
	local e = registry.entries[id]
	if not e then return nil, "no such semantics: " .. id end
	return e
end

-- ── Checker ─────────────────────────────────────────────────────────────────
--
-- The substrate's checker processes a CheckRequest. Evidence may arrive in
-- arbitrary order; the checker finds a valid acceptance order via a worklist
-- that retries until no more evidence can be accepted (a fixpoint over the
-- "accepted" set). Dependency cycles are detected: a cycle yields unknown for
-- the stuck claims with a diagnostic, never nontermination.
--
-- The substrate does not know what makes a claim valid. For each evidence
-- object it calls the registered hosted checker, passing a CheckContext that
-- lets the checker query whether an input claim is already accepted and read
-- artifacts/observations. The hosted checker returns a result class plus the
-- dependencies and trust boundaries it relied on. The substrate records those
-- as first-class Dependency records and aggregates trust.

--:: CheckRequest = {
--::   state: AnalysisState,
--::   requested_claims: Id[],
--::   semantics_registry: SemanticsRegistry,
--::   trust_policy: unknown
--:: }

--:: CheckContext = {
--::   state: AnalysisState,
--::   is_accepted: (Id) -> boolean,
--::   accepted_result: (Id) -> unknown,
--::   get_claim: (Id) -> Claim | nil,
--::   get_artifact: (Id) -> Artifact | nil,
--::   get_observation: (Id) -> Observation | nil,
--::   ACCEPTED: string,
--::   REJECTED: string,
--::   UNKNOWN: string
--:: }

-- The contract a hosted checker satisfies. It returns a result class plus the
-- dependencies and trust boundaries it relied on. All four values are always
-- returned; trailing ones may be nil.
--:: HostedChecker = (ctx: CheckContext, claim: Claim, ev: Evidence) -> (string, string | nil, Dependency[] | nil, unknown[] | nil)

--:: CheckResult = {
--::   accepted_claims: { [string]: Claim },
--::   rejected_claims: { [string]: Claim },
--::   unknown_claims: { [string]: Claim },
--::   diagnostics: string[],
--::   dependency_graph: Dependency[],
--::   trust_summary: { [string]: unknown }
--:: }

-- Validate that every claim/evidence in the request is admissible for its
-- semantics (the registry is a contract, not a wish list): the claim predicate
-- must be listed, and each evidence method must be listed for that semantics.
--: (CheckRequest) -> (boolean, string | nil)
local function validate_request(req)
	local state = req.state
	for _, claim in pairs(state.claims) do
		local entry, err = M.lookup(req.semantics_registry, claim.semantics)
		if not entry then return false, err end
		if not entry.claim_predicates[claim.predicate] then
			return false, "claim predicate not in semantics " .. claim.semantics
				.. ": " .. claim.predicate
		end
	end
	for _, ev in pairs(state.evidence) do
		local claim = state.claims[idk(ev.claim)]
		if not claim then
			return false, "evidence references unknown claim: " .. idk(ev.claim)
		end
		local entry = req.semantics_registry.entries[claim.semantics]
		if entry and not entry.evidence_methods[ev.method] then
			-- Adversarial: registry rejects evidence methods not listed for
			-- the semantics version.
			return false, "evidence method not admitted by semantics "
				.. claim.semantics .. ": " .. ev.method
		end
	end
	return true
end

-- Process the request. Returns a CheckResult (never nil — even on a malformed
-- request it returns a result whose diagnostics record the failure, except for
-- registry-contract violations which are returned as (nil, errmsg) since they
-- indicate the request itself is ill-formed).
--: (CheckRequest) -> (CheckResult | nil, string | nil)
function M.check(req)
	local ok, verr = validate_request(req)
	if not ok then return nil, verr end

	local state = req.state

	-- accepted: claim-key -> result payload returned by the hosted checker.
	local accepted = {} --[[: { [string]: unknown } ]]
	local accepted_claim = {} --[[: { [string]: Claim } ]]
	-- evidence id -> status: nil (untried/blocked), "accepted", "rejected".
	local ev_status = {} --[[: { [string]: string } ]]
	local diagnostics = {} --[[: string[] ]]
	local deps = {} --[[: Dependency[] ]]
	local trust_summary = {} --[[: { [string]: unknown } ]]
	-- Per requested-claim list of trust-boundary entries it relied on.
	local claim_trust = {} --[[: { [string]: unknown[] } ]]

	-- CheckContext: read-only queries the hosted checker uses. is_accepted
	-- answers whether a given claim Id resolves to an already-accepted claim;
	-- a checker MUST NOT treat unknown as proof.
	local ctx --[[: CheckContext ]]
	ctx = {
		state = state,
		ACCEPTED = M.ACCEPTED,
		REJECTED = M.REJECTED,
		UNKNOWN = M.UNKNOWN,
		--: (Id) -> Claim | nil
		get_claim = function(id) return state.claims[idk(id)] end,
		--: (Id) -> Artifact | nil
		get_artifact = function(id) return state.artifacts[idk(id)] end,
		--: (Id) -> Observation | nil
		get_observation = function(id) return state.observations[idk(id)] end,
		-- Is the claim with this Id accepted? Looks up the claim, then its
		-- structural key in the accepted set.
		--: (Id) -> boolean
		is_accepted = function(id)
			local c = state.claims[idk(id)]
			if not c then return false end
			return accepted[claim_key(c)] ~= nil
		end,
		-- Returns the hosted checker's result payload for an accepted claim,
		-- or nil. Used to chain witnesses.
		--: (Id) -> unknown
		accepted_result = function(id)
			local c = state.claims[idk(id)]
			if not c then return nil end
			return accepted[claim_key(c)]
		end,
	}

	-- Try to run one evidence object. Returns the result class.
	--: (Evidence) -> string
	local function run_evidence(ev)
		local claim = state.claims[idk(ev.claim)]
		local entry = req.semantics_registry.entries[claim.semantics]
		local checker = entry.checker --[[: HostedChecker ]]
		local result, diag, ev_deps, ev_trust = checker(ctx, claim, ev)
		if result == M.ACCEPTED then
			local ck = claim_key(claim)
			accepted[ck] = ev.result or true
			accepted_claim[ck] = claim
			for _, d in ipairs(ev_deps or {}) do deps[#deps + 1] = d end
			-- aggregate trust by claim key
			if ev_trust and #ev_trust > 0 then
				local list = claim_trust[ck] or {}
				for _, tb in ipairs(ev_trust) do list[#list + 1] = tb end
				claim_trust[ck] = list
			end
		elseif result == M.REJECTED then
			if diag then diagnostics[#diagnostics + 1] = diag end
			for _, d in ipairs(ev_deps or {}) do deps[#deps + 1] = d end
		end
		return result or M.UNKNOWN
	end

	-- Worklist fixpoint: repeatedly sweep pending evidence. An evidence object
	-- that returns "unknown" (its inputs are not yet accepted) is left pending
	-- and retried on the next sweep. We stop when a sweep accepts nothing new.
	-- This makes the result independent of submission order (scheduling
	-- requirement) and terminates: each sweep either grows `accepted` or the
	-- loop ends. A dependency cycle means a set of evidence is mutually blocked
	-- on each other's claims; no sweep ever accepts them, so they settle as
	-- pending and we report them via a cycle diagnostic below — never loop.
	local progress = true
	while progress do
		progress = false
		for ekey, ev in pairs(state.evidence) do
			if ev_status[ekey] == nil then
				local r = run_evidence(ev)
				if r == M.ACCEPTED then
					ev_status[ekey] = M.ACCEPTED
					progress = true
				elseif r == M.REJECTED then
					ev_status[ekey] = M.REJECTED
					progress = true
				end
				-- r == unknown: leave pending, retry next sweep.
			end
		end
	end

	-- Any evidence still pending after the fixpoint is blocked: its inputs
	-- never became accepted. If a pending evidence object's blocked inputs
	-- trace back to its own claim, that is a dependency cycle. Detect cycles
	-- so we emit a precise diagnostic rather than a generic "unknown".
	--: () -> boolean
	local function detect_cycle()
		-- Build edges among pending evidence: ev -> claims it needs that are
		-- produced (as a claim) by another pending evidence.
		local pending = {} --[[: { [string]: Evidence } ]]
		for ekey, ev in pairs(state.evidence) do
			if ev_status[ekey] == nil then pending[ekey] = ev end
		end
		-- producer map: claim-key -> evidence key (among pending)
		local producer = {} --[[: { [string]: string } ]]
		for ekey, ev in pairs(pending) do
			local c = state.claims[idk(ev.claim)]
			if c then producer[claim_key(c)] = ekey end
		end
		-- DFS over pending evidence following input-claim edges.
		local color = {} --[[: { [string]: number } ]]
		local cycle_found = false
		--: (string) -> nil
		local function visit(ekey)
			if cycle_found then return end
			color[ekey] = 1
			local ev = pending[ekey]
			for _, inp in ipairs(ev.inputs) do
				local ic = state.claims[idk(inp)]
				if ic then
					local pk = producer[claim_key(ic)]
					if pk then
						if color[pk] == 1 then
							cycle_found = true
							return
						elseif color[pk] == nil then
							visit(pk)
						end
					end
				end
			end
			color[ekey] = 2
		end
		for ekey in pairs(pending) do
			if color[ekey] == nil then visit(ekey) end
		end
		return cycle_found
	end

	if detect_cycle() then
		diagnostics[#diagnostics + 1] =
			"dependency cycle among evidence; cyclic claims left unknown"
	end

	-- Classify requested claims.
	local accepted_out = {} --[[: { [string]: Claim } ]]
	local rejected_out = {} --[[: { [string]: Claim } ]]
	local unknown_out = {} --[[: { [string]: Claim } ]]

	-- A claim is rejected only if it has at least one evidence object and ALL
	-- of its evidence objects were rejected (no accepted evidence exists). This
	-- realizes the prop-logic rule: malformed evidence rejects the claim only
	-- when no other evidence object could accept it.
	for _, cid in ipairs(req.requested_claims) do
		local claim = state.claims[idk(cid)]
		if not claim then
			diagnostics[#diagnostics + 1] = "requested claim not in state: " .. idk(cid)
		else
			local ck = claim_key(claim)
			if accepted[ck] ~= nil then
				accepted_out[ck] = claim
				trust_summary[ck] = claim_trust[ck] or {}
			else
				-- gather this claim's evidence statuses
				local has_ev, all_rejected = false, true
				for ekey, ev in pairs(state.evidence) do
					if claim_key(state.claims[idk(ev.claim)]) == ck then
						has_ev = true
						if ev_status[ekey] ~= M.REJECTED then all_rejected = false end
					end
				end
				if has_ev and all_rejected then
					rejected_out[ck] = claim
				else
					unknown_out[ck] = claim
				end
			end
		end
	end

	return {
		accepted_claims = accepted_out,
		rejected_claims = rejected_out,
		unknown_claims = unknown_out,
		diagnostics = diagnostics,
		dependency_graph = deps,
		trust_summary = trust_summary,
	}
end

-- ── Trust summary ─────────────────────────────────────────────────────────
--
-- Per the hosted-checker trust obligation (object model): a hand-written Lua
-- checker's verdict is itself a trusted boundary until checkers are mechanized.
-- This helper builds a trust-summary entry recording "verdict produced by an
-- unverified hosted checker" so that trust is visible the same way every other
-- trusted boundary is. Hosted checkers and harnesses call this to surface the
-- obligation; the substrate does not hide it.
--: (string, string) -> { kind: string, semantics: string, note: string }
function M.unverified_checker_trust(semantics_id, version)
	return {
		kind = "unverified_hosted_checker",
		semantics = semantics_id .. "@" .. (version or "?"),
		note = "verdict produced by an unverified hosted checker (hand-written Lua)",
	}
end

return M
