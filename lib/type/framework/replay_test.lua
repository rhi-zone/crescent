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

local function scoped_identity(id)
	return {
		tag = "scoped",
		binders = {
			{ tag = "binder", binder_id = id, schema = "term_binding", fields = {} },
		},
		body = term("Var", {
			ref = { tag = "bound_ref", binder_id = id, namespace = "term_var" },
		}),
	}
end

local function scoped_theory()
	local theory = combinator_theory()
	theory.namespaces = {
		{ tag = "namespace", name = "term_var" },
	}
	theory.binder_schemas = {
		{ tag = "binder_schema", name = "term_binding", namespace = "term_var", category = "Term", fields = {} },
	}
	theory.term_heads[#theory.term_heads + 1] = {
		tag = "term_head",
		name = "Var",
		result_category = "Term",
		fields = {
			{ tag = "field_bound_ref", name = "ref", namespace = "term_var" },
		},
	}
	theory.term_heads[#theory.term_heads + 1] = {
		tag = "term_head",
		name = "Lam",
		result_category = "Term",
		fields = {
			{
				tag = "field_scoped",
				name = "body",
				binders = { { tag = "binder_schema_ref", schema = "term_binding" } },
				body = { tag = "field_category", name = "body", category = "Term" },
			},
		},
	}
	theory.term_heads[#theory.term_heads + 1] = {
		tag = "term_head",
		name = "Pair",
		result_category = "Term",
		fields = {
			{ tag = "field_category", name = "left", category = "Term" },
			{ tag = "field_category", name = "right", category = "Term" },
		},
	}
	theory.rules[#theory.rules + 1] = {
		tag = "rule",
		name = "same_pair",
		judgment = "HasType",
		metavariables = {
			{ tag = "metavariable", name = "x", kind = "category", category = "Term", mode = "input" },
		},
		conclusion = {
			tag = "claim_pattern",
			judgment = "HasType",
			args = {
				term = p_term("Pair", { left = p_meta("x"), right = p_meta("x") }),
				ty = p_term("TyUnit"),
			},
		},
		premises = {},
		structural_conditions = {},
	}
	theory.rules[#theory.rules + 1] = {
		tag = "rule",
		name = "any_term",
		judgment = "HasType",
		metavariables = {
			{ tag = "metavariable", name = "x", kind = "category", category = "Term", mode = "input" },
		},
		conclusion = {
			tag = "claim_pattern",
			judgment = "HasType",
			args = {
				term = p_meta("x"),
				ty = p_term("TyUnit"),
			},
		},
		premises = {},
		structural_conditions = {},
	}
	return theory
end

local function scoped_certificate(id, rule, term_value)
	return {
		tag = "certificate",
		framework_version = shape.FRAMEWORK_VERSION,
		theory_id = "comb",
		theory_version = "0",
		evidence = {
			evidence(id, claim(term_value, term("TyUnit")), rule),
		},
		roots = {
			{ tag = "root", root_kind = "program_type", node_id = id },
		},
	}
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

	T.it("rejects non-input metavariables", function()
		local theory = combinator_theory()
		theory.rules[1].metavariables = {
			{ tag = "metavariable", name = "s", kind = "category", category = "Term", mode = "output" },
		}
		local result, errors = replay.replay(theory, app_certificate())
		T.eq(result, nil)
		T.ok(has_error(errors, "input metavariables only"), table.concat(errors or {}, "\n"))
	end)

	T.it("uses alpha equality for repeated metavariable matches", function()
		local pair = term("Pair", {
			left = term("Lam", { body = scoped_identity("x") }),
			right = term("Lam", { body = scoped_identity("y") }),
		})
		local result, errors = replay.replay(scoped_theory(), scoped_certificate("pair", "same_pair", pair))
		T.ok(result, table.concat(errors or {}, "\n"))
	end)

	T.it("computes alpha-stable root digests", function()
		local theory = scoped_theory()
		local a, ae = replay.replay(theory, scoped_certificate("a", "any_term", term("Lam", { body = scoped_identity("x") })))
		local b, be = replay.replay(theory, scoped_certificate("b", "any_term", term("Lam", { body = scoped_identity("y") })))
		T.ok(a, table.concat(ae or {}, "\n"))
		T.ok(b, table.concat(be or {}, "\n"))
		T.eq(a.root_digests[1], b.root_digests[1])
	end)

	T.it("matches scoped binders and bound references by lexical identity", function()
		local theory = scoped_theory()
		theory.rules[#theory.rules + 1] = {
			tag = "rule",
			name = "identity_lam",
			judgment = "HasType",
			metavariables = {
				{ tag = "metavariable", name = "x", kind = "binder", namespace = "term_var", mode = "input" },
			},
			conclusion = {
				tag = "claim_pattern",
				judgment = "HasType",
				args = {
					term = p_term("Lam", {
						body = {
							tag = "p_scoped",
							binders = { "x" },
							body = p_term("Var", {
								ref = { tag = "p_bound_ref", name = "x" },
							}),
						},
					}),
					ty = p_term("TyUnit"),
				},
			},
			premises = {},
			structural_conditions = {},
		}
		local result, errors = replay.replay(theory, scoped_certificate("id_lam", "identity_lam", term("Lam", {
			body = scoped_identity("source_name_does_not_matter"),
		})))
		T.ok(result, table.concat(errors or {}, "\n"))
	end)

	T.it("rejects bound references to a different scoped binder", function()
		local theory = scoped_theory()
		theory.term_heads[#theory.term_heads + 1] = {
			tag = "term_head",
			name = "Two",
			result_category = "Term",
			fields = {
				{
					tag = "field_scoped",
					name = "body",
					binders = {
						{ tag = "binder_schema_ref", schema = "term_binding" },
						{ tag = "binder_schema_ref", schema = "term_binding" },
					},
					body = { tag = "field_category", name = "body", category = "Term" },
				},
			},
		}
		theory.rules[#theory.rules + 1] = {
			tag = "rule",
			name = "bad_two",
			judgment = "HasType",
			metavariables = {
				{ tag = "metavariable", name = "x", kind = "binder", namespace = "term_var", mode = "input" },
				{ tag = "metavariable", name = "y", kind = "binder", namespace = "term_var", mode = "input" },
			},
			conclusion = {
				tag = "claim_pattern",
				judgment = "HasType",
				args = {
					term = p_term("Two", {
						body = {
							tag = "p_scoped",
							binders = { "x", "y" },
							body = p_term("Var", {
								ref = { tag = "p_bound_ref", name = "x" },
							}),
						},
					}),
					ty = p_term("TyUnit"),
				},
			},
			premises = {},
			structural_conditions = {},
		}
		local bad = term("Two", {
			body = {
				tag = "scoped",
				binders = {
					{ tag = "binder", binder_id = "x", schema = "term_binding", fields = {} },
					{ tag = "binder", binder_id = "y", schema = "term_binding", fields = {} },
				},
				body = term("Var", {
					ref = { tag = "bound_ref", binder_id = "y", namespace = "term_var" },
				}),
			},
		})
		local result, errors = replay.replay(theory, scoped_certificate("bad_two", "bad_two", bad))
		T.eq(result, nil)
		T.ok(has_error(errors, "bound reference binder mismatch"), table.concat(errors or {}, "\n"))
	end)

	T.it("matches repeated explicit binder values with p_binder_ref", function()
		local theory = scoped_theory()
		theory.term_heads[#theory.term_heads + 1] = {
			tag = "term_head",
			name = "BinderPair",
			result_category = "Term",
			fields = {
				{ tag = "field_binder", name = "left", binder_schema = "term_binding" },
				{ tag = "field_binder", name = "right", binder_schema = "term_binding" },
			},
		}
		theory.rules[#theory.rules + 1] = {
			tag = "rule",
			name = "same_binder_pair",
			judgment = "HasType",
			metavariables = {
				{ tag = "metavariable", name = "b", kind = "binder", namespace = "term_var", mode = "input" },
			},
			conclusion = {
				tag = "claim_pattern",
				judgment = "HasType",
				args = {
					term = p_term("BinderPair", {
						left = { tag = "p_binder_ref", name = "b" },
						right = { tag = "p_binder_ref", name = "b" },
					}),
					ty = p_term("TyUnit"),
				},
			},
			premises = {},
			structural_conditions = {},
		}
		local b = { tag = "binder", binder_id = "x", schema = "term_binding", fields = {} }
		local result, errors = replay.replay(theory, scoped_certificate("binder_pair", "same_binder_pair", term("BinderPair", {
			left = b,
			right = b,
		})))
		T.ok(result, table.concat(errors or {}, "\n"))
	end)
end)
