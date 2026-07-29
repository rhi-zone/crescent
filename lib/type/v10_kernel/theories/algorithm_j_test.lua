-- lib/type/v10_kernel/theories/algorithm_j_test.lua
-- Algorithm J over the canonical v10 core (see algorithm_w_test.lua's
-- header for the canon-swap port context and the two structural differences
-- from the pre-swap suite: replay-time-only citation validation, and F8
-- node-identity discharge).
--
-- Demonstrates the v10 core's GENERICITY claim using Algorithm J (the
-- imperative, mutable-ref-cell reformulation of the same Damas-Milner
-- algorithm algorithm_w.lua certifies functionally):
--   (a) a valid J-derived certificate replays with zero replayer knowledge
--       of J's semantics — same replayer, same hm.lua vocabulary as W,
--       zero changes, zero special-casing (see algorithm_j.lua's header
--       for the genericity finding this checks)
--   (b) J exhibits the IDENTICAL documented limitation W does (no
--       let-generalization pins a let-bound type variable at its first
--       call site) on the same term, confirming W and J are genuinely
--       equivalent in what they certify, not just superficially similar
--   (c) a tampered J-emitted certificate fails replay the same way
--       tampered W certificates do (well-foundedness cycle, skipped
--       discharge)

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local hm = require("lib.type.v10_kernel.theories.hm")
local j = require("lib.type.v10_kernel.theories.algorithm_j")

local VALID_TERM = {
	tag = "let", name = "id", locus = "let@1",
	value = { tag = "abs", param = "x", locus = "abs@1",
		body = { tag = "var", index = 0, name = "x", locus = "var@1" } },
	body = { tag = "app", locus = "app@1",
		fn = { tag = "var", index = 0, name = "id", locus = "var@2" },
		arg = { tag = "lit", base = "integer", value = 42, locus = "lit@1" } },
}

--:: HmSetup = { vocab: Vocab, rp: Replayer }

-- One registry + vocabulary + replayer per describe block ((name, version)
-- unique per registry, F11).
--: () -> HmSetup
local function setup()
	local reg = rl.new_registry()
	local vocab, verr = hm.declare_vocabulary(reg)
	if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
	local rp, rerr = rl.new_replayer({ registry = reg })
	if not rp then error("rl.new_replayer failed: " .. tostring(rerr)) end
	return { vocab = vocab, rp = rp }
end

T.describe("algorithm_j — valid certificate", function()
	local s = setup()
	local vocab, rp = s.vocab, s.rp

	T.it("replays a valid J-derived certificate with zero replayer changes", function()
		local cert, err = j.certify(VALID_TERM, vocab)
		T.ok(cert, err)
		if cert == nil then return end
		local root, rerr = rl.replay(rp, cert)
		T.ok(root, rerr)
	end)

	T.it("W and J certify the same conclusion for the identical term", function()
		local w = require("lib.type.v10_kernel.theories.algorithm_w")
		local wcert = w.certify(VALID_TERM, vocab)
		local jcert = j.certify(VALID_TERM, vocab)
		T.ok(wcert)
		T.ok(jcert)
		if wcert == nil or jcert == nil then return end
		local wroot = rl.replay(rp, wcert)
		local jroot = rl.replay(rp, jcert)
		T.ok(wroot)
		T.ok(jroot)
		T.ok(wroot ~= nil and jroot ~= nil and ta.equal(wroot.conclusion, jroot.conclusion))
	end)
end)

T.describe("algorithm_j — tampered certificates fail at replay, not silently", function()
	local s = setup()
	local vocab, rp = s.vocab, s.rp

	T.it("rejects a broken well-foundedness cycle", function()
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
		local cert, err = j.certify(VALID_TERM, vocab)
		T.ok(cert, err)
		if cert == nil then return end
		T.ok(cert.rule == vocab.rule_let, "expected the root node to be the hm-let citation")
		if cert.discharge ~= nil then cert.discharge[1] = {} end
		local root, replay_err = rl.replay(rp, cert)
		T.fail(root, "an undischarged assumed hypothesis must not replay")
		T.ok(replay_err and replay_err:find("undischarged"), "error should name the missing discharge: " .. tostring(replay_err))
	end)
end)

T.describe("algorithm_j — exhibits W's identical documented limitation", function()
	local s = setup()
	local vocab = s.vocab

	T.it("pins a let-bound function's type variable at its first call site, same as W", function()
		-- Identical term to algorithm_w_test.lua's "known limitation" case.
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
		local cert, err = j.certify(term, vocab)
		T.fail(cert, "expected inference to fail on the second, differently-typed call")
		T.ok(err and err:find("cannot unify"), "error should be a genuine unify mismatch: " .. tostring(err))
	end)
end)

return {}
