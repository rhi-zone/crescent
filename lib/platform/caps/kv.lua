-- lib/platform/caps/kv.lua
-- kv_cap() -> cap_table, revoke_fn
-- In-memory key-value store capability for sandboxed apps.
--
-- Capability API:
--   cap.get(key) -> value | nil, string
--   cap.set(key, value) -> true | nil, string

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- kv_cap() -> cap_table, revoke_fn
function M.kv_cap()
	local store = {}
	local revoked = false

	local cap = {
		get = function(key)
			if revoked then return nil, "capability revoked" end
			return store[key]
		end,

		set = function(key, value)
			if revoked then return nil, "capability revoked" end
			store[key] = value
			return true
		end,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
