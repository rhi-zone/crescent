-- lib/platform/apps/card/server.lua
-- Card app BFF backend.
--
-- Serves static files + JSON API endpoints for the card conversation UI.
-- All business logic lives here — the frontend is a dumb terminal.
--
-- Messages are stored in a SQLite-backed conversation tree (lib/conversation).
-- Each message has a parent_id. Siblings (same parent) are what were previously
-- called "swipes". Editing forks (creates a new sibling). Regenerating creates
-- a new sibling. The "active path" is the canonical path from root to leaf.
--
-- Capabilities (injected via caps table):
--   caps.llm.call(messages) -> string | nil, err
--   caps.llm.count_tokens(text) -> integer (optional)
--   caps.png.text(keyword) -> string | nil
--   caps.kv.get(key) / caps.kv.set(key, val) — persistence (optional)
--   caps.config.get(key) -> value | nil — settings (optional)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local card_mod = require("lib.formats.ccv2.card")
local context_mod = require("lib.formats.ccv2.context")
local macro_mod = require("lib.formats.ccv2.macro")
local lorebook_mod = require("lib.formats.ccv2.lorebook")
local conversation = require("lib.conversation")

local M = {}

-- ── Helpers ─────────────────────────────────────────────────────────────────

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

-- ── State ───────────────────────────────────────────────────────────────────

local function create_state()
	return {
		card = nil,           -- CardData
		lorebook = nil,       -- NormalizedEntry[]
		user_name = "User",
		conv = nil,           -- lib/conversation db handle
		session_id = nil,     -- active session id
	}
end

-- ── Card loading ────────────────────────────────────────────────────────────

local function load_card(state, caps)
	if not caps.png then return nil, "no png capability" end
	local raw = caps.png.text("chara")
	if not raw then return nil, "no chara chunk" end
	local json_str = raw
	if json_str:sub(1, 1) ~= "{" then
		local ok, b64 = pcall(require, "lib.base64")
		if not ok then return nil, "cannot decode base64: no decoder available" end
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

-- ── Tree helpers ────────────────────────────────────────────────────────────

-- get_canonical_path: returns the active path for the session.
-- Wraps conv:get_canonical_path().
local function get_canonical_path(state)
	return state.conv:get_canonical_path(state.session_id)
end

-- get_siblings: returns all siblings of a message (children of its parent).
-- For root messages (parent_id is nil), returns all roots in the session.
local function get_siblings(state, msg)
	if msg.parent_id == nil then
		return state.conv:get_roots(state.session_id)
	end
	return state.conv:get_children(msg.parent_id)
end

-- sibling_info: compute sibling_index (0-based) and sibling_count for a message.
local function sibling_info(state, msg)
	local siblings, err = get_siblings(state, msg)
	if not siblings then return 0, 1 end
	local index = 0
	for i, s in ipairs(siblings) do
		if s.id == msg.id then index = i - 1; break end
	end
	return index, #siblings
end

-- msg_response: format a message for the API response.
local function msg_response(state, msg)
	local idx, total = sibling_info(state, msg)
	return {
		id = msg.id,
		role = msg.role,
		content = msg.content,
		parent_id = msg.parent_id,
		sibling_index = idx,
		sibling_count = total,
	}
end

-- ── Context assembly ────────────────────────────────────────────────────────

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

	if not card then
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
	if caps.config and caps.config.get then
		max_context = caps.config.get("max_context") or max_context
		max_response = caps.config.get("max_response") or max_response
	end

	local result, err = context_mod.assemble({
		card = card,
		history = path,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = card.name,
		user_name = state.user_name,
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

-- build_context_to_parent: build context from root to a given parent message.
-- Used for generating siblings (swipe/new, edit).
local function build_context_to_parent(state, caps, parent_id)
	if parent_id == nil then
		-- Parent is the session root — context is empty (no messages before root).
		return build_context(state, caps, {})
	end
	-- Walk up from parent_id to root, then reverse.
	local chain = {}
	local current_id = parent_id
	while current_id do
		local msg, err = state.conv:get_message(current_id)
		if not msg then return nil, err end
		chain[#chain + 1] = msg
		current_id = msg.parent_id
	end
	-- Reverse: root first.
	local path = {}
	for i = #chain, 1, -1 do
		path[#path + 1] = chain[i]
	end
	return build_context(state, caps, path)
end

-- ── Persistence ─────────────────────────────────────────────────────────────

local function save_session_id(state, caps)
	if not caps.kv then return end
	caps.kv.set("card_session_id", state.session_id)
end

local function load_session_id(caps)
	if not caps.kv then return nil end
	return caps.kv.get("card_session_id")
end

-- ── Greeting ────────────────────────────────────────────────────────────────

local function init_greeting(state)
	local card = state.card
	if not card or not card.first_mes or #card.first_mes == 0 then return end

	local env = make_macro_env(state)
	local content = macro_mod.substitute(card.first_mes, env)

	-- Create primary greeting as root message.
	local msg, err = state.conv:add_message(state.session_id, nil, "assistant", content)
	if not msg then return end

	-- Create alternate greetings as root siblings (also parent_id = nil).
	if card.alternate_greetings then
		for _, g in ipairs(card.alternate_greetings) do
			if g and #g > 0 then
				local alt_content = macro_mod.substitute(g, env)
				state.conv:add_message(state.session_id, nil, "assistant", alt_content)
			end
		end
	end

	-- Swipe back to the first greeting so canonical path starts from it.
	-- add_message updates nothing for roots (no parent), but the last root added
	-- will be picked by get_canonical_path (first in query order).
	-- We need to ensure the first greeting is the one on the canonical path.
	-- get_canonical_path picks the first root by created_at (or insertion order).
	-- Since all roots share the same created_at (os.time() granularity is 1s),
	-- we rely on SQLite rowid ordering which matches insertion order.
	-- The first root inserted is the primary greeting — this is correct.
end

-- ── API endpoints ───────────────────────────────────────────────────────────

local function api_get_card(state, _caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	local path = get_canonical_path(state)
	local data = { name = state.card.name }
	if path and #path > 0 and path[1].role == "assistant" then
		data.greeting = msg_response(state, path[1])
	end
	return json_ok(res, data)
end

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

	-- Find current leaf (last node in canonical path).
	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 500, perr) end
	local leaf_id = path[#path] and path[#path].id or nil

	-- Add user message as child of leaf.
	local user_msg, uerr = state.conv:add_message(state.session_id, leaf_id, "user", text)
	if not user_msg then return json_err(res, 500, uerr) end

	-- Build context (canonical path now includes user_msg).
	local context = build_context(state, caps)
	local response, err = caps.llm.call(context)
	if not response then
		-- Rollback: delete user message.
		state.conv:delete_subtree(user_msg.id)
		return json_err(res, 502, "LLM error: " .. tostring(err))
	end

	-- Add assistant message as child of user message.
	local asst_msg, aerr = state.conv:add_message(state.session_id, user_msg.id, "assistant", response)
	if not asst_msg then return json_err(res, 500, aerr) end

	save_session_id(state, caps)
	return json_ok(res, {
		user = { id = user_msg.id, role = "user", content = text },
		assistant = msg_response(state, asst_msg),
	})
end

-- ── SSE helpers ────────────────────────────────────────────────────────────

local function sse_write(sock, data)
	sock:send("data: " .. data .. "\r\n\r\n")
end

local function sse_start(sock, res)
	res.raw = true
	local headers = "HTTP/1.1 200 OK\r\n"
		.. "Content-Type: text/event-stream\r\n"
		.. "Cache-Control: no-cache\r\n"
		.. "Connection: keep-alive\r\n"
		.. "Access-Control-Allow-Origin: *\r\n"
		.. "\r\n"
	sock:send(headers)
end

local function api_post_message_stream(state, caps, _params, body, res, sock)
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content
	if type(text) ~= "string" or #text == 0 then return json_err(res, 400, "empty content") end

	-- Check streaming support.
	if not caps.llm.call_stream then
		-- Fall back to non-streaming.
		return api_post_message(state, caps, _params, body, res)
	end

	-- Find current leaf.
	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 500, perr) end
	local leaf_id = path[#path] and path[#path].id or nil

	-- Add user message.
	local user_msg, uerr = state.conv:add_message(state.session_id, leaf_id, "user", text)
	if not user_msg then return json_err(res, 500, uerr) end

	-- Build context.
	local context = build_context(state, caps)

	-- Start SSE stream.
	sse_start(sock, res)

	-- Send user message event.
	sse_write(sock, json.encode({
		type = "user",
		id = user_msg.id,
		role = "user",
		content = text,
	}))

	-- Stream LLM response.
	local response, err = caps.llm.call_stream(context, function(token)
		sse_write(sock, json.encode({ type = "token", token = token }))
	end)

	if not response then
		-- Rollback: delete user message.
		state.conv:delete_subtree(user_msg.id)
		sse_write(sock, json.encode({ type = "error", error = "LLM error: " .. tostring(err) }))
		sock:close()
		return true
	end

	-- Add assistant message.
	local asst_msg, aerr = state.conv:add_message(state.session_id, user_msg.id, "assistant", response)
	if not asst_msg then
		sse_write(sock, json.encode({ type = "error", error = "db error: " .. tostring(aerr) }))
		sock:close()
		return true
	end

	save_session_id(state, caps)

	-- Send done event with final message data.
	local idx, total = sibling_info(state, asst_msg)
	sse_write(sock, json.encode({
		type = "done",
		id = asst_msg.id,
		role = "assistant",
		content = response,
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
		-- Append to existing assistant message (in-place update).
		local updated, uerr = state.conv:update_message(leaf.id, {
			content = leaf.content .. response,
		})
		if not updated then return json_err(res, 500, uerr) end
		save_session_id(state, caps)
		return json_ok(res, msg_response(state, updated))
	else
		-- Add new assistant message as child of leaf.
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
	-- Append instruction to generate as the user character.
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

	-- Build context up to (but not including) this message.
	local context, cerr = build_context_to_parent(state, caps, msg.parent_id)
	if not context then return json_err(res, 500, cerr) end

	local response, err = caps.llm.call(context)
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Add as sibling (same parent, same role).
	local new_msg, nerr = state.conv:add_message(
		state.session_id, msg.parent_id, msg.role, response
	)
	if not new_msg then return json_err(res, 500, nerr) end

	-- For root siblings, add_message doesn't update any parent canonical_child_id.
	-- The canonical path still starts from the first root. We rely on the frontend
	-- calling /api/branch/navigate to switch to the new sibling.
	-- For non-root siblings, add_message already updated parent's canonical_child_id.

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

	-- Create a new sibling with the edited content (fork).
	-- The old message and its subtree remain accessible by swiping back.
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
		-- Non-root: use swipe_to to update parent's canonical_child_id.
		local ok, err = state.conv:swipe_to(body.message_id)
		if not ok then return json_err(res, 400, err) end
	end
	-- For root messages, get_canonical_path picks the first root by insertion order.
	-- We don't have root-level canonical tracking yet — this is a known limitation.
	-- TODO: support root-level swipe navigation.

	local resp = msg_response(state, msg)
	resp.reload_below = true
	return json_ok(res, resp)
end

-- ── Router ──────────────────────────────────────────────────────────────────

local routes = {
	["GET /api/card"]             = api_get_card,
	["GET /api/messages"]         = api_get_messages,
	["POST /api/message"]         = api_post_message,
	["POST /api/continue"]        = api_post_continue,
	["GET /api/swipes"]           = api_get_swipes,
	["POST /api/swipe/new"]       = api_post_swipe_new,
	["POST /api/message/edit"]    = api_post_message_edit,
	["POST /api/message/delete"]  = api_post_message_delete,
	["POST /api/message/stream"]  = api_post_message_stream,
	["POST /api/impersonate"]     = api_post_impersonate,
	["POST /api/branch/navigate"] = api_post_branch_navigate,
	-- Aliases for renamed endpoints.
	["GET /api/siblings"]         = api_get_swipes,
	["POST /api/branch/new"]      = api_post_swipe_new,
}

function M.create(caps, opts)
	opts = opts or {}
	local state = create_state()

	-- Read user name from config.
	if caps.config and caps.config.get then
		local name = caps.config.get("user_name")
		if name then state.user_name = name end
	end

	-- Load card.
	load_card(state, caps)

	-- Open conversation database.
	local db_path = opts.db_path or ":memory:"
	local conv_db, db_err = conversation.open(db_path)
	if not conv_db then
		error("card server: failed to open conversation db: " .. tostring(db_err))
	end
	state.conv = conv_db

	-- Restore or create session.
	local session_id = load_session_id(caps)
	if session_id then
		local session = conv_db:get_session(session_id)
		if session then
			state.session_id = session_id
		end
	end
	if not state.session_id then
		local session, serr = conv_db:create_session("card")
		if not session then
			error("card server: failed to create session: " .. tostring(serr))
		end
		state.session_id = session.id
		save_session_id(state, caps)
	end

	-- If session has no messages and card has a greeting, create it.
	local path = get_canonical_path(state)
	if not path or #path == 0 then
		init_greeting(state)
	end

	-- Static file serving.
	local ok_static, static_serve = false, nil
	if not opts.no_static then
		local static_dir = opts.static_dir or "static"
		ok_static, static_serve = pcall(function()
			return require("lib.http.router.static").router(static_dir)
		end)
	end

	local function handler(req, res, sock)
		local req_path, params = parse_target(req.target)
		local key = req.method .. " " .. req_path
		local route = routes[key]
		if route then
			local req_body = read_json_body(req)
			return route(state, caps, params, req_body, res, sock)
		end
		-- Static files.
		if ok_static then
			req.path = req_path
			return static_serve(req, res)
		end
	end

	return { handler = handler, state = state }
end

function M.start(caps, opts)
	opts = opts or {}
	local app = M.create(caps, opts)
	local http_server = require("lib.http.server")
	local port = opts.port or 7860
	return http_server.server(app.handler, port)
end

return M
