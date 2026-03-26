local T = require("lib.test.assert")
local json = require("lib.format.json")

local describe, it = T.describe, T.it

-- ── Mock provider ──────────────────────────────────────────────────────────────

local function make_mock_provider(opts)
	opts = opts or {}
	return {
		generate = function(req)
			if opts.generate_err then return nil, opts.generate_err end
			return {
				text = opts.generate_text or "mock response",
				tool_calls = opts.generate_tool_calls,
				finish_reason = "stop",
				usage = { input_tokens = 10, output_tokens = 5 },
			}
		end,
		stream = function(req)
			if opts.stream_err then return nil, opts.stream_err end
			local deltas = opts.stream_deltas or {
				{ text = "hel" },
				{ text = "lo" },
				{ finish_reason = "stop" },
			}
			local i = 0
			return function()
				i = i + 1
				return deltas[i]
			end
		end,
	}
end

-- ── Provider resolution ────────────────────────────────────────────────────────

describe("ai", function()
	local ai = require("lib.ai")

	describe("provider resolution", function()
		it("should parse provider:model prefix", function()
			local mock = make_mock_provider()
			ai.register("testprov", mock)
			local res, err = ai.generate({
				model = "testprov:test-model",
				messages = { { role = "user", content = "hi" } },
			})
			T.ok(res, "response returned")
			T.eq(res.text, "mock response")
		end)

		it("should use explicit provider table", function()
			local mock = make_mock_provider({ generate_text = "custom" })
			local res = ai.generate({
				model = "anything",
				messages = { { role = "user", content = "hi" } },
				provider = mock,
			})
			T.ok(res)
			T.eq(res.text, "custom")
		end)

		it("should return error for unknown provider", function()
			local res, err = ai.generate({
				model = "nonexistent:model",
				messages = { { role = "user", content = "hi" } },
			})
			T.eq(res, nil)
			T.ok(err:find("unknown provider"), "error mentions unknown provider")
		end)
	end)

	describe("generate", function()
		it("should return ai_response fields", function()
			local mock = make_mock_provider({
				generate_text = "hello world",
				generate_tool_calls = nil,
			})
			ai.register("mock", mock)
			local res = ai.generate({
				model = "mock:m1",
				messages = { { role = "user", content = "hi" } },
			})
			T.ok(res)
			T.eq(res.text, "hello world")
			T.eq(res.finish_reason, "stop")
			T.eq(res.usage.input_tokens, 10)
			T.eq(res.usage.output_tokens, 5)
		end)

		it("should propagate provider errors", function()
			local mock = make_mock_provider({ generate_err = "rate limited" })
			ai.register("errmock", mock)
			local res, err = ai.generate({
				model = "errmock:m1",
				messages = { { role = "user", content = "hi" } },
			})
			T.eq(res, nil)
			T.eq(err, "rate limited")
		end)

		it("should return tool calls", function()
			local mock = make_mock_provider({
				generate_tool_calls = {
					{ id = "tc1", name = "get_weather", arguments = { city = "NYC" } },
				},
			})
			ai.register("toolmock", mock)
			local res = ai.generate({
				model = "toolmock:m1",
				messages = { { role = "user", content = "weather?" } },
				tools = { { name = "get_weather", description = "Get weather", parameters = {} } },
			})
			T.ok(res)
			T.ok(res.tool_calls)
			T.eq(#res.tool_calls, 1)
			T.eq(res.tool_calls[1].name, "get_weather")
			T.eq(res.tool_calls[1].arguments.city, "NYC")
		end)
	end)

	describe("stream", function()
		it("should iterate deltas", function()
			local mock = make_mock_provider()
			ai.register("streammock", mock)
			local parts = {}
			for delta in ai.stream({ model = "streammock:m1", messages = { { role = "user", content = "hi" } } }) do
				if delta.text then parts[#parts + 1] = delta.text end
			end
			T.eq(table.concat(parts), "hello")
		end)

		it("should handle stream errors", function()
			local mock = make_mock_provider({ stream_err = "connection failed" })
			ai.register("streamerr", mock)
			local iter, err = ai.stream({ model = "streamerr:m1", messages = { { role = "user", content = "hi" } } })
			-- stream returns an iterator even on error; the error is the second return
			T.ok(err, "error returned")
			T.eq(err, "connection failed")
		end)
	end)
end)

-- ── Anthropic provider (requires libtls) ───────────────────────────────────────

local has_tls, anthropic = pcall(require, "lib.ai.providers.anthropic")

if has_tls then
	describe("ai/providers/anthropic", function()
		it("should require ANTHROPIC_API_KEY", function()
			if not os.getenv("ANTHROPIC_API_KEY") then
				local res, err = anthropic.generate({
					model = "claude-sonnet-4-20250514",
					messages = { { role = "user", content = "hi" } },
				})
				T.eq(res, nil)
				T.eq(err, "ANTHROPIC_API_KEY not set")
			end
		end)

		it("stream should require ANTHROPIC_API_KEY", function()
			if not os.getenv("ANTHROPIC_API_KEY") then
				local iter, err = anthropic.stream({
					model = "claude-sonnet-4-20250514",
					messages = { { role = "user", content = "hi" } },
				})
				T.eq(iter, nil)
				T.eq(err, "ANTHROPIC_API_KEY not set")
			end
		end)
	end)
end

-- ── OpenAI provider (requires libtls) ──────────────────────────────────────────

local has_tls_oai, openai = pcall(require, "lib.ai.providers.openai")

if has_tls_oai then
	describe("ai/providers/openai", function()
		it("should require OPENAI_API_KEY", function()
			if not os.getenv("OPENAI_API_KEY") then
				local res, err = openai.generate({
					model = "gpt-4o",
					messages = { { role = "user", content = "hi" } },
				})
				T.eq(res, nil)
				T.eq(err, "OPENAI_API_KEY not set")
			end
		end)
	end)
end

-- ── Tool loop ──────────────────────────────────────────────────────────────────

describe("ai/tools", function()
	local ai = require("lib.ai")
	local tools_mod = require("lib.ai.tools")

	it("should run tool loop until no more tool calls", function()
		local call_count = 0
		local mock = {
			generate = function(req)
				call_count = call_count + 1
				if call_count == 1 then
					return {
						text = nil,
						tool_calls = {
							{ id = "tc1", name = "get_weather", arguments = { city = "NYC" } },
						},
						finish_reason = "tool_use",
					}
				else
					return {
						text = "The weather in NYC is 72F",
						tool_calls = nil,
						finish_reason = "stop",
					}
				end
			end,
			stream = function() end,
		}
		ai.register("toolloop", mock)

		local handler_called = false
		local res, err = tools_mod.run({
			model = "toolloop:m1",
			messages = { { role = "user", content = "what's the weather in NYC?" } },
			tools = { { name = "get_weather", description = "Get weather", parameters = {} } },
			handlers = {
				get_weather = function(args)
					handler_called = true
					T.eq(args.city, "NYC")
					return '{"temp": 72, "unit": "F"}'
				end,
			},
		})
		T.ok(res, "final response returned")
		T.eq(res.text, "The weather in NYC is 72F")
		T.ok(handler_called, "handler was called")
		T.eq(call_count, 2)
	end)

	it("should respect max_rounds", function()
		local mock = {
			generate = function()
				return {
					tool_calls = { { id = "tc1", name = "loop", arguments = {} } },
					finish_reason = "tool_use",
				}
			end,
			stream = function() end,
		}
		ai.register("looper", mock)

		local res, err = tools_mod.run({
			model = "looper:m1",
			messages = { { role = "user", content = "loop" } },
			tools = { { name = "loop", description = "Loop", parameters = {} } },
			handlers = { loop = function() return "{}" end },
			max_rounds = 3,
		})
		T.eq(res, nil)
		T.eq(err, "max rounds exceeded")
	end)

	it("should handle unknown tool gracefully", function()
		local call_count = 0
		local mock = {
			generate = function(req)
				call_count = call_count + 1
				if call_count == 1 then
					return {
						tool_calls = { { id = "tc1", name = "unknown_tool", arguments = {} } },
						finish_reason = "tool_use",
					}
				else
					return { text = "ok", finish_reason = "stop" }
				end
			end,
			stream = function() end,
		}
		ai.register("unk", mock)

		local res = tools_mod.run({
			model = "unk:m1",
			messages = { { role = "user", content = "test" } },
			tools = {},
			handlers = {},
		})
		T.ok(res)
		T.eq(res.text, "ok")
	end)

	it("should handle handler errors gracefully", function()
		local call_count = 0
		local mock = {
			generate = function(req)
				call_count = call_count + 1
				if call_count == 1 then
					return {
						tool_calls = { { id = "tc1", name = "boom", arguments = {} } },
						finish_reason = "tool_use",
					}
				else
					return { text = "recovered", finish_reason = "stop" }
				end
			end,
			stream = function() end,
		}
		ai.register("errtool", mock)

		local res = tools_mod.run({
			model = "errtool:m1",
			messages = { { role = "user", content = "test" } },
			tools = { { name = "boom", description = "Boom", parameters = {} } },
			handlers = { boom = function() error("kaboom") end },
		})
		T.ok(res)
		T.eq(res.text, "recovered")
	end)
end)

-- ── Live tests (gated on env vars) ────────────────────────────────────────────

if has_tls and os.getenv("ANTHROPIC_API_KEY") then
	describe("ai/live/anthropic", function()
		local ai = require("lib.ai")

		it("should generate a response", function()
			local res, err = ai.generate({
				model = "anthropic:claude-sonnet-4-20250514",
				messages = { { role = "user", content = "Say exactly: hello" } },
				max_tokens = 32,
			})
			T.ok(res, "response: " .. tostring(err))
			T.ok(res.text, "has text")
			T.ok(#res.text > 0, "text not empty")
		end)

		it("should stream a response", function()
			local parts = {}
			for delta in ai.stream({
				model = "anthropic:claude-sonnet-4-20250514",
				messages = { { role = "user", content = "Say exactly: hi" } },
				max_tokens = 32,
			}) do
				if delta.text then parts[#parts + 1] = delta.text end
			end
			T.ok(#parts > 0, "got streaming deltas")
			local full = table.concat(parts)
			T.ok(#full > 0, "concatenated text not empty")
		end)
	end)
end
