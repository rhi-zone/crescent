-- lib/platform/caps/http_server.lua
-- http_server_cap(opts) -> capability table, revoke_fn
-- Stub: provides the interface shape. Actual serving requires lib/http wiring.
--
-- opts.port : number (0 = auto-assign)
--
-- Capability API (passed to sandbox as caps.http_server):
--   cap.port()     -> number  (the bound port)
--   cap.on(method, path, handler) -> nil  (register a route)
--   cap.start()    -> true | nil, err
--   cap.stop()     -> true

local M = {}

function M.http_server_cap(opts)
	opts = opts or {}
	local port = opts.port or 0
	local routes = {}
	local running = false

	local cap = {
		port = function() return port end,
		on = function(method, path, handler)
			routes[#routes + 1] = { method = method, path = path, handler = handler }
		end,
		start = function()
			-- Stub: real implementation would bind and listen
			running = true
			return true
		end,
		stop = function()
			running = false
			return true
		end,
	}

	local function revoke()
		running = false
		routes = {}
	end

	return cap, revoke
end

return M
