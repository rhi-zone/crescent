-- lib/type/v10_cleanroom/init.lua
-- v10 kernel core, cleanroom reference implementation: term algebra
-- (reference tier) + certificate replayer. Spec:
-- docs/decisions/typechecker-v10-core-design.md (+ the F1..F13
-- adjudication rulings, 2026-07-29).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {
	term_algebra = require("lib.type.v10_cleanroom.term_algebra"),
	replayer = require("lib.type.v10_cleanroom.replayer"),
}

return M
