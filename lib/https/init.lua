if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local client = require("lib.https.client")

--:: http_request = { method: string, host: string, port?: number, path: string, headers?: { [string]: string }, body?: string }
--:: http_response = { version: number, status: number, status_text: string, headers: { [string]: string }, body: string }

local M = {}

-- Send an HTTPS request and return the full response.
-- Returns (nil, errmsg) on any failure.
--: (http_request) -> http_response?, string?
M.request = client.request

-- Send an HTTPS request and return streaming read/close functions.
-- On success: returns (recv_fn, close_fn).
-- On failure: returns (nil, errmsg).
--: (http_request) -> ((() -> string?, string?)?, (() -> nil)?) | (nil, string?)
M.stream = client.stream

return M
