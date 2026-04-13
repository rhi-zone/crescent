-- lib/platform/rpc.lua
-- RPC dispatcher for cap bridging.
--
-- Browser-side code calls caps via HTTP. This module dispatches those requests
-- to real cap objects held by the server.
--
-- API:
--   rpc.make_dispatcher(caps) -> dispatch(body_string) -> status, body_string
--
-- Request format (JSON body of POST /api/cap):
--   { "cap": "llm", "method": "call", "args": [messages] }
--
-- Response format (JSON body):
--   Success: { "result": value }     — value may be null (JSON null)
--   Error:   { "error": "message" }  — cap returned nil,err or threw

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.json")

local M = {}

-- Encode a response with a result that may be nil.
-- json.encode({result = nil}) omits the key, so we build manually.
--: (unknown) -> string
local function encode_result(val)
	if val == nil then
		return '{"result":null}'
	end
	return '{"result":' .. json.encode(val) .. '}'
end

-- Encode an error response.
--: (string) -> string
local function encode_error(msg)
	return '{"error":' .. json.encode(msg) .. '}'
end

-- make_dispatcher(caps) -> dispatch(body) -> status, response_body
-- caps: table of cap_name -> cap_table (same table passed to sandbox).
--: ({ [string]: { [string]: (...) -> ... } }) -> (string) -> integer, string
function M.make_dispatcher(caps)
	return function(body)
		-- Parse request JSON
		local ok, req = pcall(json.decode, body)
		if not ok or type(req) ~= "table" then
			return 400, encode_error("invalid JSON")
		end

		local cap_name = req.cap
		local method_name = req.method
		local args = req.args

		if type(cap_name) ~= "string" or type(method_name) ~= "string" then
			return 400, encode_error("missing cap or method")
		end
		if args ~= nil and type(args) ~= "table" then
			return 400, encode_error("args must be an array or null")
		end

		-- Look up cap
		local cap = caps[cap_name]
		if not cap or type(cap) ~= "table" then
			return 404, encode_error("unknown cap: " .. cap_name)
		end

		-- Look up method
		local fn = cap[method_name]
		if type(fn) ~= "function" then
			return 404, encode_error("unknown method: " .. cap_name .. "." .. method_name)
		end

		-- Call the cap method, catching throws
		local call_ok, r1, r2
		if args and #args > 0 then
			call_ok, r1, r2 = pcall(fn, unpack(args))
		else
			call_ok, r1, r2 = pcall(fn)
		end

		if not call_ok then
			-- fn threw an error
			return 500, encode_error(tostring(r1))
		end

		-- Lua (nil, errmsg) convention: if first return is nil and second is
		-- a string, treat as an error response (not an HTTP error — the cap
		-- executed, it just reported failure).
		if r1 == nil and type(r2) == "string" then
			return 200, encode_error(r2)
		end

		return 200, encode_result(r1)
	end
end

return M
