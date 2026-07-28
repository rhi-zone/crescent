-- lib/type/v10_kernel/theories/discharge_scope_test.lua
-- Ported from the retired lib/type/v10_kernel/kernel_discharge_scope_test.lua
-- (see algorithm_w_test.lua's header for the retirement/port context).
--
-- The retired kernel checked hypothesis discharge by computing, per node,
-- the INTERSECTION (across every incoming `premises` edge) of each parent's
-- own ancestor-discharge set — a single node-level verdict, computed once
-- against the whole DAG. The ratified core (see
-- docs/decisions/typechecker-v10-core-design.md, "Replayer: certificates,
-- taint, discharge") formulates this differently: "a shared subderivation
-- has one fixed open set; each parent subtracts within its own computation
-- only" — there is no analogous single per-shared-node verdict; instead,
-- whether a hypothesis stays open bubbles up through EACH parent's own
-- union/subtract computation independently, and it is ROOT acceptance
-- (open-hypothesis set empty) that ultimately rejects a certificate where
-- some path left it open. This file confirms the four retired scenarios
-- produce the SAME accept/reject verdicts under that different mechanism —
-- see the individual test comments for the correspondence in each case.
--
-- Built using hm.lua's `rule_abs` (2 premises: the hypothesis premise, then
-- a body premise; discharges the hypothesis premise) purely for its
-- structural SHAPE (matching the retired file's own "cite W's rule schemas
-- purely for their structural shape" framing) -- these are hand-built
-- certificates, not real W/J-produced derivations.

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")
local hm = require("lib.type.v10_kernel.theories.hm")

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("discharge scope (" .. tier .. " tier) — DAG-shared discharge", function()
		local k = term_algebra.new({ tier = tier })
		local vocab, verr = hm.declare_vocabulary(k)
		if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
		local h_int = vocab.H(vocab.int_ty)

		T.it("rejects a hypothesis assumed in one branch and discharged only in an unrelated sibling branch", function()
			-- Retired shape: n1(App){n2,n3}; n2 assumes h1 with no
			-- discharging ancestor; n3 discharges h1 but is n2's SIBLING,
			-- not ancestor. Ported: hy is a hypothesis leaf cited directly
			-- as n2 (nothing above it discharges it); n3 is a SEPARATE
			-- hm-abs citation over an UNRELATED hypothesis, discharging
			-- THAT one, not hy. n1 = hm-app(n2=hy-as-fn-premise is ill-typed
			-- for hm-app's arrow-shape, so instead use hm-abs as the
			-- "parent that unions two premises" vehicle: n1 = hm-abs over
			-- {hy, n3} -- hy (premise 1) is what n1's OWN discharge slot
			-- targets; deliberately name a DIFFERENT id at that slot
			-- (n3's own unrelated hypothesis id) so hy itself is left
			-- open at the root -- this is the direct ported analogue of
			-- "a sibling's discharge does not satisfy this assumption."
			local hy = replayer.hypothesis("hy", h_int)
			local h_other = replayer.hypothesis("h_other", h_int)
			local n3, n3err = replayer.cite_rule(vocab.rule_abs, { h_other, h_other }, { { "h_other" } })
			T.ok(n3, n3err)
			-- n1 cites hy as premise 1 (the slot hy could be discharged
			-- at) and n3 as premise 2, but discharges n3's id instead of
			-- hy's -- hy stays open despite n3's own (unrelated) discharge.
			local n1, n1err = replayer.cite_rule(vocab.rule_abs, { hy, n3 }, { {} })
			T.ok(n1, n1err)
			local root, err = replayer.new(k):replay_root(n1)
			T.fail(root, "hy must remain undischarged -- a sibling's own discharge does not satisfy it")
			T.ok(err and err:find("undischarged"), "error should name the missing discharge: " .. tostring(err))
		end)

		T.it("accepts a hypothesis assumed at a shared node when both parents discharge it (every path)", function()
			-- Retired shape: n1(App){n2,n3}; both n2 and n3 are Abs parents
			-- of the SAME shared node n5 (assumes h1), both discharging
			-- h1 -- accepted. Ported directly: a single shared hypothesis
			-- leaf `hy`, cited as the premise-1 of TWO separate hm-abs
			-- citations (n2, n3), each discharging hy from its own
			-- computation; n1 = hm-abs over {hy_reused_via_n2's body...}
			-- -- simplest direct port: replay EACH parent independently
			-- (mirrors the MANDATORY replayer_test.lua acceptance shape)
			-- and confirm both succeed at their own root.
			local hy = replayer.hypothesis("hy", h_int)
			local n2, n2err = replayer.cite_rule(vocab.rule_abs, { hy, hy }, { { "hy" } })
			T.ok(n2, n2err)
			local n3, n3err = replayer.cite_rule(vocab.rule_abs, { hy, hy }, { { "hy" } })
			T.ok(n3, n3err)
			local r = replayer.new(k)
			local root2, err2 = r:replay_root(n2)
			T.ok(root2, err2)
			local root3, err3 = r:replay_root(n3)
			T.ok(root3, err3)
		end)

		T.it("rejects a hypothesis assumed at a shared node when only one of two incoming paths discharges it", function()
			-- Retired shape: n2 discharges h1 on its way to shared n5; n3
			-- reaches the SAME n5 WITHOUT discharging -- rejected because
			-- n5's assumption must hold on every path. Ported: the shared
			-- hypothesis leaf `hy` is cited as premise 1 into BOTH n2
			-- (discharges hy) and n3 (does NOT discharge hy, vacuous slot).
			-- n2's own root succeeds (fully discharged); n3's own root
			-- fails (hy stays open) -- confirming, via the mechanism
			-- actually ratified ("each parent subtracts within its own
			-- computation only"), that whether hy's assumption holds is
			-- NOT a single node-level fact independent of which parent is
			-- asked -- it is exactly per-path, which is the stronger
			-- (not weaker) form of "every path must discharge": a
			-- consumer of n3's own derivation genuinely has an
			-- undischarged obligation, regardless of what some OTHER
			-- parent (n2) did with the same shared subderivation.
			local hy = replayer.hypothesis("hy", h_int)
			local n2, n2err = replayer.cite_rule(vocab.rule_abs, { hy, hy }, { { "hy" } })
			T.ok(n2, n2err)
			local n3, n3err = replayer.cite_rule(vocab.rule_abs, { hy, hy }, { {} })
			T.ok(n3, n3err)
			local r = replayer.new(k)
			local root2, err2 = r:replay_root(n2)
			T.ok(root2, err2)
			local root3, err3 = r:replay_root(n3)
			T.fail(root3, "n3 does not discharge hy -- its own root must reject")
			T.ok(err3 and err3:find("undischarged"), "error should name the missing discharge: " .. tostring(err3))
		end)

		T.it("accepts a hypothesis assumed directly beneath its properly-nested discharging ancestor", function()
			-- Baseline positive case: hy assumed at a leaf directly under
			-- its own discharging parent, tree-shaped -- both W's and J's
			-- own certificates rely on exactly this shape (see
			-- algorithm_w.lua's hm-abs citation).
			local hy = replayer.hypothesis("hy", h_int)
			local n1, n1err = replayer.cite_rule(vocab.rule_abs, { hy, hy }, { { "hy" } })
			T.ok(n1, n1err)
			local root, err = replayer.new(k):replay_root(n1)
			T.ok(root, err)
		end)
	end)
end

return {}
