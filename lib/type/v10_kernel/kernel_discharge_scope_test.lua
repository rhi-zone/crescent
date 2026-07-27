-- lib/type/v10_kernel/kernel_discharge_scope_test.lua
-- Demonstrates the ancestor-scoped hypothesis discharge check in kernel.lua's
-- check_discharge (see that file's header for the full semantics). These
-- certificates are hand-built directly (not produced by w.lua/algorithm_j.lua
-- — both producers only ever emit trees), the same way kernel_test.lua's own
-- well-foundedness-cycle case hand-builds a cert to exercise a shape no real
-- producer emits, citing W's rule schemas purely for their structural shape
-- (arity, assumes/discharges permissions), not their semantics.
--
--   (a) a hypothesis assumed in one branch of a TREE and "discharged" only
--       in an unrelated sibling branch is rejected — this is the exact bug
--       the flat, reachable-set-wide id match used to miss (a discharge
--       anywhere in the certificate satisfied any assumption anywhere).
--   (b) a hypothesis assumed at a node SHARED by two parents (a DAG, not a
--       tree) is accepted when EVERY path from the root to that node passes
--       through a discharging ancestor.
--   (c) the same shared-node shape is rejected when only one of the two
--       paths reaching it discharges the hypothesis — the sharper,
--       DAG-generalized version of (a): "somewhere" is still not enough,
--       even when "somewhere" is a real ancestor on one path.
--   (d) a hypothesis assumed at a node directly beneath its true ancestor's
--       discharge (properly nested, tree-shaped) is accepted — the baseline
--       positive case both W's and J's existing certificates already rely
--       on, restated here explicitly against a hand-built cert.

local T = require("lib.test.assert")
local registry_mod = require("lib.type.v10_kernel.registry")
local kernel = require("lib.type.v10_kernel.kernel")
local w = require("lib.type.v10_kernel.theories.algorithm_w")

--:: require "lib.type.v10_kernel.registry"

--: () -> Registry
local function w_registry()
	local reg = registry_mod.new(w.THEORY)
	local ok, err = w.register_rules(reg)
	T.ok(ok, "register W rules: " .. tostring(err))
	return reg
end

--: (string) -> unknown
local function leaf(id)
	return {
		id = id, rule = "W-Lit", judgment = "has_type", locus = id,
		conclusion = { term_str = id }, premises = {},
	}
end

T.describe("v10 kernel — discharge is scoped to derivation ancestry, not flat reachability", function()
	T.it("rejects a hypothesis assumed in one tree branch and discharged only in an unrelated sibling branch", function()
		local reg = w_registry()
		local cert = {
			theory = w.THEORY,
			hypotheses = { h1 = { id = "h1", judgment = "has_type", payload = {} } },
			nodes = {
				n1 = {
					id = "n1", rule = "W-App", judgment = "has_type", locus = "n1",
					conclusion = { term_str = "n1" }, premises = { "n2", "n3" },
				},
				-- n2 assumes h1 but has no ancestor that discharges it.
				n2 = {
					id = "n2", rule = "W-Var", judgment = "has_type", locus = "n2",
					conclusion = { term_str = "n2" }, premises = {}, assumes = { "h1" },
				},
				-- n3 discharges h1, but n3 is n2's SIBLING, not its ancestor.
				n3 = {
					id = "n3", rule = "W-Abs", judgment = "has_type", locus = "n3",
					conclusion = { term_str = "n3" }, premises = { "n4" }, discharges = { "h1" },
				},
				n4 = leaf("n4"),
			},
			root = "n1",
		}
		local ok, err = kernel.replay(cert, reg)
		T.fail(ok, "a sibling-branch discharge must not satisfy an unrelated branch's assumption")
		T.ok(err and err:find("not discharged by an ancestor"), "error should name the scoping violation: " .. tostring(err))
	end)

	T.it("accepts a hypothesis assumed at a shared (DAG) node when every incoming path discharges it", function()
		local reg = w_registry()
		local cert = {
			theory = w.THEORY,
			hypotheses = { h1 = { id = "h1", judgment = "has_type", payload = {} } },
			nodes = {
				n1 = {
					id = "n1", rule = "W-App", judgment = "has_type", locus = "n1",
					conclusion = { term_str = "n1" }, premises = { "n2", "n3" },
				},
				-- both n2 and n3 are parents of the shared node n5, and both
				-- discharge h1 — every path from root to n5 passes through a
				-- discharging ancestor.
				n2 = {
					id = "n2", rule = "W-Abs", judgment = "has_type", locus = "n2",
					conclusion = { term_str = "n2" }, premises = { "n5" }, discharges = { "h1" },
				},
				n3 = {
					id = "n3", rule = "W-Abs", judgment = "has_type", locus = "n3",
					conclusion = { term_str = "n3" }, premises = { "n5" }, discharges = { "h1" },
				},
				n5 = {
					id = "n5", rule = "W-Var", judgment = "has_type", locus = "n5",
					conclusion = { term_str = "n5" }, premises = {}, assumes = { "h1" },
				},
			},
			root = "n1",
		}
		local ok, err = kernel.replay(cert, reg)
		T.ok(ok, "expected the shared-node cert to replay: " .. tostring(err))
	end)

	T.it("rejects a hypothesis assumed at a shared (DAG) node when only one of two incoming paths discharges it", function()
		local reg = w_registry()
		local cert = {
			theory = w.THEORY,
			hypotheses = { h1 = { id = "h1", judgment = "has_type", payload = {} } },
			nodes = {
				n1 = {
					id = "n1", rule = "W-App", judgment = "has_type", locus = "n1",
					conclusion = { term_str = "n1" }, premises = { "n2", "n3" },
				},
				-- n2 discharges h1 on its way to the shared node n5...
				n2 = {
					id = "n2", rule = "W-Abs", judgment = "has_type", locus = "n2",
					conclusion = { term_str = "n2" }, premises = { "n5" }, discharges = { "h1" },
				},
				-- ...but n3 reaches the SAME shared node n5 without discharging
				-- anything. n5's assumption of h1 must hold on every path, so
				-- this path breaks it.
				n3 = {
					id = "n3", rule = "W-App", judgment = "has_type", locus = "n3",
					conclusion = { term_str = "n3" }, premises = { "n5", "n6" },
				},
				n5 = {
					id = "n5", rule = "W-Var", judgment = "has_type", locus = "n5",
					conclusion = { term_str = "n5" }, premises = {}, assumes = { "h1" },
				},
				n6 = leaf("n6"),
			},
			root = "n1",
		}
		local ok, err = kernel.replay(cert, reg)
		T.fail(ok, "a shared node reachable via one non-discharging path must not replay")
		T.ok(err and err:find("not discharged by an ancestor"), "error should name the scoping violation: " .. tostring(err))
	end)

	T.it("accepts a hypothesis assumed directly beneath its properly-nested discharging ancestor", function()
		local reg = w_registry()
		local cert = {
			theory = w.THEORY,
			hypotheses = { h1 = { id = "h1", judgment = "has_type", payload = {} } },
			nodes = {
				n1 = {
					id = "n1", rule = "W-Abs", judgment = "has_type", locus = "n1",
					conclusion = { term_str = "n1" }, premises = { "n2" }, discharges = { "h1" },
				},
				n2 = {
					id = "n2", rule = "W-Var", judgment = "has_type", locus = "n2",
					conclusion = { term_str = "n2" }, premises = {}, assumes = { "h1" },
				},
			},
			root = "n1",
		}
		local ok, err = kernel.replay(cert, reg)
		T.ok(ok, "expected the properly-nested cert to replay: " .. tostring(err))
	end)
end)
