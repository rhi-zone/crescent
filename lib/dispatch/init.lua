if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: DispatchHandler = (...unknown) -> unknown
--:: DispatchKeyFn = (...unknown) -> string
--:: DispatchHandlers = { [string]: DispatchHandler }

--: (DispatchKeyFn, DispatchHandlers) -> (...unknown) -> unknown
function M.dispatcher_from_table_by(key_fn, handlers)
	return function(...)
		local key = key_fn(...)
		local fn = handlers[key]
		if not fn then
			error("no handler for key: " .. tostring(key))
		end
		return fn(...)
	end
end

--: (string, DispatchHandlers) -> (...unknown) -> unknown
function M.dispatcher_from_table(field_name, handlers)
	return M.dispatcher_from_table_by(function(first, ...)
		return first[field_name]
	end, handlers)
end

return M
