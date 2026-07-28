-- lib/type/v10_kernel/pilot/narrow_pilot_v1_test.lua
--
-- narrow-pilot-v1's own smoke tests, plus the cross-signature identity
-- checks this pilot exists to demonstrate (docs/typechecker-v10-pilot-
-- signatures-proposal.md §4, resolved by phase 1's `imports` mechanism):
--   1. both signatures declare with no errors
--   2. a representative holds_at judgment term builds over a real
--      point/path (from addr-v1) and a ty (from narrow-pilot-v1's own ops)
--   3. the imported point/path sorts ARE addr-v1's own sort objects, not
--      merely same-named copies — a term built via addr-v1's own operators
--      is usable directly as a holds_at argument with no conversion
--   4. an unrelated THIRD signature that declares its own same-named
--      `point` sort (not imported from addr-v1) is rejected when used
--      where addr-v1's point is expected — confirming phase 1's identity
--      protection actually holds at this pilot's real use site.

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local narrow_pilot_v1 = require("lib.type.v10_kernel.pilot.narrow_pilot_v1")

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("narrow-pilot-v1 (" .. tier .. " tier)", function()
		local k = term_algebra.new({ tier = tier })
		local addr_sig = addr_v1.declare()

		T.it("declares with no errors, given an already-declared addr-v1", function()
			local sig, err = narrow_pilot_v1.declare(addr_sig)
			T.ok(sig, err)
			T.eq(sig.name, "narrow-pilot-v1")
			T.eq(sig.version, 1)
			-- the imported sorts are the SAME objects addr-v1 owns, not copies
			T.eq(sig.sorts.point, addr_sig.sorts.point)
			T.eq(sig.sorts.path, addr_sig.sorts.path)
		end)

		T.it("builds a holds_at judgment over a real point/path and a ty from prim tags", function()
			local narrow_sig = narrow_pilot_v1.declare(addr_sig)
			local addr_ops = addr_sig.ops
			local narrow_ops = narrow_sig.ops

			-- reuse addr-v1's own worked example for the point/path arguments
			local one = k.build(addr_ops.succ, { k.build(addr_ops.zero, {}) })
			local zero = k.build(addr_ops.zero, {})
			local path = k.build(addr_ops.path_child, { k.build(addr_ops.path_child, { k.build(addr_ops.path_root, {}), one }), zero })
			local bits = k.build(addr_ops.bs_cons, { k.build(addr_ops.b1, {}), k.build(addr_ops.bs_nil, {}) })
			local fid = k.build(addr_ops.file_id_of, { bits })
			local point = k.build(addr_ops.entry_of, { fid, path })
			T.ok(point)
			T.ok(path)

			-- ty = ty_union(ty_of(tag_nil), ty_of(tag_false)) -- the proposal's
			-- own "falsy" composite example (§2.2)
			local ty_nil = k.build(narrow_ops.ty_of, { k.build(narrow_ops.tag_nil, {}) })
			local ty_false = k.build(narrow_ops.ty_of, { k.build(narrow_ops.tag_false, {}) })
			T.ok(ty_nil)
			T.ok(ty_false)
			local falsy_ty = k.build(narrow_ops.ty_union, { ty_nil, ty_false })
			T.ok(falsy_ty)

			-- the point/path terms above were built via addr-v1's OWN operator
			-- context, not narrow-pilot-v1's — usable directly here, no
			-- conversion, because the imported sorts are the same objects.
			local judgment = k.build(narrow_ops.holds_at, { point, path, falsy_ty })
			T.ok(judgment)
			T.eq(k.sort_of(judgment), narrow_sig.sorts.judgment)
			T.eq(k.sort_of(point), addr_sig.sorts.point)
			T.eq(k.sort_of(path), addr_sig.sorts.path)
		end)

		T.it("an unrelated signature's own same-named point sort is NOT interchangeable with addr-v1's", function()
			local narrow_sig = narrow_pilot_v1.declare(addr_sig)
			local narrow_ops = narrow_sig.ops

			-- a third, unrelated signature that happens to declare its own
			-- sort literally named "point" -- NOT imported from addr-v1.
			local rogue_sig, rogue_err = term_algebra.declare_signature({
				name = "rogue-addressing-v1",
				version = 1,
				sorts = { "point" },
				ops = { rogue_origin = { result = "point", args = {} } },
			})
			T.ok(rogue_sig, rogue_err)

			local rogue_point = k.build(rogue_sig.ops.rogue_origin, {})
			T.ok(rogue_point)

			-- addr-v1's real point, for comparison
			local addr_point = k.build(addr_sig.ops.entry_of, {
				k.build(addr_sig.ops.file_id_of, { k.build(addr_sig.ops.bs_nil, {}) }),
				k.build(addr_sig.ops.path_root, {}),
			})
			T.ok(addr_point)

			-- the rogue signature's "point" is a different object than
			-- addr-v1's "point" despite sharing a display name: it is
			-- rejected when passed where narrow-pilot-v1's holds_at expects
			-- addr-v1's point (imported), and the two point-sorted vars are
			-- not equal.
			local path = k.build(addr_sig.ops.path_root, {})
			local ty = k.build(narrow_ops.ty_of, { k.build(narrow_ops.tag_nil, {}) })
			local bad, err = k.build(narrow_ops.holds_at, { rogue_point, path, ty })
			T.eq(bad, nil)
			T.ok(err)

			local good = k.build(narrow_ops.holds_at, { addr_point, path, ty })
			T.ok(good)

			T.fail(k.equal(k.build_var(0, rogue_sig.sorts.point), k.build_var(0, addr_sig.sorts.point)))
		end)
	end)
end

return {}
