local path = require("lib.path")
local mimetype_by_name = require("lib.mimetype.by_name").mimetype
local urldecode = require("lib.encode.urlencode").urlencode_to_string
local urlencode = require("lib.encode.urlencode").string_to_urlencode
local dir_list = require("lib.fs.dir_list").dir_list
local mimetype_by_contents

local mod = {}

--:: StaticFullHandlerFn = (req: { path: string, target: string, headers: { [string]: unknown }, ... }, res: { body: string | nil, status: integer, headers: { [string]: unknown }, ... }) -> nil
--: (string) -> string | nil
local system_specific_mime_type = function (file_path) end

if jit.os == "Linux" then
	local ffi = require("ffi")
	ffi.cdef [[ ssize_t getxattr(const char *path, const char *name, void *value, size_t size); ]]
	local buf = ffi.new("char[128]") --[[:! cdata]]
	-- TODO: cdef-derived ffi.C.getxattr type doesn't unify with normal call shape; cast at FFI boundary.
	local getxattr = ffi.C.getxattr --[[:! (string, string, cdata, integer) -> integer]]

	system_specific_mime_type = function (file_path)
		local size = getxattr(file_path, "user.Content-Type", buf, 128)
		if size ~= -1 then return ffi.string(buf, size) end
		size = getxattr(file_path, "user.mime_type", buf, 128)
		if size ~= -1 then return ffi.string(buf, size) end
	end
end

--: (integer | nil) -> string
local human_readable_size = function (size)
	if not size then return "" end
	if size < 1024 then
		return size .. " B"
	elseif size < 1048576 then
		return string.format("%.1f kiB", size / 1024)
	elseif size < 1073741824 then
		return string.format("%.1f MiB", size / 1048576)
	elseif size < 1099511627776 then
		return string.format("%.1f GiB", size / 1073741824)
	else
		return string.format("%.1f TiB", size / 1099511627776)
	end
end

--[[FIXME: refactor out]]
local html_escape_lookup = {
	["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\""] = "&quot;", ["'"] = "&#039;",
}

--: (string) -> string
local html_escape = function (string)
	local result, _ = string:gsub("[&<>\"']", html_escape_lookup)
	return result
end

--:: FileHandle = { read: (self: unknown, string) -> string | nil, close: (self: unknown) -> nil }
--: (base: string | nil, opts: { io_open: (string, string) -> (FileHandle | nil, string | nil), os_date: (string, integer) -> string } | nil) -> StaticFullHandlerFn | (nil, string)
mod.router = function (base, opts)
	if base ~= nil and type(base) ~= "string" then
		return nil, "static() expects string as base path, got " .. tostring(base)
	end
	local io_open = opts and opts.io_open
	if not io_open then return nil, "static() requires opts.io_open cap" end
	local os_date = opts and opts.os_date
	if not os_date then return nil, "static() requires opts.os_date cap" end
	base = (base or "."):gsub("/$", "")
	return function (req, res)
		--[[TODO: urldecode? urldecode(req.path)]]
		local full_path = path.safe_resolve(base, urldecode(req.path))
		if not full_path then res.status = 404; return end
		local file = io_open(full_path, "rb")
		if file == nil then res.status = 404; return end
		res.status = 200
		res.body = file:read("*all")
		file:close()
		if res.body == nil then
			local full_path_s = full_path --[[: string]]
			local dir_path = full_path_s:gsub("/$", "")
			local file2 = io_open(dir_path .. "/index.html", "rb")
			if file2 then
				res.body = file2:read("*all")
				file2:close()
			end
		end
		if res.body == nil then
			--[[probably a directory]]
			local iter, dir = dir_list(full_path)
			if dir then
				res.headers["Content-Type"] = { "text/html" }
				local parts = {}
				parts[#parts+1] = [[<!DOCTYPE html><html><head><meta charset="utf-8"><title>Index of ]] .. html_escape(full_path) .. "</title></head><body><table><thead><tr><th>Name</th><th>Size</th><th>Created</th><th>Last modified</th></tr></thead><tbody><h1>Index of " .. html_escape(full_path) .. "</h1><a href=\"..\">[up one level]</a>"
				for file_info in iter, dir do
					--[[TODO: consider adding sorting (via js)]]
					local slash = (file_info.is_dir and "/" or "")
					parts[#parts+1] = "<tr><td><a href=\"" .. urlencode(file_info.name) .. slash .. "\">" .. html_escape(file_info.name) ..
						slash .. "</a></td><td data-value=\"" .. (file_info.is_dir and "" or file_info.size or "") .. "\">" .. (file_info.is_dir and "" or human_readable_size(file_info.size)) ..
						-- "</td><td data-value=\"" .. (file_info.created or "") .. "\">" .. (file_info.created and os_date("%x %X", file_info.created) or "") ..
						"</td><td data-value=\"" .. (file_info.modified or "") .. "\">" .. (file_info.modified and os_date("%x %X", file_info.modified) or "") .. "</td></tr>"
				end
				parts[#parts+1] = "</tbody></table></body>"
				res.body = table.concat(parts)
			else res.status = 404 end
			return
		end
		local ct = system_specific_mime_type(full_path) or mimetype_by_name(req.path)
		if not ct then
			mimetype_by_contents = mimetype_by_contents or require("lib.mimetype.by_contents").mimetype
			ct = mimetype_by_contents(res.body)
		end
		if ct then res.headers["Content-Type"] = { ct } end
	end
end

return mod
