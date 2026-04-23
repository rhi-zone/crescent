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

-- Make a minimal caps table. conversations is nil; the server falls back to
-- lib.conversation with an in-memory db (the default test path).
local function make_caps(llm_response, llm_opts, extra_caps)
	local mock_time = make_mock_time()
	local caps = {
		llm  = make_mock_llm(llm_response or "assistant reply", llm_opts),
		kv   = make_mock_kv(),
		time = mock_time,
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
	T.it("creates app with handler and state", function()
		local app = server.create({ llm = make_mock_llm("hi"), time = make_mock_time() })
		T.ok(type(app) == "table")
		T.ok(type(app.handler) == "function")
		T.ok(app.state ~= nil)
	end)

	T.it("exposes state with conv handle and session_id", function()
		local caps = make_caps("hi")
		local app = server.create(caps)
		T.ok(app.state ~= nil)
		T.ok(app.state.conv ~= nil)
		T.ok(type(app.state.session_id) == "string")
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
		T.ok(type(body.current) == "string")
		T.eq(body.sessions[1].id, body.current)
	end)

	T.it("POST /api/session/new creates a new session and activates it", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local first_session_id = app.state.session_id

		local status, body = call(app, "POST", "/api/session/new")
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(type(body.session) == "table")
		T.ok(body.session.id ~= first_session_id)
		T.eq(app.state.session_id, body.session.id)

		local _, list = call(app, "GET", "/api/sessions")
		T.eq(#list.sessions, 2)
	end)

	T.it("POST /api/session/switch switches active session", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local first_id = app.state.session_id

		-- Create a second session.
		call(app, "POST", "/api/session/new")
		local second_id = app.state.session_id
		T.ok(second_id ~= first_id)

		-- Switch back to the first session.
		local status, body = call(app, "POST", "/api/session/switch", { session_id = first_id })
		T.eq(status, 200)
		T.eq(app.state.session_id, first_id)
	end)

	T.it("POST /api/session/delete deletes a session", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })

		-- Create a second session so we can delete the first.
		local first_id = app.state.session_id
		call(app, "POST", "/api/session/new")

		local status, body = call(app, "POST", "/api/session/delete", { session_id = first_id })
		T.eq(status, 200)
		T.ok(body.deleted == true)

		local _, list = call(app, "GET", "/api/sessions")
		T.eq(#list.sessions, 1)
		T.ok(list.sessions[1].id ~= first_id)
	end)

	T.it("POST /api/session/delete on active session switches to another", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local first_id = app.state.session_id

		-- Create second session (becomes active).
		local _, new_body = call(app, "POST", "/api/session/new")
		local second_id = new_body.session.id

		-- Switch back to first and delete it.
		call(app, "POST", "/api/session/switch", { session_id = first_id })
		T.eq(app.state.session_id, first_id)

		local status, body = call(app, "POST", "/api/session/delete", { session_id = first_id })
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
		call(app, "POST", "/api/session/new")

		-- Second session should have no messages.
		local _, msgs = call(app, "GET", "/api/messages")
		T.eq(#msgs.messages, 0)

		-- Switch back to first session.
		call(app, "POST", "/api/session/switch", { session_id = first_id })
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
		-- New server requires name to be inside the preset object.
		local status, body = call(app, "POST", "/api/presets/save", {
			type   = "generation",
			preset = { name = "My Custom", temperature = 0.9, max_tokens = 256 },
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
		-- Save a preset first (name must be inside preset object).
		call(app, "POST", "/api/presets/save", {
			type   = "prompt",
			preset = { name = "To Delete", system_prompt = "x" },
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

	T.it("returns 500 for preset endpoints when kv cap absent", function()
		local app = server.create({ llm = make_mock_llm("ok"), time = make_mock_time() }, { no_static = true })
		local status, _ = call(app, "GET", "/api/presets")
		T.eq(status, 500)
	end)
end)

-- ── User lorebooks (CRUD) ─────────────────────────────────────────────────────

T.describe("user_lorebooks", function()
	T.it("lists empty when no books exist", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, body = call(app, "GET", "/api/user_lorebooks")
		T.eq(status, 200)
		T.ok(body ~= nil)
		T.ok(type(body.books) == "table")
		T.eq(#body.books, 0)
	end)

	T.it("creates, renames, toggles, and deletes a book", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })

		local status, created = call(app, "POST", "/api/user_lorebooks", { name = "Sci-fi" })
		T.eq(status, 200)
		T.ok(created.id ~= nil)
		T.eq(created.name, "Sci-fi")
		T.eq(created.active, false)
		T.eq(created.entry_count, 0)

		-- Rename.
		local _, renamed = call(app, "POST", "/api/user_lorebooks/rename",
			{ id = created.id, name = "Cyberpunk" })
		T.eq(renamed.name, "Cyberpunk")

		-- Toggle active.
		local _, toggled = call(app, "POST", "/api/user_lorebooks/toggle",
			{ id = created.id, active = true })
		T.eq(toggled.active, true)

		-- Reload from kv: should survive across restart.
		local app2 = server.create(caps, { no_static = true })
		local _, list = call(app2, "GET", "/api/user_lorebooks")
		T.eq(#list.books, 1)
		T.eq(list.books[1].name, "Cyberpunk")
		T.eq(list.books[1].active, true)

		-- Delete.
		local _, del = call(app, "POST", "/api/user_lorebooks/delete", { id = created.id })
		T.ok(del.deleted == true)
		local _, empty = call(app, "GET", "/api/user_lorebooks")
		T.eq(#empty.books, 0)
	end)

	T.it("entry CRUD within a book", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local _, book = call(app, "POST", "/api/user_lorebooks", { name = "Notes" })

		-- Add an entry.
		local status, added = call(app, "POST", "/api/user_lorebooks/entry/add", {
			book_id = book.id,
			keys = { "dragon" },
			content = "A fire-breathing lizard.",
		})
		T.eq(status, 200)
		T.ok(added.uid ~= nil)
		T.eq(added.content, "A fire-breathing lizard.")

		-- Get entries.
		local _, listed = call(app, "GET", "/api/user_lorebooks/entries?book_id=" .. book.id)
		T.eq(#listed.entries, 1)
		T.eq(listed.entries[1].uid, added.uid)

		-- Update the entry.
		local _, updated = call(app, "POST", "/api/user_lorebooks/entry/update", {
			book_id = book.id,
			uid = added.uid,
			content = "An ancient fire-breathing reptile.",
		})
		T.eq(updated.content, "An ancient fire-breathing reptile.")

		-- Delete.
		local _, deleted = call(app, "POST", "/api/user_lorebooks/entry/delete", {
			book_id = book.id,
			uid = added.uid,
		})
		T.ok(deleted.deleted == true)
		local _, listed2 = call(app, "GET", "/api/user_lorebooks/entries?book_id=" .. book.id)
		T.eq(#listed2.entries, 0)
	end)

	T.it("active books merge into context-assembly lorebook set", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local _, b = call(app, "POST", "/api/user_lorebooks", { name = "Active" })
		call(app, "POST", "/api/user_lorebooks/entry/add", {
			book_id = b.id,
			keys = { "k" },
			content = "c",
		})
		-- Inactive by default: not merged.
		T.ok(app.state.user_lorebooks[1].active == false)
		call(app, "POST", "/api/user_lorebooks/toggle", { id = b.id, active = true })
		T.ok(app.state.user_lorebooks[1].active == true)
	end)

	T.it("returns 404 for unknown book on rename/toggle/entries", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		local status, _ = call(app, "POST", "/api/user_lorebooks/rename",
			{ id = "nope", name = "x" })
		T.eq(status, 404)
		status = select(1, call(app, "POST", "/api/user_lorebooks/toggle",
			{ id = "nope", active = true }))
		T.eq(status, 404)
		status = select(1, call(app, "GET", "/api/user_lorebooks/entries?book_id=nope"))
		T.eq(status, 404)
	end)
end)

-- ── Migration: world_info → user_lorebooks ───────────────────────────────────

T.describe("world_info migration", function()
	T.it("wraps legacy world_info kv into an 'Imported' active book", function()
		local caps = make_caps("reply")
		-- Pre-seed kv as if an older server wrote the legacy key.
		local legacy = { {
			uid = "x1", key = { "k" }, keysecondary = {}, content = "legacy entry",
			enabled = true, constant = false, order = 0, position = 0,
		} }
		caps.kv.set("world_info", require("lib.format.json").encode(legacy))
		local app = server.create(caps, { no_static = true })
		local _, list = call(app, "GET", "/api/user_lorebooks")
		T.eq(#list.books, 1)
		T.eq(list.books[1].name, "Imported")
		T.eq(list.books[1].active, true)
		T.eq(list.books[1].entry_count, 1)
		-- Legacy key deleted.
		T.eq(caps.kv.get("world_info"), nil)
	end)

	T.it("is idempotent (no duplicate book on second start)", function()
		local caps = make_caps("reply")
		caps.kv.set("world_info", "[]")
		local app1 = server.create(caps, { no_static = true })
		-- Empty legacy array yields a book with 0 entries; still migrates once.
		local _, list1 = call(app1, "GET", "/api/user_lorebooks")
		local count1 = #list1.books
		-- Second start: legacy key gone; no new "Imported" book.
		local app2 = server.create(caps, { no_static = true })
		local _, list2 = call(app2, "GET", "/api/user_lorebooks")
		T.eq(#list2.books, count1)
	end)
end)

-- ── Card-state PNG writeback + fallback ──────────────────────────────────────

local function make_mock_self_write()
	-- In-memory simulation: chara chunk stored in a closed-over string.
	local stored
	local cap = {
		metadata = function(k) if k == "chara" then return stored end end,
		entries = function() return {} end,
		entry = function() return nil end,
		write_metadata = function(k, bytes)
			if k ~= "chara" then return nil, "bad key" end
			stored = bytes
			return true
		end,
	}
	return cap, function() return stored end
end

local function minimal_card_json()
	local base64 = require("lib.encode.base64")
	local json_mod = require("lib.format.json")
	local envelope = {
		spec = "chara_card_v2",
		spec_version = "2.0",
		data = {
			name = "Tester",
			description = "for tests",
			first_mes = "hi",
		},
	}
	return base64.encode(json_mod.encode(envelope))
end

T.describe("card state PNG writeback", function()
	T.it("writes chara via self_write when available", function()
		local base64 = require("lib.encode.base64")
		local json_mod = require("lib.format.json")
		local self_cap, read_stored = make_mock_self_write()
		-- Pre-seed a card in the "PNG".
		self_cap.write_metadata("chara", minimal_card_json())
		local caps = make_caps("reply", nil, {
			self = self_cap,
			self_write = self_cap,
		})
		local app = server.create(caps, { no_static = true })
		-- Author's note edit triggers flush_card_state, which writes chara.
		local status, _ = call(app, "POST", "/api/authors_note",
			{ text = "remember the goal", depth = 2, position = "after" })
		T.eq(status, 200)
		local stored = read_stored()
		T.ok(stored ~= nil)
		local decoded = base64.decode(stored)
		local ok, envelope = pcall(json_mod.decode, decoded)
		T.ok(ok)
		T.ok(envelope.data ~= nil)
		T.eq(envelope.data.extensions.depth_prompt, "remember the goal")
		T.eq(envelope.data.extensions.depth_prompt_depth, 2)
	end)

	T.it("falls back to kv when self_write is absent", function()
		local caps = make_caps("reply")
		local app = server.create(caps, { no_static = true })
		-- No card loaded (no self cap), but authors_note state still accepts
		-- writes and persists to kv.
		call(app, "POST", "/api/authors_note",
			{ text = "kv fallback", depth = 1, position = "before" })
		local raw = caps.kv.get("authors_note")
		T.ok(raw ~= nil)
		local json_mod = require("lib.format.json")
		local saved = json_mod.decode(raw)
		T.eq(saved.text, "kv fallback")
	end)

	T.it("restores authors_note/regex_scripts from chara.extensions on load", function()
		local base64 = require("lib.encode.base64")
		local json_mod = require("lib.format.json")
		local envelope = {
			spec = "chara_card_v2", spec_version = "2.0",
			data = {
				name = "Restored",
				description = "with extensions",
				first_mes = "hi",
				extensions = {
					depth_prompt = "baked in",
					depth_prompt_depth = 3,
					depth_prompt_role = "before",
					regex_scripts = {
						{ name = "s1", find = "x", replace = "y", enabled = true, scope = "ai_output", order = 0 },
					},
				},
			},
		}
		local encoded = base64.encode(json_mod.encode(envelope))
		local self_cap = {
			metadata = function(k) if k == "chara" then return encoded end end,
			entries = function() return {} end,
			entry = function() return nil end,
		}
		local caps = make_caps("reply", nil, { self = self_cap })
		local app = server.create(caps, { no_static = true })
		local _, an = call(app, "GET", "/api/authors_note")
		T.eq(an.text, "baked in")
		T.eq(an.depth, 3)
		T.eq(an.position, "before")
		local _, regex = call(app, "GET", "/api/regex")
		T.eq(#regex.scripts, 1)
		T.eq(regex.scripts[1].name, "s1")
	end)

	T.it("migrates legacy card-state kv keys into chara when self_write granted", function()
		local base64 = require("lib.encode.base64")
		local json_mod = require("lib.format.json")
		local self_cap, read_stored = make_mock_self_write()
		self_cap.write_metadata("chara", minimal_card_json())
		local caps = make_caps("reply", nil, {
			self = self_cap,
			self_write = self_cap,
		})
		-- Simulate a legacy install: author's note stored in kv.
		caps.kv.set("authors_note",
			json_mod.encode({ text = "migrate me", depth = 2, position = "after" }))
		local app = server.create(caps, { no_static = true })
		-- kv key should be deleted post-migration.
		T.eq(caps.kv.get("authors_note"), nil)
		-- State should reflect the migrated value.
		T.eq(app.state.authors_note.text, "migrate me")
		-- PNG should now carry the baked note.
		local stored = read_stored()
		local decoded = base64.decode(stored)
		local envelope = json_mod.decode(decoded)
		T.eq(envelope.data.extensions.depth_prompt, "migrate me")
	end)
end)
