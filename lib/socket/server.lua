local socket = require("lib.ljsocket")
local epoll_ = require("lib.epoll")

local M = {}

-- NOTE: lib/ljsocket has no crescent type annotations; interactions with
-- ljsocket objects are untyped until lib/ljsocket gets --:: declarations.

--:: server_opts = { host: string | nil, on_client: ((unknown) -> nil) | nil, on_client_close: ((unknown) -> nil) | nil }

-- Bind and listen on port. callback(client, state) -> state is called on each
-- readable event per client. epoll is optional — if omitted, a new one is
-- created and the call blocks until the server socket is closed.
M.server = function(callback, port, epoll, opts)
    opts = opts or {}
    local opts_ = opts --[[:! { on_client: ((unknown) -> nil) | nil, on_client_close: ((unknown) -> nil) | nil, host: string | nil }]]
    local is_running = not epoll
    epoll = epoll or epoll_.new()
    local epoll_any = epoll

    -- https://github.com/CapsAdmin/luajitsocket/blob/acb3bc3236cb4551a477a74f2bc9305860ca6492/examples/tcp_server_blocking.lua
    local server = assert(socket.bind(opts_.host or "*", port))
    assert(server:listen())

    local _, remove = epoll_any:add(server.fd, function()
        local client_ = (server --[[:! { accept: (unknown) -> unknown, fd: integer, close: (unknown) -> nil, ... }]]):accept()
        local client = (client_ --[[:! { fd: integer, close: (unknown) -> nil, ... }]])
        if not client then return end
        local state, remove_client
        local client_close = client.close
        client.close = function(_self)
            if opts_.on_client_close then opts_.on_client_close(client) end
            client_close(client)
            local rc = remove_client --[[:! () -> nil]]
            rc()
        end
        _, remove_client = epoll_any:add(client.fd, function()
            state = callback(client, state)
        end, client.close)
        if opts_.on_client then opts_.on_client(client) end
    end, is_running and function() is_running = false end or nil)

    local server_close = server.close
    server.close = function(self)
        local sc = server_close --[[:! (unknown) -> nil]]
        sc(self)
        remove()
    end

    local ep = epoll_any --[[:! { wait: (unknown) -> nil, add: (unknown, integer, (unknown) -> nil, (unknown) -> nil | nil) -> (unknown, () -> nil), ... }]]
    while is_running do ep:wait() end

    return server
end

return M
