if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local mod = {}

--[[https://github.com/ms-jpq/lua-async-await/blob/neo/README.md]]

--: ((...any) -> any) -> (...any) -> ((any) -> nil) -> nil
mod.futurify = function (fn)
	return function (...)
		local params = { ... }
		local done = false
		return function (step)
			if done then return end
			params[#params+1] = step
			done = true
			fn(unpack(params))
		end
	end
end

--: ((...any) -> any) -> (...any) -> () -> ((any) -> nil) -> nil
mod.futurify_many = function (fn)
	return function (...)
		local params = { ... }
		local done = false
		--[[TODO: figure out how to end iteration]]
		local next = function (step)
			if done then return end
			params[#params+1] = step
			done = true
			fn(unpack(params))
		end
		return function () return next end
	end
end

--[[TODO: return yield() somehow?]]
--: ((...any) -> any) -> (...any) -> ((any) -> nil) -> nil
mod.async = function (fn)
	return function (...)
		local args = { ... }
		return function (cb)
			local co = coroutine.create(fn)
			local step
			step = function (...)
				local _, cont = assert(coroutine.resume(co, ...))
				if coroutine.status(co) == "dead" then
					if cb then cb(cont) end
				else
					--[[@diagnostic disable-next-line: need-check-nil]]
					cont(step)
				end
			end
			step(unpack(args))
		end
	end
end

--: (((any) -> nil) -> nil) -> any
mod.await = coroutine.yield

--: (...((any) -> nil) -> nil) -> ...any
mod.await_all = function(...)
	local fns = { ... }
	local vals = {}
	local left = #fns
	return mod.await(function (step)
		for i, fn in ipairs(fns) do
			fn(function (...)
				vals[i] = { ... }
				left = left - 1
				if left == 0 then
					step(unpack(vals))
				end
			end)
		end
	end)
end

--: (any, any, any) -> (any, any) -> any, any, any
mod.await_each = function (step, c, v)
	return function (c2, v2)
		local future = step(c2, v2)
		print("future", future)
		local ret = mod.await(future)
		print("ret", ret)
		return ret
	end, c, v
end

return mod
