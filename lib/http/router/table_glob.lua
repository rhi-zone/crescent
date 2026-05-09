local mod = {}

--: (unknown) -> (unknown, unknown, unknown) -> boolean | nil
mod.router = function (routes)
	return function (req0, res, sock)
		local req = req0 --[[:! { path: string, globs: { rest: string, [integer]: unknown } }]]
		local route = routes
		if type(route) == "function" then
			local success = route(req, res, sock)
			return success == nil or success
		end
		local start
		local end_ = 0
		local part
		repeat
			start, end_, part = req.path:find("/([^/]*)", end_ + 1)
			local new_route = route[part]
			if not new_route then
				new_route = route[1]
				local globs = req.globs or {} --[[:! { rest: string, [integer]: unknown }]]
				globs[#globs+1] = part
				req.globs = globs
			end
			route = new_route
			if type(route) == "function" then
				if end_ < #req.path then req.globs.rest = req.path:sub(end_ + 1) end
				local success = route(req, res, sock)
				return success == nil or success
			elseif route == nil then return end
		until end_ == #req.path
		route = route[""]
		if type(route) == "function" then
			if end_ < #req.path then req.globs.rest = req.path:sub(end_ + 1) end
			local success = route(req, res, sock)
			return success == nil or success
		end
	end
end

return mod
