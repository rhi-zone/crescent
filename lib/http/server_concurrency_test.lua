-- lib/http/server_concurrency_test.lua
-- Proves lib/http/server.lua services multiple simultaneous connections
-- through the async event loop rather than serializing them.
--
-- The handler suspends (async.await on loop:sleep) before responding, so if
-- connections were serviced one at a time, every request would fully finish
-- (start + end) before the next one's handler even started. Driving the
-- shared event loop lets all N connections make progress together: every
-- handler reaches its "start" marker before any of them reaches "end".

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local epoll_mod = require("lib.epoll")
local async = require("lib.async")
local http_server = require("lib.http.server")
local client_mod = require("lib.http.client")
local format = require("lib.http.format")

-- Ephemeral test port — high number to avoid conflicts with system services.
local TEST_PORT = 19090

T.describe("http/server concurrency", function()
	T.it("services multiple simultaneous connections via the event loop, not serialized", function()
		local ep = epoll_mod.new()
		local loop = async.loop(ep)

		local n = 5
		local sleep_ms = 40
		local order = {} --: { [integer]: string }

		-- Closes over `loop` (the real, fully-typed lib/async LoopObj created
		-- above) instead of reading the connection's private `sock._loop` field,
		-- so no cross-module cast is needed — this is the same loop instance
		-- socket/server.lua assigns to each client, since it was handed to
		-- http_server.server via opts.loop below.
		--: (req: { target: string, ... }, res: { status: integer, headers: { [string]: string[] }, body: string | nil, ... }, sock: unknown) -> nil
		local function handler(req, res, _sock)
			order[#order + 1] = "start:" .. req.target

			async.await(loop:sleep(sleep_ms))

			order[#order + 1] = "end:" .. req.target
			res.status = 200
			res.headers["content-type"] = { "text/plain" }
			res.body = "response for " .. req.target
		end

		local srv = http_server.server(handler, TEST_PORT, nil, {
			host = nil,
			tls_cert = nil,
			tls_key = nil,
			idle_timeout = nil,
			max_requests = nil,
			loop = loop,
		})

		local results = {} --: { [integer]: { data: string | nil, err: string | nil } }
		local completed = 0

		for i = 1, n do
			client_mod.send_async({
				host = "127.0.0.1",
				port = tostring(TEST_PORT),
				method = "GET",
				path = "/" .. i,
				version = "HTTP/1.1",
				headers = nil,
				body = nil,
			}, function(data, err)
				results[i] = { data = data, err = err }
				completed = completed + 1
			end, ep)
		end

		-- Drive the shared async loop by hand (loop:step polls, then fires due
		-- timers/microtasks — driving the raw poller alone would never fire
		-- the sleep timers the handler awaits on). Bounded iteration count so
		-- a regression that hangs the loop fails the test instead of the suite.
		local max_iters = 20000
		local iters = 0
		while completed < n and iters < max_iters do
			loop:step()
			iters = iters + 1
		end

		srv:close()

		T.eq(completed, n, "all " .. n .. " requests completed")

		for i = 1, n do
			local r = results[i]
			T.ok(r ~= nil, "request " .. i .. " produced a result")
			if r then
				T.ok(r.err == nil, "request " .. i .. ": no error: " .. tostring(r.err))
				if r.data then
					local parsed = format.parse_response(r.data)
					T.ok(parsed ~= nil, "request " .. i .. ": valid HTTP response")
					if parsed then
						T.eq(parsed.status, 200)
						T.eq(parsed.body, "response for /" .. i)
					end
				end
			end
		end

		-- Prove non-serialization: every "start" marker must appear before the
		-- first "end" marker. If requests were serialized, "end:/1" would land
		-- before "start:/2" ever ran.
		local first_end_index = nil --: integer | nil
		for idx = 1, #order do
			if order[idx]:find("^end:") and not first_end_index then
				first_end_index = idx
			end
		end
		T.ok(first_end_index ~= nil, "at least one request completed its handler")
		if first_end_index then
			T.ok(first_end_index >= n,
				"all " .. n .. " handlers started before the first one finished (order: "
					.. table.concat(order, ", ") .. ")")
		end
	end)
end)
