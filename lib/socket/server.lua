local socket = require("lib.ljsocket")
local epoll_ = require("lib.epoll")
local async = require("lib.async")

local M = {}

--:: server_opts = { host: string | nil, on_client: ((unknown) -> nil) | nil, on_client_close: ((unknown) -> nil) | nil }

--:: server_socket = { fd: integer, close: (self: server_socket) -> (boolean | nil, string | nil), accept: (self: server_socket) -> (server_client | nil, string | nil, integer | nil), listen: (self: server_socket, max: integer | nil) -> (boolean | nil, string | nil), set_blocking: (self: server_socket, boolean) -> (boolean | nil, string | nil, integer | nil), ... }

--:: server_client = { fd: integer, close: (self: server_client) -> (boolean | nil, string | nil), set_blocking: (self: server_client, boolean) -> (boolean | nil, string | nil, integer | nil), on_receive: unknown, on_send: ((unknown, unknown, unknown) -> (integer | nil, string | nil, integer | nil)) | nil, _loop: unknown, ... }

-- NOTE: cross-module named types are not yet supported; AsyncLoop is the
-- structural subset of lib/async LoopObj used here.
--:: AsyncLoop = { await_readable: (self: AsyncLoop, integer) -> (unknown, string | nil, (() -> nil) | nil), await_writable: (self: AsyncLoop, integer) -> (unknown, string | nil, (() -> nil) | nil), sleep: (self: AsyncLoop, number) -> unknown, step: (self: AsyncLoop) -> nil, ... }

-- Wrap a client socket for non-blocking I/O with coroutine yields.
-- After this call, receive() yields on EAGAIN via await_readable, and
-- send() handles partial writes + yields on EAGAIN via await_writable.
-- Skips wrapping for TLS connections (on_receive already set by TLS layer).
--: (server_client, AsyncLoop) -> nil
local function wrap_client_async(client, loop)
	-- TLS connections have on_receive set by wrap_client_tls in on_client.
	-- TLS + non-blocking requires WANT_POLLIN/WANT_POLLOUT handling (future work).
	if client.on_receive then return end

	client:set_blocking(false)

	local orig_receive = client.receive
	local orig_send = client.send

	-- Yield-aware receive: retries on EAGAIN via await_readable.
	--: (self: server_client, unknown, unknown, unknown, unknown) -> (string | nil, unknown, integer | nil)
	client.receive = function(self, size, flags, src_address, address_len)
		while true do
			local data, err, num = orig_receive(self, size, flags, src_address, address_len)
			if data then return data end
			if err == "timeout" then
				local p, _perr, _cancel = loop:await_readable(self.fd)
				if not p then return nil, "await_readable failed", nil end
				async.await(p)
			else
				return nil, err, num
			end
		end
	end

	-- Yield-aware send: retries on EAGAIN via await_writable, handles partial writes.
	--: (self: server_client, string, unknown, unknown) -> (integer | nil, string | nil, integer | nil)
	client.send = function(self, data, flags, addr)
		local on_send = self.on_send
		if on_send then
			local r1, r2, r3 = on_send(self, data, flags)
			return r1, r2, r3
		end
		local total = #data
		local sent = 0
		while sent < total do
			local chunk = sent == 0 and data or data:sub(sent + 1)
			local len, err, num = orig_send(self, chunk, flags, addr)
			if len then
				sent = sent + len
			elseif err == "timeout" then
				local p, _perr, _cancel = loop:await_writable(self.fd)
				if not p then return nil, "await_writable failed", nil end
				async.await(p)
			else
				return nil, err, num
			end
		end
		return sent
	end
end

-- Bind and listen on port. callback(client) is called once per accepted
-- connection inside a dedicated coroutine. receive/send on the client yield
-- back to the event loop when the kernel would block (EAGAIN), allowing other
-- connections to be serviced concurrently.
-- epoll is optional — if omitted, a new one is created and the call blocks
-- until the server socket is closed.
--: (callback: (unknown) -> unknown, port: integer | string, epoll: unknown | nil, opts: server_opts | nil) -> unknown
M.server = function(callback, port, epoll, opts)
	local opts_ = opts or {}
	local is_running = not epoll
	local ep = (epoll or epoll_.new()) --[[: { add: (self: unknown, fd: integer, on_read: ((string) -> nil) | (() -> nil), close: (() -> nil) | nil, weak: boolean | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil), wait: (self: unknown, integer | nil) -> nil, ... }]]
	local loop = async.loop(ep) --[[: AsyncLoop]]

	local server = assert(socket.bind(opts_.host or "*", port)) --[[: server_socket]]
	assert(server:listen())
	server:set_blocking(false)

	--: (server_client) -> nil
	local function spawn_connection(client)
		async.async(function()
			-- Override close to trigger on_client_close.
			local client_close = client.close
			--: (self: server_client) -> (boolean | nil, string | nil)
			client.close = function(self)
				local on_close = opts_.on_client_close
				if on_close then pcall(on_close, client) end
				if client_close then return client_close(self) end
				return true
			end

			-- Call on_client first (TLS handshake sets on_receive/on_send here).
			local on_client = opts_.on_client
			if on_client then on_client(client) end

			-- Wrap for async I/O (skips if TLS detected via on_receive).
			wrap_client_async(client, loop)
			client._loop = loop

			local ok, err = pcall(callback, client)
			if not ok then
				-- "fd closed" is normal (remote disconnect during await).
				if type(err) ~= "string" or not err:find("fd closed", 1, true) then
					io.stderr:write("socket/server: connection error: " .. tostring(err) .. "\n")
				end
				pcall(client.close, client)
			end
		end)()
	end

	local _, remove = ep:add(server.fd, function()
		while true do
			local client = server:accept()
			if not client then break end
			spawn_connection(client)
		end
	end, is_running and function() is_running = false end or nil)

	local server_close = server.close
	--: (self: server_socket) -> (boolean | nil, string | nil)
	server.close = function(self)
		is_running = false
		local r = server_close(self)
		if remove then remove() end
		return r
	end

	while is_running do loop:step() end

	return server
end

return M
