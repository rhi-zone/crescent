-- lib/platform/caps/stdin.lua
-- stdin_cap(opts?) -> cap_table, revoke_fn
-- Standard input capability for sandboxed apps.
--
-- Capability API:
--   cap.read(n?) -> string | nil, string   (reads n bytes, or all if n is nil)
--   cap.line()   -> string | nil, string   (reads one line)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- stdin_cap(opts?) -> cap_table, revoke_fn
function M.stdin_cap(opts)
	local revoked = false

	local cap = {
		_type = "stdin",
		read = function(n)
			if revoked then return nil, "capability revoked" end
			if n then
				return io.stdin:read(n)
			else
				return io.stdin:read("*a")
			end
		end,

		line = function()
			if revoked then return nil, "capability revoked" end
			return io.stdin:read("*l")
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
