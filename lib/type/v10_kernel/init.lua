-- lib/type/v10_kernel/init.lua
-- v10 typechecker core: term algebra + replayer, plus the ported
-- Hindley-Milner theory entries (algorithm_w, algorithm_j) built on top of
-- them. See README.md and NOTATION.md before reading the modules
-- themselves. The retired kernel.lua/registry.lua trust-core prototype has
-- been ported and removed — see docs/decisions/typechecker-v10-core-design.md
-- and docs/decisions/typechecker-v10-core-charter.md.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

return {
	term_algebra = require("lib.type.v10_kernel.term_algebra"),
	replayer = require("lib.type.v10_kernel.replayer"),
	hm = require("lib.type.v10_kernel.theories.hm"),
	w = require("lib.type.v10_kernel.theories.algorithm_w"),
	j = require("lib.type.v10_kernel.theories.algorithm_j"),
}
