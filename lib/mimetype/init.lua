if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local by_name = require("lib.mimetype.by_name")
local by_contents = require("lib.mimetype.by_contents")

local M = {}

--: (string) -> string | nil
M.by_name = function(filename)
	return (by_name.mimetype)(filename)
end

--: (string, integer | nil) -> (string | nil, string | nil)
M.by_contents = function(buffer, pos)
	return (by_contents.mimetype)(buffer, pos)
end

--: (string, string) -> string | nil
M.detect = function(filename, buffer)
	local mt = (by_name.mimetype)(filename)
	if mt then return mt end
	local _, mt2 = (by_contents.mimetype)(buffer)
	return mt2
end

return M
