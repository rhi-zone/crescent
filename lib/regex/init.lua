-- lib/regex/init.lua
-- Regex library with tier selection: PCRE2 FFI (system) > pure Lua.
--
-- Public API:
--   M.compile(pattern, flags?) -> regex, err
--   M.match(pattern, subject, init?) -> captures | nil
--   M.find(pattern, subject, init?) -> start, end_ | nil
--   M.gmatch(pattern, subject) -> iterator
--   M.gsub(pattern, subject, replacement, n?) -> result, count
--   M.split(pattern, subject) -> array
--   M._tier -> "system-pcre2" | "pure-lua"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Try system tier first (PCRE2 FFI), fall back to pure Lua.
local ok, mod = pcall(require, "lib.regex.system")
if not ok then
	-- Clear partial require cache entry so future attempts can retry.
	package.loaded["lib.regex.system"] = nil
end
local impl_raw = (ok and type(mod) == "table") and mod or require("lib.regex.pure")
local impl_u = impl_raw --[[: unknown]]
local impl_t = impl_u --[[:! { compile: unknown, match: unknown, find: unknown, gmatch: unknown, gsub: unknown, split: unknown, _tier: unknown, ... }]]

--:: RegexCompile = (pattern: string, flags: string | nil) -> (unknown, string | nil)
--:: RegexMatch = (pattern: string, subject: string, init: integer | nil) -> unknown
--:: RegexFind = (pattern: string, subject: string, init: integer | nil) -> unknown
--:: RegexGmatch = (pattern: string, subject: string) -> unknown
--:: RegexGsub = (pattern: string, subject: string, replacement: unknown, n: integer | nil) -> unknown
--:: RegexSplit = (pattern: string, subject: string) -> unknown
--:: RegexModule = {
--::     compile: RegexCompile,
--::     match:   RegexMatch,
--::     find:    RegexFind,
--::     gmatch:  RegexGmatch,
--::     gsub:    RegexGsub,
--::     split:   RegexSplit,
--::     _tier:   string,
--:: }
--: RegexModule
local M = {
	compile = impl_t.compile --[[:! RegexCompile]],
	match   = impl_t.match   --[[:! RegexMatch]],
	find    = impl_t.find    --[[:! RegexFind]],
	gmatch  = impl_t.gmatch  --[[:! RegexGmatch]],
	gsub    = impl_t.gsub    --[[:! RegexGsub]],
	split   = impl_t.split   --[[:! RegexSplit]],
	_tier   = impl_t._tier   --[[:! string]],
}

return M
