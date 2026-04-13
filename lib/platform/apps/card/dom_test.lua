-- lib/platform/apps/card/dom_test.lua
-- Tests for the CCv2 Card App conversation view.
--
-- Uses a mock DOM (same pattern as reactive_dom_test.lua) and mock capabilities
-- to test state logic, message flow, and widget construction.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local base64 = require("lib.base64")
local json = require("lib.format.json")
local card_mod = require("lib.formats.ccv2.card")
--:: require "lib.formats.ccv2.ccv2_types"

-- ── Mock DOM ────────────────────────────────────────────────────────────────

local function make_style()
	return { display = "" }
end

local function make_node(node_type, tag_or_data)
	local n = {}
	n.nodeType   = node_type
	n.tagName    = (node_type == 1) and tag_or_data or nil
	n.data       = (node_type == 3) and (tag_or_data or "") or nil
	n.children   = {}
	n.attributes = {}
	n.listeners  = {}
	n.style      = make_style()
	n.parentNode = nil
	n.firstChild = nil
	n.value      = ""

	local function _refresh_first()
		n.firstChild = n.children[1] or nil
	end

	function n.appendChild(child)
		n.children[#n.children + 1] = child
		child.parentNode = n
		_refresh_first()
		return child
	end

	function n.removeChild(child)
		for i = 1, #n.children do
			if n.children[i] == child then
				table.remove(n.children, i)
				child.parentNode = nil
				_refresh_first()
				return child
			end
		end
		error("removeChild: node not found")
	end

	function n.setAttribute(name, value)
		n.attributes[name] = value
	end

	function n.getAttribute(name)
		return n.attributes[name]
	end

	function n.addEventListener(event, handler)
		if not n.listeners[event] then n.listeners[event] = {} end
		n.listeners[event][handler] = true
	end

	function n.removeEventListener(event, handler)
		if n.listeners[event] then
			n.listeners[event][handler] = nil
		end
	end

	function n._dispatch(event, event_obj)
		if n.listeners[event] then
			for h in pairs(n.listeners[event]) do h(event_obj) end
		end
	end

	return n
end

local mock_document = {}
function mock_document.createElement(tag)
	return make_node(1, tag)
end
function mock_document.createTextNode(data)
	return make_node(3, data or "")
end
mock_document.body = make_node(1, "body")

-- Install as global
document = mock_document --: any

-- Now load the module (after document is set up)
local card_dom = require("lib.platform.apps.card.dom")
local R = require("lib.reactive")
local widget = require("lib.widget")

-- ── Test card data ──────────────────────────────────────────────────────────

--: CardData
local test_card_data = {
	name = "Test Card",
	description = "You are a test character.",
	first_mes = "Hello!",
	personality = "",
	scenario = "",
	mes_example = "",
}

-- Encode as a proper CCv2 chara chunk: base64(json(envelope))
local test_chara_chunk = base64.encode(assert(card_mod.to_json(test_card_data)))

-- ── Mock capabilities ───────────────────────────────────────────────────────

local function make_mock_caps(opts)
	opts = opts or {}
	return {
		llm = {
			call = opts.llm_call or function(messages)
				return "Mock response to: " .. (messages[#messages] and messages[#messages].content or "?")
			end,
		},
		png = {
			text = opts.png_text or function(keyword)
				if keyword == "chara" then return test_chara_chunk end
				return nil
			end,
		},
		kv = {
			get = function() return nil end,
			set = function() end,
		},
	}
end

-- ── Tests ───────────────────────────────────────────────────────────────────

T.describe("card_dom.create_state", function()
	T.it("creates state with all required signals", function()
		local state = card_dom.create_state()
		T.ok(state.messages, "has messages signal")
		T.ok(state.input_text, "has input_text signal")
		T.ok(state.loading, "has loading signal")
		T.ok(state.current_card, "has current_card signal")
		T.ok(state.session_id, "has session_id signal")
	end)

	T.it("initializes with empty/default values", function()
		local state = card_dom.create_state()
		T.eq(#state.messages.get(), 0)
		T.eq(state.input_text.get(), "")
		T.eq(state.loading.get(), false)
		T.eq(state.current_card.get(), nil)
		T.eq(state.session_id.get(), nil)
	end)
end)

T.describe("card_dom.append_message", function()
	T.it("adds a message to the list", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Hello")
		local msgs = state.messages.get()
		T.eq(#msgs, 1)
		T.eq(msgs[1].role, "user")
		T.eq(msgs[1].content, "Hello")
	end)

	T.it("appends multiple messages in order", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Hi")
		card_dom.append_message(state, "assistant", "Hello!")
		card_dom.append_message(state, "user", "How are you?")
		local msgs = state.messages.get()
		T.eq(#msgs, 3)
		T.eq(msgs[1].role, "user")
		T.eq(msgs[2].role, "assistant")
		T.eq(msgs[3].content, "How are you?")
	end)

	T.it("does not mutate the previous array", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "First")
		local first_ref = state.messages.get()
		card_dom.append_message(state, "user", "Second")
		local second_ref = state.messages.get()
		-- The two refs should be different tables (immutable update)
		T.neq(first_ref, second_ref)
		T.eq(#first_ref, 1)
		T.eq(#second_ref, 2)
	end)
end)

T.describe("card_dom.clear_input", function()
	T.it("resets input text to empty string", function()
		local state = card_dom.create_state()
		state.input_text.set("some text")
		T.eq(state.input_text.get(), "some text")
		card_dom.clear_input(state)
		T.eq(state.input_text.get(), "")
	end)
end)

T.describe("card_dom.load_card", function()
	T.it("loads card data from PNG chara chunk", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		local card, err = card_dom.load_card(state, caps)
		T.ok(card, "card loaded: " .. tostring(err))
		T.eq(card.name, "Test Card")
		T.eq(state.current_card.get().name, "Test Card")
	end)

	T.it("returns nil when no png capability", function()
		local state = card_dom.create_state()
		local card, err = card_dom.load_card(state, {})
		T.eq(card, nil)
		T.ok(err, "has error message")
	end)

	T.it("returns nil when no chara chunk", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps({
			png_text = function() return nil end,
		})
		local card, err = card_dom.load_card(state, caps)
		T.eq(card, nil)
		T.eq(err, "no chara chunk")
	end)
end)

T.describe("card_dom.build_context", function()
	T.it("builds context with system prompt from card", function()
		local state = card_dom.create_state()
		state.current_card.set({
			name = "Test", description = "You are a test.", first_mes = "Hi!",
		})
		local ctx = card_dom.build_context(state)
		T.eq(#ctx, 2) -- system + greeting (no messages yet)
		T.eq(ctx[1].role, "system")
		T.eq(ctx[1].content, "You are a test.")
		T.eq(ctx[2].role, "assistant")
		T.eq(ctx[2].content, "Hi!")
	end)

	T.it("includes conversation history", function()
		local state = card_dom.create_state()
		state.current_card.set({
			name = "Test", description = "System prompt.",
		})
		card_dom.append_message(state, "user", "Hello")
		card_dom.append_message(state, "assistant", "Hi there")
		local ctx = card_dom.build_context(state)
		T.eq(#ctx, 3) -- system + 2 messages (no greeting when messages exist)
		T.eq(ctx[1].role, "system")
		T.eq(ctx[2].role, "user")
		T.eq(ctx[2].content, "Hello")
		T.eq(ctx[3].role, "assistant")
		T.eq(ctx[3].content, "Hi there")
	end)

	T.it("works with no card loaded", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Test")
		local ctx = card_dom.build_context(state)
		T.eq(#ctx, 1)
		T.eq(ctx[1].role, "user")
	end)
end)

T.describe("card_dom.send_message", function()
	T.it("sends user message and receives LLM response", function()
		local state = card_dom.create_state()
		state.input_text.set("Hello bot")
		local caps = make_mock_caps()
		local response, err = card_dom.send_message(state, caps)
		T.ok(response, "got response: " .. tostring(err))
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[1].role, "user")
		T.eq(msgs[1].content, "Hello bot")
		T.eq(msgs[2].role, "assistant")
		T.ok(msgs[2].content:find("Mock response"), "response contains mock text")
	end)

	T.it("clears input after sending", function()
		local state = card_dom.create_state()
		state.input_text.set("Hello")
		local caps = make_mock_caps()
		card_dom.send_message(state, caps)
		T.eq(state.input_text.get(), "")
	end)

	T.it("sets loading during LLM call", function()
		local state = card_dom.create_state()
		local loading_during_call = nil
		local caps = make_mock_caps({
			llm_call = function(messages)
				loading_during_call = state.loading.get()
				return "response"
			end,
		})
		state.input_text.set("Test")
		card_dom.send_message(state, caps)
		T.eq(loading_during_call, true)
		T.eq(state.loading.get(), false) -- reset after call
	end)

	T.it("handles LLM error gracefully", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps({
			llm_call = function() return nil, "connection refused" end,
		})
		state.input_text.set("Test")
		local response, err = card_dom.send_message(state, caps)
		T.eq(response, nil)
		T.eq(err, "connection refused")
		local msgs = state.messages.get()
		T.eq(#msgs, 2) -- user message + error message
		T.eq(msgs[2].role, "system")
		T.ok(msgs[2].content:find("connection refused"), "error shown in messages")
	end)

	T.it("rejects empty input", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		local response, err = card_dom.send_message(state, caps)
		T.eq(response, nil)
		T.eq(err, "empty input")
		T.eq(#state.messages.get(), 0)
	end)

	T.it("rejects while already loading", function()
		local state = card_dom.create_state()
		state.loading.set(true)
		state.input_text.set("Test")
		local caps = make_mock_caps()
		local response, err = card_dom.send_message(state, caps)
		T.eq(response, nil)
		T.eq(err, "already loading")
	end)
end)

T.describe("card_dom widgets", function()
	T.it("message_list_widget creates a container", function()
		local state = card_dom.create_state()
		local w = card_dom.message_list_widget(state)
		local node, cleanup = widget.with_scope(w)
		T.eq(node.tagName, "div")
		T.eq(node.attributes["class"], "message-list")
		cleanup()
	end)

	T.it("loading_indicator_widget reflects loading state", function()
		local state = card_dom.create_state()
		local w = card_dom.loading_indicator_widget(state)
		local node, cleanup = widget.with_scope(w)
		T.eq(node.tagName, "div")
		-- Initially not loading
		T.eq(node.attributes["class"], "loading-indicator")
		-- Set loading
		state.loading.set(true)
		T.eq(node.attributes["class"], "loading-indicator loading-visible")
		-- Clear loading
		state.loading.set(false)
		T.eq(node.attributes["class"], "loading-indicator")
		cleanup()
	end)

	T.it("input_row_widget creates textarea and button", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		local w = card_dom.input_row_widget(state, caps)
		local node, cleanup = widget.with_scope(w)
		T.eq(node.tagName, "div")
		T.eq(node.attributes["class"], "input-row")
		-- Should have textarea and button as children
		T.eq(#node.children, 2)
		T.eq(node.children[1].tagName, "textarea")
		T.eq(node.children[2].tagName, "button")
		cleanup()
	end)

	T.it("app_widget creates full layout", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		local w = card_dom.app_widget(state, caps)
		local node, cleanup = widget.with_scope(w)
		T.eq(node.tagName, "div")
		T.eq(node.attributes["class"], "card-app")
		-- Three children: message list, loading indicator, input row
		T.eq(#node.children, 3)
		cleanup()
	end)
end)

T.describe("card_dom.init", function()
	T.it("initializes the app with card greeting", function()
		-- Reset document.body
		document.body = make_node(1, "body")
		local caps = make_mock_caps()
		local result = card_dom.init(caps)
		T.ok(result.state, "has state")
		T.ok(result.cleanup, "has cleanup function")
		-- Card should be loaded
		local card = result.state.current_card.get()
		T.ok(card, "card loaded")
		T.eq(card.name, "Test Card")
		-- Greeting should appear as first message
		local msgs = result.state.messages.get()
		T.eq(#msgs, 1)
		T.eq(msgs[1].role, "assistant")
		T.eq(msgs[1].content, "Hello!")
		-- Cleanup
		result.cleanup()
	end)
end)
