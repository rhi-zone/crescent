-- lib/platform/caps/stderr.lua
-- stderr_cap() -> cap_table, revoke_fn
-- Standard error capability for sandboxed apps.
--
-- Capability API:
--   cap.write(str) -> true | nil, string   (writes string to stderr)
--   cap.flush()    -> true | nil, string   (flushes stderr)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._type = "stderr"

-- stderr_cap() -> cap_table, revoke_fn
function M.stderr_cap()
	local revoked = false

	local cap = {
		_type = "stderr",
		write = function(str)
			if revoked then return nil, "capability revoked" end
			io.stderr:write(str)
			return true
		end,

		flush = function()
			if revoked then return nil, "capability revoked" end
			io.stderr:flush()
			return true
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

function M.risk(_)
	return { severity = "low", text = "Writes to standard error." }
end

return M
