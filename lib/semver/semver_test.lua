-- lib/semver/semver_test.lua
if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local semver = require("lib.semver")

T.describe("semver", function()

	T.describe("parse", function()
		T.it("parses basic version", function()
			local v = semver.parse("1.2.3")
			T.ok(v)
			T.eq(v.major, 1)
			T.eq(v.minor, 2)
			T.eq(v.patch, 3)
			T.eq(v.prerelease, nil)
			T.eq(v.build, nil)
		end)

		T.it("parses 0.0.0", function()
			local v = semver.parse("0.0.0")
			T.ok(v)
			T.eq(v.major, 0)
			T.eq(v.minor, 0)
			T.eq(v.patch, 0)
		end)

		T.it("parses version with prerelease", function()
			local v = semver.parse("1.2.3-beta.1")
			T.ok(v)
			T.eq(v.major, 1)
			T.eq(v.minor, 2)
			T.eq(v.patch, 3)
			T.eq(v.prerelease, "beta.1")
			T.eq(v.build, nil)
		end)

		T.it("parses version with build metadata", function()
			local v = semver.parse("1.2.3+build.42")
			T.ok(v)
			T.eq(v.build, "build.42")
			T.eq(v.prerelease, nil)
		end)

		T.it("parses version with prerelease and build", function()
			local v = semver.parse("1.2.3-beta.1+build.42")
			T.ok(v)
			T.eq(v.major, 1)
			T.eq(v.minor, 2)
			T.eq(v.patch, 3)
			T.eq(v.prerelease, "beta.1")
			T.eq(v.build, "build.42")
		end)

		T.it("parses version with hyphen in prerelease", function()
			local v = semver.parse("1.0.0-alpha-beta")
			T.ok(v)
			T.eq(v.prerelease, "alpha-beta")
		end)

		T.it("parses large version numbers", function()
			local v = semver.parse("999.999.999")
			T.ok(v)
			T.eq(v.major, 999)
			T.eq(v.minor, 999)
			T.eq(v.patch, 999)
		end)

		T.it("parses prerelease with only numeric identifiers", function()
			local v = semver.parse("1.0.0-1.2.3")
			T.ok(v)
			T.eq(v.prerelease, "1.2.3")
		end)

		T.it("parses prerelease with mixed identifiers", function()
			local v = semver.parse("1.0.0-0.3.7")
			T.ok(v)
			T.eq(v.prerelease, "0.3.7")
		end)

		T.it("parses build with multiple identifiers", function()
			local v = semver.parse("1.0.0+20130313144700")
			T.ok(v)
			T.eq(v.build, "20130313144700")
		end)

		T.it("parses complex prerelease and build", function()
			local v = semver.parse("1.0.0-beta.11+exp.sha.5114f85")
			T.ok(v)
			T.eq(v.prerelease, "beta.11")
			T.eq(v.build, "exp.sha.5114f85")
		end)
	end)

	T.describe("parse errors", function()
		T.it("rejects non-string", function()
			local v, err = semver.parse(123)
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects empty string", function()
			local v, err = semver.parse("")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects missing patch", function()
			local v, err = semver.parse("1.2")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects missing minor and patch", function()
			local v, err = semver.parse("1")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects leading zeros in major", function()
			local v, err = semver.parse("01.2.3")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects leading zeros in minor", function()
			local v, err = semver.parse("1.02.3")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects leading zeros in patch", function()
			local v, err = semver.parse("1.2.03")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects leading zeros in numeric prerelease identifier", function()
			local v, err = semver.parse("1.2.3-01")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects non-alphanumeric prerelease", function()
			local v, err = semver.parse("1.2.3-beta@1")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects non-alphanumeric build", function()
			local v, err = semver.parse("1.2.3+build@1")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects letters in version core", function()
			local v, err = semver.parse("a.b.c")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects negative numbers", function()
			local v, err = semver.parse("-1.2.3")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects extra dots", function()
			local v, err = semver.parse("1.2.3.4")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects empty prerelease after hyphen", function()
			local v, err = semver.parse("1.2.3-")
			T.eq(v, nil)
			T.ok(err)
		end)

		T.it("rejects empty build after plus", function()
			local v, err = semver.parse("1.2.3+")
			T.eq(v, nil)
			T.ok(err)
		end)
	end)

	T.describe("is_valid", function()
		T.it("returns true for valid versions", function()
			T.ok(semver.is_valid("1.2.3"))
			T.ok(semver.is_valid("0.0.0"))
			T.ok(semver.is_valid("1.2.3-alpha"))
			T.ok(semver.is_valid("1.2.3+build"))
			T.ok(semver.is_valid("1.2.3-alpha+build"))
		end)

		T.it("returns false for invalid versions", function()
			T.eq(semver.is_valid("not.a.version"), false)
			T.eq(semver.is_valid("1.2"), false)
			T.eq(semver.is_valid(""), false)
			T.eq(semver.is_valid("01.2.3"), false)
		end)
	end)

	T.describe("tostring", function()
		T.it("round-trips basic version", function()
			T.eq(tostring(semver.parse("1.2.3")), "1.2.3")
		end)

		T.it("round-trips version with prerelease", function()
			T.eq(tostring(semver.parse("1.2.3-beta.1")), "1.2.3-beta.1")
		end)

		T.it("round-trips version with build", function()
			T.eq(tostring(semver.parse("1.2.3+build.42")), "1.2.3+build.42")
		end)

		T.it("round-trips version with prerelease and build", function()
			T.eq(tostring(semver.parse("1.2.3-beta.1+build.42")), "1.2.3-beta.1+build.42")
		end)

		T.it("round-trips 0.0.0", function()
			T.eq(tostring(semver.parse("0.0.0")), "0.0.0")
		end)
	end)

	T.describe("comparison", function()
		T.it("equal versions", function()
			local v1 = semver.parse("1.2.3")
			local v2 = semver.parse("1.2.3")
			T.ok(v1:eq(v2))
			T.ok(not v1:lt(v2))
			T.ok(not v1:gt(v2))
			T.ok(v1:le(v2))
			T.ok(v1:ge(v2))
		end)

		T.it("major difference", function()
			local v1 = semver.parse("1.0.0")
			local v2 = semver.parse("2.0.0")
			T.ok(v1:lt(v2))
			T.ok(v2:gt(v1))
			T.ok(not v1:eq(v2))
		end)

		T.it("minor difference", function()
			local v1 = semver.parse("1.0.0")
			local v2 = semver.parse("1.1.0")
			T.ok(v1:lt(v2))
			T.ok(v2:gt(v1))
		end)

		T.it("patch difference", function()
			local v1 = semver.parse("1.0.0")
			local v2 = semver.parse("1.0.1")
			T.ok(v1:lt(v2))
			T.ok(v2:gt(v1))
		end)

		T.it("prerelease < release", function()
			local v1 = semver.parse("1.0.0-alpha")
			local v2 = semver.parse("1.0.0")
			T.ok(v1:lt(v2))
			T.ok(v2:gt(v1))
		end)

		T.it("SemVer 2.0.0 spec prerelease ordering", function()
			-- 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0
			local versions = {
				"1.0.0-alpha",
				"1.0.0-alpha.1",
				"1.0.0-alpha.beta",
				"1.0.0-beta",
				"1.0.0-beta.2",
				"1.0.0-beta.11",
				"1.0.0-rc.1",
				"1.0.0",
			}
			for i = 1, #versions - 1 do
				local a = semver.parse(versions[i])
				local b = semver.parse(versions[i + 1])
				T.ok(a:lt(b), versions[i] .. " < " .. versions[i + 1])
			end
		end)

		T.it("numeric prerelease identifiers compared as integers", function()
			local v1 = semver.parse("1.0.0-2")
			local v2 = semver.parse("1.0.0-11")
			T.ok(v1:lt(v2))
		end)

		T.it("numeric < string prerelease identifiers", function()
			local v1 = semver.parse("1.0.0-1")
			local v2 = semver.parse("1.0.0-alpha")
			T.ok(v1:lt(v2))
		end)

		T.it("build metadata ignored in comparison", function()
			local v1 = semver.parse("1.0.0+build1")
			local v2 = semver.parse("1.0.0+build2")
			T.ok(v1:eq(v2))
		end)

		T.it("build metadata ignored with prerelease", function()
			local v1 = semver.parse("1.0.0-alpha+build1")
			local v2 = semver.parse("1.0.0-alpha+build2")
			T.ok(v1:eq(v2))
		end)

		T.it("metamethod == works", function()
			local v1 = semver.parse("1.2.3")
			local v2 = semver.parse("1.2.3")
			T.ok(v1 == v2)
		end)

		T.it("metamethod < works", function()
			local v1 = semver.parse("1.2.3")
			local v2 = semver.parse("1.2.4")
			T.ok(v1 < v2)
		end)

		T.it("metamethod <= works", function()
			local v1 = semver.parse("1.2.3")
			local v2 = semver.parse("1.2.3")
			T.ok(v1 <= v2)
		end)

		T.it("shorter prerelease < longer with same prefix", function()
			local v1 = semver.parse("1.0.0-alpha")
			local v2 = semver.parse("1.0.0-alpha.1")
			T.ok(v1:lt(v2))
		end)
	end)

	T.describe("inc_major", function()
		T.it("increments major and resets minor/patch", function()
			local v = semver.parse("1.2.3"):inc_major()
			T.eq(tostring(v), "2.0.0")
		end)

		T.it("clears prerelease", function()
			local v = semver.parse("1.2.3-beta"):inc_major()
			T.eq(tostring(v), "2.0.0")
			T.eq(v.prerelease, nil)
		end)

		T.it("clears build", function()
			local v = semver.parse("1.2.3+build"):inc_major()
			T.eq(v.build, nil)
		end)

		T.it("from 0.x", function()
			local v = semver.parse("0.9.5"):inc_major()
			T.eq(tostring(v), "1.0.0")
		end)
	end)

	T.describe("inc_minor", function()
		T.it("increments minor and resets patch", function()
			local v = semver.parse("1.2.3"):inc_minor()
			T.eq(tostring(v), "1.3.0")
		end)

		T.it("clears prerelease", function()
			local v = semver.parse("1.2.3-beta"):inc_minor()
			T.eq(tostring(v), "1.3.0")
		end)

		T.it("preserves major", function()
			local v = semver.parse("5.2.3"):inc_minor()
			T.eq(v.major, 5)
			T.eq(v.minor, 3)
			T.eq(v.patch, 0)
		end)
	end)

	T.describe("inc_patch", function()
		T.it("increments patch", function()
			local v = semver.parse("1.2.3"):inc_patch()
			T.eq(tostring(v), "1.2.4")
		end)

		T.it("clears prerelease", function()
			local v = semver.parse("1.2.3-beta"):inc_patch()
			T.eq(tostring(v), "1.2.4")
		end)

		T.it("preserves major and minor", function()
			local v = semver.parse("5.2.3"):inc_patch()
			T.eq(v.major, 5)
			T.eq(v.minor, 2)
			T.eq(v.patch, 4)
		end)
	end)

	T.describe("sort", function()
		T.it("sorts versions ascending", function()
			local list = {
				semver.parse("3.0.0"),
				semver.parse("1.0.0"),
				semver.parse("2.0.0"),
			}
			semver.sort(list)
			T.eq(tostring(list[1]), "1.0.0")
			T.eq(tostring(list[2]), "2.0.0")
			T.eq(tostring(list[3]), "3.0.0")
		end)

		T.it("sorts with prerelease correctly", function()
			local list = {
				semver.parse("1.0.0"),
				semver.parse("1.0.0-alpha"),
				semver.parse("1.0.0-beta"),
			}
			semver.sort(list)
			T.eq(tostring(list[1]), "1.0.0-alpha")
			T.eq(tostring(list[2]), "1.0.0-beta")
			T.eq(tostring(list[3]), "1.0.0")
		end)

		T.it("returns the list", function()
			local list = { semver.parse("1.0.0") }
			T.ok(semver.sort(list) == list)
		end)
	end)

	T.describe("max", function()
		T.it("returns the highest version", function()
			local list = {
				semver.parse("1.0.0"),
				semver.parse("3.0.0"),
				semver.parse("2.0.0"),
			}
			T.eq(tostring(semver.max(list)), "3.0.0")
		end)

		T.it("returns nil for empty list", function()
			T.eq(semver.max({}), nil)
		end)

		T.it("prefers release over prerelease", function()
			local list = {
				semver.parse("1.0.0-alpha"),
				semver.parse("1.0.0"),
			}
			T.eq(tostring(semver.max(list)), "1.0.0")
		end)
	end)

	T.describe("min", function()
		T.it("returns the lowest version", function()
			local list = {
				semver.parse("3.0.0"),
				semver.parse("1.0.0"),
				semver.parse("2.0.0"),
			}
			T.eq(tostring(semver.min(list)), "1.0.0")
		end)

		T.it("returns nil for empty list", function()
			T.eq(semver.min({}), nil)
		end)

		T.it("prefers prerelease over release", function()
			local list = {
				semver.parse("1.0.0"),
				semver.parse("1.0.0-alpha"),
			}
			T.eq(tostring(semver.min(list)), "1.0.0-alpha")
		end)
	end)

	T.describe("constraints", function()
		T.describe("exact", function()
			T.it("matches exact version", function()
				local c = semver.constraint("=1.2.3")
				T.ok(c:matches(semver.parse("1.2.3")))
			end)

			T.it("rejects different version", function()
				local c = semver.constraint("=1.2.3")
				T.ok(not c:matches(semver.parse("1.2.4")))
			end)

			T.it("bare version is exact match", function()
				local c = semver.constraint("1.2.3")
				T.ok(c:matches(semver.parse("1.2.3")))
				T.ok(not c:matches(semver.parse("1.2.4")))
			end)
		end)

		T.describe("comparison operators", function()
			T.it(">= matches equal", function()
				local c = semver.constraint(">=1.0.0")
				T.ok(c:matches(semver.parse("1.0.0")))
			end)

			T.it(">= matches greater", function()
				local c = semver.constraint(">=1.0.0")
				T.ok(c:matches(semver.parse("2.0.0")))
			end)

			T.it(">= rejects lesser", function()
				local c = semver.constraint(">=1.0.0")
				T.ok(not c:matches(semver.parse("0.9.9")))
			end)

			T.it("> matches greater", function()
				local c = semver.constraint(">1.0.0")
				T.ok(c:matches(semver.parse("1.0.1")))
			end)

			T.it("> rejects equal", function()
				local c = semver.constraint(">1.0.0")
				T.ok(not c:matches(semver.parse("1.0.0")))
			end)

			T.it("<= matches equal", function()
				local c = semver.constraint("<=1.0.0")
				T.ok(c:matches(semver.parse("1.0.0")))
			end)

			T.it("<= matches lesser", function()
				local c = semver.constraint("<=1.0.0")
				T.ok(c:matches(semver.parse("0.9.9")))
			end)

			T.it("<= rejects greater", function()
				local c = semver.constraint("<=1.0.0")
				T.ok(not c:matches(semver.parse("1.0.1")))
			end)

			T.it("< matches lesser", function()
				local c = semver.constraint("<1.0.0")
				T.ok(c:matches(semver.parse("0.9.9")))
			end)

			T.it("< rejects equal", function()
				local c = semver.constraint("<1.0.0")
				T.ok(not c:matches(semver.parse("1.0.0")))
			end)
		end)

		T.describe("caret ^", function()
			T.it("^1.2.3 matches >=1.2.3 <2.0.0", function()
				local c = semver.constraint("^1.2.3")
				T.ok(c:matches(semver.parse("1.2.3")))
				T.ok(c:matches(semver.parse("1.9.9")))
				T.ok(not c:matches(semver.parse("2.0.0")))
				T.ok(not c:matches(semver.parse("1.2.2")))
			end)

			T.it("^0.2.3 matches >=0.2.3 <0.3.0", function()
				local c = semver.constraint("^0.2.3")
				T.ok(c:matches(semver.parse("0.2.3")))
				T.ok(c:matches(semver.parse("0.2.9")))
				T.ok(not c:matches(semver.parse("0.3.0")))
				T.ok(not c:matches(semver.parse("0.2.2")))
			end)

			T.it("^0.0.3 matches >=0.0.3 <0.0.4", function()
				local c = semver.constraint("^0.0.3")
				T.ok(c:matches(semver.parse("0.0.3")))
				T.ok(not c:matches(semver.parse("0.0.4")))
				T.ok(not c:matches(semver.parse("0.0.2")))
			end)

			T.it("^1.0.0 matches up to <2.0.0", function()
				local c = semver.constraint("^1.0.0")
				T.ok(c:matches(semver.parse("1.0.0")))
				T.ok(c:matches(semver.parse("1.99.99")))
				T.ok(not c:matches(semver.parse("2.0.0")))
			end)
		end)

		T.describe("tilde ~", function()
			T.it("~1.2.3 matches >=1.2.3 <1.3.0", function()
				local c = semver.constraint("~1.2.3")
				T.ok(c:matches(semver.parse("1.2.3")))
				T.ok(c:matches(semver.parse("1.2.9")))
				T.ok(not c:matches(semver.parse("1.3.0")))
				T.ok(not c:matches(semver.parse("1.2.2")))
			end)

			T.it("~1.2 matches >=1.2.0 <1.3.0", function()
				local c = semver.constraint("~1.2")
				T.ok(c:matches(semver.parse("1.2.0")))
				T.ok(c:matches(semver.parse("1.2.9")))
				T.ok(not c:matches(semver.parse("1.3.0")))
			end)

			T.it("~1 matches >=1.0.0 <2.0.0", function()
				local c = semver.constraint("~1")
				T.ok(c:matches(semver.parse("1.0.0")))
				T.ok(c:matches(semver.parse("1.9.9")))
				T.ok(not c:matches(semver.parse("2.0.0")))
			end)

			T.it("~0.2.3 matches >=0.2.3 <0.3.0", function()
				local c = semver.constraint("~0.2.3")
				T.ok(c:matches(semver.parse("0.2.3")))
				T.ok(c:matches(semver.parse("0.2.9")))
				T.ok(not c:matches(semver.parse("0.3.0")))
			end)
		end)

		T.describe("wildcard x/X/*", function()
			T.it("* matches any version", function()
				local c = semver.constraint("*")
				T.ok(c:matches(semver.parse("0.0.0")))
				T.ok(c:matches(semver.parse("99.99.99")))
			end)

			T.it("1.2.x matches >=1.2.0 <1.3.0", function()
				local c = semver.constraint("1.2.x")
				T.ok(c:matches(semver.parse("1.2.0")))
				T.ok(c:matches(semver.parse("1.2.9")))
				T.ok(not c:matches(semver.parse("1.3.0")))
				T.ok(not c:matches(semver.parse("1.1.9")))
			end)

			T.it("1.x matches >=1.0.0 <2.0.0", function()
				local c = semver.constraint("1.x")
				T.ok(c:matches(semver.parse("1.0.0")))
				T.ok(c:matches(semver.parse("1.99.99")))
				T.ok(not c:matches(semver.parse("2.0.0")))
			end)

			T.it("1.2.X works (uppercase)", function()
				local c = semver.constraint("1.2.X")
				T.ok(c:matches(semver.parse("1.2.5")))
				T.ok(not c:matches(semver.parse("1.3.0")))
			end)

			T.it("1.2.* works (asterisk)", function()
				local c = semver.constraint("1.2.*")
				T.ok(c:matches(semver.parse("1.2.5")))
				T.ok(not c:matches(semver.parse("1.3.0")))
			end)
		end)

		T.describe("compound constraints", function()
			T.it(">=1.0.0 <2.0.0 matches range", function()
				local c = semver.constraint(">=1.0.0 <2.0.0")
				T.ok(c:matches(semver.parse("1.0.0")))
				T.ok(c:matches(semver.parse("1.5.0")))
				T.ok(not c:matches(semver.parse("2.0.0")))
				T.ok(not c:matches(semver.parse("0.9.9")))
			end)

			T.it(">=1.0.0 <=2.0.0 includes upper bound", function()
				local c = semver.constraint(">=1.0.0 <=2.0.0")
				T.ok(c:matches(semver.parse("2.0.0")))
			end)

			T.it(">1.0.0 <1.5.0 narrow range", function()
				local c = semver.constraint(">1.0.0 <1.5.0")
				T.ok(not c:matches(semver.parse("1.0.0")))
				T.ok(c:matches(semver.parse("1.2.0")))
				T.ok(not c:matches(semver.parse("1.5.0")))
			end)
		end)

		T.describe("constraint errors", function()
			T.it("rejects non-string", function()
				local c, err = semver.constraint(123)
				T.eq(c, nil)
				T.ok(err)
			end)

			T.it("rejects empty string", function()
				local c, err = semver.constraint("")
				T.eq(c, nil)
				T.ok(err)
			end)

			T.it("rejects invalid version in constraint", function()
				local c, err = semver.constraint(">=not.a.version")
				T.eq(c, nil)
				T.ok(err)
			end)
		end)

		T.describe("constraint tostring", function()
			T.it("preserves source string", function()
				T.eq(tostring(semver.constraint(">=1.0.0 <2.0.0")), ">=1.0.0 <2.0.0")
			end)
		end)
	end)

	T.describe("new", function()
		T.it("creates a version from components", function()
			local v = semver.new(1, 2, 3)
			T.eq(v.major, 1)
			T.eq(v.minor, 2)
			T.eq(v.patch, 3)
			T.eq(tostring(v), "1.2.3")
		end)

		T.it("creates a version with prerelease and build", function()
			local v = semver.new(1, 2, 3, "alpha", "build.1")
			T.eq(v.prerelease, "alpha")
			T.eq(v.build, "build.1")
			T.eq(tostring(v), "1.2.3-alpha+build.1")
		end)
	end)

	T.describe("edge cases", function()
		T.it("0.0.0 is valid and minimal", function()
			local v = semver.parse("0.0.0")
			T.ok(v)
			T.eq(tostring(v), "0.0.0")
		end)

		T.it("0.0.0-0 is valid", function()
			local v = semver.parse("0.0.0-0")
			T.ok(v)
			T.eq(v.prerelease, "0")
		end)

		T.it("single digit prerelease 0 is allowed", function()
			local v = semver.parse("1.0.0-0")
			T.ok(v)
		end)

		T.it("comparison is transitive", function()
			local a = semver.parse("1.0.0")
			local b = semver.parse("1.1.0")
			local c = semver.parse("1.2.0")
			T.ok(a:lt(b))
			T.ok(b:lt(c))
			T.ok(a:lt(c))
		end)

		T.it("cmp returns exactly -1, 0, or 1", function()
			local v1 = semver.parse("1.0.0")
			local v2 = semver.parse("2.0.0")
			T.eq(v1:cmp(v2), -1)
			T.eq(v2:cmp(v1), 1)
			T.eq(v1:cmp(v1), 0)
		end)

		T.it("inc_major from 0.0.0", function()
			T.eq(tostring(semver.parse("0.0.0"):inc_major()), "1.0.0")
		end)

		T.it("inc_minor from 0.0.0", function()
			T.eq(tostring(semver.parse("0.0.0"):inc_minor()), "0.1.0")
		end)

		T.it("inc_patch from 0.0.0", function()
			T.eq(tostring(semver.parse("0.0.0"):inc_patch()), "0.0.1")
		end)

		T.it("constraint with prerelease version", function()
			local c = semver.constraint(">=1.0.0-alpha")
			T.ok(c:matches(semver.parse("1.0.0-alpha")))
			T.ok(c:matches(semver.parse("1.0.0-beta")))
			T.ok(c:matches(semver.parse("1.0.0")))
		end)
	end)
end)
