-- lib/type/v10_kernel/pilot/pilot_initial_facts_v1_test.lua
--
-- Smoke tests for the pilot-initial-facts-v1 axiom: declares cleanly over an
-- already-built flow_narrow_v1 vocabulary, and a citation replays (with no
-- discharge, matching the "axiom nodes admit no discharge form" grammar
-- rule) to the exact ground `holds_at` conclusion the bindings name.

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")
local pilot_initial_facts_v1 = require("lib.type.v10_kernel.pilot.pilot_initial_facts_v1")

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("pilot-initial-facts-v1 (" .. tier .. " tier)", function()
		local k = term_algebra.new({ tier = tier })
		local addr_sig = addr_v1.declare()
		local vocab = flow_narrow_v1.declare_vocabulary(k, addr_sig)

		T.it("declares with no errors over the flow_narrow_v1 v2 vocabulary", function()
			local ax, err = pilot_initial_facts_v1.declare(k, vocab)
			T.ok(ax, err)
			T.eq(ax.name, "pilot-initial-facts-v1")
			T.eq(ax.version, 1)
			T.eq(ax.signature, vocab.signature)
		end)

		T.it("a citation replays to the exact ground holds_at the bindings name, with no open hypotheses", function()
			local ax = pilot_initial_facts_v1.declare(k, vocab)
			local addr_ops = addr_sig.ops
			local fid = k.build(addr_ops.file_id_of, {
				k.build(addr_ops.bs_cons, { k.build(addr_ops.b0, {}), k.build(addr_ops.bs_nil, {}) }),
			})
			local var_path = k.build(addr_ops.path_child, { k.build(addr_ops.path_root, {}), k.build(addr_ops.zero, {}) })
			local point = k.build(addr_ops.entry_of, { fid, var_path })
			local ty = vocab.TyUnion(vocab.TyOf(vocab.tag_string()), vocab.TyOf(vocab.tag_nil()))

			local node = replayer.cite_axiom(ax, {
				P = { term = point, depth = 0 },
				X = { term = var_path, depth = 0 },
				T = { term = ty, depth = 0 },
			})
			local r = replayer.new(k)
			local result, err = r:replay(node)
			T.ok(result, err)
			T.ok(k.equal(result.conclusion, vocab.HoldsAt(point, var_path, ty)))
			T.eq(next(result.open), nil)

			local root, rerr = r:replay_root(node)
			T.ok(root, rerr)
			T.eq(root.trust.taint["pilot-initial-facts-v1@v1"], true)
		end)
	end)
end

return {}
