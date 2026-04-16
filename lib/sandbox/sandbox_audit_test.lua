-- lib/sandbox/sandbox_audit_test.lua
-- Regression audit: assert that sandbox.stdlib + sandbox.env do not
-- transitively expose escape-vector symbols. Every addition to sandbox.stdlib
-- must pass this audit — if a new entry leaks one of the blacklist functions,
-- this test fails.
--
-- Build-order ref: docs/daemon-isolation.md "Stdlib audit + regression test".

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.sandbox")

-- ── Blacklist: functions that must never be reachable from inside a sandbox.
-- Keyed by function identity (the real global), value is the name used in the
-- failure message. `rawequal` comparison defeats metatable-proxied aliasing.
local blacklist = {}

local function ban(fn, label)
	if fn then blacklist[fn] = label end
end

ban(require,     "require")
ban(dofile,      "dofile")
ban(load,        "load")
ban(loadstring,  "loadstring")
ban(loadfile,    "loadfile")
ban(string.dump, "string.dump")
ban(debug and debug.getinfo,     "debug.getinfo")
ban(debug and debug.getupvalue,  "debug.getupvalue")
ban(debug and debug.setupvalue,  "debug.setupvalue")
ban(debug and debug.getlocal,    "debug.getlocal")
ban(debug and debug.setlocal,    "debug.setlocal")
ban(debug and debug.getregistry, "debug.getregistry")
ban(debug and debug.sethook,     "debug.sethook")
ban(debug and debug.traceback,   "debug.traceback")
ban(os and os.execute,           "os.execute")
ban(os and os.getenv,            "os.getenv")
ban(os and os.remove,            "os.remove")
ban(os and os.exit,              "os.exit")
ban(io and io.open,              "io.open")
ban(io and io.popen,             "io.popen")
ban(io and io.read,              "io.read")
-- getfenv/setfenv: Lua 5.1/LuaJIT specifics. `getfenv(0)` returns the globals
-- table directly; reachable would completely undo the env sandbox.
ban(_G.getfenv, "getfenv")
ban(_G.setfenv, "setfenv")
-- newproxy: LuaJIT-specific. Can build userdata with arbitrary metatables,
-- useful primitive in some escape constructions. Banned defensively.
ban(_G.newproxy, "newproxy")

-- ffi module (if present on LuaJIT) — ban every member, not just the table.
local ok_ffi, ffi_mod = pcall(require, "ffi")
if ok_ffi and type(ffi_mod) == "table" then
	for k, v in pairs(ffi_mod) do
		if type(v) == "function" then ban(v, "ffi." .. k) end
	end
end

-- ── BFS: enumerate everything reachable from sandbox.stdlib.globals via
-- table indexing. Track visited tables (cycles are real — e.g. _G.package
-- self-references). Return a list of (path, value) pairs.
local function reachable(root)
	local out = {}
	local seen = {}
	local function visit(v, path)
		local tv = type(v)
		if tv == "function" then
			out[#out + 1] = { path = path, fn = v }
		elseif tv == "table" then
			if seen[v] then return end
			seen[v] = true
			for k, child in pairs(v) do
				visit(child, path .. "." .. tostring(k))
			end
		end
		-- strings / numbers / booleans / nil / userdata: leaves, skip.
	end
	visit(root, "<root>")
	return out
end

T.describe("sandbox.stdlib audit", function()
	T.it("does not transitively expose any blacklisted escape-vector function", function()
		local leaks = {}
		for _, entry in ipairs(reachable(S.stdlib)) do
			local label = blacklist[entry.fn]
			if label then
				leaks[#leaks + 1] = label .. " reachable at " .. entry.path
			end
		end
		if #leaks > 0 then
			T.fail(true, "sandbox.stdlib leaks escape vectors:\n  " .. table.concat(leaks, "\n  "))
		else
			T.ok(true)
		end
	end)

	T.it("does not transitively expose any blacklisted function via sandbox.pure", function()
		local leaks = {}
		for _, entry in ipairs(reachable(S.pure)) do
			local label = blacklist[entry.fn]
			if label then
				leaks[#leaks + 1] = label .. " reachable at " .. entry.path
			end
		end
		if #leaks > 0 then
			T.fail(true, "sandbox.pure leaks escape vectors:\n  " .. table.concat(leaks, "\n  "))
		else
			T.ok(true)
		end
	end)

	-- The stdlib blacklists `load`/`loadstring` by omission, but if `string`
	-- leaks `dump`, a sandbox script can materialise a bytecode payload —
	-- which matters iff a caller re-exposes a loader later. Assert `string`
	-- in the bundle is NOT the global string table (must be the safe copy).
	T.it("exposes a string copy, not the real string module", function()
		T.neq(S.stdlib.globals.string, string, "sandbox.stdlib.string must be a filtered copy")
		T.eq(S.stdlib.globals.string.dump, nil, "string.dump must be absent")
		T.eq(S.pure.globals.string.dump, nil, "pure string.dump must be absent")
		-- Sanity: the safe copy still works.
		T.eq(S.stdlib.globals.string.upper("abc"), "ABC")
	end)
end)

T.describe("sandbox.stdlib primitive metatables", function()
	-- Threat: if `getmetatable("")` returns a mutable table, sandboxed code
	-- can set `__index` on it and poison every string operation in every
	-- app sharing the VM. Same for number/boolean/nil (though LuaJIT gives
	-- those no metatable by default).
	--
	-- Defense: `__metatable = false` sentinel on the string metatable so
	-- `getmetatable("")` returns the sentinel and `setmetatable` on strings
	-- raises. The sandbox module sets this at load time.

	T.it("getmetatable('') returns the sentinel (not a mutable table)", function()
		local mt = getmetatable("")
		T.eq(mt, false, "expected __metatable=false sentinel, got " .. tostring(mt))
	end)

	T.it("getmetatable(0/true/nil) returns nil — no primitive metatable exposed", function()
		T.eq(getmetatable(0), nil)
		T.eq(getmetatable(true), nil)
		T.eq(getmetatable(nil), nil)
	end)

	T.it("setmetatable on a string raises (protected by __metatable sentinel)", function()
		local ok = pcall(setmetatable, "", {})
		T.fail(ok, "setmetatable on a string must not succeed")
	end)

	-- End-to-end: from INSIDE a sandbox env, the same invariants must hold.
	T.it("from inside sandbox.env, getmetatable('') still returns the sentinel", function()
		local env = S.env(S.stdlib)
		local ok, r = S.run("return getmetatable('')", env)
		T.ok(ok)
		T.eq(r, false, "sandbox-visible getmetatable('') must be the sentinel")
	end)

	T.it("from inside sandbox.env, setmetatable on a string raises", function()
		local env = S.env(S.stdlib)
		local ok = S.run("setmetatable('', {})", env)
		T.fail(ok, "sandbox-visible setmetatable on a string must fail")
	end)
end)

T.describe("sandbox.env globals access", function()
	-- Threat: sandboxed code reaches the outer globals table (_G or _ENV)
	-- and reads/writes host state. Env-based sandbox relies on these being
	-- invisible; verify it.

	T.it("_G evaluates to nil inside sandbox env", function()
		local env = S.env(S.stdlib)
		local ok, r = S.run("return _G", env)
		T.ok(ok)
		T.eq(r, nil, "expected _G invisible inside sandbox, got " .. tostring(r))
	end)

	T.it("_ENV evaluates to the env table, not the host _G", function()
		local env = S.env(S.stdlib)
		-- Under LuaJIT 5.1, _ENV is not a first-class name; under 5.2+ it
		-- would resolve to the closure's env. Either way, it must never
		-- resolve to the outer _G.
		local ok, r = S.run("return _ENV", env)
		T.ok(ok)
		T.neq(r, _G, "_ENV must not resolve to host _G")
	end)

	T.it("getfenv/setfenv are not reachable inside sandbox env", function()
		local env = S.env(S.stdlib)
		local ok1, r1 = S.run("return getfenv", env)
		T.ok(ok1); T.eq(r1, nil, "getfenv must be invisible")
		local ok2, r2 = S.run("return setfenv", env)
		T.ok(ok2); T.eq(r2, nil, "setfenv must be invisible")
	end)

	T.it("newproxy is not reachable inside sandbox env", function()
		local env = S.env(S.stdlib)
		local ok, r = S.run("return newproxy", env)
		T.ok(ok); T.eq(r, nil)
	end)
end)
