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
if ok and type(mod) == "table" then return mod end

return require("lib.regex.pure")
