-- lib/platform/runtime_test.lua
-- Tests for lib/platform/runtime (browser-side cap proxy generation).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local runtime = require("lib.platform.runtime")

-- ── Tests ────────────────────────────────────────────────────────────────────

T.describe("platform.runtime", function()

	T.it("generates valid JavaScript for empty caps", function()
		local js = runtime.generate({})
		T.ok(type(js) == "string", "should return a string")
		T.ok(#js > 0, "should not be empty")
		T.ok(js:find("export const caps", 1, true) ~= nil, "should export caps")
	end)

	T.it("includes cap name and method names", function()
		local caps = {
			llm = {
				call = function() end,
				count_tokens = function() end,
			},
		}
		local js = runtime.generate(caps)
		T.ok(js:find("llm:", 1, true) ~= nil, "should include llm cap")
		T.ok(js:find("call:", 1, true) ~= nil, "should include call method")
		T.ok(js:find("count_tokens:", 1, true) ~= nil, "should include count_tokens method")
	end)

	T.it("includes multiple caps sorted alphabetically", function()
		local caps = {
			kv  = { get = function() end, set = function() end },
			llm = { call = function() end },
		}
		local js = runtime.generate(caps)
		-- kv should appear before llm alphabetically
		local kv_pos = js:find("kv:", 1, true)
		local llm_pos = js:find("llm:", 1, true)
		T.ok(kv_pos ~= nil, "should include kv cap")
		T.ok(llm_pos ~= nil, "should include llm cap")
		T.ok(kv_pos < llm_pos, "kv should appear before llm (sorted)")
	end)

	T.it("methods within a cap are sorted alphabetically", function()
		local caps = {
			kv = { set = function() end, get = function() end },
		}
		local js = runtime.generate(caps)
		local get_pos = js:find("get:", 1, true)
		local set_pos = js:find("set:", 1, true)
		T.ok(get_pos < set_pos, "get should appear before set (sorted)")
	end)

	T.it("skips non-function values in cap tables", function()
		local caps = {
			mixed = {
				method = function() end,
				data = "not a function",
				count = 42,
			},
		}
		local js = runtime.generate(caps)
		T.ok(js:find("method:", 1, true) ~= nil, "should include method")
		-- data and count should not appear as proxied methods
		T.ok(js:find("data:", 1, true) == nil, "should not include string data")
		T.ok(js:find("count:", 1, true) == nil, "should not include number data")
	end)

	T.it("skips non-table caps", function()
		local caps = {
			llm = { call = function() end },
			version = "1.0.0",
		}
		local js = runtime.generate(caps)
		T.ok(js:find("llm:", 1, true) ~= nil, "should include llm")
		T.ok(js:find("version:", 1, true) == nil, "should not include string value as cap")
	end)

	T.it("includes the rpc helper function", function()
		local js = runtime.generate({ t = { f = function() end } })
		T.ok(js:find("async function rpc", 1, true) ~= nil, "should include rpc function")
		T.ok(js:find("fetch('/api/cap'", 1, true) ~= nil, "should fetch /api/cap")
	end)

	T.it("method proxies pass cap and method names as strings", function()
		local caps = { llm = { call = function() end } }
		local js = runtime.generate(caps)
		T.ok(js:find("'llm'", 1, true) ~= nil, "should pass 'llm' string")
		T.ok(js:find("'call'", 1, true) ~= nil, "should pass 'call' string")
	end)

	T.it("generates deterministic output", function()
		local caps = {
			kv  = { get = function() end, set = function() end },
			llm = { call = function() end },
		}
		local js1 = runtime.generate(caps)
		local js2 = runtime.generate(caps)
		T.eq(js1, js2, "output should be identical across calls")
	end)

end)
