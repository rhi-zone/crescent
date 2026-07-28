-- lib/type/v10_kernel/replayer/init.lua
--
-- Public entry point for the v10 kernel replayer
-- (docs/decisions/typechecker-v10-core-design.md,
-- docs/decisions/typechecker-v10-core-charter.md). Cleanroom-built over
-- lib/type/v10_kernel/term_algebra/ only; does not read or depend on the
-- retired lib/type/v10_kernel/kernel.lua replayer.
--
--   local term_algebra = require("lib.type.v10_kernel.term_algebra")
--   local replayer = require("lib.type.v10_kernel.replayer")
--
--   local sig = term_algebra.declare_signature({ ... })
--   local rule, err = replayer.declare_rule({ name=..., version=1, signature=sig, premises={...}, conclusion=..., discharges={...} })
--   local axiom, err = replayer.declare_axiom({ name=..., version=1, signature=sig, pattern=... })
--
--   local hyp = replayer.hypothesis("h1", judgment_term)
--   local node = replayer.cite_rule(rule, { premise_node, ... }, { {"h1"} })
--
--   local k = term_algebra.new({ tier = "reference" })   -- caps-first: injected, never ambient
--   local r, err = replayer.new(k)
--   local root, err = r:replay_root(node)   -- { conclusion, trust = { taint, run_label } }

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local registry = require("lib.type.v10_kernel.replayer.registry")
local certificate = require("lib.type.v10_kernel.replayer.certificate")
local replay = require("lib.type.v10_kernel.replayer.replay")

local M = {}

-- Registry declarations (registry.lua).
M.declare_rule = registry.declare_rule
M.declare_axiom = registry.declare_axiom

-- Certificate node constructors (certificate.lua).
M.hypothesis = certificate.hypothesis
M.cite_axiom = certificate.cite_axiom
M.cite_rule = certificate.cite_rule

-- Replayer construction (replay.lua). Tier choice (and therefore trust
-- exposure) lives entirely in the caller-supplied term_algebra instance
-- `k` — never selected or defaulted here.
M.new = replay.new

return M
