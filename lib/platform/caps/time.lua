-- lib/platform/caps/time.lua
-- time_cap() -> capability table
-- Provides time-related functions to sandboxed apps.
--
-- Capability API (passed to sandbox as caps.time):
--   cap.now()     -> number (os.time())
--   cap.clock()   -> number (os.clock())

local M = {}

function M.time_cap()
	return {
		now = function() return os.time() end,
		clock = function() return os.clock() end,
	}
end

return M
