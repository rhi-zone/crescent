if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

-- The env module requires a compiled env.so native library.
-- Skip all tests if the module cannot be loaded.
local ok, env = pcall(require, "lib.env")
if not ok then
	print("SKIP lib/env/env_test.lua: env.so not available (" .. tostring(env) .. ")")
	return
end

-- ── env.env (snapshot table) ────────────────────────────────────────────────

T.describe("env.env", function()
	T.it("returns a table", function()
		local e = env.env()
		T.ok(type(e) == "table", "env() should return a table")
	end)

	T.it("contains PATH", function()
		local e = env.env()
		T.ok(e.PATH ~= nil, "PATH should be present in environment")
		T.ok(type(e.PATH) == "string", "PATH should be a string")
	end)

	T.it("contains HOME or USER", function()
		local e = env.env()
		local has = e.HOME ~= nil or e.USER ~= nil
		T.ok(has, "at least one of HOME or USER should be present")
	end)

	T.it("does not contain entries with nil keys", function()
		local e = env.env()
		for k, v in pairs(e) do
			T.ok(type(k) == "string", "key should be a string, got " .. type(k))
			T.ok(type(v) == "string", "value should be a string, got " .. type(v))
		end
	end)
end)

-- ── env.env_stateless (iterator) ────────────────────────────────────────────

T.describe("env.env_stateless", function()
	T.it("returns an iterator function", function()
		local iter, state, init = env.env_stateless()
		T.ok(type(iter) == "function", "first return should be a function")
		T.eq(state, nil, "state should be nil (stateless)")
		T.eq(init, -1, "initial index should be -1")
	end)

	T.it("yields strings containing '='", function()
		local count = 0
		for _, entry in env.env_stateless() do
			T.ok(type(entry) == "string", "entry should be a string")
			T.ok(entry:find("=", 1, true) ~= nil, "entry should contain '=': " .. entry)
			count = count + 1
			if count >= 5 then break end -- spot check, no need to exhaust
		end
		T.ok(count > 0, "should yield at least one entry")
	end)
end)
