-- lib/platform/apps/charactercardv2/dom.lua
-- CCv2 Card App — conversation view (dom entrypoint).
--
-- Runs in the browser after lua2ts transpilation. Uses reactive DOM to render
-- a conversation interface: scrollable message list + pinned input row.
--
-- Receives capabilities from the platform:
--   caps.llm.call(messages) -> string | nil, err
--   caps.llm.count_tokens(text) -> integer (optional, fallback: #text/4)
--   caps.png.text(keyword)  -> string | nil
--   caps.kv.get(key) / caps.kv.set(key, val) — persistent state (optional)
--   caps.config.get(key)    -> value | nil — global settings (optional)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local R        = require("lib.reactive")
local dom      = require("lib.web.reactive_dom")
local widget   = require("lib.widget")
local card_mod = require("lib.formats.ccv2.card")
local context  = require("lib.formats.ccv2.context")
local macro    = require("lib.formats.ccv2.macro")
local lorebook_mod = require("lib.formats.ccv2.lorebook")
--:: require "lib.formats.ccv2.ccv2_types"

local M = {}

-- ── State model ─────────────────────────────────────────────────────────────

--: () -> table
function M.create_state()
	return {
		messages       = R.signal({}),      -- {role, content}[]
		input_text     = R.signal(""),      -- current input field text
		loading        = R.signal(false),   -- true while waiting for LLM
		current_card   = R.signal(nil),     -- CardData | nil
		lorebook       = R.signal(nil),     -- NormalizedEntry[] | nil
		greeting_index = R.signal(0),       -- index into alternate_greetings (0 = first_mes)
		session_id     = R.signal(nil),     -- current conversation session id
		user_name      = R.signal("User"),  -- user display name
	}
end

-- ── State operations ────────────────────────────────────────────────────────

--: (table, string, string) -> nil
function M.append_message(state, role, content)
	state.messages.update(function(msgs)
		local new = {}
		for i = 1, #msgs do new[i] = msgs[i] end
		new[#new + 1] = { role = role, content = content }
		return new
	end)
end

-- Replace the last message (for regenerate).
--: (table, string, string) -> nil
function M.replace_last_message(state, role, content)
	state.messages.update(function(msgs)
		local new = {}
		for i = 1, #msgs do new[i] = msgs[i] end
		if #new > 0 and new[#new].role == role then
			new[#new] = { role = role, content = content }
		else
			new[#new + 1] = { role = role, content = content }
		end
		return new
	end)
end

-- Remove the last message if it matches the given role.
--: (table, string) -> { role: string, content: string }?
function M.pop_last_message(state, role)
	local removed
	state.messages.update(function(msgs)
		if #msgs == 0 or msgs[#msgs].role ~= role then return msgs end
		local new = {}
		for i = 1, #msgs - 1 do new[i] = msgs[i] end
		removed = msgs[#msgs]
		return new
	end)
	return removed
end

--: (table) -> nil
function M.clear_input(state)
	state.input_text.set("")
end

-- ── Macro environment ───────────────────────────────────────────────────────

--: (table) -> { [string]: string }
function M.make_macro_env(state)
	local card = state.current_card.get()
	if not card then return {} end
	return {
		char = card.name or "",
		user = state.user_name.get(),
	}
end

-- ── Card loading ────────────────────────────────────────────────────────────

--: (table, table) -> CardData | nil, string
function M.load_card(state, caps)
	if not caps or not caps.png then return nil, "no png capability" end
	local raw = caps.png.text("chara")
	if not raw then return nil, "no chara chunk" end
	-- The chara chunk is base64-encoded CCv2 JSON.
	local json_str = raw
	if json_str:sub(1, 1) ~= "{" then
		local ok, b64 = pcall(require, "lib.base64")
		if ok and b64 then
			local decoded, err = b64.decode(json_str)
			if not decoded then return nil, "base64 decode failed: " .. tostring(err) end
			json_str = decoded
		elseif type(atob) == "function" then
			json_str = atob(json_str) --: string
		else
			return nil, "cannot decode base64: no decoder available"
		end
	end
	local card_data, err = card_mod.from_json(json_str)
	if not card_data then return nil, err end
	state.current_card.set(card_data)
	-- Extract lorebook if present
	if card_data.character_book then
		local entries = lorebook_mod.from_ccv2(card_data.character_book)
		state.lorebook.set(entries)
	end
	return card_data
end

-- ── Greeting management ─────────────────────────────────────────────────────

-- Get all available greetings (first_mes + alternate_greetings).
--: (table) -> string[]
function M.get_greetings(state)
	local card = state.current_card.get()
	if not card then return {} end
	local greetings = {}
	if card.first_mes and #card.first_mes > 0 then
		greetings[#greetings + 1] = card.first_mes
	end
	if card.alternate_greetings then
		for _, g in ipairs(card.alternate_greetings) do
			if g and #g > 0 then
				greetings[#greetings + 1] = g
			end
		end
	end
	return greetings
end

-- Get the current greeting with macros expanded.
--: (table) -> string?
function M.get_current_greeting(state)
	local greetings = M.get_greetings(state)
	if #greetings == 0 then return nil end
	local idx = state.greeting_index.get() + 1 -- 0-based to 1-based
	if idx < 1 or idx > #greetings then idx = 1 end
	local env = M.make_macro_env(state)
	return macro.substitute(greetings[idx], env)
end

-- Cycle to next/previous greeting (before conversation starts).
--: (table, number) -> nil
function M.cycle_greeting(state, delta)
	local greetings = M.get_greetings(state)
	if #greetings <= 1 then return end
	state.greeting_index.update(function(idx)
		return (idx + delta) % #greetings
	end)
	-- Replace the greeting message
	local greeting = M.get_current_greeting(state)
	if greeting then
		M.replace_last_message(state, "assistant", greeting)
	end
end

-- ── Context assembly ────────────────────────────────────────────────────────

-- Build context using the full context assembly engine.
--: (table, table) -> { role: string, content: string }[]
function M.build_context(state, caps)
	local card = state.current_card.get()
	local msgs = state.messages.get()
	if not card then
		-- No card loaded — just return history as-is
		local result = {}
		for i = 1, #msgs do
			result[#result + 1] = { role = msgs[i].role, content = msgs[i].content }
		end
		return result
	end

	-- Token counter: use caps.llm.count_tokens if available, else rough estimate
	local count_tokens
	if caps and caps.llm and caps.llm.count_tokens then
		count_tokens = caps.llm.count_tokens
	else
		count_tokens = function(text) return math.ceil(#text / 4) end
	end

	-- Read settings from caps.config if available
	local max_context = 4096
	local max_response = 512
	if caps and caps.config and caps.config.get then
		max_context = caps.config.get("max_context") or max_context
		max_response = caps.config.get("max_response") or max_response
	end

	local result, err = context.assemble({
		card = card,
		history = msgs,
		count_tokens = count_tokens,
		max_context = max_context,
		max_response = max_response,
		char_name = card.name,
		user_name = state.user_name.get(),
		lorebook_entries = state.lorebook.get(),
	})
	if not result then
		-- Fallback: return raw history on assembly error
		local fallback = {}
		for i = 1, #msgs do
			fallback[#fallback + 1] = { role = msgs[i].role, content = msgs[i].content }
		end
		return fallback
	end
	return result
end

-- ── Send flow ───────────────────────────────────────────────────────────────

--: (table, table) -> string | nil, string
function M.send_message(state, caps)
	local text = state.input_text.get()
	if not text or #text == 0 then return nil, "empty input" end
	if state.loading.get() then return nil, "already loading" end

	M.clear_input(state)
	M.append_message(state, "user", text)

	state.loading.set(true)
	local messages = M.build_context(state, caps)
	local response, err = caps.llm.call(messages)
	state.loading.set(false)

	if not response then
		M.append_message(state, "system", "Error: " .. tostring(err))
		return nil, err
	end

	M.append_message(state, "assistant", response)
	M.save_messages(state, caps)
	return response
end

-- Regenerate the last assistant response.
--: (table, table) -> string | nil, string
function M.regenerate(state, caps)
	if state.loading.get() then return nil, "already loading" end
	-- Remove the last assistant message
	local removed = M.pop_last_message(state, "assistant")
	if not removed then return nil, "no assistant message to regenerate" end

	state.loading.set(true)
	local messages = M.build_context(state, caps)
	local response, err = caps.llm.call(messages)
	state.loading.set(false)

	if not response then
		-- Restore the old message on error
		M.append_message(state, "assistant", removed.content)
		return nil, err
	end

	M.append_message(state, "assistant", response)
	M.save_messages(state, caps)
	return response
end

-- Continue: ask the LLM to continue without a user message.
--: (table, table) -> string | nil, string
function M.continue_message(state, caps)
	if state.loading.get() then return nil, "already loading" end

	state.loading.set(true)
	local messages = M.build_context(state, caps)
	local response, err = caps.llm.call(messages)
	state.loading.set(false)

	if not response then
		M.append_message(state, "system", "Error: " .. tostring(err))
		return nil, err
	end

	-- Append continuation to last assistant message if possible
	local msgs = state.messages.get()
	if #msgs > 0 and msgs[#msgs].role == "assistant" then
		M.replace_last_message(state, "assistant", msgs[#msgs].content .. response)
	else
		M.append_message(state, "assistant", response)
	end
	M.save_messages(state, caps)
	return response
end

-- ── Persistence ─────────────────────────────────────────────────────────────

--: (table, table) -> nil
function M.save_messages(state, caps)
	if not caps or not caps.kv then return end
	local msgs = state.messages.get()
	local ok, json_mod = pcall(require, "lib.format.json")
	if not ok then return end
	local key = "messages"
	local sid = state.session_id.get()
	if sid then key = "messages:" .. sid end
	caps.kv.set(key, json_mod.encode(msgs))
end

--: (table, table) -> boolean
function M.load_messages(state, caps)
	if not caps or not caps.kv then return false end
	local ok, json_mod = pcall(require, "lib.format.json")
	if not ok then return false end
	local key = "messages"
	local sid = state.session_id.get()
	if sid then key = "messages:" .. sid end
	local raw = caps.kv.get(key)
	if not raw then return false end
	local parse_ok, msgs = pcall(json_mod.decode, raw)
	if not parse_ok or type(msgs) ~= "table" then return false end
	state.messages.set(msgs)
	return true
end

-- ── Widgets ─────────────────────────────────────────────────────────────────

local function message_widget(msg_signal)
	return function()
		local wrapper = document.createElement("div")
		widget.subscribe_now(msg_signal, function(m)
			if m then
				wrapper.setAttribute("class", "message message-" .. (m.role or "unknown"))
			end
		end)
		local content_node = document.createTextNode("")
		widget.subscribe_now(msg_signal, function(m)
			if m then
				content_node.data = m.content or ""
			end
		end)
		local content_div = document.createElement("div")
		content_div.setAttribute("class", "message-content")
		content_div.appendChild(content_node)
		wrapper.appendChild(content_div)
		return wrapper
	end
end

function M.message_list_widget(state)
	local list_w = dom.each(function(item_sig)
		local inner_w = message_widget(item_sig)
		return inner_w()
	end)
	return function()
		local container = document.createElement("div")
		container.setAttribute("class", "message-list")
		local node, cleanup = widget.with_scope(function()
			return list_w(state.messages)
		end)
		container.appendChild(node)
		widget.register(cleanup)
		return container
	end
end

function M.loading_indicator_widget(state)
	return function()
		local el = document.createElement("div")
		el.setAttribute("class", "loading-indicator")
		local text_node = document.createTextNode("")
		el.appendChild(text_node)
		widget.subscribe_now(state.loading, function(is_loading)
			if is_loading then
				el.setAttribute("class", "loading-indicator loading-visible")
				text_node.data = "..."
			else
				el.setAttribute("class", "loading-indicator")
				text_node.data = ""
			end
		end)
		return el
	end
end

function M.input_row_widget(state, caps)
	return function()
		local row = document.createElement("div")
		row.setAttribute("class", "input-row")

		-- Textarea
		local textarea = document.createElement("textarea")
		textarea.setAttribute("class", "input-textarea")
		textarea.setAttribute("placeholder", "Type a message...")
		textarea.setAttribute("rows", "1")

		widget.subscribe_now(state.input_text, function(v)
			textarea.value = v or ""
		end)
		dom.on(textarea, "input", function()
			state.input_text.set(textarea.value or "")
		end)
		dom.on(textarea, "keydown", function(e)
			if e and e.key == "Enter" and not e.shiftKey then
				if e.preventDefault then e.preventDefault() end
				M.send_message(state, caps)
			end
		end)

		-- Send button
		local send_btn = document.createElement("button")
		send_btn.setAttribute("class", "send-button")
		send_btn.appendChild(document.createTextNode("Send"))
		dom.on(send_btn, "click", function() M.send_message(state, caps) end)

		-- Regenerate button
		local regen_btn = document.createElement("button")
		regen_btn.setAttribute("class", "regen-button")
		regen_btn.appendChild(document.createTextNode("Regen"))
		dom.on(regen_btn, "click", function() M.regenerate(state, caps) end)

		-- Continue button
		local cont_btn = document.createElement("button")
		cont_btn.setAttribute("class", "continue-button")
		cont_btn.appendChild(document.createTextNode("Continue"))
		dom.on(cont_btn, "click", function() M.continue_message(state, caps) end)

		-- Disable all buttons while loading
		widget.subscribe_now(state.loading, function(is_loading)
			local val = is_loading and "true" or ""
			send_btn.setAttribute("disabled", val)
			regen_btn.setAttribute("disabled", val)
			cont_btn.setAttribute("disabled", val)
		end)

		row.appendChild(textarea)
		row.appendChild(send_btn)
		row.appendChild(regen_btn)
		row.appendChild(cont_btn)
		return row
	end
end

-- Greeting swipe bar (prev/next greeting before conversation starts).
function M.greeting_bar_widget(state)
	return function()
		local bar = document.createElement("div")
		bar.setAttribute("class", "greeting-bar")

		local prev_btn = document.createElement("button")
		prev_btn.appendChild(document.createTextNode("<"))
		dom.on(prev_btn, "click", function() M.cycle_greeting(state, -1) end)

		local label = document.createElement("span")
		label.setAttribute("class", "greeting-label")

		local next_btn = document.createElement("button")
		next_btn.appendChild(document.createTextNode(">"))
		dom.on(next_btn, "click", function() M.cycle_greeting(state, 1) end)

		-- Update label and visibility reactively
		local update = function()
			local greetings = M.get_greetings(state)
			local idx = state.greeting_index.get()
			if #greetings <= 1 then
				bar.setAttribute("class", "greeting-bar greeting-bar-hidden")
			else
				bar.setAttribute("class", "greeting-bar")
				label.textContent = tostring(idx + 1) .. "/" .. tostring(#greetings)
			end
		end
		widget.subscribe_now(state.greeting_index, function() update() end)
		widget.subscribe_now(state.current_card, function() update() end)

		bar.appendChild(prev_btn)
		bar.appendChild(label)
		bar.appendChild(next_btn)
		return bar
	end
end

function M.app_widget(state, caps)
	return function()
		local app = document.createElement("div")
		app.setAttribute("class", "card-app")

		-- Greeting bar
		local greet_node, greet_cleanup = widget.with_scope(
			M.greeting_bar_widget(state)
		)
		app.appendChild(greet_node)
		widget.register(greet_cleanup)

		-- Message list
		local list_node, list_cleanup = widget.with_scope(
			M.message_list_widget(state)
		)
		app.appendChild(list_node)
		widget.register(list_cleanup)

		-- Loading indicator
		local load_node, load_cleanup = widget.with_scope(
			M.loading_indicator_widget(state)
		)
		app.appendChild(load_node)
		widget.register(load_cleanup)

		-- Input row
		local input_node, input_cleanup = widget.with_scope(
			M.input_row_widget(state, caps)
		)
		app.appendChild(input_node)
		widget.register(input_cleanup)

		return app
	end
end

-- ── Entrypoint ──────────────────────────────────────────────────────────────

--: (table) -> { state: table, cleanup: () -> nil }
function M.init(caps)
	local state = M.create_state()

	-- Read user name from config if available
	if caps and caps.config and caps.config.get then
		local name = caps.config.get("user_name")
		if name then state.user_name.set(name) end
	end

	-- Load card
	M.load_card(state, caps)

	-- Try to restore saved messages
	local restored = M.load_messages(state, caps)

	-- If no saved messages and card has a greeting, show it
	if not restored or #state.messages.get() == 0 then
		local greeting = M.get_current_greeting(state)
		if greeting then
			M.append_message(state, "assistant", greeting)
		end
	end

	-- Mount the app
	local app_w = M.app_widget(state, caps)
	local container = document.body or document.createElement("div")
	local cleanup = dom.mount(app_w, R.signal(true), container)

	return {
		state = state,
		cleanup = cleanup,
	}
end

return M
