-- Shared MR0 verifier fixtures.
--
-- These are semantic certificate fixtures, not source-code fixtures. A rejected
-- fixture is useful when it pins an MR0 boundary the verifier must not infer.

--:: MR0FixtureInputs = { type?: string, producer?: string, consumer?: string, a?: string, b?: string, arm_index?: integer, value?: unknown, exported_claim?: unknown, primitive_name?: string, ... }
--:: MR0FixtureNode = { node_id: string, family: string, rule: string, inputs?: MR0FixtureInputs, outputs: unknown, premises?: { [integer]: string, ... }, ... }
--:: MR0FixtureTerm = { term_id: string, sort: string, payload: unknown, ... }
--:: MR0FixtureRoot = { kind: string, subject: string, proof: string, ... }
--:: MR0FixtureCert = { version: string, target: { id: string, ... }, terms: { [integer]: MR0FixtureTerm, ... } | nil, nodes: { [integer]: MR0FixtureNode, ... }, roots: { [integer]: MR0FixtureRoot, ... }, ... }
--:: MR0Fixture = { name: string, expect: "accept" | "reject", reason: string, contains: string | nil, cert: MR0FixtureCert }

local M = {}

local lit_int = { term_id = "t_lit_1", sort = "type", payload = { tag = "literal", base = "integer", value = 1 } }
local lit_num_half = { term_id = "t_lit_1_5", sort = "type", payload = { tag = "literal", base = "number", value = 1.5 } }
local integer = { term_id = "t_integer", sort = "type", payload = "integer" }
local number = { term_id = "t_number", sort = "type", payload = "number" }
local string_t = { term_id = "t_string", sort = "type", payload = "string" }
local unknown = { term_id = "t_unknown", sort = "type", payload = "unknown" }
local lit_a = { term_id = "t_lit_a", sort = "type", payload = { tag = "literal", base = "string", value = "a" } }
local setmetatable_cap = {
	term_id = "t_setmetatable_cap",
	sort = "type",
	payload = { tag = "primitive_cap", name = "$SetMetatable" },
}
local union_ab = {
	term_id = "t_union_ab",
	sort = "type",
	payload = {
		tag = "union",
		arms = {
			{ tag = "literal", base = "string", value = "a" },
			{ tag = "literal", base = "string", value = "b" },
		},
	},
}

--: ({ [integer]: MR0FixtureNode, ... }, { [integer]: MR0FixtureRoot, ... } | nil, { [integer]: MR0FixtureTerm, ... } | nil) -> MR0FixtureCert
local function cert(nodes, roots, terms)
	local last_node = nodes[#nodes]
	local proof = last_node and last_node.node_id or "<missing>"
	return {
		version = "v7-mr0",
		target = { id = "luajit51-crescent", digest = "test-target", table_digest = "test-target-table" },
		sources = { { source_id = "fixture", digest = "test-source" } },
		declarations = {},
		terms = terms or {},
		contexts = {},
		nodes = nodes,
		roots = roots or { { kind = "local_annotation", subject = "fixture", proof = proof } },
	}
end

--: (string, string, MR0FixtureCert) -> MR0Fixture
local function accept(name, reason, c)
	return { name = name, expect = "accept", reason = reason, contains = nil, cert = c }
end

--: (string, string, string, MR0FixtureCert) -> MR0Fixture
local function reject(name, reason, contains, c)
	return { name = name, expect = "reject", reason = reason, contains = contains, cert = c }
end

M.cases = {
	accept("local number annotation accepts literal integer",
		"`local x: number = 1` is justified by literal-to-base and integer-to-number.",
		cert({
			{
				node_id = "n_wf_lit",
				family = "WFNode",
				rule = "wf_type",
				inputs = { type = "t_lit_1" },
				outputs = { ok = true },
			},
			{
				node_id = "n_lit_base",
				family = "SubNode",
				rule = "literal_to_base",
				inputs = { producer = "t_lit_1", consumer = "t_integer" },
				premises = { "n_wf_lit" },
				outputs = { ok = true },
			},
			{
				node_id = "n_int_num",
				family = "SubNode",
				rule = "integer_to_number",
				inputs = { producer = "t_integer", consumer = "t_number" },
				premises = { "n_lit_base" },
				outputs = { ok = true },
			},
		}, nil, { lit_int, integer, number })),

	accept("union right arm is named",
		"`local x: 'a' | 'b' = 'a'` names the admitted union arm; verifier does not search.",
		cert({
			{
				node_id = "n_union",
				family = "SubNode",
				rule = "union_right_arm",
				inputs = { producer = "t_lit_a", consumer = "t_union_ab", arm_index = 1 },
				outputs = { ok = true },
			},
		}, nil, { lit_a, union_ab })),

	accept("trusted primitive capability value is explicit unsafe input",
		"A primitive capability can enter MR0 only through a trusted boundary node.",
		cert({
			{
				node_id = "n_decl",
				family = "UnsafeNode",
				rule = "trusted_decl_value",
				inputs = {
					exported_claim = {
						type = { tag = "primitive_cap", name = "$SetMetatable" },
						name = "setmetatable_alias",
					},
				},
				outputs = {
					claim = {
						type = { tag = "primitive_cap", name = "$SetMetatable" },
						name = "setmetatable_alias",
					},
				},
			},
		}, { { kind = "unsafe_export", subject = "setmetatable_alias", proof = "n_decl" } }, { setmetatable_cap })),

	reject("integer annotation rejects non-integer number literal",
		"`local x: integer = 1.5` cannot use literal-to-base because the literal base is number.",
		"literal base",
		cert({
			{
				node_id = "n_bad",
				family = "SubNode",
				rule = "literal_to_base",
				inputs = { producer = "t_lit_1_5", consumer = "t_integer" },
				outputs = { ok = true },
			},
		}, nil, { lit_num_half, integer })),

	reject("union arm mismatch rejects",
		"A named union arm is not enough; the source must match that exact arm.",
		"union_right_arm",
		cert({
			{
				node_id = "n_union_bad",
				family = "SubNode",
				rule = "union_right_arm",
				inputs = { producer = "t_lit_a", consumer = "t_union_ab", arm_index = 2 },
				outputs = { ok = true },
			},
		}, nil, { lit_a, union_ab })),

	reject("wrong target is outside this verifier",
		"MR0 spike is currently tied to the concrete luajit51-crescent target input.",
		"target",
		(function()
			local c = cert({
				{
					node_id = "n_wf",
					family = "WFNode",
					rule = "wf_type",
					inputs = { type = "t_unknown" },
					outputs = { ok = true },
				},
			}, nil, { unknown })
			c.target = { id = "lua54", digest = "test-target" }
			return c
		end)()),

	reject("closed function call replay is not implemented in spike",
		"CallNode is in MR0's design, but not admitted by this verifier until pack/call replay lands.",
		"unsupported node family",
		cert({
			{
				node_id = "n_call",
				family = "CallNode",
				rule = "call_arrow",
				inputs = {},
				outputs = {},
			},
		})),

	reject("overload export replay is not implemented in spike",
		"Overload export must check every branch body; accepting it before GenericNode replay would be ad hoc.",
		"unsupported node family",
		cert({
			{
				node_id = "n_overload",
				family = "GenericNode",
				rule = "overload_export_all_branches",
				inputs = {},
				outputs = {},
			},
		}, { { kind = "overload_export", subject = "f", proof = "n_overload" } })),

	reject("metatable index read is outside MR0 spike",
		"`__index` chain walking is explicitly excluded; unsupported identity replay must reject.",
		"unsupported node family",
		cert({
			{
				node_id = "n_index",
				family = "IdentityNode",
				rule = "metatable_index_read",
				inputs = {},
				outputs = {},
			},
		})),

	reject("rawlen primitive is not in MR0 primitive set",
		"`rawlen` is not one of MR0's admitted primitive capabilities.",
		"unsupported node family",
		cert({
			{
				node_id = "n_rawlen",
				family = "PrimitiveCallNode",
				rule = "primitive_call",
				inputs = { primitive_name = "$RawLen" },
				outputs = {},
			},
		})),

	reject("type predicate narrowing is not implemented in spike",
		"`type(x) == 'string'` requires predicate/fact-transition replay, not source-name magic.",
		"unsupported",
		cert({
			{
				node_id = "n_type_narrow",
				family = "ExprNode",
				rule = "type_predicate_narrow",
				inputs = {},
				outputs = {},
			},
		}, nil, { string_t })),

	reject("unresolved require is not a value claim",
		"`require` is an external declaration/import bridge concern, not verifier fallback to unknown.",
		"unsupported",
		cert({
			{
				node_id = "n_require",
				family = "ExprNode",
				rule = "require_unresolved",
				inputs = {},
				outputs = {},
			},
		})),
}

return M
