-- F2 shape validation for framework theory specs.
--
-- This module validates declarations and field-schema references. It does not
-- replay rules, validate certificates, or interpret theory-specific meaning.

local M = {}

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
	if not expect_array(st, rule, "metavariables", path) then return end
	local seen = {}
	for i, mv in ipairs(rule.metavariables) do
		local mpath = path .. ".metavariables[" .. i .. "]"
		check_fields(st, mv, mpath, { "tag", "name", "kind", "mode" }, { "category", "namespace" })
		if mv.tag ~= "metavariable" then err(st, mpath .. ".tag", "expected metavariable") end
		if expect_string(st, mv, "name", mpath) then
			if seen[mv.name] then err(st, mpath .. ".name", "duplicate metavariable " .. mv.name) end
			seen[mv.name] = true
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
		validate_metavariables(st, rule, path, indexes)
		expect_array(st, rule, "premises", path)
		expect_array(st, rule, "structural_conditions", path)
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

return M
