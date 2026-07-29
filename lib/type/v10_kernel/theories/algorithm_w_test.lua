-- lib/type/v10_kernel/theories/algorithm_w_test.lua
-- Algorithm W over the canonical v10 core (lib/type/v10_cleanroom/, per the
-- owner-ratified canon swap). Demonstrates the same v10 trust-core shape as
-- before the swap:
--   (a) a valid W-derived certificate replays with zero replayer knowledge
--       of W's semantics
--   (b) tampered certificates fail replay, not silently: a malformed
--       citation (wrong premise count), a well-foundedness cycle, and a
--       hypothesis discharge stripped after construction
--   (c) W's own documented limitation (no let-generalization) rejects a
--       program a real let-polymorphic checker would accept — shown, not
--       fixed
--
-- Two structural differences from the pre-swap suite, both forced by the
-- canonical core's grammar (mechanical, not semantic):
--   - Certificates are plain tables with no constructors, so the old
--     "malformed citation rejected at construction" case has no
--     construction step to reject at any more — the same tamper (citing
--     hm-abs with one premise) is rejected at REPLAY instead ("expects 2
--     premise(s)"). Same tamper, same verdict, later (and sole) checkpoint.
--   - Hypothesis identity is the leaf node OBJECT (F8), not an id string,
--     so discharge tampering strips node references, not id lists.
-- The old suite's per-tier loop is gone: the canonical core is the
-- reference tier only (the fast tier retired with the old core).

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
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

--:: HmSetup = { vocab: Vocab, rp: Replayer }

-- One registry + vocabulary + replayer per describe block: (name, version)
-- is unique per registry (F11), so a fresh vocabulary needs a fresh
-- registry.
--: () -> HmSetup
local function setup()
	local reg = rl.new_registry()
	local vocab, verr = hm.declare_vocabulary(reg)
	if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
	local rp, rerr = rl.new_replayer({ registry = reg })
	if not rp then error("rl.new_replayer failed: " .. tostring(rerr)) end
	return { vocab = vocab, rp = rp }
end

T.describe("algorithm_w — valid certificate", function()
	local s = setup()
	local vocab, rp = s.vocab, s.rp

	T.it("replays a valid W-derived certificate with zero replayer knowledge of W's semantics", function()
		local cert, err = w.certify(VALID_TERM, vocab)
		T.ok(cert, err)
		if cert == nil then return end
		local root, rerr = rl.replay(rp, cert)
		T.ok(root, rerr)
	end)

	T.it("the replayed conclusion is has_type(int_ty -> int_ty ... ) resolved down to int_ty", function()
		-- `id 42` : integer -- id's param pins to integer at this call.
		local cert = w.certify(VALID_TERM, vocab)
		T.ok(cert)
		if cert == nil then return end
		local root = rl.replay(rp, cert)
		T.ok(root)
		local expected = vocab.H(vocab.int_ty)
		T.ok(root ~= nil and expected ~= nil and ta.equal(root.conclusion, expected))
	end)
end)

T.describe("algorithm_w — tampered certificates fail at replay, not silently", function()
	local s = setup()
	local vocab, rp = s.vocab, s.rp

	T.it("rejects a malformed citation at replay (wrong premise count)", function()
		-- vocab.rule_abs expects exactly 2 premises. Certificates are plain
		-- tables under the canonical grammar — there is no construction
		-- step to reject at, so the malformed citation is rejected at
		-- replay, the grammar's sole validation point.
		local hyp = { kind = "hypothesis", judgment = vocab.H(vocab.int_ty) } --[[: CertNode ]]
		local bad = { kind = "rule", rule = vocab.rule_abs, premises = { hyp } } --[[: CertNode ]]
		local root, err = rl.replay(rp, bad)
		T.fail(root)
		T.ok(err and err:find("expects 2"), "error should name the premise count: " .. tostring(err))
	end)

	T.it("rejects a broken well-foundedness cycle", function()
		-- Hand-built: force a rule-citation node to cite itself as one of
		-- its own premises after construction — the same hand-tampering the
		-- pre-swap suite's cycle case did.
		local hyp_a = { kind = "hypothesis", judgment = vocab.H(vocab.int_ty) } --[[: CertNode ]]
		local n1 = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hyp_a, hyp_a },
			discharge = { [1] = { hyp_a } },
		} --[[: CertNode ]]
		n1.premises[2] = n1
		local result, err = rl.replay(rp, n1)
		T.fail(result, "a self-citing node must not replay")
		T.ok(err and err:find("cycle"), "error should name the cycle: " .. tostring(err))
	end)

	T.it("rejects a hypothesis that is assumed but never discharged", function()
		local cert, err = w.certify(VALID_TERM, vocab)
		T.ok(cert, err)
		-- VALID_TERM's outermost construct is the `let` itself, so `cert`
		-- (the root certificate node) IS the hm-let citation directly.
		-- Strip its discharge of the let-bound "id" hypothesis (a node
		-- reference under F8, not an id string).
		if cert == nil then return end
		T.ok(cert.rule == vocab.rule_let, "expected the root node to be the hm-let citation")
		if cert.discharge ~= nil then cert.discharge[1] = {} end
		local root, replay_err = rl.replay(rp, cert)
		T.fail(root, "an undischarged assumed hypothesis must not replay")
		T.ok(replay_err and replay_err:find("undischarged"), "error should name the missing discharge: " .. tostring(replay_err))
	end)
end)

T.describe("algorithm_w — W's documented limitation (shown, not fixed)", function()
	local s = setup()
	local vocab = s.vocab

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

return {}
