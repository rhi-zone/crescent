-- lib/type/v10_kernel/pilot/assign_effects_v1_test.lua
--
-- Tests for the effects theory (pilot/assign_effects_v1.lua): the signature
-- declares cleanly over an already-declared spine; `preserves-transfer`
-- replays a hand-built citation of its own syntax-fact axiom to the
-- expected spine conclusion (taint carries exactly that axiom key);
-- `preserves-trans` chains two `preserves-transfer` derivations into one
-- longer span with NO further taint (a genuine rule, not an axiom); a
-- malformed variant (mismatched `x`) is rejected at replay.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local effects_spine_v1 = require("lib.type.v10_kernel.pilot.effects_spine_v1")
local assign_effects_v1 = require("lib.type.v10_kernel.pilot.assign_effects_v1")

--: (v: Term | nil, err: string | nil) -> Term
local function must_term(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Signature | nil, err: string | nil) -> Signature
local function must_sig(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: EffectsSpine | nil, err: string | nil) -> EffectsSpine
local function must_spine(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: AssignEffectsVocab | nil, err: string | nil) -> AssignEffectsVocab
local function must_vocab(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Replayer | nil, err: string | nil) -> Replayer
local function must_rp(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

local addr_sig_raw, addr_sig_err = addr_v1.declare()
local addr_sig = must_sig(addr_sig_raw, addr_sig_err)
local addr_ops = addr_sig.ops

--: (n: integer) -> Term
local function nat(n)
	local t = must_term(ta.build(addr_ops.zero, {}))
	for _ = 1, n do t = must_term(ta.build(addr_ops.succ, { t })) end
	return t
end
--: (indices: integer[]) -> Term
local function path(indices)
	local p = must_term(ta.build(addr_ops.path_root, {}))
	for _, i in ipairs(indices) do
		p = must_term(ta.build(addr_ops.path_child, { p, nat(i) }))
	end
	return p
end
--: () -> Term
local function fid()
	return must_term(ta.build(addr_ops.file_id_of, {
		must_term(ta.build(addr_ops.bs_cons, {
			must_term(ta.build(addr_ops.b1, {})), must_term(ta.build(addr_ops.bs_nil, {})),
		})),
	}))
end
--: (indices: integer[]) -> Term
local function entry(indices) return must_term(ta.build(addr_ops.entry_of, { fid(), path(indices) })) end
--: (indices: integer[]) -> Term
local function exit(indices) return must_term(ta.build(addr_ops.exit_of, { fid(), path(indices) })) end

local var_path = path({ 5 })
local other_path = path({ 6 })

--:: Setup = { vocab: AssignEffectsVocab, rp: Replayer }

--: () -> Setup
local function setup()
	local reg = rl.new_registry()
	local spine_raw, spine_err = effects_spine_v1.declare(addr_sig)
	local spine = must_spine(spine_raw, spine_err)
	local vocab_raw, vocab_err = assign_effects_v1.declare_vocabulary(reg, addr_sig, spine)
	local vocab = must_vocab(vocab_raw, vocab_err)
	local rp_raw, rp_err = rl.new_replayer({ registry = reg })
	local rp = must_rp(rp_raw, rp_err)
	return { vocab = vocab, rp = rp }
end

T.describe("assign-effects-v1", function()
	T.it("declares with no errors, given an already-declared addr-v1 and spine", function()
		local reg = rl.new_registry()
		local spine, serr = effects_spine_v1.declare(addr_sig)
		T.ok(spine, serr)
		if spine == nil then return end
		local vocab, err = assign_effects_v1.declare_vocabulary(reg, addr_sig, spine)
		T.ok(vocab, err)
		if vocab == nil then return end
		T.eq(vocab.signature.name, "assign-effects-v1")
		T.eq(vocab.signature.version, 1)
	end)

	T.it("preserves-transfer replays to preserves(from,to,x), tainted by exactly the syntax-facts axiom", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local p_from = exit({ 0 })
		local p_to = entry({ 1 })
		local fact_node = {
			kind = "axiom", axiom = vocab.ax_syntax_facts,
			bindings = { A = p_from, B = p_to, X = var_path },
		} --[[: CertNode ]]
		local node = { kind = "rule", rule = vocab.rule_transfer, premises = { fact_node } } --[[: CertNode ]]
		local result, err = rl.replay(rp, node)
		T.ok(result, err)
		if result == nil then return end
		T.ok(ta.equal(result.conclusion, must_term(vocab.Preserves(p_from, p_to, var_path))))
		local n = 0
		local only_key = nil --[[: string | nil ]]
		for key in pairs(result.taint) do n = n + 1; only_key = key end
		T.eq(n, 1)
		T.eq(only_key, rl.citation_key("assign-effects-syntax-facts-v1", 1))
	end)

	T.it("preserves-trans chains two spans with NO additional taint beyond the two syntax facts", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local p1 = exit({ 0 })
		local p2 = entry({ 1 })
		local p3 = exit({ 1 })
		local fact1 = {
			kind = "axiom", axiom = vocab.ax_syntax_facts, bindings = { A = p1, B = p2, X = var_path },
		} --[[: CertNode ]]
		local fact2 = {
			kind = "axiom", axiom = vocab.ax_syntax_facts, bindings = { A = p2, B = p3, X = var_path },
		} --[[: CertNode ]]
		local step1 = { kind = "rule", rule = vocab.rule_transfer, premises = { fact1 } } --[[: CertNode ]]
		local step2 = { kind = "rule", rule = vocab.rule_transfer, premises = { fact2 } } --[[: CertNode ]]
		local chained = { kind = "rule", rule = vocab.rule_trans, premises = { step1, step2 } } --[[: CertNode ]]
		local result, err = rl.replay(rp, chained)
		T.ok(result, err)
		if result == nil then return end
		T.ok(ta.equal(result.conclusion, must_term(vocab.Preserves(p1, p3, var_path))))
		local n = 0
		for _ in pairs(result.taint) do n = n + 1 end
		T.eq(n, 1) -- both spans cite the SAME axiom declaration; taint is a set, not a multiset
	end)

	T.it("preserves-trans rejects when the two spans don't share the middle point", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local p1 = exit({ 0 })
		local p2 = entry({ 1 })
		local p2_other = entry({ 2 }) -- deliberately NOT p2
		local p3 = exit({ 1 })
		local fact1 = {
			kind = "axiom", axiom = vocab.ax_syntax_facts, bindings = { A = p1, B = p2, X = var_path },
		} --[[: CertNode ]]
		local fact2 = {
			kind = "axiom", axiom = vocab.ax_syntax_facts, bindings = { A = p2_other, B = p3, X = var_path },
		} --[[: CertNode ]]
		local step1 = { kind = "rule", rule = vocab.rule_transfer, premises = { fact1 } } --[[: CertNode ]]
		local step2 = { kind = "rule", rule = vocab.rule_transfer, premises = { fact2 } } --[[: CertNode ]]
		local chained = { kind = "rule", rule = vocab.rule_trans, premises = { step1, step2 } } --[[: CertNode ]]
		local result, err = rl.replay(rp, chained)
		T.eq(result, nil)
		T.ok(err)
	end)

	T.it("preserves-trans rejects when the two spans name different paths", function()
		local s = setup()
		local vocab, rp = s.vocab, s.rp
		local p1 = exit({ 0 })
		local p2 = entry({ 1 })
		local p3 = exit({ 1 })
		local fact1 = {
			kind = "axiom", axiom = vocab.ax_syntax_facts, bindings = { A = p1, B = p2, X = var_path },
		} --[[: CertNode ]]
		local fact2 = {
			kind = "axiom", axiom = vocab.ax_syntax_facts, bindings = { A = p2, B = p3, X = other_path },
		} --[[: CertNode ]]
		local step1 = { kind = "rule", rule = vocab.rule_transfer, premises = { fact1 } } --[[: CertNode ]]
		local step2 = { kind = "rule", rule = vocab.rule_transfer, premises = { fact2 } } --[[: CertNode ]]
		local chained = { kind = "rule", rule = vocab.rule_trans, premises = { step1, step2 } } --[[: CertNode ]]
		local result, err = rl.replay(rp, chained)
		T.eq(result, nil)
		T.ok(err)
	end)
end)

return {}
