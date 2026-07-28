-- lib/type/v10_kernel/theories/algorithm_w_test.lua
-- Ported from the retired lib/type/v10_kernel/kernel_test.lua (see
-- docs/decisions/typechecker-v10-core-design.md,
-- docs/decisions/typechecker-v10-core-charter.md — the conformance task
-- that retired kernel.lua/registry.lua). Demonstrates the same v10
-- trust-core shape as the retired prototype, over the ratified core:
--   (a) a valid W-derived certificate replays with zero replayer knowledge
--       of W's semantics, across both term_algebra tiers
--   (b) tampered certificates fail replay, not silently: a well-foundedness
--       cycle, and a hypothesis discharge stripped after construction
--   (c) W's own documented limitation (no let-generalization) rejects a
--       program a real let-polymorphic checker would accept — shown, not
--       fixed
--
-- One tamper category from the retired suite has NO analog here and is not
-- reproduced: "citation forged to a nonexistent rule schema by name." The
-- retired kernel resolved citations by STRING NAME against a registry
-- (`registry.lookup`), so a certificate could name a rule that was never
-- registered. The new core's `cite_rule`/`cite_axiom` take the declared
-- rule/axiom OBJECT directly — there is no name-keyed lookup step to forge
-- a miss against; passing something that isn't a real declared object is
-- instead caught by `cite_rule`'s own shape validation at CONSTRUCTION time
-- (see "malformed citation" below), which is a strictly earlier/stronger
-- rejection than the retired kernel's replay-time-only check, not a
-- narrower one.

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")
local hm = require("lib.type.v10_kernel.theories.hm")
local w = require("lib.type.v10_kernel.theories.algorithm_w")

-- let id = \x -> x in id 42
-- De Bruijn indices: inside the abs body, `x` is the nearest enclosing
-- binder -> index 0. Inside the let body, `id` is the nearest enclosing
-- binder -> index 0.
local VALID_TERM = {
	tag = "let", name = "id", locus = "let@1",
	value = { tag = "abs", param = "x", locus = "abs@1",
		body = { tag = "var", index = 0, name = "x", locus = "var@1" } },
	body = { tag = "app", locus = "app@1",
		fn = { tag = "var", index = 0, name = "id", locus = "var@2" },
		arg = { tag = "lit", base = "integer", value = 42, locus = "lit@1" } },
}

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("algorithm_w (" .. tier .. " tier) — valid certificate", function()
		local k = term_algebra.new({ tier = tier })
		local vocab, verr = hm.declare_vocabulary(k)
		if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
		local r = replayer.new(k)

		T.it("replays a valid W-derived certificate with zero replayer knowledge of W's semantics", function()
			local cert, err = w.certify(VALID_TERM, vocab)
			T.ok(cert, err)
			local root, rerr = r:replay_root(cert)
			T.ok(root, rerr)
		end)

		T.it("the replayed conclusion is has_type(int_ty -> int_ty ... ) resolved down to int_ty", function()
			-- `id 42` : integer -- id's param pins to integer at this call.
			local cert = w.certify(VALID_TERM, vocab)
			local root = r:replay_root(cert)
			T.ok(k.equal(root.conclusion, vocab.H(vocab.int_ty)))
		end)
	end)

	T.describe("algorithm_w (" .. tier .. " tier) — tampered certificates fail at replay, not silently", function()
		local k = term_algebra.new({ tier = tier })
		local vocab, verr = hm.declare_vocabulary(k)
		if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
		local r = replayer.new(k)

		T.it("rejects a malformed citation at construction (no name-keyed forgery possible any more)", function()
			-- vocab.rule_abs expects exactly 2 premises; citing it with 1 is
			-- rejected by cite_rule itself, before any replay is attempted --
			-- strictly earlier than the retired kernel's replay-time-only
			-- "unregistered rule schema" rejection.
			local hyp = replayer.hypothesis("h1", vocab.H(vocab.int_ty))
			local bad, err = replayer.cite_rule(vocab.rule_abs, { hyp })
			T.fail(bad)
			T.ok(err)
		end)

		T.it("rejects a broken well-foundedness cycle", function()
			-- Hand-built: a rule-citation node cannot literally cite itself as
			-- its own premise table entry at construction (Lua would need the
			-- table to already exist), so build it via a mutable local and
			-- patch the premises list in after construction -- this is exactly
			-- the kind of hand-tampering kernel_test.lua's own cycle case did.
			local hyp_a = replayer.hypothesis("ha", vocab.H(vocab.int_ty))
			local n1 = replayer.cite_rule(vocab.rule_abs, { hyp_a, hyp_a }, { { "ha" } })
			-- Force n1 to cite itself as one of its own premises.
			n1.premises[2] = n1
			local result, err = r:replay(n1)
			T.fail(result, "a self-citing node must not replay")
			T.ok(err and err:find("cycle"), "error should name the cycle: " .. tostring(err))
		end)

		T.it("rejects a hypothesis that is assumed but never discharged", function()
			local cert, err = w.certify(VALID_TERM, vocab)
			T.ok(cert, err)
			-- VALID_TERM's outermost construct is the `let` itself, so `cert`
			-- (the root certificate node) IS the hm-let citation directly.
			-- Strip its discharge of the let-bound "id" hypothesis, mirroring
			-- kernel_test.lua's "let_node.discharges = {}" tamper.
			T.ok(cert.rule == vocab.rule_let, "expected the root node to be the hm-let citation")
			cert.discharges[1] = {}
			local root, replay_err = r:replay_root(cert)
			T.fail(root, "an undischarged assumed hypothesis must not replay")
			T.ok(replay_err and replay_err:find("undischarged"), "error should name the missing discharge: " .. tostring(replay_err))
		end)
	end)

	T.describe("algorithm_w (" .. tier .. " tier) — W's documented limitation (shown, not fixed)", function()
		local k = term_algebra.new({ tier = tier })
		local vocab, verr = hm.declare_vocabulary(k)
		if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end

		T.it("pins a let-bound function's type variable at its first call site", function()
			-- let id = \x -> x in
			--   let a = id 1 in
			--     id true
			--
			-- A real let-polymorphic checker accepts this (id : forall a. a
			-- -> a, instantiated fresh at each call). This W does not
			-- generalize let-bindings (see algorithm_w.lua's header), so
			-- id's parameter type variable is unified with `integer` at the
			-- first call and stays pinned; the second call against `true`
			-- is rejected as a genuine type error, not a replayer failure.
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
			local cert, err = w.certify(term, vocab)
			T.fail(cert, "expected inference to fail on the second, differently-typed call")
			T.ok(err and err:find("cannot unify"), "error should be a genuine unify mismatch: " .. tostring(err))
		end)
	end)
end

return {}
