-- MR0 certificate verifier spike.
--
-- This module intentionally does not infer. It replays a small subset of the
-- v7 MR0 certificate model from docs/typechecker-v7-mr0-payloads.md.

local M = {}

local SUPPORTED_VERSION = "v7-mr0"

--:: MR0Map = { ... }
--:: MR0List = { [integer]: unknown, ... }
--:: MR0Term = { term_id: string, sort: string, payload: unknown, ... }
--:: MR0Inputs = { type?: string, pack?: string, source_pack?: string, target_pack?: string, producer?: string, consumer?: string, a?: string, b?: string, arm_index?: integer, value?: unknown, exported_claim?: unknown, callee_claim?: string, arg_pack?: string, arrow?: string, ... }
--:: MR0Node = { node_id: string, family: string, rule: string, inputs?: MR0Inputs, outputs: unknown, premises?: { [integer]: string, ... }, ... }
--:: MR0Root = { proof: string, ... }
--:: MR0Cert = { version: string, target: { id: string, ... }, terms: { [integer]: MR0Term, ... } | nil, nodes: { [integer]: MR0Node, ... } | nil, roots: { [integer]: MR0Root, ... }, ... }
--:: MR0State = { terms: { [string]: MR0Term, ... }, nodes: { [string]: MR0Node, ... }, accepted: { [string]: boolean, ... }, outputs: { [string]: unknown, ... } }
--:: ReplayFn = (st: MR0State, node: MR0Node) -> (boolean | nil, unknown)

--: (unknown) -> (nil, string)
local function err(msg)
	return nil, tostring(msg)
end

--: (unknown) -> boolean
local function is_array(t)
	if type(t) ~= "table" then return false end
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		local n = k
		if n < 1 or n % 1 ~= 0 then return false end
	end
	return true
end

--: (unknown, unknown) -> boolean
local function same(a, b)
	if a == b then return true end
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return false end
	if type(b) ~= "table" then return false end
	local at = a
	local bt = b
	for k, v in pairs(at) do
		if not same(v, bt[k]) then return false end
	end
	for k in pairs(bt) do
		if at[k] == nil then return false end
	end
	return true
end

--: (unknown) -> string | nil
local function type_tag(t)
	if type(t) == "string" then return t end
	if type(t) == "table" then
		local tag = t.tag
		if type(tag) == "string" then return tag end
	end
	return nil
end

--: (unknown) -> string | nil
local function base_of_literal(t)
	if type(t) ~= "table" then return nil end
	if t.tag ~= "literal" then return nil end
	local base = t.base
	if type(base) == "string" then return base end
	return nil
end

--: (unknown) -> boolean
local function is_union(t)
	if type(t) ~= "table" then return false end
	if t.tag ~= "union" then return false end
	return is_array(t.arms)
end

--: (unknown) -> boolean
local function is_intersection(t)
	if type(t) ~= "table" then return false end
	if t.tag ~= "intersection" then return false end
	return is_array(t.arms)
end

--: (unknown) -> ({ [integer]: unknown, ... } | nil)
local function pack_items(p)
	if type(p) ~= "table" then return nil end
	if p.tag ~= "pack" then return nil end
	if p.rest ~= nil then return nil end
	local items = p.items
	if type(items) ~= "table" then return nil end
	if not is_array(items) then return nil end
	local out = {}
	for _, item in ipairs(items) do
		out[#out + 1] = item
	end
	return out
end

--: (unknown) -> boolean
local function is_closed_pack(p)
	return pack_items(p) ~= nil
end

--: (unknown) -> (unknown, unknown, string | nil)
local function arrow_parts(t)
	if type(t) ~= "table" then return nil, nil, "arrow type must be table" end
	if t.tag ~= "arrow" then return nil, nil, "call_arrow needs arrow type" end
	local params = t.params
	local returns = t.returns
	if not is_closed_pack(params) then return nil, nil, "arrow params must be closed pack" end
	if not is_closed_pack(returns) then return nil, nil, "arrow returns must be closed pack" end
	if t.effect ~= "pure" then return nil, nil, "MR0 arrow effect must be pure" end
	if t.post ~= true then return nil, nil, "MR0 arrow post must be true" end
	return params, returns, nil
end

--: (unknown) -> (unknown, string | nil)
local function value_claim_type(claim)
	if type(claim) ~= "table" then return nil, "value claim must be table" end
	local typ = claim.type
	if typ == nil then return nil, "value claim missing type" end
	return typ, nil
end

--: (unknown) -> (unknown, string | nil)
local function pack_claim_pack(claim)
	if type(claim) ~= "table" then return nil, "pack claim must be table" end
	local pack = claim.pack
	if pack == nil then return nil, "pack claim missing pack" end
	if not is_closed_pack(pack) then return nil, "pack claim is not closed" end
	return pack, nil
end

--: (unknown) -> (boolean | nil, string | nil)
local function validate_type(t)
	local tag = type_tag(t)
	if tag == "never" or tag == "unknown" or tag == "nil" or tag == "boolean"
		or tag == "integer" or tag == "number" or tag == "string" then
		return true
	end
	if tag == "literal" then
		if type(t) ~= "table" then return false, "literal type must be table" end
		if t.base ~= "boolean" and t.base ~= "integer" and t.base ~= "number" and t.base ~= "string" then
			return false, "invalid literal base"
		end
		return true
	end
	if tag == "primitive_cap" then
		if type(t) ~= "table" then return false, "primitive cap type must be table" end
		local name = t.name
		return name == "$SetMetatable" or name == "$GetMetatable" or name == "$RawGet"
			or name == "$RawSet" or name == "$RawEqual"
	end
	if is_union(t) or is_intersection(t) then
		if type(t) ~= "table" then return false, "compound type must be table" end
		local arms = t.arms
		if type(arms) ~= "table" then return false, "compound type arms must be table" end
		for _, arm in ipairs(arms) do
			local ok, msg = validate_type(arm)
			if not ok then return nil, msg end
		end
		return true
	end
	if tag == "arrow" then
		local params, returns, arrow_msg = arrow_parts(t)
		if not params then return false, arrow_msg end
		local params_items = pack_items(params)
		local returns_items = pack_items(returns)
		if not params_items or not returns_items then return false, "arrow packs must be closed" end
		for _, item in ipairs(params_items) do
			local ok, msg = validate_type(item)
			if not ok then return nil, msg end
		end
		for _, item in ipairs(returns_items) do
			local ok, msg = validate_type(item)
			if not ok then return nil, msg end
		end
		return true
	end
	return false, "unsupported MR0 type"
end

--: ({ [integer]: MR0Map, ... } | nil, string) -> ({ [string]: MR0Map, ... } | nil, string | nil)
local function index_by_id(items, field)
	local out = {}
	for _, item in ipairs(items or {}) do
		local id = item[field]
		if type(id) ~= "string" then return nil, "missing " .. field end
		if out[id] then return nil, "duplicate id " .. tostring(id) end
		out[id] = item
	end
	return out
end

--: (MR0Cert) -> (MR0State | nil, string | nil)
local function mk_state(cert)
	local terms, msg = index_by_id(cert.terms, "term_id")
	if not terms then return nil, msg end
	local nodes, msg2 = index_by_id(cert.nodes, "node_id")
	if not nodes then return nil, msg2 end
	return {
		terms = terms,
		nodes = nodes,
		accepted = {},
		outputs = {},
	}
end

--: (MR0State, string, string | nil) -> (unknown, string | nil)
local function term_payload(st, id, expected_sort)
	local entry = st.terms[id]
	if not entry then return nil, "unknown term " .. tostring(id) end
	if expected_sort and entry.sort ~= expected_sort then
		return nil, "term " .. tostring(id) .. " has sort " .. tostring(entry.sort) .. ", expected " .. expected_sort
	end
	return entry.payload
end

--: (MR0State, string) -> (unknown, string | nil)
local function pack_payload(st, id)
	local p, msg = term_payload(st, id, "pack")
	if not p then return nil, msg end
	if not is_closed_pack(p) then return nil, "pack term is not closed pack" end
	return p
end

--: (MR0State, string) -> (unknown, string | nil)
local function type_payload(st, id)
	return term_payload(st, id, "type")
end

--: (MR0State, string) -> (unknown, string | nil)
local function value_claim_payload(st, id)
	local claim, msg = term_payload(st, id, "value_claim")
	if not claim then return nil, msg end
	local _, claim_msg = value_claim_type(claim)
	if claim_msg then return nil, claim_msg end
	return claim
end

--: (MR0State, string) -> (unknown, string | nil)
local function pack_claim_payload(st, id)
	local claim, msg = term_payload(st, id, "pack_claim")
	if not claim then return nil, msg end
	local _, claim_msg = pack_claim_pack(claim)
	if claim_msg then return nil, claim_msg end
	return claim
end

--: (unknown, string) -> (string | nil, string | nil)
local function require_term_id(id, field)
	if type(id) ~= "string" then return nil, "missing term input " .. field end
	return id
end

--: (MR0State, MR0Node) -> (boolean | nil, string | nil)
local function require_premises(st, node)
	for _, premise in ipairs(node.premises or {}) do
		if not st.accepted[premise] then
			return nil, "premise not accepted: " .. tostring(premise)
		end
	end
	return true
end

--: (MR0State, MR0Node) -> (boolean | nil, unknown)
local function replay_wf(st, node)
	if node.rule == "wf_type" then
		local inputs = node.inputs or {}
		local type_id, id_msg = require_term_id(inputs.type, "type")
		if not type_id then return err(id_msg) end
		local t, msg = term_payload(st, type_id, "type")
		if not t then return err(msg) end
		local ok, why = validate_type(t)
		if not ok then return err(why) end
		return true, { ok = true }
	elseif node.rule == "wf_pack_closed" then
		local inputs = node.inputs or {}
		local pack_id, id_msg = require_term_id(inputs.pack, "pack")
		if not pack_id then return err(id_msg) end
		local p, msg = pack_payload(st, pack_id)
		if not p then return err(msg) end
		local items = pack_items(p)
		if not items then return err("pack term is not closed pack") end
		for _, item in ipairs(items) do
			local ok, why = validate_type(item)
			if not ok then return err(why) end
		end
		return true, { ok = true }
	end
	return err("unsupported WFNode rule " .. tostring(node.rule))
end

--: (MR0State, MR0Node) -> (boolean | nil, unknown)
local function replay_sub(st, node)
	local inputs = node.inputs or {}
	local producer_id, producer_msg = require_term_id(inputs.producer or inputs.a, "producer")
	if not producer_id then return err(producer_msg) end
	local consumer_id, consumer_msg = require_term_id(inputs.consumer or inputs.b, "consumer")
	if not consumer_id then return err(consumer_msg) end
	local a, msg = term_payload(st, producer_id, "type")
	if not a then return err(msg) end
	local b, msg2 = term_payload(st, consumer_id, "type")
	if not b then return err(msg2) end

	if node.rule == "refl" then
		if not same(a, b) then return err("refl types differ") end
		return true, { ok = true }
	elseif node.rule == "never_left" then
		if type_tag(a) ~= "never" then return err("never_left producer is not never") end
		return true, { ok = true }
	elseif node.rule == "unknown_right" then
		if type_tag(b) ~= "unknown" then return err("unknown_right consumer is not unknown") end
		return true, { ok = true }
	elseif node.rule == "literal_to_base" then
		if base_of_literal(a) ~= type_tag(b) then return err("literal base does not match consumer") end
		return true, { ok = true }
	elseif node.rule == "integer_to_number" then
		if type_tag(a) ~= "integer" or type_tag(b) ~= "number" then return err("integer_to_number shape mismatch") end
		return true, { ok = true }
	elseif node.rule == "union_right_arm" then
		if not is_union(b) then return err("consumer is not union") end
		if type(b) ~= "table" then return err("consumer union arms missing") end
		local arms = b.arms
		if type(arms) ~= "table" then return err("consumer union arms missing") end
		if type(inputs.arm_index) ~= "number" then return err("missing union arm index") end
		local arm_index = inputs.arm_index
		local arm = arms[arm_index]
		if not arm then return err("missing union arm") end
		if not same(a, arm) then
			return err("union_right_arm requires producer to match named arm in this spike")
		end
		return true, { ok = true }
	end

	return err("unsupported SubNode rule " .. tostring(node.rule))
end

--: (MR0State, string, unknown, unknown) -> (boolean | nil, string | nil)
local function premise_matches_slot(st, premise_id, source_item, target_item)
	local premise = st.nodes[premise_id]
	if not premise then return nil, "unknown slot premise " .. premise_id end
	if tostring(premise.family) ~= "SubNode" then return nil, "slot premise is not SubNode" end
	if not st.accepted[premise_id] then return nil, "slot premise is not accepted" end
	local inputs = premise.inputs or {}
	local producer_id, producer_msg = require_term_id(inputs.producer or inputs.a, "producer")
	if not producer_id then return nil, producer_msg end
	local consumer_id, consumer_msg = require_term_id(inputs.consumer or inputs.b, "consumer")
	if not consumer_id then return nil, consumer_msg end
	local producer, pmsg = type_payload(st, producer_id)
	if not producer then return nil, pmsg end
	local consumer, cmsg = type_payload(st, consumer_id)
	if not consumer then return nil, cmsg end
	if not same(producer, source_item) then return nil, "slot premise producer mismatch" end
	if not same(consumer, target_item) then return nil, "slot premise consumer mismatch" end
	return true
end

--: (MR0State, MR0Node) -> (boolean | nil, unknown)
local function replay_pack_move(st, node)
	if node.rule ~= "closed_exact" and node.rule ~= "closed_call_adjust" then
		return err("unsupported PackMoveNode rule " .. tostring(node.rule))
	end

	local inputs = node.inputs or {}
	local source_id, source_msg = require_term_id(inputs.source_pack, "source_pack")
	if not source_id then return err(source_msg) end
	local target_id, target_msg = require_term_id(inputs.target_pack, "target_pack")
	if not target_id then return err(target_msg) end
	local source, smsg = pack_payload(st, source_id)
	if not source then return err(smsg) end
	local target, tmsg = pack_payload(st, target_id)
	if not target then return err(tmsg) end
	local source_items = pack_items(source)
	local target_items = pack_items(target)
	if not source_items or not target_items then return err("pack move requires closed packs") end
	if #source_items ~= #target_items then return err("closed pack length mismatch") end
	if #(node.premises or {}) ~= #source_items then return err("closed pack move needs one premise per slot") end
	for i = 1, #source_items do
		local ok, msg = premise_matches_slot(st, node.premises[i], source_items[i], target_items[i])
		if not ok then return err(msg) end
	end
	return true, { ok = true }
end

--: (MR0State, MR0Node) -> (boolean | nil, unknown)
local function replay_call(st, node)
	if node.rule ~= "call_arrow" then
		return err("unsupported CallNode rule " .. tostring(node.rule))
	end
	local inputs = node.inputs or {}
	local callee_id, callee_msg = require_term_id(inputs.callee_claim, "callee_claim")
	if not callee_id then return err(callee_msg) end
	local arg_id, arg_msg = require_term_id(inputs.arg_pack, "arg_pack")
	if not arg_id then return err(arg_msg) end
	local arrow_id, arrow_msg = require_term_id(inputs.arrow, "arrow")
	if not arrow_id then return err(arrow_msg) end

	local callee, cmsg = value_claim_payload(st, callee_id)
	if not callee then return err(cmsg) end
	local args, amsg = pack_claim_payload(st, arg_id)
	if not args then return err(amsg) end
	local arrow, tmsg = type_payload(st, arrow_id)
	if not arrow then return err(tmsg) end
	local ok_type, type_msg = validate_type(arrow)
	if not ok_type then return err(type_msg) end
	local params, returns, arrow_msg = arrow_parts(arrow)
	if not params then return err(arrow_msg) end
	local callee_type, callee_type_msg = value_claim_type(callee)
	if callee_type_msg then return err(callee_type_msg) end
	local arg_pack, arg_pack_msg = pack_claim_pack(args)
	if arg_pack_msg then return err(arg_pack_msg) end
	if not same(callee_type, arrow) then return err("callee claim does not match arrow") end
	if not same(arg_pack, params) then return err("argument pack does not match arrow params source") end
	if #(node.premises or {}) ~= 1 then return err("call_arrow needs exactly one pack movement premise") end
	local move = st.nodes[node.premises[1]]
	if not move or tostring(move.family) ~= "PackMoveNode" then return err("call_arrow premise is not PackMoveNode") end
	if move.rule ~= "closed_call_adjust" and move.rule ~= "closed_exact" then return err("call_arrow premise is not call pack movement") end
	if not same(move.outputs, { ok = true }) then return err("call_arrow pack movement output mismatch") end
	local move_inputs = move.inputs or {}
	local move_source_id, move_source_msg = require_term_id(move_inputs.source_pack, "source_pack")
	if not move_source_id then return err(move_source_msg) end
	local move_target_id, move_target_msg = require_term_id(move_inputs.target_pack, "target_pack")
	if not move_target_id then return err(move_target_msg) end
	local move_source, move_source_payload_msg = pack_payload(st, move_source_id)
	if not move_source then return err(move_source_payload_msg) end
	local move_target, move_target_payload_msg = pack_payload(st, move_target_id)
	if not move_target then return err(move_target_payload_msg) end
	if not same(move_source, arg_pack) then return err("call_arrow pack movement source mismatch") end
	if not same(move_target, params) then return err("call_arrow pack movement target mismatch") end

	return true, { result_pack = { pack = returns }, effect = "pure", post = true }
end

--: (string, unknown) -> { type: unknown, ... }
local function literal_claim(base, value)
	local out = { type = { tag = "literal", base = base, value = value } }
	return out
end

--: (MR0State, MR0Node) -> (boolean | nil, unknown)
local function replay_expr(_, node)
	local inputs = node.inputs or {}
	if node.rule == "literal_integer" then
		local value = inputs.value
		if type(value) ~= "number" then return err("literal_integer needs integer number") end
		local n = value
		if n % 1 ~= 0 then return err("literal_integer needs integer number") end
		return true, { claim = literal_claim("integer", n) }
	elseif node.rule == "literal_number" then
		if type(inputs.value) ~= "number" then return err("literal_number needs number") end
		return true, { claim = literal_claim("number", inputs.value) }
	elseif node.rule == "literal_string" then
		if type(inputs.value) ~= "string" then return err("literal_string needs string") end
		return true, { claim = literal_claim("string", inputs.value) }
	elseif node.rule == "literal_boolean" then
		if type(inputs.value) ~= "boolean" then return err("literal_boolean needs boolean") end
		return true, { claim = literal_claim("boolean", inputs.value) }
	elseif node.rule == "literal_nil" then
		return true, { claim = { type = "nil" } }
	end
	return err("unsupported ExprNode rule " .. tostring(node.rule))
end

--: (MR0State, MR0Node) -> (boolean | nil, unknown)
local function replay_unsafe(_, node)
	local inputs = node.inputs or {}
	if node.rule ~= "trusted_decl_value" and node.rule ~= "force_claim" then
		return err("unsupported UnsafeNode rule " .. tostring(node.rule))
	end
	if not inputs.exported_claim then return err("unsafe node missing exported_claim") end
	return true, { claim = inputs.exported_claim }
end

local FAMILY = {
	WFNode = replay_wf,
	SubNode = replay_sub,
	ExprNode = replay_expr,
	PackMoveNode = replay_pack_move,
	CallNode = replay_call,
	UnsafeNode = replay_unsafe,
} --: { [string]: ReplayFn }

--: (MR0State, MR0Node) -> (boolean | nil, unknown)
local function replay_node(st, node)
	local f = FAMILY[node.family]
	if not f then return err("unsupported node family " .. tostring(node.family)) end
	local ok, msg = require_premises(st, node)
	if not ok then return err(msg) end
	local accepted, output = f(st, node)
	if not accepted then return nil, output end
	if node.outputs and not same(node.outputs, output) then
		return err("node output mismatch for " .. tostring(node.node_id))
	end
	return true, output
end

--: (MR0Cert) -> (boolean | nil, string | nil)
function M.verify(cert)
	if cert.version ~= SUPPORTED_VERSION then return err("unsupported certificate version") end
	if cert.target.id ~= "luajit51-crescent" then return err("missing luajit51-crescent target") end
	if #cert.roots == 0 then return err("certificate has no roots") end

	local st, msg = mk_state(cert)
	if not st then return err(msg) end

	for _, node in ipairs(cert.nodes or {}) do
		local ok, output = replay_node(st, node)
		if not ok then return nil, "node " .. tostring(node.node_id) .. ": " .. tostring(output) end
		st.accepted[node.node_id] = true
		st.outputs[node.node_id] = output
	end

	for _, root in ipairs(cert.roots) do
		if not st.accepted[root.proof] then
			return err("root references unaccepted proof " .. tostring(root.proof))
		end
	end

	return true
end

return M
