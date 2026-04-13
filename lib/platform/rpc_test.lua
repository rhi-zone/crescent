-- lib/platform/rpc_test.lua
-- Tests for lib/platform/rpc (cap bridging RPC dispatcher).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local rpc  = require("lib.platform.rpc")
local json = require("lib.json")

-- ── Mock caps ────────────────────────────────────────────────────────────────

local function make_mock_caps()
	return {
		llm = {
			call = function(messages)
				if not messages or #messages == 0 then
					return nil, "empty messages"
				end
				return "Hello from LLM"
			end,
			count_tokens = function(text)
				return math.ceil(#text / 4)
			end,
		},
		kv = {
			get = function(key)
				if key == "exists" then return "value" end
				return nil  -- not found, NOT an error
			end,
			set = function(key, value)
				-- no-op in mock
			end,
		},
		throws = {
			boom = function()
				error("kaboom!")
			end,
		},
	}
end

-- Helper: dispatch a request table
local function call(dispatch, req)
	local status, body = dispatch(json.encode(req))
	local parsed = json.decode(body)
	return status, parsed
end

-- ── Tests ────────────────────────────────────────────────────────────────────

T.describe("platform.rpc", function()

	T.describe("successful calls", function()

		T.it("dispatches llm.call with args and returns result", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "llm", method = "call",
				args = { { { role = "user", content = "hi" } } },
			})
			T.eq(status, 200)
			T.eq(res.result, "Hello from LLM")
			T.eq(res.error, nil)
		end)

		T.it("dispatches llm.count_tokens", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "llm", method = "count_tokens",
				args = { "hello world" },
			})
			T.eq(status, 200)
			T.eq(res.result, 3) -- ceil(11/4)
		end)

		T.it("kv.get returns value for existing key", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "kv", method = "get", args = { "exists" },
			})
			T.eq(status, 200)
			T.eq(res.result, "value")
		end)

		T.it("kv.get returns null for missing key (not an error)", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, body_str = dispatch(json.encode({
				cap = "kv", method = "get", args = { "missing" },
			}))
			T.eq(status, 200)
			-- kv.get("missing") returns nil (single return, no error string)
			-- Response should be {"result":null}
			T.ok(body_str:find('"result"', 1, true), "should have result key")
			T.ok(body_str:find("null", 1, true), "result should be null")
			-- Should NOT have error key
			T.eq(body_str:find('"error"', 1, true), nil)
		end)

		T.it("kv.set with no return value", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, body_str = dispatch(json.encode({
				cap = "kv", method = "set", args = { "key", "val" },
			}))
			T.eq(status, 200)
			T.ok(body_str:find("null", 1, true), "void return → null result")
		end)

		T.it("call with no args", function()
			local caps = { test = { noop = function() return "ok" end } }
			local dispatch = rpc.make_dispatcher(caps)
			local status, res = call(dispatch, { cap = "test", method = "noop" })
			T.eq(status, 200)
			T.eq(res.result, "ok")
		end)

	end)

	T.describe("nil + error convention", function()

		T.it("returns error when cap returns nil, errmsg", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "llm", method = "call", args = { {} },
			})
			T.eq(status, 200) -- not an HTTP error — the call executed
			T.eq(res.error, "empty messages")
			T.eq(res.result, nil)
		end)

	end)

	T.describe("cap throws", function()

		T.it("returns 500 with error message when cap throws", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "throws", method = "boom",
			})
			T.eq(status, 500)
			T.ok(type(res.error) == "string", "should have error string")
			T.ok(res.error:find("kaboom", 1, true) ~= nil, "error should contain original message")
		end)

	end)

	T.describe("validation errors", function()

		T.it("rejects invalid JSON", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, body_str = dispatch("not json{{{")
			T.eq(status, 400)
			local res = json.decode(body_str)
			T.ok(res.error:find("invalid JSON", 1, true) ~= nil)
		end)

		T.it("rejects missing cap name", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, { method = "call" })
			T.eq(status, 400)
			T.ok(res.error:find("missing cap or method", 1, true) ~= nil)
		end)

		T.it("rejects missing method name", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, { cap = "llm" })
			T.eq(status, 400)
			T.ok(res.error:find("missing cap or method", 1, true) ~= nil)
		end)

		T.it("rejects non-string args", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "llm", method = "call", args = "not-array",
			})
			T.eq(status, 400)
			T.ok(res.error:find("args must be", 1, true) ~= nil)
		end)

		T.it("returns 404 for unknown cap", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "nosuch", method = "call",
			})
			T.eq(status, 404)
			T.ok(res.error:find("unknown cap", 1, true) ~= nil)
		end)

		T.it("returns 404 for unknown method", function()
			local dispatch = rpc.make_dispatcher(make_mock_caps())
			local status, res = call(dispatch, {
				cap = "llm", method = "nosuch",
			})
			T.eq(status, 404)
			T.ok(res.error:find("unknown method", 1, true) ~= nil)
		end)

	end)

	T.describe("result types", function()

		T.it("handles table result", function()
			local caps = { t = { get = function() return { a = 1, b = "two" } end } }
			local dispatch = rpc.make_dispatcher(caps)
			local status, res = call(dispatch, { cap = "t", method = "get" })
			T.eq(status, 200)
			T.eq(res.result.a, 1)
			T.eq(res.result.b, "two")
		end)

		T.it("handles numeric result", function()
			local caps = { t = { num = function() return 42 end } }
			local dispatch = rpc.make_dispatcher(caps)
			local status, res = call(dispatch, { cap = "t", method = "num" })
			T.eq(status, 200)
			T.eq(res.result, 42)
		end)

		T.it("handles boolean result", function()
			local caps = { t = { flag = function() return true end } }
			local dispatch = rpc.make_dispatcher(caps)
			local status, res = call(dispatch, { cap = "t", method = "flag" })
			T.eq(status, 200)
			T.eq(res.result, true)
		end)

		T.it("handles array result", function()
			local caps = { t = { list = function() return { "a", "b", "c" } end } }
			local dispatch = rpc.make_dispatcher(caps)
			local status, res = call(dispatch, { cap = "t", method = "list" })
			T.eq(status, 200)
			T.eq(#res.result, 3)
			T.eq(res.result[1], "a")
		end)

	end)

end)
