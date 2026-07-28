-- lib/type/v10_kernel/term_algebra/term_algebra_test.lua
--
-- Unit tests for every primitive (build/build_var/build_meta, equal, shift,
-- subst, match, instantiate, is_ground, is_closed, sort_of), including de
-- Bruijn edge cases, run against BOTH tiers (the same test bodies, since
-- both tiers must agree on every result — parity for the specific cases
-- here; broader parity + fuzzing lives in term_algebra_parity_test.lua).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local kernel = require("lib.type.v10_kernel.term_algebra")

-- ── Test signature ────────────────────────────────────────────────────────
--
-- A small vocabulary exercising binders of varying valence, non-binding
-- multi-arg operators, and a two-variable-binding operator:
--   zero          : term                              (nullary constant)
--   succ(t)       : term  <- term                      (unary, non-binding)
--   app(f, x)     : term  <- term, term                (binary, non-binding)
--   lam(body)     : term  <- term, binds [term]         (one-var binder)
--   pair2(body)   : term  <- term, binds [term, term]   (two-var binder)

local sig, sig_err = kernel.declare_signature({
	name = "test-theory",
	version = 1,
	sorts = { "term" },
	ops = {
		zero = { result = "term", args = {} },
		succ = { result = "term", args = { { sort = "term" } } },
		app = { result = "term", args = { { sort = "term" }, { sort = "term" } } },
		lam = { result = "term", args = { { sort = "term", binds = { "term" } } } },
		pair2 = { result = "term", args = { { sort = "term", binds = { "term", "term" } } } },
	},
})
T.it("declare_signature succeeds for the test vocabulary", function()
	T.ok(sig, sig_err)
end)

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe(tier .. " tier", function()
		local k = kernel.new({ tier = tier })

		T.it("tier/trust_label are reported", function()
			T.eq(k.tier, tier)
			T.ok(k.trust_label)
			T.ok(k.trust_label.eq)
			T.ok(k.trust_label.subst)
		end)

		-- ── build / build_var / build_meta ────────────────────────────────

		T.describe("build_var", function()
			T.it("builds a var with its sort", function()
				local v = k.build_var(0, sig.sorts.term)
				T.ok(v)
				T.eq(k.sort_of(v), sig.sorts.term)
			end)
			T.it("rejects a negative index", function()
				local v, err = k.build_var(-1, sig.sorts.term)
				T.eq(v, nil)
				T.ok(err)
			end)
			T.it("rejects a non-integer index", function()
				local v, err = k.build_var(1.5, sig.sorts.term)
				T.eq(v, nil)
				T.ok(err)
			end)
		end)

		T.describe("build_meta", function()
			T.it("builds a meta with its sort", function()
				local m = k.build_meta("M", sig.sorts.term)
				T.ok(m)
				T.eq(k.sort_of(m), sig.sorts.term)
			end)
			T.it("is not ground", function()
				local m = k.build_meta("M", sig.sorts.term)
				T.fail(k.is_ground(m))
			end)
		end)

		T.describe("build (op)", function()
			T.it("builds a nullary op", function()
				local z = k.build(sig.ops.zero, {})
				T.ok(z)
				T.eq(k.sort_of(z), sig.sorts.term)
			end)
			T.it("rejects wrong arity", function()
				local v0 = k.build_var(0, sig.sorts.term)
				local bad, err = k.build(sig.ops.zero, { v0 })
				T.eq(bad, nil)
				T.ok(err)
			end)
			T.it("rejects wrong argument sort", function()
				-- succ's argument must be sort "term"; there is no other
				-- sort in this signature, so exercise via a malformed decl
				-- shape instead: passing a term whose sort_of would need to
				-- differ — build a second signature with a distinct sort.
				local sig2 = kernel.declare_signature({
					name = "two-sorts", version = 1, sorts = { "term", "prop" },
					ops = { p = { result = "prop", args = {} }, s = { result = "term", args = { { sort = "term" } } } },
				})
				local pv = k.build(sig2.ops.p, {})
				local bad, err = k.build(sig2.ops.s, { pv })
				T.eq(bad, nil)
				T.ok(err)
			end)
			T.it("builds a binder and discharges the bound index", function()
				local v0 = k.build_var(0, sig.sorts.term)
				local body = k.build(sig.ops.succ, { v0 })
				local l = k.build(sig.ops.lam, { body })
				T.ok(l)
				T.ok(k.is_closed(l))
			end)
			T.it("rejects a var whose sort mismatches the binder's declared bind sort", function()
				local sig2 = kernel.declare_signature({
					name = "mismatch-sig", version = 1, sorts = { "term", "prop" },
					ops = { lamp = { result = "term", args = { { sort = "term", binds = { "prop" } } } } },
				})
				-- var(0) here is declared sort "term" (sig2's own "term" —
				-- deliberately NOT the outer `sig`'s, so this exercises the
				-- binder-sort mismatch below, not an unrelated cross-
				-- signature arg-sort mismatch), but lamp's binder declares
				-- its bound variable sort "prop" — the occurrence of index 0
				-- inside the body must be sort "prop" to be well-formed
				-- under this binder.
				local v0 = k.build_var(0, sig2.sorts.term)
				local bad, err = k.build(sig2.ops.lamp, { v0 })
				T.eq(bad, nil)
				T.ok(err)
			end)
			T.it("leaves an unreferenced bound index unconstrained", function()
				local z = k.build(sig.ops.zero, {})
				local l = k.build(sig.ops.lam, { z })
				T.ok(l)
				T.ok(k.is_closed(l))
			end)
		end)

		-- ── sort_of / is_ground / is_closed ────────────────────────────────

		T.describe("sort_of / is_ground / is_closed", function()
			T.it("sort_of is O(1)-contracted and total", function()
				local z = k.build(sig.ops.zero, {})
				T.eq(k.sort_of(z), sig.sorts.term)
			end)
			T.it("a term with a metavariable is not ground", function()
				local m = k.build_meta("M", sig.sorts.term)
				local s = k.build(sig.ops.succ, { m })
				T.fail(k.is_ground(s))
			end)
			T.it("a term with no metavariable is ground", function()
				local z = k.build(sig.ops.zero, {})
				local s = k.build(sig.ops.succ, { z })
				T.ok(k.is_ground(s))
			end)
			T.it("a free var is not closed", function()
				local v0 = k.build_var(0, sig.sorts.term)
				T.fail(k.is_closed(v0))
			end)
			T.it("a term with only bound (discharged) vars is closed", function()
				local v0 = k.build_var(0, sig.sorts.term)
				local l = k.build(sig.ops.lam, { v0 })
				T.ok(k.is_closed(l))
			end)
			T.it("a var free relative to an outer binder is not closed", function()
				local v1 = k.build_var(1, sig.sorts.term) -- refers past the one binder lam introduces
				local l = k.build(sig.ops.lam, { v1 })
				T.fail(k.is_closed(l))
			end)
		end)

		-- ── equal ────────────────────────────────────────────────────────

		T.describe("equal", function()
			T.it("identical structure is equal", function()
				local a = k.build(sig.ops.succ, { k.build(sig.ops.zero, {}) })
				local b = k.build(sig.ops.succ, { k.build(sig.ops.zero, {}) })
				T.ok(k.equal(a, b))
			end)
			T.it("different operators are not equal", function()
				local a = k.build(sig.ops.zero, {})
				local b = k.build(sig.ops.succ, { a })
				T.fail(k.equal(a, b))
			end)
			T.it("different var indices are not equal", function()
				T.fail(k.equal(k.build_var(0, sig.sorts.term), k.build_var(1, sig.sorts.term)))
			end)
			T.it("operators from different signatures are different operators (decl identity)", function()
				local sig_b = kernel.declare_signature({
					name = "test-theory", version = 1, sorts = { "term" },
					ops = { zero = { result = "term", args = {} } },
				})
				local a = k.build(sig.ops.zero, {})
				local b = k.build(sig_b.ops.zero, {})
				T.fail(k.equal(a, b))
			end)
		end)

		-- ── shift ────────────────────────────────────────────────────────

		T.describe("shift", function()
			T.it("shifts a free var above cutoff", function()
				local v2 = k.build_var(2, sig.sorts.term)
				local s = k.shift(v2, 3, 0)
				T.ok(k.equal(s, k.build_var(5, sig.sorts.term)))
			end)
			T.it("does not shift a var below cutoff", function()
				local v1 = k.build_var(1, sig.sorts.term)
				local s = k.shift(v1, 3, 2)
				T.ok(k.equal(s, v1))
			end)
			T.it("shifts at the cutoff boundary (index == cutoff is shifted)", function()
				local v2 = k.build_var(2, sig.sorts.term)
				local s = k.shift(v2, 1, 2)
				T.ok(k.equal(s, k.build_var(3, sig.sorts.term)))
			end)
			T.it("cutoff increases when descending under a binder", function()
				-- lam(var(0)) shifted by 5 at cutoff 0: var(0) is bound by
				-- lam (index < cutoff+1), so it must NOT shift.
				local body = k.build_var(0, sig.sorts.term)
				local l = k.build(sig.ops.lam, { body })
				local s = k.shift(l, 5, 0)
				T.ok(k.equal(s, l))
			end)
			T.it("shifts a var free relative to a binder", function()
				-- lam(var(1)): var(1) is free relative to lam's own binder.
				-- Shifting the whole term by 5 at cutoff 0 must shift it to
				-- var(6) (cutoff inside the binder is 0+1=1, so index 1 >= 1
				-- is shifted).
				local body = k.build_var(1, sig.sorts.term)
				local l = k.build(sig.ops.lam, { body })
				local s = k.shift(l, 5, 0)
				local expected = k.build(sig.ops.lam, { k.build_var(6, sig.sorts.term) })
				T.ok(k.equal(s, expected))
			end)
			T.it("negative shift causing underflow is an error", function()
				local v0 = k.build_var(0, sig.sorts.term)
				local s, err = k.shift(v0, -1, 0)
				T.eq(s, nil)
				T.ok(err)
			end)
			T.it("identity shift (d=0) is a no-op", function()
				local v3 = k.build_var(3, sig.sorts.term)
				local s = k.shift(v3, 0, 0)
				T.ok(k.equal(s, v3))
			end)
		end)

		-- ── subst ────────────────────────────────────────────────────────

		T.describe("subst", function()
			T.it("replaces the exact target index", function()
				local v0 = k.build_var(0, sig.sorts.term)
				local z = k.build(sig.ops.zero, {})
				local s = k.subst(v0, 0, z)
				T.ok(k.equal(s, z))
			end)
			T.it("leaves a different index unchanged (no renumbering)", function()
				local v1 = k.build_var(1, sig.sorts.term)
				local z = k.build(sig.ops.zero, {})
				local s = k.subst(v1, 0, z)
				T.ok(k.equal(s, v1))
			end)
			T.it("rejects a sort-mismatched replacement", function()
				local sig2 = kernel.declare_signature({
					name = "two-sorts-subst", version = 1, sorts = { "term", "prop" },
					ops = { p = { result = "prop", args = {} } },
				})
				local v0 = k.build_var(0, sig.sorts.term)
				local pv = k.build(sig2.ops.p, {})
				local s, err = k.subst(v0, 0, pv)
				T.eq(s, nil)
				T.ok(err)
			end)
			T.it("is capture-avoiding under a binder: target index bumps, replacement shifts", function()
				-- lam(var(1)): substituting var(0)->succ(zero) at the OUTER
				-- level must reach var(1) (bumped to var(1) matching outer
				-- index 0 + 1 binder = still var(1) since target k=0 becomes
				-- k+1=1 under lam), replacing it with the replacement term
				-- shifted by 1 (so any free vars in it point past the
				-- binder).
				local body = k.build_var(1, sig.sorts.term)
				local l = k.build(sig.ops.lam, { body })
				local repl = k.build(sig.ops.succ, { k.build_var(0, sig.sorts.term) })
				local s = k.subst(l, 0, repl)
				-- Expected: lam(succ(var(1))) — repl's var(0) shifted by 1
				-- under the binder becomes var(1).
				local expected = k.build(sig.ops.lam, { k.build(sig.ops.succ, { k.build_var(1, sig.sorts.term) }) })
				T.ok(k.equal(s, expected))
			end)
			T.it("does not touch a bound occurrence with the same raw index (capture is impossible)", function()
				-- lam(var(0)): var(0) here refers to lam's OWN binder, not
				-- the outer scope. subst(lam(var(0)), 0, z) must leave the
				-- body's var(0) alone (target index bumps to 1 under the
				-- binder; var(0) != 1).
				local body = k.build_var(0, sig.sorts.term)
				local l = k.build(sig.ops.lam, { body })
				local z = k.build(sig.ops.zero, {})
				local s = k.subst(l, 0, z)
				T.ok(k.equal(s, l))
			end)
			T.it("fast-path short-circuit: substituting an absent index returns an equal (unchanged) term", function()
				local a = k.build(sig.ops.succ, { k.build_var(5, sig.sorts.term) })
				local z = k.build(sig.ops.zero, {})
				local s = k.subst(a, 0, z)
				T.ok(k.equal(s, a))
			end)
			T.it("two-variable binder: correct target bump per bound_count", function()
				-- pair2(var(2)) : var(2) is free relative to pair2's own
				-- two binders. subst target k=0 becomes k+2=2 inside; var(2)
				-- IS replaced.
				local body = k.build_var(2, sig.sorts.term)
				local p = k.build(sig.ops.pair2, { body })
				local z = k.build(sig.ops.zero, {})
				local s = k.subst(p, 0, z)
				local expected = k.build(sig.ops.pair2, { z })
				T.ok(k.equal(s, expected))
			end)
		end)

		-- ── match ────────────────────────────────────────────────────────

		T.describe("match", function()
			T.it("matches a metavariable against any term of the right sort", function()
				local pat = k.build_meta("M", sig.sorts.term)
				local term = k.build(sig.ops.zero, {})
				local b, err = k.match(pat, term)
				T.ok(b, err)
				T.ok(k.equal(b.M.term, term))
				T.eq(b.M.depth, 0)
			end)
			T.it("matches rigid structure recursively", function()
				local pat = k.build(sig.ops.succ, { k.build_meta("M", sig.sorts.term) })
				local term = k.build(sig.ops.succ, { k.build(sig.ops.zero, {}) })
				local b, err = k.match(pat, term)
				T.ok(b, err)
				T.ok(k.equal(b.M.term, k.build(sig.ops.zero, {})))
			end)
			T.it("fails on structural mismatch (different operator)", function()
				local pat = k.build(sig.ops.zero, {})
				local term = k.build(sig.ops.succ, { k.build(sig.ops.zero, {}) })
				local b, err = k.match(pat, term)
				T.eq(b, nil)
				T.ok(err)
			end)
			T.it("fails on var index mismatch", function()
				local pat = k.build_var(0, sig.sorts.term)
				local term = k.build_var(1, sig.sorts.term)
				local b, err = k.match(pat, term)
				T.eq(b, nil)
				T.ok(err)
			end)
			T.it("non-linear pattern: same-depth repeated metavariable succeeds when equal", function()
				-- app(M, M) matching app(zero, zero).
				local m = k.build_meta("M", sig.sorts.term)
				local pat = k.build(sig.ops.app, { m, m })
				local z = k.build(sig.ops.zero, {})
				local term = k.build(sig.ops.app, { z, z })
				local b, err = k.match(pat, term)
				T.ok(b, err)
				T.ok(k.equal(b.M.term, z))
			end)
			T.it("non-linear pattern: same-depth repeated metavariable fails when unequal", function()
				local m = k.build_meta("M", sig.sorts.term)
				local pat = k.build(sig.ops.app, { m, m })
				local term = k.build(sig.ops.app, { k.build(sig.ops.zero, {}), k.build(sig.ops.succ, { k.build(sig.ops.zero, {}) }) })
				local b, err = k.match(pat, term)
				T.eq(b, nil)
				T.ok(err)
			end)
			T.it("non-linear pattern across different binder depths: shift-adjusted equality succeeds", function()
				-- pattern: app(M, lam(M)) — M's first occurrence at depth 0,
				-- second occurrence at depth 1 (inside lam). For M=var(0)
				-- (a term free relative to the outer app), the SECOND
				-- occurrence must equal shift(var(0), 1) = var(1) — i.e.
				-- the candidate at that position is the same variable,
				-- correctly re-expressed one binder deeper.
				local m1 = k.build_meta("M", sig.sorts.term)
				local m2 = k.build_meta("M", sig.sorts.term)
				local pat = k.build(sig.ops.app, { m1, k.build(sig.ops.lam, { m2 }) })
				local outer_v = k.build_var(0, sig.sorts.term)
				local inner_v = k.build_var(1, sig.sorts.term) -- shift(var(0), 1) under the binder
				local term = k.build(sig.ops.app, { outer_v, k.build(sig.ops.lam, { inner_v }) })
				local b, err = k.match(pat, term)
				T.ok(b, err)
				T.ok(k.equal(b.M.term, outer_v))
				T.eq(b.M.depth, 0)
			end)
			T.it("non-linear pattern across different binder depths: mismatched candidate fails", function()
				local m1 = k.build_meta("M", sig.sorts.term)
				local m2 = k.build_meta("M", sig.sorts.term)
				local pat = k.build(sig.ops.app, { m1, k.build(sig.ops.lam, { m2 }) })
				local outer_v = k.build_var(0, sig.sorts.term)
				-- Wrong: inner occurrence uses var(2) instead of the
				-- correctly-shifted var(1).
				local wrong_inner = k.build_var(2, sig.sorts.term)
				local term = k.build(sig.ops.app, { outer_v, k.build(sig.ops.lam, { wrong_inner }) })
				local b, err = k.match(pat, term)
				T.eq(b, nil)
				T.ok(err)
			end)
			T.it("non-linear pattern referencing a binder strictly between the two depths fails naturally", function()
				-- pattern: app(M, lam(M)) again, but the candidate at depth
				-- 1 references index 0 (the binder introduced strictly
				-- between the two occurrences) — no consistent binding
				-- exists (shifting the depth-0 binding down would
				-- underflow), so match must fail.
				local m1 = k.build_meta("M", sig.sorts.term)
				local m2 = k.build_meta("M", sig.sorts.term)
				local pat = k.build(sig.ops.app, { m1, k.build(sig.ops.lam, { m2 }) })
				local outer_v = k.build_var(0, sig.sorts.term)
				local bound_ref = k.build_var(0, sig.sorts.term) -- refers to lam's own binder
				local term = k.build(sig.ops.app, { outer_v, k.build(sig.ops.lam, { bound_ref }) })
				local b, err = k.match(pat, term)
				T.eq(b, nil)
				T.ok(err)
			end)
			T.it("fails on metavariable sort mismatch", function()
				local sig2 = kernel.declare_signature({
					name = "two-sorts-match", version = 1, sorts = { "term", "prop" },
					ops = { p = { result = "prop", args = {} } },
				})
				local pat = k.build_meta("M", sig2.sorts.prop)
				local term = k.build(sig.ops.zero, {})
				local b, err = k.match(pat, term)
				T.eq(b, nil)
				T.ok(err)
			end)
		end)

		-- ── instantiate ──────────────────────────────────────────────────

		T.describe("instantiate", function()
			T.it("replaces a metavariable with its binding", function()
				local pat = k.build_meta("M", sig.sorts.term)
				local z = k.build(sig.ops.zero, {})
				local t, err = k.instantiate(pat, { M = { term = z, depth = 0 } })
				T.ok(t, err)
				T.ok(k.equal(t, z))
			end)
			T.it("errors on an unbound metavariable", function()
				local pat = k.build_meta("M", sig.sorts.term)
				local t, err = k.instantiate(pat, {})
				T.eq(t, nil)
				T.ok(err)
			end)
			T.it("is exactly inverse to match on a round trip (same depth)", function()
				local pat = k.build(sig.ops.succ, { k.build_meta("M", sig.sorts.term) })
				local term = k.build(sig.ops.succ, { k.build(sig.ops.zero, {}) })
				local b = k.match(pat, term)
				local t, err = k.instantiate(pat, b)
				T.ok(t, err)
				T.ok(k.equal(t, term))
			end)
			T.it("shifts the binding when the metavariable occurs under a binder", function()
				-- pattern: lam(M) with M bound (at depth 0) to var(0)
				-- (a term free relative to that outer scope). Instantiating
				-- under the binder (depth 1) must shift the bound term by
				-- 1: lam(var(1)).
				local pat = k.build(sig.ops.lam, { k.build_meta("M", sig.sorts.term) })
				local bound_term = k.build_var(0, sig.sorts.term)
				local t, err = k.instantiate(pat, { M = { term = bound_term, depth = 0 } })
				T.ok(t, err)
				local expected = k.build(sig.ops.lam, { k.build_var(1, sig.sorts.term) })
				T.ok(k.equal(t, expected))
			end)
			T.it("round trip through match+instantiate across differing binder depths", function()
				local m1 = k.build_meta("M", sig.sorts.term)
				local m2 = k.build_meta("M", sig.sorts.term)
				local pat = k.build(sig.ops.app, { m1, k.build(sig.ops.lam, { m2 }) })
				local outer_v = k.build_var(0, sig.sorts.term)
				local inner_v = k.build_var(1, sig.sorts.term)
				local term = k.build(sig.ops.app, { outer_v, k.build(sig.ops.lam, { inner_v }) })
				local b, merr = k.match(pat, term)
				T.ok(b, merr)
				local t, err = k.instantiate(pat, b)
				T.ok(t, err)
				T.ok(k.equal(t, term))
			end)
			T.it("errors when the shifted binding's sort mismatches the metavariable's declared sort", function()
				-- Constructing this requires a metavariable declared with
				-- one sort in the pattern but bound (via a hand-built
				-- bindings table, not via match) to a term of a different
				-- sort.
				local sig2 = kernel.declare_signature({
					name = "two-sorts-inst", version = 1, sorts = { "term", "prop" },
					ops = { p = { result = "prop", args = {} } },
				})
				local pat = k.build_meta("M", sig.sorts.term)
				local pv = k.build(sig2.ops.p, {})
				local t, err = k.instantiate(pat, { M = { term = pv, depth = 0 } })
				T.eq(t, nil)
				T.ok(err)
			end)
		end)

		-- ── Sort identity (docs/decisions/typechecker-v10-core-design.md
		-- "Sort identity: identity-by-declaration + explicit imports";
		-- closes the gap docs/typechecker-v10-pilot-signatures-proposal.md
		-- §4 recorded — option C of the three it enumerated) ─────────────

		T.describe("sort identity", function()
			T.it("same-named sorts in independently-declared signatures are not interchangeable", function()
				local sig_a = kernel.declare_signature({
					name = "coord-a", version = 1, sorts = { "point" },
					ops = { origin = { result = "point", args = {} } },
				})
				local sig_b = kernel.declare_signature({
					name = "coord-b", version = 1, sorts = { "point" },
					ops = { mk_point = { result = "point", args = { { sort = "point" } } } },
				})
				T.ok(sig_a)
				T.ok(sig_b)
				local origin = k.build(sig_a.ops.origin, {})
				T.ok(origin)
				-- sig_b's mk_point expects an argument of sig_b's OWN "point"
				-- object, not sig_a's — even though both are literally named
				-- "point": build rejects it structurally, not silently.
				local bad, err = k.build(sig_b.ops.mk_point, { origin })
				T.eq(bad, nil)
				T.ok(err)
				-- Two vars built against each signature's own "point" object,
				-- same de Bruijn index, are not equal — the sort objects
				-- differ by identity despite sharing a display name.
				local va = k.build_var(0, sig_a.sorts.point)
				local vb = k.build_var(0, sig_b.sorts.point)
				T.fail(k.equal(va, vb))
			end)

			T.it("an imported sort is usable in ops and identity-stable across signatures", function()
				local base_sig = kernel.declare_signature({
					name = "addr-base", version = 1, sorts = { "point" },
					ops = { origin = { result = "point", args = {} } },
				})
				T.ok(base_sig)
				local importer_sig = kernel.declare_signature({
					name = "addr-importer", version = 1,
					sorts = {},
					imports = { point = base_sig.sorts.point },
					ops = { shift_point = { result = "point", args = { { sort = "point" } } } },
				})
				T.ok(importer_sig)
				-- The imported sort is the SAME object the owning signature
				-- declared, cited under a local name — not a copy.
				T.eq(importer_sig.sorts.point, base_sig.sorts.point)
				local origin = k.build(base_sig.ops.origin, {})
				T.ok(origin)
				-- Usable directly as an argument to the IMPORTING signature's
				-- operator, exactly like a locally-declared sort.
				local shifted = k.build(importer_sig.ops.shift_point, { origin })
				T.ok(shifted)
				-- sort_of returns the identical object regardless of which
				-- signature's op produced the term.
				T.eq(k.sort_of(origin), base_sig.sorts.point)
				T.eq(k.sort_of(shifted), base_sig.sorts.point)
				T.ok(k.equal(k.build_var(0, base_sig.sorts.point), k.build_var(0, importer_sig.sorts.point)))
			end)

			T.it("declare_signature rejects an import that is not a declared sort object", function()
				local bad1, err1 = kernel.declare_signature({
					name = "bad-import-not-a-table", version = 1, sorts = {},
					imports = { point = "not-a-sort-object" },
					ops = {},
				})
				T.eq(bad1, nil)
				T.ok(err1)

				local bad2, err2 = kernel.declare_signature({
					name = "bad-import-malformed-table", version = 1, sorts = {},
					imports = { point = { name = "point" } }, -- missing sig_name/sig_version
					ops = {},
				})
				T.eq(bad2, nil)
				T.ok(err2)
			end)
		end)
	end)
end

return {}
