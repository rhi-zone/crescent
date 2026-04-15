-- lib/platform/apps/charactercardv2/dom_test.lua
-- Tests for the CCv2 Card App conversation view.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local base64 = require("lib.base64")
local json = require("lib.format.json")
local card_mod = require("lib.formats.ccv2.card")
local lorebook_mod = require("lib.formats.ccv2.lorebook")
--:: require "lib.formats.ccv2.ccv2_types"

-- ── Mock DOM ────────────────────────────────────────────────────────────────

local function make_node(node_type, tag_or_data)
	local n = {}
	n.nodeType   = node_type
	n.tagName    = (node_type == 1) and tag_or_data or nil
	n.data       = (node_type == 3) and (tag_or_data or "") or nil
	n.children   = {}
	n.attributes = {}
	n.listeners  = {}
	n.style      = { display = "" }
	n.parentNode = nil
	n.firstChild = nil
	n.value      = ""
	n.textContent = ""

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
function mock_document.createElement(tag) return make_node(1, tag) end
function mock_document.createTextNode(data) return make_node(3, data or "") end
mock_document.body = make_node(1, "body")

document = mock_document --: any

local card_dom = require("lib.platform.apps.charactercardv2.dom")
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

local test_chara_chunk = base64.encode(assert(card_mod.to_json(test_card_data)))

-- Card with alternate greetings
--: CardData
local test_card_greetings = {
	name = "Greeter",
	description = "A character with multiple greetings.",
	first_mes = "Greeting one.",
	alternate_greetings = { "Greeting two.", "Greeting three." },
	personality = "",
	scenario = "",
	mes_example = "",
}

local test_greetings_chunk = base64.encode(assert(card_mod.to_json(test_card_greetings)))

-- Card with macros
--: CardData
local test_card_macros = {
	name = "MacroBot",
	description = "You are {{char}}, talking to {{user}}.",
	first_mes = "Hello, {{user}}! I am {{char}}.",
	personality = "",
	scenario = "",
	mes_example = "",
}

local test_macros_chunk = base64.encode(assert(card_mod.to_json(test_card_macros)))

-- Card with lorebook
local test_card_lorebook_json = json.encode({
	spec = "chara_card_v2", spec_version = "2.0",
	data = {
		name = "LoreBot",
		description = "A character with lorebook.",
		first_mes = "Welcome.",
		personality = "", scenario = "", mes_example = "",
		character_book = {
			entries = {
				{ keys = { "sword" }, content = "A sharp blade.", enabled = true,
				  insertion_order = 100, case_sensitive = false },
			},
		},
	},
})
local test_lorebook_chunk = base64.encode(test_card_lorebook_json)

-- ── Mock capabilities ───────────────────────────────────────────────────────

local function make_mock_caps(opts)
	opts = opts or {}
	local kv_store = {}
	return {
		llm = {
			call = opts.llm_call or function(messages)
				return "Mock response to: " .. (messages[#messages] and messages[#messages].content or "?")
			end,
			count_tokens = opts.count_tokens or function(text) return #text end,
		},
		png = {
			text = opts.png_text or function(keyword)
				if keyword == "chara" then return test_chara_chunk end
				return nil
			end,
		},
		kv = opts.kv or {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		},
		config = opts.config or {
			get = function(key)
				if key == "max_context" then return 4096 end
				if key == "max_response" then return 512 end
				return nil
			end,
		},
	}
end

-- ── Tests ───────────────────────────────────────────────────────────────────

T.describe("card_dom.create_state", function()
	T.it("creates state with all required signals", function()
		local state = card_dom.create_state()
		T.ok(state.messages)
		T.ok(state.input_text)
		T.ok(state.loading)
		T.ok(state.current_card)
		T.ok(state.lorebook)
		T.ok(state.greeting_index)
		T.ok(state.session_id)
		T.ok(state.user_name)
	end)

	T.it("initializes with defaults", function()
		local state = card_dom.create_state()
		T.eq(#state.messages.get(), 0)
		T.eq(state.input_text.get(), "")
		T.eq(state.loading.get(), false)
		T.eq(state.current_card.get(), nil)
		T.eq(state.lorebook.get(), nil)
		T.eq(state.greeting_index.get(), 0)
		T.eq(state.user_name.get(), "User")
	end)
end)

T.describe("card_dom message operations", function()
	T.it("appends messages", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Hello")
		card_dom.append_message(state, "assistant", "Hi!")
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[1].role, "user")
		T.eq(msgs[2].content, "Hi!")
	end)

	T.it("does not mutate previous array", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "First")
		local ref1 = state.messages.get()
		card_dom.append_message(state, "user", "Second")
		local ref2 = state.messages.get()
		T.neq(ref1, ref2)
		T.eq(#ref1, 1)
		T.eq(#ref2, 2)
	end)

	T.it("replaces last message of matching role", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Q")
		card_dom.append_message(state, "assistant", "Old answer")
		card_dom.replace_last_message(state, "assistant", "New answer")
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[2].content, "New answer")
	end)

	T.it("pops last message of matching role", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Q")
		card_dom.append_message(state, "assistant", "A")
		local removed = card_dom.pop_last_message(state, "assistant")
		T.ok(removed)
		T.eq(removed.content, "A")
		T.eq(#state.messages.get(), 1)
	end)

	T.it("pop returns nil when role doesn't match", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Q")
		local removed = card_dom.pop_last_message(state, "assistant")
		T.eq(removed, nil)
		T.eq(#state.messages.get(), 1)
	end)
end)

T.describe("card_dom.load_card", function()
	T.it("loads card and extracts name", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		local card, err = card_dom.load_card(state, caps)
		T.ok(card, "card loaded: " .. tostring(err))
		T.eq(card.name, "Test Card")
		T.eq(state.current_card.get().name, "Test Card")
	end)

	T.it("extracts lorebook from card", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps({
			png_text = function(keyword)
				if keyword == "chara" then return test_lorebook_chunk end
				return nil
			end,
		})
		local card = assert(card_dom.load_card(state, caps))
		T.eq(card.name, "LoreBot")
		local entries = state.lorebook.get()
		T.ok(entries)
		T.eq(#entries, 1)
		T.eq(entries[1].content, "A sharp blade.")
	end)

	T.it("returns nil when no png capability", function()
		local state = card_dom.create_state()
		local _, err = card_dom.load_card(state, {})
		T.eq(err, "no png capability")
	end)

	T.it("returns nil when no chara chunk", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps({ png_text = function() return nil end })
		local _, err = card_dom.load_card(state, caps)
		T.eq(err, "no chara chunk")
	end)
end)

T.describe("card_dom greeting management", function()
	T.it("returns first_mes as only greeting by default", function()
		local state = card_dom.create_state()
		state.current_card.set(test_card_data)
		local greetings = card_dom.get_greetings(state)
		T.eq(#greetings, 1)
		T.eq(greetings[1], "Hello!")
	end)

	T.it("returns all greetings including alternates", function()
		local state = card_dom.create_state()
		state.current_card.set(test_card_greetings)
		local greetings = card_dom.get_greetings(state)
		T.eq(#greetings, 3)
		T.eq(greetings[1], "Greeting one.")
		T.eq(greetings[2], "Greeting two.")
		T.eq(greetings[3], "Greeting three.")
	end)

	T.it("expands macros in current greeting", function()
		local state = card_dom.create_state()
		state.current_card.set(test_card_macros)
		local greeting = card_dom.get_current_greeting(state)
		T.eq(greeting, "Hello, User! I am MacroBot.")
	end)

	T.it("cycles through greetings", function()
		local state = card_dom.create_state()
		state.current_card.set(test_card_greetings)
		card_dom.append_message(state, "assistant", "Greeting one.")
		-- Cycle forward
		card_dom.cycle_greeting(state, 1)
		T.eq(state.greeting_index.get(), 1)
		local msgs = state.messages.get()
		T.eq(msgs[#msgs].content, "Greeting two.")
		-- Cycle forward again
		card_dom.cycle_greeting(state, 1)
		T.eq(state.greeting_index.get(), 2)
		-- Cycle wraps around
		card_dom.cycle_greeting(state, 1)
		T.eq(state.greeting_index.get(), 0)
	end)

	T.it("does not cycle when only one greeting", function()
		local state = card_dom.create_state()
		state.current_card.set(test_card_data)
		card_dom.cycle_greeting(state, 1)
		T.eq(state.greeting_index.get(), 0)
	end)
end)

T.describe("card_dom.build_context", function()
	T.it("uses context assembly engine with card fields", function()
		local state = card_dom.create_state()
		state.current_card.set({
			name = "Bot", description = "A helpful bot.",
			personality = "", scenario = "", first_mes = "Hi!",
			mes_example = "", system_prompt = "", post_history_instructions = "",
			creator_notes = "", creator = "", character_version = "",
			alternate_greetings = {}, tags = {}, extensions = {},
		})
		local caps = make_mock_caps()
		card_dom.append_message(state, "user", "Hello")
		local ctx = card_dom.build_context(state, caps)
		-- Should have description as system message + history
		T.ok(#ctx >= 2, "at least description + user message")
		-- Find the description block
		local found_desc = false
		for _, msg in ipairs(ctx) do
			if msg.content == "A helpful bot." then found_desc = true end
		end
		T.ok(found_desc, "description included in context")
		-- Last message should be the user's
		T.eq(ctx[#ctx].role, "user")
		T.eq(ctx[#ctx].content, "Hello")
	end)

	T.it("expands macros in card fields", function()
		local state = card_dom.create_state()
		state.current_card.set({
			name = "MacroBot", description = "I am {{char}}.",
			personality = "", scenario = "", first_mes = "",
			mes_example = "", system_prompt = "", post_history_instructions = "",
			creator_notes = "", creator = "", character_version = "",
			alternate_greetings = {}, tags = {}, extensions = {},
		})
		local caps = make_mock_caps()
		local ctx = card_dom.build_context(state, caps)
		local found = false
		for _, msg in ipairs(ctx) do
			if msg.content == "I am MacroBot." then found = true end
		end
		T.ok(found, "macro expanded in description")
	end)

	T.it("falls back to raw history when no card", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Test")
		local ctx = card_dom.build_context(state)
		T.eq(#ctx, 1)
		T.eq(ctx[1].content, "Test")
	end)
end)

T.describe("card_dom.send_message", function()
	T.it("sends user message and receives response", function()
		local state = card_dom.create_state()
		state.input_text.set("Hello bot")
		local caps = make_mock_caps()
		local response = assert(card_dom.send_message(state, caps))
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[1].role, "user")
		T.eq(msgs[1].content, "Hello bot")
		T.eq(msgs[2].role, "assistant")
		T.ok(response:find("Mock response"))
	end)

	T.it("clears input after sending", function()
		local state = card_dom.create_state()
		state.input_text.set("Hello")
		card_dom.send_message(state, make_mock_caps())
		T.eq(state.input_text.get(), "")
	end)

	T.it("sets loading during LLM call", function()
		local state = card_dom.create_state()
		local loading_during
		local caps = make_mock_caps({
			llm_call = function()
				loading_during = state.loading.get()
				return "ok"
			end,
		})
		state.input_text.set("Test")
		card_dom.send_message(state, caps)
		T.eq(loading_during, true)
		T.eq(state.loading.get(), false)
	end)

	T.it("handles LLM error", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps({
			llm_call = function() return nil, "connection refused" end,
		})
		state.input_text.set("Test")
		local _, err = card_dom.send_message(state, caps)
		T.eq(err, "connection refused")
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[2].role, "system")
		T.ok(msgs[2].content:find("connection refused"))
	end)

	T.it("rejects empty input", function()
		local state = card_dom.create_state()
		local _, err = card_dom.send_message(state, make_mock_caps())
		T.eq(err, "empty input")
	end)

	T.it("rejects while loading", function()
		local state = card_dom.create_state()
		state.loading.set(true)
		state.input_text.set("Test")
		local _, err = card_dom.send_message(state, make_mock_caps())
		T.eq(err, "already loading")
	end)
end)

T.describe("card_dom.regenerate", function()
	T.it("replaces last assistant message with new response", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Q")
		card_dom.append_message(state, "assistant", "Old A")
		local caps = make_mock_caps({
			llm_call = function() return "New A" end,
		})
		local response = assert(card_dom.regenerate(state, caps))
		T.eq(response, "New A")
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[2].content, "New A")
	end)

	T.it("restores old message on LLM error", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Q")
		card_dom.append_message(state, "assistant", "Keep me")
		local caps = make_mock_caps({
			llm_call = function() return nil, "timeout" end,
		})
		local _, err = card_dom.regenerate(state, caps)
		T.eq(err, "timeout")
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[2].content, "Keep me")
	end)

	T.it("returns error when no assistant message exists", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Q")
		local _, err = card_dom.regenerate(state, make_mock_caps())
		T.eq(err, "no assistant message to regenerate")
	end)
end)

T.describe("card_dom.continue_message", function()
	T.it("appends continuation to last assistant message", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "assistant", "Start ")
		local caps = make_mock_caps({
			llm_call = function() return "continued text" end,
		})
		local response = assert(card_dom.continue_message(state, caps))
		T.eq(response, "continued text")
		local msgs = state.messages.get()
		T.eq(#msgs, 1)
		T.eq(msgs[1].content, "Start continued text")
	end)

	T.it("adds new assistant message when last is not assistant", function()
		local state = card_dom.create_state()
		card_dom.append_message(state, "user", "Q")
		local caps = make_mock_caps({
			llm_call = function() return "response" end,
		})
		card_dom.continue_message(state, caps)
		local msgs = state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[2].role, "assistant")
	end)
end)

T.describe("card_dom persistence", function()
	T.it("saves and loads messages via kv", function()
		local state = card_dom.create_state()
		local kv_store = {}
		local caps = make_mock_caps({
			kv = {
				get = function(key) return kv_store[key] end,
				set = function(key, val) kv_store[key] = val end,
			},
		})
		card_dom.append_message(state, "user", "Hello")
		card_dom.append_message(state, "assistant", "Hi!")
		card_dom.save_messages(state, caps)
		T.ok(kv_store["messages"])

		-- Load into fresh state
		local state2 = card_dom.create_state()
		local loaded = card_dom.load_messages(state2, caps)
		T.ok(loaded)
		local msgs = state2.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[1].content, "Hello")
		T.eq(msgs[2].content, "Hi!")
	end)

	T.it("returns false when no saved messages", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		T.eq(card_dom.load_messages(state, caps), false)
	end)
end)

T.describe("card_dom widgets", function()
	T.it("message_list_widget creates container", function()
		local state = card_dom.create_state()
		local node, cleanup = widget.with_scope(card_dom.message_list_widget(state))
		T.eq(node.tagName, "div")
		T.eq(node.attributes["class"], "message-list")
		cleanup()
	end)

	T.it("loading_indicator reflects state", function()
		local state = card_dom.create_state()
		local node, cleanup = widget.with_scope(card_dom.loading_indicator_widget(state))
		T.eq(node.attributes["class"], "loading-indicator")
		state.loading.set(true)
		T.eq(node.attributes["class"], "loading-indicator loading-visible")
		state.loading.set(false)
		T.eq(node.attributes["class"], "loading-indicator")
		cleanup()
	end)

	T.it("input_row has textarea + 3 buttons", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		local node, cleanup = widget.with_scope(card_dom.input_row_widget(state, caps))
		T.eq(node.attributes["class"], "input-row")
		T.eq(#node.children, 4) -- textarea, send, regen, continue
		T.eq(node.children[1].tagName, "textarea")
		T.eq(node.children[2].tagName, "button")
		T.eq(node.children[3].tagName, "button")
		T.eq(node.children[4].tagName, "button")
		cleanup()
	end)

	T.it("app_widget creates full layout with greeting bar", function()
		local state = card_dom.create_state()
		local caps = make_mock_caps()
		local node, cleanup = widget.with_scope(card_dom.app_widget(state, caps))
		T.eq(node.attributes["class"], "card-app")
		T.eq(#node.children, 4) -- greeting bar, message list, loading, input row
		cleanup()
	end)
end)

T.describe("card_dom.init", function()
	T.it("loads card and shows macro-expanded greeting", function()
		document.body = make_node(1, "body")
		local caps = make_mock_caps({
			png_text = function(keyword)
				if keyword == "chara" then return test_macros_chunk end
				return nil
			end,
		})
		local result = card_dom.init(caps)
		T.ok(result.state)
		T.ok(result.cleanup)
		local card = result.state.current_card.get()
		T.ok(card)
		T.eq(card.name, "MacroBot")
		local msgs = result.state.messages.get()
		T.eq(#msgs, 1)
		T.eq(msgs[1].role, "assistant")
		T.eq(msgs[1].content, "Hello, User! I am MacroBot.")
		result.cleanup()
	end)

	T.it("restores saved messages instead of showing greeting", function()
		document.body = make_node(1, "body")
		local kv_store = {}
		-- Pre-populate kv with saved messages
		kv_store["messages"] = json.encode({
			{ role = "user", content = "Saved Q" },
			{ role = "assistant", content = "Saved A" },
		})
		local caps = make_mock_caps({
			kv = {
				get = function(key) return kv_store[key] end,
				set = function(key, val) kv_store[key] = val end,
			},
		})
		local result = card_dom.init(caps)
		local msgs = result.state.messages.get()
		T.eq(#msgs, 2)
		T.eq(msgs[1].content, "Saved Q")
		T.eq(msgs[2].content, "Saved A")
		result.cleanup()
	end)
end)
