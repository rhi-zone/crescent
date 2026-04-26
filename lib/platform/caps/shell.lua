-- lib/platform/caps/shell.lua
-- shell_cap() -> cap_table, revoke_fn
-- Runs arbitrary shell command strings. stdout and stderr merged.
--
-- Capability API:
--   cap.run(cmd) -> output: string | nil, err: string

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

function M.shell_cap()
	local revoked = false

	local cap = {
		run = function(cmd)
			if revoked then return nil, "shell: capability revoked" end
			if type(cmd) ~= "string" then return nil, "shell: command must be a string" end
			local fh, err = io.popen(cmd .. " 2>&1", "r")
			if not fh then return nil, "shell: popen failed: " .. tostring(err) end
			local out = fh:read("*a")
			fh:close()
			return out or ""
		end,
	}

	local function revoke() revoked = true end

	return cap, revoke
end

return M
