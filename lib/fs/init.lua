if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local dir_list = require("lib.fs.dir_list")
local ops      = require("lib.fs.ops")

return {
	--: (string | nil) -> (() -> (file_info | nil, string | nil))
	dir_list = dir_list.dir_list,
	--: (string | nil) -> (file_info | nil, string | nil)
	dir_info = dir_list.dir_info,
	--: (string | nil) -> (file_info | nil, string | nil)
	stat = dir_list.stat,
	--: (string) -> (true | nil, string | nil)
	mkdir = ops.mkdir,
	--: (string) -> (true | nil, string | nil)
	rmdir = ops.rmdir,
	--: (string) -> (true | nil, string | nil)
	unlink = ops.unlink,
}
