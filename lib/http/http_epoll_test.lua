if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local epoll_mod = require("lib.epoll")
local client_mod = require("lib.http.client")
local format = require("lib.http.format")
local socket_mod = require("lib.ljsocket")

-- Ephemeral test ports — high numbers to avoid conflicts with system services.
local TEST_PORT_1 = 19081
local TEST_PORT_2 = 19082
local TEST_PORT_3 = 19083

-- Helper: bind a minimal non-blocking HTTP echo server on the given port.
-- Registers itself on ep (weak entries so it doesn't keep the loop alive).
-- Returns the server socket.
local function make_test_server(ep, port, response_body)
	local srv = assert(socket_mod.bind("*", tostring(port)))
	assert(srv:listen())
	assert(srv:set_blocking(false))

	local resp = format.serialize_response({
		status = 200,
		headers = {
			["Content-Type"] = { "text/plain" },
			["Content-Length"] = { tostring(#response_body) },
		},
		body = response_body,
	})

	-- Weak: server listener doesn't hold the loop open.
	ep:add(srv.fd, function ()
		local client = srv:accept()
		if not client then return end
		client:set_blocking(false)
		-- Weak: server-side client connections don't hold the loop open either.
		local _, client_remove
		_, client_remove = ep:add(client.fd, function ()
			client:receive() -- consume the request
			client:send(resp)
			client_remove()
			client:close()
		end, function () client:close() end, true)
	end, nil, true)

	return srv
end

T.describe("http/client epoll", function ()
	T.it("send_async with shared epoll gets a valid response", function ()
		local ep = epoll_mod.new()
		local resp_body = "hello from test server"
		local srv = make_test_server(ep, TEST_PORT_1, resp_body)

		local received = nil
		local got_err = nil

		client_mod.send_async({
			host = "127.0.0.1",
			port = tostring(TEST_PORT_1),
			method = "GET",
			path = "/",
		}, function (data, err)
			received = data
			got_err = err
		end, ep)

		ep:loop()
		srv:close()

		T.ok(got_err == nil, "no error: " .. tostring(got_err))
		T.ok(received ~= nil, "received a response")
		local parsed = format.parse_response(received)
		T.ok(parsed ~= nil, "response is valid HTTP")
		T.eq(parsed.status, 200)
		T.eq(parsed.body, resp_body)
	end)

	T.it("two concurrent send_async requests share one epoll loop", function ()
		local ep = epoll_mod.new()
		local srv1 = make_test_server(ep, TEST_PORT_2, "response one")
		local srv2 = make_test_server(ep, TEST_PORT_3, "response two")

		local results = {}

		client_mod.send_async({
			host = "127.0.0.1",
			port = tostring(TEST_PORT_2),
			method = "GET",
			path = "/one",
		}, function (data, err)
			results[1] = { data = data, err = err }
		end, ep)

		client_mod.send_async({
			host = "127.0.0.1",
			port = tostring(TEST_PORT_3),
			method = "GET",
			path = "/two",
		}, function (data, err)
			results[2] = { data = data, err = err }
		end, ep)

		ep:loop()
		srv1:close()
		srv2:close()

		T.ok(results[1] ~= nil, "first request got a result")
		T.ok(results[2] ~= nil, "second request got a result")
		T.ok(results[1].err == nil, "first request: no error: " .. tostring(results[1].err))
		T.ok(results[2].err == nil, "second request: no error: " .. tostring(results[2].err))

		local p1 = format.parse_response(results[1].data)
		local p2 = format.parse_response(results[2].data)
		T.ok(p1 ~= nil, "first response is valid HTTP")
		T.ok(p2 ~= nil, "second response is valid HTTP")
		T.eq(p1.status, 200)
		T.eq(p2.status, 200)
		T.eq(p1.body, "response one")
		T.eq(p2.body, "response two")
	end)
end)
