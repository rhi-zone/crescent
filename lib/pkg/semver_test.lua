if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local semver = require("lib.pkg.semver")

T.describe("semver.parse", function()
	T.it("parses a basic version", function()
		local v = semver.parse("1.2.3")
		T.eq(v.major, 1)
		T.eq(v.minor, 2)
		T.eq(v.patch, 3)
		T.eq(v.pre, nil)
	end)

	T.it("parses a version with leading v", function()
		local v = semver.parse("v2.0.0")
		T.eq(v.major, 2)
		T.eq(v.minor, 0)
		T.eq(v.patch, 0)
	end)

	T.it("parses pre-release string identifier", function()
		local v = semver.parse("1.2.3-alpha")
		T.ok(v.pre ~= nil)
		T.eq(v.pre[1], "alpha")
	end)

	T.it("parses pre-release with numeric identifier", function()
		local v = semver.parse("1.2.3-alpha.1")
		T.eq(v.pre[1], "alpha")
		T.eq(v.pre[2], 1)
	end)

	T.it("parses pre-release numeric only", function()
		local v = semver.parse("1.0.0-0.3.7")
		T.eq(v.pre[1], 0)
		T.eq(v.pre[2], 3)
		T.eq(v.pre[3], 7)
	end)

	T.it("strips build metadata", function()
		local v = semver.parse("1.0.0+build.1")
		T.eq(v.major, 1)
		T.eq(v.pre, nil)
	end)

	T.it("returns nil on empty string", function()
		local v, err = semver.parse("")
		T.eq(v, nil)
		T.ok(err ~= nil)
	end)

	T.it("returns nil on missing patch", function()
		local v, err = semver.parse("1.2")
		T.eq(v, nil)
		T.ok(err ~= nil)
	end)

	T.it("returns nil on non-string", function()
		local v, err = semver.parse(123)
		T.eq(v, nil)
		T.ok(err ~= nil)
	end)

	T.it("returns nil on garbage", function()
		local v, err = semver.parse("not-a-version")
		T.eq(v, nil)
		T.ok(err ~= nil)
	end)
end)

T.describe("semver.cmp", function()
	local function p(s) return semver.parse(s) end

	T.it("equal versions return 0", function()
		T.eq(semver.cmp(p("1.2.3"), p("1.2.3")), 0)
	end)

	T.it("major ordering", function()
		T.eq(semver.cmp(p("2.0.0"), p("1.9.9")), 1)
		T.eq(semver.cmp(p("1.0.0"), p("2.0.0")), -1)
	end)

	T.it("minor ordering", function()
		T.eq(semver.cmp(p("1.3.0"), p("1.2.9")), 1)
		T.eq(semver.cmp(p("1.2.0"), p("1.3.0")), -1)
	end)

	T.it("patch ordering", function()
		T.eq(semver.cmp(p("1.2.4"), p("1.2.3")), 1)
		T.eq(semver.cmp(p("1.2.3"), p("1.2.4")), -1)
	end)

	T.it("release is greater than pre-release", function()
		T.eq(semver.cmp(p("1.0.0"), p("1.0.0-alpha")), 1)
		T.eq(semver.cmp(p("1.0.0-alpha"), p("1.0.0")), -1)
	end)

	T.it("pre-release numeric < string identifiers", function()
		-- semver spec: numeric identifiers < alphanumeric
		T.eq(semver.cmp(p("1.0.0-1"), p("1.0.0-alpha")), -1)
	end)

	T.it("pre-release string lexicographic", function()
		T.eq(semver.cmp(p("1.0.0-alpha"), p("1.0.0-beta")), -1)
		T.eq(semver.cmp(p("1.0.0-beta"), p("1.0.0-alpha")), 1)
	end)

	T.it("shorter pre-release < longer", function()
		T.eq(semver.cmp(p("1.0.0-alpha"), p("1.0.0-alpha.1")), -1)
	end)

	T.it("semver spec example ordering", function()
		-- 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0
		local versions = {
			"1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
			"1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
			"1.0.0-rc.1", "1.0.0"
		}
		for i = 1, #versions - 1 do
			T.eq(semver.cmp(semver.parse(versions[i]), semver.parse(versions[i+1])), -1)
		end
	end)
end)

T.describe("semver.satisfies — exact", function()
	T.it("exact match", function()
		T.ok(semver.satisfies(semver.parse("1.2.3"), "1.2.3"))
	end)

	T.it("exact mismatch", function()
		T.fail(semver.satisfies(semver.parse("1.2.4"), "1.2.3"))
	end)

	T.it("wildcard *", function()
		T.ok(semver.satisfies(semver.parse("9.9.9"), "*"))
	end)

	T.it("empty string is wildcard", function()
		T.ok(semver.satisfies(semver.parse("0.0.1"), ""))
	end)
end)

T.describe("semver.satisfies — comparison operators", function()
	local function p(s) return semver.parse(s) end

	T.it(">=", function()
		T.ok(semver.satisfies(p("1.2.3"), ">=1.2.3"))
		T.ok(semver.satisfies(p("1.2.4"), ">=1.2.3"))
		T.fail(semver.satisfies(p("1.2.2"), ">=1.2.3"))
	end)

	T.it(">", function()
		T.ok(semver.satisfies(p("1.2.4"), ">1.2.3"))
		T.fail(semver.satisfies(p("1.2.3"), ">1.2.3"))
		T.fail(semver.satisfies(p("1.2.2"), ">1.2.3"))
	end)

	T.it("<=", function()
		T.ok(semver.satisfies(p("1.2.3"), "<=1.2.3"))
		T.ok(semver.satisfies(p("1.2.2"), "<=1.2.3"))
		T.fail(semver.satisfies(p("1.2.4"), "<=1.2.3"))
	end)

	T.it("<", function()
		T.ok(semver.satisfies(p("1.2.2"), "<1.2.3"))
		T.fail(semver.satisfies(p("1.2.3"), "<1.2.3"))
		T.fail(semver.satisfies(p("1.2.4"), "<1.2.3"))
	end)
end)

T.describe("semver.satisfies — caret ^", function()
	local function p(s) return semver.parse(s) end

	T.it("^1.2.3 allows patch bumps", function()
		T.ok(semver.satisfies(p("1.2.3"), "^1.2.3"))
		T.ok(semver.satisfies(p("1.2.9"), "^1.2.3"))
	end)

	T.it("^1.2.3 allows minor bumps", function()
		T.ok(semver.satisfies(p("1.3.0"), "^1.2.3"))
		T.ok(semver.satisfies(p("1.9.9"), "^1.2.3"))
	end)

	T.it("^1.2.3 rejects same-major upper boundary", function()
		T.fail(semver.satisfies(p("2.0.0"), "^1.2.3"))
	end)

	T.it("^1.2.3 rejects older patch", function()
		T.fail(semver.satisfies(p("1.2.2"), "^1.2.3"))
	end)

	T.it("^0.2.3 same minor", function()
		T.ok(semver.satisfies(p("0.2.3"), "^0.2.3"))
		T.ok(semver.satisfies(p("0.2.9"), "^0.2.3"))
		T.fail(semver.satisfies(p("0.3.0"), "^0.2.3"))
	end)

	T.it("^0.0.3 exact patch only", function()
		T.ok(semver.satisfies(p("0.0.3"), "^0.0.3"))
		T.fail(semver.satisfies(p("0.0.4"), "^0.0.3"))
		T.fail(semver.satisfies(p("0.0.2"), "^0.0.3"))
	end)

	T.it("pre-release of anchor satisfies ^", function()
		-- 1.2.3-alpha is >= 1.2.3-alpha (same) but actually 1.2.3-alpha < 1.2.3
		-- so ^1.2.3 should NOT be satisfied by 1.2.3-alpha since it's < 1.2.3
		T.fail(semver.satisfies(p("1.2.3-alpha"), "^1.2.3"))
	end)
end)

T.describe("semver.satisfies — tilde ~", function()
	local function p(s) return semver.parse(s) end

	T.it("~1.2.3 allows patch bumps only", function()
		T.ok(semver.satisfies(p("1.2.3"), "~1.2.3"))
		T.ok(semver.satisfies(p("1.2.9"), "~1.2.3"))
		T.fail(semver.satisfies(p("1.3.0"), "~1.2.3"))
		T.fail(semver.satisfies(p("1.2.2"), "~1.2.3"))
	end)

	T.it("~1.2 same as ~1.2.0", function()
		T.ok(semver.satisfies(p("1.2.0"), "~1.2"))
		T.ok(semver.satisfies(p("1.2.9"), "~1.2"))
		T.fail(semver.satisfies(p("1.3.0"), "~1.2"))
		T.fail(semver.satisfies(p("1.1.9"), "~1.2"))
	end)

	T.it("~1 allows minor bumps", function()
		T.ok(semver.satisfies(p("1.0.0"), "~1"))
		T.ok(semver.satisfies(p("1.9.9"), "~1"))
		T.fail(semver.satisfies(p("2.0.0"), "~1"))
		T.fail(semver.satisfies(p("0.9.9"), "~1"))
	end)
end)

T.describe("semver.parse_constraint", function()
	T.it("parses *", function()
		local c = semver.parse_constraint("*")
		T.eq(c.op, "*")
	end)

	T.it("parses empty as *", function()
		local c = semver.parse_constraint("")
		T.eq(c.op, "*")
	end)

	T.it("parses ^1.2.3", function()
		local c = semver.parse_constraint("^1.2.3")
		T.eq(c.op, "^")
		T.eq(c.version.major, 1)
		T.eq(c.version.minor, 2)
		T.eq(c.version.patch, 3)
	end)

	T.it("parses ~1.2.3", function()
		local c = semver.parse_constraint("~1.2.3")
		T.eq(c.op, "~")
		T.eq(c.version.major, 1)
	end)

	T.it("parses >=1.0.0", function()
		local c = semver.parse_constraint(">=1.0.0")
		T.eq(c.op, ">=")
		T.eq(c.version.major, 1)
	end)

	T.it("parses <2.0.0", function()
		local c = semver.parse_constraint("<2.0.0")
		T.eq(c.op, "<")
		T.eq(c.version.major, 2)
	end)

	T.it("parses exact version", function()
		local c = semver.parse_constraint("1.2.3")
		T.eq(c.op, "=")
		T.eq(c.version.patch, 3)
	end)

	T.it("returns nil on invalid constraint", function()
		local c, err = semver.parse_constraint("not-valid")
		T.eq(c, nil)
		T.ok(err ~= nil)
	end)

	T.it("trims whitespace", function()
		local c = semver.parse_constraint("  ^1.2.3  ")
		T.eq(c.op, "^")
	end)
end)
