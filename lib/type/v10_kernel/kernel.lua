-- lib/type/v10_kernel/kernel.lua
-- The v10 trust core: a domain-blind certificate REPLAYER.
--
-- This module derives nothing. It is handed a certificate some untrusted
-- producer (e.g. w.lua's Algorithm W inferencer) already built, and it
-- checks four things, all purely structural:
--
--   1. citation validity    every `rule` a node cites resolves to a schema
--                            actually registered in the theory's registry.
--   2. rule instantiation   the node's shape (judgment, premise count,
--                            assumes/discharges usage) matches what the
--                            cited schema declares.
--   3. well-foundedness     the premise graph has no cycle (no node's
--                            justification depends, directly or
--                            transitively, on itself).
--   4. hypothesis discharge every hypothesis id a node `assumes` is
--                           discharged by an ANCESTOR of that node — a node
--                           on every root-to-node path through `premises` —
--                           and is defined in certificate.hypotheses. A
--                           hypothesis assumed but not discharged by an
--                           enclosing node, on every path that reaches it,
--                           is a silent (or partially-scoped) assumption,
--                           and is rejected.
--
-- The kernel never inspects `conclusion` payloads beyond checking they
-- exist; it has zero knowledge of what "var", "abs", "app", "let," or
-- unification mean, or what a "type" is. See NOTATION.md for the full
-- certificate grammar.
--
-- DERIVATION SHAPE: a certificate's `premises` edges form a DAG, not
-- necessarily a tree — a node MAY be listed as a premise of more than one
-- parent (a shared sub-derivation). A tree is the special case where every
-- node has exactly one parent; neither W's nor J's producers ever emit a
-- shared node today (each is built fresh per source-term occurrence), so
-- this is a generalization with no effect on any certificate either theory
-- currently produces. When a node IS shared, hypothesis discharge is
-- checked against the INTERSECTION of what's discharged along every
-- distinct root-to-node path — i.e. a shared node's assumption must be
-- covered by an ancestor on EACH path that reaches it, not merely one. This
-- is what makes a DAG certificate mean the same thing as the (possibly much
-- larger) tree you'd get by unfolding each shared node into one copy per
-- incoming path: each unfolded copy would independently need its own
-- ancestor-discharge, so the shared node must satisfy all of them at once.
-- Well-foundedness (no node depends on itself, `walk`'s cycle check) still
-- guarantees the DAG has no cycles, so "every path" is always a finite set.

local registry_mod = require("lib.type.v10_kernel.registry")

--:: require "lib.type.v10_kernel.registry"

local M = {}

--:: Node = { id: string, rule: string, judgment: string, locus: string, conclusion: unknown, premises: { [integer]: string, ... }, assumes?: { [integer]: string, ... }, discharges?: { [integer]: string, ... } }
--:: Hypothesis = { id: string, judgment: string, payload: unknown }
--:: Certificate = { theory: string, nodes: { [string]: Node, ... }, hypotheses: { [string]: Hypothesis, ... }, root: string }

--: (string, string) -> string
local function path_err(node_id, msg)
	return "node " .. tostring(node_id) .. ": " .. msg
end

-- Walk the premise graph from `root`, checking citation validity, rule
-- instantiation, and well-foundedness in one DFS. Returns the set of node
-- ids reachable from root (what the derivation structurally depends on), or
-- (nil, err) on the first violation.
--: (Certificate, Registry, string) -> ({ [string]: boolean, ... } | nil, string | nil)
local function walk(cert, registry, root)
	local reachable = {}
	local color = {} --[[: { [string]: string } ]] -- nil = unvisited, "visiting" = on the current DFS stack, "done" = closed

	local visit
	--: (string) -> (boolean | nil, string | nil)
	visit = function(node_id)
		if color[node_id] == "done" then return true end
		if color[node_id] == "visiting" then
			return nil, path_err(node_id, "well-foundedness violation: cites itself through a cycle")
		end
		local node = cert.nodes[node_id]
		if not node then
			return nil, path_err(node_id, "certificate cites a node id that does not exist")
		end
		color[node_id] = "visiting"
		reachable[node_id] = true

		local schema = registry_mod.lookup(registry, node.rule)
		if not schema then
			return nil, path_err(node_id, "citation to unregistered rule schema '" .. tostring(node.rule) .. "'")
		end
		-- TYPECHECKER WORKAROUND: the natural code reads `schema.name` /
		-- `schema.judgment` / `schema.arity` directly wherever needed. But
		-- concatenating (`..`) a field pulled from a value whose type comes
		-- from a *different module's* `--:: require`-imported alias
		-- (RuleSchema, from registry.lua) makes the typechecker report that
		-- field as type `never` at the point of concatenation only — plain
		-- field access, assignment, and `return` of the same value all
		-- typecheck fine. A checked re-cast (not a force cast) through a
		-- local of the same declared type clears it. Minimal repro kept in
		-- session notes, not committed. TODO.md has the tracking entry.
		local schema_name = schema.name --[[: string]]
		local schema_judgment = schema.judgment --[[: string]]
		local schema_arity = schema.arity --[[: integer]]
		local schema_assumes = schema.assumes
		local schema_discharges = schema.discharges
		if schema_judgment ~= node.judgment then
			return nil, path_err(node_id, "judgment '" .. tostring(node.judgment)
				.. "' does not match schema '" .. schema_name .. "' which concludes '" .. schema_judgment .. "'")
		end
		local premises = node.premises or {}
		if #premises ~= schema_arity then
			return nil, path_err(node_id, "schema '" .. schema_name .. "' declares arity " .. tostring(schema_arity)
				.. " but node has " .. #premises .. " premise(s)")
		end
		if node.assumes and not schema_assumes then
			return nil, path_err(node_id, "schema '" .. schema_name .. "' does not permit hypothesis assumption")
		end
		if node.discharges and not schema_discharges then
			return nil, path_err(node_id, "schema '" .. schema_name .. "' does not permit hypothesis discharge")
		end
		if node.conclusion == nil then
			return nil, path_err(node_id, "node has no conclusion")
		end

		for _, premise_id in ipairs(premises) do
			local ok, err = visit(premise_id)
			if not ok then return nil, err end
		end

		color[node_id] = "done"
		return true
	end

	local ok, err = visit(root)
	if not ok then return nil, err end
	return reachable
end

-- Topological order (parents before children) of `reachable`, computed as a
-- DFS post-order over `premises` edges from `root`, reversed. Assumes
-- `reachable` is already known acyclic (walk's well-foundedness check
-- already ran against the same edges) — this pass never re-detects cycles,
-- it only orders what's already been proven a DAG. A node with more than
-- one parent is visited (and appended) exactly once, on whichever parent's
-- premise list reaches it first during the DFS; that's safe here because
-- topological order is what's needed, not a specific path, and any DFS
-- order over an acyclic graph yields a valid one.
--: (Certificate, { [string]: boolean, ... }, string) -> { [integer]: string, ... }
local function topo_order(cert, reachable, root)
	local postorder = {}
	local done = {}
	local visit
	--: (string) -> ()
	visit = function(node_id)
		if done[node_id] then return end
		done[node_id] = true
		local node = cert.nodes[node_id]
		for _, premise_id in ipairs(node.premises or {}) do
			visit(premise_id)
		end
		postorder[#postorder + 1] = node_id
	end
	visit(root)
	local topo = {}
	for i = #postorder, 1, -1 do
		topo[#topo + 1] = postorder[i]
	end
	return topo
end

-- For every node reachable from `root`, require that each hypothesis id it
-- `assumes` (a) is defined in `cert.hypotheses`, and (b) is discharged by an
-- ANCESTOR of that node on EVERY root-to-node path through `premises` — not
-- merely present in some `discharges` list anywhere in the certificate, and
-- not merely on some (rather than every) path when the node is shared by
-- more than one parent. See kernel.lua's header for why "every path" is the
-- correct scoping rule for a DAG-shaped derivation.
--
-- Implementation: walk `reachable` in topological order (parents before
-- children). For each node, track the discharge set carried in from its
-- ancestors — the intersection, across every incoming premises-edge, of
-- (the carrying parent's own ancestor-discharge set UNION that parent's own
-- `discharges`). A node with a single parent just inherits that parent's
-- set (intersection of one set is itself); the intersection is what
-- enforces "every path" once a node has more than one.
--: (Certificate, { [string]: boolean, ... }, string) -> (boolean | nil, string | nil)
local function check_discharge(cert, reachable, root)
	local topo = topo_order(cert, reachable, root)

	--:: HypSet = { [string]: boolean, ... }
	local ancestor_discharges = {} --[[: { [string]: HypSet } ]]
	ancestor_discharges[root] = {}

	for _, node_id in ipairs(topo) do
		local node = cert.nodes[node_id]
		local carried = {} --[[: HypSet ]]
		for hyp_id in pairs(ancestor_discharges[node_id] or {}) do carried[hyp_id] = true end
		for _, hyp_id in ipairs(node.discharges or {}) do carried[hyp_id] = true end

		for _, premise_id in ipairs(node.premises or {}) do
			local existing = ancestor_discharges[premise_id]
			if existing == nil then
				local copy = {} --[[: HypSet ]]
				for hyp_id in pairs(carried) do copy[hyp_id] = true end
				ancestor_discharges[premise_id] = copy
			else
				local intersected = {} --[[: HypSet ]]
				for hyp_id in pairs(existing) do
					if carried[hyp_id] then intersected[hyp_id] = true end
				end
				ancestor_discharges[premise_id] = intersected
			end
		end
	end

	for node_id in pairs(reachable) do
		local node = cert.nodes[node_id]
		local node_ads = ancestor_discharges[node_id] or {}
		for _, hyp_id in ipairs(node.assumes or {}) do
			if not (cert.hypotheses or {})[hyp_id] then
				return nil, path_err(node_id, "assumes undefined hypothesis '" .. tostring(hyp_id) .. "'")
			end
			if not node_ads[hyp_id] then
				return nil, path_err(node_id, "assumes hypothesis '" .. tostring(hyp_id)
					.. "' that is not discharged by an ancestor on every path reaching this node")
			end
		end
	end
	return true
end

-- Replay `cert` against `registry`. Returns (true, nil) if every citation
-- resolves, every rule instantiation matches its schema, the derivation is
-- well-founded, and every assumed hypothesis is discharged. Returns
-- (nil, err) describing the first structural violation found. Never
-- throws — a malformed certificate is a data error, not a bug.
--: (Certificate, Registry) -> (boolean | nil, string | nil)
function M.replay(cert, registry)
	if type(cert) ~= "table" then return nil, "certificate must be a table" end
	if type(registry) ~= "table" then return nil, "registry must be a table" end
	if cert.theory ~= registry.theory then
		return nil, "certificate declares theory '" .. tostring(cert.theory)
			.. "' but registry is for '" .. tostring(registry.theory) .. "'"
	end
	local root = cert.root
	if type(root) ~= "string" then return nil, "certificate.root must be a node id" end
	if type(cert.nodes) ~= "table" then return nil, "certificate.nodes must be a table" end

	local reachable, err = walk(cert, registry, root)
	if not reachable then return nil, err end

	local ok, discharge_err = check_discharge(cert, reachable, root)
	if not ok then return nil, discharge_err end

	return true
end

return M
