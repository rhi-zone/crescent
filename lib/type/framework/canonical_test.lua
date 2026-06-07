local T = require("lib.test.assert")
local canonical = require("lib.type.framework.canonical")

T.describe("type.framework canonicalization", function()
	T.it("serializes maps independent of insertion order", function()
		local a = { tag = "term", fields = { b = 2, a = "x" }, head = "T" }
		local b = { head = "T", tag = "term", fields = { a = "x", b = 2 } }
		local sa, ea = canonical.serialize(a)
		local sb, eb = canonical.serialize(b)
		T.ok(sa, ea)
		T.ok(sb, eb)
		T.eq(sa, sb)
	end)

	T.it("drops meta from semantic projection", function()
		local a = { tag = "term", head = "TyUnit", fields = {}, meta = { label = "a" } }
		local b = { tag = "term", head = "TyUnit", fields = {}, meta = { label = "b" } }
		local da, ea = canonical.digest(a)
		local db, eb = canonical.digest(b)
		T.ok(da, ea)
		T.ok(db, eb)
		T.eq(da, db)
	end)

	T.it("computes prefixed digests", function()
		local d, err = canonical.prefixed_digest("theory", { tag = "theory_spec", theory_id = "x", version = "0" })
		T.ok(d, err)
		T.ok(tostring(d):find("^theory:%x%x%x%x") ~= nil, tostring(d))
	end)

	T.it("rejects non-integer numbers in F1", function()
		local encoded, err = canonical.serialize({ tag = "literal", value = 0.5 })
		T.eq(encoded, nil)
		T.ok(tostring(err):find("non%-integer") ~= nil, tostring(err))
	end)

	T.it("rejects NaN", function()
		local encoded, err = canonical.serialize(0 / 0)
		T.eq(encoded, nil)
		T.ok(tostring(err):find("NaN") ~= nil, tostring(err))
	end)

	T.it("rejects infinities", function()
		local pos, pos_err = canonical.serialize(math.huge)
		local neg, neg_err = canonical.serialize(-math.huge)
		T.eq(pos, nil)
		T.eq(neg, nil)
		T.ok(tostring(pos_err):find("infinity") ~= nil, tostring(pos_err))
		T.ok(tostring(neg_err):find("infinity") ~= nil, tostring(neg_err))
	end)

	T.it("normalizes negative zero as integer zero", function()
		local pos, pos_err = canonical.serialize(0)
		local neg, neg_err = canonical.serialize(-0)
		T.ok(pos, pos_err)
		T.ok(neg, neg_err)
		T.eq(pos, neg)
		T.ok(tostring(pos):find("-0") == nil, tostring(pos))
	end)

	T.it("rejects sparse arrays", function()
		local value = { "a", "b" }
		value[4] = "d"
		local encoded, err = canonical.serialize(value)
		T.eq(encoded, nil)
		T.ok(tostring(err):find("dense array") ~= nil, tostring(err))
	end)

	T.it("rejects mixed array/map tables", function()
		local encoded, err = canonical.serialize({ "a", tag = "mixed" })
		T.eq(encoded, nil)
		T.ok(tostring(err):find("dense array") ~= nil, tostring(err))
	end)

	T.it("rejects metatables", function()
		local encoded, err = canonical.serialize(setmetatable({ tag = "term" }, {}))
		T.eq(encoded, nil)
		T.ok(tostring(err):find("metatables") ~= nil, tostring(err))
	end)
end)
