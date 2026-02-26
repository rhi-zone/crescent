local socket = require("lib.socket.server")
local http = require("lib.http.format")

local mod = {}

--[[@alias http_callback fun(req: http_request, res: http_response, sock: luajitsocket): boolean?]]

local ffi = require("ffi")
local buf = ffi.new("char[65536]")
local err_res = http.http_response_to_string({ status = 400, headers = {} })
local max_header_size = 65536

--[[@param handler http_callback]]
mod.make_connection_handler = function (handler)
	--[[@param client luajitsocket]]
	return function (client)
		local parts = {}
		local total = 0
		local header_end
		--[[read until we have complete headers (\r\n\r\n)]]
		while not header_end do
			local s = client:receive(buf)
			if not s then return end
			parts[#parts + 1] = s
			total = total + #s
			if total > max_header_size then client:send(err_res); return end
			local combined = table.concat(parts)
			header_end = combined:find("\r\n\r\n", 1, true)
			if header_end then parts = { combined } end
		end
		local data = parts[1]
		local req, i = http.string_to_http_request(data)
		if not req or not i then client:send(err_res); return end
		--[[read remaining body if Content-Length specified]]
		local content_length = req.headers["content-length"]
		if content_length then
			content_length = tonumber(content_length[1])
			if content_length then
				local body_start = header_end + 4
				local body_so_far = #data - body_start + 1
				while body_so_far < content_length do
					local s = client:receive(buf)
					if not s then break end
					parts[#parts + 1] = s
					body_so_far = body_so_far + #s
				end
				if #parts > 1 then
					data = table.concat(parts)
					req = http.string_to_http_request(data)
					if not req then client:send(err_res); return end
				end
			end
		end
		local res = { headers = {} } --[[@type http_response]]
		handler(req, res, client)
		client:send(http.http_response_to_string(res))
		client:close()
	end
end

--[[@return luajitsocket sock]]
--[[@param handler http_callback]] --[[@param port? integer]] --[[@param epoll? epoll]]
mod.server = function (handler, port, epoll)
	return socket.server(mod.make_connection_handler(handler), port or 80, epoll)
end

return mod
