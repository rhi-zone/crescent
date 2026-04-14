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

local function make_mock_sock()
	local sent = {}
	local closed = false
	return {
		send = function(_, data) sent[#sent + 1] = data end,
		close = function() closed = true end,
		sent = sent,
		is_closed = function() return closed end,
	}
end

local function parse_sse_events(sent_parts)
	local raw = table.concat(sent_parts)
	local events = {}
	for line in raw:gmatch("[^\r\n]+") do
		if line:sub(1, 6) == "data: " then
			local ok, val = pcall(json.decode, line:sub(7))
			if ok then events[#events + 1] = val end
		end
	end
	return events
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

local function call_with_sock(app, method, target, body)
	local req = make_req(method, target, body)
	local res = make_res()
	local sock = make_mock_sock()
	app.handler(req, res, sock)
	return res, sock
end

-- ── Tests ───────────────────────────────────────────────────────────────────

local server = require("lib.platform.apps.card.server")

T.describe("server — init", function()
	T.it("loads card and creates greeting in conversation tree", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		T.ok(app.state.card, "card loaded")
		T.eq(app.state.card.name, "TestChar")
		T.ok(app.state.conv, "conversation db exists")
		T.ok(app.state.session_id, "session_id exists")
		-- Canonical path should have the greeting.
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path, 1)
		T.eq(path[1].role, "assistant")
		T.eq(path[1].content, "Hello, Tester!")
	end)

	T.it("creates alternate greetings as root siblings", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local roots = app.state.conv:get_roots(app.state.session_id)
		T.ok(roots, "roots retrieved")
		T.eq(#roots, 3) -- first_mes + 2 alternates
		T.eq(roots[1].content, "Hello, Tester!")
		T.eq(roots[2].content, "Hi there!")
		T.eq(roots[3].content, "Greetings!")
	end)

	T.it("reads user_name from config", function()
		local caps = make_mock_caps({ user_name = "Alice" })
		local app = server.create(caps, { no_static = true })
		T.eq(app.state.user_name, "Alice")
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(path[1].content, "Hello, Alice!")
	end)
end)

T.describe("GET /api/card", function()
	T.it("returns card name and greeting with sibling info", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/card")
		T.eq(status, 200)
		T.eq(data.name, "TestChar")
		T.ok(data.greeting, "has greeting")
		T.eq(data.greeting.role, "assistant")
		T.eq(data.greeting.content, "Hello, Tester!")
		T.eq(data.greeting.sibling_count, 3)
		T.eq(data.greeting.sibling_index, 0)
	end)
end)

T.describe("GET /api/messages", function()
	T.it("returns canonical path with sibling info", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/messages")
		T.eq(status, 200)
		T.eq(#data.messages, 1)
		T.eq(data.messages[1].role, "assistant")
		T.eq(data.messages[1].sibling_count, 3)
		T.eq(data.messages[1].sibling_index, 0)
		T.ok(data.messages[1].id, "message has id")
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
		T.eq(data.assistant.sibling_count, 1)
		-- Canonical path: greeting + user + assistant = 3
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path, 3)
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
		local path_before = app.state.conv:get_canonical_path(app.state.session_id)
		local initial_count = #path_before
		local status, data = call(app, "POST", "/api/message", { content = "Hello" })
		T.eq(status, 502)
		T.ok(data.error:find("timeout"), "error mentions timeout")
		local path_after = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path_after, initial_count, "message rolled back")
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
		-- Send initial message to get an assistant response.
		call(app, "POST", "/api/message", { content = "Go" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(path[#path].content, "First part")

		-- Continue.
		local status, data = call(app, "POST", "/api/continue")
		T.eq(status, 200)
		T.eq(data.content, "First part continued")
		local path2 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(path2[#path2].content, "First part continued")
	end)

	T.it("adds new assistant message when last is user", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		-- Add a user message as the leaf.
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local leaf_id = path[#path].id
		app.state.conv:add_message(app.state.session_id, leaf_id, "user", "test")
		local status, data = call(app, "POST", "/api/continue")
		T.eq(status, 200)
		T.eq(data.role, "assistant")
		local path2 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(path2[#path2].role, "assistant")
	end)
end)

T.describe("GET /api/swipes", function()
	T.it("returns all siblings for greeting message", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local msg_id = path[1].id
		local status, data = call(app, "GET", "/api/swipes?message_id=" .. msg_id)
		T.eq(status, 200)
		T.eq(#data.swipes, 3)
		T.eq(data.swipes[1].content, "Hello, Tester!")
		T.eq(data.swipes[2].content, "Hi there!")
		T.eq(data.swipes[3].content, "Greetings!")
		T.eq(data.current, 0) -- 0-based
	end)

	T.it("returns single-entry for message without siblings", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "Hello" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		-- The user message is the only child of greeting.
		local user_msg = path[2]
		local status, data = call(app, "GET", "/api/swipes?message_id=" .. user_msg.id)
		T.eq(status, 200)
		T.eq(#data.swipes, 1)
		T.eq(data.swipes[1].content, "Hello")
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
	T.it("generates new sibling for assistant message", function()
		local call_count = 0
		local caps = make_mock_caps({
			llm_call = function()
				call_count = call_count + 1
				return "response " .. call_count
			end,
		})
		local app = server.create(caps, { no_static = true })
		-- Send a message to get an assistant reply.
		call(app, "POST", "/api/message", { content = "Hello" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local asst_msg = path[#path]
		T.eq(asst_msg.content, "response 1")

		-- Generate new sibling.
		local status, data = call(app, "POST", "/api/swipe/new", { message_id = asst_msg.id })
		T.eq(status, 200)
		T.eq(data.content, "response 2")
		T.eq(data.sibling_count, 2)
		T.eq(data.sibling_index, 1) -- 0-based, second item

		-- Canonical path should now end at the new sibling.
		local path2 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(path2[#path2].content, "response 2")
	end)

	T.it("generates new sibling for greeting (root)", function()
		local caps = make_mock_caps({ llm_call = function() return "new greeting" end })
		local app = server.create(caps, { no_static = true })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local msg_id = path[1].id
		local status, data = call(app, "POST", "/api/swipe/new", { message_id = msg_id })
		T.eq(status, 200)
		T.eq(data.content, "new greeting")
		T.eq(data.sibling_count, 4) -- 3 original + 1 new
	end)

	T.it("returns 404 for unknown message", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/swipe/new", { message_id = "nope" })
		T.eq(status, 404)
	end)
end)

T.describe("POST /api/message/edit", function()
	T.it("creates a new sibling (fork) instead of editing in place", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		-- Send a user message.
		call(app, "POST", "/api/message", { content = "Hello" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local user_msg = path[2]
		T.eq(user_msg.role, "user")
		T.eq(user_msg.content, "Hello")

		local status, data = call(app, "POST", "/api/message/edit", {
			message_id = user_msg.id, content = "Hello edited",
		})
		T.eq(status, 200)
		T.eq(data.content, "Hello edited")
		T.ok(data.reload_below, "signals frontend to reload")
		-- The edited message is a new sibling, different id.
		T.neq(data.id, user_msg.id)
		-- Old message still exists.
		local old = app.state.conv:get_message(user_msg.id)
		T.ok(old, "old message preserved")
		T.eq(old.content, "Hello")
	end)

	T.it("fork has correct sibling count", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "Hello" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local user_msg = path[2]
		local status, data = call(app, "POST", "/api/message/edit", {
			message_id = user_msg.id, content = "edited",
		})
		T.eq(status, 200)
		T.eq(data.sibling_count, 2) -- original + edited
	end)

	T.it("returns 404 for unknown message", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/message/edit", {
			message_id = "nonexistent", content = "x",
		})
		T.eq(status, 404)
		T.ok(data.error, "has error")
	end)

	T.it("returns 400 for missing fields", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/message/edit", {})
		T.eq(status, 400)
		T.ok(data.error, "has error")

		status, data = call(app, "POST", "/api/message/edit", { message_id = "m1" })
		T.eq(status, 400)
		T.ok(data.error, "has error")
	end)
end)

T.describe("POST /api/message/delete", function()
	T.it("removes message and its subtree", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		-- greeting(1) + user(2) + assistant(3)
		call(app, "POST", "/api/message", { content = "Hello" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path, 3)

		-- Delete from user message onward (user + assistant = subtree of 2).
		local user_id = path[2].id
		local status, data = call(app, "POST", "/api/message/delete", { message_id = user_id })
		T.eq(status, 200)
		T.eq(data.deleted, 2) -- user + assistant
		local path2 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path2, 1) -- only greeting remains
	end)

	T.it("returns 404 for unknown message", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/message/delete", { message_id = "nope" })
		T.eq(status, 404)
		T.ok(data.error, "has error")
	end)

	T.it("returns 400 for missing message_id", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/message/delete", {})
		T.eq(status, 400)
		T.ok(data.error, "has error")
	end)

	T.it("returns correct deleted count for single message", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "Hello" })
		-- Delete only the last message (assistant leaf).
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local asst_id = path[3].id
		local status, data = call(app, "POST", "/api/message/delete", { message_id = asst_id })
		T.eq(status, 200)
		T.eq(data.deleted, 1)
		local path2 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path2, 2) -- greeting + user
	end)
end)

T.describe("POST /api/branch/navigate", function()
	T.it("switches canonical path to a different sibling", function()
		local call_count = 0
		local caps = make_mock_caps({
			llm_call = function()
				call_count = call_count + 1
				return "response " .. call_count
			end,
		})
		local app = server.create(caps, { no_static = true })
		-- Send a message to get an assistant reply.
		call(app, "POST", "/api/message", { content = "Hello" })
		local path1 = app.state.conv:get_canonical_path(app.state.session_id)
		local first_asst = path1[#path1]
		T.eq(first_asst.content, "response 1")

		-- Generate a new sibling.
		call(app, "POST", "/api/swipe/new", { message_id = first_asst.id })
		local path2 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(path2[#path2].content, "response 2")

		-- Navigate back to first sibling.
		local status, data = call(app, "POST", "/api/branch/navigate", { message_id = first_asst.id })
		T.eq(status, 200)
		T.eq(data.content, "response 1")
		T.ok(data.reload_below, "signals reload")

		-- Canonical path should now end at first_asst.
		local path3 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(path3[#path3].id, first_asst.id)
	end)

	T.it("returns 404 for unknown message", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/branch/navigate", { message_id = "nope" })
		T.eq(status, 404)
	end)

	T.it("returns 400 for missing message_id", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/branch/navigate", {})
		T.eq(status, 400)
		T.ok(data.error, "has error")
	end)
end)

T.describe("persistence", function()
	T.it("restores session from kv on restart", function()
		local kv_store = {}
		local shared_kv = {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		}

		-- Create app — session_id should be saved to kv.
		local caps1 = make_mock_caps()
		caps1.kv = shared_kv
		local app1 = server.create(caps1, { no_static = true })
		T.ok(kv_store["card_session_id"], "session_id was saved")
		local session_id = app1.state.session_id

		-- The session_id persists, but the db is in-memory so a new app
		-- won't find it. This test verifies the kv save/load mechanism.
		T.eq(kv_store["card_session_id"], session_id)
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
		-- First message should be system prompt.
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

-- ── Impersonate tests ──────────────────────────────────────────────────────

T.describe("POST /api/impersonate", function()
	T.it("returns generated content without modifying conversation", function()
		local caps = make_mock_caps({ llm_call = function() return "impersonated text" end })
		local app = server.create(caps, { no_static = true })
		local path_before = app.state.conv:get_canonical_path(app.state.session_id)
		local initial_count = #path_before
		local status, data = call(app, "POST", "/api/impersonate")
		T.eq(status, 200)
		T.eq(data.content, "impersonated text")
		local path_after = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path_after, initial_count, "conversation unchanged")
	end)

	T.it("does not add messages to conversation", function()
		local call_count = 0
		local caps = make_mock_caps({
			llm_call = function()
				call_count = call_count + 1
				return "response " .. call_count
			end,
		})
		local app = server.create(caps, { no_static = true })
		-- Send a real message first.
		call(app, "POST", "/api/message", { content = "Hello" })
		local path_after_send = app.state.conv:get_canonical_path(app.state.session_id)
		local count_after_send = #path_after_send

		-- Impersonate should not change message count.
		local status, data = call(app, "POST", "/api/impersonate")
		T.eq(status, 200)
		T.ok(data.content, "has content")
		local path_after_imp = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path_after_imp, count_after_send, "no new messages added")
	end)

	T.it("includes optional prompt hint in context", function()
		local captured_context
		local caps = make_mock_caps({
			llm_call = function(messages)
				captured_context = messages
				return "with hint"
			end,
		})
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/impersonate", { prompt = "Be dramatic" })
		T.eq(status, 200)
		T.eq(data.content, "with hint")
		-- Last context message should contain the hint.
		T.ok(captured_context, "context was captured")
		local last = captured_context[#captured_context]
		T.eq(last.role, "system")
		T.ok(last.content:find("Be dramatic"), "hint included in context")
		T.ok(last.content:find("Tester"), "user name substituted")
	end)

	T.it("returns 502 on LLM failure", function()
		local caps = make_mock_caps({ llm_call = function() return nil, "timeout" end })
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/impersonate")
		T.eq(status, 502)
		T.ok(data.error:find("timeout"), "error mentions timeout")
	end)
end)

-- ── Streaming tests ────────────────────────────────────────────────────────

T.describe("POST /api/message/stream", function()
	T.it("streams tokens via SSE when call_stream is available", function()
		local tokens_sent = { "Hello", " world", "!" }
		local caps = make_mock_caps()
		caps.llm.call_stream = function(messages, on_token)
			for _, tok in ipairs(tokens_sent) do
				on_token(tok)
			end
			return "Hello world!"
		end
		local app = server.create(caps, { no_static = true })
		local res, sock = call_with_sock(app, "POST", "/api/message/stream", { content = "Hi" })

		T.ok(res.raw, "res.raw is set for streaming")
		T.ok(sock.is_closed(), "socket was closed")

		local events = parse_sse_events(sock.sent)
		-- Should have: user, token*3, done
		local types = {}
		for _, e in ipairs(events) do types[#types + 1] = e.type end

		T.eq(types[1], "user")
		T.eq(types[2], "token")
		T.eq(types[3], "token")
		T.eq(types[4], "token")
		T.eq(types[5], "done")

		-- Check token content.
		T.eq(events[2].token, "Hello")
		T.eq(events[3].token, " world")
		T.eq(events[4].token, "!")

		-- Check done event has full content.
		T.eq(events[5].content, "Hello world!")
		T.eq(events[5].role, "assistant")
		T.ok(events[5].id, "done event has id")

		-- State should be updated.
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path, 3) -- greeting + user + assistant
		T.eq(path[3].content, "Hello world!")
	end)

	T.it("falls back to non-streaming when call_stream is absent", function()
		local caps = make_mock_caps({ llm_call = function() return "sync reply" end })
		-- No call_stream on caps.llm.
		local app = server.create(caps, { no_static = true })
		local res, sock = call_with_sock(app, "POST", "/api/message/stream", { content = "Hi" })

		-- Should fall back to regular JSON response (not streaming).
		T.ok(not res.raw, "res.raw is not set")
		T.eq(res.status, 200)
		local data = json.decode(res.body)
		T.eq(data.assistant.content, "sync reply")
	end)

	T.it("sends error event on LLM failure", function()
		local caps = make_mock_caps()
		caps.llm.call_stream = function(_messages, _on_token)
			return nil, "timeout"
		end
		local app = server.create(caps, { no_static = true })
		local path_before = app.state.conv:get_canonical_path(app.state.session_id)
		local initial_count = #path_before
		local res, sock = call_with_sock(app, "POST", "/api/message/stream", { content = "Hi" })

		T.ok(res.raw, "res.raw is set")
		local events = parse_sse_events(sock.sent)

		-- Should have user event then error event.
		local found_error = false
		for _, e in ipairs(events) do
			if e.type == "error" then
				found_error = true
				T.ok(e.error:find("timeout"), "error mentions timeout")
			end
		end
		T.ok(found_error, "error event was sent")

		-- User message should be rolled back.
		local path_after = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path_after, initial_count, "message rolled back")
	end)

	T.it("rejects empty content", function()
		local caps = make_mock_caps()
		caps.llm.call_stream = function() return "ok" end
		local app = server.create(caps, { no_static = true })
		local res, sock = call_with_sock(app, "POST", "/api/message/stream", { content = "" })

		T.ok(not res.raw, "res.raw not set for error")
		T.eq(res.status, 400)
	end)

	T.it("creates tree entry for streamed assistant message", function()
		local caps = make_mock_caps()
		caps.llm.call_stream = function(_messages, on_token)
			on_token("streamed")
			return "streamed"
		end
		local app = server.create(caps, { no_static = true })
		call_with_sock(app, "POST", "/api/message/stream", { content = "Test" })

		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local asst_msg = path[#path]
		T.eq(asst_msg.role, "assistant")
		T.eq(asst_msg.content, "streamed")
	end)
end)

-- ── Tree-specific behavior ─────────────────────────────────────────────────

T.describe("tree branching", function()
	T.it("edit creates fork — old branch preserved, swipeable", function()
		local call_count = 0
		local caps = make_mock_caps({
			llm_call = function()
				call_count = call_count + 1
				return "response " .. call_count
			end,
		})
		local app = server.create(caps, { no_static = true })

		-- Send a message: greeting -> user -> assistant
		call(app, "POST", "/api/message", { content = "Hello" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		local user_msg = path[2]
		local asst_msg = path[3]

		-- Edit the user message — creates a fork.
		local status, data = call(app, "POST", "/api/message/edit", {
			message_id = user_msg.id, content = "Goodbye",
		})
		T.eq(status, 200)
		T.eq(data.content, "Goodbye")

		-- The old branch (user_msg -> asst_msg) still exists.
		local old_user = app.state.conv:get_message(user_msg.id)
		T.ok(old_user, "old user msg preserved")
		T.eq(old_user.content, "Hello")
		local old_asst = app.state.conv:get_message(asst_msg.id)
		T.ok(old_asst, "old assistant msg preserved")

		-- The edited message is a sibling of the original.
		local siblings = app.state.conv:get_children(user_msg.parent_id)
		T.eq(#siblings, 2) -- original + edited
	end)

	T.it("delete removes subtree, parent switches canonical child", function()
		local call_count = 0
		local caps = make_mock_caps({
			llm_call = function()
				call_count = call_count + 1
				return "response " .. call_count
			end,
		})
		local app = server.create(caps, { no_static = true })

		-- Send two rounds of messages.
		call(app, "POST", "/api/message", { content = "First" })
		call(app, "POST", "/api/message", { content = "Second" })
		local path = app.state.conv:get_canonical_path(app.state.session_id)
		-- greeting, user1, asst1, user2, asst2
		T.eq(#path, 5)

		-- Delete user2 (and its child asst2).
		local user2_id = path[4].id
		local status, data = call(app, "POST", "/api/message/delete", { message_id = user2_id })
		T.eq(status, 200)
		T.eq(data.deleted, 2)

		-- Canonical path now ends at asst1.
		local path2 = app.state.conv:get_canonical_path(app.state.session_id)
		T.eq(#path2, 3)
		T.eq(path2[3].content, "response 1")
	end)
end)

-- ── Settings tests ────────────────────────────────────────────────────────

T.describe("GET /api/settings", function()
	T.it("returns default settings", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/settings")
		T.eq(status, 200)
		T.eq(data.temperature, 0.7)
		T.eq(data.top_p, 1.0)
		T.eq(data.max_tokens, 512)
		T.eq(data.frequency_penalty, 0.0)
		T.eq(data.presence_penalty, 0.0)
		T.eq(data.max_context, 4096)
	end)
end)

T.describe("POST /api/settings", function()
	T.it("merges partial update", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/settings", { temperature = 1.2 })
		T.eq(status, 200)
		T.eq(data.temperature, 1.2)
		-- Unchanged values preserved.
		T.eq(data.top_p, 1.0)
		T.eq(data.max_tokens, 512)
	end)

	T.it("persists settings to kv", function()
		local kv_store = {}
		local caps = make_mock_caps()
		caps.kv = {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		}
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/settings", { temperature = 0.5, max_tokens = 256 })
		T.ok(kv_store["settings"], "settings saved to kv")
		local saved = json.decode(kv_store["settings"])
		T.eq(saved.temperature, 0.5)
		T.eq(saved.max_tokens, 256)
	end)

	T.it("loads persisted settings on create", function()
		local kv_store = {}
		local shared_kv = {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		}
		-- Save settings via first app.
		local caps1 = make_mock_caps()
		caps1.kv = shared_kv
		local app1 = server.create(caps1, { no_static = true })
		call(app1, "POST", "/api/settings", { temperature = 1.5, max_context = 8192 })

		-- New app with same kv should load persisted settings.
		local caps2 = make_mock_caps()
		caps2.kv = shared_kv
		local app2 = server.create(caps2, { no_static = true })
		local status, data = call(app2, "GET", "/api/settings")
		T.eq(status, 200)
		T.eq(data.temperature, 1.5)
		T.eq(data.max_context, 8192)
		-- Defaults for unset values.
		T.eq(data.top_p, 1.0)
	end)
end)

T.describe("LLM parameter passthrough", function()
	T.it("passes generation params to llm.call", function()
		local captured_opts
		local caps = make_mock_caps({
			llm_call = function(messages, opts)
				captured_opts = opts
				return "ok"
			end,
		})
		local app = server.create(caps, { no_static = true })
		-- Update settings.
		call(app, "POST", "/api/settings", { temperature = 1.2, max_tokens = 256 })
		-- Send a message — LLM call should receive opts.
		call(app, "POST", "/api/message", { content = "test" })
		T.ok(captured_opts, "opts were passed to llm.call")
		T.eq(captured_opts.temperature, 1.2)
		T.eq(captured_opts.max_tokens, 256)
		T.eq(captured_opts.top_p, 1.0)
	end)

	T.it("passes generation params to llm.call_stream", function()
		local captured_opts
		local caps = make_mock_caps()
		caps.llm.call_stream = function(messages, on_token, opts)
			captured_opts = opts
			on_token("hi")
			return "hi"
		end
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/settings", { temperature = 0.3 })
		call_with_sock(app, "POST", "/api/message/stream", { content = "test" })
		T.ok(captured_opts, "opts were passed to call_stream")
		T.eq(captured_opts.temperature, 0.3)
	end)
end)

-- ── Lorebook tests ─────────────────────────────────────────────────────────

local function make_lorebook_caps(opts)
	opts = opts or {}
	local kv_store = {}
	return {
		llm = {
			call = opts.llm_call or function() return "mock response" end,
			count_tokens = function(text) return math.ceil(#text / 4) end,
		},
		png = {
			text = function(keyword)
				if keyword == "chara" then
					return json.encode({
						spec = "chara_card_v2",
						data = {
							name = "TestChar",
							description = "A test character.",
							personality = "Friendly.",
							scenario = "",
							first_mes = "Hello!",
							mes_example = "",
							creator_notes = "",
							system_prompt = "You are {{char}}.",
							post_history_instructions = "",
							alternate_greetings = {},
							tags = {},
							creator = "",
							character_version = "",
							extensions = {},
							character_book = {
								entries = {
									{
										keys = { "cat", "feline" },
										content = "Cats are small furry animals.",
										enabled = true,
										constant = false,
										insertion_order = 100,
										position = "before_char",
									},
									{
										keys = { "dog" },
										content = "Dogs are loyal companions.",
										enabled = true,
										constant = false,
										insertion_order = 50,
										position = "after_char",
									},
								},
							},
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
				if key == "user_name" then return "Tester" end
				if key == "max_context" then return 4096 end
				if key == "max_response" then return 512 end
				return nil
			end,
		},
	}, kv_store
end

T.describe("GET /api/lorebook", function()
	T.it("returns entries from loaded card", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/lorebook")
		T.eq(status, 200)
		T.ok(data.entries, "has entries")
		T.eq(#data.entries, 2)
		T.eq(data.entries[1].keys[1], "cat")
		T.eq(data.entries[1].keys[2], "feline")
		T.eq(data.entries[1].content, "Cats are small furry animals.")
		T.eq(data.entries[1].enabled, true)
		T.eq(data.entries[1].order, 100)
		T.eq(data.entries[2].keys[1], "dog")
		T.eq(data.entries[2].content, "Dogs are loyal companions.")
	end)

	T.it("returns empty list when no lorebook", function()
		local caps = make_mock_caps()
		-- Default mock has no character_book
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/lorebook")
		T.eq(status, 200)
		T.eq(#data.entries, 0)
	end)
end)

T.describe("POST /api/lorebook/update", function()
	T.it("updates entry fields", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		-- Get entries to find uid
		local _, list = call(app, "GET", "/api/lorebook")
		local uid = list.entries[1].uid
		local status, data = call(app, "POST", "/api/lorebook/update", {
			uid = uid,
			keys = { "kitty" },
			content = "Updated content.",
			enabled = false,
			order = 200,
		})
		T.eq(status, 200)
		T.eq(data.uid, uid)
		T.eq(data.keys[1], "kitty")
		T.eq(data.content, "Updated content.")
		T.eq(data.enabled, false)
		T.eq(data.order, 200)
		-- Verify persisted
		local _, list2 = call(app, "GET", "/api/lorebook")
		T.eq(list2.entries[1].keys[1], "kitty")
		T.eq(list2.entries[1].content, "Updated content.")
	end)

	T.it("returns 400 without uid", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/lorebook/update", { content = "x" })
		T.eq(status, 400)
		T.ok(data.error, "has error")
	end)

	T.it("returns 404 for unknown uid", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/lorebook/update", { uid = "nonexistent" })
		T.eq(status, 404)
	end)
end)

T.describe("POST /api/lorebook/add", function()
	T.it("creates a new entry", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/lorebook/add", {
			keys = { "bird", "avian" },
			content = "Birds can fly.",
			order = 75,
		})
		T.eq(status, 200)
		T.ok(data.uid, "has generated uid")
		T.eq(data.keys[1], "bird")
		T.eq(data.keys[2], "avian")
		T.eq(data.content, "Birds can fly.")
		T.eq(data.enabled, true, "defaults to enabled")
		T.eq(data.order, 75)
		-- Verify it appears in the list
		local _, list = call(app, "GET", "/api/lorebook")
		T.eq(#list.entries, 3)
	end)

	T.it("returns 400 without keys or content", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/lorebook/add", { keys = { "x" } })
		T.eq(status, 400)
		status = call(app, "POST", "/api/lorebook/add", { content = "x" })
		T.eq(status, 400)
	end)
end)

T.describe("POST /api/lorebook/delete", function()
	T.it("removes entry by uid", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local _, list = call(app, "GET", "/api/lorebook")
		T.eq(#list.entries, 2)
		local uid = list.entries[1].uid
		local status, data = call(app, "POST", "/api/lorebook/delete", { uid = uid })
		T.eq(status, 200)
		T.eq(data.deleted, true)
		local _, list2 = call(app, "GET", "/api/lorebook")
		T.eq(#list2.entries, 1)
		T.eq(list2.entries[1].keys[1], "dog")
	end)

	T.it("returns 400 without uid", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/lorebook/delete", {})
		T.eq(status, 400)
		T.ok(data.error, "has error")
	end)

	T.it("returns 404 for unknown uid", function()
		local caps = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/lorebook/delete", { uid = "nonexistent" })
		T.eq(status, 404)
	end)
end)

T.describe("lorebook persistence", function()
	T.it("saves to kv after mutation and loads on init", function()
		local caps, kv_store = make_lorebook_caps()
		local app = server.create(caps, { no_static = true })
		-- Mutate: add an entry
		call(app, "POST", "/api/lorebook/add", {
			keys = { "fish" },
			content = "Fish swim.",
		})
		T.ok(kv_store["lorebook"], "lorebook saved to kv")
		-- Verify kv contains 3 entries
		local saved = json.decode(kv_store["lorebook"])
		T.eq(#saved, 3)

		-- Create a new app with the same kv — should load from kv
		local caps2 = make_lorebook_caps()
		caps2.kv = caps.kv  -- share the kv store
		local app2 = server.create(caps2, { no_static = true })
		local _, list = call(app2, "GET", "/api/lorebook")
		T.eq(#list.entries, 3)
	end)
end)

-- ── Session management tests ──────────────────────────────────────────────

T.describe("GET /api/sessions", function()
	T.it("lists sessions with previews", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "GET", "/api/sessions")
		T.eq(status, 200)
		T.ok(data.sessions, "has sessions")
		T.eq(#data.sessions, 1)
		T.eq(data.current, app.state.session_id)
		-- Preview should be the greeting (no user messages yet).
		T.eq(data.sessions[1].preview, "Hello, Tester!")
		T.ok(data.sessions[1].created_at, "has created_at")
	end)

	T.it("preview uses first user message when present", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "Tell me about cats" })
		local status, data = call(app, "GET", "/api/sessions")
		T.eq(status, 200)
		T.eq(data.sessions[1].preview, "Tell me about cats")
	end)

	T.it("truncates long previews", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		local long_text = string.rep("a", 100)
		call(app, "POST", "/api/message", { content = long_text })
		local status, data = call(app, "GET", "/api/sessions")
		T.eq(status, 200)
		T.ok(#data.sessions[1].preview <= 80, "preview truncated")
		T.ok(data.sessions[1].preview:find("%.%.%.$"), "ends with ...")
	end)
end)

T.describe("POST /api/session/new", function()
	T.it("creates a new session with greeting", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local original_session = app.state.session_id
		local status, data = call(app, "POST", "/api/session/new")
		T.eq(status, 200)
		T.ok(data.session, "has session")
		T.ok(data.session.id, "has session id")
		T.neq(data.session.id, original_session)
		T.ok(data.messages, "has messages")
		T.eq(#data.messages, 1) -- greeting
		T.eq(data.messages[1].role, "assistant")
		T.eq(data.messages[1].content, "Hello, Tester!")
		-- State should be switched.
		T.eq(app.state.session_id, data.session.id)
	end)

	T.it("new session appears in list", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/session/new")
		local status, data = call(app, "GET", "/api/sessions")
		T.eq(status, 200)
		T.eq(#data.sessions, 2)
	end)
end)

T.describe("POST /api/session/switch", function()
	T.it("switches to an existing session", function()
		local caps = make_mock_caps({ llm_call = function() return "reply" end })
		local app = server.create(caps, { no_static = true })
		local first_session = app.state.session_id
		-- Send a message in the first session.
		call(app, "POST", "/api/message", { content = "Hello" })
		-- Create a second session.
		call(app, "POST", "/api/session/new")
		T.neq(app.state.session_id, first_session)
		-- Switch back.
		local status, data = call(app, "POST", "/api/session/switch", { session_id = first_session })
		T.eq(status, 200)
		T.eq(app.state.session_id, first_session)
		T.eq(data.session.id, first_session)
		-- Should have the messages from the first session.
		T.eq(#data.messages, 3) -- greeting + user + assistant
	end)

	T.it("returns 404 for unknown session", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/session/switch", { session_id = "nonexistent" })
		T.eq(status, 404)
	end)

	T.it("returns 400 without session_id", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status, data = call(app, "POST", "/api/session/switch", {})
		T.eq(status, 400)
	end)
end)

T.describe("POST /api/session/delete", function()
	T.it("deletes a session and switches to another", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local first_session = app.state.session_id
		-- Create a second session (becomes current).
		call(app, "POST", "/api/session/new")
		local second_session = app.state.session_id
		-- Delete the current (second) session.
		local status, data = call(app, "POST", "/api/session/delete", { session_id = second_session })
		T.eq(status, 200)
		T.ok(data.deleted, "deleted flag set")
		T.eq(data.current_session_id, first_session)
		T.eq(app.state.session_id, first_session)
		T.ok(data.messages, "has messages")
	end)

	T.it("deleting non-current session keeps current", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local first_session = app.state.session_id
		call(app, "POST", "/api/session/new")
		local second_session = app.state.session_id
		-- Delete the first session (not current).
		local status, data = call(app, "POST", "/api/session/delete", { session_id = first_session })
		T.eq(status, 200)
		T.eq(data.current_session_id, second_session)
		T.eq(app.state.session_id, second_session)
	end)

	T.it("deleting last session creates a new one", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local only_session = app.state.session_id
		local status, data = call(app, "POST", "/api/session/delete", { session_id = only_session })
		T.eq(status, 200)
		T.ok(data.deleted, "deleted flag set")
		-- A new session should have been created.
		T.neq(data.current_session_id, only_session)
		T.eq(app.state.session_id, data.current_session_id)
		T.ok(data.messages, "has messages for new session")
	end)

	T.it("returns 404 for unknown session", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/session/delete", { session_id = "nope" })
		T.eq(status, 404)
	end)

	T.it("returns 400 without session_id", function()
		local caps = make_mock_caps()
		local app = server.create(caps, { no_static = true })
		local status = call(app, "POST", "/api/session/delete", {})
		T.eq(status, 400)
	end)
end)

T.describe("session persistence via kv", function()
	T.it("saves session_id to kv on session/new", function()
		local kv_store = {}
		local caps = make_mock_caps()
		caps.kv = {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		}
		local app = server.create(caps, { no_static = true })
		local original = app.state.session_id
		call(app, "POST", "/api/session/new")
		T.neq(kv_store["card_session_id"], original)
		T.eq(kv_store["card_session_id"], app.state.session_id)
	end)

	T.it("saves session_id to kv on session/switch", function()
		local kv_store = {}
		local caps = make_mock_caps()
		caps.kv = {
			get = function(key) return kv_store[key] end,
			set = function(key, val) kv_store[key] = val end,
		}
		local app = server.create(caps, { no_static = true })
		local first = app.state.session_id
		call(app, "POST", "/api/session/new")
		local second = app.state.session_id
		T.eq(kv_store["card_session_id"], second)
		call(app, "POST", "/api/session/switch", { session_id = first })
		T.eq(kv_store["card_session_id"], first)
	end)
end)
