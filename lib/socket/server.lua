local socket = require("lib.ljsocket")
local epoll_ = require("lib.epoll")

local M = {}

-- NOTE: cross-module named types are not yet supported, so callbacks
-- accept the client as `unknown` rather than `LjSocket`. When that lands,
-- replace these `unknown` with `LjSocket` and the `epoll: unknown | nil`
-- with `epoll | nil` (see lib/ljsocket and lib/epoll for the type aliases).

--:: server_opts = { host: string | nil, on_client: ((unknown) -> nil) | nil, on_client_close: ((unknown) -> nil) | nil }

--:: server_socket = { fd: integer, close: (self: server_socket) -> (boolean | nil, string | nil), accept: (self: server_socket) -> (server_client | nil, string | nil, integer | nil), listen: (self: server_socket, max: integer | nil) -> (boolean | nil, string | nil), ... }

--:: server_client = { fd: integer, close: (self: server_client) -> (boolean | nil, string | nil), ... }

-- Bind and listen on port. callback(client, state) -> state is called on each
-- readable event per client. epoll is optional — if omitted, a new one is
-- created and the call blocks until the server socket is closed.
--: (callback: (unknown, unknown) -> unknown, port: integer | string, epoll: unknown | nil, opts: server_opts | nil) -> unknown
M.server = function(callback, port, epoll, opts)
    local opts_ = opts or {}
    local is_running = not epoll
    local ep = (epoll or epoll_.new()) --[[: { add: (self: unknown, fd: integer, on_read: ((string) -> nil) | (() -> nil), close: (() -> nil) | nil, weak: boolean | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil), wait: (self: unknown) -> nil, ... }]]

    -- https://github.com/CapsAdmin/luajitsocket/blob/acb3bc3236cb4551a477a74f2bc9305860ca6492/examples/tcp_server_blocking.lua
    local server = assert(socket.bind(opts_.host or "*", port)) --[[: server_socket]]
    assert(server:listen())

    local _, remove = ep:add(server.fd, function()
        local client = server:accept()
        if not client then return end
        local state
        local remove_client --: (() -> nil) | nil
        local client_close = client.close
        --: (self: server_client) -> (boolean | nil, string | nil)
        client.close = function(_self)
            local on_close = opts_.on_client_close
            if on_close then on_close(client) end
            if client_close then client_close(client) end
            if remove_client then remove_client() end
            return true
        end
        _, remove_client = ep:add(client.fd, function()
            state = callback(client, state)
        end, client.close)
        local on_client = opts_.on_client
        if on_client then on_client(client) end
    end, is_running and function() is_running = false end or nil)

    local server_close = server.close
    --: (self: server_socket) -> (boolean | nil, string | nil)
    server.close = function(self)
        local r = server_close(self)
        if remove then remove() end
        return r
    end

    while is_running do ep:wait() end

    return server
end

return M
