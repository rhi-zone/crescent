-- lib/platform/apps/card/dom.lua
-- CCv2 Card App — conversation view (dom entrypoint).
--
-- Runs in the browser after lua2ts transpilation. Uses reactive DOM to render
-- a conversation interface: scrollable message list + pinned input row.
--
-- Receives capabilities from the platform:
--   caps.llm.call(messages) -> string | nil, err
--   caps.png.text(keyword)  -> string | nil
--   caps.kv.get(key) / caps.kv.set(key, val) — persistent state (optional)
--   caps.conversations      -> shared_db handle (optional, future)
--   caps.config             -> user preferences (optional, future)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local R        = require("lib.reactive")
local dom      = require("lib.web.reactive_dom")
local widget   = require("lib.widget")
local card_mod = require("lib.formats.ccv2.card")

local M = {}

-- ── State model ─────────────────────────────────────────────────────────────

-- create_state() -> state table with all reactive signals
function M.create_state()
	return {
		messages    = R.signal({}),      -- {role, content}[]
		input_text  = R.signal(""),      -- current input field text
		loading     = R.signal(false),   -- true while waiting for LLM
		current_card = R.signal(nil),    -- parsed card data (table or nil)
		session_id  = R.signal(nil),     -- current conversation session id
	}
end

-- ── State operations ────────────────────────────────────────────────────────

-- append_message(state, role, content) — add a message to the list
function M.append_message(state, role, content)
	state.messages.update(function(msgs)
		local new = {}
		for i = 1, #msgs do new[i] = msgs[i] end
		new[#new + 1] = { role = role, content = content }
		return new
	end)
end

-- clear_input(state) — reset input field
function M.clear_input(state)
	state.input_text.set("")
end

-- ── Card loading ────────────────────────────────────────────────────────────

-- load_card(state, caps) — read card data from PNG chunk via caps.png
-- Returns card_data or nil, errmsg
function M.load_card(state, caps)
	if not caps or not caps.png then return nil, "no png capability" end
	local raw = caps.png.text("chara")
	if not raw then return nil, "no chara chunk" end
	-- The chara chunk is base64-encoded CCv2 JSON.
	-- Decode base64, then use card.from_json for normalization.
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
	return card_data
end

-- ── Context assembly ────────────────────────────────────────────────────────

-- build_context(state) -> messages array for LLM call
-- Builds the messages array from card system prompt + conversation history.
function M.build_context(state)
	local card = state.current_card.get()
	local msgs = state.messages.get()
	local context = {}
	-- System prompt from card
	if card then
		local system_text = card.description or ""
		if #system_text > 0 then
			context[#context + 1] = { role = "system", content = system_text }
		end
		-- First message / greeting
		local first_msg = card.first_mes
		if first_msg and #first_msg > 0 and #msgs == 0 then
			-- If no messages yet, the greeting is the assistant's opening
			context[#context + 1] = { role = "assistant", content = first_msg }
		end
	end
	-- Conversation history
	for i = 1, #msgs do
		context[#context + 1] = { role = msgs[i].role, content = msgs[i].content }
	end
	return context
end

-- ── Send flow ───────────────────────────────────────────────────────────────

-- send_message(state, caps) — handle sending user input to LLM
-- Returns assistant response text or nil, errmsg
function M.send_message(state, caps)
	local text = state.input_text.get()
	if not text or #text == 0 then return nil, "empty input" end
	if state.loading.get() then return nil, "already loading" end

	-- 1. Clear input, add user message
	M.clear_input(state)
	M.append_message(state, "user", text)

	-- 2. Build context and call LLM
	state.loading.set(true)
	local context = M.build_context(state)
	local response, err = caps.llm.call(context)
	state.loading.set(false)

	if not response then
		-- Add error as system message so user sees it
		M.append_message(state, "system", "Error: " .. tostring(err))
		return nil, err
	end

	-- 3. Add assistant response
	M.append_message(state, "assistant", response)
	return response
end

-- ── Widgets ─────────────────────────────────────────────────────────────────

-- message_widget(msg_signal) -> DOM node
-- Renders a single message with role styling.
local function message_widget(msg_signal)
	return function()
		local wrapper = document.createElement("div")
		-- Set class reactively based on role
		widget.subscribe_now(msg_signal, function(m)
			if m then
				wrapper.setAttribute("class", "message message-" .. (m.role or "unknown"))
			end
		end)
		-- Content text node
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

-- message_list_widget(state) -> Widget
-- Scrollable list of messages using dom.each.
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

-- loading_indicator_widget(state) -> Widget
-- Shows a loading indicator when state.loading is true.
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

-- input_row_widget(state, caps) -> Widget
-- Input textarea + send button. Enter sends, Shift+Enter adds newline.
function M.input_row_widget(state, caps)
	return function()
		local row = document.createElement("div")
		row.setAttribute("class", "input-row")

		-- Textarea
		local textarea = document.createElement("textarea")
		textarea.setAttribute("class", "input-textarea")
		textarea.setAttribute("placeholder", "Type a message...")
		textarea.setAttribute("rows", "1")

		-- Two-way bind textarea value to state.input_text
		widget.subscribe_now(state.input_text, function(v)
			textarea.value = v or ""
		end)
		local function on_input()
			state.input_text.set(textarea.value or "")
		end
		dom.on(textarea, "input", on_input)

		-- Enter to send, Shift+Enter for newline
		local function on_keydown(e)
			if e and e.key == "Enter" and not e.shiftKey then
				if e.preventDefault then e.preventDefault() end
				M.send_message(state, caps)
			end
		end
		dom.on(textarea, "keydown", on_keydown)

		-- Send button
		local send_btn = document.createElement("button")
		send_btn.setAttribute("class", "send-button")
		local btn_text = document.createTextNode("Send")
		send_btn.appendChild(btn_text)
		local function on_click()
			M.send_message(state, caps)
		end
		dom.on(send_btn, "click", on_click)

		-- Disable send button while loading
		widget.subscribe_now(state.loading, function(is_loading)
			if is_loading then
				send_btn.setAttribute("disabled", "true")
			else
				send_btn.setAttribute("disabled", "")
			end
		end)

		row.appendChild(textarea)
		row.appendChild(send_btn)
		return row
	end
end

-- ── Main app widget ─────────────────────────────────────────────────────────

-- app_widget(state, caps) -> Widget
-- The full conversation view: message list + loading indicator + input row.
function M.app_widget(state, caps)
	return function()
		local app = document.createElement("div")
		app.setAttribute("class", "card-app")

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

-- init(caps) — called by the platform to bootstrap the app.
-- Creates state, loads card, mounts the app widget into document.body.
function M.init(caps)
	local state = M.create_state()

	-- Load card data if PNG capability is available
	M.load_card(state, caps)

	-- If card has a greeting and no messages yet, show it
	local card = state.current_card.get()
	if card then
		local first_msg = card.first_mes
		if first_msg and #first_msg > 0 then
			M.append_message(state, "assistant", first_msg)
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
