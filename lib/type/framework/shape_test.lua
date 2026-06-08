local T = require("lib.test.assert")
local shape = require("lib.type.framework.shape")

local function base_theory()
	return {
		tag = "theory_spec",
		theory_id = "test",
		version = "0",
		namespaces = {
			{ tag = "namespace", name = "term_var" },
		},
		categories = {
			{ tag = "category", name = "Ty" },
			{ tag = "category", name = "Tm" },
			{ tag = "category", name = "Ctx", role = "context" },
		},
		term_heads = {
			{ tag = "term_head", name = "TyUnit", result_category = "Ty", fields = {} },
			{ tag = "term_head", name = "UnitTerm", result_category = "Tm", fields = {} },
			{ tag = "term_head", name = "EmptyCtx", result_category = "Ctx", fields = {} },
			{
				tag = "term_head",
				name = "Lam",
				result_category = "Tm",
				fields = {
					{
						tag = "field_scoped",
						name = "body",
						binders = { { tag = "binder_schema_ref", schema = "term_binding" } },
						body = { tag = "field_category", name = "body", category = "Tm" },
					},
				},
			},
		},
		binder_schemas = {
			{
				tag = "binder_schema",
				name = "term_binding",
				namespace = "term_var",
				category = "Tm",
				fields = {
					{ tag = "field_category", name = "type", category = "Ty" },
				},
			},
		},
		judgments = {
			{
				tag = "judgment",
				name = "has_type",
				params = {
					{ tag = "field_category", name = "ctx", category = "Ctx" },
					{ tag = "field_category", name = "term", category = "Tm" },
					{ tag = "field_category", name = "type", category = "Ty" },
				},
			},
		},
		rules = {},
		oracles = {},
		roots = {
			{
				tag = "root_decl",
				root_kind = "program_type",
				required_judgment = "has_type",
				required_claim_pattern = {
					tag = "claim_pattern",
					judgment = "has_type",
					args = {
						ctx = { tag = "p_term", head = "EmptyCtx", fields = {} },
						term = { tag = "p_term", head = "UnitTerm", fields = {} },
						type = { tag = "p_term", head = "TyUnit", fields = {} },
					},
				},
				scope_policy = "closed",
			},
		},
	}
end

local function has_error(errors, needle)
	for _, e in ipairs(errors or {}) do
		if tostring(e):find(needle, 1, true) then return true end
	end
	return false
end

local function term(head, fields)
	return { tag = "term", head = head, fields = fields or {} }
end

local function certificate_theory()
	local theory = base_theory()
	theory.rules = {
		{
			tag = "rule",
			name = "unit",
			judgment = "has_type",
			metavariables = {},
			conclusion = theory.roots[1].required_claim_pattern,
			premises = {},
			structural_conditions = {},
		},
	}
	return theory
end

local function valid_certificate()
	return {
		tag = "certificate",
		framework_version = shape.FRAMEWORK_VERSION,
		theory_id = "test",
		theory_version = "0",
		evidence = {
			{
				tag = "evidence",
				node_id = "n1",
				theory_id = "test",
				judgment = "has_type",
				claim = {
					tag = "claim",
					scope = {},
					judgment = "has_type",
					args = {
						ctx = term("EmptyCtx"),
						term = term("UnitTerm"),
						type = term("TyUnit"),
					},
				},
				justification = { tag = "rule_application", rule = "unit", premises = {} },
			},
		},
		roots = {
			{ tag = "root", root_kind = "program_type", node_id = "n1" },
		},
	}
end

T.describe("type.framework shape validation", function()
	T.it("accepts a theory declaration graph without replaying rules", function()
		local indexes, errors = shape.validate_theory(base_theory())
		T.ok(indexes, table.concat(errors or {}, "\n"))
		T.ok(indexes.categories.Ty ~= nil)
		T.ok(indexes.term_heads.Lam ~= nil)
		T.ok(indexes.roots.program_type ~= nil)
	end)

	T.it("rejects duplicate declaration names", function()
		local theory = base_theory()
		theory.categories[#theory.categories + 1] = { tag = "category", name = "Ty" }
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "duplicate name Ty"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects theories with no declared root kind", function()
		local theory = base_theory()
		theory.roots = {}
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "at least one root kind"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects field schemas that reference missing categories", function()
		local theory = base_theory()
		theory.term_heads[1].fields = {
			{ tag = "field_category", name = "bad", category = "Missing" },
		}
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "unknown category Missing"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects unknown semantic fields outside meta", function()
		local theory = base_theory()
		theory.term_heads[1].surprise = true
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "unknown field"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects malformed scoped binder references", function()
		local theory = base_theory()
		theory.term_heads[4].fields[1].binders[1].schema = "missing_binding"
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "unknown binder schema missing_binding"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects root claim patterns with missing judgment arguments", function()
		local theory = base_theory()
		theory.roots[1].required_claim_pattern.args.type = nil
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "missing pattern field"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects rule conclusions for the wrong judgment", function()
		local theory = base_theory()
		theory.judgments[#theory.judgments + 1] = {
			tag = "judgment",
			name = "is_type",
			params = {
				{ tag = "field_category", name = "type", category = "Ty" },
			},
		}
		theory.rules = {
			{
				tag = "rule",
				name = "bad",
				judgment = "has_type",
				metavariables = {},
				conclusion = {
					tag = "claim_pattern",
					judgment = "is_type",
					args = {
						type = { tag = "p_term", head = "TyUnit", fields = {} },
					},
				},
				premises = {},
				structural_conditions = {},
			},
		}
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "expected judgment has_type"), table.concat(errors or {}, "\n"))
	end)

	T.it("accepts explicit structural condition operands", function()
		local theory = base_theory()
		theory.rules = {
			{
				tag = "rule",
				name = "unit",
				judgment = "has_type",
				metavariables = {
					{ tag = "metavariable", name = "ty", kind = "category", category = "Ty", mode = "input" },
				},
				conclusion = {
					tag = "claim_pattern",
					judgment = "has_type",
					args = {
						ctx = { tag = "p_term", head = "EmptyCtx", fields = {} },
						term = { tag = "p_term", head = "UnitTerm", fields = {} },
						type = { tag = "p_meta", name = "ty" },
					},
				},
				premises = {},
				structural_conditions = {
					{
						tag = "cond_category_eq",
						left = { tag = "operand_meta", name = "ty" },
						right = { tag = "operand_meta", name = "ty" },
					},
				},
			},
		}
		local indexes, errors = shape.validate_theory(theory)
		T.ok(indexes, table.concat(errors or {}, "\n"))
	end)

	T.it("rejects legacy string structural condition operands", function()
		local theory = base_theory()
		theory.rules = {
			{
				tag = "rule",
				name = "bad_operand",
				judgment = "has_type",
				metavariables = {
					{ tag = "metavariable", name = "ty", kind = "category", category = "Ty", mode = "input" },
				},
				conclusion = theory.roots[1].required_claim_pattern,
				premises = {},
				structural_conditions = {
					{ tag = "cond_category_eq", left = "ty", right = "ty" },
				},
			},
		}
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "expected table"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects direct operand metavariables with the wrong kind", function()
		local theory = base_theory()
		theory.rules = {
			{
				tag = "rule",
				name = "bad_kind",
				judgment = "has_type",
				metavariables = {
					{ tag = "metavariable", name = "b", kind = "binder", namespace = "term_var", mode = "input" },
				},
				conclusion = theory.roots[1].required_claim_pattern,
				premises = {},
				structural_conditions = {
					{
						tag = "cond_category_eq",
						left = { tag = "operand_meta", name = "b" },
						right = { tag = "operand_meta", name = "b" },
					},
				},
			},
		}
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "expected category metavariable"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects field operands with empty paths", function()
		local theory = base_theory()
		theory.rules = {
			{
				tag = "rule",
				name = "bad_field_path",
				judgment = "has_type",
				metavariables = {
					{ tag = "metavariable", name = "term", kind = "category", category = "Tm", mode = "input" },
				},
				conclusion = theory.roots[1].required_claim_pattern,
				premises = {},
				structural_conditions = {
					{
						tag = "cond_literal_eq",
						left = { tag = "operand_field", base = "term", path = {} },
						right = { tag = "operand_field", base = "term", path = { "tag" } },
					},
				},
			},
		}
		local indexes, errors = shape.validate_theory(theory)
		T.eq(indexes, nil)
		T.ok(has_error(errors, "path must be non-empty"), table.concat(errors or {}, "\n"))
	end)

	T.it("accepts a certificate envelope and claim values without replaying rules", function()
		local result, errors = shape.validate_certificate(certificate_theory(), valid_certificate())
		T.ok(result, table.concat(errors or {}, "\n"))
	end)

	T.it("rejects evidence rule applications with unknown rules", function()
		local cert = valid_certificate()
		cert.evidence[1].justification.rule = "missing"
		local result, errors = shape.validate_certificate(certificate_theory(), cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "unknown rule missing"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects roots that point at missing evidence", function()
		local cert = valid_certificate()
		cert.roots[1].node_id = "missing"
		local result, errors = shape.validate_certificate(certificate_theory(), cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "unknown evidence node_id missing"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects oracle applications in the first checker slice", function()
		local cert = valid_certificate()
		cert.evidence[1].justification = {
			tag = "oracle_application",
			oracle_kind = "external",
			input_payload = term("UnitTerm"),
			result_payload = term("TyUnit"),
			trust_policy_id = "none",
		}
		local result, errors = shape.validate_certificate(certificate_theory(), cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "oracle applications are not admitted"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects claim terms with unknown heads", function()
		local cert = valid_certificate()
		cert.evidence[1].claim.args.term = term("Missing")
		local result, errors = shape.validate_certificate(certificate_theory(), cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "unknown term head Missing"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects bound references outside scope", function()
		local theory = certificate_theory()
		theory.term_heads[#theory.term_heads + 1] = {
			tag = "term_head",
			name = "Var",
			result_category = "Tm",
			fields = {
				{ tag = "field_bound_ref", name = "ref", namespace = "term_var" },
			},
		}
		local cert = valid_certificate()
		cert.evidence[1].claim.args.term = term("Var", {
			ref = { tag = "bound_ref", binder_id = "x", namespace = "term_var" },
		})
		local result, errors = shape.validate_certificate(theory, cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "unresolved bound reference x"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects bound references whose namespace disagrees with the resolved binder", function()
		local theory = certificate_theory()
		theory.namespaces[#theory.namespaces + 1] = { tag = "namespace", name = "type_var" }
		theory.binder_schemas[#theory.binder_schemas + 1] = {
			tag = "binder_schema",
			name = "type_binding",
			namespace = "type_var",
			category = "Ty",
			fields = {},
		}
		theory.term_heads[#theory.term_heads + 1] = {
			tag = "term_head",
			name = "Var",
			result_category = "Tm",
			fields = {
				{ tag = "field_bound_ref", name = "ref", namespace = "term_var" },
			},
		}
		local cert = valid_certificate()
		cert.evidence[1].claim.scope = {
			{ tag = "binder", binder_id = "x", schema = "type_binding", fields = {} },
		}
		cert.evidence[1].claim.args.term = term("Var", {
			ref = { tag = "bound_ref", binder_id = "x", namespace = "term_var" },
		})
		local result, errors = shape.validate_certificate(theory, cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "binder namespace mismatch"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects binder fields with the wrong binder schema", function()
		local theory = certificate_theory()
		theory.binder_schemas[#theory.binder_schemas + 1] = {
			tag = "binder_schema",
			name = "other_binding",
			namespace = "term_var",
			category = "Tm",
			fields = {},
		}
		theory.term_heads[#theory.term_heads + 1] = {
			tag = "term_head",
			name = "HasBinder",
			result_category = "Tm",
			fields = {
				{ tag = "field_binder", name = "binder", binder_schema = "term_binding" },
			},
		}
		local cert = valid_certificate()
		cert.evidence[1].claim.args.term = term("HasBinder", {
			binder = { tag = "binder", binder_id = "x", schema = "other_binding", fields = {} },
		})
		local result, errors = shape.validate_certificate(theory, cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "expected binder schema term_binding"), table.concat(errors or {}, "\n"))
	end)

	T.it("rejects scoped values with the wrong binder schema", function()
		local theory = certificate_theory()
		theory.binder_schemas[#theory.binder_schemas + 1] = {
			tag = "binder_schema",
			name = "other_binding",
			namespace = "term_var",
			category = "Tm",
			fields = {},
		}
		local cert = valid_certificate()
		cert.evidence[1].claim.args.term = term("Lam", {
			body = {
				tag = "scoped",
				binders = {
					{ tag = "binder", binder_id = "x", schema = "other_binding", fields = {} },
				},
				body = term("UnitTerm"),
			},
		})
		local result, errors = shape.validate_certificate(theory, cert)
		T.eq(result, nil)
		T.ok(has_error(errors, "expected binder schema term_binding"), table.concat(errors or {}, "\n"))
	end)
end)
