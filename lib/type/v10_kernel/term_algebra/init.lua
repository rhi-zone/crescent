-- lib/type/v10_kernel/term_algebra/init.lua
--
-- Public entry point for the v10 kernel term algebra
-- (docs/decisions/typechecker-v10-core-design.md,
-- docs/decisions/typechecker-v10-core-charter.md). Cleanroom-built; NOT yet
-- wired into the existing lib/type/v10_kernel/kernel.lua replayer — that
-- integration is a separate, later task per the charter.
--
--   local kernel = require("lib.type.v10_kernel.term_algebra")
--   local sig, err = kernel.declare_signature(spec)
--   local k, err = kernel.new({ tier = "reference" })   -- or "fast"
--   local t, err = k.build_var(0, "term")
--   ...
--
-- Tier selection is explicit and caps-first (passed in via `opts`, never an
-- ambient global or auto-selected-at-load-time default) — per the ratified
-- design, tier choice is a deliberate trust decision (run-level axiom
-- exposure), not a "best available" fallback the way system/FFI/pure tiers
-- are elsewhere in this repo.
--
-- Tier framing note (an implementation-scope choice, not a semantics gap):
-- the ratified design names exactly two tiers — "a reference tier" and "a
-- fast tier" — each bundling one `eq` choice with one `subst` choice
-- (reference=structural-eq+eager-subst, fast=interned-eq+lazy-subst), and
-- separately names two per-primitive axioms (kernel-interner-sound-v1,
-- kernel-lazy-subst-sound-v1). This module selects tiers atomically
-- (`"reference"` | `"fast"`) rather than exposing all four `{eq, subst}`
-- combinations independently — matching the doc's own two-tier framing —
-- while still reporting the full `{eq, subst}` trust-label shape the
-- design's run-level trust carveout specifies.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local shared = require("lib.type.v10_kernel.term_algebra.shared")
local reference = require("lib.type.v10_kernel.term_algebra.reference")
local fast = require("lib.type.v10_kernel.term_algebra.fast")

local M = {}

--:: Sort = string
--:: OpArgSpec = { sort: Sort, binds: Sort[] | nil }
--:: OpSpec = { result: Sort, args: OpArgSpec[] | nil }
--:: SignatureSpec = { name: string, version: integer, sorts: Sort[], ops: { [string]: OpSpec } }
--:: OpArgDecl = { sort: Sort, binds: Sort[], bound_count: integer }
--:: OpDecl = { name: string, sig_name: string, sig_version: integer, result: Sort, args: OpArgDecl[], arity: integer }
--:: Signature = { name: string, version: integer, sorts: { [string]: boolean }, ops: { [string]: OpDecl } }

--:: TrustLabel = { eq: string, subst: string }
--:: TierOpts = { tier: string | nil }

-- Declare a theory's operator vocabulary once. See shared.lua for the
-- ratified spec shape and validation contract.
--: (spec: unknown) -> (Signature | nil, string | nil)
function M.declare_signature(spec)
	return shared.declare_signature(spec)
end

--: (tier: string) -> TrustLabel
local function trust_label_for(tier)
	if tier == "fast" then return { eq = "interned", subst = "lazy" } end
	return { eq = "reference", subst = "eager" }
end

-- Select a kernel-primitive tier. opts.tier: "reference" (default) | "fast".
--: (opts: TierOpts | nil) -> (unknown | nil, string | nil)
function M.new(opts)
	local tier = (opts and opts.tier) or "reference"
	if tier == "reference" then
		local inst = {}
		inst.build_var = reference.build_var
		inst.build_meta = reference.build_meta
		inst.build = reference.build
		inst.sort_of = reference.sort_of
		inst.is_ground = reference.is_ground
		inst.is_closed = reference.is_closed
		inst.equal = reference.equal
		inst.shift = reference.shift
		inst.subst = reference.subst
		inst.match = reference.match
		inst.instantiate = reference.instantiate
		inst.tier = "reference"
		inst.trust_label = trust_label_for("reference")
		return inst
	elseif tier == "fast" then
		local inst = fast.new()
		inst.tier = "fast"
		inst.trust_label = trust_label_for("fast")
		return inst
	end
	return nil, "new: unknown tier " .. tostring(tier) .. " (expected \"reference\" or \"fast\")"
end

return M
