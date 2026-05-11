-- UDP port 53, truncated to 512 bytes (TC bit set if required)
-- TCP port 53, prefixed with 2-octet length field

local dns = require("lib.dns.format")
local tcp_client = require("lib.tcp.client").client
local bit = require("bit")

local mod = {}

--[[this only sends a single message so "client" is a bit of a misnomer]]
--[[TODO: the positioning of epoll is very inconvenient. but breaking up the arguments isn't a great option either]]
--: ((unknown) -> nil, string, string, integer | nil, integer | nil, integer | nil, unknown | nil) -> nil
mod.client = function (cb, nameserver, domain, opcode, type, class, epoll)
	local is_running = not epoll
	epoll = epoll or require("lib.epoll").new()
	type = (type or (dns.type --[[:! { [string]: unknown }]])["*"]) --[[:! integer]]
	class = class or dns.class.IN
	local name_parts = {}
	for s in domain:gmatch("[^.]+") do name_parts[#name_parts+1] = s end
	if #name_parts[#name_parts] > 0 then name_parts[#name_parts+1] = "" end
	local msg_raw = { opcode = opcode, is_query = true, is_recursion_desired = true, questions = { { name = name_parts, type = type, class = class } } }
	local msg = ((msg_raw --[[: unknown]]) --[[:! { additional?: { [integer]: { class: integer, data: string, name: { [integer]: string }, ttl: integer, type: integer } }, answers?: { [integer]: { class: integer, data: string, name: { [integer]: string }, ttl: integer, type: integer } }, id?: integer, is_authoritative?: boolean, is_query?: boolean, is_recursion_available?: boolean, is_recursion_desired?: boolean, is_response?: boolean, is_truncated?: boolean, nameservers?: { [integer]: { class: integer, data: string, name: { [integer]: string }, ttl: integer, type: integer } }, opcode?: integer, questions?: { [integer]: { class: integer, name: { [integer]: string }, type: integer } }, response_code?: integer }]])
	local s = dns.dns_message_to_string(msg)
	s = string.char(bit.rshift(#s, 8), bit.band(#s, 0xff)) .. s
	local send, close
	send, close = tcp_client(nameserver, 53, function (s2)
		--[[local length = bit.bor(bit.lshift(s2:byte(1), 8), s2:byte(2))]]
		cb(dns.string_to_dns_message(s2:sub(3)))
		close()
	end, epoll)
	;((send --[[: unknown]]) --[[:! (string) -> ()]])(s)
	if is_running then ((epoll --[[: unknown]]) --[[:! { loop: () -> () }]]):loop() end
end

return mod
