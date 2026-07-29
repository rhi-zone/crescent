-- lib/type/v10_cleanroom/term_algebra_test.lua
-- Tests for the cleanroom v10 term algebra reference tier: every ratified
-- property and failure mode from docs/decisions/typechecker-v10-core-design.md
-- plus the F1..F13 adjudication rulings.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")

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

--: (v: Bindings | nil, err: string | nil) -> Bindings
local function must_bindings(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: boolean | nil, err: string | nil) -> boolean
local function must_ok(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

-- dynamic-key fixture mutation for negative-path tests (a static field
-- write would retroactively pollute the shared record type); val = nil
-- removes the field
--: (t: unknown, k: string, val: string | nil) -> nil
local function set_field(t, k, val)
	if type(t) == "table" then
		t[k] = val
	end
end

-- ── shared test signature ─────────────────────────────────────────────────────

local sig_v, sig_err = ta.declare_signature({
	name = "ta-test",
	version = 1,
	sorts = { "tm", "jdg" },
	ops = {
		c0 = { result = "tm", args = {} },
		c1 = { result = "tm", args = {} },
		f = { result = "tm", args = { { sort = "tm" }, { sort = "tm" } } },
		g = { result = "tm", args = { { sort = "tm" } } },
		lam = { result = "tm", args = { { sort = "tm", binds = { "tm" } } } },
		hj = { result = "jdg", args = { { sort = "tm" } } },
		pairj = { result = "jdg", args = { { sort = "tm" }, { sort = "tm" } } },
		bindfst = { result = "jdg", args = { { sort = "tm", binds = { "tm" } }, { sort = "tm" } } },
	},
})
local sig = must_sig(sig_v, sig_err)

local tm = sig.sorts.tm
local jdg = sig.sorts.jdg
local ops = sig.ops

local c0 = must_term(ta.build(ops.c0, {}))
local c1 = must_term(ta.build(ops.c1, {}))

--: (k: integer, s: Sort | nil) -> Term
local function v(k, s) return must_term(ta.var(k, s or tm)) end
--: (op: OpDecl, a: Term | nil, b: Term | nil) -> Term
local function mk(op, a, b)
	local args = {} --[[: Term[] ]]
	if a ~= nil then args[#args + 1] = a end
	if b ~= nil then args[#args + 1] = b end
	return must_term(ta.build(op, args))
end
--: (id: string, s: Sort | nil) -> Term
local function m(id, s) return must_term(ta.meta(id, s or tm)) end

-- ── signature declaration ─────────────────────────────────────────────────────

T.describe("declare_signature", function()
	T.it("validates and rejects unknown sorts in ops", function()
		local s, err = ta.declare_signature({
			name = "bad", version = 1, sorts = { "a" },
			ops = { k = { result = "nope", args = {} } },
		})
		T.eq(s, nil)
		T.ok(err:find("unknown sort", 1, true))
	end)

	T.it("rejects duplicate sort names (F6)", function()
		local s, err = ta.declare_signature({
			name = "bad", version = 1, sorts = { "a", "a" }, ops = {},
		})
		T.eq(s, nil)
		T.ok(err:find("duplicate sort name", 1, true))
	end)

	T.it("rejects own-vs-import sort name collision (F6)", function()
		local s, err = ta.declare_signature({
			name = "bad", version = 1, sorts = { "tm" },
			imports = { { from = sig, sorts = { "tm" } } },
			ops = {},
		})
		T.eq(s, nil)
		T.ok(err:find("collision", 1, true))
	end)

	T.it("rejects import-vs-import sort name collision (F6)", function()
		local other = must_sig(ta.declare_signature({
			name = "other", version = 1, sorts = { "tm" }, ops = {},
		}))
		local s, err = ta.declare_signature({
			name = "bad", version = 1, sorts = {},
			imports = { { from = sig, sorts = { "tm" } }, { from = other, sorts = { "tm" } } },
			ops = {},
		})
		T.eq(s, nil)
		T.ok(err:find("collision", 1, true))
	end)

	T.it("rejects unresolvable imports", function()
		local s, err = ta.declare_signature({
			name = "bad", version = 1, sorts = {},
			imports = { { from = sig, sorts = { "no_such_sort" } } },
			ops = {},
		})
		T.eq(s, nil)
		T.ok(err:find("unresolvable import", 1, true))
	end)

	T.it("rejects malformed valences", function()
		local s, err = ta.declare_signature({
			name = "bad", version = 1, sorts = { "a" },
			ops = { k = { result = "a", args = { { sort = "a", binds = { "zzz" } } } } },
		})
		T.eq(s, nil)
		T.ok(err:find("valence cites unknown sort", 1, true))
	end)

	T.it("requires an explicit args list", function()
		local spec = {
			name = "bad", version = 1, sorts = { "a" },
			ops = { k = { result = "a", args = {} } },
		}
		set_field(spec.ops.k, "args", nil)
		local s, err = ta.declare_signature(spec)
		T.eq(s, nil)
		T.ok(err:find("args list", 1, true))
	end)

	T.it("traps field addition on declaration objects (immutability fence)", function()
		-- existing-field writes cannot be trapped in plain Lua 5.1 tables
		-- (out-of-contract); new-key addition is trapped. Uses a dedicated
		-- signature: the attempted writes must not leak into shared values.
		local fsig = must_sig(ta.declare_signature({
			name = "frozen", version = 1, sorts = { "s" },
			ops = { c = { result = "s", args = { { sort = "s", binds = { "s" } } } } },
		}))
		T.throws(function() set_field(fsig, "extra", "hacked") end)
		T.throws(function() set_field(fsig.sorts.s, "extra", "hacked") end)
		T.throws(function() set_field(fsig.ops.c, "extra", "hacked") end)
		T.throws(function() set_field(fsig.ops.c.args[1], "extra", "hacked") end)
	end)

	T.it("allows imported sorts in result position (F6)", function()
		local s = must_sig(ta.declare_signature({
			name = "resimp", version = 1, sorts = {},
			imports = { { from = sig, sorts = { "tm" } } },
			ops = { mkc = { result = "tm", args = {} } },
		}))
		T.eq(s.ops.mkc.result, tm)
	end)
end)

T.describe("sort identity", function()
	T.it("same-named sorts in different signatures are not interchangeable", function()
		local sig2 = must_sig(ta.declare_signature({
			name = "other-th", version = 1, sorts = { "tm" },
			ops = { c = { result = "tm", args = {} } },
		}))
		T.neq(sig2.sorts.tm, tm)
		local foreign = must_term(ta.build(sig2.ops.c, {}))
		-- a term of the OTHER signature's same-named sort is ill-sorted here
		local t, err = ta.build(ops.g, { foreign })
		T.eq(t, nil)
		T.ok(err:find("sort mismatch", 1, true))
	end)

	T.it("imported sorts are the same declared object (import identity)", function()
		local sig3 = must_sig(ta.declare_signature({
			name = "importer", version = 1, sorts = {},
			imports = { { from = sig, sorts = { "tm" } } },
			ops = { wrap = { result = "tm", args = { { sort = "tm" } } } },
		}))
		T.eq(sig3.sorts.tm, tm)
		-- terms built from the exporting signature are legal arguments
		local t = must_term(ta.build(sig3.ops.wrap, { c0 }))
		T.eq(ta.sort_of(t), tm)
	end)

	T.it("distinct declarations of the same spec are distinct identities", function()
		local a = must_sig(ta.declare_signature({ name = "twin", version = 1, sorts = { "s" }, ops = {} }))
		local b = must_sig(ta.declare_signature({ name = "twin", version = 1, sorts = { "s" }, ops = {} }))
		T.neq(a.sorts.s, b.sorts.s)
	end)
end)

-- ── build ─────────────────────────────────────────────────────────────────────

T.describe("build (sole constructor)", function()
	T.it("checks arity", function()
		local t, err = ta.build(ops.f, { c0 })
		T.eq(t, nil)
		T.ok(err:find("expects 2", 1, true))
	end)

	T.it("checks argument sorts", function()
		local j = mk(ops.hj, c0)
		local t, err = ta.build(ops.g, { j })
		T.eq(t, nil)
		T.ok(err:find("sort mismatch", 1, true))
	end)

	T.it("stamps bound_count from the decl", function()
		local targs = mk(ops.lam, v(0)).args
		T.neq(targs, nil)
		if targs ~= nil then T.eq(targs[1].bound_count, 1) end
		local uargs = mk(ops.g, c0).args
		T.neq(uargs, nil)
		if uargs ~= nil then T.eq(uargs[1].bound_count, 0) end
	end)

	T.it("discharges matched binder indices from the context", function()
		local t = mk(ops.lam, v(0))
		T.ok(ta.is_closed(t))
	end)

	T.it("shifts the remainder of the context down by the valence", function()
		local t = mk(ops.lam, v(1))
		T.fail(ta.is_closed(t))
		T.eq(t.ctx[0], tm)
		T.eq(t.ctx[1], nil)
	end)

	T.it("rejects binder sort mismatches via the cached context", function()
		local sig2 = must_sig(ta.declare_signature({
			name = "two-sorted", version = 1, sorts = { "a", "b" },
			ops = {
				bindb = { result = "a", args = { { sort = "a", binds = { "b" } } } },
			},
		}))
		local a = sig2.sorts.a
		local t, err = ta.build(sig2.ops.bindb, { v(0, a) })
		T.eq(t, nil)
		T.ok(err:find("binder index 0 sort mismatch", 1, true))
	end)

	T.it("maps binds list positions to indices in order (F1)", function()
		local sig2 = must_sig(ta.declare_signature({
			name = "order", version = 1, sorts = { "a", "b" },
			ops = {
				bind2 = { result = "a", args = { { sort = "a", binds = { "a", "b" } } } },
				wrapb = { result = "a", args = { { sort = "b" } } },
			},
		}))
		local a, b = sig2.sorts.a, sig2.sorts.b
		-- index 0 must be sort a (binds[1]); index 1 must be sort b (binds[2])
		local body_ok = must_term(ta.build(sig2.ops.wrapb, { v(1, b) }))
		T.eq(body_ok.ctx[1], b)
		-- v(0, a) at index 0: fine; wrapb(v(1,b)) carries {1 -> b}: fine
		local body2 = must_term(ta.build(sig2.ops.bind2, { body_ok }))
		T.ok(ta.is_closed(body2))
		-- reversed sorts must reject
		local bad, err = ta.build(sig2.ops.bind2, { must_term(ta.build(sig2.ops.wrapb, { v(0, b) })) })
		T.eq(bad, nil)
		T.ok(err:find("binder index 0 sort mismatch", 1, true))
	end)

	T.it("merges free-variable contexts with a same-index-same-sort check", function()
		local sig2 = must_sig(ta.declare_signature({
			name = "merge", version = 1, sorts = { "a", "b" },
			ops = {
				mixed = { result = "a", args = { { sort = "a" }, { sort = "b" } } },
			},
		}))
		local a, b = sig2.sorts.a, sig2.sorts.b
		local t, err = ta.build(sig2.ops.mixed, { v(0, a), v(0, b) })
		T.eq(t, nil)
		T.ok(err:find("conflicting sorts", 1, true))
		local u = must_term(ta.build(sig2.ops.mixed, { v(0, a), v(1, b) }))
		T.eq(u.ctx[0], a)
		T.eq(u.ctx[1], b)
	end)

	T.it("rejects the same metavariable id with two different sorts (F13)", function()
		local t, err = ta.build(ops.bindfst, { m("M", tm), m("M", tm) })
		T.neq(t, nil)
		local bad, err2 = ta.build(ops.pairj, { m("X", tm), mk(ops.g, m("X", tm)) })
		T.neq(bad, nil)
		-- different sorts for the same id must reject: use jdg-sorted meta via hj arg
		local sigm = must_sig(ta.declare_signature({
			name = "msorts", version = 1, sorts = { "a", "b" },
			ops = { two = { result = "a", args = { { sort = "a" }, { sort = "b" } } } },
		}))
		local bad2, err3 = ta.build(sigm.ops.two, { m("Y", sigm.sorts.a), m("Y", sigm.sorts.b) })
		T.eq(bad2, nil)
		T.ok(err3:find("two different sorts", 1, true))
	end)
end)

-- ── equal ─────────────────────────────────────────────────────────────────────

T.describe("equal (reference structural equality)", function()
	T.it("distinguishes distinct constants and equates equal structures", function()
		T.ok(ta.equal(c0, must_term(ta.build(ops.c0, {}))))
		T.fail(ta.equal(c0, c1))
		T.ok(ta.equal(mk(ops.f, c0, c1), mk(ops.f, c0, c1)))
		T.fail(ta.equal(mk(ops.f, c0, c1), mk(ops.f, c1, c0)))
	end)

	T.it("compares variables by index and sort identity", function()
		T.ok(ta.equal(v(2), v(2)))
		T.fail(ta.equal(v(2), v(3)))
		T.fail(ta.equal(v(0, tm), v(0, jdg)))
	end)

	T.it("compares metavariables by id and sort", function()
		T.ok(ta.equal(m("M"), m("M")))
		T.fail(ta.equal(m("M"), m("N")))
		T.fail(ta.equal(m("M", tm), m("M", jdg)))
	end)

	T.it("compares operators by declared-object identity, not name", function()
		local sig2 = must_sig(ta.declare_signature({
			name = "eqtwin", version = 1, sorts = { "tm" },
			ops = { c0 = { result = "tm", args = {} } },
		}))
		local foreign_c0 = must_term(ta.build(sig2.ops.c0, {}))
		T.fail(ta.equal(c0, foreign_c0))
	end)
end)

-- ── shift ─────────────────────────────────────────────────────────────────────

T.describe("shift", function()
	T.it("shifts free indices at or above the cutoff", function()
		local t = mk(ops.f, v(0), v(2))
		local s = must_term(ta.shift(t, 3, 1))
		T.eq(s.ctx[0], tm)
		T.eq(s.ctx[5], tm)
		T.eq(s.ctx[2], nil)
	end)

	T.it("respects binders (cutoff advances by bound_count)", function()
		local t = mk(ops.lam, v(1)) -- lam(<x> free-0)
		local s = must_term(ta.shift(t, 2, 0))
		T.eq(s.ctx[2], tm)
		T.eq(s.ctx[0], nil)
	end)

	T.it("accepts negative amounts (F4)", function()
		local t = v(3)
		local s = must_term(ta.shift(t, -2, 0))
		T.eq(s.ctx[1], tm)
	end)

	T.it("underflow below the cutoff is a data error (F4)", function()
		local t, err = ta.shift(v(0), -1, 0)
		T.eq(t, nil)
		T.ok(err:find("underflow", 1, true))
		local t2, err2 = ta.shift(v(1), -1, 1)
		T.eq(t2, nil)
		T.ok(err2:find("underflow", 1, true))
	end)

	T.it("leaves metavariables untouched", function()
		local p = mk(ops.g, m("M"))
		local s = must_term(ta.shift(p, 5, 0))
		T.ok(ta.equal(p, s))
	end)
end)

-- ── subst ─────────────────────────────────────────────────────────────────────

T.describe("subst (eager reference substitution)", function()
	T.it("replaces the target variable", function()
		local t = mk(ops.g, v(0))
		local s = must_term(ta.subst(t, 0, c0))
		T.ok(ta.equal(s, mk(ops.g, c0)))
	end)

	T.it("does not renumber indices above k (F2)", function()
		local t = mk(ops.f, v(0), v(2))
		local s = must_term(ta.subst(t, 0, c0))
		T.ok(ta.equal(s, mk(ops.f, c0, v(2))))
		T.eq(s.ctx[2], tm)
		T.eq(s.ctx[1], nil)
	end)

	T.it("is a no-op success when k is not free in t (F3)", function()
		local t = mk(ops.g, v(1))
		local s = must_term(ta.subst(t, 0, c0))
		T.eq(s, t)
		-- no sort check on the no-op path (F3): jdg-sorted replacement accepted
		local j = mk(ops.hj, c0)
		local s2 = must_term(ta.subst(t, 0, j))
		T.eq(s2, t)
	end)

	T.it("is sort-safe when k is free", function()
		local t = mk(ops.g, v(0))
		local j = mk(ops.hj, c0)
		local s, err = ta.subst(t, 0, j)
		T.eq(s, nil)
		T.ok(err:find("sort mismatch", 1, true))
	end)

	T.it("substitutes under binders with a shift (capture-avoiding)", function()
		-- lam(<x> free-0) with free-0 := c0
		local t = mk(ops.lam, v(1))
		local s = must_term(ta.subst(t, 0, c0))
		T.ok(ta.equal(s, mk(ops.lam, c0)))
		-- replacement's own free variables keep referring outward:
		-- lam(<x> free-0) with free-0 := var(0) gives lam(<x> var(1))
		local s2 = must_term(ta.subst(t, 0, v(0)))
		T.ok(ta.equal(s2, mk(ops.lam, v(1))))
		T.eq(s2.ctx[0], tm)
	end)

	T.it("leaves bound variables alone", function()
		local t = mk(ops.lam, v(0))
		local s = must_term(ta.subst(t, 0, c0))
		T.eq(s, t) -- closed: no-op
	end)
end)

-- ── match / instantiate ───────────────────────────────────────────────────────

T.describe("match", function()
	T.it("matches structurally and binds metavariables", function()
		local p = mk(ops.f, m("A"), m("B"))
		local t = mk(ops.f, c0, c1)
		local b = must_bindings(ta.match(p, t))
		T.ok(ta.equal(b.A.term, c0))
		T.eq(b.A.depth, 0)
		T.ok(ta.equal(b.B.term, c1))
	end)

	T.it("no-match on operator mismatch, distinguishable via is_no_match", function()
		local b, err = ta.match(mk(ops.g, m("A")), c0)
		T.eq(b, nil)
		T.ok(ta.is_no_match(err))
	end)

	T.it("checks the metavariable sort at bind time (F13)", function()
		local b, err = ta.match(m("J", jdg), c0)
		T.eq(b, nil)
		T.ok(ta.is_no_match(err))
		T.ok(err:find("sort", 1, true))
	end)

	T.it("a metavariable in the subject is a data error, not no-match (F7)", function()
		local b, err = ta.match(m("A"), mk(ops.g, m("X")))
		T.eq(b, nil)
		T.fail(ta.is_no_match(err))
		T.ok(err:find("subject term contains a metavariable", 1, true))
	end)

	T.it("non-linear patterns check later occurrences with equal", function()
		local p = mk(ops.f, m("A"), m("A"))
		T.neq(must_bindings(ta.match(p, mk(ops.f, c0, c0))), nil)
		local b, err = ta.match(p, mk(ops.f, c0, c1))
		T.eq(b, nil)
		T.ok(ta.is_no_match(err))
	end)

	T.it("binds under binders at the crossing depth", function()
		local p = mk(ops.lam, mk(ops.g, m("A")))
		local t = mk(ops.lam, mk(ops.g, v(0)))
		local b = must_bindings(ta.match(p, t))
		T.eq(b.A.depth, 1)
		T.ok(ta.equal(b.A.term, v(0)))
	end)

	T.it("shift-adjusts non-linear recurrences across depths (deeper later)", function()
		-- pattern: pairj(M, lam-like binder over M) via bindfst(<x> M, M)
		-- pre-order: first occurrence inside the binder (depth 1), then depth 0
		local p = mk(ops.bindfst, m("M"), m("M"))
		-- subject: bindfst(<x> shift(t0,1), t0) with t0 = g(c0)
		local t0 = mk(ops.g, c0)
		local subject = mk(ops.bindfst, must_term(ta.shift(t0, 1, 0)), t0)
		local b = must_bindings(ta.match(p, subject))
		T.eq(b.M.depth, 1)
		T.ok(ta.equal(b.M.term, t0)) -- t0 closed: shift is identity
	end)

	T.it("cross-depth recurrence referencing the intervening binder fails naturally", function()
		local p = mk(ops.bindfst, m("M"), m("M"))
		-- first occurrence binds var(0) (the bound variable) at depth 1;
		-- recurrence at depth 0 needs shift(var(0), -1): underflow = no-match (F4)
		local subject = mk(ops.bindfst, v(0), c0)
		local b, err = ta.match(p, subject)
		T.eq(b, nil)
		T.ok(ta.is_no_match(err))
	end)

	T.it("cross-depth recurrence agreeing up to shift succeeds with free vars", function()
		-- subject: bindfst(<x> var(1), var(0)) — the same OUTER variable seen
		-- at both depths
		local subject = mk(ops.bindfst, v(1), v(0))
		local p = mk(ops.bindfst, m("M"), m("M"))
		local b = must_bindings(ta.match(p, subject))
		T.eq(b.M.depth, 1)
		T.ok(ta.equal(b.M.term, v(1)))
	end)

	T.it("match_into accumulates a shared environment across calls", function()
		local b = {}
		T.ok(must_ok(ta.match_into(mk(ops.hj, m("M")), mk(ops.hj, c0), b)))
		local ok, err = ta.match_into(mk(ops.hj, m("M")), mk(ops.hj, c1), b)
		T.eq(ok, nil)
		T.ok(ta.is_no_match(err))
	end)
end)

T.describe("instantiate", function()
	T.it("is the exact inverse of match", function()
		local p = mk(ops.bindfst, mk(ops.f, m("M"), v(0)), m("M"))
		local t0 = mk(ops.g, c1)
		local subject = mk(ops.bindfst, mk(ops.f, must_term(ta.shift(t0, 1, 0)), v(0)), t0)
		local b = must_bindings(ta.match(p, subject))
		local r = must_term(ta.instantiate(p, b))
		T.ok(ta.equal(r, subject))
	end)

	T.it("errors on unbound metavariables", function()
		local r, err = ta.instantiate(mk(ops.g, m("Z")), {})
		T.eq(r, nil)
		T.ok(err:find("unbound metavariable", 1, true))
	end)

	T.it("rejects mis-sorted bindings (F13)", function()
		local r, err = ta.instantiate(mk(ops.g, m("M")), {
			M = { term = mk(ops.hj, c0), depth = 0 },
		})
		T.eq(r, nil)
		T.ok(err:find("sort", 1, true))
	end)

	T.it("shifts bindings by occurrence depth minus binding depth", function()
		local p = mk(ops.bindfst, m("M"), m("N"))
		local r = must_term(ta.instantiate(p, {
			M = { term = v(0), depth = 0 }, -- occurrence at depth 1: becomes var(1)
			N = { term = v(0), depth = 0 },
		}))
		T.ok(ta.equal(r, mk(ops.bindfst, v(1), v(0))))
	end)

	T.it("underflow during instantiation is a data error", function()
		local p = mk(ops.g, m("M"))
		local r, err = ta.instantiate(p, { M = { term = v(0), depth = 1 } })
		T.eq(r, nil)
		T.ok(err:find("underflow", 1, true))
	end)
end)

-- ── is_ground / is_closed / sort_of ───────────────────────────────────────────

T.describe("ground, closed, sort_of", function()
	T.it("is_ground reflects metavariable presence", function()
		T.ok(ta.is_ground(c0))
		T.fail(ta.is_ground(mk(ops.g, m("M"))))
	end)

	T.it("is_closed is O(1) over the cached context", function()
		T.ok(ta.is_closed(c0))
		T.fail(ta.is_closed(v(0)))
		T.ok(ta.is_closed(mk(ops.lam, v(0))))
	end)

	T.it("sort_of is stored at build", function()
		T.eq(ta.sort_of(c0), tm)
		T.eq(ta.sort_of(mk(ops.hj, c0)), jdg)
		T.eq(ta.sort_of(v(4)), tm)
		T.eq(ta.sort_of(m("M", jdg)), jdg)
	end)
end)
