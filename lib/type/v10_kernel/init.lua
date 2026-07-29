-- lib/type/v10_kernel/init.lua
-- v10 typechecker theories and pilot over the CANONICAL core.
--
-- The core itself lives in lib/type/v10_cleanroom/ (term_algebra +
-- replayer), per the owner-ratified canon swap
-- (docs/decisions/typechecker-v10-core-design.md, "Canon swap: cleanroom
-- core"). This directory's prior core (term_algebra/ + replayer/,
-- including its fast tier) is retired — git history preserves it; the
-- retirement evidence is the differential adjudication at
-- docs/typechecker-v10-parity-adjudication.md. The fast tier will be
-- rebuilt against the canonical reference as a separate, axiom-carrying
-- effort (see TODO.md).
--
-- What remains here: the Hindley-Milner theory entries (theories/) and the
-- flow-narrowing pilot (pilot/), all built on the canonical core. See
-- README.md and NOTATION.md.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local core = require("lib.type.v10_cleanroom")

return {
	-- The canonical core, re-exported for convenience; the source of truth
	-- is lib/type/v10_cleanroom/.
	term_algebra = core.term_algebra,
	replayer = core.replayer,
	hm = require("lib.type.v10_kernel.theories.hm"),
	w = require("lib.type.v10_kernel.theories.algorithm_w"),
	j = require("lib.type.v10_kernel.theories.algorithm_j"),
}
