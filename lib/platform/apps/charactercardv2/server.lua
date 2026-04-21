-- lib/platform/apps/charactercardv2/server.lua
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
--   caps.llm.call(messages, opts?) -> string | nil, err  (temporary — will be replaced by http_client cap + LLM library)
--   caps.llm.count_tokens(text) -> integer (optional)
--   caps.self.metadata(keyword) -> string | nil
--   caps.self.entry(path) -> string | nil
--   caps.self.entries() -> string[]
--   caps.kv.get(key) / caps.kv.set(key, val) — persistence (optional)
--   caps.time.now() -> integer — Unix timestamp

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json")
local card_mod = require("lib.formats.ccv2.card")
local context_mod = require("lib.formats.ccv2.context")
local macro_mod = require("lib.formats.ccv2.macro")
local lorebook_mod = require("lib.formats.ccv2.lorebook")
local conversation = require("lib.conversation")
local presets_mod = require("lib.platform.apps.charactercardv2.presets")

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

local DEFAULT_SETTINGS = {
	temperature = 0.7,
	top_p = 1.0,
	max_tokens = 512,
	frequency_penalty = 0.0,
	presence_penalty = 0.0,
	max_context = 4096,
}

local SETTINGS_KEYS = { "temperature", "top_p", "max_tokens", "frequency_penalty", "presence_penalty", "max_context" }

local function create_state()
	return {
		card = nil,           -- CardData
		lorebook = nil,       -- NormalizedEntry[]
		user_name = "User",
		conv = nil,           -- lib/conversation db handle
		session_id = nil,     -- active session id
		settings = nil,       -- generation settings (initialized from defaults + kv)
		personas = nil,       -- {name, description}[] (initialized on create)
		active_persona = nil, -- name string or nil
		authors_note = nil,   -- {text, depth, position} (initialized on create)
		regex_scripts = {},   -- {name, find, replace, enabled, scope, order}[]
		instruct_templates = {}, -- instruct template definitions
		instruct_active = nil,   -- name of active template (nil = chat mode)
		world_info = {},      -- NormalizedEntry[] (global lorebook, persists across cards)
		group = nil,          -- {enabled, members[], turn_order, next_speaker}
	}
end

local function default_settings()
	local s = {}
	for k, v in pairs(DEFAULT_SETTINGS) do s[k] = v end
	return s
end

local function llm_opts_from_settings(settings)
	return {
		temperature = settings.temperature,
		top_p = settings.top_p,
		max_tokens = settings.max_tokens,
		frequency_penalty = settings.frequency_penalty,
		presence_penalty = settings.presence_penalty,
	}
end

-- ── Card loading ────────────────────────────────────────────────────────────

local function load_card(state, caps)
	if not caps.self then return nil, "no self capability" end
	local raw = caps.self.metadata("chara")
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
	local resp = {
		id = msg.id,
		role = msg.role,
		content = msg.content,
		parent_id = msg.parent_id,
		sibling_index = idx,
		sibling_count = total,
	}
	local speaker = msg.speaker
	if not speaker and msg.metadata and msg.metadata.speaker then
		speaker = msg.metadata.speaker
	end
	if speaker then resp.speaker = speaker end
	return resp
end

-- ── Persona helpers (forward declarations for context assembly) ────────────

local function find_persona(personas, name)
	for i, p in ipairs(personas) do
		if p.name == name then return p, i end
	end
	return nil
end

local function get_active_persona(state)
	if not state.active_persona then return nil end
	return find_persona(state.personas, state.active_persona)
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

	local max_context = state.settings and state.settings.max_context or 4096
	local max_response = state.settings and state.settings.max_tokens or 512

	local active_p = get_active_persona(state)
	local result, err = context_mod.assemble({
		card = card,
		history = path,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = card.name,
		user_name = state.user_name,
		persona = active_p and active_p.description or nil,
		lorebook_entries = (function()
			local all = {}
			if state.lorebook then
				for _, e in ipairs(state.lorebook) do all[#all + 1] = e end
			end
			for _, e in ipairs(state.world_info) do all[#all + 1] = e end
			return #all > 0 and all or nil
		end)(),
	})
	if not result then
		local fallback = {}
		for i = 1, #path do
			fallback[#fallback + 1] = { role = path[i].role, content = path[i].content }
		end
		result = fallback
	end

	-- Insert Author's Note at configured depth.
	local an = state.authors_note
	if an and an.text and #an.text > 0 then
		local depth = an.depth or 4
		local pos = an.position or "after"
		local insert_pos = #result - depth
		if pos == "before" then insert_pos = insert_pos end
		if pos == "after" then insert_pos = insert_pos + 1 end
		if insert_pos < 1 then insert_pos = 1 end
		if insert_pos > #result + 1 then insert_pos = #result + 1 end
		table.insert(result, insert_pos, { role = "system", content = an.text })
	end

	return result
end

-- compute_token_count: build context and count tokens without calling the LLM.
-- Returns a table suitable for JSON response.
local function compute_token_count(state, caps)
	local path, perr = get_canonical_path(state)
	if not path then return nil, perr end

	local context, cerr = build_context(state, caps, path)
	if not context then return nil, cerr end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local total = 0
	for _, msg in ipairs(context) do
		total = total + count_tokens(msg.content)
	end

	local max_context = state.settings and state.settings.max_context or 4096
	local max_tokens = state.settings and state.settings.max_tokens or 512
	local available = math.max(0, max_context - total - max_tokens)

	-- Count triggered lorebook entries.
	local lorebook_count = 0
	if state.lorebook then
		for _, e in ipairs(state.lorebook) do
			if e.enabled then lorebook_count = lorebook_count + 1 end
		end
	end

	return {
		context_used = total,
		context_max = max_context,
		response_budget = max_tokens,
		available = available,
		messages = #path,
		lorebook_entries = lorebook_count,
	}
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

-- ── Regex scripts ──────────────────────────────────────────────────────────

local function apply_regex_scripts(state, text, scope)
	local scripts = state.regex_scripts
	if not scripts or #scripts == 0 then return text end
	-- Collect enabled scripts matching scope, sorted by order.
	local sorted = {}
	for _, s in ipairs(scripts) do
		if s.enabled and s.scope == scope then
			sorted[#sorted + 1] = s
		end
	end
	table.sort(sorted, function(a, b) return (a.order or 0) < (b.order or 0) end)
	for _, s in ipairs(sorted) do
		local ok, result = pcall(string.gsub, text, s.find, s.replace)
		if ok then text = result end
	end
	return text
end

local function save_regex_scripts(state, caps)
	if not caps.kv then return end
	caps.kv.set("regex_scripts", json.encode(state.regex_scripts))
end

-- ── Instruct templates ─────────────────────────────────────────────────────

local DEFAULT_INSTRUCT_TEMPLATES = {
	{
		name = "OpenAI (native)",
		mode = "chat",
		system_prefix = "", system_suffix = "",
		user_prefix = "", user_suffix = "",
		assistant_prefix = "", assistant_suffix = "",
		separator = "",
		stop_strings = {},
	},
	{
		name = "ChatML",
		mode = "instruct",
		system_prefix = "<|im_start|>system\n",
		system_suffix = "<|im_end|>\n",
		user_prefix = "<|im_start|>user\n",
		user_suffix = "<|im_end|>\n",
		assistant_prefix = "<|im_start|>assistant\n",
		assistant_suffix = "<|im_end|>\n",
		separator = "",
		stop_strings = { "<|im_end|>" },
	},
	{
		name = "Llama2",
		mode = "instruct",
		system_prefix = "[INST] <<SYS>>\n",
		system_suffix = "\n<</SYS>>\n\n",
		user_prefix = "",
		user_suffix = " [/INST] ",
		assistant_prefix = "",
		assistant_suffix = " </s><s>[INST] ",
		separator = "",
		stop_strings = { "</s>" },
	},
	{
		name = "Alpaca",
		mode = "instruct",
		system_prefix = "### Instruction:\n",
		system_suffix = "\n\n",
		user_prefix = "### Input:\n",
		user_suffix = "\n\n",
		assistant_prefix = "### Response:\n",
		assistant_suffix = "\n\n",
		separator = "",
		stop_strings = { "### Instruction:", "### Input:", "### Response:" },
	},
	{
		name = "Mistral",
		mode = "instruct",
		system_prefix = "[INST] ",
		system_suffix = "\n",
		user_prefix = "[INST] ",
		user_suffix = " [/INST] ",
		assistant_prefix = "",
		assistant_suffix = " </s> ",
		separator = "",
		stop_strings = { "</s>" },
	},
	{
		name = "Vicuna",
		mode = "instruct",
		system_prefix = "",
		system_suffix = "\n\n",
		user_prefix = "USER: ",
		user_suffix = "\n",
		assistant_prefix = "ASSISTANT: ",
		assistant_suffix = "\n",
		separator = "",
		stop_strings = { "USER:", "ASSISTANT:" },
	},
	{
		name = "Plain",
		mode = "instruct",
		system_prefix = "System: ",
		system_suffix = "\n",
		user_prefix = "User: ",
		user_suffix = "\n",
		assistant_prefix = "Assistant: ",
		assistant_suffix = "\n",
		separator = "",
		stop_strings = {},
	},
}

-- format_for_instruct(messages, template) -> messages
-- If template is nil or mode="chat", returns messages unchanged.
-- If mode="instruct", formats into a single user message using template prefixes/suffixes.
local function format_for_instruct(messages, template)
	if not template or template.mode == "chat" then return messages end
	local parts = {}
	local sep = template.separator or ""
	for i, msg in ipairs(messages) do
		local prefix, suffix
		if msg.role == "system" then
			prefix = template.system_prefix or ""
			suffix = template.system_suffix or ""
		elseif msg.role == "user" then
			prefix = template.user_prefix or ""
			suffix = template.user_suffix or ""
		elseif msg.role == "assistant" then
			prefix = template.assistant_prefix or ""
			suffix = template.assistant_suffix or ""
		else
			prefix = ""
			suffix = ""
		end
		if i > 1 and sep ~= "" then parts[#parts + 1] = sep end
		parts[#parts + 1] = prefix
		parts[#parts + 1] = msg.content
		parts[#parts + 1] = suffix
	end
	-- Append the assistant prefix to prompt a response.
	parts[#parts + 1] = template.assistant_prefix or ""
	return { { role = "user", content = table.concat(parts) } }
end

-- Expose for testing.
M._format_for_instruct = format_for_instruct
M._DEFAULT_INSTRUCT_TEMPLATES = DEFAULT_INSTRUCT_TEMPLATES

local function find_instruct_template(templates, name)
	for i, t in ipairs(templates) do
		if t.name == name then return t, i end
	end
	return nil
end

local function save_instruct(state, caps)
	if not caps.kv then return end
	caps.kv.set("instruct_templates", json.encode(state.instruct_templates))
	caps.kv.set("instruct_active", state.instruct_active or "")
end

-- Get the active instruct template (nil if none or chat mode).
local function get_active_instruct(state)
	if not state.instruct_active or state.instruct_active == "" then return nil end
	return find_instruct_template(state.instruct_templates, state.instruct_active)
end

-- Apply instruct template to messages before LLM call.
local function apply_instruct(state, messages)
	local template = get_active_instruct(state)
	return format_for_instruct(messages, template)
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

-- ── Session helpers ─────────────────────────────────────────────────────────

local function get_session_preview(state, session_id)
	local path = state.conv:get_canonical_path(session_id)
	if not path or #path == 0 then return "" end
	for _, msg in ipairs(path) do
		if msg.role == "user" then
			local text = msg.content
			if #text > 80 then text = text:sub(1, 77) .. "..." end
			return text
		end
	end
	local text = path[1].content
	if #text > 80 then text = text:sub(1, 77) .. "..." end
	return text
end

local function format_messages(state, path)
	local result = {}
	for _, msg in ipairs(path) do
		result[#result + 1] = msg_response(state, msg)
	end
	return result
end

local function switch_to_session(state, caps, session_id)
	state.session_id = session_id
	save_session_id(state, caps)
end

local function create_new_session(state, caps)
	local session, serr = state.conv:create_session("card")
	if not session then return nil, nil, serr end
	state.session_id = session.id
	init_greeting(state)
	switch_to_session(state, caps, session.id)
	local path = get_canonical_path(state)
	local messages = format_messages(state, path or {})
	return session, messages
end

-- ── Group chat helpers ────────────────────────────────────────────────────

local function init_group(state)
	local primary_name = state.card and state.card.name or "Character"
	state.group = {
		enabled = false,
		members = { { card = state.card, name = primary_name, is_primary = true } },
		turn_order = "round_robin",
		next_speaker = 1,
	}
end

local function save_group(state, caps)
	if not caps.kv then return end
	local serializable = {
		enabled = state.group.enabled,
		turn_order = state.group.turn_order,
		next_speaker = state.group.next_speaker,
		members = {},
	}
	for i, m in ipairs(state.group.members) do
		if m.is_primary then
			serializable.members[i] = { name = m.name, is_primary = true }
		else
			serializable.members[i] = {
				name = m.name,
				card_json = card_mod.to_json(m.card),
			}
		end
	end
	caps.kv.set("group", json.encode(serializable))
end

local function group_members_response(state)
	local members = {}
	for _, m in ipairs(state.group.members) do
		members[#members + 1] = { name = m.name, is_primary = m.is_primary or false }
	end
	return members
end

local function group_response(state)
	return {
		enabled = state.group.enabled,
		members = group_members_response(state),
		turn_order = state.group.turn_order,
	}
end

-- Build context for a specific group member's turn.
local function build_group_context(state, caps, speaker_member, path)
	local speaker_card = speaker_member.card
	if not speaker_card then return build_context(state, caps, path) end

	local count_tokens
	if caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	local max_context = state.settings and state.settings.max_context or 4096
	local max_response = state.settings and state.settings.max_tokens or 512

	-- Label history messages with speaker names for group context.
	local labeled_history = {}
	for _, msg in ipairs(path) do
		local content = msg.content
		if msg.role == "assistant" and msg.speaker then
			content = msg.speaker .. ": " .. content
		elseif msg.role == "user" then
			content = state.user_name .. ": " .. content
		end
		labeled_history[#labeled_history + 1] = { role = msg.role, content = content }
	end

	local active_p = get_active_persona(state)
	local result = context_mod.assemble({
		card = speaker_card,
		history = labeled_history,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = speaker_card.name,
		user_name = state.user_name,
		persona = active_p and active_p.description or nil,
		lorebook_entries = state.lorebook,
	})
	if not result then
		return labeled_history
	end

	-- Insert Author's Note at configured depth.
	local an = state.authors_note
	if an and an.text and #an.text > 0 then
		local depth = an.depth or 4
		local pos = an.position or "after"
		local insert_pos = #result - depth
		if pos == "after" then insert_pos = insert_pos + 1 end
		if insert_pos < 1 then insert_pos = 1 end
		if insert_pos > #result + 1 then insert_pos = #result + 1 end
		table.insert(result, insert_pos, { role = "system", content = an.text })
	end

	return result
end

-- Pick the next speaker(s) based on turn order.
local function pick_next_speakers(state)
	local group = state.group
	local members = group.members
	if #members == 0 then return {} end

	if group.turn_order == "round_robin" then
		local idx = group.next_speaker
		if idx < 1 or idx > #members then idx = 1 end
		group.next_speaker = (idx % #members) + 1
		return { members[idx] }
	elseif group.turn_order == "random" then
		local idx = math.random(1, #members)
		return { members[idx] }
	elseif group.turn_order == "all" then
		return members
	end
	-- Default: round_robin behavior.
	local idx = group.next_speaker
	if idx < 1 or idx > #members then idx = 1 end
	group.next_speaker = (idx % #members) + 1
	return { members[idx] }
end

-- ── Group endpoints ──────────────────────────────────────────────────────

local function api_get_group(state, _caps, _params, _body, res)
	return json_ok(res, group_response(state))
end

local function api_post_group_toggle(state, caps, _params, body, res)
	if not body or body.enabled == nil then
		return json_err(res, 400, "enabled field required")
	end
	state.group.enabled = not not body.enabled
	save_group(state, caps)
	return json_ok(res, group_response(state))
end

local function api_post_group_add(state, caps, _params, body, res)
	if not body or not body.card_json then
		return json_err(res, 400, "card_json required")
	end
	local card_data, cerr = card_mod.from_json(body.card_json)
	if not card_data then
		return json_err(res, 400, "invalid card: " .. tostring(cerr))
	end
	local name = card_data.name
	for _, m in ipairs(state.group.members) do
		if m.name == name then
			return json_err(res, 409, "character '" .. name .. "' already in group")
		end
	end
	state.group.members[#state.group.members + 1] = {
		card = card_data,
		name = name,
		is_primary = false,
	}
	save_group(state, caps)
	return json_ok(res, group_response(state))
end

local function api_post_group_remove(state, caps, _params, body, res)
	if not body or not body.name then
		return json_err(res, 400, "name required")
	end
	for i, m in ipairs(state.group.members) do
		if m.name == body.name then
			if m.is_primary then
				return json_err(res, 400, "cannot remove primary character")
			end
			table.remove(state.group.members, i)
			if state.group.next_speaker > #state.group.members then
				state.group.next_speaker = 1
			end
			save_group(state, caps)
			return json_ok(res, group_response(state))
		end
	end
	return json_err(res, 404, "character not found")
end

local function api_post_group_order(state, caps, _params, body, res)
	if not body or not body.turn_order then
		return json_err(res, 400, "turn_order required")
	end
	local order = body.turn_order
	if order ~= "round_robin" and order ~= "random" and order ~= "all" and order ~= "manual" then
		return json_err(res, 400, "invalid turn_order: " .. tostring(order))
	end
	state.group.turn_order = order
	state.group.next_speaker = 1
	save_group(state, caps)
	return json_ok(res, group_response(state))
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

local function api_get_avatar(_state, caps, _params, _body, res)
	if not caps.self or not caps.self.entry then
		res.status = 404
		res.headers["Content-Type"] = "text/plain"
		res.body = "no avatar"
		return true
	end
	local bytes = caps.self.entry("avatar.png")
	if not bytes then
		res.status = 404
		res.headers["Content-Type"] = "text/plain"
		res.body = "no avatar"
		return true
	end
	res.status = 200
	res.headers["Content-Type"] = "image/png"
	res.headers["Cache-Control"] = "max-age=3600"
	res.body = bytes
	return true
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

	-- Apply user_input regex scripts.
	text = apply_regex_scripts(state, text, "user_input")

	-- Find current leaf (last node in canonical path).
	local path, perr = get_canonical_path(state)
	if not path then return json_err(res, 500, perr) end
	local leaf_id = path[#path] and path[#path].id or nil

	-- Add user message as child of leaf.
	local user_msg, uerr = state.conv:add_message(state.session_id, leaf_id, "user", text)
	if not user_msg then return json_err(res, 500, uerr) end

	-- Group mode: generate responses from multiple characters.
	if state.group and state.group.enabled and #state.group.members > 0 then
		local speakers = pick_next_speakers(state)
		local responses = {}
		local parent_id = user_msg.id
		for _, speaker in ipairs(speakers) do
			local path2 = get_canonical_path(state)
			local context = build_group_context(state, caps, speaker, path2)
			local resp, gerr = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
			if not resp then
				if #responses == 0 then
					state.conv:delete_subtree(user_msg.id)
					return json_err(res, 502, "LLM error: " .. tostring(gerr))
				end
				break
			end
			resp = apply_regex_scripts(state, resp, "ai_output")
			local meta = { speaker = speaker.name }
			local asst_msg, aerr = state.conv:add_message(state.session_id, parent_id, "assistant", resp, meta)
			if not asst_msg then return json_err(res, 500, aerr) end
			asst_msg.speaker = speaker.name
			parent_id = asst_msg.id
			local r = msg_response(state, asst_msg)
			r.speaker = speaker.name
			responses[#responses + 1] = r
		end
		save_group(state, caps)
		save_session_id(state, caps)
		return json_ok(res, {
			user = { id = user_msg.id, role = "user", content = text },
			assistants = responses,
			token_count = compute_token_count(state, caps),
		})
	end

	-- Build context (canonical path now includes user_msg).
	local context = build_context(state, caps)
	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
	if not response then
		-- Rollback: delete user message.
		state.conv:delete_subtree(user_msg.id)
		return json_err(res, 502, "LLM error: " .. tostring(err))
	end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

	-- Add assistant message as child of user message.
	local asst_msg, aerr = state.conv:add_message(state.session_id, user_msg.id, "assistant", response)
	if not asst_msg then return json_err(res, 500, aerr) end

	save_session_id(state, caps)
	return json_ok(res, {
		user = { id = user_msg.id, role = "user", content = text },
		assistant = msg_response(state, asst_msg),
		token_count = compute_token_count(state, caps),
	})
end

-- ── SSE streaming (via res.send_event / res.close from http_server cap) ───

local function api_post_message_stream(state, caps, _params, body, res)
	if not body or not body.content then return json_err(res, 400, "content required") end
	local text = body.content
	if type(text) ~= "string" or #text == 0 then return json_err(res, 400, "empty content") end

	-- Apply user_input regex scripts.
	text = apply_regex_scripts(state, text, "user_input")

	-- Check streaming support.
	if not caps.llm.call_stream then
		-- Fall back to non-streaming (text already transformed, pass it through).
		body = { content = text }
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

	-- Send user message event.
	res.send_event(json.encode({
		type = "user",
		id = user_msg.id,
		role = "user",
		content = text,
	}))

	-- Stream LLM response.
	local response, err = caps.llm.call_stream(apply_instruct(state, context), function(token)
		res.send_event(json.encode({ type = "token", token = token }))
	end, llm_opts_from_settings(state.settings))

	if not response then
		-- Rollback: delete user message.
		state.conv:delete_subtree(user_msg.id)
		res.send_event(json.encode({ type = "error", error = "LLM error: " .. tostring(err) }))
		res.close()
		return true
	end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

	-- Add assistant message.
	local asst_msg, aerr = state.conv:add_message(state.session_id, user_msg.id, "assistant", response)
	if not asst_msg then
		res.send_event(json.encode({ type = "error", error = "db error: " .. tostring(aerr) }))
		res.close()
		return true
	end

	save_session_id(state, caps)

	-- Send done event with final message data.
	local idx, total = sibling_info(state, asst_msg)
	res.send_event(json.encode({
		type = "done",
		id = asst_msg.id,
		role = "assistant",
		content = response,
		sibling_index = idx,
		sibling_count = total,
	}))

	res.close()
	return true
end

local function api_post_continue(state, caps, _params, _body, res)
	local path, perr = get_canonical_path(state)
	if not path or #path == 0 then return json_err(res, 400, "no messages") end

	local context = build_context(state, caps, path)
	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

	local leaf = path[#path]
	if leaf.role == "assistant" then
		-- Append to existing assistant message (in-place update).
		local updated, uerr = state.conv:update_message(leaf.id, {
			content = leaf.content .. response,
		})
		if not updated then return json_err(res, 500, uerr) end
		save_session_id(state, caps)
		local resp = msg_response(state, updated)
		resp.token_count = compute_token_count(state, caps)
		return json_ok(res, resp)
	else
		-- Add new assistant message as child of leaf.
		local asst_msg, aerr = state.conv:add_message(
			state.session_id, leaf.id, "assistant", response
		)
		if not asst_msg then return json_err(res, 500, aerr) end
		save_session_id(state, caps)
		local resp = msg_response(state, asst_msg)
		resp.token_count = compute_token_count(state, caps)
		return json_ok(res, resp)
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

	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
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

	local response, err = caps.llm.call(apply_instruct(state, context), llm_opts_from_settings(state.settings))
	if not response then return json_err(res, 502, "LLM error: " .. tostring(err)) end

	-- Apply ai_output regex scripts.
	response = apply_regex_scripts(state, response, "ai_output")

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

-- ── Session endpoints ──────────────────────────────────────────────────────

local function api_get_sessions(state, _caps, _params, _body, res)
	local sessions, err = state.conv:list_sessions("card")
	if not sessions then return json_err(res, 500, err) end
	local result = {}
	for _, s in ipairs(sessions) do
		result[#result + 1] = {
			id = s.id,
			created_at = s.created_at,
			preview = get_session_preview(state, s.id),
		}
	end
	return json_ok(res, { sessions = result, current = state.session_id })
end

local function api_post_session_new(state, caps, _params, _body, res)
	local session, messages, serr = create_new_session(state, caps)
	if not session then return json_err(res, 500, serr) end
	return json_ok(res, {
		session = { id = session.id, created_at = session.created_at },
		messages = messages,
	})
end

local function api_post_session_switch(state, caps, _params, body, res)
	if not body or not body.session_id then
		return json_err(res, 400, "session_id required")
	end
	local target_id = body.session_id
	local session, serr = state.conv:get_session(target_id)
	if not session then return json_err(res, 404, "session not found") end
	switch_to_session(state, caps, target_id)
	local path = get_canonical_path(state)
	local messages = format_messages(state, path or {})
	return json_ok(res, {
		session = { id = session.id, created_at = session.created_at },
		messages = messages,
	})
end

local function api_post_session_delete(state, caps, _params, body, res)
	if not body or not body.session_id then
		return json_err(res, 400, "session_id required")
	end
	local target_id = body.session_id
	local session, serr = state.conv:get_session(target_id)
	if not session then return json_err(res, 404, "session not found") end
	local ok, derr = state.conv:delete_session(target_id)
	if not ok then return json_err(res, 500, derr) end
	local current_id = state.session_id
	local messages
	if target_id == current_id then
		local remaining = state.conv:list_sessions("card")
		if remaining and #remaining > 0 then
			switch_to_session(state, caps, remaining[1].id)
			local path = get_canonical_path(state)
			messages = format_messages(state, path or {})
		else
			local new_session, new_messages, nerr = create_new_session(state, caps)
			if not new_session then return json_err(res, 500, nerr) end
			messages = new_messages
		end
	else
		local path = get_canonical_path(state)
		messages = format_messages(state, path or {})
	end
	return json_ok(res, {
		deleted = true,
		current_session_id = state.session_id,
		messages = messages,
	})
end

-- ── Lorebook endpoints ──────────────────────────────────────────────────────

local function entry_to_json(e)
	return {
		uid = e.uid,
		keys = e.key or {},
		content = e.content or "",
		enabled = e.enabled,
		constant = e.constant,
		position = e.position or 0,
		order = e.order or 0,
		role = e.role or 0,
	}
end

local function save_lorebook(state, caps)
	if not caps.kv then return end
	caps.kv.set("lorebook", json.encode(state.lorebook or {}))
end

local function api_get_lorebook(state, _caps, _params, _body, res)
	local entries = state.lorebook or {}
	local result = {}
	for _, e in ipairs(entries) do
		result[#result + 1] = entry_to_json(e)
	end
	return json_ok(res, { entries = result })
end

local function api_post_lorebook_update(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	local entries = state.lorebook or {}
	for _, e in ipairs(entries) do
		if e.uid == body.uid then
			if body.keys ~= nil then e.key = body.keys end
			if body.content ~= nil then e.content = body.content end
			if body.enabled ~= nil then e.enabled = body.enabled end
			if body.constant ~= nil then e.constant = body.constant end
			if body.position ~= nil then e.position = body.position end
			if body.order ~= nil then e.order = body.order end
			if body.role ~= nil then e.role = body.role end
			save_lorebook(state, caps)
			return json_ok(res, entry_to_json(e))
		end
	end
	return json_err(res, 404, "entry not found")
end

local function api_post_lorebook_add(state, caps, _params, body, res)
	if not body or not body.keys or not body.content then
		return json_err(res, 400, "keys and content required")
	end
	local entry = lorebook_mod.normalize({
		key = body.keys,
		content = body.content,
		enabled = body.enabled,
		constant = body.constant,
		position = body.position,
		order = body.order,
		role = body.role,
	})
	if not state.lorebook then state.lorebook = {} end
	state.lorebook[#state.lorebook + 1] = entry
	save_lorebook(state, caps)
	return json_ok(res, entry_to_json(entry))
end

local function api_post_lorebook_delete(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	local entries = state.lorebook or {}
	for i, e in ipairs(entries) do
		if e.uid == body.uid then
			table.remove(entries, i)
			save_lorebook(state, caps)
			return json_ok(res, { deleted = true })
		end
	end
	return json_err(res, 404, "entry not found")
end

-- ── World info endpoints ───────────────────────────────────────────────────

local function save_world_info(state, caps)
	if not caps.kv then return end
	caps.kv.set("world_info", json.encode(state.world_info))
end

local function api_get_world_info(state, _caps, _params, _body, res)
	local result = {}
	for _, e in ipairs(state.world_info) do
		result[#result + 1] = entry_to_json(e)
	end
	return json_ok(res, { entries = result })
end

local function api_post_world_info_update(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	for _, e in ipairs(state.world_info) do
		if e.uid == body.uid then
			if body.keys ~= nil then e.key = body.keys end
			if body.content ~= nil then e.content = body.content end
			if body.enabled ~= nil then e.enabled = body.enabled end
			if body.constant ~= nil then e.constant = body.constant end
			if body.position ~= nil then e.position = body.position end
			if body.order ~= nil then e.order = body.order end
			if body.role ~= nil then e.role = body.role end
			save_world_info(state, caps)
			return json_ok(res, entry_to_json(e))
		end
	end
	return json_err(res, 404, "entry not found")
end

local function api_post_world_info_add(state, caps, _params, body, res)
	if not body or not body.keys or not body.content then
		return json_err(res, 400, "keys and content required")
	end
	local entry = lorebook_mod.normalize({
		key = body.keys,
		content = body.content,
		enabled = body.enabled,
		constant = body.constant,
		position = body.position,
		order = body.order,
		role = body.role,
	})
	state.world_info[#state.world_info + 1] = entry
	save_world_info(state, caps)
	return json_ok(res, entry_to_json(entry))
end

local function api_post_world_info_delete(state, caps, _params, body, res)
	if not body or not body.uid then return json_err(res, 400, "uid required") end
	for i, e in ipairs(state.world_info) do
		if e.uid == body.uid then
			table.remove(state.world_info, i)
			save_world_info(state, caps)
			return json_ok(res, { deleted = true })
		end
	end
	return json_err(res, 404, "entry not found")
end

local function api_post_world_info_import(state, caps, _params, body, res)
	if not body or not body.entries or type(body.entries) ~= "table" then
		return json_err(res, 400, "entries array required")
	end
	for _, raw in ipairs(body.entries) do
		local entry = lorebook_mod.normalize({
			key = raw.keys or raw.key,
			content = raw.content,
			enabled = raw.enabled,
			constant = raw.constant,
			position = raw.position,
			order = raw.order,
			role = raw.role,
		})
		state.world_info[#state.world_info + 1] = entry
	end
	save_world_info(state, caps)
	local result = {}
	for _, e in ipairs(state.world_info) do
		result[#result + 1] = entry_to_json(e)
	end
	return json_ok(res, { entries = result, imported = #body.entries })
end

local function api_get_world_info_export(state, _caps, _params, _body, res)
	local result = {}
	for _, e in ipairs(state.world_info) do
		result[#result + 1] = entry_to_json(e)
	end
	return json_ok(res, { entries = result })
end

-- ── Persona endpoints helpers ──────────────────────────────────────────────

local function save_personas(state, caps)
	if not caps.kv then return end
	caps.kv.set("personas", json.encode(state.personas))
	caps.kv.set("personas:active", state.active_persona or "")
end

local function activate_persona(state, name)
	local persona = find_persona(state.personas, name)
	if not persona then return nil, "persona not found" end
	state.active_persona = name
	state.user_name = persona.name
	return persona
end

-- ── Persona endpoints ─────────────────────────────────────────────────────

local function api_get_personas(state, _caps, _params, _body, res)
	local result = {}
	for _, p in ipairs(state.personas) do
		result[#result + 1] = { name = p.name, description = p.description }
	end
	return json_ok(res, { personas = result, active = state.active_persona })
end

local function api_post_personas_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or #body.name == 0 then
		return json_err(res, 400, "name required")
	end
	local name = body.name
	local description = body.description or ""
	local existing = find_persona(state.personas, name)
	if existing then
		existing.description = description
	else
		state.personas[#state.personas + 1] = { name = name, description = description }
	end
	-- If the active persona was updated, sync user_name.
	if state.active_persona == name then
		state.user_name = name
	end
	save_personas(state, caps)
	return json_ok(res, { name = name, description = description })
end

local function api_post_personas_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local name = body.name
	local _, idx = find_persona(state.personas, name)
	if not idx then return json_err(res, 404, "persona not found") end
	table.remove(state.personas, idx)
	-- If we deleted the active persona, switch to first remaining or create Default.
	if state.active_persona == name then
		if #state.personas == 0 then
			state.personas[1] = { name = "User", description = "" }
		end
		activate_persona(state, state.personas[1].name)
	end
	save_personas(state, caps)
	return json_ok(res, { deleted = true, active = state.active_persona })
end

local function api_post_personas_activate(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local persona, err = activate_persona(state, body.name)
	if not persona then return json_err(res, 404, err) end
	save_personas(state, caps)
	return json_ok(res, { active = state.active_persona })
end

-- ── Token count endpoint ───────────────────────────────────────────────────

local function api_get_token_count(state, caps, _params, _body, res)
	local tc, err = compute_token_count(state, caps)
	if not tc then return json_err(res, 500, err) end
	return json_ok(res, tc)
end

-- ── Settings endpoints ─────────────────────────────────────────────────────

local function api_get_settings(state, _caps, _params, _body, res)
	return json_ok(res, state.settings)
end

local function api_post_settings(state, caps, _params, body, res)
	if not body then return json_err(res, 400, "body required") end
	for _, key in ipairs(SETTINGS_KEYS) do
		if body[key] ~= nil then
			local val = tonumber(body[key])
			if val then state.settings[key] = val end
		end
	end
	-- Persist to kv.
	if caps.kv then
		caps.kv.set("settings", json.encode(state.settings))
	end
	return json_ok(res, state.settings)
end

-- ── Card editor endpoints ──────────────────────────────────────────────────

local CARD_EDIT_FIELDS = {
	"name", "description", "personality", "scenario", "first_mes", "mes_example",
	"system_prompt", "post_history_instructions", "creator_notes", "creator",
	"character_version",
}

local function card_edit_response(card)
	local data = {}
	for _, key in ipairs(CARD_EDIT_FIELDS) do
		data[key] = card[key] or ""
	end
	data.alternate_greetings = card.alternate_greetings or {}
	data.tags = card.tags or {}
	return data
end

local function api_get_card_edit(state, _caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	return json_ok(res, card_edit_response(state.card))
end

local function api_post_card_edit(state, caps, _params, body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end
	if not body then return json_err(res, 400, "body required") end

	-- Merge provided fields into card.
	for _, key in ipairs(CARD_EDIT_FIELDS) do
		if body[key] ~= nil then
			state.card[key] = body[key]
		end
	end
	if body.alternate_greetings ~= nil then
		state.card.alternate_greetings = body.alternate_greetings
	end
	if body.tags ~= nil then
		state.card.tags = body.tags
	end

	-- Persist overrides to kv.
	if caps.kv then
		caps.kv.set("card_overrides", json.encode(card_edit_response(state.card)))
	end

	return json_ok(res, card_edit_response(state.card))
end

local function api_post_card_reset(state, caps, _params, _body, res)
	if not state.card then return json_err(res, 404, "no card loaded") end

	-- Delete overrides from kv.
	if caps.kv then
		caps.kv.set("card_overrides", nil)
	end

	-- Reload card from PNG data.
	state.card = nil
	state.lorebook = nil
	load_card(state, caps)

	if not state.card then return json_err(res, 500, "failed to reload card") end
	return json_ok(res, card_edit_response(state.card))
end

-- ── Preset endpoints ───────────────────────────────────────────────────────

local function api_get_presets(_state, caps, _params, _body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	local data = presets_mod.load_all(caps.kv)
	return json_ok(res, data)
end

local function api_post_presets_save(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.preset then
		return json_err(res, 400, "type and preset required")
	end
	local preset = body.preset
	if not preset.name or type(preset.name) ~= "string" or #preset.name == 0 then
		return json_err(res, 400, "preset must have a name")
	end
	local ok, err = presets_mod.save(caps.kv, body.type, preset.name, preset)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_presets_delete(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.delete(caps.kv, body.type, body.name)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_presets_activate(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	local ok, err = presets_mod.set_active(caps.kv, body.type, body.name)
	if not ok then return json_err(res, 400, err) end
	return json_ok(res, { ok = true })
end

local function api_post_presets_import(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.json then
		return json_err(res, 400, "json field required")
	end
	local preset, err = presets_mod.import_preset(body.json)
	if not preset then return json_err(res, 400, err) end
	return json_ok(res, { preset = preset })
end

local function api_post_presets_export(_state, caps, _params, body, res)
	if not caps.kv then return json_err(res, 500, "kv not available") end
	if not body or not body.type or not body.name then
		return json_err(res, 400, "type and name required")
	end
	-- Find the preset.
	local list = presets_mod.load_all(caps.kv)
	local type_key = body.type .. "s"
	local presets_list = list[type_key]
	if not presets_list then return json_err(res, 404, "no presets for type") end
	local found
	for i = 1, #presets_list do
		if presets_list[i].name == body.name then
			found = presets_list[i]
			break
		end
	end
	if not found then return json_err(res, 404, "preset not found: " .. body.name) end
	return json_ok(res, { json = presets_mod.export_preset(found) })
end

-- ── Regex script endpoints ─────────────────────────────────────────────────

local function regex_script_to_json(s)
	return {
		name = s.name,
		find = s.find,
		replace = s.replace,
		enabled = s.enabled,
		scope = s.scope,
		order = s.order,
	}
end

local function api_get_regex(state, _caps, _params, _body, res)
	local result = {}
	for _, s in ipairs(state.regex_scripts) do
		result[#result + 1] = regex_script_to_json(s)
	end
	return json_ok(res, { scripts = result })
end

local function api_post_regex_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or #body.name == 0 then
		return json_err(res, 400, "name required")
	end
	if not body.find or type(body.find) ~= "string" then
		return json_err(res, 400, "find required")
	end
	-- Validate the pattern.
	local ok_pat, pat_err = pcall(string.find, "", body.find)
	if not ok_pat then
		return json_err(res, 400, "invalid pattern: " .. tostring(pat_err))
	end
	-- Find existing by name.
	local found
	for _, s in ipairs(state.regex_scripts) do
		if s.name == body.name then found = s; break end
	end
	if found then
		found.find = body.find
		found.replace = body.replace or ""
		if body.enabled ~= nil then found.enabled = body.enabled end
		if body.scope ~= nil then found.scope = body.scope end
		if body.order ~= nil then found.order = tonumber(body.order) or 0 end
	else
		found = {
			name = body.name,
			find = body.find,
			replace = body.replace or "",
			enabled = body.enabled ~= false,
			scope = body.scope or "ai_output",
			order = tonumber(body.order) or 0,
		}
		state.regex_scripts[#state.regex_scripts + 1] = found
	end
	save_regex_scripts(state, caps)
	return json_ok(res, regex_script_to_json(found))
end

local function api_post_regex_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local scripts = state.regex_scripts
	for i, s in ipairs(scripts) do
		if s.name == body.name then
			table.remove(scripts, i)
			save_regex_scripts(state, caps)
			return json_ok(res, { deleted = true })
		end
	end
	return json_err(res, 404, "script not found")
end

local function api_post_regex_test(_state, _caps, _params, body, res)
	if not body or not body.find or not body.input then
		return json_err(res, 400, "find and input required")
	end
	local ok_pat, pat_err = pcall(string.find, "", body.find)
	if not ok_pat then
		return json_err(res, 400, "invalid pattern: " .. tostring(pat_err))
	end
	local replace = body.replace or ""
	local ok_gsub, output = pcall(string.gsub, body.input, body.find, replace)
	if not ok_gsub then
		return json_err(res, 400, "gsub error: " .. tostring(output))
	end
	return json_ok(res, { output = output })
end


-- ── Author's Note endpoints ───────────────────────────────────────────────

local function save_authors_note(state, caps)
	if not caps.kv then return end
	caps.kv.set("authors_note", json.encode(state.authors_note))
end

local function api_get_authors_note(state, _caps, _params, _body, res)
	return json_ok(res, state.authors_note)
end

local function api_post_authors_note(state, caps, _params, body, res)
	if not body then return json_err(res, 400, "body required") end
	local an = state.authors_note
	if body.text ~= nil then an.text = tostring(body.text) end
	if body.depth ~= nil then
		local d = tonumber(body.depth)
		if d then an.depth = d end
	end
	if body.position ~= nil then
		if body.position == "before" or body.position == "after" then
			an.position = body.position
		end
	end
	save_authors_note(state, caps)
	return json_ok(res, an)
end

-- ── Instruct template endpoints ───────────────────────────────────────────

local function api_get_instruct(state, _caps, _params, _body, res)
	local result = {}
	for _, t in ipairs(state.instruct_templates) do
		result[#result + 1] = {
			name = t.name,
			mode = t.mode,
			system_prefix = t.system_prefix,
			system_suffix = t.system_suffix,
			user_prefix = t.user_prefix,
			user_suffix = t.user_suffix,
			assistant_prefix = t.assistant_prefix,
			assistant_suffix = t.assistant_suffix,
			separator = t.separator,
			stop_strings = t.stop_strings,
		}
	end
	return json_ok(res, { templates = result, active = state.instruct_active or "" })
end

local INSTRUCT_FIELDS = {
	"name", "mode",
	"system_prefix", "system_suffix",
	"user_prefix", "user_suffix",
	"assistant_prefix", "assistant_suffix",
	"separator",
}

local function api_post_instruct_save(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" or #body.name == 0 then
		return json_err(res, 400, "name required")
	end
	local template = {}
	for _, key in ipairs(INSTRUCT_FIELDS) do
		template[key] = body[key] ~= nil and body[key] or ""
	end
	template.name = body.name
	template.mode = body.mode == "instruct" and "instruct" or "chat"
	template.stop_strings = body.stop_strings or {}
	-- Ensure stop_strings is a table.
	if type(template.stop_strings) ~= "table" then template.stop_strings = {} end

	local existing, idx = find_instruct_template(state.instruct_templates, body.name)
	if existing then
		state.instruct_templates[idx] = template
	else
		state.instruct_templates[#state.instruct_templates + 1] = template
	end
	save_instruct(state, caps)
	return json_ok(res, template)
end

local function api_post_instruct_delete(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	local _, idx = find_instruct_template(state.instruct_templates, body.name)
	if not idx then return json_err(res, 404, "template not found") end
	table.remove(state.instruct_templates, idx)
	-- If we deleted the active template, clear active.
	if state.instruct_active == body.name then
		state.instruct_active = nil
	end
	save_instruct(state, caps)
	return json_ok(res, { deleted = true, active = state.instruct_active or "" })
end

local function api_post_instruct_activate(state, caps, _params, body, res)
	if not body or not body.name or type(body.name) ~= "string" then
		return json_err(res, 400, "name required")
	end
	-- Empty name clears active template (reverts to chat mode).
	if body.name == "" then
		state.instruct_active = nil
		save_instruct(state, caps)
		return json_ok(res, { active = "" })
	end
	local template = find_instruct_template(state.instruct_templates, body.name)
	if not template then return json_err(res, 404, "template not found") end
	state.instruct_active = body.name
	save_instruct(state, caps)
	return json_ok(res, { active = state.instruct_active })
end

-- ── Chat export endpoint ──────────────────────────────────────────────────

local function api_get_export_chat(state, caps, params, _body, res)
	local path, err = get_canonical_path(state)
	if not path then return json_err(res, 500, err) end

	local card_name = state.card and state.card.name or "Chat"
	local now = caps.time and caps.time.now() or os.time()
	local date_str = os.date("!%Y-%m-%d", now)
	local format = params.format or "text"

	if format == "json" then
		local messages = {}
		for _, msg in ipairs(path) do
			messages[#messages + 1] = { role = msg.role, content = msg.content }
		end
		local data = {
			card_name = card_name,
			messages = messages,
			exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
		}
		res.status = 200
		res.headers["Content-Type"] = "application/json"
		res.headers["Content-Disposition"] = 'attachment; filename="chat_' .. card_name .. '_' .. date_str .. '.json"'
		res.body = json.encode(data)
		return true
	else
		-- Plain text format.
		local lines = {}
		lines[#lines + 1] = "# Conversation with " .. card_name
		lines[#lines + 1] = "# Exported " .. date_str
		lines[#lines + 1] = ""
		for _, msg in ipairs(path) do
			local sender
			if msg.role == "assistant" then
				sender = card_name
			elseif msg.role == "user" then
				sender = state.user_name or "User"
			else
				sender = "System"
			end
			lines[#lines + 1] = sender .. ": " .. msg.content
			lines[#lines + 1] = ""
		end
		res.status = 200
		res.headers["Content-Type"] = "text/plain; charset=utf-8"
		res.headers["Content-Disposition"] = 'attachment; filename="chat_' .. card_name .. '_' .. date_str .. '.txt"'
		res.body = table.concat(lines, "\n")
		return true
	end
end

-- ── Connection test ─────────────────────────────────────────────────────────

local function api_post_connection_test(state, caps, params, body, res)
	if not caps.llm or not caps.llm.call then
		return json_ok(res, { success = false, error = "no LLM capability configured" })
	end
	local test_messages = {{ role = "user", content = "Hello" }}
	local t0 = os.clock()
	local response, err = caps.llm.call(test_messages, { max_tokens = 10 })
	local elapsed_ms = math.floor((os.clock() - t0) * 1000 + 0.5)
	if response then
		return json_ok(res, {
			success = true,
			response = response:sub(1, 100),
			latency_ms = elapsed_ms,
		})
	else
		return json_ok(res, {
			success = false,
			error = tostring(err),
		})
	end
end

-- ── Router ──────────────────────────────────────────────────────────────────

local routes = {
	["GET /api/card"]             = api_get_card,
	["GET /api/avatar"]           = api_get_avatar,
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
	["GET /api/lorebook"]          = api_get_lorebook,
	["POST /api/lorebook/update"]  = api_post_lorebook_update,
	["POST /api/lorebook/add"]     = api_post_lorebook_add,
	["POST /api/lorebook/delete"]  = api_post_lorebook_delete,
	["GET /api/world_info"]          = api_get_world_info,
	["POST /api/world_info/update"]  = api_post_world_info_update,
	["POST /api/world_info/add"]     = api_post_world_info_add,
	["POST /api/world_info/delete"]  = api_post_world_info_delete,
	["POST /api/world_info/import"]  = api_post_world_info_import,
	["GET /api/world_info/export"]   = api_get_world_info_export,
	["GET /api/sessions"]         = api_get_sessions,
	["POST /api/session/new"]     = api_post_session_new,
	["POST /api/session/switch"]  = api_post_session_switch,
	["POST /api/session/delete"]  = api_post_session_delete,
	["GET /api/personas"]           = api_get_personas,
	["POST /api/personas/save"]     = api_post_personas_save,
	["POST /api/personas/delete"]   = api_post_personas_delete,
	["POST /api/personas/activate"] = api_post_personas_activate,
	["GET /api/token_count"]      = api_get_token_count,
	["GET /api/settings"]         = api_get_settings,
	["POST /api/settings"]        = api_post_settings,
	["GET /api/card/edit"]          = api_get_card_edit,
	["POST /api/card/edit"]         = api_post_card_edit,
	["POST /api/card/reset"]        = api_post_card_reset,
	["GET /api/presets"]           = api_get_presets,
	["POST /api/presets/save"]     = api_post_presets_save,
	["POST /api/presets/delete"]   = api_post_presets_delete,
	["POST /api/presets/activate"] = api_post_presets_activate,
	["POST /api/presets/import"]   = api_post_presets_import,
	["POST /api/presets/export"]   = api_post_presets_export,
	["GET /api/regex"]             = api_get_regex,
	["POST /api/regex/save"]       = api_post_regex_save,
	["POST /api/regex/delete"]     = api_post_regex_delete,
	["POST /api/regex/test"]       = api_post_regex_test,
	["GET /api/authors_note"]       = api_get_authors_note,
	["POST /api/authors_note"]      = api_post_authors_note,
	["GET /api/export/chat"]        = api_get_export_chat,
	["POST /api/connection/test"]    = api_post_connection_test,
	["GET /api/instruct"]             = api_get_instruct,
	["POST /api/instruct/save"]       = api_post_instruct_save,
	["POST /api/instruct/delete"]     = api_post_instruct_delete,
	["POST /api/instruct/activate"]   = api_post_instruct_activate,
	["GET /api/group"]              = api_get_group,
	["POST /api/group/toggle"]      = api_post_group_toggle,
	["POST /api/group/add"]         = api_post_group_add,
	["POST /api/group/remove"]      = api_post_group_remove,
	["POST /api/group/order"]       = api_post_group_order,
	-- Aliases for renamed endpoints.
	["GET /api/siblings"]         = api_get_swipes,
	["POST /api/branch/new"]      = api_post_swipe_new,
}

function M.create(caps, opts)
	opts = opts or {}
	local state = create_state()

	-- Read user name from opts (previously from caps.config, now passed directly).
	if opts.user_name then
		state.user_name = opts.user_name
	end

	-- Initialize generation settings from defaults, then overlay persisted values.
	state.settings = default_settings()
	if caps.kv then
		local raw = caps.kv.get("settings")
		if raw then
			local ok, saved = pcall(json.decode, raw)
			if ok and type(saved) == "table" then
				for _, key in ipairs(SETTINGS_KEYS) do
					if saved[key] ~= nil then
						local val = tonumber(saved[key])
						if val then state.settings[key] = val end
					end
				end
			end
		end
	end

	-- Load card.
	load_card(state, caps)

	-- Apply card overrides from kv (user edits take precedence over PNG data).
	if caps.kv and state.card then
		local raw = caps.kv.get("card_overrides")
		if raw then
			local ok, overrides = pcall(json.decode, raw)
			if ok and type(overrides) == "table" then
				for k, v in pairs(overrides) do
					state.card[k] = v
				end
			end
		end
	end

	-- Load lorebook from kv (overrides card's character_book if present).
	if caps.kv then
		local raw = caps.kv.get("lorebook")
		if raw then
			local ok, saved = pcall(json.decode, raw)
			if ok and type(saved) == "table" then
				state.lorebook = saved
			end
		end
	end

	-- Load world info from kv.
	if caps.kv then
		local raw = caps.kv.get("world_info")
		if raw then
			local ok, saved = pcall(json.decode, raw)
			if ok and type(saved) == "table" then
				state.world_info = saved
			end
		end
	end

	-- Load personas from kv or initialize defaults.
	state.personas = { { name = state.user_name, description = "" } }
	state.active_persona = state.user_name
	if caps.kv then
		local raw = caps.kv.get("personas")
		if raw then
			local ok_p, saved = pcall(json.decode, raw)
			if ok_p and type(saved) == "table" and #saved > 0 then
				state.personas = saved
			end
		end
		local active = caps.kv.get("personas:active")
		if active and active ~= "" then
			local p = find_persona(state.personas, active)
			if p then
				state.active_persona = active
				state.user_name = p.name
			end
		end
	end

	-- Load regex scripts from kv.
	if caps.kv then
		local raw = caps.kv.get("regex_scripts")
		if raw then
			local ok_r, saved = pcall(json.decode, raw)
			if ok_r and type(saved) == "table" then
				state.regex_scripts = saved
			end
		end
	end

	-- Load instruct templates from kv or initialize defaults.
	do
		local templates = {}
		for _, t in ipairs(DEFAULT_INSTRUCT_TEMPLATES) do
			local copy = {}
			for k, v in pairs(t) do
				if type(v) == "table" then
					local arr = {}
					for _, item in ipairs(v) do arr[#arr + 1] = item end
					copy[k] = arr
				else
					copy[k] = v
				end
			end
			templates[#templates + 1] = copy
		end
		state.instruct_templates = templates
		state.instruct_active = "OpenAI (native)"
	end
	if caps.kv then
		local raw = caps.kv.get("instruct_templates")
		if raw then
			local ok_it, saved = pcall(json.decode, raw)
			if ok_it and type(saved) == "table" and #saved > 0 then
				state.instruct_templates = saved
			end
		end
		local active = caps.kv.get("instruct_active")
		if active ~= nil then
			if active == "" then
				state.instruct_active = nil
			else
				local t = find_instruct_template(state.instruct_templates, active)
				if t then state.instruct_active = active end
			end
		end
	end

	-- Load author's note from kv or initialize defaults.
	state.authors_note = { text = "", depth = 4, position = "after" }
	if caps.kv then
		local raw = caps.kv.get("authors_note")
		if raw then
			local ok_an, saved = pcall(json.decode, raw)
			if ok_an and type(saved) == "table" then
				if saved.text ~= nil then state.authors_note.text = saved.text end
				if saved.depth ~= nil then state.authors_note.depth = saved.depth end
				if saved.position ~= nil then state.authors_note.position = saved.position end
			end
		end
	end

	-- Open conversation database.
	local db_path = opts.db_path or ":memory:"
	local time_fn = caps.time and caps.time.now or os.time
	local conv_db, db_err = conversation.open(db_path, time_fn)
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

	-- Initialize group chat.
	init_group(state)
	if caps.kv then
		local raw = caps.kv.get("group")
		if raw then
			local ok_g, saved = pcall(json.decode, raw)
			if ok_g and type(saved) == "table" then
				state.group.enabled = saved.enabled or false
				state.group.turn_order = saved.turn_order or "round_robin"
				state.group.next_speaker = saved.next_speaker or 1
				if saved.members then
					for i, sm in ipairs(saved.members) do
						if sm.is_primary then
							-- Primary member already initialized from card.
						elseif sm.card_json then
							local cdata = card_mod.from_json(sm.card_json)
							if cdata then
								state.group.members[#state.group.members + 1] = {
									card = cdata,
									name = sm.name,
									is_primary = false,
								}
							end
						end
					end
				end
			end
		end
	end

	-- If session has no messages and card has a greeting, create it.
	local path = get_canonical_path(state)
	if not path or #path == 0 then
		init_greeting(state)
	end

	-- Extension -> content-type map for static file serving via caps.self.
	local MIME_TYPES = {
		html = "text/html; charset=utf-8",
		js = "application/javascript",
		css = "text/css",
		json = "application/json",
		png = "image/png",
		jpg = "image/jpeg",
		jpeg = "image/jpeg",
		gif = "image/gif",
		svg = "image/svg+xml",
		ico = "image/x-icon",
		woff = "font/woff",
		woff2 = "font/woff2",
		ttf = "font/ttf",
		txt = "text/plain",
	}

	local serve_static = not opts.no_static and caps.self and caps.self.entry

	local function handler(req, res)
		local req_path, params = parse_target(req.target or req.path or "/")
		local key = req.method .. " " .. req_path
		local route = routes[key]
		if route then
			local req_body = read_json_body(req)
			return route(state, caps, params, req_body, res)
		end
		-- Static files via caps.self tarball entries.
		if serve_static then
			local entry_path = "static" .. req_path
			if req_path == "/" then entry_path = "static/index.html" end
			local content = caps.self.entry(entry_path)
			if content then
				local ext = entry_path:match("%.([^%.]+)$")
				res.status = 200
				res.headers["Content-Type"] = MIME_TYPES[ext] or "application/octet-stream"
				res.body = content
				return true
			end
		end
	end

	return { handler = handler, state = state }
end

return M
