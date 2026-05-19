-- Unit tests for the v4 typechecker foundation.
--
-- Tests construct types programmatically (no parser, no AST walker in 4a) and
-- assert subtype obligations directly.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V = require("lib.type.static-v4")
local T = require("lib.test.assert")

-- Shorthand.
local function st(a, b)
	local ok, err = V.subtype(a, b)
	return ok, err
end

T.describe("primitives", function()
	T.it("reflexive: number <: number", function()
		T.ok(st(V.number, V.number))
	end)
	T.it("integer <: number (declared edge)", function()
		T.ok(st(V.integer, V.number))
	end)
	T.it("number is not <: integer", function()
		T.fail(st(V.number, V.integer))
	end)
	T.it("unrelated primitives reject: string </: number", function()
		T.fail(st(V.string_, V.number))
	end)
end)

T.describe("top and bottom", function()
	T.it("A <: unknown for any A", function()
		T.ok(st(V.number, V.top()))
		T.ok(st(V.string_, V.top()))
		T.ok(st(V.fn({}, V.number), V.top()))
	end)
	T.it("never <: A for any A", function()
		T.ok(st(V.bot(), V.number))
		T.ok(st(V.bot(), V.fn({V.number}, V.string_)))
	end)
	T.it("unknown is not <: number", function()
		T.fail(st(V.top(), V.number))
	end)
end)

T.describe("literals", function()
	T.it("42 <: 42 (same literal)", function()
		T.ok(st(V.literal("integer", 42), V.literal("integer", 42)))
	end)
	T.it("42 </: 43 (distinct literals)", function()
		T.fail(st(V.literal("integer", 42), V.literal("integer", 43)))
	end)
	T.it("42 <: integer (literal-to-base)", function()
		T.ok(st(V.literal("integer", 42), V.integer))
	end)
	T.it("42 <: number (transitive integer <: number)", function()
		T.ok(st(V.literal("integer", 42), V.number))
	end)
	T.it("\"GET\" <: string", function()
		T.ok(st(V.literal("string", "GET"), V.string_))
	end)
	T.it("string </: \"GET\" (primitive too wide)", function()
		T.fail(st(V.string_, V.literal("string", "GET")))
	end)
end)

T.describe("functions", function()
	T.it("(number) -> integer <: (number) -> number (covariant return)", function()
		T.ok(st(V.fn({V.number}, V.integer), V.fn({V.number}, V.number)))
	end)
	T.it("(number) -> number <: (integer) -> number (contravariant param)", function()
		-- The supertype accepts only integers; the subtype accepts all numbers,
		-- so the subtype handles every input the supertype could pass.
		T.ok(st(V.fn({V.number}, V.number), V.fn({V.integer}, V.number)))
	end)
	T.it("(integer) -> number </: (number) -> number (contravariance check)", function()
		T.fail(st(V.fn({V.integer}, V.number), V.fn({V.number}, V.number)))
	end)
	T.it("arity mismatch rejects", function()
		T.fail(st(V.fn({V.number}, V.number), V.fn({V.number, V.number}, V.number)))
	end)
end)

T.describe("records — width", function()
	T.it("{x: int, y: int} <: {x: int} (closed-on-RHS-wider-LHS rejected)", function()
		-- A closed RHS forbids extra fields on the LHS.
		T.fail(st(
			V.rec({ x = V.integer, y = V.integer }, false),
			V.rec({ x = V.integer }, false)
		))
	end)
	T.it("{x: int, y: int} <: {x: int, ...} (open-on-RHS accepts extras)", function()
		T.ok(st(
			V.rec({ x = V.integer, y = V.integer }, false),
			V.rec({ x = V.integer }, true)
		))
	end)
	T.it("{x: int} </: {x: int, y: int} (missing field)", function()
		T.fail(st(
			V.rec({ x = V.integer }, false),
			V.rec({ x = V.integer, y = V.integer }, false)
		))
	end)
end)

T.describe("records — depth", function()
	T.it("{x: integer} <: {x: number} (covariant field)", function()
		T.ok(st(
			V.rec({ x = V.integer }, false),
			V.rec({ x = V.number }, false)
		))
	end)
	T.it("{x: number} </: {x: integer}", function()
		T.fail(st(
			V.rec({ x = V.number }, false),
			V.rec({ x = V.integer }, false)
		))
	end)
end)

T.describe("union", function()
	-- Union-on-LHS decomposes without backtracking: every member must hold.
	-- This is supported in 4a.
	T.it("A | B <: C requires A <: C AND B <: C", function()
		-- integer | string is not <: number (string fails).
		T.fail(st(V.union({V.integer, V.string_}), V.number))
		-- integer | 42 IS <: number (both members are).
		T.ok(st(V.union({V.integer, V.literal("integer", 42)}), V.number))
	end)

	-- Union-on-RHS (`A <: B | C`) was deferred in 4a; Phase 4c lifted the
	-- rejection by adding complement and the MLstruct negation rewrite
	-- (`A ∧ ¬B <: C`). The obligation now reduces to a DNF emptiness check
	-- (see subtype.lua, empty.lua).
	T.it("A <: A | B holds (resolved in Phase 4c via negation rewrite)", function()
		T.ok(st(V.integer, V.union({V.integer, V.string_})))
	end)
	T.it("A <: B | C rejects when no disjunct fits", function()
		-- integer is not a subtype of (string | boolean) — no disjunct
		-- covers it, and integer ∩ ¬string ∩ ¬boolean = integer ≠ ⊥.
		T.fail(st(V.integer, V.union({V.string_, V.boolean})))
	end)
end)

T.describe("intersection", function()
	-- Intersection-on-RHS decomposes without backtracking: every member
	-- must hold. This is supported in 4a.
	T.it("C <: A & B requires C <: A AND C <: B", function()
		-- 42 <: integer AND 42 <: number, so 42 <: integer & number.
		T.ok(st(
			V.literal("integer", 42),
			V.inter({V.integer, V.number})
		))
		-- integer is not <: string, so integer is not <: integer & string.
		T.fail(st(V.integer, V.inter({V.integer, V.string_})))
	end)

	-- Intersection-on-LHS (`A & B <: C`) — dual of union-on-RHS. Phase 4c
	-- resolves both via the same DNF emptiness machinery. The case below is
	-- vacuously true because `integer ∩ string = ⊥`.
	T.it("A & B <: A holds (resolved in Phase 4c via emptiness)", function()
		T.ok(st(V.inter({V.integer, V.string_}), V.integer))
	end)
	T.it("integer & number <: integer (non-empty inter, holds)", function()
		T.ok(st(V.inter({V.integer, V.number}), V.integer))
	end)
end)

T.describe("variables — bound accumulation", function()
	T.it("constraint integer <: α adds a lower bound", function()
		local a = V.var("a")
		local ok = st(V.integer, a)
		T.ok(ok)
		T.eq(#a.lower, 1)
		T.eq(a.lower[1], V.integer)
	end)
	T.it("constraint α <: number adds an upper bound", function()
		local a = V.var("a")
		local ok = st(a, V.number)
		T.ok(ok)
		T.eq(#a.upper, 1)
		T.eq(a.upper[1], V.number)
	end)
	T.it("both bounds: integer <: α <: number is satisfiable", function()
		local a = V.var("a")
		local s = V.new_solver()
		T.ok(V.constrain(s, V.integer, a))
		T.ok(V.constrain(s, a, V.number))
		-- The transitive closure check (integer <: number) should fire and
		-- succeed silently.
		T.eq(s.error, nil)
	end)
	T.it("incompatible bounds: string <: α <: number fails on closure", function()
		local a = V.var("a")
		local s = V.new_solver()
		T.ok(V.constrain(s, V.string_, a))
		-- Adding the upper bound triggers string <: number, which fails.
		local ok = V.constrain(s, a, V.number)
		T.fail(ok)
		T.neq(s.error, nil)
	end)
	T.it("variable linking propagates bounds", function()
		-- integer <: α, α <: β, then β must have integer as a lower bound.
		local a, b = V.var("a"), V.var("b")
		local s = V.new_solver()
		T.ok(V.constrain(s, V.integer, a))
		T.ok(V.constrain(s, a, b))
		-- β should now have integer flowing in as a lower bound.
		T.eq(#b.lower, 1)
		T.eq(b.lower[1], V.integer)
	end)
end)

T.describe("recursive types — equi-recursive μ", function()
	T.it("μX. {value: int, next: X} <: itself (identity short-circuit)", function()
		-- Same node on both sides: identity check fires before unfolding.
		local list = V.fix(function(self)
			return V.rec({ value = V.integer, next = self }, false)
		end)
		T.ok(st(list, list))
	end)

	T.it("μX. () -> X <: μY. () -> Y (covariant return, two distinct mus)", function()
		-- Distinct μ nodes that should be structurally equivalent. Subtyping
		-- unfolds both, lands on a (μX, μY) pair, caches it, decomposes the
		-- arrows, and when the bodies recurse to (μX, μY) again the cache
		-- short-circuits — the canonical termination property for recursive
		-- subtyping (Amadio-Cardelli 1993, Pierce TAPL §21).
		local f1 = V.fix(function(self) return V.fn({}, self) end)
		local f2 = V.fix(function(self) return V.fn({}, self) end)
		T.ok(st(f1, f2))
		T.ok(st(f2, f1))
	end)

	T.it("μX. (X) -> integer <: μY. (Y) -> integer (contravariant param)", function()
		-- Parameter is contravariant: comparing the bodies requires Y <: X,
		-- which is the *reverse* of the outer obligation. Without cycle
		-- caching this would diverge or fail; with it, the cache admits the
		-- swapped pair on second visit.
		local g1 = V.fix(function(self) return V.fn({ self }, V.integer) end)
		local g2 = V.fix(function(self) return V.fn({ self }, V.integer) end)
		T.ok(st(g1, g2))
	end)

	T.it("μX. () -> X <: μY. () -> integer (rejects when bodies diverge)", function()
		-- Recursive on LHS, non-recursive on RHS. Unfold LHS to (() -> μX),
		-- decompose, return covariant: μX <: integer. Unfold LHS again:
		-- (() -> μX) <: integer — function does not fit primitive, error.
		local rec = V.fix(function(self) return V.fn({}, self) end)
		local nonrec = V.fn({}, V.integer)
		T.fail(st(rec, nonrec))
	end)

	T.it("cycle cache fires: μX. () -> X compared with itself terminates", function()
		-- Self-comparison via identity is too easy. Construct two distinct
		-- μ nodes whose bodies' subtype obligation traverses the cycle, and
		-- verify termination relies on the cache (timing out would mean
		-- divergence). We use a wall-clock-free witness: the call returns.
		local m1 = V.fix(function(self) return V.fn({}, self) end)
		local m2 = V.fix(function(self) return V.fn({}, self) end)
		local s = V.new_solver()
		T.ok(V.constrain(s, m1, m2))
		-- The cache must contain the (m1, m2) pair (under unfold the body
		-- recurses to that same pair, hits the cache, returns).
		local k = tostring(m1) .. "<:" .. tostring(m2)
		T.ok(s.cache[k])
	end)

	T.it("recursive type with a type-variable parameter", function()
		-- Models `List<α>` (non-empty cons list) by leaving the head's type
		-- as a free variable. Subtyping List<α> <: List<α> (same instance)
		-- succeeds by identity; depositing bounds on α via a separate
		-- constraint then visibly affects the recursive structure.
		local alpha = V.var("α")
		local list_alpha = V.fix(function(self)
			return V.rec({ head = alpha, tail = self }, false)
		end)
		T.ok(st(list_alpha, list_alpha))
		-- The body still mentions α — constraining α propagates through.
		T.ok(V.subtype(V.integer, alpha))
		T.eq(#alpha.lower, 1)
		T.eq(alpha.lower[1], V.integer)
	end)

	T.it("μX. {value: int, next: X} <: μY. {value: int, next: Y} (record cycle)", function()
		-- Same shape, distinct μ nodes. Field-by-field decomposition runs
		-- into the recursive `next` pair on both sides; cache short-circuits.
		local l1 = V.fix(function(self) return V.rec({ value = V.integer, next = self }, false) end)
		local l2 = V.fix(function(self) return V.rec({ value = V.integer, next = self }, false) end)
		T.ok(st(l1, l2))
	end)

	T.it("pretty-printing terminates and emits μ form", function()
		local l = V.fix(function(self) return V.rec({ value = V.integer, next = self }, false) end)
		local str = V.show(l)
		T.ok(string.find(str, "μ", 1, true) ~= nil, "expected μ in output: " .. str)
		-- The back-reference should appear: the body mentions the bound
		-- name (X<id>) where `next: self` recurses.
		T.ok(string.find(str, "X", 1, true) ~= nil, "expected bound name in output: " .. str)
		-- And it must be a finite string (termination — vacuously true if
		-- we got this far, but assert non-empty for the record).
		T.neq(#str, 0)
	end)

	T.it("pretty-printing nested μ types uses distinct bound names", function()
		local inner = V.fix(function(self) return V.fn({}, self) end)
		local outer = V.fix(function(self) return V.rec({ inner = inner, outer = self }, false) end)
		local str = V.show(outer)
		-- Two distinct μ nodes produced two distinct bound names; the
		-- output must mention both ids.
		T.ok(string.find(str, "X" .. inner.id, 1, true) ~= nil, "missing inner mu name in: " .. str)
		T.ok(string.find(str, "X" .. outer.id, 1, true) ~= nil, "missing outer mu name in: " .. str)
	end)
end)

T.describe("variables — termination on cycles", function()
	T.it("self-referential constraint does not loop", function()
		-- α <: α should succeed trivially via identity. We additionally check
		-- that linking α to itself through a structural form terminates.
		local a = V.var("a")
		T.ok(st(a, a))
	end)
	T.it("mutually referential variables terminate", function()
		local a, b = V.var("a"), V.var("b")
		local s = V.new_solver()
		T.ok(V.constrain(s, a, b))
		T.ok(V.constrain(s, b, a))
		-- Subsequent identical constraints hit the cache.
		T.ok(V.constrain(s, a, b))
	end)
end)

-- ── Phase 4b.2: indexed access types ─────────────────────────────────────

-- Shorthand: literal string key.
local function ks(s) return V.literal("string", s) end

T.describe("indexed access — closed record", function()
	T.it("closed record + literal key in record → field type", function()
		local r = V.rec({ x = V.integer, y = V.string_ }, false)
		local got, err = V.index(r, ks("x"))
		T.eq(err, nil)
		T.eq(got, V.integer)
	end)

	T.it("closed record + literal key NOT in record → error", function()
		-- Decision: error, not `never`. Rationale: a missing-key indexed
		-- access is almost always a user typo, and silently producing `never`
		-- propagates an inhabited-by-nothing type into downstream constraints
		-- where it shows up as a confusing subtype failure. Surfacing the
		-- bug at the operation site itself is the principled response.
		local r = V.rec({ x = V.integer, y = V.string_ }, false)
		local got, err = V.index(r, ks("nope"))
		T.eq(got, nil)
		T.ok(err and err:find("nope", 1, true) ~= nil, "error should mention the missing key, got: " .. tostring(err))
	end)

	T.it("closed record + union of literal keys → distributed union", function()
		-- T["x" | "y"] = T["x"] | T["y"] = integer | string.
		local r = V.rec({ x = V.integer, y = V.string_ }, false)
		local got, err = V.index(r, V.union({ ks("x"), ks("y") }))
		T.eq(err, nil)
		-- T["x"] <: result and T["y"] <: result; result is { integer, string }
		-- in some order — assert via subtype rather than identity.
		T.ok(got ~= nil and got.tag == "union", "expected union, got: " .. V.show(got))
		-- Validate members structurally — `A <: B | C` is deferred to Phase
		-- 4c (no complement yet), so we cannot use `subtype` directly.
		local saw_int, saw_str = false, false
		for _, m in ipairs(got.members) do
			if m == V.integer then saw_int = true end
			if m == V.string_ then saw_str = true end
		end
		T.ok(saw_int, "missing integer member: " .. V.show(got))
		T.ok(saw_str, "missing string member: " .. V.show(got))
	end)

	T.it("closed record + string primitive key → union of all field types", function()
		local r = V.rec({ x = V.integer, y = V.string_ }, false)
		local got, err = V.index(r, V.string_)
		T.eq(err, nil)
		T.ok(got ~= nil and got.tag == "union", "expected union, got: " .. V.show(got))
		local saw_int, saw_str = false, false
		for _, m in ipairs(got.members) do
			if m == V.integer then saw_int = true end
			if m == V.string_ then saw_str = true end
		end
		T.ok(saw_int)
		T.ok(saw_str)
	end)
end)

T.describe("indexed access — indexer-typed record", function()
	T.it("{ [string]: V } + literal key → V", function()
		local v = V.prim("boolean")
		local r = V.rec({}, false, V.indexer(V.string_, v))
		local got, err = V.index(r, ks("anything"))
		T.eq(err, nil)
		T.eq(got, v)
	end)

	T.it("mixed: named field wins over indexer at the named key", function()
		-- { x: integer, [string]: boolean }[\"x\"] = integer (not boolean).
		-- Named fields shadow the indexer at their key.
		local r = V.rec({ x = V.integer }, false, V.indexer(V.string_, V.boolean))
		local got, err = V.index(r, ks("x"))
		T.eq(err, nil)
		T.eq(got, V.integer)
	end)

	T.it("mixed: extra key falls through to indexer", function()
		local r = V.rec({ x = V.integer }, false, V.indexer(V.string_, V.boolean))
		local got, err = V.index(r, ks("other"))
		T.eq(err, nil)
		T.eq(got, V.boolean)
	end)
end)

T.describe("indexed access — open record", function()
	T.it("open record + literal key in closed prefix → field type", function()
		local r = V.rec({ x = V.integer }, true)
		local got, err = V.index(r, ks("x"))
		T.eq(err, nil)
		T.eq(got, V.integer)
	end)

	T.it("open record + literal key NOT in closed prefix → unknown (row var contribution)", function()
		-- Per the rewrite design §1.1: an open record's row variable contributes
		-- the result. Under 4b.2's scope (no proper row polymorphism yet) the
		-- row's contribution is `unknown`. Documented in index.lua.
		local r = V.rec({ x = V.integer }, true)
		local got, err = V.index(r, ks("other"))
		T.eq(err, nil)
		T.ok(got ~= nil and got.tag == "top", "expected unknown, got: " .. V.show(got))
	end)
end)

T.describe("indexed access — distribution", function()
	T.it("union of records + literal key → distributed", function()
		-- (R1 | R2)[\"x\"] = R1[\"x\"] | R2[\"x\"] = integer | string.
		local r1 = V.rec({ x = V.integer }, false)
		local r2 = V.rec({ x = V.string_ }, false)
		local got, err = V.index(V.union({ r1, r2 }), ks("x"))
		T.eq(err, nil)
		T.ok(got ~= nil and got.tag == "union", "expected union, got: " .. V.show(got))
		local saw_int, saw_str = false, false
		for _, m in ipairs(got.members) do
			if m == V.integer then saw_int = true end
			if m == V.string_ then saw_str = true end
		end
		T.ok(saw_int)
		T.ok(saw_str)
	end)

	T.it("union of records + literal key missing in one → error (closed)", function()
		local r1 = V.rec({ x = V.integer }, false)
		local r2 = V.rec({ y = V.string_ }, false)
		local got, err = V.index(V.union({ r1, r2 }), ks("x"))
		T.eq(got, nil)
		T.neq(err, nil)
	end)
end)

T.describe("indexed access — deferred / rejected cases", function()
	T.it("type-variable key on a concrete record → rejected (no deferred queue in 4b.2)", function()
		-- Decision: REJECT, not defer. Phase 4a's solver has only the `<:`
		-- primitive with eager bound propagation; no deferred-constraint
		-- queue exists. CLAUDE.md "Temporary measures are context poisoning"
		-- prohibits bolting on a one-off queue for indexed access alone. The
		-- principled choice is to error loudly until the general suspension
		-- mechanism lands (alongside match-type suspension).
		local r = V.rec({ x = V.integer }, false)
		local key = V.var("k")
		local got, err = V.index(r, key)
		T.eq(got, nil)
		T.ok(err and err:find("deferred", 1, true) ~= nil, "expected deferred error, got: " .. tostring(err))
	end)

	T.it("indexed access on a type variable target → rejected", function()
		local obj = V.var("o")
		local got, err = V.index(obj, ks("x"))
		T.eq(got, nil)
		T.ok(err and err:find("deferred", 1, true) ~= nil, "expected deferred error, got: " .. tostring(err))
	end)

	T.it("non-record target → error", function()
		local got, err = V.index(V.integer, ks("x"))
		T.eq(got, nil)
		T.ok(err and err:find("record", 1, true) ~= nil, "expected record-shape error, got: " .. tostring(err))
	end)

	T.it("non-string-typed key → error", function()
		local r = V.rec({ x = V.integer }, false)
		local got, err = V.index(r, V.integer)
		T.eq(got, nil)
		T.neq(err, nil)
	end)
end)

T.describe("indexed access — recursive (μ) types", function()
	T.it("indexed access on μ unfolds and terminates", function()
		-- μX. { value: integer, next: X }. Reading ["value"] yields integer;
		-- reading ["next"] yields the μ node itself (the cyclic table). Both
		-- must terminate in finite steps.
		local list = V.fix(function(self)
			return V.rec({ value = V.integer, next = self }, false)
		end)
		local v, ev = V.index(list, ks("value"))
		T.eq(ev, nil)
		T.eq(v, V.integer)
		local n, en = V.index(list, ks("next"))
		T.eq(en, nil)
		-- `next` field projects to the μ node itself (identity).
		T.eq(n, list)
	end)
end)

T.describe("indexed access — subtyping with indexers", function()
	-- These tests exercise the new V4Rec.indexer field in subtype.lua to
	-- verify 4b.2 didn't regress the existing record subtyping path.
	T.it("{ [string]: integer } <: { [string]: number } (covariant value)", function()
		local a = V.rec({}, false, V.indexer(V.string_, V.integer))
		local b = V.rec({}, false, V.indexer(V.string_, V.number))
		T.ok(st(a, b))
	end)

	T.it("{ x: integer } <: { [string]: number } (named field flows into indexer)", function()
		local a = V.rec({ x = V.integer }, false)
		local b = V.rec({}, false, V.indexer(V.string_, V.number))
		T.ok(st(a, b))
	end)

	T.it("{ x: string } </: { [string]: number } (named field violates indexer value)", function()
		local a = V.rec({ x = V.string_ }, false)
		local b = V.rec({}, false, V.indexer(V.string_, V.number))
		T.fail(st(a, b))
	end)
end)

-- ── Phase 4c: negation / complement ──────────────────────────────────────

T.describe("negation — construction and short-circuits", function()
	T.it("~unknown = never", function()
		local n = V.neg(V.top())
		T.eq(n.tag, "bot")
	end)
	T.it("~never = unknown", function()
		local n = V.neg(V.bot())
		T.eq(n.tag, "top")
	end)
	T.it("~~T = T (involution)", function()
		local int_neg = V.neg(V.neg(V.integer))
		T.eq(int_neg, V.integer)
	end)
	T.it("~~~T = ~T", function()
		-- Three negations involute to one.
		local t = V.neg(V.neg(V.neg(V.integer)))
		T.eq(t.tag, "neg")
		T.eq(t.body, V.integer)
	end)
end)

T.describe("negation — basic subtype queries", function()
	T.it("A <: ~B for disjoint A, B (integer <: ~string)", function()
		T.ok(st(V.integer, V.neg(V.string_)))
	end)
	T.it("A </: ~B for overlapping A, B (integer </: ~integer)", function()
		T.fail(st(V.integer, V.neg(V.integer)))
	end)
	T.it("A </: ~B for A inside B (integer </: ~number)", function()
		-- integer <: number, so integer is NOT in ¬number.
		T.fail(st(V.integer, V.neg(V.number)))
	end)
	T.it("never <: ~T for any T", function()
		T.ok(st(V.bot(), V.neg(V.integer)))
		T.ok(st(V.bot(), V.neg(V.top())))
	end)
	T.it("~T <: unknown for any T", function()
		T.ok(st(V.neg(V.integer), V.top()))
	end)
end)

T.describe("negation — De Morgan and lattice laws", function()
	T.it("excluded middle: T <: T | ~T", function()
		-- 42 <: integer | ~integer (lattice covers everything).
		T.ok(st(V.literal("integer", 42), V.union({V.integer, V.neg(V.integer)})))
		-- Also for an unrelated value.
		T.ok(st(V.string_, V.union({V.integer, V.neg(V.integer)})))
	end)
	T.it("self-cancellation in intersection: T & ~T = never", function()
		-- (T & ~T) <: C for any C — even an impossible C like never.
		T.ok(st(V.inter({V.integer, V.neg(V.integer)}), V.bot()))
		-- Symmetric: never <: T & ~T.
		T.ok(st(V.bot(), V.inter({V.integer, V.neg(V.integer)})))
	end)
	T.it("De Morgan: ~(A | B) <: ~A (component on the right)", function()
		-- ¬(A ∨ B) = ¬A ∧ ¬B  <:  ¬A. Decomposed by the solver's
		-- emptiness check after De Morgan rewrites.
		T.ok(st(V.neg(V.union({V.integer, V.string_})), V.neg(V.integer)))
	end)
	T.it("De Morgan: ~A & ~B <: ~(A | B)", function()
		T.ok(st(
			V.inter({ V.neg(V.integer), V.neg(V.string_) }),
			V.neg(V.union({V.integer, V.string_}))
		))
	end)
end)

T.describe("negation — distribution and combinator interactions", function()
	T.it("worked example: (A | B | (A->B)) & ~(A->B) <: A | B", function()
		-- Design doc §2.2 worked example. Reduces by distribution and
		-- self-cancellation to (A & ~(A->B)) | (B & ~(A->B)) | ⊥. The
		-- A & ¬(A→B) and B & ¬(A→B) parts hold because A, B are not
		-- function-shaped → cross-kind disjoint with (A→B) under
		-- intersection with its negation.
		local A, B = V.integer, V.string_
		local fab = V.fn({A}, B)
		local lhs = V.inter({ V.union({A, B, fab}), V.neg(fab) })
		local rhs = V.union({A, B})
		T.ok(st(lhs, rhs))
	end)
	T.it("discriminated-union narrowing structurally", function()
		-- ({tag:\"a\"} | {tag:\"b\"}) & ~{tag:\"a\"} <: {tag:\"b\"}.
		-- The first disjunct cancels with its negation; the second survives.
		local ka = V.literal("string", "a")
		local kb = V.literal("string", "b")
		local ra = V.rec({ tag = ka }, false)
		local rb = V.rec({ tag = kb }, false)
		T.ok(st(V.inter({ V.union({ra, rb}), V.neg(ra) }), rb))
	end)
end)

T.describe("negation — recursive types (μ)", function()
	T.it("~(μX. F(X)) is constructible and never <: that", function()
		-- We do not push ¬ inside μ; μ stays an atom. Sanity: never <: ¬μ,
		-- and μ </: ¬μ (a value of type μ is not in the complement of μ).
		local list = V.fix(function(self)
			return V.rec({ value = V.integer, next = self }, false)
		end)
		local nlist = V.neg(list)
		T.ok(st(V.bot(), nlist))
		T.fail(st(list, nlist))
	end)
end)

T.describe("negation — indexed-access interaction", function()
	-- Negated key on indexed access is admitted by the design (§1.1) but
	-- the index reducer does not yet handle ~K (deferred to a later phase
	-- where match-type wildcards force it in). The negation infrastructure
	-- itself is exercised via the subtype path on already-indexed types.
	T.it("indexed access result interacts with ~T at the type level", function()
		-- T = { x: integer }; T[\"x\"] = integer; integer <: ~string.
		local r = V.rec({ x = V.integer }, false)
		local got, err = V.index(r, V.literal("string", "x"))
		T.eq(err, nil)
		T.ok(st(got, V.neg(V.string_)))
	end)
end)

T.describe("negation — DNF normalization (worst-case structural)", function()
	T.it("nested negation/union does not loop", function()
		-- ~((A & ~B) | (C & ~D)) is reduced to (~A | B) & (~C | D) by De
		-- Morgan, then to a (4-way) DNF for emptiness checks. We don't
		-- assert the shape — only that subtype queries on such inputs
		-- terminate in finite time and produce correct answers.
		local A, B, C, D = V.integer, V.string_, V.number, V.boolean
		local lhs = V.neg(V.union({ V.inter({A, V.neg(B)}), V.inter({C, V.neg(D)}) }))
		-- This type is huge but still satisfies trivial bounds:
		T.ok(st(V.bot(), lhs))
		T.ok(st(lhs, V.top()))
	end)
end)

-- ── Phase 4d: match types ─────────────────────────────────────────────────

T.describe("match — forward evaluation", function()
	-- Shared literal instances so identity comparisons in tests succeed
	-- (V.literal builds a fresh table per call).
	local L_TRUE  = V.literal("boolean", true)
	local L_FALSE = V.literal("boolean", false)

	T.it("ground subject hits exactly one arm (IsString<string>)", function()
		-- IsString<T> = match T { string => true, _ => false }
		local arms = { V.arm(V.string_, L_TRUE) }
		local r, err = V.match(V.string_, arms, L_FALSE)
		T.eq(err, nil)
		T.eq(r, L_TRUE)
	end)

	T.it("ground subject hits the wildcard (IsString<integer>)", function()
		local arms = { V.arm(V.string_, L_TRUE) }
		local r, err = V.match(V.integer, arms, L_FALSE)
		T.eq(err, nil)
		T.eq(r, L_FALSE)
	end)

	T.it("literal subject fires the primitive-typed arm (\"x\" <: string)", function()
		local arms = { V.arm(V.string_, L_TRUE) }
		local r, err = V.match(V.literal("string", "x"), arms, L_FALSE)
		T.eq(err, nil)
		T.eq(r, L_TRUE)
	end)
end)

T.describe("match — disjointness check", function()
	T.it("overlapping non-wildcard arms rejected at construction", function()
		-- number and integer overlap (integer <: number), so they are NOT
		-- disjoint.
		local arms = {
			V.arm(V.number, V.literal("integer", 1)),
			V.arm(V.integer, V.literal("integer", 2)),
		}
		local r, err = V.match(V.integer, arms, nil)
		T.eq(r, nil)
		T.ok(err and err:find("not disjoint", 1, true) ~= nil,
			"expected disjointness error, got: " .. tostring(err))
	end)

	T.it("disjoint arms pass the check", function()
		-- string and integer are disjoint (different primitive kinds).
		local L1, L2 = V.literal("integer", 1), V.literal("integer", 2)
		local arms = {
			V.arm(V.string_, L1),
			V.arm(V.integer, L2),
		}
		local r, err = V.match(V.integer, arms, nil)
		T.eq(err, nil)
		T.eq(r, L2)
	end)
end)

T.describe("match — multiple arms + wildcard", function()
	-- Three pairwise-disjoint arms covering string, integer, and boolean, with
	-- a wildcard for the rest. Shared literal instances so tests can compare
	-- by identity.
	local L_S = V.literal("string", "s")
	local L_I = V.literal("string", "i")
	local L_B = V.literal("string", "b")
	local L_O = V.literal("string", "other")
	local arms = {
		V.arm(V.string_, L_S),
		V.arm(V.integer, L_I),
		V.arm(V.boolean, L_B),
	}

	T.it("each arm fires independently", function()
		local r1 = ({V.match(V.string_, arms, L_O)})[1]
		local r2 = ({V.match(V.integer, arms, L_O)})[1]
		local r3 = ({V.match(V.boolean, arms, L_O)})[1]
		T.eq(r1, L_S)
		T.eq(r2, L_I)
		T.eq(r3, L_B)
	end)

	T.it("subject in none of the arms hits the wildcard", function()
		-- nil is not in string, integer, or boolean → wildcard.
		local r, err = V.match(V.nil_, arms, L_O)
		T.eq(err, nil)
		T.eq(r, L_O)
	end)
end)

T.describe("match — backward evaluation", function()
	T.it("known result picks the firing arm's pattern", function()
		-- IsString<T> = match T { string => true, _ => false }
		-- backward(true) = string. backward(false) = ~string.
		local L_T = V.literal("boolean", true)
		local L_F = V.literal("boolean", false)
		local arms = { V.arm(V.string_, L_T) }
		local wild = L_F
		local rt, et = V.match_backward(arms, wild, L_T)
		T.eq(et, nil)
		T.eq(rt, V.string_)
		local rf, ef = V.match_backward(arms, wild, L_F)
		T.eq(ef, nil)
		-- The wildcard pattern is ~(string). Single contribution → that pattern.
		T.ok(rf ~= nil and rf.tag == "neg",
			"expected ~string, got: " .. V.show(rf))
		T.eq(rf and rf.body, V.string_)
	end)

	T.it("incompatible expected result yields the empty contribution error", function()
		-- arms produce only "s" or "i"; expected "z" matches neither.
		local arms = {
			V.arm(V.string_, V.literal("string", "s")),
			V.arm(V.integer, V.literal("string", "i")),
		}
		local r, err = V.match_backward(arms, nil, V.literal("string", "z"))
		T.eq(r, nil)
		T.neq(err, nil)
	end)
end)

T.describe("match — captures", function()
	T.it("forward capture witnesses the structural fragment", function()
		-- match T { { value: %V } => %V, _ => nil }
		local cap = V.var("V")
		local arms = { V.arm(V.rec({ value = cap }, false), cap, { cap }) }
		local subj = V.rec({ value = V.integer }, false)
		local r, err = V.match(subj, arms, V.nil_)
		T.eq(err, nil)
		-- Result is a freshened capture var with integer as a lower bound.
		T.ok(r ~= nil and r.tag == "var", "expected fresh var, got: " .. V.show(r))
		T.eq(#r.lower, 1)
		T.eq(r.lower[1], V.integer)
	end)

	T.it("backward capture constrains the subject", function()
		-- match T { { value: %V } => %V, _ => nil }
		-- backward(integer) should yield { value: integer } (capture flows).
		local cap = V.var("V")
		local arms = { V.arm(V.rec({ value = cap }, false), cap, { cap }) }
		local r, err = V.match_backward(arms, V.nil_, V.integer)
		T.eq(err, nil)
		-- Expected result <: nil is "never"; expected <: %V is "fires" (V
		-- gets a lower bound of integer). The contribution is the pattern
		-- { value: %V } with V bound to integer.
		T.ok(r ~= nil, "expected non-nil result")
		-- Should be the pattern (no union with the wildcard since wildcard
		-- result nil is disjoint from integer).
		T.ok(r ~= nil and r.tag == "rec",
			"expected record pattern, got: " .. V.show(r))
	end)
end)

T.describe("match — recursive patterns and subjects", function()
	T.it("μ subject matches an open-record pattern", function()
		-- list = μX. { value: integer, next: X }. Match against pattern
		-- { value: integer, ... } — fires; otherwise → "other".
		local L_L = V.literal("string", "list")
		local L_O = V.literal("string", "other")
		local list = V.fix(function(self)
			return V.rec({ value = V.integer, next = self }, false)
		end)
		local arms = { V.arm(V.rec({ value = V.integer }, true), L_L) }
		local r, err = V.match(list, arms, L_O)
		T.eq(err, nil)
		T.eq(r, L_L)
	end)
end)

T.describe("match — union distribution", function()
	T.it("union subject distributes member-wise", function()
		-- IsString<integer | string> = match (integer | string) { ... }
		-- = IsString<integer> | IsString<string> = false | true.
		local arms = { V.arm(V.string_, V.literal("boolean", true)) }
		local wild = V.literal("boolean", false)
		local r, err = V.match(V.union({ V.integer, V.string_ }), arms, wild)
		T.eq(err, nil)
		T.ok(r ~= nil and r.tag == "union",
			"expected union, got: " .. V.show(r))
		local saw_t, saw_f = false, false
		for _, m in ipairs(r.members) do
			if m == V.literal("boolean", true)  then saw_t = true end
			if m == V.literal("boolean", false) then saw_f = true end
		end
		-- Identity equality won't fire (literals are fresh tables). Check by
		-- structural inspection.
		saw_t, saw_f = false, false
		for _, m in ipairs(r.members) do
			if m.tag == "literal" and m.base == "boolean" and m.value == true  then saw_t = true end
			if m.tag == "literal" and m.base == "boolean" and m.value == false then saw_f = true end
		end
		T.ok(saw_t, "missing true member: " .. V.show(r))
		T.ok(saw_f, "missing false member: " .. V.show(r))
	end)
end)

T.describe("match — suspension", function()
	T.it("unbound variable subject rejects loudly (no suspension queue)", function()
		-- Per design §5.3, the principled handling is suspension. 4d does not
		-- expose the general suspension mechanism (it is shared with deferred
		-- indexed access, 4b.2). The principled fallback is reject-loudly —
		-- not a one-off pending-match queue. See CLAUDE.md
		-- "Ad-hoc conditions are strictly forbidden".
		local v = V.var("x")
		local arms = { V.arm(V.string_, V.literal("boolean", true)) }
		local r, err = V.match(v, arms, V.literal("boolean", false))
		T.eq(r, nil)
		T.ok(err and err:find("suspended", 1, true) ~= nil
		      or err and err:find("deferred", 1, true) ~= nil,
			"expected deferred/suspended error, got: " .. tostring(err))
	end)
end)

T.describe("match — _ as sugar for complement", function()
	T.it("wildcard reaches the negated-union backward", function()
		-- Two-arm match: string → "s", integer → "i", _ → "other".
		-- backward("other") should produce ~(string | integer).
		local arms = {
			V.arm(V.string_, V.literal("string", "s")),
			V.arm(V.integer, V.literal("string", "i")),
		}
		local r, err = V.match_backward(arms, V.literal("string", "other"), V.literal("string", "other"))
		T.eq(err, nil)
		-- The result should be ~(string | integer) (i.e. a neg of a union).
		T.ok(r ~= nil and r.tag == "neg",
			"expected ~union, got: " .. V.show(r))
		T.ok(r ~= nil and r.body.tag == "union",
			"expected ~(union), got: " .. V.show(r))
	end)

	T.it("wildcard arm dispatches via emptiness, not by special-casing", function()
		-- A subject disjoint from all explicit arms hits the wildcard. The
		-- wildcard's pattern is the v4 type ~(union of arms) — handled by the
		-- generic subtype path, not by any special wildcard branch. With three
		-- primitive-typed arms (string, integer, boolean) the wildcard pattern
		-- is ~(string ∪ integer ∪ boolean), and a subject of nil hits the
		-- wildcard via the same arm_outcome primitive used for the explicit
		-- arms — observable as the correct result with no special-case code
		-- path in match.lua.
		local L_S = V.literal("integer", 1)
		local L_I = V.literal("integer", 2)
		local L_B = V.literal("integer", 3)
		local L_O = V.literal("integer", 0)
		local arms = {
			V.arm(V.string_, L_S),
			V.arm(V.integer, L_I),
			V.arm(V.boolean, L_B),
		}
		local r, err = V.match(V.nil_, arms, L_O)
		T.eq(err, nil)
		T.eq(r, L_O)
	end)
end)

T.describe("match — discriminated-record dispatch", function()
	T.it("records with disjoint literal discriminants are disjoint arms", function()
		-- { tag: "a" } ∩ { tag: "b" } = ⊥ because no inhabitant can have
		-- tag = "a" and tag = "b" simultaneously. The same-kind record
		-- collision rule in empty.lua recognizes this; match-arm construction
		-- on two such patterns must therefore pass the disjointness check
		-- and forward-fire on the appropriate record.
		local L1 = V.literal("integer", 1)
		local L2 = V.literal("integer", 2)
		local L0 = V.literal("integer", 0)
		local arms = {
			V.arm(V.rec({ tag = V.literal("string", "a") }, false), L1),
			V.arm(V.rec({ tag = V.literal("string", "b") }, false), L2),
		}
		-- Subject `{ tag: "a" }` fires the first arm.
		local subj = V.rec({ tag = V.literal("string", "a") }, false)
		local r, err = V.match(subj, arms, L0)
		T.eq(err, nil)
		T.eq(r, L1)
		-- Subject `{ tag: "b" }` fires the second.
		local subj2 = V.rec({ tag = V.literal("string", "b") }, false)
		local r2, err2 = V.match(subj2, arms, L0)
		T.eq(err2, nil)
		T.eq(r2, L2)
	end)
end)

T.describe("match — worked design-doc example", function()
	T.it("(A | B | (A->B)) ∩ ~(A->B) <: A | B", function()
		-- This is the design doc §2.2 worked example, not literally a match
		-- expression but the kind of simplification a match arm's backward
		-- step relies on. It exercises the same machinery: distribution of
		-- intersection over union and self-cancellation of a function-shaped
		-- conjunct with its negation. The test already exists for the
		-- subtype path; reasserting here serves as the "match types rely on
		-- this" anchor.
		local A, B = V.integer, V.string_
		local fab = V.fn({A}, B)
		local lhs = V.inter({ V.union({A, B, fab}), V.neg(fab) })
		local rhs = V.union({A, B})
		T.ok(st(lhs, rhs))
	end)
end)

-- ── Rank-N polymorphism (Phase 4e) ───────────────────────────────────────

T.describe("forall — basic", function()
	T.it("(∀X. X -> X) <: (integer -> integer)", function()
		-- LHS forall instantiates to a fresh α; α -> α <: integer -> integer
		-- forces α = integer (contravariant param: integer <: α; covariant
		-- return: α <: integer). The constraint solver handles both.
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		T.ok(st(id_poly, V.fn({V.integer}, V.integer)))
	end)

	T.it("(integer -> integer) </: (∀X. X -> X)", function()
		-- RHS forall skolemizes: we'd need integer -> integer <: σ -> σ for an
		-- arbitrary σ. Contravariance gives σ <: integer (lower bound on σ),
		-- covariance gives integer <: σ (upper bound). Both flow back to σ's
		-- variable bounds — but σ is a skolem, not a variable, so neither
		-- direction holds. The subsumption fails.
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		T.fail(st(V.fn({V.integer}, V.integer), id_poly))
	end)

	T.it("(∀X. X -> X) <: (string -> string)", function()
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		T.ok(st(id_poly, V.fn({V.string_}, V.string_)))
	end)

	T.it("(∀X. X -> integer) <: (string -> integer)", function()
		-- Bound var only in negative position; instantiation gives α -> integer
		-- and α gets upper-bounded by string from contravariance.
		local poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, V.integer)
		end)
		T.ok(st(poly, V.fn({V.string_}, V.integer)))
	end)
end)

T.describe("forall — skolem distinctness", function()
	T.it("(∀X. ∀Y. X -> Y) </: (∀X. X -> X) — would force two skolems equal", function()
		-- Skolemize RHS once: prove `∀X. ∀Y. X -> Y <: σ_R -> σ_R`. Instantiate
		-- LHS: α -> β <: σ_R -> σ_R. Contravariant: σ_R <: α (skolem lower-
		-- bound — only itself satisfies). Covariant: β <: σ_R. So α = β = σ_R.
		-- But α and β were introduced as independent fresh vars by the doubly-
		-- nested LHS forall; the system is satisfiable! Actually this DOES
		-- hold — verifying.
		local rhs = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		local lhs = V.forall({"X", "Y"}, function(vs)
			local x, y = vs[1], vs[2]
			if x == nil or y == nil then return V.top() end
			return V.fn({x}, y)
		end)
		-- LHS is more polymorphic; usable wherever a less-polymorphic value
		-- is required. So this *does* hold.
		T.ok(st(lhs, rhs))
	end)

	T.it("(∀X. X -> X) </: (∀X. ∀Y. X -> Y) — would constrain output to skolem-1", function()
		-- Skolemize RHS first: prove `∀X. X -> X <: σ_X -> σ_Y` for distinct
		-- skolems σ_X and σ_Y. Instantiate LHS: α -> α. Contravariant param:
		-- σ_X <: α. Covariant ret: α <: σ_Y. Transitively σ_X <: σ_Y — two
		-- distinct skolems, fails.
		local lhs = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		local rhs = V.forall({"X", "Y"}, function(vs)
			local x, y = vs[1], vs[2]
			if x == nil or y == nil then return V.top() end
			return V.fn({x}, y)
		end)
		T.fail(st(lhs, rhs))
	end)
end)

T.describe("forall — higher rank", function()
	T.it("rank-2: ((∀X. X -> X) -> string) <: ((integer -> integer) -> string)", function()
		-- The polymorphic argument type appears in contravariant position of
		-- the outer arrow. The supertype's argument is monomorphic; the
		-- subtype demands a polymorphic argument. Anything passed to the
		-- subtype must work for ALL X, so it must work for integer in
		-- particular — meaning a `(integer -> integer) -> string` accepts
		-- fewer values than `(∀X. X -> X) -> string`. Subtyping flips: the
		-- subtype is the more-polymorphic-arg version, since contravariance
		-- inverts the relation between forall and concrete.
		-- I.e. (∀X. X -> X) <: (integer -> integer), so by contravariance
		-- ((integer -> integer) -> string) <: ((∀X. X -> X) -> string), NOT
		-- the other direction. Test the correct direction:
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		local outer_mono = V.fn({V.fn({V.integer}, V.integer)}, V.string_)
		local outer_poly = V.fn({id_poly}, V.string_)
		-- The function that accepts ANY argument-shape is a subtype of the
		-- function that accepts only polymorphic functions.
		T.ok(st(outer_mono, outer_poly))
	end)

	T.it("rank-3: (∀X. (∀Y. X -> Y -> Y)) <: (integer -> ∀Y. Y -> Y)", function()
		-- LHS instantiates X to fresh α; body becomes (∀Y. α -> Y -> Y).
		-- That should subsume against (integer -> ∀Y. Y -> Y). The outer
		-- function-subtype rule: contravariant param: integer <: α; covariant
		-- return: (∀Y. α -> Y -> Y).ret_after_first_arg ... actually the body
		-- is itself a function (∀Y. α -> Y -> Y) — a forall returning a
		-- function. After instantiating X, we have (∀Y. α -> Y -> Y) which
		-- is itself a curried 2-arg form. Restructure the test more directly.
		local lhs = V.forall({"X"}, function(vs1)
			local x = vs1[1]
			if x == nil then return V.top() end
			return V.forall({"Y"}, function(vs2)
				local y = vs2[1]
				if y == nil then return V.top() end
				return V.fn({x, y}, y)
			end)
		end)
		-- After instantiating X = integer, we get (∀Y. (integer, Y) -> Y).
		local rhs = V.forall({"Y"}, function(vs)
			local y = vs[1]
			if y == nil then return V.top() end
			return V.fn({V.integer, y}, y)
		end)
		T.ok(st(lhs, rhs))
	end)

	T.it("rank-2 in argument position with chained foralls", function()
		-- `((∀X. ∀Y. X -> Y -> X) -> string) <: ((∀X. X -> X -> X) -> string)`
		-- Inner LHS is more polymorphic than inner RHS; by contravariance
		-- the outer relation flips.
		local inner_poly = V.forall({"X", "Y"}, function(vs)
			local x, y = vs[1], vs[2]
			if x == nil or y == nil then return V.top() end
			return V.fn({x, y}, x)
		end)
		local inner_less_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x, x}, x)
		end)
		-- inner_poly <: inner_less_poly (specializing Y to X)
		T.ok(st(inner_poly, inner_less_poly))
		-- so by contravariance: (inner_less_poly -> string) <: (inner_poly -> string)
		T.ok(st(V.fn({inner_less_poly}, V.string_), V.fn({inner_poly}, V.string_)))
	end)
end)

T.describe("forall — skolem escape check", function()
	T.it("(α -> α) </: (∀X. X -> X) when α is a pre-existing free var", function()
		-- α is a free variable from outer scope. If we were to admit
		-- `α -> α <: ∀X. X -> X`, instantiating later (e.g. with α = integer)
		-- would falsify the polymorphism claim. Skolemization detects this:
		-- RHS skolemizes to σ -> σ; subsumption pushes σ <: α and α <: σ as
		-- bounds on α; the escape check on LHS walks α's bounds and finds σ.
		local a = V.var("α")
		local fa_a = V.fn({a}, a)
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		local ok, err = V.subtype(fa_a, id_poly)
		T.fail(ok, err)
		T.ok(err ~= nil and err:find("escape"), "expected escape error, got: " .. tostring(err))
	end)

	T.it("(integer -> integer) <: (∀X. X -> X) fails without skolem escape (ground LHS)", function()
		-- No free vars to escape into, but the subsumption still fails for
		-- the integer-not-<:-σ reason (concrete type does not match an
		-- arbitrary skolem).
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		T.fail(st(V.fn({V.integer}, V.integer), id_poly))
	end)
end)

T.describe("forall — interaction with μ", function()
	T.it("(∀X. μ Y. X | { next: Y }) constructs and subsumes by reflexivity", function()
		local poly_list = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fix(function(self)
				return V.union({ x, V.rec({ next = self }, false) })
			end)
		end)
		-- Reflexive subtype: the same forall against itself. Goes through
		-- skolemize-on-RHS + instantiate-on-LHS, the body recurses into μ,
		-- and the cache short-circuits the cycle.
		T.ok(st(poly_list, poly_list))
	end)
end)

T.describe("forall — used at two concrete types", function()
	T.it("(∀X. X -> X) instantiated twice yields independent var graphs", function()
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		-- One instantiation at integer.
		T.ok(st(id_poly, V.fn({V.integer}, V.integer)))
		-- Another at string. Each call re-instantiates with fresh vars, so
		-- the two queries do not entangle.
		T.ok(st(id_poly, V.fn({V.string_}, V.string_)))
	end)
end)

T.describe("forall — indexed-access body", function()
	T.it("(∀X. { value: X, next: X })[\"value\"] reduces after instantiation", function()
		-- The forall is itself not directly indexable (index.lua doesn't have
		-- a forall case), but instantiating first then indexing works.
		local poly_rec = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.rec({ value = x, next = x }, false)
		end)
		local body = V.instantiate(poly_rec)
		local r, err = V.index(body, V.literal("string", "value"))
		T.eq(err, nil)
		T.ok(r ~= nil, "expected non-nil index result")
		-- The result is a fresh free var (from instantiation).
		T.ok(r ~= nil and r.tag == "var", "expected var, got " .. V.show(r))
	end)
end)

T.describe("forall — in match arms", function()
	T.it("a match arm result template may be a forall", function()
		-- A subject matches an arm whose result is a polymorphic identity.
		-- The forward evaluator should hand the forall back verbatim (it is
		-- not instantiated by match — instantiation happens at the call site
		-- of the polymorphic value, not at match-evaluation time).
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		local arms = {
			V.arm(V.string_, id_poly),
			V.arm(V.integer, V.fn({V.integer}, V.integer)),
		}
		local r, err = V.match(V.string_, arms, V.nil_)
		T.eq(err, nil)
		T.eq(r, id_poly)
	end)
end)

T.describe("forall — impredicativity", function()
	T.it("a forall body may itself contain a forall in a field (impredicative)", function()
		-- A record field typed by a forall. Full rank-N admits this in the
		-- type *representation*; subtyping treats the forall atomically when
		-- comparing field types, with the same skolemize/instantiate rules
		-- triggered by the recursive descent through record subtyping.
		local id_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		local r1 = V.rec({ id = id_poly }, false)
		local r2 = V.rec({ id = V.fn({V.integer}, V.integer) }, false)
		-- r1.id is more polymorphic than r2.id, so r1 <: r2 (covariant field).
		T.ok(st(r1, r2))
		-- The other direction fails (concrete cannot impersonate poly).
		T.fail(st(r2, r1))
	end)
end)

-- ── Phase 4f: effects ─────────────────────────────────────────────────────

T.describe("effects — constructor", function()
	T.it("pure function has empty effect set", function()
		local f = V.fn({V.integer}, V.integer)
		T.eq(next(f.effects), nil)
	end)
	T.it("effect-bearing function records the effects", function()
		local f = V.fn({V.integer}, V.integer, {"yield"})
		T.eq(f.effects.yield, true)
		T.eq(f.effects.throw, nil)
	end)
	T.it("effects can be passed as a set or a list", function()
		local f1 = V.fn({}, V.nil_, { yield = true, throw = true })
		local f2 = V.fn({}, V.nil_, { "yield", "throw" })
		T.eq(f1.effects.yield, true)
		T.eq(f1.effects.throw, true)
		T.eq(f2.effects.yield, true)
		T.eq(f2.effects.throw, true)
	end)
	T.it("unknown effect rejected at construction", function()
		local ok = pcall(V.fn, {}, V.nil_, { "boom" })
		T.fail(ok)
	end)
end)

T.describe("effects — subtype", function()
	T.it("pure <: effect-bearing (same params/ret)", function()
		local pure = V.fn({V.integer}, V.integer)
		local yfn  = V.fn({V.integer}, V.integer, {"yield"})
		T.ok(st(pure, yfn))
	end)
	T.it("effect-bearing NOT <: pure", function()
		local pure = V.fn({V.integer}, V.integer)
		local yfn  = V.fn({V.integer}, V.integer, {"yield"})
		T.fail(st(yfn, pure))
	end)
	T.it("yield-only <: {yield, throw}", function()
		local a = V.fn({V.integer}, V.integer, {"yield"})
		local b = V.fn({V.integer}, V.integer, {"yield", "throw"})
		T.ok(st(a, b))
	end)
	T.it("{yield, throw} NOT <: yield-only", function()
		local a = V.fn({V.integer}, V.integer, {"yield", "throw"})
		local b = V.fn({V.integer}, V.integer, {"yield"})
		T.fail(st(a, b))
	end)
	T.it("same effect set: reflexive", function()
		local a = V.fn({V.integer}, V.integer, {"yield"})
		local b = V.fn({V.integer}, V.integer, {"yield"})
		T.ok(st(a, b))
		T.ok(st(b, a))
	end)
end)

T.describe("effects — higher-order contravariance", function()
	T.it("contravariance flips the effect-set subtype direction", function()
		-- Inner: a-effect <: b-effect means a-fn <: b-fn (covariant in effects).
		-- Outer (the inner sits in contravariant position): the relation flips.
		-- Concretely: ((A -[yield]-> B) -> C) <: ((A -[]-> B) -> C) because the
		-- subtype's argument accepts a STRICTLY WIDER class of inputs (it can
		-- consume yielding functions too) than the supertype's argument needs.
		local inner_pure  = V.fn({V.integer}, V.integer)
		local inner_yield = V.fn({V.integer}, V.integer, {"yield"})
		-- inner_pure <: inner_yield is the covariant direction.
		T.ok(st(inner_pure, inner_yield))
		-- So by contravariance:
		--   (inner_yield -> string) <: (inner_pure -> string)
		T.ok(st(V.fn({inner_yield}, V.string_), V.fn({inner_pure}, V.string_)))
		-- And the reverse direction fails.
		T.fail(st(V.fn({inner_pure}, V.string_), V.fn({inner_yield}, V.string_)))
	end)
end)

T.describe("effects — inside other type constructors", function()
	T.it("effect-bearing arrow inside a forall", function()
		-- (∀X. X -[yield]-> X) <: (integer -[yield]-> integer)
		local poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x, {"yield"})
		end)
		T.ok(st(poly, V.fn({V.integer}, V.integer, {"yield"})))
		-- And the same forall is NOT <: a pure arrow at the same shape.
		T.fail(st(poly, V.fn({V.integer}, V.integer)))
		-- A pure forall IS <: an effect-bearing concrete instance.
		local pure_poly = V.forall({"X"}, function(vs)
			local x = vs[1]
			if x == nil then return V.top() end
			return V.fn({x}, x)
		end)
		T.ok(st(pure_poly, V.fn({V.integer}, V.integer, {"yield"})))
	end)
	T.it("effect-bearing arrow inside a record (covariant field)", function()
		local yfn  = V.fn({V.integer}, V.integer, {"yield"})
		local pure = V.fn({V.integer}, V.integer)
		local r1 = V.rec({ f = pure }, false)
		local r2 = V.rec({ f = yfn  }, false)
		-- r1.f (pure) <: r2.f (yield-bearing) by effect covariance.
		T.ok(st(r1, r2))
		T.fail(st(r2, r1))
	end)
	T.it("effect-bearing arrow inside a union", function()
		-- (integer -[yield]-> integer) <: (integer -[yield, throw]-> integer)
		--   | string. Holds because the LHS satisfies the first disjunct.
		local lhs = V.fn({V.integer}, V.integer, {"yield"})
		local rhs = V.union({
			V.fn({V.integer}, V.integer, {"yield", "throw"}),
			V.string_,
		})
		T.ok(st(lhs, rhs))
	end)
end)

T.describe("effects — pretty print", function()
	T.it("pure arrow renders without effect annotation", function()
		local s = V.show(V.fn({V.integer}, V.string_))
		T.eq(s, "(integer) -> string")
	end)
	T.it("yield arrow renders with -[yield]->", function()
		local s = V.show(V.fn({V.integer}, V.string_, {"yield"}))
		T.eq(s, "(integer) -[yield]-> string")
	end)
	T.it("multi-effect arrow renders deterministically (sorted)", function()
		local s = V.show(V.fn({V.integer}, V.string_, {"throw", "yield"}))
		T.eq(s, "(integer) -[throw, yield]-> string")
	end)
end)

-- ── Phase 4g: content-addressed cache ────────────────────────────────────

-- Structural equality predicate. Round-trip equality cannot use the subtype
-- predicate as a witness: v4's solver has known limitations around prim/skolem
-- comparisons across distinct table instances, and a deserialized type is by
-- construction a new tree. Structural eq compares trees up to:
--   - vars/μ-nodes by serialization-position correspondence (a bijection
--     `seen` mapping LHS-id → RHS-id, built up as we walk);
--   - skolems by their (locally minted) id correspondence;
--   - everything else by tag + same-shape recursion.
--: (V4Type, V4Type, { var_map: { [integer]: integer }, mu_map: { [integer]: integer }, sk_map: { [integer]: integer } }) -> boolean
local function streq_inner(a, b, ctx)
	-- Chained if/elseif on `a.tag` so the typechecker sees exhaustive
	-- narrowing on `a`. `b`'s tag is re-tested in each arm so that `b`'s
	-- structural access typechecks (an unrelated b.tag would imply the
	-- types are not structurally equal — return false).
	if a.tag == "top" then return b.tag == "top"
	elseif a.tag == "bot" then return b.tag == "bot"
	elseif a.tag == "prim" then
		if b.tag == "prim" then return a.name == b.name else return false end
	elseif a.tag == "literal" then
		if b.tag == "literal" then
			if a.base ~= b.base then return false end
			return a.value == b.value
		else return false end
	elseif a.tag == "fn" then
		if b.tag == "fn" then
			if #a.params ~= #b.params then return false end
			for i = 1, #a.params do
				local ap = a.params[i]; local bp = b.params[i]
				if ap == nil or bp == nil then return false end
				if not streq_inner(ap, bp, ctx) then return false end
			end
			if not streq_inner(a.ret, b.ret, ctx) then return false end
			for k in pairs(a.effects) do if not b.effects[k] then return false end end
			for k in pairs(b.effects) do if not a.effects[k] then return false end end
			return true
		else return false end
	elseif a.tag == "rec" then
		if b.tag == "rec" then
			if a.open ~= b.open then return false end
			for k, v in pairs(a.fields) do
				local bv = b.fields[k]
				if v == nil or bv == nil then return false end
				if not streq_inner(v, bv, ctx) then return false end
			end
			for k in pairs(b.fields) do
				if a.fields[k] == nil then return false end
			end
			local ai, bi = a.indexer, b.indexer
			if (ai == nil) ~= (bi == nil) then return false end
			if ai ~= nil and bi ~= nil then
				if not streq_inner(ai.key, bi.key, ctx) then return false end
				if not streq_inner(ai.value, bi.value, ctx) then return false end
			end
			return true
		else return false end
	elseif a.tag == "union" then
		if b.tag == "union" then
			if #a.members ~= #b.members then return false end
			for i = 1, #a.members do
				local am = a.members[i]; local bm = b.members[i]
				if am == nil or bm == nil then return false end
				if not streq_inner(am, bm, ctx) then return false end
			end
			return true
		else return false end
	elseif a.tag == "inter" then
		if b.tag == "inter" then
			if #a.members ~= #b.members then return false end
			for i = 1, #a.members do
				local am = a.members[i]; local bm = b.members[i]
				if am == nil or bm == nil then return false end
				if not streq_inner(am, bm, ctx) then return false end
			end
			return true
		else return false end
	elseif a.tag == "neg" then
		if b.tag == "neg" then return streq_inner(a.body, b.body, ctx) else return false end
	elseif a.tag == "mu" then
		if b.tag == "mu" then
			local existing = ctx.mu_map[a.id]
			if existing ~= nil then return existing == b.id end
			ctx.mu_map[a.id] = b.id
			return streq_inner(a.body, b.body, ctx)
		else return false end
	elseif a.tag == "var" then
		if b.tag == "var" then
			local existing = ctx.var_map[a.id]
			if existing ~= nil then return existing == b.id end
			ctx.var_map[a.id] = b.id
			if #a.lower ~= #b.lower then return false end
			if #a.upper ~= #b.upper then return false end
			for i = 1, #a.lower do
				local av = a.lower[i]; local bv = b.lower[i]
				if av == nil or bv == nil then return false end
				if not streq_inner(av, bv, ctx) then return false end
			end
			for i = 1, #a.upper do
				local av = a.upper[i]; local bv = b.upper[i]
				if av == nil or bv == nil then return false end
				if not streq_inner(av, bv, ctx) then return false end
			end
			return true
		else return false end
	elseif a.tag == "forall" then
		if b.tag == "forall" then
			if #a.vars ~= #b.vars then return false end
			for i = 1, #a.vars do
				local av = a.vars[i]; local bv = b.vars[i]
				if av == nil or bv == nil then return false end
				if not streq_inner(av, bv, ctx) then return false end
			end
			return streq_inner(a.body, b.body, ctx)
		else return false end
	else  -- a.tag == "skolem"
		if b.tag == "skolem" then
			local existing = ctx.sk_map[a.id]
			if existing ~= nil then return existing == b.id end
			ctx.sk_map[a.id] = b.id
			return a.name == b.name
		else return false end
	end
end

--: (V4Type, V4Type) -> boolean
local function streq(a, b)
	return streq_inner(a, b, {
		var_map = {} --[[: { [integer]: integer } ]],
		mu_map  = {} --[[: { [integer]: integer } ]],
		sk_map  = {} --[[: { [integer]: integer } ]],
	})
end

--: (V4Type) -> nil
local function roundtrip(t)
	local bytes = V.serialize(t)
	local got, err = V.deserialize(bytes)
	T.eq(err, nil)
	T.ok(got ~= nil, "deserialize returned nil")
	if got == nil then return end
	T.ok(streq(t, got --[[: V4Type]]), "round-trip not structurally equal: " ..
		V.show(t) .. " vs " .. V.show(got --[[: V4Type]]))
end

T.describe("4g — serialization round-trip", function()
	T.it("top, bot", function()
		roundtrip(V.top())
		roundtrip(V.bot())
	end)
	T.it("primitives", function()
		roundtrip(V.number); roundtrip(V.integer); roundtrip(V.string_)
		roundtrip(V.boolean); roundtrip(V.nil_); roundtrip(V.cdata)
	end)
	T.it("literals: nil, boolean, integer, number, string", function()
		roundtrip(V.literal("nil", nil))
		roundtrip(V.literal("boolean", true))
		roundtrip(V.literal("boolean", false))
		roundtrip(V.literal("integer", 42))
		roundtrip(V.literal("number", 3.14))
		roundtrip(V.literal("string", "hi"))
		-- Edge values that the %.17g round-trip must preserve.
		roundtrip(V.literal("number", -0.0))
		roundtrip(V.literal("number", 1e308))
		-- Embedded NUL — confirms length-prefixed strings don't terminate.
		roundtrip(V.literal("string", "a\0b\0c"))
	end)
	T.it("functions: pure and effectful", function()
		roundtrip(V.fn({V.integer}, V.string_))
		roundtrip(V.fn({V.integer, V.string_}, V.boolean, {"yield"}))
		roundtrip(V.fn({}, V.bot(), {"throw", "yield"}))
	end)
	T.it("records: closed, open, with indexer", function()
		roundtrip(V.rec({ x = V.integer, y = V.string_ }, false))
		roundtrip(V.rec({ a = V.number }, true))
		roundtrip(V.rec({}, false, V.indexer(V.string_, V.boolean)))
		roundtrip(V.rec({ tag = V.literal("string", "a") }, false,
			V.indexer(V.string_, V.integer)))
	end)
	T.it("union, inter", function()
		roundtrip(V.union({V.integer, V.string_}))
		roundtrip(V.inter({V.rec({ x = V.integer }, true),
		                   V.rec({ y = V.string_ }, true)}))
	end)
	T.it("negation", function()
		roundtrip(V.neg(V.integer))
		roundtrip(V.neg(V.union({V.integer, V.string_})))
	end)
	T.it("μ types preserve cyclic structure", function()
		-- μX. { value: integer, next: X }
		local list = V.fix(function(self)
			return V.rec({ value = V.integer, next = self }, false)
		end)
		local bytes = V.serialize(list)
		local got, err = V.deserialize(bytes)
		T.eq(err, nil)
		T.ok(got ~= nil)
		if got == nil then return end
		-- Identity-share check: the μ's body's `next` field must be the same
		-- table as the μ node itself, not a fresh copy. The cycle MUST be
		-- preserved by table identity, or the resulting structure has
		-- infinite depth.
		T.ok(got.tag == "mu", "outer is μ")
		if got.tag == "mu" then
			local body = got.body
			T.ok(body.tag == "rec")
			if body.tag == "rec" then
				T.ok(body.fields["next"] == got, "cycle preserved by identity")
			end
		end
		-- Structural round-trip.
		T.ok(streq(list, got --[[: V4Type]]))
	end)
	T.it("var with bounds", function()
		local a = V.var("α")
		a.lower[1] = V.integer
		a.upper[1] = V.number
		roundtrip(a)
	end)
	T.it("var with self-referencing bound (cycle in var bound list)", function()
		-- A var that appears in its own bounds (transitive closure step).
		local a = V.var("α")
		a.lower[1] = V.union({V.integer, a})
		roundtrip(a)
	end)
	T.it("forall (rank-1)", function()
		-- ∀X. X → X
		local f = V.forall({"X"}, function(vars)
			return V.fn({vars[1]}, vars[1])
		end)
		roundtrip(f)
	end)
	T.it("forall (rank-2 / impredicative)", function()
		-- (∀X. X → X) → string
		local inner = V.forall({"X"}, function(vars)
			return V.fn({vars[1]}, vars[1])
		end)
		roundtrip(V.fn({inner}, V.string_))
	end)
	T.it("skolem", function()
		local sk = V.skolem("S")
		roundtrip(sk)
	end)
	T.it("match-via-neg: complement of a union", function()
		roundtrip(V.neg(V.union({V.literal("string", "a"),
		                         V.literal("string", "b")})))
	end)
	T.it("nested: forall of fn returning union of records", function()
		local t = V.forall({"X"}, function(vars)
			return V.fn({vars[1]}, V.union({
				V.rec({ tag = V.literal("string", "ok"), value = vars[1] }, false),
				V.rec({ tag = V.literal("string", "err"), message = V.string_ }, false),
			}))
		end)
		roundtrip(t)
	end)
end)

T.describe("4g — content hash determinism", function()
	T.it("same type → same hash regardless of field-insertion order", function()
		-- Two record literals with the same fields in different orders. v4's
		-- `rec` doesn't care about insertion order, but `pairs(t.fields)`
		-- *does* iterate in hash-bucket order. The serializer sorts keys
		-- before emitting, so both hashes must match.
		local a = V.rec({ x = V.integer, y = V.string_, z = V.boolean }, false)
		local b = V.rec({ z = V.boolean, y = V.string_, x = V.integer }, false)
		T.eq(V.content_hash(V.serialize(a)), V.content_hash(V.serialize(b)))
	end)
	T.it("same effect set → same hash regardless of order", function()
		local a = V.fn({V.integer}, V.string_, {"yield", "throw"})
		local b = V.fn({V.integer}, V.string_, {"throw", "yield"})
		T.eq(V.content_hash(V.serialize(a)), V.content_hash(V.serialize(b)))
	end)
	T.it("hash is 64 lowercase-hex chars", function()
		local h = V.content_hash(V.serialize(V.integer))
		T.eq(#h, 64)
		T.ok(h:match("^[0-9a-f]+$") ~= nil)
	end)
end)

T.describe("4g — hash distinguishes structurally different types", function()
	T.it("integer vs string", function()
		local a = V.content_hash(V.serialize(V.integer))
		local b = V.content_hash(V.serialize(V.string_))
		T.neq(a, b)
	end)
	T.it("fn with vs without effects", function()
		local a = V.content_hash(V.serialize(V.fn({V.integer}, V.string_)))
		local b = V.content_hash(V.serialize(V.fn({V.integer}, V.string_, {"yield"})))
		T.neq(a, b)
	end)
	T.it("open vs closed record with same fields", function()
		local a = V.content_hash(V.serialize(V.rec({ x = V.integer }, false)))
		local b = V.content_hash(V.serialize(V.rec({ x = V.integer }, true)))
		T.neq(a, b)
	end)
	T.it("literal value distinguishes", function()
		local a = V.content_hash(V.serialize(V.literal("integer", 1)))
		local b = V.content_hash(V.serialize(V.literal("integer", 2)))
		T.neq(a, b)
	end)
end)

T.describe("4g — manifest round-trip", function()
	T.it("empty manifest", function()
		local m = { entries = {} --[[: { [string]: V4CacheEntry } ]] }
		local bytes = V.serialize_manifest(m)
		local got, err = V.deserialize_manifest(bytes)
		T.eq(err, nil)
		T.ok(got ~= nil)
	end)
	T.it("manifest with entries and deps round-trips", function()
		local m = {
			entries = {
				["abc123"] = { cri_hash = "deadbeef", deps = {
					["lib/foo.lua"] = "hash1",
					["lib/bar.lua"] = "hash2",
				} },
				["def456"] = { cri_hash = "cafef00d", deps = {} --[[: { [string]: string } ]] },
			} --[[: { [string]: V4CacheEntry } ]],
		}
		local bytes = V.serialize_manifest(m)
		local got, err = V.deserialize_manifest(bytes)
		T.eq(err, nil)
		T.ok(got ~= nil)
		if got == nil then return end
		T.eq(got.entries["abc123"].cri_hash, "deadbeef")
		T.eq(got.entries["abc123"].deps["lib/foo.lua"], "hash1")
		T.eq(got.entries["abc123"].deps["lib/bar.lua"], "hash2")
		T.eq(got.entries["def456"].cri_hash, "cafef00d")
	end)
	T.it("manifest serialization is deterministic across insertion order", function()
		local m1 = { entries = {
			["a"] = { cri_hash = "h1", deps = {} --[[: { [string]: string } ]] },
			["b"] = { cri_hash = "h2", deps = {} --[[: { [string]: string } ]] },
		} --[[: { [string]: V4CacheEntry } ]] }
		local m2 = { entries = {} --[[: { [string]: V4CacheEntry } ]] }
		m2.entries["b"] = { cri_hash = "h2", deps = {} }
		m2.entries["a"] = { cri_hash = "h1", deps = {} }
		T.eq(V.serialize_manifest(m1), V.serialize_manifest(m2))
	end)
end)

-- In-memory I/O caps for testing cache_lookup/cache_store. Each test gets a
-- fresh filesystem; no on-disk artifacts.
--: () -> { files: { [string]: string }, dirs: { [string]: boolean }, caps: unknown }
local function fake_caps()
	local files = {} --[[: { [string]: string } ]]
	local dirs  = {} --[[: { [string]: boolean } ]]
	local caps = {
		--: (string) -> (string | nil, string | nil)
		read_file = function(p)
			local v = files[p]
			if v == nil then return nil, "not found: " .. p end
			return v, nil
		end,
		--: (string, string) -> (boolean, string | nil)
		write_file = function(p, b)
			files[p] = b
			return true, nil
		end,
		--: (string) -> (boolean, string | nil)
		mkdir = function(p)
			dirs[p] = true
			return true, nil
		end,
		--: (string) -> boolean
		file_exists = function(p)
			return files[p] ~= nil
		end,
	}
	return { files = files, dirs = dirs, caps = caps }
end

T.describe("4g — cache primitives", function()
	T.it("cache_lookup of non-existent key returns nil", function()
		local fc = fake_caps()
		local got = V.cache_lookup(fc.caps, ".cache", "nonexistent")
		T.eq(got, nil)
	end)
	T.it("cache_store + lookup round-trips a type", function()
		local fc = fake_caps()
		local t = V.fn({V.integer}, V.string_, {"yield"})
		V.cache_store(fc.caps, ".cache", "src_hash_1", t, nil)
		local bytes = V.cache_lookup(fc.caps, ".cache", "src_hash_1")
		T.ok(bytes ~= nil)
		if bytes == nil then return end
		local got, err = V.deserialize(bytes)
		T.eq(err, nil)
		T.ok(got ~= nil)
		if got ~= nil then
			T.ok(streq(t, got --[[: V4Type]]))
		end
	end)
	T.it("cache_store preserves deps in manifest", function()
		local fc = fake_caps()
		local t = V.integer
		V.cache_store(fc.caps, ".cache", "src1", t,
			{ ["lib/dep.lua"] = "dep_hash" })
		-- Read manifest directly.
		local mbytes = fc.files[".cache/manifest.crm"]
		T.ok(mbytes ~= nil)
		if mbytes == nil then return end
		local m, err = V.deserialize_manifest(mbytes)
		T.eq(err, nil)
		T.ok(m ~= nil)
		if m == nil then return end
		T.eq(m.entries["src1"].deps["lib/dep.lua"], "dep_hash")
	end)
	T.it("cache_store is content-addressed (same type → same cri file)", function()
		local fc = fake_caps()
		V.cache_store(fc.caps, ".cache", "srcA", V.integer, nil)
		V.cache_store(fc.caps, ".cache", "srcB", V.integer, nil)
		-- Only one .cri file (plus manifest) should exist.
		local count = 0
		for path in pairs(fc.files) do
			if path:sub(-4) == ".cri" then count = count + 1 end
		end
		T.eq(count, 1)
	end)
	T.it("cache_lookup returns nil when cri file is missing (torn write)", function()
		local fc = fake_caps()
		V.cache_store(fc.caps, ".cache", "src1", V.integer, nil)
		-- Delete the cri file but leave the manifest.
		for path in pairs(fc.files) do
			if path:sub(-4) == ".cri" then fc.files[path] = nil end
		end
		local got = V.cache_lookup(fc.caps, ".cache", "src1")
		T.eq(got, nil)
	end)
	T.it("missing caps error loudly (no global fallback)", function()
		T.throws(function() V.cache_lookup(nil, ".cache", "x") end)
		T.throws(function() V.cache_lookup({}, ".cache", "x") end)
	end)
end)

return T._summary()
