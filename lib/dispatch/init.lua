if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: DispatchHandler<A, B, R> = (a: A, b: B) -> R
--:: DispatchKeyFn<A, B> = (a: A, b: B) -> string
--:: DispatchHandlers<A, B, R> = { [string]: DispatchHandler<A, B, R> }

--: <A, B, R>((A, B) -> string, { [string]: (A, B) -> R }) -> (A, B) -> R
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

--: <A, B, R>(string, { [string]: (A, B) -> R }) -> (A, B) -> R
function M.dispatcher_from_table(field_name, handlers)
	return M.dispatcher_from_table_by(function(first, ...)
		return first[field_name]
	end, handlers)
end

return M
