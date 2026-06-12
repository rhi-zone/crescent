-- Tests for the flow-narrowing CORE (slice_narrow.lua) — Pass 3 of the slice
-- mechanization (docs/agnostic-static-analysis-crescent-slice.md §4, §8).
--
-- These exercise the PURE refinement function `NAR.refine(guard, x, T)` directly:
-- per-form positive truthy decomposition, sound-wider falsy approximation (the
-- §4.1 / kernel §5.4 watch point — NOT exact where exactness needs complement),
-- the nil-guard's exact two-sided positivity, tag-field union-of-recs selection,
-- and and/or/not composition. The substrate-hosted `narrow_guard` evidence and the
-- adversarial substrate-agnosticism checks live in crescent_slice_test.lua.

local T = require("lib.test.assert")
local G = require("lib.type.analysis.slice_ty")
local NAR = require("lib.type.analysis.slice_narrow")

-- ── truthy (`if x`) ──────────────────────────────────────────────────────────

T.describe("slice_narrow: truthy guard (`if x`)", function()
	T.it("drops nil and false on the truthy branch; falsy is sound-wider T", function()
		G.reset()
		-- x : TN | nil | false  →  truthy: TN ; falsy: the whole union (unrefined).
		local TN = G.rec({ { key = "id", ty = G.string(), optional = false, readonly = false } }, "closed")
		local t = G.union({ TN, G.nil_(), G.lit_bool(false) })
		local tt, tf = NAR.refine({ g = "truthy", var = "x" }, "x", t)
		T.eq(tt and tt.tid, TN.tid, "truthy drops nil + false ⇒ TN exactly (positive)")
		T.eq(tf and tf.tid, t.tid, "falsy is the unrefined T (sound wider, no complement)")
	end)

	T.it("truthy on a plain boolean keeps boolean (true is the only truthy bool)", function()
		G.reset()
		-- boolean has no droppable union member at the type level (it is a primitive,
		-- not a union of true|false in v1) — truthy keeps boolean.
		local t = G.boolean()
		local tt = NAR.refine({ g = "truthy", var = "x" }, "x", t)
		T.eq(tt and tt.tid, G.boolean().tid, "truthy of boolean ⇒ boolean")
	end)
end)

-- ── nil-eq (`x == nil` / `x ~= nil`) ─────────────────────────────────────────

T.describe("slice_narrow: nil-guard (the one exact two-sided form)", function()
	T.it("`x ~= nil` drops nil truthy, keeps nil falsy (both positive ⇒ exact)", function()
		G.reset()
		local TN = G.rec({ { key = "id", ty = G.string(), optional = false, readonly = false } }, "closed")
		local t = G.union({ TN, G.nil_() })
		local tt, tf = NAR.refine({ g = "nil_eq", var = "x", eq = false }, "x", t)
		T.eq(tt and tt.tid, TN.tid, "truthy (x ~= nil) ⇒ TN (nil dropped)")
		T.eq(tf and tf.tid, G.nil_().tid, "falsy (x is nil) ⇒ nil — POSITIVE, exact, not sound-wider")
	end)

	T.it("`x == nil` is the swap: truthy nil, falsy non-nil", function()
		G.reset()
		local TN = G.rec({ { key = "id", ty = G.string(), optional = false, readonly = false } }, "closed")
		local t = G.union({ TN, G.nil_() })
		local tt, tf = NAR.refine({ g = "nil_eq", var = "x", eq = true }, "x", t)
		T.eq(tt and tt.tid, G.nil_().tid, "truthy (x == nil) ⇒ nil")
		T.eq(tf and tf.tid, TN.tid, "falsy (x is not nil) ⇒ TN")
	end)
end)

-- ── type-eq (`type(x) == "string"`) ──────────────────────────────────────────

T.describe("slice_narrow: type guard (`type(x) == ...`)", function()
	T.it("keeps the matching runtime-type members truthy; falsy is sound-wider T", function()
		G.reset()
		local t = G.union({ G.string(), G.number(), G.nil_() })
		local tt, tf = NAR.refine({ g = "type_eq", var = "x", tyname = "string" }, "x", t)
		T.eq(tt and tt.tid, G.string().tid, "truthy keeps the string member exactly")
		T.eq(tf and tf.tid, t.tid, "falsy is T unrefined (no ~string — sound wider)")
	end)

	T.it("number matches integer / lit_int / lit_num members too", function()
		G.reset()
		local t = G.union({ G.string(), G.integer(), G.lit_num(3.5) })
		local tt = NAR.refine({ g = "type_eq", var = "x", tyname = "number" }, "x", t)
		-- integer and lit_num(3.5) both match "number"; string drops.
		T.eq(tt and tt.tid, G.union({ G.integer(), G.lit_num(3.5) }).tid, "number keeps integer + lit_num")
	end)

	T.it("table matches rec / indexer members", function()
		G.reset()
		local r = G.rec({ { key = "a", ty = G.number(), optional = false, readonly = false } }, "closed")
		local t = G.union({ r, G.string() })
		local tt = NAR.refine({ g = "type_eq", var = "x", tyname = "table" }, "x", t)
		T.eq(tt and tt.tid, r.tid, "table keeps the record member")
	end)
end)

-- ── literal-eq (`x == "GET"`) ────────────────────────────────────────────────

T.describe("slice_narrow: literal-eq guard (`x == <literal>`)", function()
	T.it("narrows to the singleton truthy; falsy is sound-wider T", function()
		G.reset()
		local t = G.string()
		local lit = G.lit_str("GET")
		local tt, tf = NAR.refine({ g = "lit_eq", var = "x", lit = lit }, "x", t)
		T.eq(tt and tt.tid, lit.tid, "truthy ⇒ lit_str(\"GET\") singleton")
		T.eq(tf and tf.tid, t.tid, "falsy is T (no ~\"GET\" — sound wider)")
	end)

	T.it("an impossible literal narrows truthy to never (unreachable branch)", function()
		G.reset()
		-- x : integer, guard x == "GET" — the truthy branch cannot occur.
		local t = G.integer()
		local tt = NAR.refine({ g = "lit_eq", var = "x", lit = G.lit_str("GET") }, "x", t)
		T.eq(tt and tt.tid, G.never().tid, "literal not <: T ⇒ truthy is never")
	end)
end)

-- ── tag-eq (`x.tag == "leaf"`) — the union-of-recs discriminant ──────────────

T.describe("slice_narrow: tag-field discriminant (union-of-recs, req. 3)", function()
	T.it("selects the union members whose tag field admits the literal", function()
		G.reset()
		local Leaf = G.rec({ { key = "tag", ty = G.lit_str("leaf"), optional = false, readonly = false },
			{ key = "key", ty = G.unknown(), optional = false, readonly = false } }, "closed")
		local Interior = G.rec({ { key = "tag", ty = G.lit_str("interior"), optional = false, readonly = false },
			{ key = "n", ty = G.integer(), optional = false, readonly = false } }, "closed")
		local t = G.union({ Leaf, Interior })
		local tt, tf = NAR.refine({ g = "tag_eq", var = "x", field = "tag", lit = G.lit_str("leaf") }, "x", t)
		T.eq(tt and tt.tid, Leaf.tid, "tag == \"leaf\" ⇒ the Leaf member exactly")
		T.eq(tf and tf.tid, t.tid, "falsy is T (sound wider)")
	end)

	T.it("a plain `string` tag field admits any literal tag", function()
		G.reset()
		local R = G.rec({ { key = "tag", ty = G.string(), optional = false, readonly = false } }, "closed")
		local t = G.union({ R, G.nil_() })
		local tt = NAR.refine({ g = "tag_eq", var = "x", field = "tag", lit = G.lit_str("whatever") }, "x", t)
		T.eq(tt and tt.tid, R.tid, "string tag field admits the literal ⇒ keeps R, drops nil")
	end)

	T.it("unfolds a μ union-member before inspecting its tag field", function()
		G.reset()
		-- The discriminated-union / hamt idiom: a union one of whose members is a
		-- (mutually-)recursive μ. tag == "leaf" must select the Leaf arm even though
		-- the Interior arm is wrapped in a μ — member_admits_tag unfolds it once.
		local Leaf = G.rec({ { key = "tag", ty = G.lit_str("leaf"), optional = false, readonly = false } }, "closed")
		local InteriorMu = G.mu("X", function(x)
			return G.rec({ { key = "tag", ty = G.lit_str("interior"), optional = false, readonly = false },
				{ key = "kids", ty = G.indexer(G.integer(), x), optional = false, readonly = false } }, "closed")
		end)
		local t = G.union({ Leaf, InteriorMu })
		local tt = NAR.refine({ g = "tag_eq", var = "x", field = "tag", lit = G.lit_str("leaf") }, "x", t)
		T.eq(tt and tt.tid, Leaf.tid, "tag==\"leaf\" selects Leaf; the μ Interior member is unfolded and dropped")
		-- and selecting the μ member's own tag works too (unfold finds "interior").
		local ti = NAR.refine({ g = "tag_eq", var = "x", field = "tag", lit = G.lit_str("interior") }, "x", t)
		T.eq(ti and ti.tid, InteriorMu.tid, "tag==\"interior\" selects the μ member (unfolded to read its tag)")
	end)
end)

-- ── not / and / or composition ───────────────────────────────────────────────

T.describe("slice_narrow: `not` swaps the two branches", function()
	T.it("not (x ~= nil) swaps to (x is nil) truthy", function()
		G.reset()
		local TN = G.rec({ { key = "id", ty = G.string(), optional = false, readonly = false } }, "closed")
		local t = G.union({ TN, G.nil_() })
		local inner = { g = "nil_eq", var = "x", eq = false } -- x ~= nil
		local tt, tf = NAR.refine({ g = "not", inner = inner }, "x", t)
		-- not(x ~= nil): truthy ⇒ inner's falsy (nil); falsy ⇒ inner's truthy (TN).
		T.eq(tt and tt.tid, G.nil_().tid, "not(x ~= nil) truthy ⇒ nil")
		T.eq(tf and tf.tid, TN.tid, "not(x ~= nil) falsy ⇒ TN")
	end)
end)

T.describe("slice_narrow: `and` composition (the n==0 and 1/n<0 shape)", function()
	T.it("narrows through `and` — chained truthy refinements intersect", function()
		G.reset()
		-- The boolean-narrowing fixture shape `n == 0 and 1/n < 0`: the SECOND
		-- conjunct does not refine `x`, so the result is the first conjunct's truthy
		-- refinement. We test the narrowing form: `x ~= nil and type(x) == "string"`.
		local t = G.union({ G.string(), G.number(), G.nil_() })
		local g = { g = "and",
			left = { g = "nil_eq", var = "x", eq = false },       -- x ~= nil  (drops nil)
			right = { g = "type_eq", var = "x", tyname = "string" } } -- type(x)=="string"
		local tt, tf = NAR.refine(g, "x", t)
		-- truthy: drop nil THEN keep string ⇒ string. falsy: T (sound wider).
		T.eq(tt and tt.tid, G.string().tid, "x ~= nil and type(x)==string ⇒ string (chained)")
		T.eq(tf and tf.tid, t.tid, "and's falsy branch is sound-wider T (no complement)")
	end)

	T.it("a conjunct that does not mention x leaves x's narrowing to the other", function()
		G.reset()
		local t = G.union({ G.string(), G.nil_() })
		-- `x ~= nil and y == 0` — only the left mentions x.
		local g = { g = "and",
			left = { g = "nil_eq", var = "x", eq = false },
			right = { g = "lit_eq", var = "y", lit = G.lit_int(0) } }
		local tt = NAR.refine(g, "x", t)
		T.eq(tt and tt.tid, G.string().tid, "the y-conjunct contributes nothing to x")
	end)
end)

T.describe("slice_narrow: `or` composition", function()
	T.it("unions the two truthy refinements", function()
		G.reset()
		local t = G.union({ G.string(), G.number(), G.lit_bool(true) })
		-- type(x)=="string" or type(x)=="number" ⇒ string | number.
		local g = { g = "or",
			left = { g = "type_eq", var = "x", tyname = "string" },
			right = { g = "type_eq", var = "x", tyname = "number" } }
		local tt, tf = NAR.refine(g, "x", t)
		T.eq(tt and tt.tid, G.union({ G.string(), G.number() }).tid, "or ⇒ union of truthy refinements")
		T.eq(tf and tf.tid, t.tid, "or's falsy branch is sound-wider T")
	end)
end)

-- ── falsy-branch soundness probe (kernel §5.4 watch point) ───────────────────

T.describe("slice_narrow: falsy branch is sound-WIDER, NOT exact (the fence)", function()
	T.it("type-eq falsy is the FULL T, not T minus the matched member", function()
		G.reset()
		-- The EXACT falsy refinement of `type(x)=="string"` would be `T & ~string` =
		-- number (the complement). v1 must NOT produce that — it keeps the full T.
		-- This asserts the deferral fence held: the falsy branch is wider.
		local t = G.union({ G.string(), G.number() })
		local _, tf = NAR.refine({ g = "type_eq", var = "x", tyname = "string" }, "x", t)
		T.eq(tf and tf.tid, t.tid, "falsy keeps string|number (NOT narrowed to number) — sound wider")
		T.fail(tf and tf.tid == G.number().tid, "falsy must NOT be the exact complement (number)")
	end)

	T.it("lit-eq falsy keeps T (no ~lit), confirming no complement leaked in", function()
		G.reset()
		local t = G.union({ G.lit_str("GET"), G.lit_str("POST") })
		local _, tf = NAR.refine({ g = "lit_eq", var = "x", lit = G.lit_str("GET") }, "x", t)
		T.eq(tf and tf.tid, t.tid, "falsy of x==\"GET\" keeps \"GET\"|\"POST\" (not just \"POST\")")
	end)
end)

-- ── guard_mentions ───────────────────────────────────────────────────────────

T.describe("slice_narrow: guard_mentions", function()
	T.it("detects the target variable through composition", function()
		local g = { g = "and",
			left = { g = "truthy", var = "a" },
			right = { g = "not", inner = { g = "nil_eq", var = "b", eq = false } } }
		T.ok(NAR.guard_mentions(g, "a"), "mentions a")
		T.ok(NAR.guard_mentions(g, "b"), "mentions b (through not)")
		T.fail(NAR.guard_mentions(g, "c"), "does not mention c")
	end)
end)
