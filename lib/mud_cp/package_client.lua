local base = require("lib.mud_cp.client")

local mod = {}

--:: mcp_message_handler = (self_: unknown, message: unknown) -> nil
--:: mcp_package = { name?: string, version?: integer[], min_version?: integer[], max_version?: integer[], message_handlers?: { [string]: mcp_message_handler }, init?: (self_: unknown) -> nil }
--:: mcp = { packages: mcp_package[], message_handlers: { [string]: mcp_message_handler } }

-- TODO: need to create a mcp instance
-- TODO: sending messages, configuring which fields must be multiline regardless of newline presence,
-- support for mcp 1.0 (both understanding and sending)
-- FIXME: can't work since 
-- TODO: it should wrap write...
--: (cb: (string) -> nil, packages: mcp_package[] | nil) -> ((string) -> nil, ((string) -> nil) -> (string) -> nil)
mod.wrap = function (cb, packages)
	packages = packages or {}
	--: mcp
	local self = {
		packages = packages,
		message_handlers = {},
	}
	for i = 1, #packages do
		for k, h in pairs(packages[i].message_handlers or {}) do
			self.message_handlers[k] = h
		end
	end
	-- must be in a separate loop because `self` must be filled in before `init` is called
	for i = 1, #packages do
		local init = packages[i].init
		if init then init(self) end
	end
	return base.wrap(cb, function (type, value)
		local fn = self.message_handlers[type]
		if fn then fn(self, value) end
	end)
end

-- 0xFF 0xFB 0xC9

return mod
