-- lib/platform/caps/time.lua
-- time_cap() -> cap_table, revoke_fn
-- Clock capability for sandboxed apps.
--
-- Capability API:
--   cap.now() -> integer | nil, string   (Unix timestamp via os.time())

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- time_cap() -> cap_table, revoke_fn
function M.time_cap()
	local revoked = false

	local cap = {
		now = function()
			if revoked then return nil, "capability revoked" end
			return os.time()
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
