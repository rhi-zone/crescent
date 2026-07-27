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
--   4. hypothesis discharge every hypothesis id any reachable node
--                           `assumes` has a matching `discharges` entry on
--                           some reachable node, and is defined in
--                           certificate.hypotheses. A hypothesis cited but
--                           never discharged is a silent assumption, and is
--                           rejected.
--
-- The kernel never inspects `conclusion` payloads beyond checking they
-- exist; it has zero knowledge of what "var", "abs", "app", "let," or
-- unification mean, or what a "type" is. See NOTATION.md for the full
-- certificate grammar.
--
-- STATED SIMPLIFICATION (dinner-sized prototype, not a design closure):
-- hypothesis discharge is checked by ID MATCH ANYWHERE IN THE REACHABLE SET,
-- not by verifying the discharging node is a lexical ancestor of the
-- assuming node. Real scoping / shadowing / capture-avoidance (alpha-
-- stability, binder identity) is exactly the machinery the rejected
-- `lib/type/framework/` attempt spent most of its complexity on (see
-- docs/typechecker-framework-postmortem.md) and is explicitly out of scope
-- here — see TODO.md.

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

--: (Certificate, { [string]: boolean, ... }) -> (boolean | nil, string | nil)
local function check_discharge(cert, reachable)
	local discharged = {}
	for node_id in pairs(reachable) do
		local node = cert.nodes[node_id]
		for _, hyp_id in ipairs(node.discharges or {}) do
			discharged[hyp_id] = true
		end
	end
	for node_id in pairs(reachable) do
		local node = cert.nodes[node_id]
		for _, hyp_id in ipairs(node.assumes or {}) do
			if not (cert.hypotheses or {})[hyp_id] then
				return nil, path_err(node_id, "assumes undefined hypothesis '" .. tostring(hyp_id) .. "'")
			end
			if not discharged[hyp_id] then
				return nil, path_err(node_id, "assumes hypothesis '" .. tostring(hyp_id)
					.. "' that is never discharged in this certificate")
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

	local ok, discharge_err = check_discharge(cert, reachable)
	if not ok then return nil, discharge_err end

	return true
end

return M
