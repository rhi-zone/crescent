-- FIXME: figure out how to have a common api for tls, tcp, and udp
--[[
local socket = require("ljsocket")
local server_ = require("lib.socket.server").server
local port = 8080
local address = socket.find_first_address("*", port)

local mod = {}

mod.server = function ()
	local server = assert(socket.create("inet", "dgram", "udp"))
end

assert(server:set_blocking(false))
assert(server:bind(address))
print("hosting at ", address:get_ip(), address:get_port())

function update_server()
	local data, addr = server:receive_from()

	if data then
		assert(server:send_to(addr, "hello from server " .. os.clock()))
	elseif addr ~= "timeout" then
		error(addr)
	end
end

return mod
]]
