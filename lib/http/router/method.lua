local mod = {}

--: (any) -> (any, any, any) -> unknown
mod.router = function (cbs)
	return function (req, res, sock)
		local cb = cbs[req.method]
		if cb then return cb(req, res, sock) end
	end
end

return mod
