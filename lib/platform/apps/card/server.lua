-- lib/platform/apps/card/server.lua
-- Card app BFF backend.
--
-- Serves static files + JSON API endpoints for the card conversation UI.
-- All business logic lives here — the frontend is a dumb terminal.
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
		card = nil,       -- CardData
		lorebook = nil,   -- NormalizedEntry[]
		user_name = "User",
		messages = {},    -- [{id, role, content}] — active conversation path
		-- swipes[msg_id] = {items = {{id, content}, ...}, current = N (1-based)}
		swipes = {},
		next_id = 0,
	}
end

local function gen_id(state)
	state.next_id = state.next_id + 1
	return "m" .. state.next_id
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

-- ── Context assembly ────────────────────────────────────────────────────────

local function make_macro_env(state)
	local card = state.card
	if not card then return {} end
	return { char = card.name or "", user = state.user_name }
end

local function build_context(state, caps)
	local card = state.card
	local msgs = state.messages
	if not card then
		local result = {}
		for i = 1, #msgs do
			result[#result + 1] = { role = msgs[i].role, content = msgs[i].content }
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
		history = msgs,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = card.name,
		user_name = state.user_name,
		lorebook_entries = state.lorebook,
	})
	if not result then
		local fallback = {}
		for i = 1, #msgs do
			fallback[#fallback + 1] = { role = msgs[i].role, content = msgs[i].content }
		end
		return fallback
	end
	return result
end

-- ── Swipe helpers ───────────────────────────────────────────────────────────

local function ensure_swipes(state, msg_id)
	if state.swipes[msg_id] then return state.swipes[msg_id] end
	-- Find the message and create a single-entry swipe list
	for _, msg in ipairs(state.messages) do
		if msg.id == msg_id then
			local entry = { items = { { id = msg.id, content = msg.content } }, current = 1 }
			state.swipes[msg_id] = entry
			return entry
		end
	end
	return nil
end

local function swipe_info(state, msg)
	local entry = state.swipes[msg.id]
	if not entry then return 0, 1 end
	return entry.current - 1, #entry.items -- 0-based index for frontend
end

local function msg_response(state, msg)
	local idx, total = swipe_info(state, msg)
	return {
		id = msg.id,
		role = msg.role,
		content = msg.content,
		swipe_index = idx,
		swipe_total = total,
	}
end

-- ── Persistence ─────────────────────────────────────────────────────────────

local function save_state(state, caps)
	if not caps.kv then return end
	local data = {
		messages = state.messages,
		swipes = {},
		next_id = state.next_id,
	}
	-- Serialize swipes (only those with >1 alternative)
	for msg_id, entry in pairs(state.swipes) do
		if #entry.items > 1 then
			data.swipes[msg_id] = { items = entry.items, current = entry.current }
		end
	end
	caps.kv.set("card_state", json.encode(data))
end

local function load_state(state, caps)
	if not caps.kv then return false end
	local raw = caps.kv.get("card_state")
	if not raw then return false end
	local ok, data = pcall(json.decode, raw)
	if not ok or type(data) ~= "table" then return false end
	if data.messages then state.messages = data.messages end
	if data.swipes then
		for msg_id, entry in pairs(data.swipes) do
			state.swipes[msg_id] = entry
		end
	end
	if data.next_id then state.next_id = data.next_id end
	return true
end

-- ── Greeting ────────────────────────────────────────────────────────────────

local function init_greeting(state)
	local card = state.card
	if not card or not card.first_mes or #card.first_mes == 0 then return end

	local env = make_macro_env(state)
	local greeting_id = gen_id(state)
	local content = macro_mod.substitute(card.first_mes, env)

	local msg = { id = greeting_id, role = "assistant", content = content }
	state.messages[1] = msg

	-- Populate swipes from alternate_greetings
	local items = { { id = greeting_id, content = content } }
	if card.alternate_greetings then
		for _, g in ipairs(card.alternate_greetings) do
			if g and #g > 0 then
				local alt_id = gen_id(state)
				items[#items + 1] = { id = alt_id, content = macro_mod.substitute(g, env) }
			end
		end
	end
	state.swipes[greeting_id] = { items = items, current = 1 }
end

-- ── API endpoints ───────────────────────────────────────────────────────────

local function api_get_card(state, _caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	local data = { name = state.card.name }
	if #state.messages > 0 and state.messages[1].role == "assistant" then
		data.greeting = msg_response(state, state.messages[1])
	end
	return json_ok(res, data)
end

local function api_get_messages(state, _caps, _params, _body, res)
	local result = {}
	for _, msg in ipairs(state.messages) do
		result[#result + 1] = msg_response(state, msg)
	end
	return json_ok(res, { messages = result })
end

local function api_post_message(state, caps, _params, body, res)
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content
	if type(text) ~= "string" or #text == 0 then return json_err(res, 400, "empty content") end

	-- Add user message
	local user_id = gen_id(state)
	local user_msg = { id = user_id, role = "user", content = text }
	state.messages[#state.messages + 1] = user_msg

	-- Call LLM
	local context = build_context(state, caps)
	local response, err = caps.llm.call(context)
	if not response then
		-- Remove user message on LLM failure
		state.messages[#state.messages] = nil
		return json_err(res, 502, "LLM error: " .. tostring(err))
	end

	-- Add assistant message
	local asst_id = gen_id(state)
	local asst_msg = { id = asst_id, role = "assistant", content = response }
	state.messages[#state.messages + 1] = asst_msg
	state.swipes[asst_id] = { items = { { id = asst_id, content = response } }, current = 1 }

	save_state(state, caps)
	return json_ok(res, {
		user = { id = user_id, role = "user", content = text },
		assistant = msg_response(state, asst_msg),
	})
end

local function api_post_continue(state, caps, _params, _body, res)
	local msgs = state.messages
	if #msgs == 0 then return json_err(res, 400, "no messages") end

	local context = build_context(state, caps)
	local response, err = caps.llm.call(context)
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	local last = msgs[#msgs]
	if last.role == "assistant" then
		-- Append to existing assistant message
		last.content = last.content .. response
		-- Update swipe entry if it exists
		local entry = state.swipes[last.id]
		if entry then
			entry.items[entry.current].content = last.content
		end
	else
		-- Add new assistant message
		local asst_id = gen_id(state)
		local asst_msg = { id = asst_id, role = "assistant", content = response }
		msgs[#msgs + 1] = asst_msg
		state.swipes[asst_id] = { items = { { id = asst_id, content = response } }, current = 1 }
		last = asst_msg
	end

	save_state(state, caps)
	return json_ok(res, msg_response(state, last))
end

local function api_get_swipes(state, _caps, params, _body, res)
	local msg_id = params.message_id
	if not msg_id then return json_err(res, 400, "message_id required") end

	local entry = ensure_swipes(state, msg_id)
	if not entry then return json_err(res, 404, "message not found") end

	local swipes = {}
	for i, item in ipairs(entry.items) do
		swipes[#swipes + 1] = { id = item.id, content = item.content, index = i - 1 }
	end
	return json_ok(res, { swipes = swipes, current = entry.current - 1 })
end

local function api_post_swipe_new(state, caps, _params, body, res)
	local msg_id = body and body.message_id
	if not msg_id then return json_err(res, 400, "message_id required") end

	-- Find the message and its position
	local msg_pos
	for i, msg in ipairs(state.messages) do
		if msg.id == msg_id then msg_pos = i; break end
	end
	if not msg_pos then return json_err(res, 404, "message not found") end

	local entry = ensure_swipes(state, msg_id)
	if not entry then return json_err(res, 404, "message not found") end

	-- Build context up to the message before this one, then call LLM
	local saved_messages = state.messages
	local context_messages = {}
	for i = 1, msg_pos - 1 do
		context_messages[i] = saved_messages[i]
	end
	state.messages = context_messages
	local context = build_context(state, caps)
	state.messages = saved_messages

	local response, err = caps.llm.call(context)
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Add new swipe
	local new_id = gen_id(state)
	entry.items[#entry.items + 1] = { id = new_id, content = response }
	entry.current = #entry.items

	-- Update active message
	state.messages[msg_pos].id = new_id
	state.messages[msg_pos].content = response

	save_state(state, caps)
	return json_ok(res, {
		id = new_id,
		role = state.messages[msg_pos].role,
		content = response,
		swipe_index = entry.current - 1,
		swipe_total = #entry.items,
	})
end

-- ── Router ──────────────────────────────────────────────────────────────────

local routes = {
	["GET /api/card"]      = api_get_card,
	["GET /api/messages"]  = api_get_messages,
	["POST /api/message"]  = api_post_message,
	["POST /api/continue"] = api_post_continue,
	["GET /api/swipes"]    = api_get_swipes,
	["POST /api/swipe/new"] = api_post_swipe_new,
}

function M.create(caps, opts)
	opts = opts or {}
	local state = create_state()

	-- Read user name from config
	if caps.config and caps.config.get then
		local name = caps.config.get("user_name")
		if name then state.user_name = name end
	end

	-- Load card
	load_card(state, caps)

	-- Try to restore saved state
	local restored = load_state(state, caps)

	-- If no saved messages and card has a greeting, show it
	if not restored or #state.messages == 0 then
		init_greeting(state)
	end

	-- Static file serving
	local ok_static, static_serve = false, nil
	if not opts.no_static then
		local static_dir = opts.static_dir or "static"
		ok_static, static_serve = pcall(function()
			return require("lib.http.router.static").router(static_dir)
		end)
	end

	local function handler(req, res)
		local path, params = parse_target(req.target)
		local key = req.method .. " " .. path
		local route = routes[key]
		if route then
			local body = read_json_body(req)
			return route(state, caps, params, body, res)
		end
		-- Static files
		if ok_static then
			req.path = path
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
