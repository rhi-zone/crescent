-- lib/type/v10_cleanroom/adjudication_untested_test.lua
-- Closes the differential adjudication's "known gaps in this harness"
-- list (docs/typechecker-v10-parity-adjudication.md, "Known gaps") as
-- required canonical-suite tests, per the canon-swap ratification
-- (docs/decisions/typechecker-v10-core-design.md, "Canon swap"): the
-- adjudicator's untested areas become required additions, not
-- assumed-same. Four areas:
--
--   1. Deep F9 — per-node ground/closed enforcement at NON-leaf,
--      non-root nodes (the adjudication only exercised the leaf/root
--      shapes).
--   2. Broad declare-time validation fuzz — randomized malformed
--      signature/rule/axiom specs (collisions, malformed slots,
--      meta-subset violations) beyond the targeted F6/F11 probes.
--   3. Metavariable-in-subject fuzz — F7's data-error-not-no-match
--      distinction over randomized subjects with metavariables at
--      arbitrary positions, including under binders (the adjudication's
--      fuzzer only ever generated ground subjects).
--   4. An INDEPENDENTLY-DERIVED DAG shared-node divergent-discharge
--      test — built fresh from the design doc's own description ("a
--      shared subderivation has one fixed open set; each parent
--      subtracts within its own computation only; nothing is ever
--      globally marked discharged"), deliberately NOT a restatement of
--      replayer_test.lua's existing worked example (different shape: two
--      distinct same-judgment hypotheses, two parent/grandparent chains
--      discharging them in opposite orders).
--
-- On deep F9 GROUNDNESS (as opposed to closedness): a non-ground interior
-- conclusion is unreachable through the declared-rule path — conclusion
-- patterns may only use premise metavariables (F11), premise conclusions
-- are themselves ground (F9, inductively), axiom bindings must be ground
-- (F12), and instantiate rejects unbound metavariables — so the
-- groundness belt at interior nodes cannot be triggered without bypassing
-- the grammar. This matches the adjudicator's own observation that such a
-- node "did not look constructible"; the closedness half IS constructible
-- (a conclusion pattern carrying a free variable) and is exercised below.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")

--: (v: Signature | nil, err: string | nil) -> Signature
local function must_sig(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Term | nil, err: string | nil) -> Term
local function must_term(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: AxiomDecl | nil, err: string | nil) -> AxiomDecl
local function must_axiom(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: RuleDecl | nil, err: string | nil) -> RuleDecl
local function must_rule(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Replayer | nil, err: string | nil) -> Replayer
local function must_rp(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: ReplayResult | nil, err: string | nil) -> ReplayResult
local function must_res(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Observation | nil, err: string | nil) -> Observation
local function must_obs(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (t: { [string]: unknown }) -> integer
local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

--: (list: CertNode[], x: unknown) -> boolean
local function contains(list, x)
	for i = 1, #list do
		if list[i] == x then return true end
	end
	return false
end

-- ── shared signature ──────────────────────────────────────────────────────────

local sig = must_sig(ta.declare_signature({
	name = "adjudication-gaps",
	version = 1,
	sorts = { "tm", "jdg" },
	ops = {
		c0 = { result = "tm", args = {} },
		c1 = { result = "tm", args = {} },
		g = { result = "tm", args = { { sort = "tm" } } },
		lam = { result = "tm", args = { { sort = "tm", binds = { "tm" } } } },
		hj = { result = "jdg", args = { { sort = "tm" } } },
		ha = { result = "jdg", args = { { sort = "tm" } } },
		both = { result = "jdg", args = { { sort = "tm" } } },
		wrapped = { result = "jdg", args = { { sort = "tm" } } },
		donej = { result = "jdg", args = { { sort = "tm" } } },
	},
}))
local tm = sig.sorts.tm
local ops = sig.ops
local c0 = must_term(ta.build(ops.c0, {}))

--: (id: string) -> Term
local function m(id) return must_term(ta.meta(id, tm)) end
--: (k: integer) -> Term
local function v(k) return must_term(ta.var(k, tm)) end
--: (op: OpDecl, a: Term | nil) -> Term
local function mk(op, a)
	local args = {} --[[: Term[] ]]
	if a ~= nil then args[#args + 1] = a end
	return must_term(ta.build(op, args))
end

-- ── 1. deep F9: per-node closedness at interior (non-leaf, non-root) nodes ────

T.describe("deep F9: interior-node ground/closed enforcement", function()
	local reg = rl.new_registry()
	-- a rule whose conclusion pattern carries a FREE variable: its
	-- instantiated conclusion is non-closed at the node that cites it
	local r_open = must_rule(rl.declare_rule(reg, {
		name = "open-concl", version = 1,
		premises = { mk(ops.hj, m("M")) },
		conclusion = mk(ops.both, v(0)),
	}))
	-- a wrapping rule, so the open-conclusion node sits at an INTERIOR
	-- position of the certificate, not at the root
	local r_wrap = must_rule(rl.declare_rule(reg, {
		name = "wrap", version = 1,
		premises = { mk(ops.both, m("M")) },
		conclusion = mk(ops.wrapped, m("M")),
	}))
	-- positive control: a conclusion pattern whose variable sits UNDER a
	-- binder — closed by construction, must be accepted at every node
	local r_lam = must_rule(rl.declare_rule(reg, {
		name = "lam-concl", version = 1,
		premises = { mk(ops.hj, m("M")) },
		conclusion = mk(ops.hj, mk(ops.lam, v(0))),
	}))
	local r_wrap2 = must_rule(rl.declare_rule(reg, {
		name = "wrap2", version = 1,
		premises = { mk(ops.hj, m("M")) },
		conclusion = mk(ops.wrapped, m("M")),
	}))

	T.it("rejects a non-closed conclusion computed at an interior node (not just leaves/root)", function()
		local rp = must_rp(rl.new_replayer({ registry = reg }))
		local H = { kind = "hypothesis", judgment = mk(ops.hj, c0) } --[[: CertNode ]]
		local interior = { kind = "rule", rule = r_open, premises = { H } } --[[: CertNode ]]
		local root = { kind = "rule", rule = r_wrap, premises = { interior } } --[[: CertNode ]]
		-- observation (no root checks involved) must already fail: the
		-- rejection is per-node (F9 strict), at the interior node itself
		local obs, err = rl.observe(rp, root)
		T.eq(obs, nil)
		T.ok(err and err:find("not closed"), "error should name closedness: " .. tostring(err))
		-- and names the offending rule, locating the interior node
		T.ok(err and err:find("open%-concl"), "error should cite the interior rule: " .. tostring(err))
	end)

	T.it("accepts a variable under a binder in an interior conclusion (closed by construction)", function()
		local rp = must_rp(rl.new_replayer({ registry = reg }))
		local H = { kind = "hypothesis", judgment = mk(ops.hj, c0) } --[[: CertNode ]]
		local interior = { kind = "rule", rule = r_lam, premises = { H } } --[[: CertNode ]]
		local root = { kind = "rule", rule = r_wrap2, premises = { interior } } --[[: CertNode ]]
		local obs = must_obs(rl.observe(rp, root))
		T.ok(ta.equal(obs.conclusion, mk(ops.wrapped, mk(ops.lam, v(0)))))
	end)
end)

-- ── 2. declare-time validation fuzz ───────────────────────────────────────────

T.describe("declare-time validation fuzz (seeded, deterministic)", function()
	-- Deterministic LCG so the fuzz cases are reproducible without
	-- touching the global math.random state.
	local lcg_state = 20260729
	--: (n: integer) -> integer
	local function rnd(n)
		-- Park-Miller: products stay below 2^53, so the arithmetic is
		-- exact in doubles and the sequence is fully reproducible.
		lcg_state = (lcg_state * 16807) % 2147483647
		return (lcg_state % n) + 1
	end

	local SORT_NAMES = { "s1", "s2", "s3" }

	-- dynamic-key write for injecting deliberately-malformed spec entries
	-- the static types (correctly) cannot express
	--: (t: unknown, k: string, val: unknown) -> nil
	local function poke(t, k, val)
		if type(t) == "table" then
			local tt = t --[[: { [string]: unknown } ]]
			tt[k] = val
		end
	end

	-- Build a random WELL-FORMED signature spec (a clean baseline the
	-- defect injectors below then corrupt).
	--: (name: string) -> SignatureSpec
	local function clean_sig_spec(name)
		local ops_spec = {} --[[: { [string]: OpSpec } ]]
		local n_ops = rnd(3)
		for i = 1, n_ops do
			local args = {} --[[: OpArgSpec[] ]]
			local n_args = rnd(3) - 1
			for j = 1, n_args do
				local a = { sort = SORT_NAMES[rnd(#SORT_NAMES)] } --[[: OpArgSpec ]]
				if rnd(3) == 1 then
					a.binds = { SORT_NAMES[rnd(#SORT_NAMES)] }
				end
				args[j] = a
			end
			ops_spec["op" .. i] = { result = SORT_NAMES[rnd(#SORT_NAMES)], args = args }
		end
		return { name = name, version = 1, sorts = { "s1", "s2", "s3" }, ops = ops_spec }
	end

	T.it("every injected signature defect rejects with (nil, errmsg); clean specs accept", function()
		for iter = 1, 60 do
			local spec = clean_sig_spec("fuzz-sig-" .. iter)
			local defect = rnd(5)
			if defect == 1 then
				-- duplicate own sort name (F6)
				spec.sorts[#spec.sorts + 1] = spec.sorts[rnd(#spec.sorts)]
			elseif defect == 2 then
				-- import colliding with an own sort (F6, own-vs-import)
				local src = must_sig(ta.declare_signature({
					name = "fuzz-src-" .. iter, version = 1, sorts = { "s1" }, ops = {},
				}))
				spec.imports = { { from = src, sorts = { "s1" } } }
			elseif defect == 3 then
				-- import-vs-import collision (F6)
				local src1 = must_sig(ta.declare_signature({
					name = "fuzz-srcA-" .. iter, version = 1, sorts = { "shared" }, ops = {},
				}))
				local src2 = must_sig(ta.declare_signature({
					name = "fuzz-srcB-" .. iter, version = 1, sorts = { "shared" }, ops = {},
				}))
				spec.imports = {
					{ from = src1, sorts = { "shared" } },
					{ from = src2, sorts = { "shared" } },
				}
			elseif defect == 4 then
				-- operator citing an unknown sort, at a random position
				local where = rnd(3)
				if where == 1 then
					spec.ops["bad"] = { result = "no-such-sort", args = {} }
				elseif where == 2 then
					spec.ops["bad"] = { result = "s1", args = { { sort = "no-such-sort" } } }
				else
					spec.ops["bad"] = { result = "s1", args = { { sort = "s1", binds = { "no-such-sort" } } } }
				end
			else
				-- malformed op arg entry (missing sort field) — injected
				-- through a dynamic write since the static spec type
				-- (correctly) cannot express it
				poke(spec.ops, "bad", { result = "s1", args = { {} } })
			end
			local got, err = ta.declare_signature(spec)
			T.eq(got, nil, "defect class " .. defect .. " (iter " .. iter .. ") must reject")
			T.ok(type(err) == "string" and err ~= "", "defect must return an errmsg, never throw")

			-- the uncorrupted baseline accepts
			local ok_sig, ok_err = ta.declare_signature(clean_sig_spec("fuzz-ok-" .. iter))
			T.ok(ok_sig, ok_err)
		end
	end)

	T.it("every injected rule/axiom declaration defect rejects; clean declarations accept", function()
		for iter = 1, 60 do
			local reg = rl.new_registry()
			local premises = { mk(ops.hj, m("M")) } --[[: Term[] ]]
			if rnd(2) == 1 then premises[#premises + 1] = mk(ops.ha, m("M")) end
			local defect = rnd(5)
			if defect == 1 then
				-- discharge slot premise index out of range (F11): 0,
				-- negative, or one past the end
				local badidx_pick = rnd(3)
				local badidx = #premises + 1
				if badidx_pick == 2 then badidx = 0 end
				if badidx_pick == 3 then badidx = -rnd(4) end
				local d, err = rl.declare_rule(reg, {
					name = "r" .. iter, version = 1,
					premises = premises,
					conclusion = mk(ops.both, m("M")),
					discharges = { { premise = badidx, hypothesis = mk(ops.hj, m("M")) } },
				})
				T.eq(d, nil)
				T.ok(type(err) == "string" and err:find("out of range"))
			elseif defect == 2 then
				-- conclusion metavariable not in any premise (F11)
				local d, err = rl.declare_rule(reg, {
					name = "r" .. iter, version = 1,
					premises = premises,
					conclusion = mk(ops.both, m("Z" .. iter)),
				})
				T.eq(d, nil)
				T.ok(type(err) == "string" and err:find("does not occur"))
			elseif defect == 3 then
				-- slot-pattern metavariable not in any premise (F11)
				local d, err = rl.declare_rule(reg, {
					name = "r" .. iter, version = 1,
					premises = premises,
					conclusion = mk(ops.both, m("M")),
					discharges = { { premise = 1, hypothesis = mk(ops.hj, m("Q" .. iter)) } },
				})
				T.eq(d, nil)
				T.ok(type(err) == "string" and err:find("does not occur"))
			elseif defect == 4 then
				-- duplicate (name, version) in one registry, across kinds (F11)
				must_axiom(rl.declare_axiom(reg, { name = "dup" .. iter, version = 1, pattern = mk(ops.ha, m("M")) }))
				local d, err = rl.declare_rule(reg, {
					name = "dup" .. iter, version = 1,
					premises = premises,
					conclusion = mk(ops.both, m("M")),
				})
				T.eq(d, nil)
				T.ok(type(err) == "string" and err:find("already declared"))
			else
				-- axiom carrying a discharge form
				local d, err = rl.declare_axiom(reg, {
					name = "ax" .. iter, version = 1,
					pattern = mk(ops.ha, m("M")),
					discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
				})
				T.eq(d, nil)
				T.ok(type(err) == "string" and err:find("no discharge form"))
			end

			-- a clean rule + axiom on the same registry accept
			must_rule(rl.declare_rule(reg, {
				name = "ok-r" .. iter, version = 1,
				premises = premises,
				conclusion = mk(ops.both, m("M")),
				discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
			}))
			must_axiom(rl.declare_axiom(reg, {
				name = "ok-a" .. iter, version = 1, pattern = mk(ops.ha, m("M")),
			}))
		end
	end)
end)

-- ── 3. metavariable-in-subject fuzz (F7) ──────────────────────────────────────

T.describe("metavariable-in-subject fuzz (F7: data error, distinct from no-match)", function()
	local lcg_state = 999001
	--: (n: integer) -> integer
	local function rnd(n)
		-- Park-Miller: products stay below 2^53, so the arithmetic is
		-- exact in doubles and the sequence is fully reproducible.
		lcg_state = (lcg_state * 16807) % 2147483647
		return (lcg_state % n) + 1
	end

	-- Random tm-sorted term up to `depth`, optionally allowing meta nodes
	-- (and var nodes only where a binder scope makes them legal).
	--: (depth: integer, allow_meta: boolean, binders: integer) -> Term
	local function gen(depth, allow_meta, binders)
		local pick = rnd(depth <= 0 and 2 or 5)
		if allow_meta and rnd(4) == 1 then
			return m("F" .. rnd(3))
		end
		if pick == 1 or depth <= 0 then
			return c0
		elseif pick == 2 then
			return mk(ops.c1)
		elseif pick == 3 and binders > 0 then
			return v(rnd(binders) - 1)
		elseif pick == 4 then
			return mk(ops.g, gen(depth - 1, allow_meta, binders))
		else
			-- one binder: metavariables under binders included in the walk
			return mk(ops.lam, gen(depth - 1, allow_meta, binders + 1))
		end
	end

	T.it("any subject containing a metavariable is a data error, never no-match, at any position", function()
		local found_meta_subject = 0
		for _ = 1, 300 do
			local pattern = gen(3, true, 0)
			local subject = gen(3, true, 0)
			if not ta.is_ground(subject) then
				found_meta_subject = found_meta_subject + 1
				local got, err = ta.match(pattern, subject)
				T.eq(got, nil)
				T.ok(type(err) == "string", "match must return an errmsg")
				if type(err) == "string" then
					T.eq(ta.is_no_match(err), false,
						"a metavariable-containing subject is a DATA error, not no-match: " .. err)
				end
			else
				-- ground subject: match may succeed or no-match; it must
				-- never throw, and a failure against a ground subject that
				-- is a genuine mismatch reports through the ordinary
				-- channels
				local got, err = ta.match(pattern, subject)
				if got == nil then
					T.ok(type(err) == "string")
				end
			end
		end
		T.ok(found_meta_subject > 30, "generator must actually produce metavariable-containing subjects")
	end)

	T.it("pattern-is-meta at the exact subject-meta position is still a data error (the A-bug shape)", function()
		-- finding #2's repro shape: f(P) against f(M)
		local pattern = mk(ops.g, m("P"))
		local subject = mk(ops.g, m("M"))
		local got, err = ta.match(pattern, subject)
		T.eq(got, nil)
		T.ok(type(err) == "string" and not ta.is_no_match(err))
	end)

	T.it("a metavariable under a binder in the subject is still a data error", function()
		local pattern = mk(ops.lam, m("P"))
		local subject = mk(ops.lam, m("M"))
		local got, err = ta.match(pattern, subject)
		T.eq(got, nil)
		T.ok(type(err) == "string" and not ta.is_no_match(err))
	end)
end)

-- ── 4. independently-derived DAG shared-node divergent-discharge test ─────────

T.describe("DAG shared node, divergent per-parent discharge contexts (independent derivation)", function()
	-- Derived directly from the design doc's formulation, NOT from the
	-- existing worked example: "a shared subderivation has one fixed open
	-- set; each parent subtracts within its own computation only —
	-- nothing is ever globally marked discharged." Construction: one
	-- shared node S carrying TWO distinct hypotheses (same judgment —
	-- distinct leaf objects, F8) plus one axiom citation; two
	-- parent/grandparent chains discharge the two hypotheses in OPPOSITE
	-- orders; both chains must accept, S's own open set must stay fixed
	-- at both hypotheses throughout, and each intermediate parent's open
	-- set must reflect only ITS OWN subtraction.
	local reg = rl.new_registry()
	local ax = must_axiom(rl.declare_axiom(reg, {
		name = "dag-fact", version = 1, pattern = mk(ops.ha, m("M")),
	}))
	local r_join = must_rule(rl.declare_rule(reg, {
		name = "join3", version = 1,
		premises = { mk(ops.hj, m("M")), mk(ops.hj, m("M")), mk(ops.ha, m("M")) },
		conclusion = mk(ops.both, m("M")),
	}))
	local r_peel1 = must_rule(rl.declare_rule(reg, {
		name = "peel1", version = 1,
		premises = { mk(ops.both, m("M")) },
		conclusion = mk(ops.wrapped, m("M")),
		discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
	}))
	local r_peel2 = must_rule(rl.declare_rule(reg, {
		name = "peel2", version = 1,
		premises = { mk(ops.wrapped, m("M")) },
		conclusion = mk(ops.donej, m("M")),
		discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
	}))

	T.it("both opposite-order discharge chains accept; the shared node's open set never changes", function()
		local rp = must_rp(rl.new_replayer({ registry = reg }))
		local H1 = { kind = "hypothesis", judgment = mk(ops.hj, c0) } --[[: CertNode ]]
		local H2 = { kind = "hypothesis", judgment = mk(ops.hj, c0) } --[[: CertNode ]]
		local S = { kind = "rule", rule = r_join, premises = { H1, H2, { kind = "axiom", axiom = ax, bindings = { M = c0 } } } } --[[: CertNode ]]

		-- chain A discharges H1 first, then H2; chain B the reverse
		local PA = { kind = "rule", rule = r_peel1, premises = { S }, discharge = { [1] = { H1 } } } --[[: CertNode ]]
		local GA = { kind = "rule", rule = r_peel2, premises = { PA }, discharge = { [1] = { H2 } } } --[[: CertNode ]]
		local PB = { kind = "rule", rule = r_peel1, premises = { S }, discharge = { [1] = { H2 } } } --[[: CertNode ]]
		local GB = { kind = "rule", rule = r_peel2, premises = { PB }, discharge = { [1] = { H1 } } } --[[: CertNode ]]

		-- S's fixed open set, observed before any parent replays: exactly
		-- the two distinct leaves (F8: same judgment, two hypotheses)
		local obs_s = must_obs(rl.observe(rp, S))
		T.eq(#obs_s.open, 2)
		T.ok(contains(obs_s.open, H1))
		T.ok(contains(obs_s.open, H2))

		-- both chains accept at their own roots, opposite discharge orders
		local res_a = must_res(rl.replay(rp, GA))
		T.ok(ta.equal(res_a.conclusion, mk(ops.donej, c0)))
		local res_b = must_res(rl.replay(rp, GB))
		T.ok(ta.equal(res_b.conclusion, mk(ops.donej, c0)))

		-- identical taint through both chains: exactly the shared axiom
		T.eq(count(res_a.taint), 1)
		T.eq(count(res_b.taint), 1)
		T.eq(res_a.taint[rl.citation_key("dag-fact", 1)], ax)
		T.eq(res_b.taint[rl.citation_key("dag-fact", 1)], ax)

		-- divergent per-parent discharge status: each intermediate parent
		-- subtracted only what ITS OWN slot named
		local obs_pa = must_obs(rl.observe(rp, PA))
		T.eq(#obs_pa.open, 1)
		T.ok(contains(obs_pa.open, H2))
		T.ok(not contains(obs_pa.open, H1))
		local obs_pb = must_obs(rl.observe(rp, PB))
		T.eq(#obs_pb.open, 1)
		T.ok(contains(obs_pb.open, H1))
		T.ok(not contains(obs_pb.open, H2))

		-- nothing was ever globally marked discharged: after both full
		-- chains replayed, S's own open set is unchanged
		local obs_s_after = must_obs(rl.observe(rp, S))
		T.eq(#obs_s_after.open, 2)
		T.ok(contains(obs_s_after.open, H1))
		T.ok(contains(obs_s_after.open, H2))

		-- and neither parent alone can be a root (its counterpart
		-- hypothesis is genuinely open on that path)
		local root_pa, err_pa = rl.replay(rp, PA)
		T.eq(root_pa, nil)
		T.ok(err_pa and err_pa:find("undischarged"))
	end)
end)
