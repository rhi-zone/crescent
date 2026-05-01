local static_router = require("lib.http.router.static_full").router

local mod = {}

--[[@param base? string]]
--[[@param opts? { io_open: fun(path: string, mode: string): file* | nil, os_date: fun(fmt: string, t: integer): string }]]
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
