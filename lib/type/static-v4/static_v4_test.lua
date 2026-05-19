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

	-- Union-on-RHS (`A <: B | C`) is deferred to Phase 4c when complement
	-- lands and the MLstruct negation rewrite (`A ∧ ¬B <: C`) becomes
	-- expressible. 4a rejects the obligation loudly rather than guessing a
	-- disjunct (see subtype.lua and README for rationale).
	T.it("A <: A | B is deferred until Phase 4c (no complement yet)", function()
		local ok, err = st(V.integer, V.union({V.integer, V.string_}))
		T.fail(ok)
		T.ok(err and err:find("Phase 4c", 1, true) ~= nil)
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

	-- Intersection-on-LHS (`A & B <: C`) is the dual of union-on-RHS and is
	-- likewise deferred to Phase 4c.
	T.it("A & B <: A is deferred until Phase 4c (no complement yet)", function()
		local ok, err = st(V.inter({V.integer, V.string_}), V.integer)
		T.fail(ok)
		T.ok(err and err:find("Phase 4c", 1, true) ~= nil)
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

return T._summary()
