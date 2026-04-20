-- lib/platform/service/init.lua
-- Service layer: write methods once, project to HTTP and/or CLI.
--
-- M.create(caps, methods, descriptors) -> { handler, cli }
-- Convenience wrapper that builds both projections at once.
--
-- Individual projections:
--   require("lib.platform.service.http").create(caps, methods, desc) -> { handler }
--   require("lib.platform.service.cli").create(caps, methods, desc)  -> { cli }

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local http_proj = require("lib.platform.service.http")
local cli_proj  = require("lib.platform.service.cli")

local M = {}

M.http = http_proj
M.cli  = cli_proj

-- create(caps, methods, descriptors) -> { handler, cli }
-- Builds both HTTP and CLI projections and returns them together.
--: (unknown, { [string]: unknown }, { [string]: unknown } | nil) -> { handler: unknown, cli: unknown }
function M.create(caps, methods, descriptors)
	local http_srv = http_proj.create(caps, methods, descriptors)
	local cli_srv  = cli_proj.create(caps, methods, descriptors)
	return {
		handler = http_srv.handler,
		cli     = cli_srv.cli,
	}
end

return M
