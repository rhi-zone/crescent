if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local dir_list = require("lib.fs.dir_list")

return {
	--: (string?) -> fun(): file_info | nil, string?
	dir_list = dir_list.dir_list,
	--: (string?) -> file_info | nil, string?
	dir_info = dir_list.dir_info,
}
