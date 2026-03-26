if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

return {
	manifest  = require("lib.pkg.manifest"),
	lock      = require("lib.pkg.lock"),
	semver    = require("lib.pkg.semver"),
	config    = require("lib.pkg.config"),
	install   = require("lib.pkg.install"),
	check     = require("lib.pkg.check"),
	workspace = require("lib.pkg.workspace"),
}
