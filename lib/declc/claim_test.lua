-- lib/declc/claim_test.lua
-- Tests for the claim data type: constructors, accessors, equality/keying.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local claim = require("lib.declc.claim")

-- ── Constructor validation ──────────────────────────────────────────────────

T.describe("claim.new: validation", function()
	T.it("accepts a fully-populated valid claim", function()
		local c, err = claim.new({
			site       = "src/foo.lua:12",
			slot       = "entry:x",
			stratum    = claim.STRATUM.PI1,
			modal      = claim.MODAL.BOX,
			schema     = { kind = "string" },
			schema_key = "string",
			provenance = claim.PROVENANCE.STATED,
		})
		T.ok(c ~= nil, "claim.new should succeed")
		T.eq(err, nil)
	end)

	T.it("rejects nil fields", function()
		local c, err = claim.new(nil)
		T.eq(c, nil)
		T.ok(err ~= nil)
	end)

	local BASE = {
		site       = "s",
		slot       = "k",
		stratum    = "pi1",
		modal      = "box",
		schema     = "V",
		schema_key = "k1",
		provenance = "stated",
	}

	--: (string, unknown) -> ClaimFields
	local function with(field, value)
		local f = {}
		for k, v in pairs(BASE) do f[k] = v end
		f[field] = value
		return f
	end

	T.it("rejects missing/empty site", function()
		local c1, e1 = claim.new(with("site", nil))
		T.eq(c1, nil); T.ok(e1 ~= nil)
		local c2, e2 = claim.new(with("site", ""))
		T.eq(c2, nil); T.ok(e2 ~= nil)
	end)

	T.it("rejects missing/empty slot", function()
		local c, err = claim.new(with("slot", ""))
		T.eq(c, nil); T.ok(err ~= nil)
	end)

	T.it("rejects an unknown stratum", function()
		local c, err = claim.new(with("stratum", "sigma2"))
		T.eq(c, nil)
		T.ok(err ~= nil)
	end)

	T.it("accepts all three strata", function()
		for _, s in ipairs({ "sigma1", "pi1", "pi2" }) do
			local c, err = claim.new(with("stratum", s))
			T.ok(c ~= nil, "stratum " .. s .. " should be accepted")
			T.eq(err, nil)
		end
	end)

	T.it("rejects an unknown modal", function()
		local c, err = claim.new(with("modal", "square"))
		T.eq(c, nil)
		T.ok(err ~= nil)
	end)

	T.it("accepts both modals", function()
		for _, m in ipairs({ "box", "diamond" }) do
			local c, err = claim.new(with("modal", m))
			T.ok(c ~= nil, "modal " .. m .. " should be accepted")
			T.eq(err, nil)
		end
	end)

	T.it("rejects missing/empty schema_key", function()
		local c, err = claim.new(with("schema_key", ""))
		T.eq(c, nil); T.ok(err ~= nil)
	end)

	T.it("rejects an unknown provenance", function()
		local c, err = claim.new(with("provenance", "guessed"))
		T.eq(c, nil)
		T.ok(err ~= nil)
	end)

	T.it("accepts all three provenances", function()
		for _, p in ipairs({ "stated", "axiom", "mined" }) do
			local c, err = claim.new(with("provenance", p))
			T.ok(c ~= nil, "provenance " .. p .. " should be accepted")
			T.eq(err, nil)
		end
	end)

	T.it("schema itself may be nil (opaque, caller-owned)", function()
		local c, err = claim.new(with("schema", nil))
		T.ok(c ~= nil)
		T.eq(err, nil)
	end)
end)

-- ── Accessors ────────────────────────────────────────────────────────────

T.describe("claim accessors", function()
	local c = claim.new({
		site       = "s1",
		slot       = "k1",
		stratum    = claim.STRATUM.SIGMA1,
		modal      = claim.MODAL.DIAMOND,
		schema     = { 1, 2, 3 },
		schema_key = "arr123",
		provenance = claim.PROVENANCE.MINED,
	})

	T.it("site/slot/stratum/modal/schema_key/provenance round-trip", function()
		T.eq(claim.site(c), "s1")
		T.eq(claim.slot(c), "k1")
		T.eq(claim.stratum(c), "sigma1")
		T.eq(claim.modal(c), "diamond")
		T.eq(claim.schema_key(c), "arr123")
		T.eq(claim.provenance(c), "mined")
	end)

	T.it("schema returns the original opaque payload by identity", function()
		local schema = claim.schema(c)
		T.eq(schema[1], 1)
		T.eq(schema[2], 2)
		T.eq(schema[3], 3)
	end)
end)

-- ── Keying / equality ────────────────────────────────────────────────────

T.describe("claim.key / claim.equal", function()
	--: ("stated" | "axiom" | "mined") -> Claim
	local function mk(provenance)
		local c = claim.new({
			site       = "site-a",
			slot       = "slot-a",
			stratum    = "pi1",
			modal      = "box",
			schema     = "irrelevant",
			schema_key = "schema-a",
			provenance = provenance,
		})
		return c
	end

	T.it("two claims with identical (site,slot,stratum,modal,schema_key) are equal", function()
		local a = mk("stated")
		local b = mk("stated")
		T.ok(claim.equal(a, b))
		T.eq(claim.key(a), claim.key(b))
	end)

	T.it("provenance does NOT affect the key (both-ways-audit collapse)", function()
		local a = mk("stated")
		local b = mk("mined")
		T.ok(claim.equal(a, b),
			"same proposition asserted by two provenances must share a key")
	end)

	T.it("differing site changes the key", function()
		local a, _ = claim.new({
			site = "site-a", slot = "k", stratum = "pi1", modal = "box",
			schema = nil, schema_key = "sk", provenance = "axiom",
		})
		local b, _ = claim.new({
			site = "site-b", slot = "k", stratum = "pi1", modal = "box",
			schema = nil, schema_key = "sk", provenance = "axiom",
		})
		T.fail(claim.equal(a, b))
	end)

	T.it("differing schema_key changes the key", function()
		local a, _ = claim.new({
			site = "s", slot = "k", stratum = "pi1", modal = "box",
			schema = nil, schema_key = "sk1", provenance = "axiom",
		})
		local b, _ = claim.new({
			site = "s", slot = "k", stratum = "pi1", modal = "box",
			schema = nil, schema_key = "sk2", provenance = "axiom",
		})
		T.fail(claim.equal(a, b))
	end)

	T.it("differing modal changes the key", function()
		local a, _ = claim.new({
			site = "s", slot = "k", stratum = "pi1", modal = "box",
			schema = nil, schema_key = "sk", provenance = "axiom",
		})
		local b, _ = claim.new({
			site = "s", slot = "k", stratum = "pi1", modal = "diamond",
			schema = nil, schema_key = "sk", provenance = "axiom",
		})
		T.fail(claim.equal(a, b))
	end)

	T.it("differing stratum changes the key", function()
		local a, _ = claim.new({
			site = "s", slot = "k", stratum = "pi1", modal = "box",
			schema = nil, schema_key = "sk", provenance = "axiom",
		})
		local b, _ = claim.new({
			site = "s", slot = "k", stratum = "pi2", modal = "box",
			schema = nil, schema_key = "sk", provenance = "axiom",
		})
		T.fail(claim.equal(a, b))
	end)
end)
