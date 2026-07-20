#!/usr/bin/env luajit
local arg = arg --[[@type unknown[] ]]
if pcall(debug.getlocal, 4, 1) then arg = { ... }
else package.path = arg[0]:gsub("lua/.+$", "lua/?.lua", 1) .. ";" .. package.path end

local json = require("lib.format.json")

-- WebSocket echo server: prints each received message as JSON, echoes it back.
require("lib.http.server_ws").server({
	ws = function(ws_conn, req)
		io.stderr:write("[info] websocket connected: " .. req.target .. "\n")
		while true do
			local msg, err = ws_conn:recv()
			if not msg then
				io.stderr:write("[info] websocket closed: " .. tostring(err) .. "\n")
				return
			end
			print(json.value_to_json(msg))
			ws_conn:send(msg.payload, msg.type)
		end
	end,
}, tonumber(arg[1] or os.getenv("PORT") or os.getenv("port")))
