--[[from https://github.com/CapsAdmin/luajitsocket/blob/acb3bc3236cb4551a477a74f2bc9305860ca6492/examples/tcp_client_blocking_tls.lua]]

local ffi = require("ffi")

local tls = require("dep.tls")
local socket = require("dep.ljsocket")
local client = assert(socket.create("inet", "stream", "tcp"))

tls.tls_init()
local tls_client = tls.tls_client()

-- find certificate somewhere
local config = tls.config_new()
tls.config_insecure_noverifycert(config)
tls.config_insecure_noverifyname(config)
tls.configure(tls_client, config)

client.on_connect = function (self, host, serivce)
	if tls.connect_socket(tls_client, self.fd, host) < 0 then
		return nil, ffi.string(tls.error(tls_client))
	end
	if tls.handshake(tls_client) < 0 then
		return nil, ffi.string(tls.error(tls_client))
	end
	return true
end

client.on_send = function (self, data, flags)
	local len = tls.write(tls_client, data, #data)
	if len < 0 then return nil, ffi.string(tls.tls_error(tls_client)) end
	return len
end

client.on_receive = function (self, buf, max_size, flags)
	local len = tls.read(tls_client, buf, max_size)
	if len < 0 then return nil, ffi.string(tls.tls_error(tls_client)) end
	return ffi.string(buf, len)
end

assert(client:connect("github.com", "https"))

assert(client:send(
	"GET / HTTP/1.1\r\n"..
	"Host: github.com\r\n"..
	"User-Agent: Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:64.0) Gecko/20100101 Firefox/64.0\r\n"..
	"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"..
	"Accept-Language: nb,nb-NO;q=0.9,en;q=0.8,no-NO;q=0.6,no;q=0.5,nn-NO;q=0.4,nn;q=0.3,en-US;q=0.1\r\n"..
	--"Accept-Encoding: gzip, deflate\r\n"..
	"DNT: 1\r\n"..
	"Connection: keep-alive\r\n"..
	"Upgrade-Insecure-Requests: 1\r\n"..
	"\r\n"
))

local total_length
local str = ""

while true do
	local chunk = assert(client:receive())
	if not chunk then break end
	str = str .. chunk
	if not total_length then
		total_length = tonumber(str:match("Content%-Length: (%d+)"))
	end

	local magic = "0\r\n\r\n"
	if str:sub(-#magic) == magic or (total_length and #str >= total_length) then
		break
	end
end

print(str)