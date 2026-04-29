if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local dir_list = require("lib.fs.dir_list")

return {
	--: (string | nil) -> (() -> (file_info | nil, string | nil))
	dir_list = dir_list.dir_list,
	--: (string | nil) -> (file_info | nil, string | nil)
	dir_info = dir_list.dir_info,
}
