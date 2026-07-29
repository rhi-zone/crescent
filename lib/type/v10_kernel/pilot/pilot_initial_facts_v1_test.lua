-- lib/type/v10_kernel/pilot/pilot_initial_facts_v1_test.lua
--
-- Smoke tests for the pilot-initial-facts-v1 axiom over the canonical v10
-- core: declares cleanly into the vocabulary's registry, and a citation
-- replays root-strict (with no discharge, matching the "axiom nodes admit
-- no discharge form" grammar rule) to the exact ground `holds_at`
-- conclusion the bindings name — axiom citations leave no open
-- hypotheses, so root-strict acceptance succeeds directly.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")

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

--: (v: NarrowVocab | nil, err: string | nil) -> NarrowVocab
local function must_vocab(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

T.describe("pilot-initial-facts-v1", function()
	local addr_sig = must_sig(addr_v1.declare())
	local reg = rl.new_registry()
	local vocab = must_vocab(flow_narrow_v1.declare_vocabulary(reg, addr_sig))
	local ax, ax_err = pilot_initial_facts_v1.declare(reg, vocab)

	T.it("declares with no errors over the flow_narrow_v1 v2 vocabulary", function()
		T.ok(ax, ax_err)
		if ax == nil then return end
		T.eq(ax.name, "pilot-initial-facts-v1")
		T.eq(ax.version, 1)
	end)

	T.it("a citation replays root-strict to the exact ground holds_at the bindings name", function()
		T.ok(ax)
		if ax == nil then return end
		local addr_ops = addr_sig.ops
		local fid = must_term(ta.build(addr_ops.file_id_of, {
			must_term(ta.build(addr_ops.bs_cons, {
				must_term(ta.build(addr_ops.b0, {})), must_term(ta.build(addr_ops.bs_nil, {})),
			})),
		}))
		local var_path = must_term(ta.build(addr_ops.path_child, {
			must_term(ta.build(addr_ops.path_root, {})), must_term(ta.build(addr_ops.zero, {})),
		}))
		local point = must_term(ta.build(addr_ops.entry_of, { fid, var_path }))
		local ty = must_term(vocab.TyUnion(
			must_term(vocab.TyOf(must_term(vocab.tag_string()))),
			must_term(vocab.TyOf(must_term(vocab.tag_nil())))
		))

		local node = {
			kind = "axiom", axiom = ax,
			bindings = { P = point, X = var_path, T = ty },
		} --[[: CertNode ]]
		local rp, rperr = rl.new_replayer({ registry = reg })
		T.ok(rp, rperr)
		if rp == nil then return end
		-- observation shows the computed triple: no open hypotheses at all
		local obs, oerr = rl.observe(rp, node)
		T.ok(obs, oerr)
		if obs == nil then return end
		T.ok(ta.equal(obs.conclusion, must_term(vocab.HoldsAt(point, var_path, ty))))
		T.eq(#obs.open, 0)

		-- root-strict acceptance succeeds directly (nothing open), and the
		-- result carries the axiom's citation key in its taint
		local root, rerr = rl.replay(rp, node)
		T.ok(root, rerr)
		if root == nil then return end
		T.eq(root.taint[rl.citation_key("pilot-initial-facts-v1", 1)], ax)
	end)
end)

return {}
