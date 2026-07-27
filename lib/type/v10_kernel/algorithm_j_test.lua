-- lib/type/v10_kernel/algorithm_j_test.lua
-- Demonstrates the v10 registry/kernel's GENERICITY claim using Algorithm J
-- (the imperative, mutable-ref-cell reformulation of the same Damas-Milner
-- algorithm algorithm_w.lua certifies functionally):
--   (a) a valid J-derived certificate replays with zero kernel knowledge of
--       J's semantics — same kernel.lua, zero changes, zero special-casing
--   (b) J exhibits the IDENTICAL documented limitation W does (no let-
--       generalization pins a let-bound type variable at its first call
--       site) on the same term, confirming W and J are genuinely
--       equivalent in what they certify, not just superficially similar
--   (c) a tampered J-emitted certificate fails replay the same way tampered
--       W certificates do (forged citation, well-foundedness cycle, skipped
--       discharge — the same three tamper categories kernel_test.lua uses)
--
-- See theories/algorithm_j.lua's header for the registry-genericity finding
-- this file exists to check: J registers zero new rule schemas, reusing
-- algorithm_w.lua's exported `RULES` table verbatim into its own
-- separately-scoped registry.

local T = require("lib.test.assert")
local registry_mod = require("lib.type.v10_kernel.registry")
local kernel = require("lib.type.v10_kernel.kernel")
local j = require("lib.type.v10_kernel.theories.algorithm_j")

--:: require "lib.type.v10_kernel.registry"

--: () -> Registry
local function j_registry()
	local reg = registry_mod.new(j.THEORY)
	local ok, err = j.register_rules(reg)
	T.ok(ok, "register J rules: " .. tostring(err))
	return reg
end

-- let id = \x -> x in id 42
local VALID_TERM = {
	tag = "let", name = "id", locus = "let@1",
	value = { tag = "abs", param = "x", locus = "abs@1",
		body = { tag = "var", name = "x", locus = "var@1" } },
	body = { tag = "app", locus = "app@1",
		fn = { tag = "var", name = "id", locus = "var@2" },
		arg = { tag = "lit", base = "integer", value = 42, locus = "lit@1" } },
}

T.describe("v10 kernel — valid Algorithm J certificate", function()
	T.it("replays a valid J-derived certificate with zero kernel changes", function()
		local reg = j_registry()
		local cert, err = j.certify(VALID_TERM)
		if not cert then error("j.certify should succeed: " .. tostring(err)) end
		local ok, replay_err = kernel.replay(cert, reg)
		T.ok(ok, "expected replay to succeed: " .. tostring(replay_err))
	end)
end)

T.describe("v10 kernel — tampered Algorithm J certificates fail at replay, not silently", function()
	T.it("rejects a citation forged to a nonexistent rule schema", function()
		local reg = j_registry()
		local cert, cert_err = j.certify(VALID_TERM)
		if not cert then error("j.certify should succeed: " .. tostring(cert_err)) end
		cert.nodes[cert.root].rule = "J-Bogus"
		local ok, err = kernel.replay(cert, reg)
		T.fail(ok, "forged citation must not replay")
		T.ok(err and err:find("unregistered rule schema"), "error should name the bad citation: " .. tostring(err))
	end)

	T.it("rejects a broken well-foundedness cycle", function()
		local reg = j_registry()
		local cert = {
			theory = j.THEORY,
			hypotheses = {},
			nodes = {
				n1 = {
					id = "n1", rule = "W-Abs", judgment = "has_type", locus = "n1",
					conclusion = { term_str = "n1" }, premises = { "n2" }, discharges = { "h1" },
				},
				n2 = {
					id = "n2", rule = "W-Abs", judgment = "has_type", locus = "n2",
					conclusion = { term_str = "n2" }, premises = { "n1" }, discharges = { "h2" },
				},
			},
			root = "n1",
		}
		local ok, err = kernel.replay(cert, reg)
		T.fail(ok, "a premise cycle must not replay")
		T.ok(err and err:find("well%-foundedness"), "error should name the cycle: " .. tostring(err))
	end)

	T.it("rejects a hypothesis that is assumed but never discharged", function()
		local reg = j_registry()
		local cert, err = j.certify(VALID_TERM)
		if not cert then error("j.certify should succeed: " .. tostring(err)) end
		local let_hyp_id
		for hyp_id, hyp in pairs(cert.hypotheses) do
			if hyp.payload.name == "id" then let_hyp_id = hyp_id end
		end
		T.ok(let_hyp_id, "expected an 'id' hypothesis in the certificate")
		local let_node
		for _, node in pairs(cert.nodes) do
			if node.rule == "W-Let" then let_node = node end
		end
		if not let_node then error("expected a W-Let-citing node") end
		let_node.discharges = {}
		local ok, replay_err = kernel.replay(cert, reg)
		T.fail(ok, "an undischarged assumed hypothesis must not replay")
		T.ok(replay_err and replay_err:find("not discharged by an ancestor"), "error should name the missing discharge: " .. tostring(replay_err))
	end)
end)

T.describe("v10 kernel — Algorithm J exhibits W's identical documented limitation", function()
	T.it("pins a let-bound function's type variable at its first call site, same as W", function()
		-- let id = \x -> x in
		--   let a = id 1 in
		--     id true
		--
		-- Identical term to kernel_test.lua's W "known limitation" case. J
		-- does not generalize let-bindings either (see algorithm_j.lua's
		-- header) — id's parameter type variable's CELL gets bound (mutated)
		-- to `integer` at the first call and stays bound there; the second
		-- call against `true` is rejected as a genuine unify mismatch, not a
		-- kernel failure. This is the same rejection W produces on the same
		-- term, confirming J and W certify the same things, not merely
		-- superficially similar ones.
		local term = {
			tag = "let", name = "id", locus = "let@outer",
			value = { tag = "abs", param = "x", locus = "abs@1",
				body = { tag = "var", name = "x", locus = "var@1" } },
			body = {
				tag = "let", name = "a", locus = "let@inner",
				value = { tag = "app", locus = "app@1",
					fn = { tag = "var", name = "id", locus = "var@2" },
					arg = { tag = "lit", base = "integer", value = 1, locus = "lit@1" } },
				body = { tag = "app", locus = "app@2",
					fn = { tag = "var", name = "id", locus = "var@3" },
					arg = { tag = "lit", base = "boolean", value = true, locus = "lit@2" } },
			},
		}
		local cert, err = j.certify(term)
		T.fail(cert, "expected inference to fail on the second, differently-typed call")
		T.ok(err and err:find("cannot unify"), "error should be a genuine unify mismatch: " .. tostring(err))
	end)
end)
