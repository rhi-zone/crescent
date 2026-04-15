if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local json   = require("lib.json")
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

-- ── create ───────────────────────────────────────────────────────────────────

T.describe("server.create", function()
	T.it("creates app with pre-built llm client (caps.llm)", function()
		local app = server.create({ llm = make_mock_llm("hi") })
		T.ok(type(app) == "table")
		T.ok(type(app.chat) == "function")
		T.ok(type(app.chat_stream) == "function")
		T.ok(type(app.count_tokens) == "function")
	end)

	T.it("creates app from http_client cap (caps.llm_api)", function()
		local mock_http = {
			request = function(req)
				return {
					status = 200,
					headers = {},
					body = json.encode({ choices = { { message = { content = "from api" } } } }),
				}
			end,
			request_stream = function(req, on_chunk)
				on_chunk("data: " .. json.encode({ choices = { { delta = { content = "streamed" } } } }) .. "\n\n")
				on_chunk("data: [DONE]\n\n")
				return { status = 200, headers = {} }
			end,
		}
		local app = server.create({ llm_api = mock_http }, { model = "test" })
		local content, err = app.chat({ { role = "user", content = "hi" } })
		T.ok(content ~= nil, tostring(err))
		T.eq(content, "from api")
	end)

	T.it("prefers caps.llm over caps.llm_api", function()
		local mock_llm = make_mock_llm("from llm")
		local mock_http = {
			request = function() return { status = 200, headers = {}, body = json.encode({ choices = { { message = { content = "from api" } } } }) } end,
		}
		local app = server.create({ llm = mock_llm, llm_api = mock_http })
		local content = app.chat({ { role = "user", content = "hi" } })
		T.eq(content, "from llm")
	end)

	T.it("returns error when no llm cap provided", function()
		local app = server.create({})
		local content, err = app.chat({ { role = "user", content = "hi" } })
		T.eq(content, nil)
		T.ok(err:find("no LLM") ~= nil)
	end)
end)

-- ── chat ─────────────────────────────────────────────────────────────────────

T.describe("server.chat", function()
	T.it("passes messages to llm.call", function()
		local captured_msgs
		local mock = make_mock_llm("response", {
			on_call = function(msgs) captured_msgs = msgs end,
		})
		local app = server.create({ llm = mock })
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
		local app = server.create({ llm = mock }, { system_prompt = "You are helpful." })
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
		local app = server.create({ llm = mock })
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
		local app = server.create({ llm = mock })
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
		local app = server.create({ llm = mock }, { system_prompt = "Be nice." })
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
		local app = server.create({ llm = mock })
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
		local app = server.create({ llm = make_mock_llm("ok") })
		T.eq(app.count_tokens("hello world"), 3) -- ceil(11/4) = 3
	end)

	T.it("returns 0 when no llm available", function()
		local app = server.create({})
		T.eq(app.count_tokens("hello"), 0)
	end)
end)
