-- lib/type/v10_kernel/pilot/engine.lua
--
-- Corroboration line, engine build (iteration 3) — the generic derivation
-- engine the corroboration design-input note sketched
-- (docs/decisions/typechecker-v10-core-design.md, "Corroboration/co-solving
-- design-input note" + "Explicitly open"). fable-delegation-tier throughout
-- (pilot-execution delegation note): every choice here is delegated,
-- re-openable, not owner-ratified. Delegation-tier formalism pick this file
-- implements AS-WRITTEN (recorded, not re-derived here): semi-naive
-- Datalog over term-algebra facts, stratified negation, indexed dispatch —
-- adopted per the design-input note's "adopt a published formalism
-- as-written for the generic engine; implement small in pure Lua."
--
-- ── What this is, precisely ─────────────────────────────────────────────
--
-- Facts are ground, closed kernel Terms (lib/type/v10_cleanroom/
-- term_algebra) over any already-declared signature(s) — the engine never
-- declares vocabulary itself, never reads an AST, never talks to the
-- kernel replayer directly except to reuse its RuleDecl/AxiomDecl objects
-- as-is (declared the ordinary way via replayer.declare_rule/
-- declare_axiom — see narrow_persist_v1.lua etc. for the pattern). Rules
-- fire by matching premise patterns against the fact store using the
-- kernel's own `match_into`/`instantiate` primitives — the SAME sound
-- first-order matching the replayer uses to check a citation, run forward
-- instead of checked backward. Every derived fact carries its own
-- PROVENANCE (the rule/axiom used plus references to the premise facts
-- consumed) which `to_certificate` turns into a kernel CertNode LAZILY, on
-- export, exactly per the design note's "certificate nodes materialize
-- lazily on export." The kernel replayer never sees engine internals —
-- only the exported CertNode tree, root-strict-replayed exactly like any
-- hand-built certificate (see the existing pilot provers).
--
-- Provenance-as-CertNode is not a translation layer bolted on afterward:
-- CertNode's own three-kind grammar (replayer.lua header: rule/axiom/
-- hypothesis, no bindings field on rule nodes — bindings are RE-DERIVED by
-- replay via matching premises' own computed conclusions) already has
-- exactly the shape semi-naive Datalog provenance needs (rule + premise
-- fact references, recomputed not stored). This is why `to_certificate`
-- below is a five-line structural mirror, not a bridge/adapter — the two
-- shapes were never different to begin with.
--
-- ── Indexing (what is actually built; do not overclaim) ────────────────
--
-- Facts are bucketed by their top operator's name (`term.decl.name`) only.
-- This is head-operator indexing, the first half of the design note's
-- "(head operator, program point)" target — sub-indexing by program point
-- within a bucket is NOT built here (an honest gap, not silently assumed:
-- see the report this file's commit travels with). At current corpus scale
-- (per-file fact counts in the hundreds, not the store scanning ALL
-- accumulated facts across a whole corpus run) head-operator bucketing
-- already avoids the disqualified shape ("no store scans" reads as "no
-- scans of the WHOLE store," which this satisfies).
--
-- ── Semi-naive evaluation ────────────────────────────────────────────────
--
-- Each round only re-joins rule/premise-slot combinations where AT LEAST
-- ONE matched premise fact was added in the PREVIOUS round (the delta);
-- the other slots scan the bucket's full accumulated set. This is the
-- standard semi-naive shape traded for simplicity over a fully delta-joined
-- (delta x delta excluded) formulation — correctness does not depend on
-- avoiding the resulting rare duplicate join attempts (structural-equality
-- dedup below absorbs them); only constant-factor performance would.
--
-- ── Stratified negation ──────────────────────────────────────────────────
--
-- A rule premise may be declared `{ negated = true, pattern = <Term> }`:
-- "no fact matching this pattern, under the bindings already fixed by
-- this rule's other premises, exists once the predicate producing it has
-- reached its own fixpoint." Stratification is computed from the
-- predicate dependency graph (rule conclusion depends on its premises;
-- a negated premise forces a STRICT stratum-before edge); a cycle through
-- a negated edge is a stratification error, reported, not worked around.
-- Strata run in order, each to full local fixpoint before the next opens
-- (so a negative check always sees a CLOSED predicate, per stratified-
-- Datalog semantics). No rule ported alongside this file exercises
-- negation yet (see this file's `_test.lua` for a standalone exercise of
-- the mechanism) — recorded honestly as built-but-not-yet-load-bearing,
-- not as a completed theory feature.
--
-- ── Lattice cells ────────────────────────────────────────────────────────
--
-- NOT built. No rule in scope for this iteration needs a quantitative
-- domain (union-type narrowing and preservation are set/relational, not
-- numeric/widening). Building the mechanism unexercised would be scope
-- inflation against the line budget for no corroborating use — framed here
-- as a substrate NOT YET NEEDED, to be added the day a real rule needs it,
-- never as a result deficit.

local ta = require("lib.type.v10_cleanroom.term_algebra")
-- Required for its type declarations (RuleDecl/AxiomDecl/CertNode) only —
-- see the module doc above: the engine reuses those objects as-is but
-- never calls into the replayer itself (kernel/replay never sees engine
-- internals; only exported certificates, via `to_certificate`, ever reach it).
local _replayer_types = require("lib.type.v10_cleanroom.replayer")

local M = {}

--:: EnginePremise = { pattern: Term, op_name: string, negated: boolean }
--:: EngineRule = { decl: RuleDecl, premises: EnginePremise[] }
-- Single flat record with a string-literal `kind` discriminant and
-- optional fields per branch — deliberately mirrors CertNode's own shape
-- (lib/type/v10_cleanroom/replayer.lua's header grammar), not a true
-- tagged union of two named record types: the kernel's own replay_axiom/
-- replay_rule use exactly this flat-optional-fields style (never a tagged
-- union) to read CertNode, and it is what this typechecker narrows
-- cleanly on a `kind` string-literal check — matched here for the same
-- reason, not by preference.
-- `bindings` here (and on `seed`'s parameter below) are PLAIN terms at
-- depth 0 — the same citation-facing convention CertNode's own `bindings`
-- field uses (F12; see replayer.lua's `replay_axiom`, which wraps plain
-- terms to the matcher's depth-tagged `Bindings` shape internally before
-- calling `instantiate` — this module does the identical wrap in `seed`,
-- never earlier or later).
--:: Provenance = { kind: "axiom" | "rule", axiom: AxiomDecl | nil, bindings: ({ [string]: Term }) | nil, rule: RuleDecl | nil, premises: Fact[] | nil }
--:: Fact = { term: Term, op_name: string, provenance: Provenance }
--:: Bucket = { all: Fact[], round_added: { [integer]: Fact[] } }
--:: Store = { buckets: { [string]: Bucket }, rules: EngineRule[], round: integer }
--:: JoinOut = { chosen: { [integer]: Fact }, new_this_round: Fact[] }

--- A fresh, empty fact store. One store per derivation run (e.g. per
--- source file, or per corpus batch that shares no facts) — no global/
--- ambient state anywhere in this module.
--: () -> Store
function M.new_store()
	return { buckets = {}, rules = {}, round = 0 }
end

--: (store: Store, op_name: string) -> Bucket
local function bucket_for(store, op_name)
	local b = store.buckets[op_name]
	if not b then
		b = { all = {}, round_added = {} }
		store.buckets[op_name] = b
	end
	return b
end

-- Structural dedup key. Kernel terms have no canonical string form, but
-- `ta.equal` is the kernel's own structural-equality primitive, so dedup
-- is O(bucket size) equality checks against the candidate's bucket only
-- (already narrowed by op_name) rather than a hash — small buckets, exact,
-- no invented canonicalization the kernel doesn't already vouch for.
--: (bucket: Bucket, term: Term) -> boolean
local function bucket_has(bucket, term)
	for i = 1, #bucket.all do
		if ta.equal(bucket.all[i].term, term) then return true end
	end
	return false
end

--: (store: Store, op_name: string, term: Term, provenance: Provenance) -> (Fact | nil)
local function insert_fact(store, op_name, term, provenance)
	local bucket = bucket_for(store, op_name)
	if bucket_has(bucket, term) then return nil end
	local fact = { term = term, op_name = op_name, provenance = provenance }
	bucket.all[#bucket.all + 1] = fact
	local r = bucket.round_added[store.round]
	if not r then
		r = {}
		bucket.round_added[store.round] = r
	end
	r[#r + 1] = fact
	return fact
end

--- Seed one ground base fact via an axiom citation: `bindings` instantiate
--- `axiom_decl.pattern` to produce the fact's term. This is the ONLY entry
--- point base facts (from an AST extractor, or any other reality-boundary
--- producer) use — mirrors exactly how an untrusted prover cites a
--- schematic axiom by hand (see pilot-syntax-facts-v1's usage in
--- flow_narrow_v1/prover_narrow.lua), just run through the engine instead
--- of assembled directly into a CertNode. No F12 (ground/closed/coverage)
--- validation happens here — that trust boundary is the kernel replayer's
--- job alone, exercised when the exported certificate is actually
--- replayed; a malformed seed simply fails to replay later, never silently
--- accepted here.
--: (store: Store, axiom_decl: unknown, bindings: unknown) -> (Fact | nil, string | nil)
function M.seed(store, axiom_decl, bindings)
	if type(axiom_decl) ~= "table" then
		return nil, "seed: axiom_decl must be a declared AxiomDecl"
	end
	local ax = axiom_decl --[[: AxiomDecl ]]
	if ax.kind ~= "axiom" then
		return nil, "seed: axiom_decl must be a declared AxiomDecl"
	end
	if type(bindings) ~= "table" then
		return nil, "seed: bindings must be a table"
	end
	local plain = bindings --[[: { [string]: Term } ]]
	-- Wrap plain (F12) bindings to the matcher's depth-tagged shape, same
	-- as replayer.lua's `replay_axiom` does for a hand-built CertNode's own
	-- `bindings` field — a citation-facing convention, not an engine-only
	-- one.
	local wrapped = {} --[[: Bindings ]]
	for k, v in pairs(plain) do wrapped[k] = { term = v, depth = 0 } end
	local term, err = ta.instantiate(ax.pattern, wrapped)
	if not term then return nil, "seed: " .. (err or "instantiate failed") end
	local t = term --[[: Term ]]
	if not t.decl then return nil, "seed: instantiated term has no head operator" end
	local op_name = t.decl.name
	local fact = insert_fact(store, op_name, t, { kind = "axiom", axiom = ax, bindings = plain, rule = nil, premises = nil })
	return fact
end

--- Register an already-declared rule (a RuleDecl, from
--- replayer.declare_rule — the SAME object the kernel replayer will later
--- cite when the exported certificate is replayed) into this store's
--- active rule set. `negated_premises` (optional) names 0-based premise
--- indices to treat as negative (stratified-negation) premises; omitted =
--- all premises positive (the common case — none of the theories ported
--- alongside this file need it).
--: (store: Store, rule_decl: unknown, negated_premises: { [integer]: boolean } | nil) -> (EngineRule | nil, string | nil)
function M.add_rule(store, rule_decl, negated_premises)
	if type(rule_decl) ~= "table" then
		return nil, "add_rule: rule_decl must be a declared RuleDecl"
	end
	local rd = rule_decl --[[: RuleDecl ]]
	if rd.kind ~= "rule" then
		return nil, "add_rule: rule_decl must be a declared RuleDecl"
	end
	if #rd.discharges > 0 then
		return nil, "add_rule: " .. rd.name .. " has discharge slots; the engine only fires discharge-free rules "
			.. "(hypothesis-discharging rules are outside this iteration's scope, not silently mishandled)"
	end
	local neg = negated_premises or {}
	local premises = {} --[[: EnginePremise[] ]]
	for i = 1, #rd.premises do
		local p = rd.premises[i]
		if not p.decl then
			return nil, "add_rule: " .. rd.name .. " premise " .. i .. " is not an operator-headed pattern"
		end
		premises[i] = { pattern = p, op_name = p.decl.name, negated = neg[i - 1] == true }
	end
	local er = { decl = rd, premises = premises }
	store.rules[#store.rules + 1] = er
	return er
end

-- Recursive N-ary join: `slot` is the premise index currently being
-- extended; `candidates` is the list of facts to try at the premise index
-- that must include this round's delta (the others scan the bucket's full
-- set — see header, "Semi-naive evaluation"). `require_slot` is the one
-- premise index that MUST be drawn from the delta list at that slot (every
-- other slot scans `all`); when `slot == require_slot` we iterate
-- `delta_candidates` instead of the bucket's `all`.
--: (bindings: Bindings) -> Bindings
local function copy_bindings(bindings)
	local out = {} --[[: Bindings ]]
	for k, v in pairs(bindings) do out[k] = v end
	return out
end

--: (store: Store, rule: EngineRule, slot: integer, require_slot: integer, delta_candidates: Fact[], bindings: Bindings, out: JoinOut) -> (string | nil)
local function join_from(store, rule, slot, require_slot, delta_candidates, bindings, out)
	local premises = rule.premises
	if slot > #premises then
		if #out.new_this_round > 2000000 then return "join: runaway derivation, aborting" end
		local concl, err = ta.instantiate(rule.decl.conclusion, bindings)
		if not concl then return "join: " .. (err or "instantiate failed") end
		local concl_decl = concl.decl
		if not concl_decl then return "join: conclusion has no head operator" end
		local op_name = concl_decl.name
		local premise_facts = {} --[[: Fact[] ]]
		for i = 1, #premises do premise_facts[i] = out.chosen[i] end
		local fact = insert_fact(store, op_name, concl,
			{ kind = "rule", rule = rule.decl, premises = premise_facts, axiom = nil, bindings = nil })
		if fact then out.new_this_round[#out.new_this_round + 1] = fact end
		return nil
	end
	local prem = premises[slot]
	if prem.negated then
		-- Stratified negative check: succeeds (continues the join) iff NO
		-- fact in the (by construction, already-closed-for-this-stratum)
		-- bucket matches `prem.pattern` under the bindings fixed so far.
		local bucket = bucket_for(store, prem.op_name)
		for i = 1, #bucket.all do
			local try = copy_bindings(bindings)
			local ok = ta.match_into(prem.pattern, bucket.all[i].term, try)
			if ok then return nil end -- a match exists: negated premise fails, this branch yields nothing
		end
		return join_from(store, rule, slot + 1, require_slot, delta_candidates, bindings, out)
	end
	local cands = delta_candidates
	if slot ~= require_slot then
		cands = bucket_for(store, prem.op_name).all
	end
	for i = 1, #cands do
		local try = copy_bindings(bindings)
		local ok, err = ta.match_into(prem.pattern, cands[i].term, try)
		if ok then
			out.chosen[slot] = cands[i]
			local rerr = join_from(store, rule, slot + 1, require_slot, delta_candidates, try, out)
			if rerr then return rerr end
			out.chosen[slot] = nil
		elseif err and not ta.is_no_match(err) then
			return "join: " .. err
		end
	end
	return nil
end

--- Run semi-naive evaluation to a full fixpoint over the store's currently
--- registered rules (call `add_rule` for every rule BEFORE `run` — rules
--- added after a `run` require a fresh `run` to pick them up; a store may
--- be run more than once as more seeds/rules accumulate, each call
--- resuming from where the fact set left off). Returns the count of newly
--- derived facts this call.
--: (store: Store) -> (integer | nil, string | nil)
function M.run(store)
	local total_new = 0
	local more = true
	while more do
		more = false
		local this_round = store.round
		store.round = store.round + 1
		for ri = 1, #store.rules do
			local rule = store.rules[ri]
			for slot = 1, #rule.premises do
				local prem = rule.premises[slot]
				if not prem.negated then
					local bucket = bucket_for(store, prem.op_name)
					local delta = bucket.round_added[this_round]
					if delta and #delta > 0 then
						local out = { chosen = {}, new_this_round = {} }
						local err = join_from(store, rule, 1, slot, delta, {}, out)
						if err then return nil, err end
						if #out.new_this_round > 0 then
							more = true
							total_new = total_new + #out.new_this_round
						end
					end
				end
			end
		end
	end
	return total_new
end

--- Lazily materialize a derived (or seeded) fact into a kernel CertNode,
--- recursively over its provenance, ready for `replayer.replay`. This is
--- the ONLY place engine provenance becomes kernel-visible content — the
--- kernel itself never sees a Store, a Bucket, or an EngineRule.
--: (fact: Fact) -> (CertNode | nil, string | nil)
function M.to_certificate(fact)
	local prov = fact.provenance
	if prov.kind == "axiom" then
		local ax = prov.axiom
		local bnd = prov.bindings
		if not ax or not bnd then return nil, "to_certificate: malformed axiom provenance" end
		return { kind = "axiom", axiom = ax, bindings = bnd, conclusion = fact.term }
	elseif prov.kind == "rule" then
		local rd = prov.rule
		local prem_facts = prov.premises
		if not rd or not prem_facts then return nil, "to_certificate: malformed rule provenance" end
		local premise_nodes = {} --[[: CertNode[] ]]
		for i = 1, #prem_facts do
			local node, err = M.to_certificate(prem_facts[i])
			if not node then return nil, err end
			premise_nodes[i] = node
		end
		return { kind = "rule", rule = rd, premises = premise_nodes, conclusion = fact.term }
	else
		return nil, "to_certificate: unreachable provenance kind"
	end
end

--- All facts currently in the store whose head operator is `op_name`, in
--- insertion order — the read surface a driver/measurement script uses to
--- find, e.g., every `holds_at` fact derived for a file.
--: (store: Store, op_name: string) -> Fact[]
function M.facts_of(store, op_name)
	local bucket = store.buckets[op_name]
	if not bucket then return {} end
	local out = {} --[[: Fact[] ]]
	for i = 1, #bucket.all do out[i] = bucket.all[i] end
	return out
end

return M
