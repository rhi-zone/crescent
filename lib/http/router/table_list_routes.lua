local mod = {}

local list_routes
--: (Arr<string>, any, string | nil) -> nil
list_routes = function (routes_parts, routes, prefix)
	local keys = {} --: Arr<string>
	for k in pairs(routes) do keys[#keys+1] = k --[[:! string]] end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local path = prefix and (prefix .. "/" .. k) or k
		local v = routes[k]
		--[[does not detect tables with a `__call` metamethod]]
		if k == "" or type(v) ~= "table" then
			if type(v) == "function" then routes_parts[#routes_parts+1] = path end
		else
			list_routes(routes_parts, v, path)
		end
	end
end

--: (any, string | nil) -> (any, any) -> nil
mod.list_routes_handler = function (routes, prefix)
	local html do
		local routes_parts = {} --: Arr<string>
		list_routes(routes_parts, routes, prefix)
		for i, path in ipairs(routes_parts) do
			routes_parts[i] = [[<a href="]] .. (path ~= "" and path or ".") .. [[">]] .. (path ~= "" and path or "&nbsp;") .. [[</a><br/>]]
		end
		html = (
			[[<!doctype html>]] .. "\n" ..
			[[<style>@media (prefers-color-scheme: dark) { body { background: #222; color: white; } a { color: lightblue; } }</style>]] .. "\n" ..
			[[<link rel="stylesheet" href="/style.css">]] .. "\n" ..
			table.concat(routes_parts, "\n")
		)
	end
	return function (_, res)
		res.headers["Content-Type"] = { "text/html" }
		res.body = html
	end
end

return mod
