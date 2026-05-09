local mod = {}

--: (any) -> (any, any, any) -> unknown
mod.router = function (routes)
	return function (req, res, sock)
		local route = routes
		if type(route) == "function" then return route(req, res, sock) end
		for part in req.path:gmatch("/([^/]*)") do
			route = route[part]
			if type(route) == "function" then return route(req, res, sock)
			elseif route == nil then return end
		end
	end
end

return mod
