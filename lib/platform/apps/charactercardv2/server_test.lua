if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local server = require("lib.platform.apps.charactercardv2.server")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function make_mock_llm(response_content, opts)
	opts = opts or {}
	return {
		call = function(messages, gen_opts)
			if opts.on_call then opts.on_call(messages, gen_opts) end
			if opts.call_err then return nil, opts.call_err end
			return response_content
		end,
		call_stream = function(messages, on_token, gen_opts)
			if opts.on_call_stream then opts.on_call_stream(messages, on_token, gen_opts) end
			if opts.stream_err then return nil, opts.stream_err end
			local parts = opts.stream_parts or { response_content }
			for _, part in ipairs(parts) do
				on_token(part)
			end
			return table.concat(parts)
		end,
		count_tokens = function(text)
			return math.ceil(#text / 4)
		end,
	}
end

local function make_mock_kv()
	local store = {}
	return {
		get = function(key) return store[key] end,
		set = function(key, val) store[key] = val end,
	}
end

local function make_mock_time(t)
	local tick = t or 1000000
	return {
		now = function()
			tick = tick + 1
			return tick
		end,
	}
end

-- Make a minimal caps table with an in-memory conversation db.
local function make_caps(llm_response, llm_opts, extra_caps)
	local caps = {
		llm  = make_mock_llm(llm_response or "assistant reply", llm_opts),
		kv   = make_mock_kv(),
		time = make_mock_time(),
	}
	if extra_caps then
		for k, v in pairs(extra_caps) do
			caps[k] = v
		end
	end
	return caps
end

-- Make a request table.
local function make_req(method, target, body)
	local body_str = (type(body) == "table") and require("lib.format.json").encode(body) or (body or "")
	return {
		method  = method,
		target  = target,
		headers = {},
		body    = body_str,
	}
end

-- Make a minimal response table.
local function make_res()
	return { status = 200, headers = {}, body = "" }
end

-- Invoke a route directly through the handler and decode the JSON response.
local function call(app, method, target, body)
	local req = make_req(method, target, body)
	local res = make_res()
	app.handler(req, res, nil)
	if res.body and #res.body > 0 then
		local ok, val = pcall(require("lib.format.json").decode, res.body)
		if ok then return res.status, val end
	end
	return res.status, nil
end

-- ── create ───────────────────────────────────────────────────────────────────

T.describe("server.create", function()
	T.it("creates app with pre-built llm client (caps.llm)", function()
		local app = server.create({ llm = make_mock_llm("hi"), time = make_mock_time() })
		T.ok(type(app) == "table")
		T.ok(type(app.chat) == "function")
		T.ok(type(app.chat_stream) == "function")
		T.ok(type(app.count_tokens) == "function")
	end)

	T.it("returns error when no llm cap provided", function()
		local app = server.create({ time = make_mock_time() })
		local content, err = app.chat({ { role = "user", content = "hi" } })
		T.eq(content, nil)
		T.ok(err:find("no LLM") ~= nil)
	end)

	T.it("exposes state with conv handle and session_id", function()
		local caps = make_caps("hi")
		local app = server.create(caps)
		T.ok(app.state ~= nil)
		T.ok(app.state.conv ~= nil)
		T.ok(type(app.state.session_id) == "string")
	end)
end)

-- ── chat ─────────────────────────────────────────────────────────────────────

T.describe("server.chat", function()
	T.it("passes messages to llm.call", function()
		local captured_msgs
		local mock = make_mock_llm("response", {
			on_call = function(msgs) captured_msgs = msgs end,
		})
		local app = server.create({ llm = mock, time = make_mock_time() })
		local content = app.chat({ { role = "user", content = "hello" } })
		T.eq(content, "response")
		T.eq(#captured_msgs, 1)
		T.eq(captured_msgs[1].content, "hello")
	end)

	T.it("prepends system prompt when configured", function()
		local captured_msgs
		local mock = make_mock_llm("response", {
			on_call = function(msgs) captured_msgs = msgs end,
		})
		local app = server.create({ llm = mock, time = make_mock_time() }, { system_prompt = "You are helpful." })
		app.chat({ { role = "user", content = "hi" } })
		T.eq(#captured_msgs, 2)
		T.eq(captured_msgs[1].role, "system")
		T.eq(captured_msgs[1].content, "You are helpful.")
		T.eq(captured_msgs[2].role, "user")
		T.eq(captured_msgs[2].content, "hi")
	end)

	T.it("passes gen_opts through", function()
		local captured_opts
		local mock = make_mock_llm("ok", {
			on_call = function(_, gen_opts) captured_opts = gen_opts end,
		})
		local app = server.create({ llm = mock, time = make_mock_time() })
		app.chat({ { role = "user", content = "hi" } }, { temperature = 0.5 })
		T.eq(captured_opts.temperature, 0.5)
	end)
end)

-- ── chat_stream ──────────────────────────────────────────────────────────────

T.describe("server.chat_stream", function()
	T.it("streams tokens via on_token callback", function()
		local tokens = {}
		local mock = make_mock_llm("full", {
			stream_parts = { "hel", "lo" },
		})
		local app = server.create({ llm = mock, time = make_mock_time() })
		local full = app.chat_stream(
			{ { role = "user", content = "hi" } },
			function(delta) tokens[#tokens + 1] = delta end
		)
		T.eq(full, "hello")
		T.eq(#tokens, 2)
		T.eq(tokens[1], "hel")
		T.eq(tokens[2], "lo")
	end)

	T.it("prepends system prompt in streaming mode", function()
		local captured_msgs
		local mock = make_mock_llm("ok", {
			stream_parts = { "ok" },
			on_call_stream = function(msgs) captured_msgs = msgs end,
		})
		local app = server.create({ llm = mock, time = make_mock_time() }, { system_prompt = "Be nice." })
		app.chat_stream(
			{ { role = "user", content = "hi" } },
			function() end
		)
		T.eq(#captured_msgs, 2)
		T.eq(captured_msgs[1].role, "system")
		T.eq(captured_msgs[1].content, "Be nice.")
	end)

	T.it("returns error when streaming not supported", function()
		local mock = { call = function() return "ok" end, count_tokens = function() return 0 end }
		local app = server.create({ llm = mock, time = make_mock_time() })
		local content, err = app.chat_stream(
			{ { role = "user", content = "hi" } },
			function() end
		)
		T.eq(content, nil)
		T.ok(err:find("streaming") ~= nil)
	end)
end)

-- ── count_tokens ─────────────────────────────────────────────────────────────

T.describe("server.count_tokens", function()
	T.it("delegates to llm.count_tokens", function()
		local app = server.create({ llm = make_mock_llm("ok"), time = make_mock_time() })
		T.eq(app.count_tokens("hello world"), 3) -- ceil(11/4) = 3
	end)

	T.it("returns 0 when no llm available", function()
		local app = server.create({ time = make_mock_time() })
		T.eq(app.count_tokens("hello"), 0)
	end)
end)

-- ── GET /api/messages ─────────────────────────────────────────────────────────

T.describe("GET /api/messages", function()
	T.it("returns empty messages array for new session without card", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "GET", "/api/messages")
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(type(body.messages) == "table")
		T.eq(#body.messages, 0)
	end)
end)

-- ── POST /api/message ────────────────────────────────────────────────────────

T.describe("POST /api/message", function()
	T.it("adds user and assistant messages and returns them", function()
		local caps = make_caps("assistant reply")
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "POST", "/api/message", { content = "hello" })
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(body.user ~= nil)
		T.ok(body.assistant ~= nil)
		T.eq(body.user.role, "user")
		T.eq(body.user.content, "hello")
		T.eq(body.assistant.role, "assistant")
		T.eq(body.assistant.content, "assistant reply")
	end)

	T.it("returns 400 when content missing", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "POST", "/api/message", {})
		T.eq(status, 400)
	end)

	T.it("returns 502 and rolls back user message on LLM error", function()
		local caps = make_caps(nil, { call_err = "model unavailable" })
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "POST", "/api/message", { content = "hi" })
		T.eq(status, 502)
		-- Verify no messages were persisted.
		local mstatus, mbody = call(app, "GET", "/api/messages")
		T.eq(mstatus, 200)
		T.eq(#mbody.messages, 0)
	end)

	T.it("conversation grows with each message", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "message 1" })
		call(app, "POST", "/api/message", { content = "message 2" })
		local status, body = call(app, "GET", "/api/messages")
		T.eq(status, 200)
		-- user1, assistant1, user2, assistant2
		T.eq(#body.messages, 4)
		T.eq(body.messages[1].role, "user")
		T.eq(body.messages[1].content, "message 1")
		T.eq(body.messages[2].role, "assistant")
		T.eq(body.messages[3].role, "user")
		T.eq(body.messages[3].content, "message 2")
		T.eq(body.messages[4].role, "assistant")
	end)
end)

-- ── POST /api/message/edit ───────────────────────────────────────────────────

T.describe("POST /api/message/edit", function()
	T.it("forks message as a sibling with new content", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "original" })
		local _, msgs = call(app, "GET", "/api/messages")
		local user_msg = msgs.messages[1]

		local status, body = call(app, "POST", "/api/message/edit", {
			message_id = user_msg.id,
			content    = "edited",
		})
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.eq(body.role, "user")
		T.eq(body.content, "edited")
		T.ok(body.reload_below == true)
		-- Sibling count should now be 2 (original + edited).
		T.eq(body.sibling_count, 2)
	end)

	T.it("returns 400 when message_id or content missing", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, _ = call(app, "POST", "/api/message/edit", { content = "x" })
		T.eq(status, 400)
	end)

	T.it("returns 404 for unknown message_id", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, _ = call(app, "POST", "/api/message/edit", {
			message_id = "00000000-0000-0000-0000-000000000000",
			content    = "x",
		})
		T.eq(status, 404)
	end)
end)

-- ── POST /api/message/delete ─────────────────────────────────────────────────

T.describe("POST /api/message/delete", function()
	T.it("deletes a message and returns deleted count", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "hello" })
		local _, msgs = call(app, "GET", "/api/messages")
		T.eq(#msgs.messages, 2)

		local user_msg = msgs.messages[1]
		local status, body = call(app, "POST", "/api/message/delete", {
			message_id = user_msg.id,
		})
		T.eq(status, 200)
		-- Deleting user message also deletes assistant message (subtree).
		T.ok(body.deleted >= 1)

		local _, after = call(app, "GET", "/api/messages")
		T.eq(#after.messages, 0)
	end)

	T.it("returns 400 when message_id missing", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, _ = call(app, "POST", "/api/message/delete", {})
		T.eq(status, 400)
	end)
end)

-- ── POST /api/swipe/new ──────────────────────────────────────────────────────

T.describe("POST /api/swipe/new", function()
	T.it("generates a new sibling for an existing message", function()
		local call_count = 0
		local responses = { "first reply", "second reply" }
		local mock = make_mock_llm(nil, {
			on_call = function() end,
			call_err = nil,
		})
		mock.call = function()
			call_count = call_count + 1
			return responses[call_count] or "reply"
		end
		local caps = {
			llm  = mock,
			kv   = make_mock_kv(),
			time = make_mock_time(),
		}
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "hello" })
		local _, msgs = call(app, "GET", "/api/messages")
		local asst_msg = msgs.messages[2]
		T.eq(asst_msg.role, "assistant")
		T.eq(asst_msg.sibling_count, 1)

		local status, body = call(app, "POST", "/api/swipe/new", {
			message_id = asst_msg.id,
		})
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.eq(body.role, "assistant")
		T.eq(body.sibling_count, 2)
	end)
end)

-- ── GET /api/swipes ───────────────────────────────────────────────────────────

T.describe("GET /api/swipes", function()
	T.it("returns swipes with current index for a message", function()
		local caps = make_caps("only reply")
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "hello" })
		local _, msgs = call(app, "GET", "/api/messages")
		local asst_msg = msgs.messages[2]

		local status, body = call(app, "GET", "/api/swipes?message_id=" .. asst_msg.id)
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(type(body.swipes) == "table")
		T.eq(#body.swipes, 1)
		T.eq(body.current, 0)
		T.eq(body.swipes[1].content, "only reply")
	end)

	T.it("returns 400 when message_id missing", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, _ = call(app, "GET", "/api/swipes")
		T.eq(status, 400)
	end)
end)

-- ── POST /api/branch/navigate ────────────────────────────────────────────────

T.describe("POST /api/branch/navigate", function()
	T.it("navigates to a sibling message", function()
		local replies = { "first", "second" }
		local idx = 0
		local mock = make_mock_llm(nil, {})
		mock.call = function()
			idx = idx + 1
			return replies[idx] or "reply"
		end
		local caps = {
			llm  = mock,
			kv   = make_mock_kv(),
			time = make_mock_time(),
		}
		local app = server.create(caps, { no_static = true })
		call(app, "POST", "/api/message", { content = "hello" })
		local _, msgs1 = call(app, "GET", "/api/messages")
		local asst1 = msgs1.messages[2]
		-- Generate a second sibling.
		call(app, "POST", "/api/swipe/new", { message_id = asst1.id })
		local _, swipes = call(app, "GET", "/api/swipes?message_id=" .. asst1.id)
		T.eq(#swipes.swipes, 2)
		-- Navigate to the first sibling.
		local status, body = call(app, "POST", "/api/branch/navigate", {
			message_id = asst1.id,
		})
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(body.reload_below == true)
	end)

	T.it("returns 404 for unknown message_id", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, _ = call(app, "POST", "/api/branch/navigate", {
			message_id = "00000000-0000-0000-0000-000000000000",
		})
		T.eq(status, 404)
	end)
end)

-- ── Session management ────────────────────────────────────────────────────────

T.describe("session management", function()
	T.it("GET /api/sessions returns list with active session", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "GET", "/api/sessions")
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(type(body.sessions) == "table")
		T.eq(#body.sessions, 1)
		T.ok(type(body.active) == "string")
		T.eq(body.sessions[1].id, body.active)
	end)

	T.it("POST /api/sessions creates a new session and activates it", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local first_session_id = app.state.session_id

		local status, body = call(app, "POST", "/api/sessions")
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(type(body.session) == "table")
		T.ok(body.session.id ~= first_session_id)
		T.eq(body.active, body.session.id)

		local _, list = call(app, "GET", "/api/sessions")
		T.eq(#list.sessions, 2)
	end)

	T.it("POST /api/sessions/:id/activate switches active session", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local first_id = app.state.session_id

		-- Create a second session.
		call(app, "POST", "/api/sessions")
		local second_id = app.state.session_id
		T.ok(second_id ~= first_id)

		-- Switch back to the first session.
		local status, body = call(app, "POST", "/api/sessions/" .. first_id .. "/activate")
		T.eq(status, 200)
		T.eq(body.active, first_id)
		T.eq(app.state.session_id, first_id)
	end)

	T.it("DELETE /api/sessions/:id deletes a session", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })

		-- Create a second session so we can delete the first.
		local first_id = app.state.session_id
		call(app, "POST", "/api/sessions")

		local status, body = call(app, "DELETE", "/api/sessions/" .. first_id)
		T.eq(status, 200)
		T.eq(body.deleted, first_id)

		local _, list = call(app, "GET", "/api/sessions")
		T.eq(#list.sessions, 1)
		T.ok(list.sessions[1].id ~= first_id)
	end)

	T.it("DELETE /api/sessions/:id on active session switches to another", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local first_id = app.state.session_id

		-- Create second session (becomes active).
		local _, new_body = call(app, "POST", "/api/sessions")
		local second_id = new_body.session.id

		-- Switch back to first and delete it.
		call(app, "POST", "/api/sessions/" .. first_id .. "/activate")
		T.eq(app.state.session_id, first_id)

		local status, body = call(app, "DELETE", "/api/sessions/" .. first_id)
		T.eq(status, 200)
		-- Active session should have changed.
		T.ok(app.state.session_id ~= first_id)
	end)

	T.it("messages are isolated per session", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local first_id = app.state.session_id

		-- Send a message in the first session.
		call(app, "POST", "/api/message", { content = "in session 1" })

		-- Create a second session.
		call(app, "POST", "/api/sessions")

		-- Second session should have no messages.
		local _, msgs = call(app, "GET", "/api/messages")
		T.eq(#msgs.messages, 0)

		-- Switch back to first session.
		call(app, "POST", "/api/sessions/" .. first_id .. "/activate")
		local _, msgs1 = call(app, "GET", "/api/messages")
		T.ok(#msgs1.messages >= 1)
	end)
end)

-- ── Preset management ─────────────────────────────────────────────────────────

T.describe("preset management", function()
	T.it("GET /api/presets returns defaults when no presets stored", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "GET", "/api/presets")
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(type(body.connections) == "table")
		T.ok(type(body.generations) == "table")
		T.ok(type(body.prompts) == "table")
		T.ok(#body.connections > 0)
		T.ok(#body.generations > 0)
		T.ok(#body.prompts > 0)
	end)

	T.it("POST /api/presets/save saves a preset and GET returns it", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "POST", "/api/presets/save", {
			type   = "generation",
			name   = "My Custom",
			preset = { temperature = 0.9, max_tokens = 256 },
		})
		T.eq(status, 200)
		T.ok(body.ok == true)

		local _, presets = call(app, "GET", "/api/presets")
		local found = false
		for _, g in ipairs(presets.generations) do
			if g.name == "My Custom" then found = true; break end
		end
		T.ok(found)
	end)

	T.it("POST /api/presets/activate sets the active preset", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		-- Use a default preset name that exists.
		local status, body = call(app, "POST", "/api/presets/activate", {
			type = "generation",
			name = "Balanced",
		})
		T.eq(status, 200)
		T.ok(body.ok == true)

		local _, presets = call(app, "GET", "/api/presets")
		T.eq(presets.active.generation, "Balanced")
	end)

	T.it("POST /api/presets/delete removes a stored preset", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		-- Save a preset first.
		call(app, "POST", "/api/presets/save", {
			type   = "prompt",
			name   = "To Delete",
			preset = { system_prompt = "x" },
		})
		local status, body = call(app, "POST", "/api/presets/delete", {
			type = "prompt",
			name = "To Delete",
		})
		T.eq(status, 200)
		T.ok(body.ok == true)

		local _, presets = call(app, "GET", "/api/presets")
		for _, p in ipairs(presets.prompts) do
			T.ok(p.name ~= "To Delete")
		end
	end)

	T.it("returns 503 for preset endpoints when kv cap absent", function()
		local app = server.create({ llm = make_mock_llm("ok"), time = make_mock_time() }, { no_static = true })
		local status, _ = call(app, "GET", "/api/presets")
		T.eq(status, 503)
	end)
end)
