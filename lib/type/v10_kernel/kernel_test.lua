-- lib/type/v10_kernel/kernel_test.lua
-- Demonstrates the v10 trust-core shape end to end:
--   (a) a valid W-derived certificate replays with zero kernel knowledge of W
--   (b) three independent tamperings each fail replay, not silently
--   (c) W's own documented limitation (no let-generalization) rejects a
--       program a real let-polymorphic checker would accept — shown, not fixed

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

-- let id = \x -> x in id 42
-- De Bruijn indices: inside the abs body, `x` is the nearest enclosing
-- binder -> index 0. Inside the let body, `id` is the nearest enclosing
-- binder -> index 0. (`name` fields below are purely cosmetic display
-- hints, never used for lookup.)
local VALID_TERM = {
	tag = "let", name = "id", locus = "let@1",
	value = { tag = "abs", param = "x", locus = "abs@1",
		body = { tag = "var", index = 0, name = "x", locus = "var@1" } },
	body = { tag = "app", locus = "app@1",
		fn = { tag = "var", index = 0, name = "id", locus = "var@2" },
		arg = { tag = "lit", base = "integer", value = 42, locus = "lit@1" } },
}

T.describe("v10 kernel — valid certificate", function()
	T.it("replays a valid W-derived certificate with zero W-semantics knowledge", function()
		local reg = w_registry()
		local cert, err = w.certify(VALID_TERM)
		if not cert then error("w.certify should succeed: " .. tostring(err)) end
		local ok, replay_err = kernel.replay(cert, reg)
		T.ok(ok, "expected replay to succeed: " .. tostring(replay_err))
	end)
end)

T.describe("v10 kernel — tampered certificates fail at replay, not silently", function()
	T.it("rejects a citation forged to a nonexistent rule schema", function()
		local reg = w_registry()
		local cert, cert_err = w.certify(VALID_TERM)
		if not cert then error("w.certify should succeed: " .. tostring(cert_err)) end
		-- forge the root node's citation
		cert.nodes[cert.root].rule = "W-Bogus"
		local ok, err = kernel.replay(cert, reg)
		T.fail(ok, "forged citation must not replay")
		T.ok(err and err:find("unregistered rule schema"), "error should name the bad citation: " .. tostring(err))
	end)

	T.it("rejects a broken well-foundedness cycle", function()
		local reg = w_registry()
		local cert = {
			theory = w.THEORY,
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
		local reg = w_registry()
		local cert, err = w.certify(VALID_TERM)
		if not cert then error("w.certify should succeed: " .. tostring(err)) end
		-- Find the "id" hypothesis (the let-bound name) and strip its discharge
		-- from the W-Let node that introduced it, while leaving the W-Var node
		-- that assumes it (the `app`'s `fn`) untouched. The var node still
		-- structurally depends on the hypothesis; nothing discharges it now.
		local let_hyp_id
		for hyp_id, hyp in pairs(cert.hypotheses) do
			if hyp.payload.name == "id" then let_hyp_id = hyp_id end
		end
		T.ok(let_hyp_id, "expected an 'id' hypothesis in the certificate")
		local let_node
		for _, node in pairs(cert.nodes) do
			if node.rule == "W-Let" then let_node = node end
		end
		if not let_node then error("expected a W-Let node") end
		let_node.discharges = {}
		local ok, replay_err = kernel.replay(cert, reg)
		T.fail(ok, "an undischarged assumed hypothesis must not replay")
		T.ok(replay_err and replay_err:find("not discharged by an ancestor"), "error should name the missing discharge: " .. tostring(replay_err))
	end)
end)

T.describe("v10 kernel — W's documented limitation (shown, not fixed)", function()
	T.it("pins a let-bound function's type variable at its first call site", function()
		-- let id = \x -> x in
		--   let a = id 1 in
		--     id true
		--
		-- A real let-polymorphic checker accepts this (id : forall a. a -> a,
		-- instantiated fresh at each call). This W does not generalize
		-- let-bindings (see w.lua's header), so `id`'s parameter type variable
		-- is unified with `integer` at the first call and stays pinned; the
		-- second call against `true` is rejected as a genuine type error, not
		-- a kernel failure. This is the intended, documented weakness — the
		-- fix (let-generalization) is explicitly out of scope for this
		-- founding entry.
		-- De Bruijn indices: `x` in the abs body -> index 0 (its own
		-- binder). Inside the outer let's body, env is [id] (depth 0 =
		-- id): the inner let's `value` is still evaluated there, so its
		-- `id` reference -> index 0. The inner let's `body` env is
		-- [a, id] (depth 0 = a, depth 1 = id, since `a` shadows depth 0)
		-- -- its `id` reference is now one level further out -> index 1.
		local term = {
			tag = "let", name = "id", locus = "let@outer",
			value = { tag = "abs", param = "x", locus = "abs@1",
				body = { tag = "var", index = 0, name = "x", locus = "var@1" } },
			body = {
				tag = "let", name = "a", locus = "let@inner",
				value = { tag = "app", locus = "app@1",
					fn = { tag = "var", index = 0, name = "id", locus = "var@2" },
					arg = { tag = "lit", base = "integer", value = 1, locus = "lit@1" } },
				body = { tag = "app", locus = "app@2",
					fn = { tag = "var", index = 1, name = "id", locus = "var@3" },
					arg = { tag = "lit", base = "boolean", value = true, locus = "lit@2" } },
			},
		}
		local cert, err = w.certify(term)
		T.fail(cert, "expected inference to fail on the second, differently-typed call")
		T.ok(err and err:find("cannot unify"), "error should be a genuine unify mismatch: " .. tostring(err))
	end)
end)
