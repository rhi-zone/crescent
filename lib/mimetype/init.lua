if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local by_name = require("lib.mimetype.by_name")
local by_contents = require("lib.mimetype.by_contents")

local M = {}

--[[@param filename string]]
--[[@return string? mimetype]]
--: (string) -> string | nil
M.by_name = function(filename)
	return (by_name.mimetype --[[: any]])(filename)
end

--[[@param buffer string]]
--[[@param pos integer?]]
--[[@return string? ext, string? mimetype]]
--: (string, integer | nil) -> (string | nil, string | nil)
M.by_contents = function(buffer, pos)
	local ext, mt = (by_contents.mimetype --[[: any]])(buffer, pos)
	return ext --[[:! string | nil]], mt --[[:! string | nil]]
end

--[[@param filename string]]
--[[@param buffer string]]
--[[@return string? mimetype]]
--: (string, string) -> string | nil
M.detect = function(filename, buffer)
	local mt = (by_name.mimetype --[[: any]])(filename)
	if mt then return mt end
	local _, mt2 = (by_contents.mimetype --[[: any]])(buffer)
	return mt2 --[[:! string | nil]]
end

return M
