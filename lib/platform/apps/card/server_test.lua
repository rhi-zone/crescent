if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local json = require("lib.format.json")

-- ── Mock caps ───────────────────────────────────────────────────────────────

local function make_mock_caps(opts)
	opts = opts or {}
	local kv_store = {}
	return {
		llm = {
			call = opts.llm_call or function(_messages)
				return "mock response"
			end,
			count_tokens = function(text) return math.ceil(#text / 4) end,
		},
		png = {
			text = function(keyword)
				if keyword == "chara" then
					return opts.chara_json or json.encode({
						spec = "chara_card_v2",
						data = {
							name = "TestChar",
							description = "A test character.",
							personality = "Friendly.",
							scenario = "",
							first_mes = "Hello, {{user}}!",
							mes_example = "",
							creator_notes = "",
							system_prompt = "You are {{char}}.",
							post_history_instructions = "",
							alternate_greetings = { "Hi there!", "Greetings!" },
							tags = {},
							creator = "",
							character_version = "",
							extensions = {},
						},
					})
				end
				return nil
			end,
		},
		kv = {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		},
		config = {
			get = function(key)
				if key == "user_name" then return opts.user_name or "Tester" end
				if key == "max_context" then return 4096 end
				if key == "max_response" then return 512 end
				return nil
			end,
		},
	}
end

-- ── Request/response helpers ────────────────────────────────────────────────

local function make_req(method, target, body)
	local req = { method = method, target = target, headers = {} }
	if body then
		req.body = json.encode(body)
		req.headers["content-type"] = { "application/json" }
	end
	return req
end

local function make_res()
	return { headers = {} }
end

local function call(app, method, target, body)
	local req = make_req(method, target, body)
	local res = make_res()
	app.handler(req, res)
	local data
	if res.body then
		local ok, val = pcall(json.decode, res.body)
		if ok then data = val end
	end
	return res.status, data
end

-- ── Tests ───────────────────────────────────────────────────────────────────

local server = require("lib.platform.apps.card.server")

T.describe("server — init", function()
	T.it("loads card and creates greeting", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		T.ok(app.state.card, "card loaded")
		T.eq(app.state.card.name, "TestChar")
		T.eq(#app.state.messages, 1)
		T.eq(app.state.messages[1].role, "assistant")
		T.eq(app.state.messages[1].content, "Hello, Tester!")
	end)

	T.it("populates greeting swipes from alternate_greetings", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local msg_id = app.state.messages[1].id
		local entry = app.state.swipes[msg_id]
		T.ok(entry, "swipes entry exists")
		T.eq(#entry.items, 3) -- first_mes + 2 alternates
		T.eq(entry.items[1].content, "Hello, Tester!")
		T.eq(entry.items[2].content, "Hi there!")
		T.eq(entry.items[3].content, "Greetings!")
		T.eq(entry.current, 1)
	end)

	T.it("reads user_name from config", function()
		local caps = make_mock_caps({ user_name = "Alice" })
		local app = server.create(caps, { no_static = true })
		T.eq(app.state.user_name, "Alice")
		T.eq(app.state.messages[1].content, "Hello, Alice!")
	end)
end)

T.describe("GET /api/card", function()
	T.it("returns card name and greeting", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/card")
		T.eq(status, 200)
		T.eq(data.name, "TestChar")
		T.ok(data.greeting, "has greeting")
		T.eq(data.greeting.role, "assistant")
		T.eq(data.greeting.content, "Hello, Tester!")
		T.eq(data.greeting.swipe_total, 3)
		T.eq(data.greeting.swipe_index, 0)
	end)
end)

T.describe("GET /api/messages", function()
	T.it("returns message history with swipe info", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/messages")
		T.eq(status, 200)
		T.eq(#data.messages, 1)
		T.eq(data.messages[1].role, "assistant")
		T.eq(data.messages[1].swipe_total, 3)
	end)
end)

T.describe("POST /api/message", function()
	T.it("sends user message and returns assistant response", function()
		local caps = make_mock_caps({ llm_call = function() return "LLM says hi" end })
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/message", { content = "Hello" })
		T.eq(status, 200)
		T.ok(data.user, "has user msg")
		T.eq(data.user.role, "user")
		T.eq(data.user.content, "Hello")
		T.ok(data.assistant, "has assistant msg")
		T.eq(data.assistant.role, "assistant")
		T.eq(data.assistant.content, "LLM says hi")
		T.eq(data.assistant.swipe_total, 1)
		-- State updated
		T.eq(#app.state.messages, 3) -- greeting + user + assistant
	end)

	T.it("rejects empty content", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/message", { content = "" })
		T.eq(status, 400)
		T.ok(data.error, "has error")
	end)

	T.it("rolls back user message on LLM failure", function()
		local caps = make_mock_caps({ llm_call = function() return nil, "timeout" end })
		local app = server.create(caps, { no_static = true })
		local initial_count = #app.state.messages
		local status, data = call(app, "POST", "/api/message", { content = "Hello" })
		T.eq(status, 502)
		T.ok(data.error:find("timeout"), "error mentions timeout")
		T.eq(#app.state.messages, initial_count, "message rolled back")
	end)
end)

T.describe("POST /api/continue", function()
	T.it("appends to last assistant message", function()
		local call_count = 0
		local caps = make_mock_caps({
			llm_call = function()
				call_count = call_count + 1
				if call_count == 1 then return "First part" end
				return " continued"
			end,
		})
		local app = server.create(caps, { no_static = true })
		-- Send initial message to get an assistant response
		call(app, "POST", "/api/message", { content = "Go" })
		local asst_msg = app.state.messages[#app.state.messages]
		T.eq(asst_msg.content, "First part")

		-- Continue
		local status, data = call(app, "POST", "/api/continue")
		T.eq(status, 200)
		T.eq(data.content, "First part continued")
		T.eq(app.state.messages[#app.state.messages].content, "First part continued")
	end)

	T.it("adds new assistant message when last is user", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		-- Manually add a user message as last
		app.state.messages[#app.state.messages + 1] = { id = "u1", role = "user", content = "test" }
		local status, data = call(app, "POST", "/api/continue")
		T.eq(status, 200)
		T.eq(data.role, "assistant")
		T.eq(app.state.messages[#app.state.messages].role, "assistant")
	end)
end)

T.describe("GET /api/swipes", function()
	T.it("returns all swipes for greeting message", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local msg_id = app.state.messages[1].id
		local status, data = call(app, "GET", "/api/swipes?message_id=" .. msg_id)
		T.eq(status, 200)
		T.eq(#data.swipes, 3)
		T.eq(data.swipes[1].content, "Hello, Tester!")
		T.eq(data.swipes[2].content, "Hi there!")
		T.eq(data.swipes[3].content, "Greetings!")
		T.eq(data.current, 0) -- 0-based
	end)

	T.it("creates swipe entry on first access for non-greeting", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		-- Add a plain assistant message with no swipes
		local msg = { id = "a1", role = "assistant", content = "test" }
		app.state.messages[#app.state.messages + 1] = msg
		local status, data = call(app, "GET", "/api/swipes?message_id=a1")
		T.eq(status, 200)
		T.eq(#data.swipes, 1)
		T.eq(data.swipes[1].content, "test")
	end)

	T.it("returns 400 without message_id", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/swipes")
		T.eq(status, 400)
		T.ok(data.error, "has error")
	end)

	T.it("returns 404 for unknown message_id", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "GET", "/api/swipes?message_id=nonexistent")
		T.eq(status, 404)
	end)
end)

T.describe("POST /api/swipe/new", function()
	T.it("generates new swipe for assistant message", function()
		local call_count = 0
		local caps = make_mock_caps({
			llm_call = function()
				call_count = call_count + 1
				return "response " .. call_count
			end,
		})
		local app = server.create(caps, { no_static = true })
		-- Send a message to get an assistant reply
		call(app, "POST", "/api/message", { content = "Hello" })
		local asst_msg = app.state.messages[#app.state.messages]
		T.eq(asst_msg.content, "response 1")

		-- Generate new swipe
		local status, data = call(app, "POST", "/api/swipe/new", { message_id = asst_msg.id })
		T.eq(status, 200)
		T.eq(data.content, "response 2")
		T.eq(data.swipe_total, 2)
		T.eq(data.swipe_index, 1) -- 0-based, second item

		-- Active message updated
		T.eq(app.state.messages[#app.state.messages].content, "response 2")
	end)

	T.it("generates new swipe for greeting", function()
		local caps = make_mock_caps({ llm_call = function() return "new greeting" end })
		local app = server.create(caps, { no_static = true })
		local msg_id = app.state.messages[1].id
		local status, data = call(app, "POST", "/api/swipe/new", { message_id = msg_id })
		T.eq(status, 200)
		T.eq(data.content, "new greeting")
		T.eq(data.swipe_total, 4) -- 3 original + 1 new
	end)

	T.it("returns 404 for unknown message", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/swipe/new", { message_id = "nope" })
		T.eq(status, 404)
	end)
end)

T.describe("persistence", function()
	T.it("saves and restores state via kv", function()
		local kv_store = {}
		local shared_kv = {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		}

		-- Create app, send a message, state gets saved
		local caps1 = make_mock_caps({ llm_call = function() return "saved reply" end })
		caps1.kv = shared_kv
		local app1 = server.create(caps1, { no_static = true })
		call(app1, "POST", "/api/message", { content = "test" })
		T.ok(kv_store["card_state"], "state was saved")

		-- Create new app with same kv — should restore
		local caps2 = make_mock_caps()
		caps2.kv = shared_kv
		local app2 = server.create(caps2, { no_static = true })
		T.eq(#app2.state.messages, 3) -- greeting + user + assistant
		T.eq(app2.state.messages[3].content, "saved reply")
	end)
end)

T.describe("routing", function()
	T.it("returns nil for unknown API paths", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local res = make_res()
		local result = app.handler(make_req("GET", "/api/nonexistent"), res)
		T.eq(result, nil)
	end)

	T.it("returns nil for wrong method", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local res = make_res()
		local result = app.handler(make_req("POST", "/api/card"), res)
		T.eq(result, nil)
	end)
end)

T.describe("swipe updates active message", function()
	T.it("swipe/new on greeting changes message[1] content and id", function()
		local caps = make_mock_caps({ llm_call = function() return "generated" end })
		local app = server.create(caps, { no_static = true })
		local original_id = app.state.messages[1].id
		call(app, "POST", "/api/swipe/new", { message_id = original_id })
		-- The active message should now be the new swipe
		T.neq(app.state.messages[1].id, original_id)
		T.eq(app.state.messages[1].content, "generated")
	end)
end)

T.describe("context assembly", function()
	T.it("includes system prompt from card", function()
		local captured_context
		local caps = make_mock_caps({
			llm_call = function(messages)
				captured_context = messages
				return "ok"
			end,
		})
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "test" })
		T.ok(captured_context, "context was passed to LLM")
		-- First message should be system prompt
		local found_system = false
		for _, msg in ipairs(captured_context) do
			if msg.role == "system" and msg.content:find("TestChar") then
				found_system = true
				break
			end
		end
		T.ok(found_system, "system prompt includes card name")
	end)
end)
