local T = require("lib.test.assert")
local mr0 = require("lib.type.v7_mr0")
local canonical = require("lib.type.v7_mr0.canonical")
local fixtures = require("lib.type.v7_mr0.fixtures")

--:: MR0TestInputs = { type?: string, producer?: string, consumer?: string, a?: string, b?: string, arm_index?: integer, value?: unknown, exported_claim?: unknown, ... }
--:: MR0TestNode = { node_id: string, family: string, rule: string, inputs?: MR0TestInputs, outputs: unknown, premises?: { [integer]: string, ... }, ... }
--:: MR0TestTerm = { term_id: string, sort: string, payload: unknown, ... }
--:: MR0TestRoot = { kind: string, subject: string, proof: string, ... }
--:: MR0TestCert = { version: string, target: { id: string, ... }, terms: { [integer]: MR0TestTerm, ... } | nil, nodes: { [integer]: MR0TestNode, ... }, roots: { [integer]: MR0TestRoot, ... }, ... }

--: ({ [integer]: MR0TestNode, ... }, { [integer]: MR0TestRoot, ... } | nil, { [integer]: MR0TestTerm, ... } | nil) -> MR0TestCert
local function cert(nodes, roots, terms)
	local last_node = nodes[#nodes]
	local proof = last_node and last_node.node_id or "<missing>"
	return {
		version = "v7-mr0",
		target = { id = "luajit51-crescent", digest = "test-target" },
		sources = { { source_id = "test", digest = "test-source" } },
		declarations = {},
		terms = terms or {},
		contexts = {},
		nodes = nodes,
		roots = roots or { { kind = "local_annotation", subject = "x", proof = proof } },
	}
end

local lit_int = { term_id = "t_lit_1", sort = "type", payload = { tag = "literal", base = "integer", value = 1 } }
local integer = { term_id = "t_integer", sort = "type", payload = "integer" }
local number = { term_id = "t_number", sort = "type", payload = "number" }
local unknown = { term_id = "t_unknown", sort = "type", payload = "unknown" }
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
local lit_a = { term_id = "t_lit_a", sort = "type", payload = { tag = "literal", base = "string", value = "a" } }

T.describe("type.v7_mr0 verifier spike", function()
	T.describe("canonical payloads", function()
		T.it("serializes maps independent of insertion order", function()
			local a = { b = 2, a = { "x", true } }
			local b = { a = { "x", true }, b = 2 }
			local sa, ea = canonical.serialize(a)
			local sb, eb = canonical.serialize(b)
			T.ok(sa, ea)
			T.ok(sb, eb)
			T.eq(sa, sb)
		end)

		T.it("computes content-addressed term ids", function()
			local id, err = canonical.term_id("type", "integer")
			T.ok(id, err)
			local id_s = tostring(id)
			T.ok(id_s:find("^t:%x%x%x%x") ~= nil, id_s)
		end)

		T.it("rejects non-integer numeric payloads until numeric encoding is specified", function()
			local encoded, err = canonical.serialize({ tag = "literal", base = "number", value = 1.5 })
			T.eq(encoded, nil)
			local msg = tostring(err)
			T.ok(msg:find("numeric literal encoding", 1, true) ~= nil, msg)
		end)
	end)

	T.describe("fixture corpus", function()
		for _, fixture in ipairs(fixtures.cases) do
			T.it(fixture.expect .. "s " .. fixture.name, function()
				local ok, err = mr0.verify(fixture.cert)
				if fixture.expect == "accept" then
					T.ok(ok, err)
				else
					T.fail(ok)
					if fixture.contains then
						local msg = tostring(err)
						T.ok(msg:find(fixture.contains, 1, true) ~= nil, msg)
					end
				end
			end)
		end
	end)

	T.it("accepts literal integer annotation through integer <: number", function()
		local ok, err = mr0.verify(cert({
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
				outputs = { ok = true },
			},
		}, nil, { lit_int, integer, number }))
		T.ok(ok, err)
	end)

	T.it("accepts named union-right arm without searching", function()
		local ok, err = mr0.verify(cert({
			{
				node_id = "n_union",
				family = "SubNode",
				rule = "union_right_arm",
				inputs = { producer = "t_lit_a", consumer = "t_union_ab", arm_index = 1 },
				outputs = { ok = true },
			},
		}, nil, { lit_a, union_ab }))
		T.ok(ok, err)
	end)

	T.it("rejects wrong numeric annotation", function()
		local ok, err = mr0.verify(cert({
			{
				node_id = "n_bad",
				family = "SubNode",
				rule = "integer_to_number",
				inputs = { producer = "t_number", consumer = "t_integer" },
				outputs = { ok = true },
			},
		}, nil, { integer, number }))
		T.fail(ok)
		local msg = tostring(err)
		T.ok(msg:find("integer_to_number", 1, true) ~= nil, msg)
	end)

	T.it("rejects unsupported MR0 rules instead of guessing", function()
		local ok, err = mr0.verify(cert({
			{
				node_id = "n_generic",
				family = "GenericNode",
				rule = "overload_export_all_branches",
				inputs = {},
				outputs = {},
			},
		}))
		T.fail(ok)
		local msg = tostring(err)
		T.ok(msg:find("unsupported node family", 1, true) ~= nil, msg)
	end)

	T.it("rejects certificates without roots", function()
		local ok, err = mr0.verify(cert({}, {}))
		T.fail(ok)
		local msg = tostring(err)
		T.ok(msg:find("no roots", 1, true) ~= nil, msg)
	end)

	T.it("rejects unknown target profiles", function()
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
		local ok, err = mr0.verify(c)
		T.fail(ok)
		local msg = tostring(err)
		T.ok(msg:find("target", 1, true) ~= nil, msg)
	end)

	T.it("strict mode accepts canonical term ids", function()
		local integer_id = canonical.term_id("type", "integer")
		T.ok(integer_id, "integer term id")
		local ok, err = mr0.verify(cert({
			{
				node_id = "n_wf",
				family = "WFNode",
				rule = "wf_type",
				inputs = { type = integer_id },
				outputs = { ok = true },
			},
		}, nil, {
			{ term_id = integer_id, sort = "type", payload = "integer" },
		}), { strict_ids = true })
		T.ok(ok, err)
	end)

	T.it("strict mode rejects mismatched term ids", function()
		local ok, err = mr0.verify(cert({
			{
				node_id = "n_wf",
				family = "WFNode",
				rule = "wf_type",
				inputs = { type = "t_integer" },
				outputs = { ok = true },
			},
		}, nil, {
			{ term_id = "t_integer", sort = "type", payload = "integer" },
		}), { strict_ids = true })
		T.fail(ok)
		local msg = tostring(err)
		T.ok(msg:find("term id mismatch", 1, true) ~= nil, msg)
	end)
end)
