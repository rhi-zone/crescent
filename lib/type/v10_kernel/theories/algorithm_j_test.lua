-- lib/type/v10_kernel/theories/algorithm_j_test.lua
-- Ported from the retired lib/type/v10_kernel/algorithm_j_test.lua (see
-- algorithm_w_test.lua's header for the port context and the one dropped
-- tamper category — "forged citation by name" — that has no analog under
-- the new core's object-citation grammar).
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
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")
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

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("algorithm_j (" .. tier .. " tier) — valid certificate", function()
		local k = term_algebra.new({ tier = tier })
		local vocab, verr = hm.declare_vocabulary(k)
		if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
		local r = replayer.new(k)

		T.it("replays a valid J-derived certificate with zero replayer changes", function()
			local cert, err = j.certify(VALID_TERM, vocab)
			T.ok(cert, err)
			local root, rerr = r:replay_root(cert)
			T.ok(root, rerr)
		end)

		T.it("W and J certify the same conclusion for the identical term", function()
			local w = require("lib.type.v10_kernel.theories.algorithm_w")
			local wcert = w.certify(VALID_TERM, vocab)
			local jcert = j.certify(VALID_TERM, vocab)
			local wroot = r:replay_root(wcert)
			local jroot = r:replay_root(jcert)
			T.ok(k.equal(wroot.conclusion, jroot.conclusion))
		end)
	end)

	T.describe("algorithm_j (" .. tier .. " tier) — tampered certificates fail at replay, not silently", function()
		local k = term_algebra.new({ tier = tier })
		local vocab, verr = hm.declare_vocabulary(k)
		if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end
		local r = replayer.new(k)

		T.it("rejects a broken well-foundedness cycle", function()
			local hyp_a = replayer.hypothesis("ha", vocab.H(vocab.int_ty))
			local n1 = replayer.cite_rule(vocab.rule_abs, { hyp_a, hyp_a }, { { "ha" } })
			n1.premises[2] = n1
			local result, err = r:replay(n1)
			T.fail(result, "a self-citing node must not replay")
			T.ok(err and err:find("cycle"), "error should name the cycle: " .. tostring(err))
		end)

		T.it("rejects a hypothesis that is assumed but never discharged", function()
			local cert, err = j.certify(VALID_TERM, vocab)
			T.ok(cert, err)
			T.ok(cert.rule == vocab.rule_let, "expected the root node to be the hm-let citation")
			cert.discharges[1] = {}
			local root, replay_err = r:replay_root(cert)
			T.fail(root, "an undischarged assumed hypothesis must not replay")
			T.ok(replay_err and replay_err:find("undischarged"), "error should name the missing discharge: " .. tostring(replay_err))
		end)
	end)

	T.describe("algorithm_j (" .. tier .. " tier) — exhibits W's identical documented limitation", function()
		local k = term_algebra.new({ tier = tier })
		local vocab, verr = hm.declare_vocabulary(k)
		if not vocab then error("hm.declare_vocabulary failed: " .. tostring(verr)) end

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
end

return {}
