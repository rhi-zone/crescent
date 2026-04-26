-- lib/platform/caps/llm/llm_test.lua
-- Tests for the llm cap.
-- No live API calls — lib/ai/ providers are mocked via ai.register().

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local llm = require("lib.platform.caps.llm")
local ai  = require("lib.ai")

-- Stub http_client — the llm cap validates its presence, but mock providers
-- never actually invoke request/stream, so a table with the right shape is
-- sufficient for these tests.
local stub_http_client = {
	request = function(_req) return nil, "stub http_client: not implemented" end,
	stream  = function(_req) return nil, "stub http_client: not implemented" end,
}

-- ── Mock provider helpers ─────────────────────────────────────────────────────

-- make_mock_provider returns a provider table compatible with lib/ai/'s provider
-- interface: { generate(req) -> (ai_response|nil, err), stream(req) -> (iter|nil, err) }
local function make_mock_provider(text_result, stream_tokens)
	local p = {}

	function p.generate(_req)
		if text_result == nil then
			return nil, "mock: generate error"
		end
		return { text = text_result }
	end

	function p.stream(_req)
		local tokens = stream_tokens or { "hello", " ", "world" }
		local i = 0
		local function iter()
			i = i + 1
			if i > #tokens then return nil end
			return { text = tokens[i] }
		end
		return iter
	end

	return p
end

-- with_mock_provider(name, mock_fn, fn) registers mock under name, calls fn(),
-- then removes it. Returns results of fn().
local function with_mock_provider(name, mock, fn)
	ai.register(name, mock)
	local ok, a, b, c = pcall(fn)
	-- Remove mock by registering nil (ai has no unregister, but registering nil
	-- clears the slot — we use a sentinel key unlikely to be re-used).
	-- Actually just leave it; it's test-scoped and won't affect other providers.
	if not ok then error(a, 2) end
	return a, b, c
end

-- ── Cap factory tests ─────────────────────────────────────────────────────────

T.describe("llm_cap factory", function()
	T.it("returns nil,err for missing provider", function()
		local cap, err = llm.llm_cap({})
		T.eq(cap, nil)
		T.ok(type(err) == "string" and err:find("provider") ~= nil,
		     "expected error mentioning provider, got: " .. tostring(err))
	end)

	T.it("returns nil,err for missing http_client", function()
		local cap, err = llm.llm_cap({ provider = "somep", key = "k" })
		T.eq(cap, nil)
		T.ok(type(err) == "string" and err:find("http_client") ~= nil,
		     "expected error mentioning http_client, got: " .. tostring(err))
	end)

	T.it("returns cap and revoke function when provider is valid", function()
		local mock = make_mock_provider("ok")
		with_mock_provider("mock_valid", mock, function()
			local cap, revoke = llm.llm_cap({ provider = "mock_valid", key = "k", http_client = stub_http_client })
			T.ok(cap ~= nil, "cap should not be nil")
			T.ok(type(revoke) == "function", "revoke should be a function")
		end)
	end)
end)

-- ── cap.call tests ────────────────────────────────────────────────────────────

T.describe("cap.call", function()
	T.it("returns content string on success", function()
		local mock = make_mock_provider("The answer is 42.")
		with_mock_provider("mock_call", mock, function()
			local cap, _ = llm.llm_cap({ provider = "mock_call", key = "k", model = "m", http_client = stub_http_client })
			local msgs = { { role = "user", content = "What is the answer?" } }
			local content, err = cap.call(msgs)
			T.eq(err, nil)
			T.eq(content, "The answer is 42.")
		end)
	end)

	T.it("propagates error from provider", function()
		local mock = make_mock_provider(nil)  -- nil triggers error path
		with_mock_provider("mock_call_err", mock, function()
			local cap, _ = llm.llm_cap({ provider = "mock_call_err", key = "k", http_client = stub_http_client })
			local content, err = cap.call({ { role = "user", content = "hi" } })
			T.eq(content, nil)
			T.ok(err ~= nil, "expected error from mock provider")
		end)
	end)

	T.it("passes model from opts", function()
		local received_model
		local p = {}
		function p.generate(req) received_model = req.model; return { text = "ok" } end
		function p.stream(_req) return function() return nil end end
		ai.register("mock_model_check", p)

		local cap, _ = llm.llm_cap({ provider = "mock_model_check", key = "k", model = "gpt-4o", http_client = stub_http_client })
		cap.call({ { role = "user", content = "hi" } })
		T.eq(received_model, "gpt-4o")
	end)

	T.it("call_opts model overrides opts.model", function()
		local received_model
		local p = {}
		function p.generate(req) received_model = req.model; return { text = "ok" } end
		function p.stream(_req) return function() return nil end end
		ai.register("mock_model_override", p)

		local cap, _ = llm.llm_cap({ provider = "mock_model_override", key = "k", model = "default", http_client = stub_http_client })
		cap.call({ { role = "user", content = "hi" } }, { model = "override" })
		T.eq(received_model, "override")
	end)
end)

-- ── cap.call_stream tests ─────────────────────────────────────────────────────

T.describe("cap.call_stream", function()
	T.it("calls on_token for each delta and returns full content", function()
		local mock = make_mock_provider("_", { "foo", "bar", "baz" })
		with_mock_provider("mock_stream", mock, function()
			local cap, _ = llm.llm_cap({ provider = "mock_stream", key = "k", http_client = stub_http_client })
			local received = {}
			local msgs = { { role = "user", content = "stream test" } }
			local full, err = cap.call_stream(msgs, function(tok)
				received[#received + 1] = tok
			end)
			T.eq(err, nil)
			T.eq(full, "foobarbaz")
			T.eq(#received, 3)
			T.eq(received[1], "foo")
			T.eq(received[2], "bar")
			T.eq(received[3], "baz")
		end)
	end)

	T.it("skips empty-text deltas without calling on_token", function()
		local p = {}
		function p.generate(_req) return { text = "" } end
		function p.stream(_req)
			local seq = { { text = "" }, { text = "hi" }, { text = "" }, { text = "!" } }
			local i = 0
			return function()
				i = i + 1
				return seq[i]
			end
		end
		ai.register("mock_empty_delta", p)

		local cap, _ = llm.llm_cap({ provider = "mock_empty_delta", key = "k", http_client = stub_http_client })
		local calls = 0
		local full, err = cap.call_stream(
			{ { role = "user", content = "x" } },
			function(_tok) calls = calls + 1 end
		)
		T.eq(err, nil)
		T.eq(full, "hi!")
		T.eq(calls, 2)  -- only "hi" and "!" triggered on_token
	end)
end)

-- ── cap.count_tokens tests ────────────────────────────────────────────────────

T.describe("cap.count_tokens", function()
	T.it("returns positive integer estimate", function()
		local mock = make_mock_provider("_")
		with_mock_provider("mock_tokens", mock, function()
			local cap, _ = llm.llm_cap({ provider = "mock_tokens", key = "k", http_client = stub_http_client })
			local n = cap.count_tokens("hello world")
			T.ok(type(n) == "number" and n > 0,
			     "expected positive integer, got: " .. tostring(n))
		end)
	end)

	T.it("empty string returns 0", function()
		local mock = make_mock_provider("_")
		with_mock_provider("mock_tokens_empty", mock, function()
			local cap, _ = llm.llm_cap({ provider = "mock_tokens_empty", key = "k", http_client = stub_http_client })
			local n = cap.count_tokens("")
			T.eq(n, 0)
		end)
	end)
end)

-- ── Revocation tests ──────────────────────────────────────────────────────────

T.describe("revocation", function()
	T.it("all calls return nil,'capability revoked' after revoke()", function()
		local mock = make_mock_provider("should not be seen")
		with_mock_provider("mock_revoke", mock, function()
			local cap, revoke = llm.llm_cap({ provider = "mock_revoke", key = "k", http_client = stub_http_client })
			T.ok(cap ~= nil)
			T.ok(type(revoke) == "function")

			revoke()

			local content, err = cap.call({ { role = "user", content = "hi" } })
			T.eq(content, nil)
			T.eq(err, "capability revoked")

			local full, serr = cap.call_stream(
				{ { role = "user", content = "hi" } },
				function() end
			)
			T.eq(full, nil)
			T.eq(serr, "capability revoked")

			local n, nerr = cap.count_tokens("text")
			T.eq(n, nil)
			T.eq(nerr, "capability revoked")
		end)
	end)
end)

-- ── M.new (structured-output cap) tests ───────────────────────────────────────

-- Build a mock http_client.request function that returns a canned OpenAI
-- completion response. content is the string placed in choices[1].message.content.
local json = require("lib.format.json")

local function make_mock_http_client(content_str, status)
	status = status or 200
	local body = json.encode({
		choices = {
			{
				message = { role = "assistant", content = content_str },
				finish_reason = "stop",
			},
		},
		usage = { prompt_tokens = 10, completion_tokens = 5 },
	})
	return {
		request = function(_req)
			if status ~= 200 then
				return { status = status, headers = {}, body = "error" }
			end
			return { status = 200, headers = {}, body = body }
		end,
	}
end

T.describe("M.new — basic generate (no schema)", function()
	T.it("returns {text=content} on success", function()
		local http_client = make_mock_http_client("hello world")
		local cap, _ = llm.new({ http_client = http_client })
		local result, err = cap.generate({ messages = { { role = "user", content = "hi" } } })
		T.eq(err, nil)
		T.ok(type(result) == "table", "result should be a table")
		T.eq(result.text, "hello world")
	end)

	T.it("propagates HTTP errors", function()
		local http_client = make_mock_http_client("internal server error", 500)
		local cap, _ = llm.new({ http_client = http_client })
		local result, err = cap.generate({ messages = { { role = "user", content = "hi" } } })
		T.eq(result, nil)
		T.ok(type(err) == "string" and err:find("500") ~= nil,
		     "expected HTTP 500 error, got: " .. tostring(err))
	end)

	T.it("returns nil,err when http_client is missing", function()
		local cap, _ = llm.new({})
		local result, err = cap.generate({ messages = { { role = "user", content = "hi" } } })
		T.eq(result, nil)
		T.ok(type(err) == "string" and err:find("http_client") ~= nil,
		     "expected http_client error, got: " .. tostring(err))
	end)
end)

T.describe("M.new — generate with schema", function()
	T.it("returns decoded JSON table when content matches schema", function()
		local payload = json.encode({ name = "Alice", age = 30 })
		local http_client = make_mock_http_client(payload)
		local schema = {
			type = "object",
			properties = {
				name = { type = "string" },
				age  = { type = "integer" },
			},
			required = { "name", "age" },
		}
		local cap, _ = llm.new({ http_client = http_client })
		local result, err = cap.generate({
			messages = { { role = "user", content = "generate person" } },
			schema   = schema,
		})
		T.eq(err, nil)
		T.ok(type(result) == "table", "result should be a table")
		T.eq(result.name, "Alice")
		T.eq(result.age, 30)
	end)

	T.it("returns nil,err when required field is missing", function()
		-- Response is missing the required 'age' field.
		local payload = json.encode({ name = "Bob" })
		local http_client = make_mock_http_client(payload)
		local schema = {
			type     = "object",
			required = { "name", "age" },
		}
		local cap, _ = llm.new({ http_client = http_client })
		local result, err = cap.generate({
			messages = { { role = "user", content = "generate person" } },
			schema   = schema,
		})
		T.eq(result, nil)
		T.ok(type(err) == "string" and err:find("age") ~= nil,
		     "expected validation error mentioning 'age', got: " .. tostring(err))
	end)

	T.it("returns nil,err when content is not valid JSON", function()
		local http_client = make_mock_http_client("this is not json")
		local schema = { type = "object", required = { "foo" } }
		local cap, _ = llm.new({ http_client = http_client })
		local result, err = cap.generate({
			messages = { { role = "user", content = "hi" } },
			schema   = schema,
		})
		T.eq(result, nil)
		T.ok(type(err) == "string", "expected error string, got: " .. tostring(err))
	end)
end)

T.describe("M.new — revocation", function()
	T.it("generate returns nil,'capability revoked' after revoke()", function()
		local http_client = make_mock_http_client("hello")
		local cap, revoke = llm.new({ http_client = http_client })
		revoke()
		local result, err = cap.generate({ messages = { { role = "user", content = "hi" } } })
		T.eq(result, nil)
		T.eq(err, "capability revoked")
	end)
end)
