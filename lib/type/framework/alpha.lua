-- Alpha-normalization helpers for binder-aware framework replay.
--
-- This is framework scope plumbing only: it resolves F0 bound references to
-- lexical identities and removes source binder labels from semantic equality.

local canonical = require("lib.type.framework.canonical")

local M = {}

local function push(out, value)
	out[#out + 1] = value
end

local function resolve(scope_stack, binder_id, namespace)
	for depth = 0, #scope_stack - 1 do
		local frame = scope_stack[#scope_stack - depth]
		for index, entry in ipairs(frame) do
			if entry.binder.binder_id == binder_id then
				if entry.namespace ~= namespace then
					return nil, "binder namespace mismatch"
				end
				return { tag = "alpha_ref", namespace = namespace, depth = depth, index = index }
			end
		end
	end
	return nil, "unresolved bound reference " .. tostring(binder_id)
end

local normalize_inner

local function normalize_binder(binder, indexes, scope_stack)
	local schema = indexes.binder_schemas[binder.schema]
	local fields = {}
	for key, value in pairs(binder.fields or {}) do
		local normalized, msg = normalize_inner(value, indexes, scope_stack)
		if msg then return nil, msg end
		fields[key] = normalized
	end
	return {
		tag = "alpha_binder",
		schema = binder.schema,
		namespace = schema and schema.namespace or nil,
		fields = fields,
	}
end

local function binder_frame(binders, indexes, scope_stack)
	local frame = {}
	local normalized_binders = {}
	for _, binder in ipairs(binders) do
		local schema = indexes.binder_schemas[binder.schema]
		local normalized, msg = normalize_binder(binder, indexes, scope_stack)
		if msg then return nil, nil, msg end
		push(normalized_binders, normalized)
		push(frame, {
			binder = binder,
			namespace = schema and schema.namespace or nil,
		})
	end
	return frame, normalized_binders
end

normalize_inner = function(value, indexes, scope_stack)
	local tv = type(value)
	if tv == "string" or tv == "number" or tv == "boolean" then
		return value
	end
	if tv ~= "table" then return nil, "unsupported alpha value type " .. tv end
	if value.tag == "term" then
		local fields = {}
		for key, field in pairs(value.fields or {}) do
			local normalized, msg = normalize_inner(field, indexes, scope_stack)
			if msg then return nil, msg end
			fields[key] = normalized
		end
		return { tag = "term", head = value.head, fields = fields }
	elseif value.tag == "bound_ref" then
		return resolve(scope_stack, value.binder_id, value.namespace)
	elseif value.tag == "binder" then
		return normalize_binder(value, indexes, scope_stack)
	elseif value.tag == "scoped" then
		local frame, normalized_binders, msg = binder_frame(value.binders or {}, indexes, scope_stack)
		if msg then return nil, msg end
		scope_stack[#scope_stack + 1] = frame
		local body, body_msg = normalize_inner(value.body, indexes, scope_stack)
		scope_stack[#scope_stack] = nil
		if body_msg then return nil, body_msg end
		return { tag = "scoped", binders = normalized_binders, body = body }
	elseif value.tag == "object" then
		local fields = {}
		for key, field in pairs(value.fields or {}) do
			local normalized, msg = normalize_inner(field, indexes, scope_stack)
			if msg then return nil, msg end
			fields[key] = normalized
		end
		return { tag = "object", fields = fields }
	end
	if #value > 0 then
		local out = {}
		for i, item in ipairs(value) do
			local normalized, msg = normalize_inner(item, indexes, scope_stack)
			if msg then return nil, msg end
			out[i] = normalized
		end
		return out
	end
	return nil, "unknown alpha value tag " .. tostring(value.tag)
end

function M.normalize(value, indexes, scope_stack)
	return normalize_inner(value, indexes, scope_stack or {})
end

function M.key(value, indexes, scope_stack)
	local normalized, msg = M.normalize(value, indexes, scope_stack)
	if msg then return nil, msg end
	return canonical.serialize(normalized)
end

function M.normalize_claim(claim, indexes)
	local scope_stack = {}
	local frame, normalized_scope, msg = binder_frame(claim.scope or {}, indexes, scope_stack)
	if msg then return nil, msg end
	scope_stack[#scope_stack + 1] = frame
	local args = {}
	for key, value in pairs(claim.args or {}) do
		local normalized, arg_msg = normalize_inner(value, indexes, scope_stack)
		if arg_msg then return nil, arg_msg end
		args[key] = normalized
	end
	scope_stack[#scope_stack] = nil
	return {
		tag = "claim",
		scope = normalized_scope,
		judgment = claim.judgment,
		args = args,
	}
end

function M.claim_key(claim, indexes)
	local normalized, msg = M.normalize_claim(claim, indexes)
	if msg then return nil, msg end
	return canonical.serialize(normalized)
end

function M.equal(a, b, indexes)
	local ak, amsg = M.key(a, indexes, {})
	if not ak then return nil, amsg end
	local bk, bmsg = M.key(b, indexes, {})
	if not bk then return nil, bmsg end
	return ak == bk
end

return M
