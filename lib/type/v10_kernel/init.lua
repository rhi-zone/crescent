-- lib/type/v10_kernel/init.lua
-- v10 trust-core prototype: exploratory, dinner-sized. See README.md and
-- NOTATION.md before reading the modules themselves.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

return {
	kernel = require("lib.type.v10_kernel.kernel"),
	registry = require("lib.type.v10_kernel.registry"),
	w = require("lib.type.v10_kernel.theories.algorithm_w"),
	j = require("lib.type.v10_kernel.theories.algorithm_j"),
}
