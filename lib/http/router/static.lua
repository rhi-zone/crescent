local path = require("lib.path")
local mimetype_by_name = require("lib.mimetype.by_name").mimetype
local mimetype_by_contents

local mod = {}

--:: StaticHandlerFn = (req: { path: string, target: string, ... }, res: { body: string | nil, ... }) -> (boolean | nil)
--: (base: string | nil, opts: { io_open: (string, string) -> (unknown, string | nil) } | nil) -> StaticHandlerFn | (nil, string)
mod.router = function (base, opts)
	if base ~= nil and type(base) ~= "string" then
		return nil, "static_router() expects string as base path, got " .. tostring(base)
	end
	local io_open = opts and opts.io_open
	if not io_open then return nil, "static_router() requires opts.io_open cap" end
	base = (base or "."):gsub("/$", "")
	return function (req, res)
		-- TODO: urldecode? urldecode(req.path)
		local full_path = path.safe_resolve(base, req.path)
		if not full_path then res.status = 404; return end
		local file_raw = io_open(full_path, "rb")
		if file_raw == nil then res.status = 404; return end
		local file = file_raw --[[:! { read: (self: unknown, string) -> string | nil, close: (self: unknown) -> nil }]]
		res.status = 200
		res.body = file:read("*all")
		if res.body == nil then res.status = 404; return end
		file:close()
		-- TODO: consider refactoring this out - it's a one liner either way anyway
		local ct = mimetype_by_name(req.path)
		if not ct then
			mimetype_by_contents = mimetype_by_contents or require("lib.mimetype.by_contents").mimetype
			ct = mimetype_by_contents(res.body)
		end
		if ct then res.headers["Content-Type"] = { ct } end
		return true
	end
end

return mod
