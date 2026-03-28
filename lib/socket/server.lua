local socket = require("lib.ljsocket")
local epoll_ = require("lib.epoll")

local M = {}

-- NOTE: lib/ljsocket has no crescent type annotations; interactions with
-- ljsocket objects are untyped until lib/ljsocket gets --:: declarations.

--:: server_opts = { host: string?, on_client: ((unknown) -> nil)?, on_client_close: ((unknown) -> nil)? }

-- Bind and listen on port. callback(client, state) -> state is called on each
-- readable event per client. epoll is optional — if omitted, a new one is
-- created and the call blocks until the server socket is closed.
M.server = function(callback, port, epoll, opts)
    opts = opts or {}
    local is_running = not epoll
    epoll = epoll or epoll_.new()

    -- https://github.com/CapsAdmin/luajitsocket/blob/acb3bc3236cb4551a477a74f2bc9305860ca6492/examples/tcp_server_blocking.lua
    local server = assert(socket.bind(opts.host or "*", port))
    assert(server:listen())

    local _, remove = epoll:add(server.fd, function()
        local client = server:accept()
        if not client then return end
        local state, remove_client
        local client_close = client.close
        client.close = function()
            if opts.on_client_close then opts.on_client_close(client) end
            client_close(client)
            remove_client()
        end
        _, remove_client = epoll:add(client.fd, function()
            state = callback(client, state)
        end, client.close)
        if opts.on_client then opts.on_client(client) end
    end, is_running and function() is_running = false end or nil)

    local server_close = server.close
    server.close = function(self)
        server_close(self)
        remove()
    end

    while is_running do epoll:wait() end

    return server
end

return M
