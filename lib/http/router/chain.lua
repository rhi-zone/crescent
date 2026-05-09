local mod = {}

--: (...(unknown, unknown) -> boolean) -> (unknown, unknown) -> boolean | nil
mod.router = function (...)
	local routers = { ... } --: ((unknown, unknown) -> boolean)[]
	return function (req, res)
		for i = 1, #routers do
			local ret = routers[i](req, res)
			if ret then return ret end
		end
	end
end

return mod
