-- F2 shape validation for framework theory specs.
--
-- This module validates declarations and field-schema references. It does not
-- replay rules, validate certificates, or interpret theory-specific meaning.

local M = {}

M.FRAMEWORK_VERSION = "0"

local FIELD_SCHEMA_TAGS = {
	field_category = true,
	field_bound_ref = true,
	field_binder = true,
	field_scoped = true,
	field_list = true,
	field_literal = true,
	field_enum = true,
	field_object = true,
}

local LITERAL_KINDS = {
	string = true,
	integer = true,
	number = true,
	boolean = true,
}

local MODES = {
	input = true,
	output = true,
	fresh = true,
}

local METAVARIABLE_KINDS = {
	category = true,
	bound_ref = true,
	binder = true,
	scoped = true,
	scalar = true,
}

local PATTERN_TAGS = {
	p_meta = true,
	p_term = true,
	p_scoped = true,
	p_list = true,
	p_object = true,
	p_bound_ref = true,
	p_binder_ref = true,
	p_literal = true,
	p_enum = true,
}

local CONDITION_TAGS = {
	cond_category_eq = true,
	cond_binder_eq = true,
	cond_binder_neq = true,
	cond_alpha_eq = true,
	cond_subst = true,
	cond_literal_eq = true,
	cond_list_len_eq = true,
	cond_digest_eq = true,
}

local function new_state()
	return { errors = {} }
end

local function err(st, path, msg)
	st.errors[#st.errors + 1] = path .. ": " .. msg
end

local function is_array(t)
	local max = 0
	local count = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
		count = count + 1
		if k > max then max = k end
	end
	if max ~= count then return false end
	for i = 1, max do
		if t[i] == nil then return false end
	end
	return true
end

local function table_ok(st, value, path)
	if type(value) ~= "table" then
		err(st, path, "expected table")
		return false
	end
	if getmetatable(value) ~= nil then
		err(st, path, "metatables are not admitted")
		return false
	end
	return true
end

local function expect_string(st, obj, key, path)
	if type(obj[key]) ~= "string" then
		err(st, path .. "." .. key, "expected string")
		return false
	end
	return true
end

local function expect_array(st, obj, key, path)
	local value = obj[key]
	if not table_ok(st, value, path .. "." .. key) then return false end
	if not is_array(value) then
		err(st, path .. "." .. key, "expected dense array")
		return false
	end
	return true
end

local function check_fields(st, obj, path, required, optional)
	if not table_ok(st, obj, path) then return false end
	local allowed = { meta = true }
	for _, key in ipairs(required) do
		allowed[key] = true
		if obj[key] == nil then err(st, path .. "." .. key, "missing required field") end
	end
	for _, key in ipairs(optional or {}) do
		allowed[key] = true
	end
	for key in pairs(obj) do
		if type(key) ~= "string" then
			err(st, path, "object fields must be string-keyed")
		elseif not allowed[key] then
			err(st, path .. "." .. key, "unknown field")
		end
	end
	return true
end

local function index_by_name(st, indexes, list, key, path)
	for i, item in ipairs(list) do
		if type(item) == "table" and type(item[key]) == "string" then
			local name = item[key]
			if indexes[name] then
				err(st, path .. "[" .. i .. "]." .. key, "duplicate name " .. name)
			else
				indexes[name] = item
			end
		end
	end
end

local function validate_name_decl(st, decl, path, tag)
	check_fields(st, decl, path, { "tag", "name" })
	if decl.tag ~= tag then err(st, path .. ".tag", "expected " .. tag) end
	expect_string(st, decl, "name", path)
end

local function validate_category_decl(st, decl, path)
	check_fields(st, decl, path, { "tag", "name" }, { "role" })
	if decl.tag ~= "category" then err(st, path .. ".tag", "expected category") end
	expect_string(st, decl, "name", path)
	if decl.role ~= nil and decl.role ~= "context" then
		err(st, path .. ".role", "unknown category role " .. tostring(decl.role))
	end
end

local validate_field_schema

local function validate_field_list(st, fields, path, indexes)
	if not expect_array(st, { fields = fields }, "fields", path) then return end
	local names = {}
	for i, field in ipairs(fields) do
		local fpath = path .. ".fields[" .. i .. "]"
		validate_field_schema(st, field, fpath, indexes)
		if type(field) == "table" and type(field.name) == "string" then
			if names[field.name] then
				err(st, fpath .. ".name", "duplicate field name " .. field.name)
			else
				names[field.name] = true
			end
		end
	end
end

local validate_pattern
local validate_claim_pattern
local validate_value

validate_field_schema = function(st, field, path, indexes)
	if not table_ok(st, field, path) then return end
	if type(field.tag) ~= "string" or not FIELD_SCHEMA_TAGS[field.tag] then
		err(st, path .. ".tag", "unknown field schema tag")
		return
	end
	if field.tag == "field_category" then
		check_fields(st, field, path, { "tag", "name", "category" })
		expect_string(st, field, "name", path)
		if expect_string(st, field, "category", path) and not indexes.categories[field.category] then
			err(st, path .. ".category", "unknown category " .. field.category)
		end
	elseif field.tag == "field_bound_ref" then
		check_fields(st, field, path, { "tag", "name", "namespace" })
		expect_string(st, field, "name", path)
		if expect_string(st, field, "namespace", path) and not indexes.namespaces[field.namespace] then
			err(st, path .. ".namespace", "unknown namespace " .. field.namespace)
		end
	elseif field.tag == "field_binder" then
		check_fields(st, field, path, { "tag", "name", "binder_schema" })
		expect_string(st, field, "name", path)
		if expect_string(st, field, "binder_schema", path) and not indexes.binder_schemas[field.binder_schema] then
			err(st, path .. ".binder_schema", "unknown binder schema " .. field.binder_schema)
		end
	elseif field.tag == "field_scoped" then
		check_fields(st, field, path, { "tag", "name", "binders", "body" })
		expect_string(st, field, "name", path)
		if expect_array(st, field, "binders", path) then
			for i, ref in ipairs(field.binders) do
				local rpath = path .. ".binders[" .. i .. "]"
				check_fields(st, ref, rpath, { "tag", "schema" })
				if ref.tag ~= "binder_schema_ref" then err(st, rpath .. ".tag", "expected binder_schema_ref") end
				if expect_string(st, ref, "schema", rpath) and not indexes.binder_schemas[ref.schema] then
					err(st, rpath .. ".schema", "unknown binder schema " .. ref.schema)
				end
			end
		end
		validate_field_schema(st, field.body, path .. ".body", indexes)
	elseif field.tag == "field_list" then
		check_fields(st, field, path, { "tag", "name", "item" })
		expect_string(st, field, "name", path)
		validate_field_schema(st, field.item, path .. ".item", indexes)
	elseif field.tag == "field_literal" then
		check_fields(st, field, path, { "tag", "name", "literal_kind" })
		expect_string(st, field, "name", path)
		if expect_string(st, field, "literal_kind", path) and not LITERAL_KINDS[field.literal_kind] then
			err(st, path .. ".literal_kind", "unknown literal kind " .. field.literal_kind)
		end
	elseif field.tag == "field_enum" then
		check_fields(st, field, path, { "tag", "name", "values" })
		expect_string(st, field, "name", path)
		if expect_array(st, field, "values", path) then
			local seen = {}
			for i, value in ipairs(field.values) do
				if type(value) ~= "string" then
					err(st, path .. ".values[" .. i .. "]", "expected string")
				elseif seen[value] then
					err(st, path .. ".values[" .. i .. "]", "duplicate enum value " .. value)
				else
					seen[value] = true
				end
			end
			if #field.values == 0 then err(st, path .. ".values", "enum must be non-empty") end
		end
	elseif field.tag == "field_object" then
		check_fields(st, field, path, { "tag", "name", "fields" })
		expect_string(st, field, "name", path)
		validate_field_list(st, field.fields, path, indexes)
	end
end

local function validate_term_heads(st, theory, indexes)
	for i, head in ipairs(theory.term_heads) do
		local path = "theory.term_heads[" .. i .. "]"
		check_fields(st, head, path, { "tag", "name", "result_category", "fields" })
		if head.tag ~= "term_head" then err(st, path .. ".tag", "expected term_head") end
		expect_string(st, head, "name", path)
		if expect_string(st, head, "result_category", path) and not indexes.categories[head.result_category] then
			err(st, path .. ".result_category", "unknown category " .. head.result_category)
		end
		validate_field_list(st, head.fields, path, indexes)
	end
end

local function validate_binder_schemas(st, theory, indexes)
	for i, schema in ipairs(theory.binder_schemas) do
		local path = "theory.binder_schemas[" .. i .. "]"
		check_fields(st, schema, path, { "tag", "name", "namespace", "category", "fields" })
		if schema.tag ~= "binder_schema" then err(st, path .. ".tag", "expected binder_schema") end
		expect_string(st, schema, "name", path)
		if expect_string(st, schema, "namespace", path) and not indexes.namespaces[schema.namespace] then
			err(st, path .. ".namespace", "unknown namespace " .. schema.namespace)
		end
		if expect_string(st, schema, "category", path) and not indexes.categories[schema.category] then
			err(st, path .. ".category", "unknown category " .. schema.category)
		end
		validate_field_list(st, schema.fields, path, indexes)
	end
end

local function validate_judgments(st, theory, indexes)
	for i, judgment in ipairs(theory.judgments) do
		local path = "theory.judgments[" .. i .. "]"
		check_fields(st, judgment, path, { "tag", "name", "params" })
		if judgment.tag ~= "judgment" then err(st, path .. ".tag", "expected judgment") end
		expect_string(st, judgment, "name", path)
		validate_field_list(st, judgment.params, path, indexes)
	end
end

local function validate_metavariables(st, rule, path, indexes)
	local mvs = {}
	if not expect_array(st, rule, "metavariables", path) then return mvs end
	local seen = {}
	for i, mv in ipairs(rule.metavariables) do
		local mpath = path .. ".metavariables[" .. i .. "]"
		check_fields(st, mv, mpath, { "tag", "name", "kind", "mode" }, { "category", "namespace" })
		if mv.tag ~= "metavariable" then err(st, mpath .. ".tag", "expected metavariable") end
		if expect_string(st, mv, "name", mpath) then
			if seen[mv.name] then err(st, mpath .. ".name", "duplicate metavariable " .. mv.name) end
			seen[mv.name] = true
			mvs[mv.name] = mv
		end
		if expect_string(st, mv, "kind", mpath) and not METAVARIABLE_KINDS[mv.kind] then
			err(st, mpath .. ".kind", "unknown metavariable kind " .. mv.kind)
		end
		if expect_string(st, mv, "mode", mpath) and not MODES[mv.mode] then
			err(st, mpath .. ".mode", "unknown mode " .. mv.mode)
		end
		if mv.kind == "category" then
			if expect_string(st, mv, "category", mpath) and not indexes.categories[mv.category] then
				err(st, mpath .. ".category", "unknown category " .. mv.category)
			end
		elseif mv.kind == "bound_ref" or mv.kind == "binder" then
			if expect_string(st, mv, "namespace", mpath) and not indexes.namespaces[mv.namespace] then
				err(st, mpath .. ".namespace", "unknown namespace " .. mv.namespace)
			end
		end
	end
	return mvs
end

local function expect_metavariable(st, mvs, name, kind, path)
	if type(name) ~= "string" then
		err(st, path, "expected metavariable name")
		return
	end
	local mv = mvs and mvs[name]
	if not mv then
		err(st, path, "unknown metavariable " .. name)
	elseif kind and mv.kind ~= kind then
		err(st, path, "expected " .. kind .. " metavariable")
	end
end

local function expect_metavariable_one_of(st, mvs, name, kinds, path)
	if type(name) ~= "string" then
		err(st, path, "expected metavariable name")
		return
	end
	local mv = mvs and mvs[name]
	if not mv then
		err(st, path, "unknown metavariable " .. name)
		return
	end
	for _, kind in ipairs(kinds) do
		if mv.kind == kind then return end
	end
	err(st, path, "expected " .. table.concat(kinds, " or ") .. " metavariable")
end

local function validate_condition_operand(st, operand, path, mvs, direct_kind)
	if not table_ok(st, operand, path) then return end
	if operand.tag == "operand_meta" then
		check_fields(st, operand, path, { "tag", "name" })
		expect_metavariable(st, mvs, operand.name, direct_kind, path .. ".name")
	elseif operand.tag == "operand_field" then
		check_fields(st, operand, path, { "tag", "base", "path" })
		expect_metavariable(st, mvs, operand.base, nil, path .. ".base")
		if expect_array(st, operand, "path", path) then
			if #operand.path == 0 then err(st, path .. ".path", "field operand path must be non-empty") end
			for i, segment in ipairs(operand.path) do
				if type(segment) ~= "string" then
					err(st, path .. ".path[" .. i .. "]", "expected string")
				end
			end
		end
	else
		err(st, path .. ".tag", "unknown condition operand tag")
	end
end

local function validate_pattern_map(st, fields, expected_names, path, indexes, mvs, allow_implicit_metas)
	if not table_ok(st, fields, path) then return end
	if #fields > 0 and is_array(fields) then
		err(st, path, "expected string-keyed pattern map")
		return
	end
	for key in pairs(fields) do
		if type(key) ~= "string" then err(st, path, "pattern map keys must be strings") end
	end
	for name in pairs(expected_names) do
		if fields[name] == nil then err(st, path .. "." .. name, "missing pattern field") end
	end
	for name, value in pairs(fields) do
		if not expected_names[name] then
			err(st, path .. "." .. tostring(name), "unknown pattern field")
		else
			validate_pattern(st, value, path .. "." .. name, indexes, mvs, allow_implicit_metas)
		end
	end
end

validate_pattern = function(st, pattern, path, indexes, mvs, allow_implicit_metas)
	if not table_ok(st, pattern, path) then return end
	if type(pattern.tag) ~= "string" or not PATTERN_TAGS[pattern.tag] then
		err(st, path .. ".tag", "unknown pattern tag")
		return
	end
	if pattern.tag == "p_meta" then
		check_fields(st, pattern, path, { "tag", "name" })
		if not allow_implicit_metas then
			expect_metavariable(st, mvs, pattern.name, nil, path .. ".name")
		else
			expect_string(st, pattern, "name", path)
		end
	elseif pattern.tag == "p_term" then
		check_fields(st, pattern, path, { "tag", "head", "fields" })
		if expect_string(st, pattern, "head", path) then
			local head = indexes.term_heads[pattern.head]
			if not head then
				err(st, path .. ".head", "unknown term head " .. pattern.head)
			else
				local expected = {}
				for _, field in ipairs(head.fields) do
					expected[field.name] = true
				end
				validate_pattern_map(st, pattern.fields, expected, path .. ".fields", indexes, mvs, allow_implicit_metas)
			end
		end
	elseif pattern.tag == "p_scoped" then
		check_fields(st, pattern, path, { "tag", "binders", "body" })
		if expect_array(st, pattern, "binders", path) then
			for i, name in ipairs(pattern.binders) do
				expect_metavariable(st, mvs, name, "binder", path .. ".binders[" .. i .. "]")
			end
		end
		validate_pattern(st, pattern.body, path .. ".body", indexes, mvs, allow_implicit_metas)
	elseif pattern.tag == "p_list" then
		check_fields(st, pattern, path, { "tag", "items" })
		if expect_array(st, pattern, "items", path) then
			for i, item in ipairs(pattern.items) do
				validate_pattern(st, item, path .. ".items[" .. i .. "]", indexes, mvs, allow_implicit_metas)
			end
		end
	elseif pattern.tag == "p_object" then
		check_fields(st, pattern, path, { "tag", "fields" })
		if table_ok(st, pattern.fields, path .. ".fields") then
			for key, value in pairs(pattern.fields) do
				if type(key) ~= "string" then
					err(st, path .. ".fields", "object pattern keys must be strings")
				else
					validate_pattern(st, value, path .. ".fields." .. key, indexes, mvs, allow_implicit_metas)
				end
			end
		end
	elseif pattern.tag == "p_bound_ref" then
		check_fields(st, pattern, path, { "tag", "name" })
		expect_metavariable_one_of(st, mvs, pattern.name, { "bound_ref", "binder" }, path .. ".name")
	elseif pattern.tag == "p_binder_ref" then
		check_fields(st, pattern, path, { "tag", "name" })
		expect_metavariable(st, mvs, pattern.name, "binder", path .. ".name")
	elseif pattern.tag == "p_literal" then
		check_fields(st, pattern, path, { "tag", "value" })
		local tv = type(pattern.value)
		if tv == "number" then
			if pattern.value ~= pattern.value or pattern.value == math.huge or pattern.value == -math.huge or pattern.value % 1 ~= 0 then
				err(st, path .. ".value", "literal pattern must be an F1 integer, string, or boolean")
			end
		elseif tv ~= "string" and tv ~= "boolean" then
			err(st, path .. ".value", "literal pattern must be an F1 integer, string, or boolean")
		end
	elseif pattern.tag == "p_enum" then
		check_fields(st, pattern, path, { "tag", "value" })
		expect_string(st, pattern, "value", path)
	end
end

validate_claim_pattern = function(st, pattern, path, indexes, mvs, expected_judgment, allow_implicit_metas)
	if not table_ok(st, pattern, path) then return end
	check_fields(st, pattern, path, { "tag", "judgment", "args" })
	if pattern.tag ~= "claim_pattern" then err(st, path .. ".tag", "expected claim_pattern") end
	if expect_string(st, pattern, "judgment", path) then
		local judgment = indexes.judgments[pattern.judgment]
		if not judgment then
			err(st, path .. ".judgment", "unknown judgment " .. pattern.judgment)
		elseif expected_judgment and pattern.judgment ~= expected_judgment then
			err(st, path .. ".judgment", "expected judgment " .. expected_judgment)
		else
			local expected = {}
			for _, param in ipairs(judgment.params) do
				expected[param.name] = true
			end
			validate_pattern_map(st, pattern.args, expected, path .. ".args", indexes, mvs, allow_implicit_metas)
		end
	end
end

local function validate_premise(st, premise, path, indexes, mvs)
	check_fields(st, premise, path, { "tag", "claim" }, { "scope_from" })
	if premise.tag ~= "premise_pattern" then err(st, path .. ".tag", "expected premise_pattern") end
	validate_claim_pattern(st, premise.claim, path .. ".claim", indexes, mvs, nil, false)
	if premise.scope_from ~= nil then
		local spath = path .. ".scope_from"
		local scope_from = premise.scope_from
		check_fields(st, scope_from, spath, { "tag", "source_metavariable", "binder_metavariables", "body_metavariable" })
		if scope_from.tag ~= "scoped_open" then err(st, spath .. ".tag", "expected scoped_open") end
		expect_metavariable(st, mvs, scope_from.source_metavariable, "scoped", spath .. ".source_metavariable")
		expect_metavariable(st, mvs, scope_from.body_metavariable, nil, spath .. ".body_metavariable")
		if expect_array(st, scope_from, "binder_metavariables", spath) then
			for i, name in ipairs(scope_from.binder_metavariables) do
				expect_metavariable(st, mvs, name, "binder", spath .. ".binder_metavariables[" .. i .. "]")
			end
		end
	end
end

local function validate_structural_condition(st, condition, path, mvs)
	if not table_ok(st, condition, path) then return end
	if type(condition.tag) ~= "string" or not CONDITION_TAGS[condition.tag] then
		err(st, path .. ".tag", "unknown structural condition tag")
		return
	end
	if condition.tag == "cond_subst" then
		check_fields(st, condition, path, { "tag", "source", "binder", "replacement", "expected_result" })
		validate_condition_operand(st, condition.source, path .. ".source", mvs, nil)
		validate_condition_operand(st, condition.binder, path .. ".binder", mvs, "binder")
		validate_condition_operand(st, condition.replacement, path .. ".replacement", mvs, nil)
		validate_condition_operand(st, condition.expected_result, path .. ".expected_result", mvs, nil)
	else
		check_fields(st, condition, path, { "tag", "left", "right" })
		local kind = nil
		if condition.tag == "cond_category_eq" then
			kind = "category"
		elseif condition.tag == "cond_binder_eq" or condition.tag == "cond_binder_neq" then
			kind = "binder"
		elseif condition.tag == "cond_literal_eq" or condition.tag == "cond_digest_eq" then
			kind = "scalar"
		end
		validate_condition_operand(st, condition.left, path .. ".left", mvs, kind)
		validate_condition_operand(st, condition.right, path .. ".right", mvs, kind)
	end
end

local function validate_rules(st, theory, indexes)
	for i, rule in ipairs(theory.rules) do
		local path = "theory.rules[" .. i .. "]"
		check_fields(st, rule, path, {
			"tag", "name", "judgment", "metavariables", "conclusion", "premises", "structural_conditions",
		})
		if rule.tag ~= "rule" then err(st, path .. ".tag", "expected rule") end
		expect_string(st, rule, "name", path)
		if expect_string(st, rule, "judgment", path) and not indexes.judgments[rule.judgment] then
			err(st, path .. ".judgment", "unknown judgment " .. rule.judgment)
		end
		local mvs = validate_metavariables(st, rule, path, indexes)
		validate_claim_pattern(st, rule.conclusion, path .. ".conclusion", indexes, mvs, rule.judgment, false)
		if expect_array(st, rule, "premises", path) then
			for j, premise in ipairs(rule.premises) do
				validate_premise(st, premise, path .. ".premises[" .. j .. "]", indexes, mvs)
			end
		end
		if expect_array(st, rule, "structural_conditions", path) then
			for j, condition in ipairs(rule.structural_conditions) do
				validate_structural_condition(st, condition, path .. ".structural_conditions[" .. j .. "]", mvs)
			end
		end
	end
end

local function validate_oracles(st, theory, indexes)
	for i, oracle in ipairs(theory.oracles) do
		local path = "theory.oracles[" .. i .. "]"
		check_fields(st, oracle, path, {
			"tag", "oracle_kind", "allowed_judgments", "input_schema", "result_schema",
		}, { "trust_policy_schema" })
		if oracle.tag ~= "oracle" then err(st, path .. ".tag", "expected oracle") end
		expect_string(st, oracle, "oracle_kind", path)
		if expect_array(st, oracle, "allowed_judgments", path) then
			for j, name in ipairs(oracle.allowed_judgments) do
				if type(name) ~= "string" then
					err(st, path .. ".allowed_judgments[" .. j .. "]", "expected string")
				elseif not indexes.judgments[name] then
					err(st, path .. ".allowed_judgments[" .. j .. "]", "unknown judgment " .. name)
				end
			end
		end
		validate_field_schema(st, oracle.input_schema, path .. ".input_schema", indexes)
		validate_field_schema(st, oracle.result_schema, path .. ".result_schema", indexes)
		if oracle.trust_policy_schema ~= nil then
			validate_field_schema(st, oracle.trust_policy_schema, path .. ".trust_policy_schema", indexes)
		end
	end
end

local function validate_roots(st, theory, indexes)
	for i, root in ipairs(theory.roots) do
		local path = "theory.roots[" .. i .. "]"
		check_fields(st, root, path, {
			"tag", "root_kind", "required_judgment", "required_claim_pattern", "scope_policy",
		})
		if root.tag ~= "root_decl" then err(st, path .. ".tag", "expected root_decl") end
		expect_string(st, root, "root_kind", path)
		if expect_string(st, root, "required_judgment", path) and not indexes.judgments[root.required_judgment] then
			err(st, path .. ".required_judgment", "unknown judgment " .. root.required_judgment)
		end
		if root.scope_policy ~= "closed" and root.scope_policy ~= "open" then
			err(st, path .. ".scope_policy", "expected closed or open")
		end
		validate_claim_pattern(st, root.required_claim_pattern, path .. ".required_claim_pattern", indexes, {}, root.required_judgment, true)
	end
end

local function exact_field_names(st, fields, expected, path)
	if not table_ok(st, fields, path) then return false end
	if #fields > 0 and is_array(fields) then
		err(st, path, "expected string-keyed field map")
		return false
	end
	for name in pairs(expected) do
		if fields[name] == nil then err(st, path .. "." .. name, "missing field") end
	end
	for name in pairs(fields) do
		if type(name) ~= "string" then
			err(st, path, "field map keys must be strings")
		elseif not expected[name] then
			err(st, path .. "." .. name, "unknown field")
		end
	end
	return true
end

local function find_binder(scope_stack, binder_id)
	for frame_i = #scope_stack, 1, -1 do
		local frame = scope_stack[frame_i]
		local binder = frame[binder_id]
		if binder then return binder end
	end
	return nil
end

local function validate_literal_value(st, schema, value, path)
	local kind = schema.literal_kind
	local tv = type(value)
	if kind == "string" then
		if tv ~= "string" then err(st, path, "expected string literal") end
	elseif kind == "boolean" then
		if tv ~= "boolean" then err(st, path, "expected boolean literal") end
	elseif kind == "integer" then
		if tv ~= "number" or value ~= value or value == math.huge or value == -math.huge or value % 1 ~= 0 then
			err(st, path, "expected integer literal")
		end
	elseif kind == "number" then
		if tv ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			err(st, path, "expected finite number literal")
		end
	end
end

local function validate_binder_value(st, binder, path, indexes, scope_stack, frame)
	check_fields(st, binder, path, { "tag", "binder_id", "schema", "fields" })
	if binder.tag ~= "binder" then err(st, path .. ".tag", "expected binder") end
	expect_string(st, binder, "binder_id", path)
	local schema = nil
	if expect_string(st, binder, "schema", path) then
		schema = indexes.binder_schemas[binder.schema]
		if not schema then err(st, path .. ".schema", "unknown binder schema " .. binder.schema) end
	end
	if type(binder.binder_id) == "string" and frame then
		if frame[binder.binder_id] then
			err(st, path .. ".binder_id", "duplicate binder_id " .. binder.binder_id .. " in scope frame")
		else
			frame[binder.binder_id] = binder
		end
	end
	if schema then
		local expected = {}
		for _, field in ipairs(schema.fields) do
			expected[field.name] = field
		end
		if exact_field_names(st, binder.fields, expected, path .. ".fields") then
			for name, field_schema in pairs(expected) do
				if binder.fields[name] ~= nil then
					validate_value(st, field_schema, binder.fields[name], path .. ".fields." .. name, indexes, scope_stack)
				end
			end
		end
	end
end

local function validate_binder_frame(st, binders, path, indexes, scope_stack)
	local frame = {}
	if expect_array(st, { binders = binders }, "binders", path) then
		for i, binder in ipairs(binders) do
			validate_binder_value(st, binder, path .. ".binders[" .. i .. "]", indexes, scope_stack, frame)
		end
	end
	return frame
end

local function validate_term_value(st, value, path, indexes, scope_stack)
	check_fields(st, value, path, { "tag", "head", "fields" })
	if value.tag ~= "term" then err(st, path .. ".tag", "expected term") end
	local head = nil
	if expect_string(st, value, "head", path) then
		head = indexes.term_heads[value.head]
		if not head then err(st, path .. ".head", "unknown term head " .. value.head) end
	end
	if head then
		local expected = {}
		for _, field in ipairs(head.fields) do
			expected[field.name] = field
		end
		if exact_field_names(st, value.fields, expected, path .. ".fields") then
			for name, schema in pairs(expected) do
				if value.fields[name] ~= nil then
					validate_value(st, schema, value.fields[name], path .. ".fields." .. name, indexes, scope_stack)
				end
			end
		end
	end
end

validate_value = function(st, schema, value, path, indexes, scope_stack)
	if schema.tag == "field_category" then
		if not table_ok(st, value, path) then return end
		if value.tag ~= "term" then
			err(st, path .. ".tag", "expected term")
			return
		end
		local head = indexes.term_heads[value.head]
		if head and head.result_category ~= schema.category then
			err(st, path .. ".head", "term head category mismatch: expected " .. schema.category)
		end
		validate_term_value(st, value, path, indexes, scope_stack)
	elseif schema.tag == "field_bound_ref" then
		if not table_ok(st, value, path) then return end
		check_fields(st, value, path, { "tag", "binder_id", "namespace" })
		if value.tag ~= "bound_ref" then err(st, path .. ".tag", "expected bound_ref") end
		expect_string(st, value, "binder_id", path)
		if expect_string(st, value, "namespace", path) and not indexes.namespaces[value.namespace] then
			err(st, path .. ".namespace", "unknown namespace " .. value.namespace)
		end
		if type(value.binder_id) == "string" then
			local binder = find_binder(scope_stack, value.binder_id)
			if not binder then
				err(st, path .. ".binder_id", "unresolved bound reference " .. value.binder_id)
			else
				local binder_schema = indexes.binder_schemas[binder.schema]
				if binder_schema and value.namespace ~= binder_schema.namespace then
					err(st, path .. ".namespace", "binder namespace mismatch")
				end
			end
		end
	elseif schema.tag == "field_binder" then
		validate_binder_value(st, value, path, indexes, scope_stack, nil)
		if type(value) == "table" and value.schema ~= schema.binder_schema then
			err(st, path .. ".schema", "expected binder schema " .. schema.binder_schema)
		end
	elseif schema.tag == "field_scoped" then
		if not table_ok(st, value, path) then return end
		check_fields(st, value, path, { "tag", "binders", "body" })
		if value.tag ~= "scoped" then err(st, path .. ".tag", "expected scoped") end
		local frame = validate_binder_frame(st, value.binders, path, indexes, scope_stack)
		local expected_count = #schema.binders
		if type(value.binders) == "table" and is_array(value.binders) and #value.binders ~= expected_count then
			err(st, path .. ".binders", "expected " .. expected_count .. " binders")
		end
		if type(value.binders) == "table" and is_array(value.binders) then
			for i, binder in ipairs(value.binders) do
				local expected_ref = schema.binders[i]
				if expected_ref and type(binder) == "table" and binder.schema ~= expected_ref.schema then
					err(st, path .. ".binders[" .. i .. "].schema", "expected binder schema " .. expected_ref.schema)
				end
			end
		end
		scope_stack[#scope_stack + 1] = frame
		validate_value(st, schema.body, value.body, path .. ".body", indexes, scope_stack)
		scope_stack[#scope_stack] = nil
	elseif schema.tag == "field_list" then
		if not table_ok(st, value, path) then return end
		if not is_array(value) then
			err(st, path, "expected dense array")
			return
		end
		for i, item in ipairs(value) do
			validate_value(st, schema.item, item, path .. "[" .. i .. "]", indexes, scope_stack)
		end
	elseif schema.tag == "field_literal" then
		validate_literal_value(st, schema, value, path)
	elseif schema.tag == "field_enum" then
		if type(value) ~= "string" then
			err(st, path, "expected enum string")
		else
			local ok = false
			for _, choice in ipairs(schema.values) do
				if value == choice then ok = true end
			end
			if not ok then err(st, path, "unknown enum value " .. value) end
		end
	elseif schema.tag == "field_object" then
		if not table_ok(st, value, path) then return end
		check_fields(st, value, path, { "tag", "fields" })
		if value.tag ~= "object" then err(st, path .. ".tag", "expected object") end
		local expected = {}
		for _, field in ipairs(schema.fields) do
			expected[field.name] = field
		end
		if exact_field_names(st, value.fields, expected, path .. ".fields") then
			for name, field_schema in pairs(expected) do
				if value.fields[name] ~= nil then
					validate_value(st, field_schema, value.fields[name], path .. ".fields." .. name, indexes, scope_stack)
				end
			end
		end
	end
end

local function validate_claim(st, claim, path, indexes)
	if not table_ok(st, claim, path) then return end
	check_fields(st, claim, path, { "tag", "scope", "judgment", "args" })
	if claim.tag ~= "claim" then err(st, path .. ".tag", "expected claim") end
	local scope_stack = {}
	local frame = validate_binder_frame(st, claim.scope, path .. ".scope", indexes, scope_stack)
	scope_stack[#scope_stack + 1] = frame
	local judgment = nil
	if expect_string(st, claim, "judgment", path) then
		judgment = indexes.judgments[claim.judgment]
		if not judgment then err(st, path .. ".judgment", "unknown judgment " .. claim.judgment) end
	end
	if judgment then
		local expected = {}
		for _, param in ipairs(judgment.params) do
			expected[param.name] = param
		end
		if exact_field_names(st, claim.args, expected, path .. ".args") then
			for name, schema in pairs(expected) do
				if claim.args[name] ~= nil then
					validate_value(st, schema, claim.args[name], path .. ".args." .. name, indexes, scope_stack)
				end
			end
		end
	end
	scope_stack[#scope_stack] = nil
end

local function index_evidence_nodes(st, certificate)
	local nodes = {}
	if expect_array(st, certificate, "evidence", "certificate") then
		for i, node in ipairs(certificate.evidence) do
			if type(node) == "table" and type(node.node_id) == "string" then
				if nodes[node.node_id] then
					err(st, "certificate.evidence[" .. i .. "].node_id", "duplicate evidence node_id " .. node.node_id)
				else
					nodes[node.node_id] = node
				end
			end
		end
	end
	return nodes
end

local function validate_evidence_node(st, node, path, theory, indexes, nodes)
	check_fields(st, node, path, { "tag", "node_id", "theory_id", "judgment", "claim", "justification" })
	if node.tag ~= "evidence" then err(st, path .. ".tag", "expected evidence") end
	expect_string(st, node, "node_id", path)
	if expect_string(st, node, "theory_id", path) and node.theory_id ~= theory.theory_id then
		err(st, path .. ".theory_id", "certificate theory mismatch")
	end
	expect_string(st, node, "judgment", path)
	validate_claim(st, node.claim, path .. ".claim", indexes)
	if type(node.claim) == "table" and node.judgment ~= node.claim.judgment then
		err(st, path .. ".judgment", "evidence judgment must match claim judgment")
	end
	local app = node.justification
	if table_ok(st, app, path .. ".justification") then
		if app.tag == "rule_application" then
			check_fields(st, app, path .. ".justification", { "tag", "rule", "premises" })
			if expect_string(st, app, "rule", path .. ".justification") and not indexes.rules[app.rule] then
				err(st, path .. ".justification.rule", "unknown rule " .. app.rule)
			end
			if expect_array(st, app, "premises", path .. ".justification") then
				for i, premise_id in ipairs(app.premises) do
					if type(premise_id) ~= "string" then
						err(st, path .. ".justification.premises[" .. i .. "]", "expected evidence node_id string")
					elseif not nodes[premise_id] then
						err(st, path .. ".justification.premises[" .. i .. "]", "unknown premise node_id " .. premise_id)
					end
				end
			end
		elseif app.tag == "oracle_application" then
			err(st, path .. ".justification.tag", "oracle applications are not admitted in this checker slice")
		else
			err(st, path .. ".justification.tag", "unknown justification tag")
		end
	end
end

local function validate_certificate_roots(st, certificate, indexes, nodes)
	if expect_array(st, certificate, "roots", "certificate") then
		for i, root in ipairs(certificate.roots) do
			local path = "certificate.roots[" .. i .. "]"
			check_fields(st, root, path, { "tag", "root_kind", "node_id" })
			if root.tag ~= "root" then err(st, path .. ".tag", "expected root") end
			if expect_string(st, root, "root_kind", path) and not indexes.roots[root.root_kind] then
				err(st, path .. ".root_kind", "unknown root kind " .. root.root_kind)
			end
			if expect_string(st, root, "node_id", path) and not nodes[root.node_id] then
				err(st, path .. ".node_id", "unknown evidence node_id " .. root.node_id)
			end
		end
	end
end

--: (table) -> (table | nil, { string, ... } | nil)
function M.validate_theory(theory)
	local st = new_state()
	check_fields(st, theory, "theory", {
		"tag", "theory_id", "version", "namespaces", "categories", "term_heads",
		"binder_schemas", "judgments", "rules", "oracles", "roots",
	})
	if theory.tag ~= "theory_spec" then err(st, "theory.tag", "expected theory_spec") end
	expect_string(st, theory, "theory_id", "theory")
	expect_string(st, theory, "version", "theory")

	local array_fields = {
		"namespaces", "categories", "term_heads", "binder_schemas", "judgments", "rules", "oracles", "roots",
	}
	for _, key in ipairs(array_fields) do
		expect_array(st, theory, key, "theory")
	end
	if type(theory.roots) == "table" and is_array(theory.roots) and #theory.roots == 0 then
		err(st, "theory.roots", "theory must declare at least one root kind")
	end

	local indexes = {
		namespaces = {},
		categories = {},
		term_heads = {},
		binder_schemas = {},
		judgments = {},
		rules = {},
		oracles = {},
		roots = {},
	}
	if #st.errors > 0 then return nil, st.errors end

	for i, namespace in ipairs(theory.namespaces) do
		validate_name_decl(st, namespace, "theory.namespaces[" .. i .. "]", "namespace")
	end
	for i, category in ipairs(theory.categories) do
		validate_category_decl(st, category, "theory.categories[" .. i .. "]")
	end

	index_by_name(st, indexes.namespaces, theory.namespaces, "name", "theory.namespaces")
	index_by_name(st, indexes.categories, theory.categories, "name", "theory.categories")
	index_by_name(st, indexes.term_heads, theory.term_heads, "name", "theory.term_heads")
	index_by_name(st, indexes.binder_schemas, theory.binder_schemas, "name", "theory.binder_schemas")
	index_by_name(st, indexes.judgments, theory.judgments, "name", "theory.judgments")
	index_by_name(st, indexes.rules, theory.rules, "name", "theory.rules")
	index_by_name(st, indexes.oracles, theory.oracles, "oracle_kind", "theory.oracles")
	index_by_name(st, indexes.roots, theory.roots, "root_kind", "theory.roots")

	validate_term_heads(st, theory, indexes)
	validate_binder_schemas(st, theory, indexes)
	validate_judgments(st, theory, indexes)
	validate_rules(st, theory, indexes)
	validate_oracles(st, theory, indexes)
	validate_roots(st, theory, indexes)

	if #st.errors > 0 then return nil, st.errors end
	return indexes
end

--: (table, table) -> (table | nil, { string, ... } | nil)
function M.validate_certificate(theory, certificate)
	local indexes, theory_errors = M.validate_theory(theory)
	if not indexes then return nil, theory_errors end
	local st = new_state()
	check_fields(st, certificate, "certificate", {
		"tag", "framework_version", "theory_id", "theory_version", "evidence", "roots",
	}, { "terms" })
	if certificate.tag ~= "certificate" then err(st, "certificate.tag", "expected certificate") end
	if expect_string(st, certificate, "framework_version", "certificate")
		and certificate.framework_version ~= M.FRAMEWORK_VERSION then
		err(st, "certificate.framework_version", "unsupported framework version " .. certificate.framework_version)
	end
	if expect_string(st, certificate, "theory_id", "certificate") and certificate.theory_id ~= theory.theory_id then
		err(st, "certificate.theory_id", "theory_id does not match selected theory")
	end
	if expect_string(st, certificate, "theory_version", "certificate") and certificate.theory_version ~= theory.version then
		err(st, "certificate.theory_version", "theory_version does not match selected theory")
	end
	if certificate.terms ~= nil and expect_array(st, certificate, "terms", "certificate") then
		for i, term in ipairs(certificate.terms) do
			validate_term_value(st, term, "certificate.terms[" .. i .. "]", indexes, {})
		end
	end
	local nodes = index_evidence_nodes(st, certificate)
	validate_certificate_roots(st, certificate, indexes, nodes)
	if type(certificate.evidence) == "table" and is_array(certificate.evidence) then
		for i, node in ipairs(certificate.evidence) do
			validate_evidence_node(st, node, "certificate.evidence[" .. i .. "]", theory, indexes, nodes)
		end
	end
	if #st.errors > 0 then return nil, st.errors end
	return { indexes = indexes }
end

return M
