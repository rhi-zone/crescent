-- ideally: path based but with $seg -> param.seg
-- currently: path based copy of staticx_router
local table_router = require("lib.http.router.table_glob").router
local dir_list = require("lib.fs.dir_list").dir_list
local mimetype_by_name = require("lib.mimetype.by_name").mimetype
local mimetype_by_contents

local mod = {}

--:: FsRouterOpts = { io_open: (path: string, mode: string | nil) -> any, stderr_write: (...string) -> nil, lua_load: (path: string) -> (boolean, any) }
--: (string | nil, FsRouterOpts | nil) -> (any)
mod.router = function (path, opts)
	if not opts then error("fs_router() requires opts with io_open, stderr_write, lua_load caps") end
	local opts_ = opts --[[:! FsRouterOpts]]
	local io_open = opts_.io_open
	if not io_open then error("fs_router() requires opts.io_open cap") end
	local io_open_ = io_open --[[:! (string, string | nil) -> any]]
	local stderr_write = opts_.stderr_write
	if not stderr_write then error("fs_router() requires opts.stderr_write cap") end
	local stderr_write_ = stderr_write --[[:! (...string) -> nil]]
	local lua_load = opts_.lua_load
	if not lua_load then error("fs_router() requires opts.lua_load cap") end
	local lua_load_ = lua_load --[[:! (string) -> (boolean, any)]]
	--: (string) -> any
	local handle_file = function (path2)
		if path2:find("%.lua$") then
			local success, cb_ = lua_load_(path2)
			local cb = cb_ --[[:! string]]
			if not success then stderr_write_("fs_router: caught error when rendering page: ", cb, "\n") end
			return success and cb_ or nil
		elseif rawget(_G, "DEV") then
			return function (req, res)
				local file = io_open_(path2)
				if not file then return false end
				local contents = file:read("*all")
				file:close()
				res.body = contents
				local ct = mimetype_by_name(req.path)
				if not ct then
					mimetype_by_contents = mimetype_by_contents or require("lib.mimetype.by_contents").mimetype
					ct = mimetype_by_contents(res.body)
				end
				if ct then res.headers["Content-Type"] = { ct } end
				return true
			end
		else
			local file = io_open_(path2)
			if not file then return nil end
			local contents = file:read("*all")
			local content_type = mimetype_by_name(path2)
			if not content_type then
				mimetype_by_contents = mimetype_by_contents or require("lib.mimetype.by_contents").mimetype
				content_type = mimetype_by_contents(contents)
			end
			file:close()
			return function (req, res)
				res.body = contents
				if content_type then res.headers["Content-Type"] = { content_type } end
				return true
			end
		end
	end
	local handle_dir
	--: (string) -> any
	handle_dir = function (path2)
		local routes = {}
		for entry in dir_list(path2) do
			local new_path = path2 .. "/" .. entry.name
			if entry.is_dir then
				routes[(entry.name == "*") and 1 or entry.name] = handle_dir(new_path)
			else
				local cb = handle_file(new_path)
				if cb then routes[(entry.name == "*.lua") and 1 or entry.name:match("^(.*)%.lua$") or entry.name] = cb end
			end
		end
		return routes
	end
	local cb = table_router(handle_dir(path or ""))
	return function (req, res, sock)
		local ret = cb(req, res, sock)
		if not ret then res.status = 404 end
		return ret
	end
end

return mod

