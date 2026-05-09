local static_router = require("lib.http.router.static_full").router

local mod = {}

--: (string | nil, { io_open: (string, string) -> any, os_date: (string, integer) -> string } | nil) -> ((any, any) -> unknown) | (nil, string | nil)
mod.router = function (base, opts)
	local router, err = static_router(base, opts)
	if not router then return nil, err end
	return function (req, res)
		local ret = router(req, res)
		if not res.status or res.status == 404 then
			local path = req.path
			req.path = "/404.html"
			ret = router(req, res)
			req.path = path
		end
		return ret
	end
end

return mod
