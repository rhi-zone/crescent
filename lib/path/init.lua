local ffi = require("ffi")
ffi.cdef [[
	char *realpath(const char *path, char *resolved_path);
	void free(void *ptr);
]]

local mod = {}

--[[resolve path segments textually (eliminates `.` and `..`)]]
--[[@param base string]]
--[[@param path string]]
mod.resolve = function (base, path)
	base = base:gsub("/$", "")
	--[[@type string]]
	if path:byte(1) == 0x2f --[["/"]] then path = path:sub(2) end
	local path_parts = {base} --[[@type string[] ]]
	local path_it = path:gmatch("([^/]+)")
	while true do
		local part = path_it()
		if not part then break end
		if part == ".." then if #path_parts > 1 then path_parts[#path_parts] = nil end
		elseif part == "." then --[[ignored]]
		else path_parts[#path_parts+1] = part end
	end
	return table.concat(path_parts, "/")
end

--[[resolve path using the OS (follows symlinks, returns canonical path)]]
--[[@param path string]]
--[[@return string? resolved]]
mod.realpath = function (path)
	local buf = ffi.C.realpath(path, nil)
	if buf == nil then return nil end
	local resolved = ffi.string(buf)
	ffi.C.free(buf)
	return resolved
end

--[[resolve path and verify it stays within base (symlink-safe)]]
--[[@param base string]]
--[[@param path string]]
--[[@return string? resolved]]
mod.safe_resolve = function (base, path)
	local textual = mod.resolve(base, path)
	local real_base = mod.realpath(base)
	if not real_base then return nil end
	local real_path = mod.realpath(textual)
	if not real_path then return nil end
	if real_path:sub(1, #real_base) ~= real_base then return nil end
	local next_char = real_path:byte(#real_base + 1)
	if next_char ~= nil and next_char ~= 0x2f --[["/"]] then return nil end
	return real_path
end

return mod
