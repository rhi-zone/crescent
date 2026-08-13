-- lib/os_isolation/result_codec.lua
-- Internal wire format: encode/decode a pcall-style (ok, result) pair for a
-- forked child to hand back to its parent across a pipe. Shared by
-- fork_direct.lua (parent reads it directly) and fork_supervisor.lua (the
-- supervisor relays it verbatim from child to caller, undecoded, then the
-- caller decodes it) so the "how did the child's call go" shape lives in one
-- place instead of two.
--
-- Only JSON-representable values survive the crossing: numbers, strings,
-- booleans, nil, and plain tables of those. A function/userdata/FFI cdata
-- returned BY the child is reported as an encode error, not silently
-- dropped or coerced.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.json")

local M = {}

local ENCODE_FAILURE_FALLBACK = '{"ok":false,"err":"result_codec: could not encode payload"}'

--: (boolean, unknown) -> string
function M.encode(ok, result)
	if not ok then
		local encoded = json.encode({ ok = false, err = tostring(result) })
		return encoded or ENCODE_FAILURE_FALLBACK
	end
	local encoded = json.encode({ ok = true, result = result })
	if encoded then return encoded end
	local err_encoded = json.encode({ ok = false, err = "result_codec: could not encode child result" })
	return err_encoded or ENCODE_FAILURE_FALLBACK
end

--: (string) -> (boolean, unknown)
function M.decode(payload)
	local decoded_, err = json.decode(payload)
	if not decoded_ or type(decoded_) ~= "table" then
		return false, "result_codec: malformed child response: " .. tostring(err)
	end
	local decoded = decoded_ --[[: { ok: boolean, result: unknown, err: string } ]]
	if decoded.ok then
		return true, decoded.result
	end
	return false, decoded.err
end

return M
