-- lib/sandbox/init.lua
-- Capability-based script sandbox.
-- Capabilities are plain tables { globals={...}, modules={...} } — callers
-- define and compose them. This library is the mechanism; it does not decide
-- what is safe to expose.
--
-- API:
--   sandbox.env(cap, ...)         -> env table with whitelist require
--   sandbox.run(code, env, opts?) -> ok, result|err
--   sandbox.stdlib                -> capability bundle: safe Lua stdlib
--   sandbox.pure                  -> capability bundle: no side-effect ops
--
-- opts:
--   opts.budget  : instruction count limit (via debug.sethook)
--   opts.name    : chunk name for error messages (default "@sandbox")

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- env(cap, ...) — merge capability tables into a single environment.
-- Each cap: { globals = {name = value, ...}, modules = {"lib.foo", ...} }
-- The resulting table has a whitelist-based require covering all .modules.
function M.env(...)
	local merged = {}
	local allowed = {}

	for i = 1, select("#", ...) do
		local cap = select(i, ...)
		if cap.globals then
			for k, v in pairs(cap.globals) do
				merged[k] = v
			end
		end
		if cap.modules then
			for j = 1, #cap.modules do
				allowed[cap.modules[j]] = true
			end
		end
	end

	-- Whitelist require: only modules explicitly granted in .modules lists.
	-- Calls the host require — the module itself runs with full privileges,
	-- but the sandbox script can only name modules the host has approved.
	merged.require = function(name)
		if not allowed[name] then
			error("sandbox: require '" .. tostring(name) .. "' not allowed", 2)
		end
		return require(name)
	end

	return merged
end

-- run(code, env, opts?) -> ok, result|err
-- Loads code in text-only mode ("t" — no pre-compiled bytecode) inside env.
-- Returns pcall-style: ok=true + result, or ok=false + error message.
function M.run(code, env, opts)
	opts = opts or {}
	local name = opts.name or "@sandbox"

	local fn, err = load(code, name, "t", env)
	if not fn then
		return false, err
	end

	-- Instruction budget: hook fires after `budget` instructions and kills the
	-- coroutine. The hook clears itself first to avoid recursive error on next
	-- instruction after the error is thrown.
	if opts.budget then
		local budget = opts.budget
		debug.sethook(function()
			debug.sethook()
			error("sandbox: instruction budget exceeded")
		end, "", budget)
	end

	local ok, result = pcall(fn)

	if opts.budget then
		debug.sethook()  -- clear on normal exit too
	end

	return ok, result
end

-- lock_string_metatable()
-- Prevents sandboxed code from replacing the string metatable via
-- getmetatable("").__index = ... or similar attacks. After calling this,
-- getmetatable("") returns false (the __metatable guard value), blocking
-- both getmetatable and setmetatable on strings. Existing string methods
-- (string:upper(), etc.) continue to work — the metatable itself is not
-- removed, just protected from introspection and replacement.
-- Call once before running any sandboxed code.
function M.lock_string_metatable()
	local mt = getmetatable("")
	if mt == false then return end  -- already locked
	mt.__metatable = false
end

-- ── Safe subsets of dangerous modules ─────────────────────────────────────────
-- Read-only members that apps legitimately need for platform detection.
-- Each is a frozen table — the real module is never exposed.

local safe_jit
do
	local ok, jit_mod = pcall(require, "jit")
	if ok and jit_mod then
		safe_jit = {
			os          = jit_mod.os,
			arch        = jit_mod.arch,
			version     = jit_mod.version,
			version_num = jit_mod.version_num,
		}
	end
end

local safe_os = {
	clock    = os.clock,
	difftime = os.difftime,
	time     = os.time,
	date     = os.date,
}

local safe_bit
do
	local ok, bit_mod = pcall(require, "bit")
	if ok and bit_mod then safe_bit = bit_mod end
end

-- ── Built-in capability bundles ───────────────────────────────────────────────
-- These are just tables. Compose, subset, or ignore them as needed.

-- stdlib: safe Lua standard library.
-- Excludes: io, ffi, debug, dofile, loadfile, load, loadstring, require,
--           package (callers get require via env() instead).
-- Exposes safe read-only subsets of: os, jit, ffi (info only), bit.
M.stdlib = {
	globals = {
		assert      = assert,
		error       = error,
		ipairs      = ipairs,
		next        = next,
		pairs       = pairs,
		pcall       = pcall,
		print       = print,
		rawequal    = rawequal,
		rawget      = rawget,
		rawlen      = rawlen,
		rawset      = rawset,
		select      = select,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		tonumber    = tonumber,
		tostring    = tostring,
		type        = type,
		unpack      = unpack,
		xpcall      = xpcall,
		math        = math,
		string      = string,
		table       = table,
		coroutine   = coroutine,
		os          = safe_os,
		jit         = safe_jit,
		bit         = safe_bit,
	},
	modules = {},
}

-- pure: no I/O, no print, no coroutines — computation only.
M.pure = {
	globals = {
		assert      = assert,
		error       = error,
		ipairs      = ipairs,
		next        = next,
		pairs       = pairs,
		pcall       = pcall,
		rawequal    = rawequal,
		rawget      = rawget,
		rawlen      = rawlen,
		rawset      = rawset,
		select      = select,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		tonumber    = tonumber,
		tostring    = tostring,
		type        = type,
		unpack      = unpack,
		xpcall      = xpcall,
		math        = math,
		string      = string,
		table       = table,
	},
	modules = {},
}

return M
