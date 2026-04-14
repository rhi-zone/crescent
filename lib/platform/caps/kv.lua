-- lib/platform/caps/kv.lua
-- kv_cap(path) -> capability table, revoke_fn
-- Simple key-value store backed by a file.
-- For now, uses an in-memory table (persistence is a future concern).
--
-- path : string (backing file path — reserved for future persistence)
--
-- Capability API (passed to sandbox as caps.kv):
--   cap.get(key)        -> value | nil
--   cap.set(key, value) -> true
--   cap.del(key)        -> true
--   cap.keys()          -> string[]

local M = {}

function M.kv_cap(path)
	local store = {}
	local revoked = false

	local cap = {
		get = function(key)
			if revoked then return nil, "kv: capability revoked" end
			return store[key]
		end,
		set = function(key, value)
			if revoked then return nil, "kv: capability revoked" end
			store[key] = value
			return true
		end,
		del = function(key)
			if revoked then return nil, "kv: capability revoked" end
			store[key] = nil
			return true
		end,
		keys = function()
			if revoked then return nil, "kv: capability revoked" end
			local result = {}
			for k in pairs(store) do result[#result + 1] = k end
			return result
		end,
		-- Expose path for testing/debugging
		_path = path,
	}

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
