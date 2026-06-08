local T = require("lib.test.assert")
local replay = require("lib.type.framework.replay")
local shape = require("lib.type.framework.shape")

local function term(head, fields)
	return { tag = "term", head = head, fields = fields or {} }
end

local function p_term(head, fields)
	return { tag = "p_term", head = head, fields = fields or {} }
end

local function p_meta(name)
	return { tag = "p_meta", name = name }
end

local function combinator_theory()
	return {
		tag = "theory_spec",
		theory_id = "comb",
		version = "0",
		namespaces = {},
		categories = {
			{ tag = "category", name = "Ty" },
			{ tag = "category", name = "Term" },
		},
		term_heads = {
			{ tag = "term_head", name = "TyUnit", result_category = "Ty", fields = {} },
			{
				tag = "term_head",
				name = "TyArrow",
				result_category = "Ty",
				fields = {
					{ tag = "field_category", name = "param", category = "Ty" },
					{ tag = "field_category", name = "result", category = "Ty" },
				},
			},
			{ tag = "term_head", name = "TmUnit", result_category = "Term", fields = {} },
			{
				tag = "term_head",
				name = "TmConst",
				result_category = "Term",
				fields = {
					{ tag = "field_literal", name = "name", literal_kind = "string" },
				},
			},
			{
				tag = "term_head",
				name = "TmApp",
				result_category = "Term",
				fields = {
					{ tag = "field_category", name = "fn", category = "Term" },
					{ tag = "field_category", name = "arg", category = "Term" },
				},
			},
		},
		binder_schemas = {},
		judgments = {
			{
				tag = "judgment",
				name = "HasType",
				params = {
					{ tag = "field_category", name = "term", category = "Term" },
					{ tag = "field_category", name = "ty", category = "Ty" },
				},
			},
		},
		rules = {
			{
				tag = "rule",
				name = "const_id",
				judgment = "HasType",
				metavariables = {},
				conclusion = {
					tag = "claim_pattern",
					judgment = "HasType",
					args = {
						term = p_term("TmConst", { name = { tag = "p_literal", value = "id_unit" } }),
						ty = p_term("TyArrow", { param = p_term("TyUnit"), result = p_term("TyUnit") }),
					},
				},
				premises = {},
				structural_conditions = {},
			},
			{
				tag = "rule",
				name = "unit_intro",
				judgment = "HasType",
				metavariables = {},
				conclusion = {
					tag = "claim_pattern",
					judgment = "HasType",
					args = {
						term = p_term("TmUnit"),
						ty = p_term("TyUnit"),
					},
				},
				premises = {},
				structural_conditions = {},
			},
			{
				tag = "rule",
				name = "app",
				judgment = "HasType",
				metavariables = {
					{ tag = "metavariable", name = "fn", kind = "category", category = "Term", mode = "input" },
					{ tag = "metavariable", name = "arg", kind = "category", category = "Term", mode = "input" },
					{ tag = "metavariable", name = "A", kind = "category", category = "Ty", mode = "input" },
					{ tag = "metavariable", name = "B", kind = "category", category = "Ty", mode = "input" },
				},
				conclusion = {
					tag = "claim_pattern",
					judgment = "HasType",
					args = {
						term = p_term("TmApp", { fn = p_meta("fn"), arg = p_meta("arg") }),
						ty = p_meta("B"),
					},
				},
				premises = {
					{
						tag = "premise_pattern",
						claim = {
							tag = "claim_pattern",
							judgment = "HasType",
							args = {
								term = p_meta("fn"),
								ty = p_term("TyArrow", { param = p_meta("A"), result = p_meta("B") }),
							},
						},
					},
					{
						tag = "premise_pattern",
						claim = {
							tag = "claim_pattern",
							judgment = "HasType",
							args = {
								term = p_meta("arg"),
								ty = p_meta("A"),
							},
						},
					},
				},
				structural_conditions = {},
			},
		},
		oracles = {},
		roots = {
			{
				tag = "root_decl",
				root_kind = "program_type",
				required_judgment = "HasType",
				required_claim_pattern = {
					tag = "claim_pattern",
					judgment = "HasType",
					args = {
						term = p_meta("term"),
						ty = p_meta("ty"),
					},
				},
				scope_policy = "closed",
			},
		},
	}
end

local function claim(term_value, ty_value)
	return {
		tag = "claim",
		scope = {},
		judgment = "HasType",
		args = { term = term_value, ty = ty_value },
	}
end

local function evidence(node_id, claim_value, rule, premises)
	return {
		tag = "evidence",
		node_id = node_id,
		theory_id = "comb",
		judgment = "HasType",
		claim = claim_value,
		justification = { tag = "rule_application", rule = rule, premises = premises or {} },
	}
end

local function app_certificate()
	local unit_ty = term("TyUnit")
	local id_ty = term("TyArrow", { param = unit_ty, result = unit_ty })
	local id_term = term("TmConst", { name = "id_unit" })
	local unit_term = term("TmUnit")
	local app_term = term("TmApp", { fn = id_term, arg = unit_term })
	return {
		tag = "certificate",
		framework_version = shape.FRAMEWORK_VERSION,
		theory_id = "comb",
		theory_version = "0",
		evidence = {
			evidence("id", claim(id_term, id_ty), "const_id"),
			evidence("unit", claim(unit_term, unit_ty), "unit_intro"),
			evidence("app", claim(app_term, unit_ty), "app", { "id", "unit" }),
		},
		roots = {
			{ tag = "root", root_kind = "program_type", node_id = "app" },
		},
	}
end

local function has_error(errors, needle)
	for _, e in ipairs(errors or {}) do
		if tostring(e):find(needle, 1, true) then return true end
	end
	return false
end

T.describe("type.framework F3 replay", function()
	T.it("accepts an ordered first-order combinator derivation", function()
		local result, errors = replay.replay(combinator_theory(), app_certificate())
		T.ok(result, table.concat(errors or {}, "\n"))
		T.eq(#result.root_digests, 1)
	end)

	T.it("rejects malformed premise order", function()
		local cert = app_certificate()
		cert.evidence[3].justification.premises = { "unit", "id" }
		local result, errors = replay.replay(combinator_theory(), cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "expected term head TyArrow"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects repeated metavariable mismatches", function()
		local theory = combinator_theory()
		theory.rules[#theory.rules + 1] = {
			tag = "rule",
			name = "same",
			judgment = "HasType",
			metavariables = {
				{ tag = "metavariable", name = "x", kind = "category", category = "Term", mode = "input" },
			},
			conclusion = {
				tag = "claim_pattern",
				judgment = "HasType",
				args = {
					term = p_term("TmApp", { fn = p_meta("x"), arg = p_meta("x") }),
					ty = p_term("TyUnit"),
				},
			},
			premises = {},
			structural_conditions = {},
		}
		local cert = app_certificate()
		cert.evidence = {
			evidence("bad", claim(term("TmApp", {
				fn = term("TmUnit"),
				arg = term("TmConst", { name = "id_unit" }),
			}), term("TyUnit")), "same"),
		}
		cert.roots[1].node_id = "bad"
		local result, errors = replay.replay(theory, cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "repeated metavariable mismatch"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects unsupported scoped F3 rules", function()
		local theory = combinator_theory()
		theory.rules[1].metavariables = {
			{ tag = "metavariable", name = "s", kind = "scoped", mode = "input" },
		}
		local result, errors = replay.replay(theory, app_certificate())
		T.eq(result, nil)
		T.ok(has_error(errors, "unsupported F3 metavariable kind scoped"), table.concat(errors or {}, "\n"))
	end)
end)
