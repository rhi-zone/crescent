local T = require("lib.test.assert")
local alpha = require("lib.type.framework.alpha")
local shape = require("lib.type.framework.shape")

local function term(head, fields)
	return { tag = "term", head = head, fields = fields or {} }
end

local function binder(id, schema)
	return { tag = "binder", binder_id = id, schema = schema or "term_binding", fields = {} }
end

local function ref(id, namespace)
	return { tag = "bound_ref", binder_id = id, namespace = namespace or "term_var" }
end

local function scoped(id)
	return {
		tag = "scoped",
		binders = { binder(id) },
		body = term("Var", { ref = ref(id) }),
	}
end

local function theory()
	return {
		tag = "theory_spec",
		theory_id = "alpha",
		version = "0",
		namespaces = {
			{ tag = "namespace", name = "term_var" },
			{ tag = "namespace", name = "type_var" },
		},
		categories = {
			{ tag = "category", name = "Tm" },
		},
		term_heads = {
			{
				tag = "term_head",
				name = "Var",
				result_category = "Tm",
				fields = {
					{ tag = "field_bound_ref", name = "ref", namespace = "term_var" },
				},
			},
		},
		binder_schemas = {
			{ tag = "binder_schema", name = "term_binding", namespace = "term_var", category = "Tm", fields = {} },
			{ tag = "binder_schema", name = "type_binding", namespace = "type_var", category = "Tm", fields = {} },
		},
		judgments = {
			{
				tag = "judgment",
				name = "IsTerm",
				params = {
					{ tag = "field_category", name = "term", category = "Tm" },
				},
			},
		},
		rules = {},
		oracles = {},
		roots = {
			{
				tag = "root_decl",
				root_kind = "term",
				required_judgment = "IsTerm",
				required_claim_pattern = {
					tag = "claim_pattern",
					judgment = "IsTerm",
					args = { term = { tag = "p_meta", name = "term" } },
				},
				scope_policy = "closed",
			},
		},
	}
end

local function indexes()
	local result, errors = shape.validate_theory(theory())
	T.ok(result, table.concat(errors or {}, "\n"))
	return result
end

T.describe("type.framework alpha normalization", function()
	T.it("treats alpha-renamed scoped values as equal", function()
		local ix = indexes()
		local equal, err = alpha.equal(scoped("x"), scoped("y"), ix)
		T.ok(equal, err)
	end)

	T.it("distinguishes different binder namespaces", function()
		local ix = indexes()
		local a = scoped("x")
		local b = {
			tag = "scoped",
			binders = { binder("x", "type_binding") },
			body = term("Var", { ref = ref("x", "type_var") }),
		}
		local equal, err = alpha.equal(a, b, ix)
		T.eq(err, nil)
		T.eq(equal, false)
	end)

	T.it("rejects unresolved bound references", function()
		local ix = indexes()
		local key, err = alpha.key(term("Var", { ref = ref("missing") }), ix)
		T.eq(key, nil)
		T.ok(tostring(err):find("unresolved bound reference missing") ~= nil, tostring(err))
	end)
end)
