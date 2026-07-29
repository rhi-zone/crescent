-- lib/type/v10_cleanroom/replayer_test.lua
-- Tests for the cleanroom v10 certificate replayer: every ratified property
-- and failure mode from docs/decisions/typechecker-v10-core-design.md plus
-- the F8..F12 adjudication rulings, including the required shared-node
-- different-discharge-context worked example.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local rl = require("lib.type.v10_cleanroom.replayer")

-- unwrap (value, errmsg) pairs, failing the test on error; typed per
-- result kind (a generic unwrapper infers T | nil and pollutes callers)
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

-- dynamic-key fixture mutation for negative-path tests (a static field
-- write would retroactively pollute the shared record type)
--: (t: unknown, k: string, val: string) -> nil
local function set_field(t, k, val)
	if type(t) == "table" then
		t[k] = val
	end
end

-- dynamic-key read for shape-distinguishability tests (the static types
-- correctly lack each other's fields, so a typed read would not compile)
--: (t: unknown, k: string) -> unknown
local function get_field(t, k)
	if type(t) == "table" then
		local tt = t --[[: { [string]: unknown } ]]
		return tt[k]
	end
	return nil
end

-- ── shared test signature and registry ────────────────────────────────────────

local sig = must_sig(ta.declare_signature({
	name = "replay-test",
	version = 1,
	sorts = { "tm", "jdg" },
	ops = {
		c0 = { result = "tm", args = {} },
		c1 = { result = "tm", args = {} },
		g = { result = "tm", args = { { sort = "tm" } } },
		hj = { result = "jdg", args = { { sort = "tm" } } },
		ha = { result = "jdg", args = { { sort = "tm" } } },
		both = { result = "jdg", args = { { sort = "tm" } } },
		wrapped = { result = "jdg", args = { { sort = "tm" } } },
		closedj = { result = "jdg", args = { { sort = "tm" } } },
		donej = { result = "jdg", args = { { sort = "tm" } } },
	},
}))

local tm = sig.sorts.tm
local ops = sig.ops
local c0 = must_term(ta.build(ops.c0, {}))
local c1 = must_term(ta.build(ops.c1, {}))

--: (k: integer) -> Term
local function v(k) return must_term(ta.var(k, tm)) end
--: (id: string) -> Term
local function m(id) return must_term(ta.meta(id, tm)) end
--: (op: OpDecl, a: Term | nil, b: Term | nil) -> Term
local function mk(op, a, b)
	local args = {} --[[: Term[] ]]
	if a ~= nil then args[#args + 1] = a end
	if b ~= nil then args[#args + 1] = b end
	return must_term(ta.build(op, args))
end

local reg = rl.new_registry()

local ax_fact = must_axiom(rl.declare_axiom(reg, {
	name = "syntax-fact", version = 1, pattern = mk(ops.ha, m("M")),
}))
local ax_ground = must_axiom(rl.declare_axiom(reg, {
	name = "ground-fact", version = 1, pattern = mk(ops.ha, c0),
}))
local r_pair = must_rule(rl.declare_rule(reg, {
	name = "pair", version = 1,
	premises = { mk(ops.hj, m("M")), mk(ops.ha, m("M")) },
	conclusion = mk(ops.both, m("M")),
}))
local r_close = must_rule(rl.declare_rule(reg, {
	name = "close", version = 1,
	premises = { mk(ops.both, m("M")) },
	conclusion = mk(ops.closedj, m("M")),
	discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
}))
local r_wrap = must_rule(rl.declare_rule(reg, {
	name = "wrap", version = 1,
	premises = { mk(ops.both, m("M")) },
	conclusion = mk(ops.wrapped, m("M")),
}))
local r_close2 = must_rule(rl.declare_rule(reg, {
	name = "close2", version = 1,
	premises = { mk(ops.wrapped, m("M")) },
	conclusion = mk(ops.donej, m("M")),
	discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
}))
local r_from_ax = must_rule(rl.declare_rule(reg, {
	name = "from-ax", version = 1,
	premises = { mk(ops.ha, m("M")) },
	conclusion = mk(ops.both, m("M")),
}))
local r_two_ax = must_rule(rl.declare_rule(reg, {
	name = "two-ax", version = 1,
	premises = { mk(ops.ha, m("M")), mk(ops.ha, m("M")) },
	conclusion = mk(ops.both, m("M")),
}))
local r_hyp2 = must_rule(rl.declare_rule(reg, {
	name = "hyp2", version = 1,
	premises = { mk(ops.hj, m("M")), mk(ops.hj, m("M")) },
	conclusion = mk(ops.both, m("M")),
	discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
}))
local r_pair2 = must_rule(rl.declare_rule(reg, {
	name = "pair2", version = 1,
	premises = { mk(ops.hj, m("M1")), mk(ops.ha, m("M2")) },
	conclusion = mk(ops.both, m("M2")),
	discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M2")) } },
}))
local r_open_concl = must_rule(rl.declare_rule(reg, {
	name = "open-concl", version = 1,
	premises = { mk(ops.hj, m("M")) },
	conclusion = mk(ops.both, v(0)),
}))

--: () -> Replayer
local function new_rp()
	return must_rp(rl.new_replayer({ registry = reg }))
end

--: (j: Term) -> CertNode
local function hyp(j) return { kind = "hypothesis", judgment = j } end
--: (decl: AxiomDecl | RuleDecl, bindings: { [string]: Term } | nil) -> CertNode
local function ax(decl, bindings)
	if bindings == nil then
		return { kind = "axiom", axiom = decl }
	end
	return { kind = "axiom", axiom = decl, bindings = bindings }
end
--: (decl: RuleDecl, premises: CertNode[], discharge: { [integer]: CertNode[] } | nil) -> CertNode
local function rule(decl, premises, discharge)
	if discharge == nil then
		return { kind = "rule", rule = decl, premises = premises }
	end
	return { kind = "rule", rule = decl, premises = premises, discharge = discharge }
end

-- count entries of a set-like table
--: (t: { [string]: unknown }) -> integer
local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- true when the replayer's memo (parallel-array association) holds node
--: (rp: Replayer, node: CertNode) -> boolean
local function memo_has(rp, node)
	local memo = rp.cache[rp.config_hash]
	if memo == nil then return false end
	for i = 1, #memo.nodes do
		if memo.nodes[i] == node then return true end
	end
	return false
end

-- ── registry declaration validation ───────────────────────────────────────────

T.describe("registry declaration", function()
	T.it("rejects a duplicate (name, version) in one registry (F11)", function()
		local r2 = rl.new_registry()
		must_axiom(rl.declare_axiom(r2, { name = "a", version = 1, pattern = mk(ops.ha, c0) }))
		local d, err = rl.declare_axiom(r2, { name = "a", version = 1, pattern = mk(ops.ha, c1) })
		T.eq(d, nil)
		T.ok(err:find("already declared", 1, true))
		-- same key across kinds also rejects (one namespace per registry)
		local d2, err2 = rl.declare_rule(r2, {
			name = "a", version = 1, premises = { mk(ops.ha, m("M")) }, conclusion = mk(ops.both, m("M")),
		})
		T.eq(d2, nil)
		T.ok(err2:find("already declared", 1, true))
		-- a different version is a distinct declared object
		T.neq(must_axiom(rl.declare_axiom(r2, { name = "a", version = 2, pattern = mk(ops.ha, c0) })), nil)
	end)

	T.it("axioms admit no discharge form at declaration", function()
		local d, err = rl.declare_axiom(rl.new_registry(), {
			name = "bad", version = 1, pattern = mk(ops.ha, m("M")),
			discharges = { { premise = 1, hypothesis = mk(ops.hj, m("M")) } },
		})
		T.eq(d, nil)
		T.ok(err:find("no discharge form", 1, true))
	end)

	T.it("rejects discharge slot premise index out of range (F11)", function()
		local d, err = rl.declare_rule(rl.new_registry(), {
			name = "bad", version = 1,
			premises = { mk(ops.ha, m("M")) },
			conclusion = mk(ops.both, m("M")),
			discharges = { { premise = 2, hypothesis = mk(ops.hj, m("M")) } },
		})
		T.eq(d, nil)
		T.ok(err:find("out of range", 1, true))
	end)

	T.it("rejects conclusion metavariables not occurring in premises (F11)", function()
		local d, err = rl.declare_rule(rl.new_registry(), {
			name = "bad", version = 1,
			premises = { mk(ops.ha, m("M")) },
			conclusion = mk(ops.both, m("Z")),
		})
		T.eq(d, nil)
		T.ok(err:find("does not occur in any premise", 1, true))
	end)

	T.it("rejects slot-pattern metavariables not occurring in premises (F11)", function()
		local d, err = rl.declare_rule(rl.new_registry(), {
			name = "bad", version = 1,
			premises = { mk(ops.ha, m("M")) },
			conclusion = mk(ops.both, m("M")),
			discharges = { { premise = 1, hypothesis = mk(ops.hj, m("Z")) } },
		})
		T.eq(d, nil)
		T.ok(err:find("does not occur in any premise", 1, true))
	end)

	T.it("traps field addition on registry declarations (immutability fence)", function()
		-- dedicated declarations: the attempted writes must not leak into
		-- the shared registry objects
		local r2 = rl.new_registry()
		local fax = must_axiom(rl.declare_axiom(r2, {
			name = "fz", version = 1, pattern = mk(ops.ha, c0),
		}))
		local frule = must_rule(rl.declare_rule(r2, {
			name = "fz2", version = 1,
			premises = { mk(ops.ha, m("M")) },
			conclusion = mk(ops.both, m("M")),
		}))
		T.throws(function() set_field(fax, "extra", "hacked") end)
		T.throws(function() set_field(frule, "extra", "hacked") end)
	end)
end)

-- ── axiom citation replay ─────────────────────────────────────────────────────

T.describe("axiom citation", function()
	T.it("computes the conclusion by instantiating the declared pattern", function()
		local res = must_res(rl.replay(new_rp(), ax(ax_fact, { M = c0 })))
		T.ok(ta.equal(res.conclusion, mk(ops.ha, c0)))
		T.eq(count(res.taint), 1)
		T.eq(res.taint[rl.citation_key("syntax-fact", 1)], ax_fact)
	end)

	T.it("ground axioms are the zero-metavariable special case", function()
		local res = must_res(rl.replay(new_rp(), ax(ax_ground, nil)))
		T.ok(ta.equal(res.conclusion, mk(ops.ha, c0)))
	end)

	T.it("rejects bindings for metavariables not in the pattern (F12)", function()
		local res, err = rl.replay(new_rp(), ax(ax_fact, { M = c0, Z = c1 }))
		T.eq(res, nil)
		T.ok(err:find("no such metavariable", 1, true))
	end)

	T.it("rejects non-ground bindings (F12)", function()
		local res, err = rl.replay(new_rp(), ax(ax_fact, { M = mk(ops.g, m("X")) }))
		T.eq(res, nil)
		T.ok(err:find("contains a metavariable", 1, true))
	end)

	T.it("rejects non-closed bindings (F12)", function()
		local res, err = rl.replay(new_rp(), ax(ax_fact, { M = v(0) }))
		T.eq(res, nil)
		T.ok(err:find("must be closed", 1, true))
	end)

	T.it("errors on missing bindings (unbound metavariable)", function()
		local res, err = rl.replay(new_rp(), ax(ax_fact, {}))
		T.eq(res, nil)
		T.ok(err:find("unbound metavariable", 1, true))
	end)

	T.it("axiom citations admit no discharge form", function()
		local node = ax(ax_fact, { M = c0 })
		node.discharge = { [1] = {} }
		local res, err = rl.replay(new_rp(), node)
		T.eq(res, nil)
		T.ok(err:find("no discharge form", 1, true))
	end)

	T.it("rejects citations of declarations not in this replayer's registry", function()
		local reg2 = rl.new_registry()
		local foreign = must_axiom(rl.declare_axiom(reg2, {
			name = "foreign", version = 1, pattern = mk(ops.ha, c0),
		}))
		local res, err = rl.replay(new_rp(), ax(foreign, nil))
		T.eq(res, nil)
		T.ok(err:find("not declared in this replayer's registry", 1, true))
	end)

	T.it("rejects a rule cited as an axiom", function()
		local res, err = rl.replay(new_rp(), ax(r_pair, { M = c0 }))
		T.eq(res, nil)
	end)
end)

-- ── hypothesis nodes ──────────────────────────────────────────────────────────

T.describe("hypothesis nodes", function()
	T.it("carry a checked judgment and contribute themselves as open", function()
		-- an undischarged hypothesis alone cannot be a root
		local res, err = rl.replay(new_rp(), hyp(mk(ops.hj, c0)))
		T.eq(res, nil)
		T.ok(err:find("undischarged", 1, true))
	end)

	T.it("rejects judgments containing metavariables (F10)", function()
		local res, err = rl.replay(new_rp(), hyp(mk(ops.hj, m("M"))))
		T.eq(res, nil)
		T.ok(err:find("metavariable", 1, true))
	end)

	T.it("rejects open judgments (F10)", function()
		local res, err = rl.replay(new_rp(), hyp(mk(ops.hj, v(0))))
		T.eq(res, nil)
		T.ok(err:find("closed", 1, true))
	end)
end)

-- ── rule citation replay ──────────────────────────────────────────────────────

T.describe("rule citation", function()
	T.it("computes conclusions bottom-up via shared-environment matching", function()
		local node = rule(r_from_ax, { ax(ax_fact, { M = c1 }) })
		local res = must_res(rl.replay(new_rp(), node))
		T.ok(ta.equal(res.conclusion, mk(ops.both, c1)))
	end)

	T.it("shared metavariables force agreement across premises", function()
		local H = hyp(mk(ops.hj, c0))
		-- agreement success is exercised by the discharge tests below;
		-- here: the shared M forces the premises to agree, so a mismatched
		-- axiom instance rejects
		local bad = rule(r_pair, { H, ax(ax_fact, { M = c1 }) })
		local res, err = rl.replay(new_rp(), bad)
		T.eq(res, nil)
		T.ok(err:find("does not match", 1, true))
	end)

	T.it("rejects premise-count mismatches", function()
		local res, err = rl.replay(new_rp(), rule(r_pair, { ax(ax_fact, { M = c0 }) }))
		T.eq(res, nil)
		T.ok(err:find("expects 2", 1, true))
	end)

	T.it("verifies optional conclusion annotations", function()
		local good = rule(r_from_ax, { ax(ax_fact, { M = c0 }) })
		good.conclusion = mk(ops.both, c0)
		T.ok(ta.equal(must_res(rl.replay(new_rp(), good)).conclusion, mk(ops.both, c0)))
		local bad = rule(r_from_ax, { ax(ax_fact, { M = c0 }) })
		bad.conclusion = mk(ops.both, c1)
		local res, err = rl.replay(new_rp(), bad)
		T.eq(res, nil)
		T.ok(err:find("annotation mismatch", 1, true))
	end)

	T.it("rejects conclusions that are not closed (F9 strict)", function()
		local H = hyp(mk(ops.hj, c0))
		local res, err = rl.replay(new_rp(), rule(r_open_concl, { H }))
		T.eq(res, nil)
		T.ok(err:find("not closed", 1, true))
	end)

	T.it("rejects unknown node kinds and cycles", function()
		local res, err = rl.replay(new_rp(), { kind = "mystery" })
		T.eq(res, nil)
		T.ok(err:find("unknown certificate node kind", 1, true))
		local n = rule(r_from_ax, {})
		n.premises[1] = n
		local res2, err2 = rl.replay(new_rp(), n)
		T.eq(res2, nil)
		T.ok(err2:find("cycle", 1, true))
	end)
end)

-- ── taint ─────────────────────────────────────────────────────────────────────

T.describe("taint", function()
	T.it("propagates bottom-up by union and deduplicates (same axiom twice)", function()
		local node = rule(r_two_ax, { ax(ax_fact, { M = c0 }), ax(ax_fact, { M = c0 }) })
		local res = must_res(rl.replay(new_rp(), node))
		T.eq(count(res.taint), 1)
		T.eq(res.taint[rl.citation_key("syntax-fact", 1)], ax_fact)
	end)

	T.it("unions distinct axioms", function()
		local node = rule(r_two_ax, { ax(ax_fact, { M = c0 }), ax(ax_ground, nil) })
		local res = must_res(rl.replay(new_rp(), node))
		T.eq(count(res.taint), 2)
	end)

	T.it("axiom-free derivations have empty taint", function()
		-- a hypothesis discharged by a rule: no axiom anywhere
		local H = hyp(mk(ops.hj, c0))
		local pair_h = rule(r_hyp2, { H, H }, { [1] = { H } })
		local res = must_res(rl.replay(new_rp(), pair_h))
		T.eq(count(res.taint), 0)
		T.ok(ta.equal(res.conclusion, mk(ops.both, c0)))
	end)
end)

-- ── discharge ─────────────────────────────────────────────────────────────────

T.describe("discharge", function()
	--: () -> (CertNode, CertNode)
	local function open_pair()
		local H = hyp(mk(ops.hj, c0))
		local S = rule(r_pair, { H, ax(ax_fact, { M = c0 }) })
		return H, S
	end

	T.it("explicit id citation closes the named hypothesis", function()
		local H, S = open_pair()
		local res = must_res(rl.replay(new_rp(), rule(r_close, { S }, { [1] = { H } })))
		T.ok(ta.equal(res.conclusion, mk(ops.closedj, c0)))
	end)

	T.it("vacuous discharge is legal; unnamed hypotheses stay open", function()
		local H, S = open_pair()
		local res, err = rl.replay(new_rp(), rule(r_close, { S }, { [1] = {} }))
		T.eq(res, nil)
		T.ok(err:find("undischarged", 1, true)) -- rejected only at the root check
	end)

	T.it("citing a hypothesis not open in the cited premise rejects", function()
		local H = hyp(mk(ops.hj, c0))
		local S2 = rule(r_from_ax, { ax(ax_fact, { M = c0 }) })
		local wrapped = rule(r_wrap, { S2 })
		local res, err = rl.replay(new_rp(), rule(r_close2, { wrapped }, { [1] = { H } }))
		T.eq(res, nil)
		T.ok(err:find("not open in premise", 1, true))
	end)

	T.it("judgment mismatch at discharge rejects", function()
		local H_wrong = hyp(mk(ops.hj, c1))
		local node = rule(r_pair2, { H_wrong, ax(ax_fact, { M = c0 }) }, { [1] = { H_wrong } })
		local res, err = rl.replay(new_rp(), node)
		T.eq(res, nil)
		T.ok(err:find("does not match the slot pattern instance", 1, true))
	end)

	T.it("citing an undeclared slot rejects", function()
		local H, S = open_pair()
		local res, err = rl.replay(new_rp(), rule(r_close, { S }, { [2] = { H } }))
		T.eq(res, nil)
		T.ok(err:find("undeclared slot", 1, true))
	end)

	T.it("two leaves with the same judgment are two hypotheses (F8)", function()
		local H_a = hyp(mk(ops.hj, c0))
		local H_b = hyp(mk(ops.hj, c0))
		-- discharging only H_a leaves H_b open
		local res, err = rl.replay(new_rp(), rule(r_hyp2, { H_a, H_b }, { [1] = { H_a } }))
		T.eq(res, nil)
		T.ok(err:find("undischarged", 1, true))
		-- the shared leaf is ONE hypothesis: discharging it closes everything
		local res2 = must_res(rl.replay(new_rp(), rule(r_hyp2, { H_a, H_a }, { [1] = { H_a } })))
		T.ok(ta.equal(res2.conclusion, mk(ops.both, c0)))
	end)

	T.it("worked example: shared node, two parents, different discharge contexts", function()
		-- shared subderivation S (cites axiom X, uses hypothesis H);
		-- parent P1 discharges H, parent P2 does not; P2's parent G
		-- discharges it later. Identical taint everywhere; different
		-- discharge status per parent; S has ONE fixed open set and is
		-- never globally marked discharged.
		local rp = new_rp()
		local H, S = open_pair()
		local P1 = rule(r_close, { S }, { [1] = { H } })
		local P2 = rule(r_wrap, { S })
		local G = rule(r_close2, { P2 }, { [1] = { H } })
		local res1 = must_res(rl.replay(rp, P1))
		T.ok(ta.equal(res1.conclusion, mk(ops.closedj, c0)))
		-- P2 alone: H still open, so it cannot be a root
		local res2, err2 = rl.replay(rp, P2)
		T.eq(res2, nil)
		T.ok(err2:find("undischarged", 1, true))
		-- but G discharges the same shared H above P2
		local res3 = must_res(rl.replay(rp, G))
		T.ok(ta.equal(res3.conclusion, mk(ops.donej, c0)))
		-- identical taint through both parents
		T.eq(count(res1.taint), 1)
		T.eq(count(res3.taint), 1)
		T.eq(res1.taint[rl.citation_key("syntax-fact", 1)], ax_fact)
		T.eq(res3.taint[rl.citation_key("syntax-fact", 1)], ax_fact)
		-- S was memoized once for the whole run (DAG sharing, no re-replay)
		T.ok(memo_has(rp, S))
	end)
end)

-- ── observation entry point ───────────────────────────────────────────────────

T.describe("observation entry point (read-only, no acceptance)", function()
	--: (v: Observation | nil, err: string | nil) -> Observation
	local function must_obs(v, err)
		if v == nil then error("unexpected error: " .. tostring(err), 2) end
		return v
	end

	T.it("returns the per-node triple for a deliberately-open derivation the strict path rejects", function()
		local rp = new_rp()
		local H = hyp(mk(ops.hj, c0))
		local S = rule(r_pair, { H, ax(ax_fact, { M = c0 }) })
		-- strict acceptance rejects: H is open
		local res, err = rl.replay(rp, S)
		T.eq(res, nil)
		T.ok(err:find("undischarged", 1, true))
		-- observation exposes the same node's computed triple, open set in plain view
		local obs = must_obs(rl.observe(rp, S))
		T.ok(ta.equal(obs.conclusion, mk(ops.both, c0)))
		T.eq(count(obs.taint), 1)
		T.eq(obs.taint[rl.citation_key("syntax-fact", 1)], ax_fact)
		T.eq(#obs.open, 1)
		T.eq(obs.open[1], H)
	end)

	T.it("carries no acceptance signal: shape is structurally distinct from a ReplayResult", function()
		local rp = new_rp()
		local node = rule(r_from_ax, { ax(ax_fact, { M = c0 }) })
		local obs = must_obs(rl.observe(rp, node))
		-- an Observation exposes `open` and has neither trust_label nor
		-- config_hash — a caller probing for a root-strict verdict finds
		-- nil. Probed via a dynamic-key read (get_field): the static
		-- types (correctly) do not carry each other's fields, which is
		-- exactly the structural distinction under test.
		T.neq(get_field(obs, "open"), nil)
		T.eq(get_field(obs, "trust_label"), nil)
		T.eq(get_field(obs, "config_hash"), nil)
		-- the strict path's result is the inverse shape
		local res = must_res(rl.replay(rp, node))
		T.eq(get_field(res, "open"), nil)
		T.neq(get_field(res, "trust_label"), nil)
	end)

	T.it("shares the strict path's memoized computation and config-keyed cache", function()
		local rp = new_rp()
		local H = hyp(mk(ops.hj, c0))
		local S = rule(r_pair, { H, ax(ax_fact, { M = c0 }) })
		must_obs(rl.observe(rp, S))
		T.ok(memo_has(rp, S))
		T.eq(count(rp.cache), 1)
		-- a later strict replay of a discharging parent reuses S's memo entry
		local P = rule(r_close, { S }, { [1] = { H } })
		local res = must_res(rl.replay(rp, P))
		T.ok(ta.equal(res.conclusion, mk(ops.closedj, c0)))
	end)

	T.it("per-node data errors still reject: observation relaxes only the root check", function()
		local rp = new_rp()
		-- F10: hypothesis judgment with a metavariable
		local obs, err = rl.observe(rp, hyp(mk(ops.hj, m("M"))))
		T.eq(obs, nil)
		T.ok(err:find("metavariable", 1, true))
		-- F9 strict: non-closed interior conclusion
		local H = hyp(mk(ops.hj, c0))
		local obs2, err2 = rl.observe(rp, rule(r_open_concl, { H }))
		T.eq(obs2, nil)
		T.ok(err2:find("not closed", 1, true))
		-- cycles
		local n = rule(r_from_ax, {})
		n.premises[1] = n
		local obs3, err3 = rl.observe(rp, n)
		T.eq(obs3, nil)
		T.ok(err3:find("cycle", 1, true))
	end)
end)

-- ── kernel config / run-level trust label ─────────────────────────────────────

T.describe("kernel config and trust label", function()
	T.it("the reference config carries an empty kernel-axiom label", function()
		local rp = new_rp()
		T.eq(#rp.trust_label, 0)
		local res = must_res(rl.replay(rp, rule(r_from_ax, { ax(ax_fact, { M = c0 }) })))
		T.eq(#res.trust_label, 0)
		T.eq(res.config_hash, rp.config_hash)
	end)

	T.it("rejects kernel tiers not available in the reference build", function()
		local rp, err = rl.new_replayer({ registry = reg, config = { eq = "interned", subst = "eager" } })
		T.eq(rp, nil)
		T.ok(err:find("not available", 1, true))
		local rp2, err2 = rl.new_replayer({ registry = reg, config = { eq = "reference", subst = "lazy" } })
		T.eq(rp2, nil)
		T.ok(err2:find("not available", 1, true))
	end)

	T.it("memo caches are keyed by config hash (anti-laundering)", function()
		local rp = new_rp()
		local node = rule(r_from_ax, { ax(ax_fact, { M = c0 }) })
		must_res(rl.replay(rp, node))
		T.neq(rp.cache[rp.config_hash], nil)
		T.ok(memo_has(rp, node))
		-- nothing is cached under any other key
		T.eq(count(rp.cache), 1)
	end)

	T.it("effective axiom set = node taint union run label", function()
		local rp = new_rp()
		local res = must_res(rl.replay(rp, rule(r_from_ax, { ax(ax_fact, { M = c0 }) })))
		local eff = rl.effective_axiom_set(res)
		T.eq(count(eff), 1)
		T.ok(eff[rl.citation_key("syntax-fact", 1)])
	end)
end)
