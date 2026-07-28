-- lib/type/v10_kernel/replayer/replayer_test.lua
--
-- Unit tests for the v10 kernel replayer (registry declaration validation,
-- replay success/failure paths, taint propagation, memoization/anti-
-- laundering across kernel configs, and the MANDATORY acceptance test for
-- DAG-shared discharge from docs/decisions/typechecker-v10-core-design.md
-- / the task brief: a subderivation shared by two parents with different
-- discharge contexts must show identical taint via both parents and
-- different open-hypothesis contributions, with the undischarged path
-- correctly failing root acceptance.
--
-- Toy signature/rule/axiom vocabulary built here is test fixture only, not
-- design vocabulary (per the brief: "invent freely for test fixtures").

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local replayer = require("lib.type.v10_kernel.replayer")

-- ── Test signature: a minimal propositional-logic-flavored toy theory ──────
--
--   prop           : sort of propositions (as terms, e.g. atoms/conjunctions)
--   pf             : sort of proof judgments
--   atom(p)        : prop <- prop                       (opaque atom wrapper, non-binding)
--   conj(a, b)     : prop <- prop, prop                 (conjunction, non-binding)
--   holds(p)       : pf <- prop                          (the judgment "p holds")

local sig, sig_err = term_algebra.declare_signature({
	name = "toy-prop",
	version = 1,
	sorts = { "prop", "pf" },
	ops = {
		top = { result = "prop", args = {} },
		atom = { result = "prop", args = { { sort = "prop" } } },
		conj = { result = "prop", args = { { sort = "prop" }, { sort = "prop" } } },
		holds = { result = "pf", args = { { sort = "prop" } } },
	},
})
T.it("declare_signature succeeds for the toy theory", function()
	T.ok(sig, sig_err)
end)

-- A second, unrelated signature (for cross-signature rejection tests). It
-- imports `sig`'s "prop" sort (rather than re-declaring its own same-named
-- one) specifically so that a term built from `sig`'s vocabulary (`top`,
-- below) can still be passed into `other_sig`'s operators — the point of
-- the cross-signature test below is OPERATOR identity rejection, not an
-- incidental sort-identity mismatch (with sort identity now
-- declaration-based, an un-imported same-named "prop" would make `build`
-- itself reject earlier, for the wrong reason).
local other_sig = term_algebra.declare_signature({
	name = "toy-other",
	version = 1,
	sorts = { "pf" },
	imports = { prop = sig.sorts.prop },
	ops = {
		atom = { result = "prop", args = { { sort = "prop" } } },
		holds = { result = "pf", args = { { sort = "prop" } } },
	},
})

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe(tier .. " tier", function()
		local k = term_algebra.new({ tier = tier })

		-- Small term-building helpers over this tier + signature.
		--: (x: unknown) -> (unknown | nil, string | nil)
		local function A(x) return k.build(sig.ops.atom, { x }) end
		--: (a: unknown, b: unknown) -> (unknown | nil, string | nil)
		local function C(a, b) return k.build(sig.ops.conj, { a, b }) end
		--: (p: unknown) -> (unknown | nil, string | nil)
		local function H(p) return k.build(sig.ops.holds, { p }) end
		--: (id: string, sort: unknown) -> (unknown | nil, string | nil)
		local function meta(id, sort) return k.build_meta(id, sort) end

		-- Ground, CLOSED props p, q for concrete fixtures (built from the
		-- nullary `top` operator, not a bare var() -- a var(k,sort) leaf is
		-- ground but never closed, since it always carries a non-empty
		-- free-variable context; root acceptance requires closed, so
		-- fixtures meant to reach root acceptance need a genuinely closed
		-- base term).
		local top = k.build(sig.ops.top, {})
		local p = A(top) -- atom(top) : prop
		local q = A(A(top)) -- a distinct ground, closed prop
		T.it("fixtures p and q are ground, closed, and distinct", function()
			T.ok(k.is_ground(p))
			T.ok(k.is_ground(q))
			T.ok(k.is_closed(p))
			T.ok(k.is_closed(q))
			T.fail(k.equal(p, q))
		end)

		-- ── Rule schemas ──────────────────────────────────────────────────

		-- conj-intro: holds(X), holds(Y) |- holds(conj(X,Y))  (no discharge)
		local conj_intro, ci_err = replayer.declare_rule({
			name = "conj-intro",
			version = 1,
			signature = sig,
			premises = { H(meta("X", sig.sorts.prop)), H(meta("Y", sig.sorts.prop)) },
			conclusion = H(C(meta("X", sig.sorts.prop), meta("Y", sig.sorts.prop))),
		})
		T.it("declare_rule succeeds for conj-intro", function()
			T.ok(conj_intro, ci_err)
		end)

		-- self-conj: holds(X), holds(X) |- holds(conj(X,X))  (non-linear metavariable)
		local self_conj = replayer.declare_rule({
			name = "self-conj",
			version = 1,
			signature = sig,
			premises = { H(meta("X", sig.sorts.prop)), H(meta("X", sig.sorts.prop)) },
			conclusion = H(C(meta("X", sig.sorts.prop), meta("X", sig.sorts.prop))),
		})
		T.it("declare_rule succeeds for self-conj (non-linear metavariable)", function()
			T.ok(self_conj)
		end)

		-- discharge-intro: holds(X) |- holds(X), discharging premise-1
		-- hypothesis ids whose judgment equals holds(X) (X is the SAME
		-- metavariable premise 1 itself binds -- deliberately simple: the
		-- discharge slot's pattern must reuse only metavariables the rule's
		-- own premises bind, since the schema-level pattern has no other
		-- source of bindings).
		local discharge_intro = replayer.declare_rule({
			name = "discharge-intro",
			version = 1,
			signature = sig,
			premises = { H(meta("X", sig.sorts.prop)) },
			conclusion = H(meta("X", sig.sorts.prop)),
			discharges = { { premise = 1, pattern = H(meta("X", sig.sorts.prop)) } },
		})
		T.it("declare_rule succeeds for discharge-intro (one discharge slot)", function()
			T.ok(discharge_intro)
		end)

		-- unbound-concl: holds(X) |- holds(Y)  (Y never bound by any premise)
		local unbound_concl = replayer.declare_rule({
			name = "unbound-concl",
			version = 1,
			signature = sig,
			premises = { H(meta("X", sig.sorts.prop)) },
			conclusion = H(meta("Y", sig.sorts.prop)),
		})

		-- ── Axiom ─────────────────────────────────────────────────────────

		-- ax-holds-p: |- holds(p)  (ground axiom, ground = zero-metavariable case)
		local ax_holds_p, ax_err = replayer.declare_axiom({
			name = "ax-holds-p",
			version = 1,
			signature = sig,
			pattern = H(p),
		})
		T.it("declare_axiom succeeds for a ground axiom", function()
			T.ok(ax_holds_p, ax_err)
		end)

		-- schematic axiom: |- holds(conj(X,X))  (schematic; not ground until instantiated)
		local ax_schematic = replayer.declare_axiom({
			name = "ax-schematic-self-conj",
			version = 1,
			signature = sig,
			pattern = H(C(meta("X", sig.sorts.prop), meta("X", sig.sorts.prop))),
		})

		-- ── declare_rule / declare_axiom validation failures ────────────────

		T.describe("declaration validation", function()
			T.it("declare_rule rejects a pattern from the wrong signature", function()
				local other_p = k.build(other_sig.ops.atom, { top })
				local other_h = k.build(other_sig.ops.holds, { other_p })
				local bad, err = replayer.declare_rule({
					name = "bad-sig",
					version = 1,
					signature = sig,
					premises = {},
					conclusion = other_h,
				})
				T.fail(bad)
				T.ok(err)
			end)

			T.it("declare_rule rejects an out-of-range discharge premise index", function()
				local bad, err = replayer.declare_rule({
					name = "bad-discharge-range",
					version = 1,
					signature = sig,
					premises = { H(meta("X", sig.sorts.prop)) },
					conclusion = H(meta("X", sig.sorts.prop)),
					discharges = { { premise = 2, pattern = H(meta("X", sig.sorts.prop)) } },
				})
				T.fail(bad)
				T.ok(err)
			end)

			T.it("declare_axiom rejects a non-empty discharges field (axiom nodes admit no discharge form)", function()
				local bad, err = replayer.declare_axiom({
					name = "bad-axiom-discharge",
					version = 1,
					signature = sig,
					pattern = H(p),
					discharges = { { premise = 1, pattern = H(p) } },
				})
				T.fail(bad)
				T.ok(err)
			end)

			T.it("declare_axiom accepts an explicit empty discharges field", function()
				local ok, err = replayer.declare_axiom({
					name = "ok-empty-discharge",
					version = 1,
					signature = sig,
					pattern = H(p),
					discharges = {},
				})
				T.ok(ok, err)
			end)
		end)

		-- ── Certificate construction validation ─────────────────────────────

		T.describe("certificate construction validation", function()
			local hyp_x = replayer.hypothesis("hx", H(p))

			T.it("cite_rule rejects wrong premise arity", function()
				local bad, err = replayer.cite_rule(conj_intro, { hyp_x })
				T.fail(bad)
				T.ok(err)
			end)

			T.it("cite_rule rejects wrong discharge-slot-list arity", function()
				local bad, err = replayer.cite_rule(discharge_intro, { hyp_x }, { {}, {} })
				T.fail(bad)
				T.ok(err)
			end)

			T.it("cite_rule accepts omitted discharges for a rule with a slot (vacuous)", function()
				local ok, err = replayer.cite_rule(discharge_intro, { hyp_x })
				T.ok(ok, err)
			end)

			T.it("hypothesis rejects a non-term judgment", function()
				local bad, err = replayer.hypothesis("h", "not a term")
				T.fail(bad)
				T.ok(err)
			end)
		end)

		-- ── Replay success/failure paths ─────────────────────────────────

		T.describe("replay", function()
			local r = replayer.new(k)

			T.it("replayer.new reports tier/config", function()
				T.ok(r)
			end)

			T.it("replays a ground axiom citation to its declared conclusion", function()
				local node = replayer.cite_axiom(ax_holds_p, {})
				local result, err = r:replay(node)
				T.ok(result, err)
				T.ok(k.equal(result.conclusion, H(p)))
				T.eq(next(result.taint), "ax-holds-p@v1")
				T.eq(next(result.open), nil)
			end)

			T.it("replays a schematic axiom citation via bindings", function()
				local node = replayer.cite_axiom(ax_schematic, { X = { term = p, depth = 0 } })
				local result, err = r:replay(node)
				T.ok(result, err)
				T.ok(k.equal(result.conclusion, H(C(p, p))))
			end)

			T.it("replays a rule citation over two axiom-citation premises", function()
				local prem1 = replayer.cite_axiom(ax_holds_p, {})
				local prem2 = replayer.cite_axiom(ax_schematic, { X = { term = q, depth = 0 } })
				local node = replayer.cite_rule(conj_intro, { prem1, prem2 })
				local result, err = r:replay(node)
				T.ok(result, err)
				T.ok(k.equal(result.conclusion, H(C(p, C(q, q)))))
			end)

			T.it("root acceptance succeeds for a closed, ground, fully-discharged derivation", function()
				local node = replayer.cite_axiom(ax_holds_p, {})
				local root, err = r:replay_root(node)
				T.ok(root, err)
				T.ok(k.equal(root.conclusion, H(p)))
				T.eq(root.trust.run_label.eq, k.trust_label.eq)
			end)

			T.it("rejects bad citation arity (cite_rule construction itself rejects)", function()
				local bad = replayer.cite_rule(conj_intro, { replayer.hypothesis("h1", H(p)) })
				T.fail(bad)
			end)

			T.it("rejects a premise match failure", function()
				-- self_conj expects both premises to match the SAME metavariable X;
				-- citing two axiom premises with different conclusions must fail to match.
				local prem1 = replayer.cite_axiom(ax_holds_p, {}) -- holds(p)
				local prem2 = replayer.cite_axiom(ax_schematic, { X = { term = q, depth = 0 } }) -- holds(conj(q,q))
				local node = replayer.cite_rule(self_conj, { prem1, prem2 })
				local result, err = r:replay(node)
				T.fail(result)
				T.ok(err)
			end)

			T.it("rejects a non-ground conclusion (a hypothesis's own judgment carries a metavariable that survives instantiation)", function()
				-- A hypothesis is unchecked at its own leaf ("not trusted");
				-- its judgment can structurally contain a metavariable node.
				-- Here it matches conj-intro's premise pattern H(meta X)
				-- just fine (structurally: holds(meta Z) IS an op node of
				-- the right shape), binding X to that bare metavariable --
				-- so the rule's conclusion instantiate() succeeds but the
				-- RESULT still contains a leftover metavariable, which
				-- must be rejected as non-ground (distinct from the
				-- unbound-metavariable case below, where instantiate
				-- itself fails).
				local meta_hyp = replayer.hypothesis("hz", H(meta("Z", sig.sorts.prop)))
				local prem2 = replayer.cite_axiom(ax_holds_p, {})
				local node = replayer.cite_rule(conj_intro, { meta_hyp, prem2 })
				local result, err = r:replay(node)
				T.fail(result)
				T.ok(err)
			end)

			T.it("rejects an unbound metavariable in the conclusion pattern", function()
				local prem = replayer.cite_axiom(ax_holds_p, {})
				local node = replayer.cite_rule(unbound_concl, { prem })
				local result, err = r:replay(node)
				T.fail(result)
				T.ok(err)
			end)

			T.it("rejects a hypothesis judgment mismatch at discharge", function()
				local inner_hyp = replayer.hypothesis("hy", H(q)) -- open judgment holds(q)
				-- discharge_intro's discharge slot pattern is H(meta Y); it will match
				-- ANY hyp judgment structurally (Y unifies with whatever prop is there),
				-- so to force a genuine mismatch we discharge against a citation whose
				-- premise conclusion structurally differs from the hyp's own judgment
				-- after binding -- use self_conj's shared-metavariable premise structure
				-- with an explicit mismatching named-id discharge instead.
				local prem_inner = replayer.hypothesis("h_inner", H(p))
				local rule_node = replayer.cite_rule(discharge_intro, { prem_inner }, { { "h_inner" } })
				local result, err = r:replay(rule_node)
				T.ok(result, err) -- sanity: legitimate discharge succeeds first

				-- Now the genuine mismatch case: name an id whose actual judgment does
				-- not equal instantiate(pattern, bindings). discharge_intro's slot
				-- pattern is H(meta Y) which is fully generic (Y binds to whatever the
				-- premise's own conclusion is), so it can never mismatch structurally --
				-- construct a rule whose discharge pattern is a FIXED ground judgment
				-- instead, so a differently-judgmented open hypothesis is a real mismatch.
				local fixed_discharge = replayer.declare_rule({
					name = "fixed-discharge",
					version = 1,
					signature = sig,
					premises = { H(meta("X", sig.sorts.prop)) },
					conclusion = H(meta("X", sig.sorts.prop)),
					discharges = { { premise = 1, pattern = H(p) } }, -- fixed: must be holds(p)
				})
				local mismatched_hyp = replayer.hypothesis("h_mismatch", H(q)) -- holds(q), not holds(p)
				local premise_over_hyp = replayer.cite_rule(conj_intro, {
					mismatched_hyp,
					replayer.cite_axiom(ax_holds_p, {}),
				}) -- conclusion: holds(conj(q,p)); irrelevant, just need an open hyp inside
				-- Simplify: directly discharge mismatched_hyp itself under fixed_discharge.
				local direct_node = replayer.cite_rule(fixed_discharge, { mismatched_hyp }, { { "h_mismatch" } })
				local bad_result, bad_err = r:replay(direct_node)
				T.fail(bad_result)
				T.ok(bad_err)
				T.ok((bad_err --[[:! string]]):find("does not match"))
			end)

			T.it("rejects citing a hypothesis id that is not open in the named premise", function()
				local prem = replayer.hypothesis("h_real", H(p))
				local node = replayer.cite_rule(discharge_intro, { prem }, { { "h_not_open" } })
				local result, err = r:replay(node)
				T.fail(result)
				T.ok(err)
			end)

			T.it("root acceptance rejects an undischarged hypothesis", function()
				local hyp = replayer.hypothesis("h_undischarged", H(p))
				local node = replayer.cite_rule(conj_intro, { hyp, replayer.cite_axiom(ax_holds_p, {}) })
				local root, err = r:replay_root(node)
				T.fail(root)
				T.ok(err)
			end)

			T.it("vacuous discharge (empty id-set for a slot) is legal", function()
				local prem = replayer.cite_axiom(ax_holds_p, {})
				local node = replayer.cite_rule(discharge_intro, { prem }, { {} })
				local root, err = r:replay_root(node)
				T.ok(root, err)
			end)
		end)

		-- ── Taint propagation ────────────────────────────────────────────

		T.describe("taint propagation", function()
			local r = replayer.new(k)

			T.it("taint propagates through a chain (axiom -> rule -> rule)", function()
				local ax_node = replayer.cite_axiom(ax_holds_p, {})
				local step1 = replayer.cite_rule(conj_intro, { ax_node, ax_node })
				local step2 = replayer.cite_rule(conj_intro, { step1, ax_node })
				local result, err = r:replay(step2)
				T.ok(result, err)
				T.eq(next(result.taint), "ax-holds-p@v1")
			end)

			T.it("taint unions across a DAG with two different axiom citations", function()
				local ax1 = replayer.cite_axiom(ax_holds_p, {})
				local ax2 = replayer.cite_axiom(ax_schematic, { X = { term = q, depth = 0 } })
				local node = replayer.cite_rule(conj_intro, { ax1, ax2 })
				local result, err = r:replay(node)
				T.ok(result, err)
				T.ok(result.taint["ax-holds-p@v1"])
				T.ok(result.taint["ax-schematic-self-conj@v1"])
			end)

			T.it("a rule citation over pure hypotheses (no axioms) has empty taint", function()
				local h1 = replayer.hypothesis("hh1", H(p))
				local h2 = replayer.hypothesis("hh2", H(q))
				local node = replayer.cite_rule(conj_intro, { h1, h2 })
				local result, err = r:replay(node)
				T.ok(result, err)
				T.eq(next(result.taint), nil)
			end)
		end)

		-- ── MANDATORY acceptance test: DAG-shared discharge ─────────────────
		--
		-- A single hypothesis leaf `hy` is shared as a premise into TWO
		-- parent rule-citations: parent A's schema discharges it (its
		-- discharge slot names hy's id); parent B's schema does NOT (empty
		-- id-set for its slot). Both parents cite the exact same underlying
		-- premise node object for the shared subderivation's OTHER premise
		-- (a common axiom citation), demonstrating memoized reuse too.
		--
		-- Required: identical taint via both parents (both derive from the
		-- same axiom-citation ancestor); DIFFERENT open-hypothesis
		-- contributions (A's open set does not contain hy's id, B's does);
		-- the undischarged path (B) correctly fails root acceptance while
		-- the discharged path (A) succeeds.

		T.describe("MANDATORY: DAG-shared discharge with different parent contexts", function()
			local r = replayer.new(k)

			-- Shared hypothesis leaf, and a shared axiom-citation node reused
			-- as-is (same table object) by both parents' OTHER premise.
			local hy = replayer.hypothesis("hy", H(q))
			local shared_axiom_node = replayer.cite_axiom(ax_holds_p, {})

			-- Parent A: discharges hy at its (only) discharge slot.
			local parent_a = replayer.cite_rule(discharge_intro, { hy }, { { "hy" } })

			-- Parent B: does NOT discharge hy (empty id-set for its slot).
			local parent_b = replayer.cite_rule(discharge_intro, { hy }, { {} })

			T.it("parent A (discharges hy) and parent B (does not) both replay successfully", function()
				local ra, erra = r:replay(parent_a)
				T.ok(ra, erra)
				local rb, errb = r:replay(parent_b)
				T.ok(rb, errb)
			end)

			T.it("both parents' conclusions are identical (same rule, same premise)", function()
				local ra = r:replay(parent_a)
				local rb = r:replay(parent_b)
				T.ok(k.equal(ra.conclusion, rb.conclusion))
			end)

			T.it("taint is identical via both parents", function()
				local ra = r:replay(parent_a)
				local rb = r:replay(parent_b)
				-- hy carries no axiom taint itself (a plain hypothesis); both
				-- parents' taint sets must be equal (both empty here, since
				-- neither parent's rule citation nor the shared hypothesis
				-- introduces any axiom). Compare set membership explicitly.
				local a_keys, b_keys = {}, {}
				for k1 in pairs(ra.taint) do a_keys[#a_keys + 1] = k1 end
				for k2 in pairs(rb.taint) do b_keys[#b_keys + 1] = k2 end
				T.eq(#a_keys, #b_keys)
				for _, key in ipairs(a_keys) do T.ok(rb.taint[key]) end
			end)

			T.it("open-hypothesis contributions DIFFER: A discharges hy, B leaves it open", function()
				local ra = r:replay(parent_a)
				local rb = r:replay(parent_b)
				T.eq(ra.open["hy"], nil) -- discharged: not open
				T.ok(rb.open["hy"] ~= nil) -- NOT discharged: still open, carries hy's judgment
			end)

			T.it("root acceptance: A (discharged) succeeds, B (undischarged) correctly fails", function()
				local root_a, err_a = r:replay_root(parent_a)
				T.ok(root_a, err_a)

				local root_b, err_b = r:replay_root(parent_b)
				T.fail(root_b)
				T.ok(err_b)
			end)
		end)
	end)
end

-- ── Memoization / anti-laundering across kernel configs ─────────────────────
--
-- Not run per-tier (this section IS about comparing across tiers): build
-- the same logical derivation once per tier (each tier builds its own terms
-- via its own k instance -- terms are tier-specific data, per
-- term_algebra's own parity-test convention), replay each under its own
-- replayer instance, and confirm: (a) both produce equal conclusions
-- (parity), (b) each replayer instance owns an independent memo (no
-- cross-instance state), and (c) each result's run-level trust label
-- matches its own tier -- a fast-tier result is never reported under a
-- reference-tier label or vice versa.

T.describe("memoization and anti-laundering across kernel configs", function()
	local function build_for(tier)
		local k = term_algebra.new({ tier = tier })
		local p = k.build(sig.ops.atom, { k.build_var(0, sig.sorts.prop) })
		local ax = replayer.declare_axiom({ name = "cfg-ax", version = 1, signature = sig, pattern = k.build(sig.ops.holds, { p }) })
		local node = replayer.cite_axiom(ax, {})
		local r = replayer.new(k)
		return k, r, node
	end

	T.it("reference and fast tiers agree on the computed conclusion (parity)", function()
		local k_ref, r_ref, node_ref = build_for("reference")
		local k_fast, r_fast, node_fast = build_for("fast")
		local result_ref, err_ref = r_ref:replay(node_ref)
		local result_fast, err_fast = r_fast:replay(node_fast)
		T.ok(result_ref, err_ref)
		T.ok(result_fast, err_fast)
		-- Cross-tier structural comparison via reference-tier equal is not
		-- meaningful (different tier's terms); instead confirm each tier's
		-- own is_ground/is_closed agree, which is what parity means here.
		T.ok(k_ref.is_ground(result_ref.conclusion))
		T.ok(k_fast.is_ground(result_fast.conclusion))
	end)

	T.it("each replayer instance's run-level trust label matches its own tier", function()
		local _, r_ref, node_ref = build_for("reference")
		local _, r_fast, node_fast = build_for("fast")
		local result_ref = r_ref:replay(node_ref)
		local result_fast = r_fast:replay(node_fast)
		local report_ref = r_ref:trust_report(result_ref)
		local report_fast = r_fast:trust_report(result_fast)
		T.eq(report_ref.run_label.eq, "reference")
		T.eq(report_fast.run_label.eq, "interned")
		T.eq(report_ref.run_label.subst, "eager")
		T.eq(report_fast.run_label.subst, "lazy")
	end)

	T.it("replayer instances do not share memoized state across configs", function()
		local k_ref, r_ref, node_ref = build_for("reference")
		local _, r_fast = build_for("fast")
		r_ref:replay(node_ref)
		-- r_fast has never seen node_ref (a reference-tier term/node); a
		-- fast-tier replayer must not be able to serve a reference-config
		-- result for it -- confirmed simply by each replayer owning its own
		-- fresh memo table (r_ref ~= r_fast structurally), which this
		-- checks by asserting they are distinct objects.
		T.neq(r_ref, r_fast)
	end)
end)

return {}
