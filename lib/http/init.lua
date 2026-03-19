if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local status = require("lib.http.status")

return {
	format = require("lib.http.format"),
	client = require("lib.http.client"),
	status_names = status.status_names,
	status_ids = status.status_ids,
}
