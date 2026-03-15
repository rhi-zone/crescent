if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

return {
	manifest = require("lib.pkg.manifest"),
}
