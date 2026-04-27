-- lib/platform/caps/stdout.lua
-- stdout_cap(opts?) -> cap_table, revoke_fn
-- Standard output capability for sandboxed apps.
--
-- Capability API:
--   cap.write(str) -> true | nil, string   (writes string to stdout)
--   cap.flush()    -> true | nil, string   (flushes stdout)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- stdout_cap(opts?) -> cap_table, revoke_fn
function M.stdout_cap(opts)
	local revoked = false

	local cap = {
		_type = "stdout",
		write = function(str)
			if revoked then return nil, "capability revoked" end
			io.stdout:write(str)
			return true
		end,

		flush = function()
			if revoked then return nil, "capability revoked" end
			io.stdout:flush()
			return true
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
