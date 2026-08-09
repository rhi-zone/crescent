-- lib/type/v10_kernel/pilot/effects_spine_v1_test.lua
--
-- Smoke tests for the effects spine signature (pilot/effects_spine_v1.lua):
-- declares cleanly, imports addr-v1's point/path sorts by OBJECT identity
-- (not name), and builds a `preserves(from,to,x)` term whose sort is this
-- signature's own `judgment` object.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local effects_spine_v1 = require("lib.type.v10_kernel.pilot.effects_spine_v1")

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

--: (v: EffectsSpine | nil, err: string | nil) -> EffectsSpine
local function must_spine(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

T.describe("effects-spine-v1", function()
	T.it("declares with no errors, given an already-declared addr-v1", function()
		local addr_sig_raw, addr_sig_err = addr_v1.declare()
		local addr_sig = must_sig(addr_sig_raw, addr_sig_err)
		local spine, err = effects_spine_v1.declare(addr_sig)
		T.ok(spine, err)
		if spine == nil then return end
		T.eq(spine.signature.name, "effects-spine-v1")
		T.eq(spine.signature.version, 1)
		-- sort identity is declared-object identity: the imported point/path
		-- ARE addr-v1's own sort objects, not same-named lookalikes.
		T.eq(spine.signature.sorts.point, addr_sig.sorts.point)
		T.eq(spine.signature.sorts.path, addr_sig.sorts.path)
	end)

	T.it("rejects when addr_sig is missing point/path sorts", function()
		local bad_sig, err = effects_spine_v1.declare({ sorts = {} })
		T.eq(bad_sig, nil)
		T.ok(err)
	end)

	T.it("builds a preserves(from,to,x) term of this signature's own judgment sort", function()
		local addr_sig_raw, addr_sig_err = addr_v1.declare()
		local addr_sig = must_sig(addr_sig_raw, addr_sig_err)
		local addr_ops = addr_sig.ops
		local spine_raw, spine_err = effects_spine_v1.declare(addr_sig)
		local spine = must_spine(spine_raw, spine_err)

		local root = must_term(ta.build(addr_ops.path_root, {}))
		local zero = must_term(ta.build(addr_ops.zero, {}))
		local path_x = must_term(ta.build(addr_ops.path_child, { root, zero }))
		local bits = must_term(ta.build(addr_ops.bs_nil, {}))
		local fid = must_term(ta.build(addr_ops.file_id_of, { bits }))
		local p_from = must_term(ta.build(addr_ops.entry_of, { fid, path_x }))
		local p_to = must_term(ta.build(addr_ops.exit_of, { fid, path_x }))

		local pres = must_term(spine.Preserves(p_from, p_to, path_x))
		T.eq(ta.sort_of(pres), spine.signature.sorts.judgment)
	end)

	T.it("two independent declare() calls yield DISTINCT signature objects (no ambient sharing)", function()
		local addr_sig_raw, addr_sig_err = addr_v1.declare()
		local addr_sig = must_sig(addr_sig_raw, addr_sig_err)
		local spine1_raw, spine1_err = effects_spine_v1.declare(addr_sig)
		local spine1 = must_spine(spine1_raw, spine1_err)
		local spine2_raw, spine2_err = effects_spine_v1.declare(addr_sig)
		local spine2 = must_spine(spine2_raw, spine2_err)
		T.fail(spine1.signature == spine2.signature)
		T.fail(spine1.signature.ops.preserves == spine2.signature.ops.preserves)
	end)
end)

return {}
