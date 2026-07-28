-- lib/type/v10_kernel/pilot/narrow_pilot_v1.lua
--
-- Pilot type vocabulary signature (`narrow-pilot-v1`), per
-- docs/typechecker-v10-pilot-signatures-proposal.md §2. Previously blocked
-- at §3/§4 of the proposal — its `holds_at` operator needs to cite
-- addr-v1's `point` and `path` sorts, and at proposal time
-- `declare_signature` had no cross-signature sort mechanism. Phase 1
-- (docs/decisions/typechecker-v10-core-design.md, "Sort identity:
-- identity-by-declaration + explicit imports") closed that gap by giving
-- `declare_signature` a `spec.imports` field: cite a SortDecl object
-- already owned by another, previously-declared signature under a local
-- name, usable in this signature's op specs exactly like a locally-declared
-- sort. This signature's own `sorts` list holds only `prim_tag, ty,
-- judgment`; `point`/`path` are imported from an already-declared addr-v1
-- signature, resolving proposal §4 via option (C) rather than (A) merging
-- the two signatures or (B) an unenforced same-name convention.
--
-- Deliberately signature-only (no rules/axioms/side-conditions/replayer
-- wiring): that is pilot step 3+, gated separately. Per proposal §2.4, no
-- side condition is needed for this vocabulary.

local term_algebra = require("lib.type.v10_kernel.term_algebra")

--:: SortDecl = { name: string, sig_name: string, sig_version: integer }
--:: Signature = { name: string, version: integer, sorts: { [string]: SortDecl }, sort_set: { [unknown]: boolean }, ops: unknown }

local M = {}

-- Declare the narrow-pilot-v1 signature, importing `point` and `path` from
-- an already-declared addr-v1 signature (see pilot/addr_v1.lua). The
-- dependency is passed explicitly, caps-clean — no hidden global signature
-- registry.
--
-- `addr_sig` is typed `unknown` and narrowed by hand (same pattern as
-- hm.lua's `declare_vocabulary(k)`), not declared as `Signature` up front —
-- doing so confuses the typechecker's runtime-guard narrowing (a `type(x)
-- ~= "table"` check on an already-record-typed value widens the else
-- branch back to `unknown` instead of preserving the declared shape).
--: (addr_sig: unknown) -> (Signature | nil, string | nil)
function M.declare(addr_sig)
	if type(addr_sig) ~= "table" then
		return nil, "narrow_pilot_v1.declare: addr_sig (a declared addr-v1 signature) is required"
	end
	local addr_sig_t = addr_sig --[[: Signature ]]
	local addr_sorts = addr_sig_t.sorts
	local point_sort = addr_sorts.point
	local path_sort = addr_sorts.path
	if not point_sort or not path_sort then
		return nil, "narrow_pilot_v1.declare: addr_sig must declare point and path sorts"
	end

	return term_algebra.declare_signature({
		name = "narrow-pilot-v1",
		version = 1,
		sorts = { "prim_tag", "ty", "judgment" },
		imports = { point = point_sort, path = path_sort },
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
