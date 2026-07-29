-- lib/type/v10_kernel/pilot/narrow_pilot_v1.lua
--
-- Pilot type vocabulary signature (`narrow-pilot-v1`), per
-- docs/typechecker-v10-pilot-signatures-proposal.md §2, declared over the
-- canonical v10 core (lib/type/v10_cleanroom/, per the owner-ratified
-- canon swap). Its `holds_at` operator cites addr-v1's `point` and `path`
-- sorts via the canonical `imports` clause: a list of
-- { from = <source signature>, sorts = { names } } citations — the
-- imported sort objects ARE the source signature's own objects (sort
-- identity is declared-object identity), resolving proposal §4 via option
-- (C) rather than (A) merging the two signatures or (B) an unenforced
-- same-name convention. This signature's own `sorts` list holds only
-- `prim_tag, ty, judgment`.
--
-- Deliberately signature-only (no rules/axioms/side-conditions/replayer
-- wiring): that is pilot step 3+, gated separately. Per proposal §2.4, no
-- side condition is needed for this vocabulary.

local ta = require("lib.type.v10_cleanroom.term_algebra")

local M = {}

-- Declare the narrow-pilot-v1 signature, importing `point` and `path` from
-- an already-declared addr-v1 signature (see pilot/addr_v1.lua). The
-- dependency is passed explicitly, caps-clean — no hidden global signature
-- registry.
-- `addr_sig` is typed `unknown` and narrowed by hand: a `type(x) ~=
-- "table"` guard on an already-record-typed parameter widens the else
-- branch back to `unknown` (the same typechecker gotcha the pre-swap file
-- documented), so the runtime guard runs on `unknown` and a checked cast
-- restores the shape.
--: (addr_sig: unknown) -> (Signature | nil, string | nil)
function M.declare(addr_sig)
	if type(addr_sig) ~= "table" then
		return nil, "narrow_pilot_v1.declare: addr_sig (a declared addr-v1 signature) is required"
	end
	local sig_in = addr_sig --[[: Signature ]]
	local addr_sorts = sig_in.sorts
	if type(addr_sorts) ~= "table" or not addr_sorts.point or not addr_sorts.path then
		return nil, "narrow_pilot_v1.declare: addr_sig must declare point and path sorts"
	end

	return ta.declare_signature({
		name = "narrow-pilot-v1",
		version = 1,
		sorts = { "prim_tag", "ty", "judgment" },
		imports = { { from = sig_in, sorts = { "point", "path" } } },
		ops = {
			tag_nil      = { result = "prim_tag", args = {} },
			tag_boolean  = { result = "prim_tag", args = {} },
			tag_true     = { result = "prim_tag", args = {} },
			tag_false    = { result = "prim_tag", args = {} },
			tag_number   = { result = "prim_tag", args = {} },
			tag_string   = { result = "prim_tag", args = {} },
			tag_table    = { result = "prim_tag", args = {} },
			tag_function = { result = "prim_tag", args = {} },

			ty_of        = { result = "ty", args = { { sort = "prim_tag" } } },
			ty_union     = { result = "ty", args = { { sort = "ty" }, { sort = "ty" } } },

			holds_at     = { result = "judgment", args = { { sort = "point" }, { sort = "path" }, { sort = "ty" } } },
		},
	})
end

return M
