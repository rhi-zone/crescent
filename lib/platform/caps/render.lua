-- lib/platform/caps/render.lua
-- render_cap(session) -> capability table
-- The render surface is caller-supplied (SSE, WebSocket, collect buffer, etc.).
-- This module provides the cap factory plus two built-in session types.
--
-- Capability API (passed to sandbox as caps.render):
--   cap.push(content)  -> nil   (content: string or table)
--   cap.flush()        -> nil   (flush buffered output; no-op for streaming sessions)
--
-- Built-in session constructors:
--   render.sse_session(write_fn)  -> session
--     write_fn(bytes): raw write function for a live HTTP connection.
--     Wraps each push in SSE "data: ...\n\n" frames. Tables are JSON-encoded.
--
--   render.collect_session()  -> session, get_all
--     Buffers all pushed content; get_all() returns the array.
--     Useful for testing and batch-mode scripts.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- render_cap(session) -> {push, flush}
-- session must implement :push(content) and optionally :flush().
function M.render_cap(session)
	return {
		push = function (content)
			session:push(content)
		end,
		flush = function ()
			local flush = session.flush
			if type(flush) == "function" then flush(session) end
		end,
	}
end

-- sse_session(write_fn) -> session
-- Streams content as Server-Sent Events (SSE) over an open HTTP connection.
-- Each push emits:  data: <content>\n\n
-- Tables are encoded as JSON; strings are sent verbatim.
function M.sse_session(write_fn)
	local json  -- lazy: only needed if caller pushes tables
	return {
		push = function (_, content)
			local str
			if type(content) == "string" then
				str = content
			else
				if not json then json = require("lib.format.json") end
				local encode = json.encode
				local enc = type(encode) == "function" and encode(content) or nil
				str = enc or tostring(content)
			end
			write_fn("data: " .. str .. "\n\n")
		end,
		flush = function () end,
	}
end

-- collect_session() -> session, get_all
-- Buffers all pushed content in an array.
-- get_all() returns that array (live reference — call after the script finishes).
function M.collect_session()
	local items = {}
	local session = {
		push = function (_, content)
			items[#items + 1] = content
		end,
		flush = function () end,
	}
	return session, function () return items end
end

return M
