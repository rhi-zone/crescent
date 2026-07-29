-- lib/type/v10_kernel/pilot/narrow_pilot_v1_test.lua
--
-- narrow-pilot-v1's own smoke tests over the canonical v10 core, plus the
-- cross-signature identity checks this pilot exists to demonstrate
-- (docs/typechecker-v10-pilot-signatures-proposal.md §4, resolved by the
-- sort-identity `imports` mechanism):
--   1. both signatures declare with no errors
--   2. a representative holds_at judgment term builds over a real
--      point/path (from addr-v1) and a ty (from narrow-pilot-v1's own ops)
--   3. the imported point/path sorts ARE addr-v1's own sort objects, not
--      merely same-named copies — a term built via addr-v1's own operators
--      is usable directly as a holds_at argument with no conversion
--   4. an unrelated THIRD signature that declares its own same-named
--      `point` sort (not imported from addr-v1) is rejected when used
--      where addr-v1's point is expected — confirming the identity
--      protection actually holds at this pilot's real use site.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local narrow_pilot_v1 = require("lib.type.v10_kernel.pilot.narrow_pilot_v1")

--: (v: Term | nil, err: string | nil) -> Term
local function must_term(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Signature | nil, err: string | nil) -> Signature
local function must_sig(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

T.describe("narrow-pilot-v1", function()
	local addr_sig = must_sig(addr_v1.declare())

	T.it("declares with no errors, given an already-declared addr-v1", function()
		local sig, err = narrow_pilot_v1.declare(addr_sig)
		T.ok(sig, err)
		if sig == nil then return end
		T.eq(sig.name, "narrow-pilot-v1")
		T.eq(sig.version, 1)
		-- the imported sorts are the SAME objects addr-v1 owns, not copies
		T.eq(sig.sorts.point, addr_sig.sorts.point)
		T.eq(sig.sorts.path, addr_sig.sorts.path)
	end)

	T.it("builds a holds_at judgment over a real point/path and a ty from prim tags", function()
		local narrow_sig = must_sig(narrow_pilot_v1.declare(addr_sig))
		local addr_ops = addr_sig.ops
		local narrow_ops = narrow_sig.ops

		-- reuse addr-v1's own worked example for the point/path arguments
		local one = must_term(ta.build(addr_ops.succ, { must_term(ta.build(addr_ops.zero, {})) }))
		local zero = must_term(ta.build(addr_ops.zero, {}))
		local path = must_term(ta.build(addr_ops.path_child, {
			must_term(ta.build(addr_ops.path_child, { must_term(ta.build(addr_ops.path_root, {})), one })), zero,
		}))
		local bits = must_term(ta.build(addr_ops.bs_cons, {
			must_term(ta.build(addr_ops.b1, {})), must_term(ta.build(addr_ops.bs_nil, {})),
		}))
		local fid = must_term(ta.build(addr_ops.file_id_of, { bits }))
		local point = must_term(ta.build(addr_ops.entry_of, { fid, path }))

		-- ty = ty_union(ty_of(tag_nil), ty_of(tag_false)) -- the proposal's
		-- own "falsy" composite example (§2.2)
		local ty_nil = must_term(ta.build(narrow_ops.ty_of, { must_term(ta.build(narrow_ops.tag_nil, {})) }))
		local ty_false = must_term(ta.build(narrow_ops.ty_of, { must_term(ta.build(narrow_ops.tag_false, {})) }))
		local falsy_ty = must_term(ta.build(narrow_ops.ty_union, { ty_nil, ty_false }))

		-- the point/path terms above were built via addr-v1's OWN operator
		-- context, not narrow-pilot-v1's — usable directly here, no
		-- conversion, because the imported sorts are the same objects.
		local judgment = must_term(ta.build(narrow_ops.holds_at, { point, path, falsy_ty }))
		T.eq(ta.sort_of(judgment), narrow_sig.sorts.judgment)
		T.eq(ta.sort_of(point), addr_sig.sorts.point)
		T.eq(ta.sort_of(path), addr_sig.sorts.path)
	end)

	T.it("an unrelated signature's own same-named point sort is NOT interchangeable with addr-v1's", function()
		local narrow_sig = must_sig(narrow_pilot_v1.declare(addr_sig))
		local narrow_ops = narrow_sig.ops

		-- a third, unrelated signature that happens to declare its own
		-- sort literally named "point" -- NOT imported from addr-v1.
		local rogue_sig, rogue_err = ta.declare_signature({
			name = "rogue-addressing-v1",
			version = 1,
			sorts = { "point" },
			ops = { rogue_origin = { result = "point", args = {} } },
		})
		T.ok(rogue_sig, rogue_err)
		if rogue_sig == nil then return end

		local rogue_point = must_term(ta.build(rogue_sig.ops.rogue_origin, {}))

		-- addr-v1's real point, for comparison
		local addr_point = must_term(ta.build(addr_sig.ops.entry_of, {
			must_term(ta.build(addr_sig.ops.file_id_of, { must_term(ta.build(addr_sig.ops.bs_nil, {})) })),
			must_term(ta.build(addr_sig.ops.path_root, {})),
		}))
		T.ok(addr_point)

		-- the rogue signature's "point" is a different object than
		-- addr-v1's "point" despite sharing a display name: it is
		-- rejected when passed where narrow-pilot-v1's holds_at expects
		-- addr-v1's point (imported), and the two point-sorted vars are
		-- not equal.
		local path = must_term(ta.build(addr_sig.ops.path_root, {}))
		local ty = must_term(ta.build(narrow_ops.ty_of, { must_term(ta.build(narrow_ops.tag_nil, {})) }))
		local bad, err = ta.build(narrow_ops.holds_at, { rogue_point, path, ty })
		T.eq(bad, nil)
		T.ok(err)

		local good = ta.build(narrow_ops.holds_at, { addr_point, path, ty })
		T.ok(good)

		local rogue_var = must_term(ta.var(0, rogue_sig.sorts.point))
		local addr_var = must_term(ta.var(0, addr_sig.sorts.point))
		T.fail(ta.equal(rogue_var, addr_var))
	end)
end)

return {}
