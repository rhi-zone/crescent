if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local json = require("lib.json")
local llm  = require("lib.platform.apps.card.llm")

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function make_mock_client(response_body, opts)
	opts = opts or {}
	return {
		request = function(req)
			if opts.on_request then opts.on_request(req) end
			return {
				status = opts.status or 200,
				headers = {},
				body = type(response_body) == "string" and response_body or json.encode(response_body),
			}
		end,
		request_stream = opts.stream_fn or function(req, on_chunk)
			if opts.on_request then opts.on_request(req) end
			if opts.chunks then
				for _, chunk in ipairs(opts.chunks) do
					on_chunk(chunk)
				end
			end
			return { status = opts.status or 200, headers = {} }
		end,
	}
end

-- ── create ───────────────────────────────────────────────────────────────────

T.describe("llm.create", function()
	T.it("returns a table with call, call_stream, count_tokens", function()
		local client = llm.create(make_mock_client({}))
		T.ok(type(client) == "table")
		T.ok(type(client.call) == "function")
		T.ok(type(client.call_stream) == "function")
		T.ok(type(client.count_tokens) == "function")
	end)

	T.it("omits call_stream when http_client lacks request_stream", function()
		local mock = { request = function() return { status = 200, headers = {}, body = "{}" } end }
		local client = llm.create(mock)
		T.ok(type(client.call) == "function")
		T.eq(client.call_stream, nil)
		T.ok(type(client.count_tokens) == "function")
	end)
end)

-- ── call ─────────────────────────────────────────────────────────────────────

T.describe("llm.call", function()
	T.it("sends correct request format and parses response", function()
		local captured_req
		local mock = make_mock_client(
			{ choices = { { message = { content = "hello world" } } } },
			{ on_request = function(req) captured_req = req end }
		)
		local client = llm.create(mock, { model = "test-model", path = "/v1/chat/completions" })
		local msgs = { { role = "user", content = "hi" } }
		local content, err = client.call(msgs)
		T.ok(content ~= nil, tostring(err))
		T.eq(content, "hello world")
		-- Verify request structure
		T.eq(captured_req.method, "POST")
		T.eq(captured_req.path, "/v1/chat/completions")
		T.eq(captured_req.headers["Content-Type"], "application/json")
		local body = json.decode(captured_req.body)
		T.eq(body.model, "test-model")
		T.eq(body.messages[1].role, "user")
		T.eq(body.messages[1].content, "hi")
	end)

	T.it("passes generation opts through", function()
		local captured_req
		local mock = make_mock_client(
			{ choices = { { message = { content = "ok" } } } },
			{ on_request = function(req) captured_req = req end }
		)
		local client = llm.create(mock)
		client.call(
			{ { role = "user", content = "test" } },
			{ temperature = 0.7, max_tokens = 100, top_p = 0.9, stop = { "\n" } }
		)
		local body = json.decode(captured_req.body)
		T.eq(body.temperature, 0.7)
		T.eq(body.max_tokens, 100)
		T.eq(body.top_p, 0.9)
		T.eq(body.stop[1], "\n")
	end)

	T.it("returns nil, err on HTTP error", function()
		local mock = make_mock_client("error body", { status = 500 })
		local client = llm.create(mock)
		local content, err = client.call({ { role = "user", content = "hi" } })
		T.eq(content, nil)
		T.ok(err:find("500") ~= nil)
	end)

	T.it("returns nil, err on missing choices", function()
		local mock = make_mock_client({ result = "no choices" })
		local client = llm.create(mock)
		local content, err = client.call({ { role = "user", content = "hi" } })
		T.eq(content, nil)
		T.ok(err:find("no choices") ~= nil)
	end)

	T.it("returns nil, err on request failure", function()
		local mock = {
			request = function() return nil, "connection refused" end,
			request_stream = function() return nil, "connection refused" end,
		}
		local client = llm.create(mock)
		local content, err = client.call({ { role = "user", content = "hi" } })
		T.eq(content, nil)
		T.ok(err:find("connection refused") ~= nil)
	end)

	T.it("uses default model and path", function()
		local captured_req
		local mock = make_mock_client(
			{ choices = { { message = { content = "ok" } } } },
			{ on_request = function(req) captured_req = req end }
		)
		local client = llm.create(mock)
		client.call({ { role = "user", content = "hi" } })
		T.eq(captured_req.path, "/v1/chat/completions")
		local body = json.decode(captured_req.body)
		T.eq(body.model, "default")
	end)
end)

-- ── call_stream ──────────────────────────────────────────────────────────────

T.describe("llm.call_stream", function()
	T.it("parses SSE events and calls on_token", function()
		local chunks = {
			"data: " .. json.encode({ choices = { { delta = { content = "hel" } } } }) .. "\n\n",
			"data: " .. json.encode({ choices = { { delta = { content = "lo" } } } }) .. "\n\n",
			"data: [DONE]\n\n",
		}
		local mock = make_mock_client(nil, { chunks = chunks })
		local client = llm.create(mock)

		local tokens = {}
		local full, err = client.call_stream(
			{ { role = "user", content = "hi" } },
			function(delta) tokens[#tokens + 1] = delta end
		)
		T.ok(full ~= nil, tostring(err))
		T.eq(full, "hello")
		T.eq(#tokens, 2)
		T.eq(tokens[1], "hel")
		T.eq(tokens[2], "lo")
	end)

	T.it("handles chunks split across boundaries", function()
		-- Simulate a chunk that arrives split mid-line
		local event1 = "data: " .. json.encode({ choices = { { delta = { content = "a" } } } })
		local event2 = "data: " .. json.encode({ choices = { { delta = { content = "b" } } } })
		local chunks = {
			event1 .. "\n\n" .. "dat",
			"a: " .. json.encode({ choices = { { delta = { content = "c" } } } }) .. "\n\n",
			event2 .. "\n\ndata: [DONE]\n\n",
		}
		local mock = make_mock_client(nil, { chunks = chunks })
		local client = llm.create(mock)

		local tokens = {}
		local full = client.call_stream(
			{ { role = "user", content = "hi" } },
			function(delta) tokens[#tokens + 1] = delta end
		)
		T.eq(full, "acb")
		T.eq(#tokens, 3)
	end)

	T.it("passes stream=true and gen_opts in request body", function()
		local captured_req
		local mock = make_mock_client(nil, {
			chunks = { "data: [DONE]\n\n" },
			on_request = function(req) captured_req = req end,
		})
		local client = llm.create(mock, { model = "stream-model" })
		client.call_stream(
			{ { role = "user", content = "hi" } },
			function() end,
			{ temperature = 0.5 }
		)
		local body = json.decode(captured_req.body)
		T.eq(body.stream, true)
		T.eq(body.model, "stream-model")
		T.eq(body.temperature, 0.5)
	end)

	T.it("returns nil, err on request failure", function()
		local mock = {
			request = function() return nil, "fail" end,
			request_stream = function() return nil, "connection refused" end,
		}
		local client = llm.create(mock)
		local full, err = client.call_stream(
			{ { role = "user", content = "hi" } },
			function() end
		)
		T.eq(full, nil)
		T.ok(err:find("connection refused") ~= nil)
	end)
end)

-- ── count_tokens ─────────────────────────────────────────────────────────────

T.describe("llm.count_tokens", function()
	T.it("estimates token count from text length", function()
		local mock = make_mock_client({})
		local client = llm.create(mock)
		T.eq(client.count_tokens(""), 0)
		T.eq(client.count_tokens("hi"), 1)          -- ceil(2/4) = 1
		T.eq(client.count_tokens("hello"), 2)        -- ceil(5/4) = 2
		T.eq(client.count_tokens("abcdefgh"), 2)     -- ceil(8/4) = 2
		T.eq(client.count_tokens("abcdefghi"), 3)    -- ceil(9/4) = 3
	end)
end)
