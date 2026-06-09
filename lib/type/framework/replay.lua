-- Framework rule replay.
--
-- The initial replay subset is F3, with alpha-aware equality/root digests added
-- as F4 substrate. It still rejects scoped premise opening, substitution, and
-- oracles.

local alpha = require("lib.type.framework.alpha")
local canonical = require("lib.type.framework.canonical")
local shape = require("lib.type.framework.shape")

local M = {}

local UNSUPPORTED_CONDITIONS = {
	cond_binder_eq = true,
	cond_binder_neq = true,
	cond_alpha_eq = true,
	cond_subst = true,
}

local function err(errors, path, msg)
	errors[#errors + 1] = path .. ": " .. msg
end

local function structural_key(value)
	local encoded, msg = canonical.serialize(value)
	if not encoded then return nil, msg end
	return encoded
end

local function same_value(a, b, indexes)
	local ak, amsg = alpha.key(a, indexes, {})
	if not ak then
		ak, amsg = structural_key(a)
	end
	if not ak then return false, amsg end
	local bk, bmsg = alpha.key(b, indexes, {})
	if not bk then
		bk, bmsg = structural_key(b)
	end
	if not bk then return false, bmsg end
	return ak == bk
end

local function bind_meta(bindings, name, value, indexes)
	local prior = bindings[name]
	if prior == nil then
		bindings[name] = value
		return true
	end
	local ok, msg = same_value(prior, value, indexes)
	if not ok then return false, msg or "repeated metavariable mismatch" end
	return true
end

local match_pattern

local function match_field_map(pattern_fields, value_fields, path, bindings, errors, indexes)
	for name in pairs(pattern_fields) do
		if value_fields[name] == nil then
			err(errors, path .. "." .. name, "missing candidate field")
		else
			match_pattern(pattern_fields[name], value_fields[name], path .. "." .. name, bindings, errors, indexes)
		end
	end
	for name in pairs(value_fields) do
		if pattern_fields[name] == nil then err(errors, path .. "." .. name, "unexpected candidate field") end
	end
end

match_pattern = function(pattern, value, path, bindings, errors, indexes)
	if pattern.tag == "p_meta" then
		local ok, msg = bind_meta(bindings, pattern.name, value, indexes)
		if not ok then err(errors, path, msg or "metavariable mismatch") end
	elseif pattern.tag == "p_term" then
		if type(value) ~= "table" or value.tag ~= "term" then
			err(errors, path, "expected term")
			return
		end
		if value.head ~= pattern.head then
			err(errors, path .. ".head", "expected term head " .. pattern.head)
			return
		end
		match_field_map(pattern.fields, value.fields or {}, path .. ".fields", bindings, errors, indexes)
	elseif pattern.tag == "p_list" then
		if type(value) ~= "table" or value.tag ~= nil then
			err(errors, path, "expected list")
			return
		end
		if #value ~= #pattern.items then
			err(errors, path, "list length mismatch")
			return
		end
		for i, item in ipairs(pattern.items) do
			match_pattern(item, value[i], path .. "[" .. i .. "]", bindings, errors, indexes)
		end
	elseif pattern.tag == "p_object" then
		if type(value) ~= "table" or value.tag ~= "object" then
			err(errors, path, "expected object")
			return
		end
		match_field_map(pattern.fields, value.fields or {}, path .. ".fields", bindings, errors, indexes)
	elseif pattern.tag == "p_literal" then
		if value ~= pattern.value then err(errors, path, "literal mismatch") end
	elseif pattern.tag == "p_enum" then
		if value ~= pattern.value then err(errors, path, "enum mismatch") end
	else
		err(errors, path, "unsupported pattern form " .. tostring(pattern.tag))
	end
end

local function match_claim(pattern, claim, path, bindings, errors, indexes)
	if claim.judgment ~= pattern.judgment then
		err(errors, path .. ".judgment", "expected judgment " .. pattern.judgment)
		return
	end
	if type(claim.scope) == "table" and #claim.scope > 0 then
		err(errors, path .. ".scope", "F3 does not admit open claims")
	end
	match_field_map(pattern.args, claim.args or {}, path .. ".args", bindings, errors, indexes)
end

local function rule_supported(rule, path, errors)
	for i, mv in ipairs(rule.metavariables) do
		if mv.mode ~= "input" then
			err(errors, path .. ".metavariables[" .. i .. "].mode", "F3 supports input metavariables only")
		end
		if mv.kind == "binder" or mv.kind == "bound_ref" or mv.kind == "scoped" then
			err(errors, path .. ".metavariables[" .. i .. "].kind", "unsupported F3 metavariable kind " .. mv.kind)
		end
	end
	for i, premise in ipairs(rule.premises) do
		if premise.scope_from ~= nil then
			err(errors, path .. ".premises[" .. i .. "].scope_from", "F3 does not admit scoped premise opening")
		end
	end
	for i, condition in ipairs(rule.structural_conditions) do
		if UNSUPPORTED_CONDITIONS[condition.tag] then
			err(errors, path .. ".structural_conditions[" .. i .. "].tag", "unsupported F3 structural condition " .. condition.tag)
		end
	end
end

local function resolve_operand(operand, bindings)
	local value = bindings[operand.name or operand.base]
	if operand.tag == "operand_meta" then return value end
	for _, segment in ipairs(operand.path) do
		if type(value) ~= "table" then return nil end
		if value.tag == "term" or value.tag == "object" then
			value = value.fields and value.fields[segment]
		else
			value = value[segment]
		end
	end
	return value
end

local function check_conditions(conditions, bindings, path, errors, indexes)
	for i, condition in ipairs(conditions) do
		local cpath = path .. "[" .. i .. "]"
		if condition.tag == "cond_category_eq" or condition.tag == "cond_literal_eq" then
			local left = resolve_operand(condition.left, bindings)
			local right = resolve_operand(condition.right, bindings)
			local ok = left ~= nil and right ~= nil and same_value(left, right, indexes)
			if not ok then err(errors, cpath, "condition equality failed") end
		elseif condition.tag == "cond_list_len_eq" then
			local left = resolve_operand(condition.left, bindings)
			local right = resolve_operand(condition.right, bindings)
			if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
				err(errors, cpath, "list length condition failed")
			end
		elseif condition.tag == "cond_digest_eq" then
			local left = resolve_operand(condition.left, bindings)
			local right = resolve_operand(condition.right, bindings)
			local ld = left ~= nil and canonical.digest(left) or nil
			local rd = right ~= nil and canonical.digest(right) or nil
			if ld == nil or rd == nil or ld ~= rd then err(errors, cpath, "digest condition failed") end
		end
	end
end

local function index_nodes(certificate)
	local nodes = {}
	for _, node in ipairs(certificate.evidence) do
		nodes[node.node_id] = node
	end
	return nodes
end

function M.replay(theory, certificate)
	local shape_ok, shape_errors = shape.validate_certificate(theory, certificate)
	if not shape_ok then return nil, shape_errors end

	local errors = {}
	local indexes = shape_ok.indexes
	local nodes = index_nodes(certificate)
	local status = {}
	local root_digests = {}

	local replay_node
	replay_node = function(node_id)
		if status[node_id] == "accepted" then return true end
		if status[node_id] == "rejected" then return false end
		if status[node_id] == "visiting" then
			err(errors, "evidence." .. node_id, "dependency cycle")
			status[node_id] = "rejected"
			return false
		end
		local node = nodes[node_id]
		if not node then
			err(errors, "evidence." .. tostring(node_id), "missing evidence node")
			return false
		end
		status[node_id] = "visiting"
		local before = #errors
		local app = node.justification
		if app.tag ~= "rule_application" then
			err(errors, "evidence." .. node_id .. ".justification", "F3 only replays rule applications")
			status[node_id] = "rejected"
			return false
		end
		local seen_premises = {}
		for i, premise_id in ipairs(app.premises) do
			if seen_premises[premise_id] then
				err(errors, "evidence." .. node_id .. ".premises[" .. i .. "]", "duplicate premise reference")
			end
			seen_premises[premise_id] = true
			if not replay_node(premise_id) then
				err(errors, "evidence." .. node_id .. ".premises[" .. i .. "]", "premise replay failure")
			end
		end

		local rule = indexes.rules[app.rule]
		rule_supported(rule, "rule." .. rule.name, errors)
		if node.judgment ~= rule.judgment then
			err(errors, "evidence." .. node_id .. ".judgment", "rule judgment mismatch")
		end
		if #app.premises ~= #rule.premises then
			err(errors, "evidence." .. node_id .. ".premises", "premise arity mismatch")
		end

		local bindings = {}
		match_claim(rule.conclusion, node.claim, "evidence." .. node_id .. ".claim", bindings, errors, indexes)
		for i, premise in ipairs(rule.premises) do
			local premise_id = app.premises[i]
			local premise_node = premise_id and nodes[premise_id]
			if premise_node then
				match_claim(premise.claim, premise_node.claim, "evidence." .. node_id .. ".premise_claims[" .. i .. "]", bindings, errors, indexes)
			end
		end
		check_conditions(rule.structural_conditions, bindings, "evidence." .. node_id .. ".conditions", errors, indexes)

		if #errors == before then
			status[node_id] = "accepted"
			return true
		end
		status[node_id] = "rejected"
		return false
	end

	for i, root in ipairs(certificate.roots) do
		local node = nodes[root.node_id]
		local root_decl = indexes.roots[root.root_kind]
		if not replay_node(root.node_id) then
			err(errors, "certificate.roots[" .. i .. "]", "root references rejected node")
		elseif node then
			if node.judgment ~= root_decl.required_judgment then
				err(errors, "certificate.roots[" .. i .. "].node_id", "root judgment mismatch")
			end
			if root_decl.scope_policy == "closed" and #node.claim.scope > 0 then
				err(errors, "certificate.roots[" .. i .. "].scope_policy", "closed root has open claim")
			end
			local bindings = {}
			match_claim(root_decl.required_claim_pattern, node.claim, "certificate.roots[" .. i .. "].claim", bindings, errors, indexes)
			local normalized_claim, normalize_err = alpha.normalize_claim(node.claim, indexes)
			local digest, digest_err
			if normalized_claim then
				digest, digest_err = canonical.prefixed_digest("root", { root_kind = root.root_kind, claim = normalized_claim })
			else
				digest_err = normalize_err
			end
			if digest then
				root_digests[#root_digests + 1] = digest
			else
				err(errors, "certificate.roots[" .. i .. "]", digest_err)
			end
		end
	end

	if #errors > 0 then return nil, errors end
	return { root_digests = root_digests }
end

return M
