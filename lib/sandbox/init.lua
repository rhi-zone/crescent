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
		local cap = (select(i, ...) --[[:! { globals?: { [string]: unknown }, modules?: { [integer]: string }, ... }]])
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

	-- Sandbox-local package mock: lets vendored app code use the standard
	-- `if not package.path:find(...)` boilerplate without erroring, and
	-- lets require("bit") / require("jit") resolve to the safe globals.
	-- The real package.path and loaders are never exposed.
	if not merged.package then
		merged.package = {
			path    = "./?/init.lua;./?.lua",
			loaded  = { bit = merged.bit, jit = merged.jit },
			preload = {},
		}
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
	-- coroutine. The hook restores whatever hook (if any) was active before
	-- this run() call first — both to avoid a recursive error on the next
	-- instruction after the error is thrown, and so a nested sandbox.run
	-- (this run() called from inside another budgeted run() on the same
	-- thread) doesn't wipe out the outer call's budget enforcement. The prior
	-- hook is saved/restored on every exit path: normal completion below and
	-- the error path inside the hook itself, since pcall(fn) below catches
	-- that error and execution always reaches the post-pcall restore too.
	local prev_hook, prev_mask, prev_count
	if opts.budget then
		prev_hook, prev_mask, prev_count = debug.gethook()
		local budget = opts.budget
		debug.sethook(function()
			if prev_hook then
				debug.sethook(prev_hook, prev_mask, prev_count)
			else
				debug.sethook(nil, "", nil)
			end
			error("sandbox: instruction budget exceeded")
		end, "", budget)
	end

	local ok, result = pcall(fn)

	if opts.budget then
		if prev_hook then
			debug.sethook(prev_hook, prev_mask, prev_count)
		else
			debug.sethook(nil, "", nil)  -- clear hook (none was active before)
		end
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

local safe_bit
do
	local ok, bit_mod = pcall(require, "bit")
	if ok and bit_mod then safe_bit = bit_mod end
end

-- `string.dump` serialises a function to LuaJIT bytecode. Crafted bytecode
-- bypasses VM-level type checks, so bundling the real `string` table would
-- put a sandbox-escape primitive one `.dump` away. Shallow-copy without it;
-- the copy is also what the string metatable's `__index` would normally
-- dispatch through — but the metatable is frozen below, so methods like
-- `("abc"):upper()` keep working via the original `string` (the frozen
-- metatable still points there; we only withhold access to the table
-- itself from sandboxed code).
local safe_string = {}
for k, v in pairs(string) do
	if k ~= "dump" then safe_string[k] = v end
end

-- Freeze the shared string metatable at module load. Without this,
-- `getmetatable("").__index = fn` would poison every string operation in
-- every sandboxed app and in the daemon itself. After this call,
-- `getmetatable("")` returns the `__metatable` sentinel (false) and
-- `setmetatable` on strings raises — but real string methods still work
-- because LuaJIT dispatches `s:upper()` through the original metatable
-- internally, not through the user-visible `getmetatable` return.
do
	local mt = getmetatable("")
	if mt and mt.__metatable == nil then mt.__metatable = false end
end

-- ── Built-in capability bundles ───────────────────────────────────────────────
-- These are just tables. Compose, subset, or ignore them as needed.

-- stdlib: safe Lua standard library.
-- Excludes: io, os, ffi, debug, dofile, loadfile, load, loadstring, require,
--           package (callers get require via env() instead), string.dump
--           (bytecode loader → sandbox-escape primitive).
-- Exposes safe read-only subsets of: jit (platform info only), bit (pure math),
-- string (omits dump).
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
		string      = safe_string,
		table       = table,
		coroutine   = coroutine,
		jit         = safe_jit,
		bit         = safe_bit,
	},
	-- Vendored app code often does require("bit") rather than using the
	-- global directly. Allow it so that pattern works without individual
	-- apps having to declare it. "jit" is deliberately NOT in this list:
	-- env()'s whitelist require() calls the real host require() (see
	-- above), which would hand sandboxed code the actual jit module —
	-- jit.on/off toggle the JIT compiler for the whole process (every
	-- other sandbox and the host share it), jit.flush discards the
	-- global trace cache, and jit.attach registers a trace-event
	-- callback that observes ALL compiled code, not just this script.
	-- That's strictly more than the curated `globals.jit` subset above
	-- (os/arch/version only) grants, so allowing it here would silently
	-- bypass the curation. "bit" has no such gap: bit_mod is pure
	-- numeric functions (band/bor/bxor/bnot/shifts/rol/ror/tobit/tohex/
	-- bswap) with no shared state, no callbacks, and no introspection,
	-- so the real module and the "safe" subset are the same thing.
	modules = { "bit" },
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
		string      = safe_string,
		table       = table,
	},
	modules = {},
}

return M
