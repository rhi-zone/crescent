--[[@alias api_callback fun(input: unknown): unknown]]
--[[@alias api_table_handler api_callback | table<string, api_callback|table<string, api_callback|table<string, api_callback|table<string, api_callback|api_table_handler>>>>]]
local mod = {}

local json_to_value = require("lib.format.json").json_to_value
local value_to_json = require("lib.format.json").value_to_json

--:: ApiReq = { body: string | nil, path: string, method: string, globs?: { [integer]: string, rest?: string }, ... }
--:: ApiRes = { body: string | nil, headers: { [string]: unknown }, ... }
--: (unknown) -> (ApiReq, ApiRes, unknown) -> boolean | nil
mod.router = function (routes)
	--: (ApiReq, ApiRes, unknown) -> boolean | nil
	return function (req_, res_, sock)
		local json_to_ = json_to_value
		local to_json_ = value_to_json
		local route = routes
		if type(route) == "function" then
			local input = json_to_(req_.body or "null")
			res_.headers["Content-Type"] = { "application/json" }
			res_.body = to_json_(route(input))
			return true
		end
		local start
		local end_ = 0
		local part
		repeat
			start, end_, part = req_.path:find("/([^/]*)", end_ + 1)
			local new_route = route[part]
			if not new_route then
				new_route = route[1]
				local globs = req_.globs or {}
				globs[#globs+1] = part
				req_.globs = globs
			end
			route = new_route
			if type(route) == "function" then
				--[[FIXME: apis don't have access to req.globs]]
				if end_ < #req_.path then req_.globs = req_.globs or {}; req_.globs.rest = req_.path:sub(end_ + 1) end
				local input = json_to_(req_.body or "null")
				res_.headers["Content-Type"] = { "application/json" }
				res_.body = to_json_(route(input))
				return true
			elseif route == nil then return end
		until end_ == #req_.path
		route = route[""]
		if type(route) == "function" then
			if end_ < #req_.path then req_.globs = req_.globs or {}; req_.globs.rest = req_.path:sub(end_ + 1) end
			local input = json_to_(req_.body or "null")
			res_.headers["Content-Type"] = { "application/json" }
			res_.body = to_json_(route(input))
			return true
		end
	end
end

return mod
