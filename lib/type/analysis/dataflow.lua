-- Hosted semantics: dataflow.reach.min
--
-- The cyclic/fixpoint-evidence probe from
-- docs/agnostic-static-analysis-fixpoint.md. It IMPORTS the substrate; the
-- substrate does NOT import it. The substrate knows nothing about graphs,
-- lattices, transfer functions, iteration, or fixpoints — this module owns all
-- of it. The substrate stores only opaque graph data, an opaque assignment, and
-- the claims/evidence/dependencies.
--
-- The semantics is forward reachability over a tiny explicit directed graph:
--
--   reachable(n)  iff  n is a source  OR  some predecessor p is reachable.
--
-- Reachability of mutually-cyclic nodes (a -> b -> a) is genuinely mutually
-- dependent, which is exactly the acyclic-evidence-breaking pressure this rung
-- exists to exert.
--
-- THE BET (design doc open question 5): a fixpoint is certified as a POST-HOC
-- WITNESS, not computed by the substrate. An (untrusted) producer proposes a
-- whole assignment (node -> bool). The hosted checker verifies LOCAL CONSISTENCY
-- of that assignment at every node against the transfer rule, reading the
-- asserted values FROM THE WITNESS PAYLOAD — never by consuming neighbour claims
-- as premises. That check is acyclic even though the claims are mutually
-- dependent: there is no claim -> claim input cycle. Each per-node reachable(n)
-- claim then depends on the SINGLE accepted witness claim, not on its neighbours.
--
-- The hosted checker is hand-written Lua, so its verdict is itself a trusted
-- boundary, surfaced via A.unverified_checker_trust on every accepted claim.

local A = require("lib.type.analysis")

local M = {}

M.ID = "dataflow.reach.min"
M.VERSION = "0"

-- ── Graph + assignment grammar (hosted vocabulary, opaque to the substrate) ──
--
-- A graph artifact: a node list and an edge list (from -> to), plus the set of
-- source nodes (nodes reachable a priori). All are plain ArgValue data.
--:: ReachGraph = {
--::   nodes: { [integer]: string },
--::   edges: { [integer]: { from: string, to: string } },
--::   sources: { [integer]: string }
--:: }
--
-- An assignment: a map from node name to asserted reachability. This is the
-- whole fixpoint candidate the witness carries. The substrate sees it as opaque
-- ArgValue; it never learns it is a lattice element.
--:: ReachAssign = { [string]: boolean }

--: ({ [integer]: string }, { [integer]: { from: string, to: string } }, { [integer]: string }) -> ReachGraph
function M.graph(nodes, edges, sources)
	return { nodes = nodes, edges = edges, sources = sources }
end

-- ── Parsers: validate opaque args at the boundary, never cast ──────────────
-- (Same discipline as prop.parse_prop / lambda.parse_term: the hosted checker
-- VALIDATES its inputs rather than trusting their shape — the trust obligation.)

--: (unknown) -> ReachGraph | nil
local function parse_graph(v)
	if type(v) ~= "table" then return nil end
	local nodes_in = v.nodes
	local edges_in = v.edges
	local sources_in = v.sources
	if type(nodes_in) ~= "table" then return nil end
	if type(edges_in) ~= "table" then return nil end
	if type(sources_in) ~= "table" then return nil end
	local nodes = {} --[[: { [integer]: string } ]]
	for _, n in ipairs(nodes_in) do
		if type(n) ~= "string" then return nil end
		nodes[#nodes + 1] = n
	end
	local edges = {} --[[: { [integer]: { from: string, to: string } } ]]
	for _, e in ipairs(edges_in) do
		if type(e) ~= "table" then return nil end
		local from, to = e.from, e.to
		if type(from) ~= "string" or type(to) ~= "string" then return nil end
		edges[#edges + 1] = { from = from, to = to }
	end
	local sources = {} --[[: { [integer]: string } ]]
	for _, s in ipairs(sources_in) do
		if type(s) ~= "string" then return nil end
		sources[#sources + 1] = s
	end
	return { nodes = nodes, edges = edges, sources = sources }
end

-- An assignment value: a table of string -> boolean. Reject any non-boolean
-- member; an "unknown member" (see below) is modelled as an ABSENT key, which
-- the checker treats as not-yet-determined, NOT as false.
--: (unknown) -> ReachAssign | nil
local function parse_assign(v)
	if type(v) ~= "table" then return nil end
	local out = {} --[[: { [string]: boolean } ]]
	for k, val in pairs(v) do
		if type(k) ~= "string" then return nil end
		if type(val) ~= "boolean" then return nil end
		out[k] = val
	end
	return out
end

M.parse_graph = parse_graph
M.parse_assign = parse_assign

-- ── Transfer rule (EVIDENCE-LOCAL hosted vocabulary) ───────────────────────
--
-- The expected reachability of node `n` under assignment `assign`:
--   true iff n is a source, or some predecessor p has assign[p] == true.
-- The substrate never learns this rule; it is local to the checker.
--: (ReachGraph, ReachAssign, string) -> boolean
local function expected_reach(graph, assign, node)
	for _, s in ipairs(graph.sources) do
		if s == node then return true end
	end
	for _, e in ipairs(graph.edges) do
		if e.to == node and assign[e.from] == true then return true end
	end
	return false
end

M.expected_reach = expected_reach

-- Is the proposed assignment LOCALLY CONSISTENT at every node? i.e. is it a
-- fixpoint of the transfer rule? Returns (true) or (false, node) naming the
-- first locally-inconsistent node. The check reads only the assignment and the
-- graph — no neighbour CLAIMS — so it is acyclic by construction.
--: (ReachGraph, ReachAssign) -> (boolean, string | nil)
local function is_fixpoint(graph, assign)
	for _, n in ipairs(graph.nodes) do
		local asserted = assign[n]
		-- Every node must have a determined (boolean) assertion to certify a
		-- TOTAL fixpoint. A missing member is an undetermined value: the witness
		-- is not a complete fixpoint and we report it (used by the unknown case).
		if type(asserted) ~= "boolean" then
			return false, n
		end
		if asserted ~= expected_reach(graph, assign, n) then
			return false, n
		end
	end
	return true
end

M.is_fixpoint = is_fixpoint

-- ── Claim builders ──────────────────────────────────────────────────────────
--
-- fixpoint(graph_ref, assignment): the whole assignment is a simultaneous
-- fixpoint of the reachability transfer rule over the graph artifact.
--: ({ space: string, key: string }, Id, ReachAssign) -> Claim
function M.fixpoint_claim(id, graph_ref, assign)
	return A.claim({
		id = id,
		semantics = M.ID,
		predicate = "fixpoint",
		args = { graph = { space = graph_ref.space, key = graph_ref.key }, assign = assign },
	})
end

-- reachable(graph_ref, node): node is reachable in the graph. Accepted by
-- PROJECTING an accepted fixpoint that asserts the node true.
--: ({ space: string, key: string }, Id, string) -> Claim
function M.reachable_claim(id, graph_ref, node)
	return A.claim({
		id = id,
		semantics = M.ID,
		predicate = "reachable",
		args = { graph = { space = graph_ref.space, key = graph_ref.key }, node = node },
	})
end

-- not_reachable(graph_ref, node): node is NOT reachable. A separate positive
-- claim (like lambda's free_in / not_free_in): unknown for one is not the other.
--: ({ space: string, key: string }, Id, string) -> Claim
function M.not_reachable_claim(id, graph_ref, node)
	return A.claim({
		id = id,
		semantics = M.ID,
		predicate = "not_reachable",
		args = { graph = { space = graph_ref.space, key = graph_ref.key }, node = node },
	})
end

-- ── Helpers ────────────────────────────────────────────────────────────────

--: (unknown) -> Id | nil
local function arg_id(v)
	if type(v) ~= "table" then return nil end
	local space, key = v.space, v.key
	if type(space) ~= "string" or type(key) ~= "string" then return nil end
	return { space = space, key = key }
end

--: (CheckContext, Id) -> ReachGraph | nil
local function graph_of(ctx, ref)
	local art = ctx.get_artifact(ref)
	if not art then return nil end
	return parse_graph(art.content_ref)
end

-- ── Checker ─────────────────────────────────────────────────────────────────

--: () -> unknown
local function trust_note() return A.unverified_checker_trust(M.ID, M.VERSION) end

--: HostedChecker
function M.checker(ctx, claim, ev)
	local method = ev.method
	local args = claim.args
	if type(args) ~= "table" then
		return ctx.REJECTED, "claim args are not a table", nil, nil
	end
	local predicate = claim.predicate

	if predicate == "fixpoint" then
		-- fixpoint_witness: the only way to accept a fixpoint claim. The witness
		-- is SELF-CONTAINED: it reads the graph artifact and the assignment from
		-- the claim args, and checks LOCAL CONSISTENCY at every node. It consumes
		-- NO neighbour claims, so there is no claim -> claim cycle even though the
		-- nodes are mutually dependent.
		if method ~= "fixpoint_witness" then
			return ctx.UNKNOWN, "unknown fixpoint method: " .. tostring(method), nil, nil
		end
		local gref = arg_id(args.graph)
		if not gref then return ctx.REJECTED, "fixpoint missing graph ref", nil, nil end
		local graph = graph_of(ctx, gref)
		if not graph then return ctx.REJECTED, "fixpoint graph artifact malformed", nil, nil end
		local assign = parse_assign(args.assign)
		if not assign then return ctx.REJECTED, "fixpoint assignment malformed", nil, nil end
		local ok, bad = is_fixpoint(graph, assign)
		if not ok then
			-- BROKEN WITNESS: the producer claimed simultaneous consistency but a
			-- member is locally inconsistent (or undetermined). Reject. The
			-- substrate trusts none of the producer's computation — only this
			-- local check.
			return ctx.REJECTED,
				"fixpoint witness is not locally consistent at node " .. tostring(bad), nil, nil
		end
		-- Dependency: the witness depends only on the graph artifact content. No
		-- accepted-claim edge to any neighbour: all the cross-node coupling lives
		-- INSIDE the single assignment the witness certifies.
		local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_ARTIFACT_CONTENT, target = gref }) }
		return ctx.ACCEPTED, nil, deps, { trust_note() }

	elseif predicate == "reachable" or predicate == "not_reachable" then
		-- witness_projection: read off a single node's value from an ACCEPTED
		-- fixpoint claim. The fixpoint claim is the one accepted-claim input; the
		-- per-node claim depends on THE WITNESS, never on neighbour reachable
		-- claims. This is the load-bearing point: all dependencies point at the
		-- witness.
		if method ~= "witness_projection" then
			return ctx.UNKNOWN, "unknown projection method: " .. tostring(method), nil, nil
		end
		local node = args.node
		local gref = arg_id(args.graph)
		if type(node) ~= "string" or not gref then
			return ctx.REJECTED, "reachable claim malformed", nil, nil
		end
		if #ev.inputs ~= 1 then
			return ctx.REJECTED, "witness_projection requires one fixpoint input", nil, nil
		end
		local fp_in = ev.inputs[1]
		local fp_claim = ctx.get_claim(fp_in)
		if not fp_claim or fp_claim.predicate ~= "fixpoint" then
			return ctx.REJECTED, "witness_projection input is not a fixpoint claim", nil, nil
		end
		-- The projection must be over the SAME graph the per-node claim names.
		local fp_args = fp_claim.args
		if type(fp_args) ~= "table" then return ctx.REJECTED, "fixpoint input args malformed", nil, nil end
		local fp_gref = arg_id(fp_args.graph)
		if not fp_gref or fp_gref.space ~= gref.space or fp_gref.key ~= gref.key then
			return ctx.REJECTED, "witness_projection graph does not match the fixpoint graph", nil, nil
		end
		if not ctx.is_accepted(fp_in) then
			-- Witness not yet accepted; retry next sweep. NEVER reject (would make
			-- the result order-dependent — the lambda-rung lesson).
			return ctx.UNKNOWN, nil, nil, nil
		end
		local assign = parse_assign(fp_args.assign)
		if not assign then return ctx.REJECTED, "fixpoint input assignment malformed", nil, nil end
		local asserted = assign[node]
		if type(asserted) ~= "boolean" then
			-- The accepted fixpoint did not determine this node. Cannot project.
			return ctx.REJECTED, "fixpoint does not determine node " .. node, nil, nil
		end
		local want = (predicate == "reachable")
		if asserted ~= want then
			return ctx.REJECTED,
				"fixpoint asserts node " .. node .. " = " .. tostring(asserted)
					.. ", contradicting " .. predicate, nil, nil
		end
		local deps = { A.dependency({ from_claim = claim.id, kind = A.DEP_ACCEPTED_CLAIM, target = fp_in }) }
		return ctx.ACCEPTED, nil, deps, { trust_note() }
	end

	return ctx.REJECTED, "unknown claim predicate: " .. tostring(claim.predicate), nil, nil
end

-- Register dataflow.reach.min in a registry.
--: (SemanticsRegistry) -> (boolean, string | nil)
function M.register(registry)
	return A.register(registry, {
		id = M.ID,
		version = M.VERSION,
		claim_predicates = { "fixpoint", "reachable", "not_reachable" },
		observation_predicates = {},
		evidence_methods = { "fixpoint_witness", "witness_projection" },
		trusted_methods = {},
		checker = M.checker,
	})
end

return M
