-- lib/platform/caps/cli.lua
-- cli_cap(args) -> cap_table, revoke_fn
-- CLI arguments capability for sandboxed apps.
--
-- Capability API:
--   cap.args() -> table | nil, string   (shallow copy of the args table)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- cli_cap(args) -> cap_table, revoke_fn
--: (args: {string}) -> ({ args: () -> {string} | (nil, string) }, () -> ())
function M.cli_cap(args)
	local revoked = false

	local cap = {
		args = function()
			if revoked then return nil, "capability revoked" end
			local copy = {}
			for i = 1, #args do
				copy[i] = args[i]
			end
			return copy
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
