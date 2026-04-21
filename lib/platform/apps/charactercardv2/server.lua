-- lib/platform/apps/charactercardv2/server.lua
-- Character Card v2 app server.
--
-- Serves static files + JSON API endpoints for the card conversation UI.
-- All business logic lives here — the frontend is a dumb terminal.
--
-- Messages are stored in a SQLite-backed conversation tree (lib/conversation).
-- Each message has a parent_id. Siblings (same parent) are what were previously
-- called "swipes". Editing forks (creates a new sibling). Regenerating creates
-- a new sibling. The "active path" is the canonical path from root to leaf.
--
-- Simple endpoints (chat/chat_stream/count_tokens) are projected via
-- lib/platform/service. Complex stateful endpoints (conversation management,
-- session management, presets) are direct handlers that close over state.
--
-- Capabilities (injected via caps table):
--   caps.llm            — llm cap (call, call_stream, count_tokens)
--   caps.conversations  — db cap for conversation tree (optional, default :memory:)
--   caps.kv             — kv cap for presets and session persistence (optional)
--   caps.self           — self cap for PNG character data access (optional)
--   caps.time           — time cap for timestamps (optional, falls back to os.time)
--   caps.server         — http_server cap for routing

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json         = require("lib.format.json")
local service      = require("lib.platform.service")
local conversation = require("lib.conversation")
local presets_mod  = require("lib.platform.apps.charactercardv2.presets")

local ok_ccv2 = pcall(function()
	require("lib.formats.ccv2.card")
	require("lib.formats.ccv2.context")
	require("lib.formats.ccv2.macro")
	require("lib.formats.ccv2.lorebook")
end)
local card_mod, context_mod, macro_mod, lorebook_mod
if ok_ccv2 then
	card_mod    = require("lib.formats.ccv2.card")
	context_mod = require("lib.formats.ccv2.context")
	macro_mod   = require("lib.formats.ccv2.macro")
	lorebook_mod = require("lib.formats.ccv2.lorebook")
end

local M = {}

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function parse_target(target)
	local qpos = target:find("?", 1, true)
	if not qpos then return target, {} end
	local path = target:sub(1, qpos - 1)
	local qs = target:sub(qpos + 1)
	local params = {}
	for kv in qs:gmatch("[^&]+") do
		local eq = kv:find("=", 1, true)
		if eq then
			params[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
		else
			params[kv] = ""
		end
	end
	return path, params
end

local function json_ok(res, data)
	res.status = 200
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode(data)
	return true
end

local function json_err(res, status, msg)
	res.status = status
	res.headers["Content-Type"] = "application/json"
	res.body = json.encode({ error = msg })
	return true
end

local function read_json_body(req)
	if not req.body or #req.body == 0 then return {} end
	local ok, val = pcall(json.decode, req.body)
	if not ok then return nil end
	return val
end

-- ── State ─────────────────────────────────────────────────────────────────────

local function create_state()
	return {
		card       = nil,       -- CardData
		lorebook   = nil,       -- NormalizedEntry[]
		user_name  = "User",
		conv       = nil,       -- lib/conversation db handle
		session_id = nil,       -- active session id
	}
end

-- ── Card loading ──────────────────────────────────────────────────────────────

local function load_card(state, caps)
	if not caps.self then return nil, "no self capability" end
	if not card_mod then return nil, "ccv2 modules not available" end
	-- caps.self.read(entry) -> data | nil, err (for tarball entries)
	-- For PNG metadata, the platform provides caps.self.png_text(keyword)
	local raw
	if caps.self.png_text then
		raw = caps.self.png_text("chara")
	elseif caps.self.read then
		raw = caps.self.read("chara")
	end
	if not raw then return nil, "no chara chunk" end
	local json_str = raw
	if json_str:sub(1, 1) ~= "{" then
		local ok_b64, b64 = pcall(require, "lib.encode.base64")
		if not ok_b64 then return nil, "cannot decode base64: no decoder available" end
		local decoded, err = b64.decode(json_str)
		if not decoded then return nil, "base64 decode failed: " .. tostring(err) end
		json_str = decoded
	end
	local card_data, err = card_mod.from_json(json_str)
	if not card_data then return nil, err end
	state.card = card_data
	if card_data.character_book then
		state.lorebook = lorebook_mod.from_ccv2(card_data.character_book)
	end
	return card_data
end

-- ── Tree helpers ──────────────────────────────────────────────────────────────

local function get_canonical_path(state)
	return state.conv:get_canonical_path(state.session_id)
end

local function get_siblings(state, msg)
	if msg.parent_id == nil then
		return state.conv:get_roots(state.session_id)
	end
	return state.conv:get_children(msg.parent_id)
end

local function sibling_info(state, msg)
	local siblings, err = get_siblings(state, msg)
	if not siblings then return 0, 1 end
	local index = 0
	for i, s in ipairs(siblings) do
		if s.id == msg.id then index = i - 1; break end
	end
	return index, #siblings
end

local function msg_response(state, msg)
	local idx, total = sibling_info(state, msg)
	return {
		id            = msg.id,
		role          = msg.role,
		content       = msg.content,
		parent_id     = msg.parent_id,
		sibling_index = idx,
		sibling_count = total,
	}
end

-- ── Context assembly ──────────────────────────────────────────────────────────

local function make_macro_env(state)
	local card = state.card
	if not card then return {} end
	return { char = card.name or "", user = state.user_name }
end

local function build_context(state, caps, path)
	local card = state.card
	if not path then
		local err
		path, err = get_canonical_path(state)
		if not path then return nil, err end
	end

	if not card or not context_mod then
		local result = {}
		for i = 1, #path do
			result[#result + 1] = { role = path[i].role, content = path[i].content }
		end
		return result
	end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local max_context = 4096
	local max_response = 512

	local result, err = context_mod.assemble({
		card             = card,
		history          = path,
		count_tokens     = count_tokens,
		max_context      = max_context,
		max_response     = max_response,
		char_name        = card.name,
		user_name        = state.user_name,
		lorebook_entries = state.lorebook,
	})
	if not result then
		local fallback = {}
		for i = 1, #path do
			fallback[#fallback + 1] = { role = path[i].role, content = path[i].content }
		end
		return fallback
	end
	return result
end

local function build_context_to_parent(state, caps, parent_id)
	if parent_id == nil then
		return build_context(state, caps, {})
	end
	local chain = {}
	local current_id = parent_id
	while current_id do
		local msg, err = state.conv:get_message(current_id)
		if not msg then return nil, err end
		chain[#chain + 1] = msg
		current_id = msg.parent_id
	end
	local path = {}
	for i = #chain, 1, -1 do
		path[#path + 1] = chain[i]
	end
	return build_context(state, caps, path)
end

-- ── Persistence ───────────────────────────────────────────────────────────────

local function save_session_id(state, caps)
	if not caps.kv then return end
	caps.kv.set("card_session_id", state.session_id)
end

local function load_session_id(caps)
	if not caps.kv then return nil end
	return caps.kv.get("card_session_id")
end

-- ── Greeting ──────────────────────────────────────────────────────────────────

local function init_greeting(state)
	local card = state.card
	if not card or not card.first_mes or #card.first_mes == 0 then return end

	local env = make_macro_env(state)
	local content = macro_mod and macro_mod.substitute(card.first_mes, env) or card.first_mes

	local msg, err = state.conv:add_message(state.session_id, nil, "assistant", content)
	if not msg then return end

	if card.alternate_greetings and macro_mod then
		for _, g in ipairs(card.alternate_greetings) do
			if g and #g > 0 then
				local alt_content = macro_mod.substitute(g, env)
				state.conv:add_message(state.session_id, nil, "assistant", alt_content)
			end
		end
	end
end

-- ── Session-switching helper ──────────────────────────────────────────────────

local function switch_session(state, caps, session_id)
	state.session_id = session_id
	save_session_id(state, caps)
	local path = get_canonical_path(state)
	if not path or #path == 0 then
		init_greeting(state)
	end
end

-- ── API: card ─────────────────────────────────────────────────────────────────

local function api_get_card(state, _caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	local path = get_canonical_path(state)
	local data = { name = state.card.name }
	if path and #path > 0 and path[1].role == "assistant" then
		data.greeting = msg_response(state, path[1])
	end
	return json_ok(res, data)
end

-- ── API: messages ─────────────────────────────────────────────────────────────

local function api_get_messages(state, _caps, _params, _body, res)
	local path, err = get_canonical_path(state)
	if not path then return json_err(res, 500, err) end
	local result = {}
	for _, msg in ipairs(path) do
		result[#result + 1] = msg_response(state, msg)
	end
	return json_ok(res, { messages = result })
end

local function api_post_message(state, caps, _params, body, res)
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content
	if type(text) ~= "string" or #text == 0 then return json_err(res, 400, "empty content") end

	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 500, perr) end
	local leaf_id = path[#path] and path[#path].id or nil

	local user_msg, uerr = state.conv:add_message(state.session_id, leaf_id, "user", text)
	if not user_msg then return json_err(res, 500, uerr) end

	local context = build_context(state, caps)
	local response, err = caps.llm.call(context)
	if not response then
		state.conv:delete_subtree(user_msg.id)
		return json_err(res, 502, "LLM error: " .. tostring(err))
	end

	local asst_msg, aerr = state.conv:add_message(state.session_id, user_msg.id, "assistant", response)
	if not asst_msg then return json_err(res, 500, aerr) end

	save_session_id(state, caps)
	return json_ok(res, {
		user      = { id = user_msg.id, role = "user", content = text },
		assistant = msg_response(state, asst_msg),
	})
end

-- ── SSE helpers ───────────────────────────────────────────────────────────────

local function sse_write(sock, data)
	sock:send("data: " .. data .. "\r\n\r\n")
end

local function sse_start(sock)
	sock:send(
		"HTTP/1.1 200 OK\r\n"
		.. "Content-Type: text/event-stream\r\n"
		.. "Cache-Control: no-cache\r\n"
		.. "Connection: keep-alive\r\n"
		.. "Access-Control-Allow-Origin: *\r\n"
		.. "\r\n"
	)
end

local function api_post_message_stream(state, caps, _params, body, res, sock)
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content
	if type(text) ~= "string" or #text == 0 then return json_err(res, 400, "empty content") end

	if not caps.llm.call_stream then
		return api_post_message(state, caps, _params, body, res)
	end

	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 500, perr) end
	local leaf_id = path[#path] and path[#path].id or nil

	local user_msg, uerr = state.conv:add_message(state.session_id, leaf_id, "user", text)
	if not user_msg then return json_err(res, 500, uerr) end

	local context = build_context(state, caps)

	sse_start(sock)
	sse_write(sock, json.encode({
		type    = "user",
		id      = user_msg.id,
		role    = "user",
		content = text,
	}))

	local response, err = caps.llm.call_stream(context, function(token)
		sse_write(sock, json.encode({ type = "token", token = token }))
	end)

	if not response then
		state.conv:delete_subtree(user_msg.id)
		sse_write(sock, json.encode({ type = "error", error = "LLM error: " .. tostring(err) }))
		sock:close()
		return true
	end

	local asst_msg, aerr = state.conv:add_message(state.session_id, user_msg.id, "assistant", response)
	if not asst_msg then
		sse_write(sock, json.encode({ type = "error", error = "db error: " .. tostring(aerr) }))
		sock:close()
		return true
	end

	save_session_id(state, caps)

	local idx, total = sibling_info(state, asst_msg)
	sse_write(sock, json.encode({
		type          = "done",
		id            = asst_msg.id,
		role          = "assistant",
		content       = response,
		sibling_index = idx,
		sibling_count = total,
	}))

	sock:close()
	return true
end

local function api_post_continue(state, caps, _params, _body, res)
	local path, perr = get_canonical_path(state)
	if not path or #path == 0 then return json_err(res, 400, "no messages") end

	local context = build_context(state, caps, path)
	local response, err = caps.llm.call(context)
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	local leaf = path[#path]
	if leaf.role == "assistant" then
		local updated, uerr = state.conv:update_message(leaf.id, {
			content = leaf.content .. response,
		})
		if not updated then return json_err(res, 500, uerr) end
		save_session_id(state, caps)
		return json_ok(res, msg_response(state, updated))
	else
		local asst_msg, aerr = state.conv:add_message(
			state.session_id, leaf.id, "assistant", response
		)
		if not asst_msg then return json_err(res, 500, aerr) end
		save_session_id(state, caps)
		return json_ok(res, msg_response(state, asst_msg))
	end
end

local function api_post_impersonate(state, caps, _params, body, res)
	local context = build_context(state, caps)
	if not context then return json_err(res, 500, "failed to build context") end
	local hint = "Continue the conversation as {{user}}, writing their next message in character."
	local env = make_macro_env(state)
	hint = hint:gsub("{{user}}", env.user or "User")
	if body and body.prompt and type(body.prompt) == "string" and #body.prompt > 0 then
		hint = hint .. " " .. body.prompt
	end
	context[#context + 1] = { role = "system", content = hint }

	local response, err = caps.llm.call(context)
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	return json_ok(res, { content = response })
end

-- ── API: swipes / branch ──────────────────────────────────────────────────────

local function api_get_swipes(state, _caps, params, _body, res)
	local msg_id = params.message_id
	if not msg_id then return json_err(res, 400, "message_id required") end

	local msg, merr = state.conv:get_message(msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	local siblings, serr = get_siblings(state, msg)
	if not siblings then return json_err(res, 500, serr) end

	local swipes = {}
	local current = 0
	for i, s in ipairs(siblings) do
		swipes[#swipes + 1] = { id = s.id, content = s.content, index = i - 1 }
		if s.id == msg_id then current = i - 1 end
	end
	return json_ok(res, { swipes = swipes, current = current })
end

local function api_post_swipe_new(state, caps, _params, body, res)
	local msg_id = body and body.message_id
	if not msg_id then return json_err(res, 400, "message_id required") end

	local msg, merr = state.conv:get_message(msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	local context, cerr = build_context_to_parent(state, caps, msg.parent_id)
	if not context then return json_err(res, 500, cerr) end

	local response, err = caps.llm.call(context)
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	local new_msg, nerr = state.conv:add_message(
		state.session_id, msg.parent_id, msg.role, response
	)
	if not new_msg then return json_err(res, 500, nerr) end

	save_session_id(state, caps)
	return json_ok(res, msg_response(state, new_msg))
end

local function api_post_message_edit(state, caps, _params, body, res)
	if not body or not body.message_id or not body.content then
		return json_err(res, 400, "message_id and content required")
	end
	local msg_id = body.message_id
	local new_content = body.content

	local msg, merr = state.conv:get_message(msg_id)
	if not msg then return json_err(res, 404, "message not found") end

	local edited, eerr = state.conv:add_message(
		state.session_id, msg.parent_id, msg.role, new_content
	)
	if not edited then return json_err(res, 500, eerr) end

	save_session_id(state, caps)
	local resp = msg_response(state, edited)
	resp.reload_below = true
	return json_ok(res, resp)
end

local function api_post_message_delete(state, _caps, _params, body, res)
	if not body or not body.message_id then
		return json_err(res, 400, "message_id required")
	end
	local msg_id = body.message_id

	local result, err = state.conv:delete_subtree(msg_id)
	if not result then return json_err(res, 404, "message not found") end

	return json_ok(res, { deleted = result.deleted })
end

local function api_post_branch_navigate(state, _caps, _params, body, res)
	if not body or not body.message_id then
		return json_err(res, 400, "message_id required")
	end

	local msg, merr = state.conv:get_message(body.message_id)
	if not msg then return json_err(res, 404, "message not found") end

	if msg.parent_id ~= nil then
		local ok, err = state.conv:swipe_to(body.message_id)
		if not ok then return json_err(res, 400, err) end
	end

	local resp = msg_response(state, msg)
	resp.reload_below = true
	return json_ok(res, resp)
end

-- ── API: sessions ─────────────────────────────────────────────────────────────

local function api_get_sessions(state, _caps, _params, _body, res)
	local sessions, err = state.conv:list_sessions("card")
	if not sessions then return json_err(res, 500, err) end
	return json_ok(res, { sessions = sessions, active = state.session_id })
end

local function api_post_sessions(state, caps, _params, body, res)
	local session, err = state.conv:create_session("card")
	if not session then return json_err(res, 500, err) end
	switch_session(state, caps, session.id)
	return json_ok(res, { session = session, active = state.session_id })
end

local function api_post_sessions_activate(state, caps, params, _body, res)
	local session_id = params.session_id
	if not session_id then return json_err(res, 400, "session_id required") end

	local session, err = state.conv:get_session(session_id)
	if not session then return json_err(res, 404, "session not found") end

	switch_session(state, caps, session_id)
	return json_ok(res, { active = state.session_id })
end

local function api_delete_session(state, caps, params, _body, res)
	local session_id = params.session_id
	if not session_id then return json_err(res, 400, "session_id required") end

	local ok, err = state.conv:delete_session(session_id)
	if not ok then return json_err(res, 404, "session not found or delete failed") end

	-- If deleted session was active, create a new one.
	if state.session_id == session_id then
		local sessions = state.conv:list_sessions("card")
		if sessions and #sessions > 0 then
			switch_session(state, caps, sessions[1].id)
		else
			local new_session, serr = state.conv:create_session("card")
			if not new_session then return json_err(res, 500, serr) end
			switch_session(state, caps, new_session.id)
		end
	end

	return json_ok(res, { deleted = session_id, active = state.session_id })
end

-- ── API: presets ──────────────────────────────────────────────────────────────

local function api_get_presets(state, caps, _params, _body, res)
	if not caps.kv then return json_err(res, 503, "kv cap not available") end
	return json_ok(res, presets_mod.load_all(caps.kv))
end

local function api_post_preset_save(state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 503, "kv cap not available") end
	if not body or not body.type or not body.name or not body.preset then
		return json_err(res, 400, "type, name, and preset required")
	end
	local ok, err = presets_mod.save(caps.kv, body.type, body.name, body.preset)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_preset_delete(state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 503, "kv cap not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.delete(caps.kv, body.type, body.name)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_preset_activate(state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 503, "kv cap not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.set_active(caps.kv, body.type, body.name)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

-- ── Router ────────────────────────────────────────────────────────────────────

-- Routes that require state are registered here as direct handlers.
-- The method+path string maps to a handler fn(state, caps, params, body, res, sock).
local CONV_ROUTES = {
	["GET /api/card"]              = api_get_card,
	["GET /api/messages"]          = api_get_messages,
	["POST /api/message"]          = api_post_message,
	["POST /api/message/stream"]   = api_post_message_stream,
	["POST /api/continue"]         = api_post_continue,
	["POST /api/impersonate"]      = api_post_impersonate,
	["GET /api/swipes"]            = api_get_swipes,
	["POST /api/swipe/new"]        = api_post_swipe_new,
	["POST /api/message/edit"]     = api_post_message_edit,
	["POST /api/message/delete"]   = api_post_message_delete,
	["POST /api/branch/navigate"]  = api_post_branch_navigate,
	-- Aliases.
	["GET /api/siblings"]          = api_get_swipes,
	["POST /api/branch/new"]       = api_post_swipe_new,
	-- Sessions.
	["GET /api/sessions"]          = api_get_sessions,
	["POST /api/sessions"]         = api_post_sessions,
	-- Presets.
	["GET /api/presets"]           = api_get_presets,
	["POST /api/presets/save"]     = api_post_preset_save,
	["POST /api/presets/delete"]   = api_post_preset_delete,
	["POST /api/presets/activate"] = api_post_preset_activate,
}

-- Routes with path parameters (matched by prefix/pattern).
-- Each entry: { method, prefix, param_name, handler }
local PARAM_ROUTES = {
	{ "POST", "/api/sessions/", "session_id", api_post_sessions_activate, "/activate" },
	{ "DELETE", "/api/sessions/", "session_id", api_delete_session, nil },
}

local function match_param_route(method, req_path)
	for _, r in ipairs(PARAM_ROUTES) do
		local rmethod, prefix, param_name, handler, suffix = r[1], r[2], r[3], r[4], r[5]
		if method == rmethod and req_path:sub(1, #prefix) == prefix then
			local rest = req_path:sub(#prefix + 1)
			if suffix then
				-- rest must end with suffix; param_value is the part before it
				if rest:sub(-#suffix) == suffix then
					local param_value = rest:sub(1, #rest - #suffix)
					if #param_value > 0 then
						return handler, { [param_name] = param_value }
					end
				end
			else
				-- rest is the param value (no further segments)
				if #rest > 0 and not rest:find("/", 1, true) then
					return handler, { [param_name] = rest }
				end
			end
		end
	end
	return nil, nil
end

-- ── create ────────────────────────────────────────────────────────────────────

-- create(caps, opts?) -> app
-- caps.llm            — llm cap (call/call_stream/count_tokens)
-- caps.conversations  — db cap for conversation persistence (optional)
-- caps.kv             — kv for presets and session bookmark (optional)
-- caps.self           — self cap for PNG chara chunk (optional)
-- caps.time           — time cap (optional, falls back to os.time)
-- opts.system_prompt  — prepended to chat/chat_stream calls
-- opts.db_path        — path for conversation db if caps.conversations absent
--                       (default ":memory:")
-- opts.no_static      — skip static file serving
-- opts.static_dir     — path to static files (default "static")
function M.create(caps, opts)
	opts = opts or {}

	local llm = caps.llm

	-- ── Time function ────────────────────────────────────────────────────────

	local time_fn
	if caps.time and caps.time.now then
		time_fn = caps.time.now
	else
		time_fn = os.time
	end

	-- ── Helpers ──────────────────────────────────────────────────────────────

	local function prepend_system(messages)
		if not opts.system_prompt then return messages end
		local msgs = { { role = "system", content = opts.system_prompt } }
		for i = 1, #messages do
			msgs[#msgs + 1] = messages[i]
		end
		return msgs
	end

	-- ── Service methods (simple LLM passthrough) ─────────────────────────────

	local function svc_chat(_caps, messages, gen_opts)
		if not llm then return nil, "card: no LLM capability available" end
		if type(messages) == "string" then
			messages = { { role = "user", content = messages } }
		end
		return llm.call(prepend_system(messages), gen_opts)
	end

	local function svc_chat_stream(_caps, messages, on_token, gen_opts)
		if not llm then return nil, "card: no LLM capability available" end
		if not llm.call_stream then return nil, "card: streaming not supported" end
		return llm.call_stream(prepend_system(messages), on_token, gen_opts)
	end

	local function svc_count_tokens(_caps, text)
		if not llm then return 0 end
		return llm.count_tokens(text)
	end

	local svc = service.create(caps, {
		chat         = svc_chat,
		chat_stream  = svc_chat_stream,
		count_tokens = svc_count_tokens,
	}, {
		chat = {
			method = "POST",
			path   = "/chat",
			help   = "Send messages to the LLM; returns assistant content.",
		},
		chat_stream = {
			method = "POST",
			path   = "/chat-stream",
			help   = "Streaming variant; returns assembled content.",
		},
		count_tokens = {
			method = "GET",
			path   = "/count-tokens",
			help   = "Count tokens in a text string.",
		},
	})

	-- ── Conversation state ───────────────────────────────────────────────────

	local state = create_state()

	-- Read user name from kv config.
	if caps.kv and caps.kv.get then
		local name = caps.kv.get("user_name")
		if name then state.user_name = name end
	end

	-- Load card character data (optional — app works without a card).
	if caps.self then
		load_card(state, caps)
	end

	-- Open conversation database.
	local conv_db, db_err
	if caps.conversations then
		-- caps.conversations is a db cap (pre-opened SQLite connection).
		conv_db, db_err = conversation.from_db(caps.conversations, time_fn)
	else
		local db_path = opts.db_path or ":memory:"
		conv_db, db_err = conversation.open(db_path, time_fn)
	end
	if not conv_db then
		error("charactercardv2 server: failed to open conversation db: " .. tostring(db_err))
	end
	state.conv = conv_db

	-- Restore or create session.
	local saved_id = load_session_id(caps)
	if saved_id then
		local session = conv_db:get_session(saved_id)
		if session then
			state.session_id = saved_id
		end
	end
	if not state.session_id then
		local session, serr = conv_db:create_session("card")
		if not session then
			error("charactercardv2 server: failed to create session: " .. tostring(serr))
		end
		state.session_id = session.id
		save_session_id(state, caps)
	end

	-- Seed greeting if session has no messages.
	local path = get_canonical_path(state)
	if not path or #path == 0 then
		init_greeting(state)
	end

	-- ── Static file serving ──────────────────────────────────────────────────

	local ok_static, static_serve = false, nil
	if not opts.no_static then
		local static_dir = opts.static_dir or "static"
		ok_static, static_serve = pcall(function()
			return require("lib.http.router.static").router(static_dir)
		end)
	end

	-- ── Combined handler ─────────────────────────────────────────────────────

	local svc_handler = svc.handler

	local function handler(req, res, sock)
		local req_path, params = parse_target(req.target)
		local key = req.method .. " " .. req_path

		-- 1. Conversation/session/preset routes (stateful).
		local conv_route = CONV_ROUTES[key]
		if conv_route then
			local req_body = read_json_body(req)
			return conv_route(state, caps, params, req_body, res, sock)
		end

		-- 2. Parameterized routes (sessions/:id, sessions/:id/activate).
		local param_route, route_params = match_param_route(req.method, req_path)
		if param_route then
			local req_body = read_json_body(req)
			return param_route(state, caps, route_params, req_body, res, sock)
		end

		-- 3. Service routes (/chat, /chat-stream, /count-tokens).
		if svc_handler(req, res, sock) then return true end

		-- 4. Static files.
		if ok_static then
			req.path = req_path
			return static_serve(req, res)
		end
	end

	return {
		handler      = handler,
		cli          = svc.cli,
		state        = state,
		-- Direct accessors: caps already closed over.
		chat         = function(messages, gen_opts)            return svc_chat(caps, messages, gen_opts) end,
		chat_stream  = function(messages, on_token, gen_opts)  return svc_chat_stream(caps, messages, on_token, gen_opts) end,
		count_tokens = function(text)                          return svc_count_tokens(caps, text) end,
	}
end

return M
