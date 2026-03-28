if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.server = require("lib.socket.server").server

-- For client-side TCP, use lib/tcp/client.lua

return M
