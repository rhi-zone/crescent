-- lib/type/v10_kernel/theories/discharge_scope_test.lua
-- DAG-shared discharge scenarios over the canonical v10 core
-- (lib/type/v10_cleanroom/, per the owner-ratified canon swap; see
-- algorithm_w_test.lua's header for the swap's two structural test
-- differences).
--
-- The historical kernel checked hypothesis discharge by computing, per
-- node, the INTERSECTION (across every incoming `premises` edge) of each
-- parent's own ancestor-discharge set — a single node-level verdict,
-- computed once against the whole DAG. The ratified core (see
-- docs/decisions/typechecker-v10-core-design.md, "Replayer: certificates,
-- taint, discharge") formulates this differently: "a shared subderivation
-- has one fixed open set; each parent subtracts within its own computation
-- only" — there is no analogous single per-shared-node verdict; instead,
-- whether a hypothesis stays open bubbles up through EACH parent's own
-- union/subtract computation independently, and it is ROOT acceptance
-- (open-hypothesis set empty) that ultimately rejects a certificate where
-- some path left it open. This file confirms the four historical scenarios
-- produce the SAME accept/reject verdicts under that mechanism — see the
-- individual test comments for the correspondence in each case.
--
-- Built using hm.lua's `rule_abs` (2 premises: the hypothesis premise, then
-- a body premise; discharges the hypothesis premise) purely for its
-- structural SHAPE -- these are hand-built certificates, not real W/J
-- derivations. Hypothesis identity is the leaf node object (F8): sharing a
-- hypothesis between certificates means citing the same node reference.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local hm = require("lib.type.v10_kernel.theories.hm")

T.describe("discharge scope — DAG-shared discharge", function()
	local reg = rl.new_registry()
	local vocab, verr = hm.declare_vocabulary(reg)
	if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
	local h_int = vocab.H(vocab.int_ty)

	--: () -> Replayer
	local function new_rp()
		local rp, rerr = rl.new_replayer({ registry = reg })
		if not rp then error("rl.new_replayer failed: " .. tostring(rerr)) end
		return rp
	end

	--: () -> CertNode
	local function new_hyp()
		return { kind = "hypothesis", judgment = h_int }
	end

	T.it("rejects a hypothesis assumed in one branch and discharged only in an unrelated sibling branch", function()
		-- hy is a hypothesis leaf cited directly as premise 1 of n1 (nothing
		-- above it discharges it); n3 is a SEPARATE hm-abs citation over an
		-- UNRELATED hypothesis, discharging THAT one, not hy. n1's own
		-- discharge slot is left vacuous, so hy stays open at the root —
		-- the direct analogue of "a sibling's discharge does not satisfy
		-- this assumption."
		local hy = new_hyp()
		local h_other = new_hyp()
		local n3 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { h_other, h_other },
			discharge = { [1] = { h_other } },
		} --[[: CertNode ]]
		local n1 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hy, n3 },
			discharge = { [1] = {} },
		} --[[: CertNode ]]
		local root, err = rl.replay(new_rp(), n1)
		T.fail(root, "hy must remain undischarged -- a sibling's own discharge does not satisfy it")
		T.ok(err and err:find("undischarged"), "error should name the missing discharge: " .. tostring(err))
	end)

	T.it("accepts a hypothesis assumed at a shared node when both parents discharge it (every path)", function()
		-- A single shared hypothesis leaf `hy`, cited as premise 1 of TWO
		-- separate hm-abs citations (n2, n3), each discharging hy from its
		-- own computation; both succeed at their own root.
		local hy = new_hyp()
		local n2 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hy, hy },
			discharge = { [1] = { hy } },
		} --[[: CertNode ]]
		local n3 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hy, hy },
			discharge = { [1] = { hy } },
		} --[[: CertNode ]]
		local rp = new_rp()
		local root2, err2 = rl.replay(rp, n2)
		T.ok(root2, err2)
		local root3, err3 = rl.replay(rp, n3)
		T.ok(root3, err3)
	end)

	T.it("rejects a hypothesis assumed at a shared node when only one of two incoming paths discharges it", function()
		-- The shared hypothesis leaf `hy` is cited as premise 1 into BOTH
		-- n2 (discharges hy) and n3 (does NOT discharge hy, vacuous slot).
		-- n2's own root succeeds (fully discharged); n3's own root fails
		-- (hy stays open) -- confirming, via the ratified mechanism ("each
		-- parent subtracts within its own computation only"), that whether
		-- hy's assumption holds is per-path: a consumer of n3's own
		-- derivation genuinely has an undischarged obligation, regardless
		-- of what some OTHER parent (n2) did with the same shared
		-- subderivation. Nothing is ever globally marked discharged.
		local hy = new_hyp()
		local n2 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hy, hy },
			discharge = { [1] = { hy } },
		} --[[: CertNode ]]
		local n3 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hy, hy },
			discharge = { [1] = {} },
		} --[[: CertNode ]]
		local rp = new_rp()
		local root2, err2 = rl.replay(rp, n2)
		T.ok(root2, err2)
		local root3, err3 = rl.replay(rp, n3)
		T.fail(root3, "n3 does not discharge hy -- its own root must reject")
		T.ok(err3 and err3:find("undischarged"), "error should name the missing discharge: " .. tostring(err3))
	end)

	T.it("accepts a hypothesis assumed directly beneath its properly-nested discharging ancestor", function()
		-- Baseline positive case: hy assumed at a leaf directly under its
		-- own discharging parent, tree-shaped -- both W's and J's own
		-- certificates rely on exactly this shape (see algorithm_w.lua's
		-- hm-abs citation).
		local hy = new_hyp()
		local n1 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hy, hy },
			discharge = { [1] = { hy } },
		} --[[: CertNode ]]
		local root, err = rl.replay(new_rp(), n1)
		T.ok(root, err)
	end)
end)

return {}
