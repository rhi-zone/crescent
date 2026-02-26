--[[ FIXME
local socket = require("ljsocket")
local client_ = require("lib.socket.client")
local port = 8080 -- TODO
local address = socket.find_first_address("*", port)

do -- client
    local client = assert(socket.create("inet", "dgram", "udp"))
    assert(client:set_blocking(false))
    local next_send = 0

    function update_client()
        if next_send < os.clock() then
            assert(client:send_to(address, "hello from client " .. os.clock()))
            next_send = os.clock() + math.random() + 0.5
        end

        local data, addr = client:receive_from(address)

        if data then
            print(data, addr:get_ip(), addr:get_port())
        elseif addr ~= "timeout" then
            error(addr)
        end
    end
end
]]
