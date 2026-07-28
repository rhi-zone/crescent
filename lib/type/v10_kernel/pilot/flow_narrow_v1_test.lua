-- lib/type/v10_kernel/pilot/flow_narrow_v1_test.lua
--
-- Tests for the flow-narrowing theory (pilot/flow_narrow_v1.lua): the
-- signature declares cleanly; each of the two rule schemas replays a
-- hand-built certificate to the expected conclusion; a malformed variant of
-- each is rejected at replay; a two-guard chain (truthiness peel, then a
-- type()-tag peel on the remainder) replays end-to-end; taint from the
-- syntax-facts axiom propagates into the trust report and does not grow
-- across repeated citations of the same axiom declaration.

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local flow_narrow_v1 = require("lib.type.v10_kernel.pilot.flow_narrow_v1")

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("flow-narrow-v1 (" .. tier .. " tier)", function()
		local k = term_algebra.new({ tier = tier })
		local addr_sig = addr_v1.declare()
		local addr_ops = addr_sig.ops

		-- A file identity and a handful of structural points/paths, built the
		-- same way pilot/narrow_pilot_v1_test.lua builds its worked example.
		--: () -> unknown
		local function fid()
			return k.build(addr_ops.file_id_of, {
				k.build(addr_ops.bs_cons, { k.build(addr_ops.b1, {}), k.build(addr_ops.bs_nil, {}) }),
			})
		end
		--: (integer) -> unknown
		local function nat(n)
			local t = k.build(addr_ops.zero, {})
			for _ = 1, n do t = k.build(addr_ops.succ, { t }) end
			return t
		end
		-- A path is a child-index chain from the chunk root.
		--: (integer[]) -> unknown
		local function path(indices)
			local p = k.build(addr_ops.path_root, {})
			for _, i in ipairs(indices) do
				p = k.build(addr_ops.path_child, { p, nat(i) })
			end
			return p
		end
		--: (integer[]) -> unknown
		local function entry(indices) return k.build(addr_ops.entry_of, { fid(), path(indices) }) end
		--: (integer[]) -> unknown
		local function exit(indices) return k.build(addr_ops.exit_of, { fid(), path(indices) }) end
		-- The variable being narrowed: identified by its declaration-site path
		-- (pilot/narrow_pilot_v1's variable-identity choice, §2.3 of the
		-- proposal), a fixed local at child 5 of the root for every test here.
		local var_path = path({ 5 })

		T.it("declares with no errors, given an already-declared addr-v1", function()
			local vocab, err = flow_narrow_v1.declare_vocabulary(k, addr_sig)
			T.ok(vocab, err)
			T.eq(vocab.signature.name, "narrow-pilot-v1")
			T.eq(vocab.signature.version, 2)
			T.eq(vocab.signature.sorts.point, addr_sig.sorts.point)
			T.eq(vocab.signature.sorts.path, addr_sig.sorts.path)
		end)

		T.describe("narrow-select-match", function()
			local vocab = flow_narrow_v1.declare_vocabulary(k, addr_sig)
			local r = replayer.new(k)

			-- `type(x) == "string"` then-branch: x : string|nil at the guard
			-- point (exit of the test expr, child 0); then-branch entry is
			-- child 0 of child 1 (the if-statement), else-branch entry child 1.
			local pg = exit({ 1 })
			local pb_then = entry({ 1, 0 })
			local union_ty = vocab.TyUnion(vocab.TyOf(vocab.tag_string()), vocab.TyOf(vocab.tag_nil()))

			T.it("replays to the expected conclusion: x : string at the then-branch entry", function()
				local hyp = replayer.hypothesis("h-guard-ty", vocab.HoldsAt(pg, var_path, union_ty))
				local fact_node = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pg, depth = 0 },
					Pb = { term = pb_then, depth = 0 },
					X = { term = var_path, depth = 0 },
					TA = { term = vocab.TyOf(vocab.tag_string()), depth = 0 },
				})
				local node = replayer.cite_rule(vocab.rule_match, { hyp, fact_node })
				local result, err = r:replay(node)
				T.ok(result, err)
				T.ok(k.equal(result.conclusion, vocab.HoldsAt(pb_then, var_path, vocab.TyOf(vocab.tag_string()))))
			end)

			T.it("rejects when the syntax fact's target_ty does not match the union's first member", function()
				local hyp = replayer.hypothesis("h-guard-ty", vocab.HoldsAt(pg, var_path, union_ty))
				-- Claims the guard selects tag_number, but the actual type at
				-- the guard point has tag_string as its first union member.
				local fact_node = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pg, depth = 0 },
					Pb = { term = pb_then, depth = 0 },
					X = { term = var_path, depth = 0 },
					TA = { term = vocab.TyOf(vocab.tag_number()), depth = 0 },
				})
				local node = replayer.cite_rule(vocab.rule_match, { hyp, fact_node })
				local result, err = r:replay(node)
				T.eq(result, nil)
				T.ok(err)
			end)
		end)

		T.describe("narrow-select-rest", function()
			local vocab = flow_narrow_v1.declare_vocabulary(k, addr_sig)
			local r = replayer.new(k)

			local pg = exit({ 1 })
			local pb_else = entry({ 1, 1 })
			local union_ty = vocab.TyUnion(vocab.TyOf(vocab.tag_string()), vocab.TyOf(vocab.tag_nil()))

			T.it("replays to the expected conclusion: x : nil at the else-branch entry", function()
				local hyp = replayer.hypothesis("h-guard-ty", vocab.HoldsAt(pg, var_path, union_ty))
				local fact_node = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pg, depth = 0 },
					Pb = { term = pb_else, depth = 0 },
					X = { term = var_path, depth = 0 },
					TA = { term = vocab.TyOf(vocab.tag_string()), depth = 0 },
				})
				local node = replayer.cite_rule(vocab.rule_rest, { hyp, fact_node })
				local result, err = r:replay(node)
				T.ok(result, err)
				T.ok(k.equal(result.conclusion, vocab.HoldsAt(pb_else, var_path, vocab.TyOf(vocab.tag_nil()))))
			end)

			T.it("rejects when the syntax fact names a different guarded variable path", function()
				local other_path = path({ 6 })
				local hyp = replayer.hypothesis("h-guard-ty", vocab.HoldsAt(pg, var_path, union_ty))
				local fact_node = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pg, depth = 0 },
					Pb = { term = pb_else, depth = 0 },
					X = { term = other_path, depth = 0 },
					TA = { term = vocab.TyOf(vocab.tag_string()), depth = 0 },
				})
				local node = replayer.cite_rule(vocab.rule_rest, { hyp, fact_node })
				local result, err = r:replay(node)
				T.eq(result, nil)
				T.ok(err)
			end)
		end)

		T.it("the syntax-facts axiom rejects a discharge form (grammar rule, no discharge on axiom nodes)", function()
			local vocab = flow_narrow_v1.declare_vocabulary(k, addr_sig)
			local bad_ax, err = replayer.declare_axiom({
				name = "pilot-syntax-facts-v1-bad", version = 1, signature = vocab.signature,
				pattern = vocab.GuardSelects(
					k.build_meta("Pg", vocab.signature.sorts.point),
					k.build_meta("Pb", vocab.signature.sorts.point),
					k.build_meta("X", vocab.signature.sorts.path),
					k.build_meta("TA", vocab.signature.sorts.ty)
				),
				discharges = { { premise = 1, pattern = k.build_meta("X", vocab.signature.sorts.path) } },
			})
			T.eq(bad_ax, nil)
			T.ok(err)
		end)

		T.describe("chained derivation: truthiness peel, then a type-tag peel on the remainder", function()
			local vocab = flow_narrow_v1.declare_vocabulary(k, addr_sig)
			local r = replayer.new(k)

			-- x : (nil|false) | (string|table) at the outer guard's point.
			local truthy_remainder = vocab.TyUnion(vocab.TyOf(vocab.tag_string()), vocab.TyOf(vocab.tag_table()))
			local whole_ty = vocab.TyUnion(vocab.falsy_ty(), truthy_remainder)

			-- Guard 1: `if x then` at exit({0}); then-branch entry({0,0}).
			local pg1 = exit({ 0 })
			local pb1 = entry({ 0, 0 })
			-- Guard 2, nested inside guard 1's then-branch: `if type(x) ==
			-- "string" then` at exit({0,0,2}); its then-branch entry({0,0,2,0}).
			local pg2 = exit({ 0, 0, 2 })
			local pb2 = entry({ 0, 0, 2, 0 })

			T.it("replays end-to-end: x : string at the innermost then-branch", function()
				local hyp = replayer.hypothesis("h-x-ty", vocab.HoldsAt(pg1, var_path, whole_ty))
				local fact1 = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pg1, depth = 0 },
					Pb = { term = pb1, depth = 0 },
					X = { term = var_path, depth = 0 },
					TA = { term = vocab.falsy_ty(), depth = 0 },
				})
				-- Truthiness then-branch keeps the REST (the truthy remainder).
				local step1 = replayer.cite_rule(vocab.rule_rest, { hyp, fact1 })

				-- step1's conclusion is holds_at(pb1, var_path, truthy_remainder)
				-- — re-cite it as guard 2's own "type fact at the guard point"
				-- premise. Guard 2 evaluates at pb1 itself (same point the prior
				-- narrowing landed at, before descending into the nested if).
				local fact2 = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pb1, depth = 0 },
					Pb = { term = pb2, depth = 0 },
					X = { term = var_path, depth = 0 },
					TA = { term = vocab.TyOf(vocab.tag_string()), depth = 0 },
				})
				local step2 = replayer.cite_rule(vocab.rule_match, { step1, fact2 })

				local result, err = r:replay(step2)
				T.ok(result, err)
				T.ok(k.equal(result.conclusion, vocab.HoldsAt(pb2, var_path, vocab.TyOf(vocab.tag_string()))))
			end)

			T.it("taint carries the syntax-facts axiom key, deduplicated across both citations", function()
				local hyp = replayer.hypothesis("h-x-ty", vocab.HoldsAt(pg1, var_path, whole_ty))
				local fact1 = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pg1, depth = 0 },
					Pb = { term = pb1, depth = 0 },
					X = { term = var_path, depth = 0 },
					TA = { term = vocab.falsy_ty(), depth = 0 },
				})
				local step1 = replayer.cite_rule(vocab.rule_rest, { hyp, fact1 })
				local fact2 = replayer.cite_axiom(vocab.ax_syntax_facts, {
					Pg = { term = pb1, depth = 0 },
					Pb = { term = pb2, depth = 0 },
					X = { term = var_path, depth = 0 },
					TA = { term = vocab.TyOf(vocab.tag_string()), depth = 0 },
				})
				local step2 = replayer.cite_rule(vocab.rule_match, { step1, fact2 })

				local result, err = r:replay(step2)
				T.ok(result, err)
				local report = r:trust_report(result)
				local keys = {}
				local n = 0
				for key in pairs(report.taint) do n = n + 1; keys[n] = key end
				T.eq(n, 1)
				T.eq(keys[1], "pilot-syntax-facts-v1@v1")
				-- The hypothesis leaf itself stays open (no discharge slot in
				-- either narrowing rule — see module header) — confirm it is
				-- exactly the one open id, not silently dropped or duplicated.
				local open_ids = {}
				local on = 0
				for id in pairs(result.open) do on = on + 1; open_ids[on] = id end
				T.eq(on, 1)
				T.eq(open_ids[1], "h-x-ty")
			end)
		end)
	end)
end

return {}
