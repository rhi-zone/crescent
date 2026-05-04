local socket = require("lib.ljsocket") --[[: any]]
local epoll_ = require("lib.epoll") --[[: any]]

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
    local epoll_any = epoll --[[: any]]

    -- https://github.com/CapsAdmin/luajitsocket/blob/acb3bc3236cb4551a477a74f2bc9305860ca6492/examples/tcp_server_blocking.lua
    local server = assert(socket.bind(opts_.host or "*", port))
    assert(server:listen())

    local _, remove = epoll_any:add(server.fd, function()
        local client = server:accept()
        if not client then return end
        local state, remove_client
        local client_close = client.close
        client.close = function()
            if opts_.on_client_close then opts_.on_client_close(client) end
            client_close(client)
            remove_client()
        end
        _, remove_client = epoll_any:add(client.fd, function()
            state = callback(client, state)
        end, client.close)
        if opts_.on_client then opts_.on_client(client) end
    end, is_running and function() is_running = false end or nil)

    local server_close = server.close
    server.close = function(self)
        server_close(self)
        local remove_any = remove --[[: any]]
        remove_any()
    end

    while is_running do epoll_any:wait() end

    return server
end

return M
