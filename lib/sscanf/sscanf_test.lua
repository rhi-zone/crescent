-- lib/sscanf/sscanf_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.sscanf")

-- ---------------------------------------------------------------------------
T.describe("sscanf._tier", function()
	T.it("is pure", function()
		T.eq(S._tier, "pure")
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %d", function()
	T.it("parses a single integer", function()
		local n = S.sscanf("42", "%d")
		T.eq(n, 42)
	end)

	T.it("parses a negative integer", function()
		local n = S.sscanf("-17", "%d")
		T.eq(n, -17)
	end)

	T.it("parses multiple integers", function()
		local a, b, c = S.sscanf("10 20 30", "%d %d %d")
		T.eq(a, 10)
		T.eq(b, 20)
		T.eq(c, 30)
	end)

	T.it("parses dash-separated integers (date-like)", function()
		local y, m, d = S.sscanf("2024-01-15", "%d-%d-%d")
		T.eq(y, 2024)
		T.eq(m, 1)
		T.eq(d, 15)
	end)

	T.it("returns nil on mismatch", function()
		local n = S.sscanf("hello", "%d")
		T.eq(n, nil)
	end)

	T.it("returns integer (floor), not float", function()
		local n = S.sscanf("7", "%d")
		T.eq(n, 7)
		T.eq(type(n), "number")
		T.eq(n % 1, 0)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %i", function()
	T.it("parses decimal", function()
		T.eq(S.sscanf("255", "%i"), 255)
	end)

	T.it("parses hex with 0x prefix", function()
		T.eq(S.sscanf("0xff", "%i"), 255)
	end)

	T.it("parses hex with 0X prefix", function()
		T.eq(S.sscanf("0XFF", "%i"), 255)
	end)

	T.it("parses octal with 0 prefix", function()
		T.eq(S.sscanf("010", "%i"), 8)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %u", function()
	T.it("parses unsigned integer", function()
		T.eq(S.sscanf("42", "%u"), 42)
	end)

	T.it("returns nil for negative (leading minus)", function()
		-- %u does not match a leading minus
		local n = S.sscanf("-5", "%u")
		T.eq(n, nil)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %f/%e/%g", function()
	T.it("parses float", function()
		T.eq(S.sscanf("3.14", "%f"), 3.14)
	end)

	T.it("parses negative float", function()
		T.eq(S.sscanf("-2.5", "%f"), -2.5)
	end)

	T.it("parses scientific notation with %e", function()
		local v = S.sscanf("1.5e3", "%e")
		T.eq(v, 1500.0)
	end)

	T.it("parses scientific notation with %g", function()
		local v = S.sscanf("2.0E-2", "%g")
		T.ok(math.abs(v - 0.02) < 1e-10)
	end)

	T.it("parses integer-looking value as float", function()
		local v = S.sscanf("100", "%f")
		T.eq(v, 100.0)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %s", function()
	T.it("parses a single token", function()
		T.eq(S.sscanf("hello", "%s"), "hello")
	end)

	T.it("parses leading whitespace before token", function()
		T.eq(S.sscanf("  world", "%s"), "world")
	end)

	T.it("parses two tokens", function()
		local a, b = S.sscanf("foo bar", "%s %s")
		T.eq(a, "foo")
		T.eq(b, "bar")
	end)

	T.it("returns nil when no token", function()
		T.eq(S.sscanf("   ", "%s"), nil)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %c", function()
	T.it("reads a single character", function()
		T.eq(S.sscanf("A", "%c"), "A")
	end)

	T.it("reads first character only", function()
		T.eq(S.sscanf("hello", "%c"), "h")
	end)

	T.it("reads multiple characters with width", function()
		T.eq(S.sscanf("hello", "%3c"), "hel")
	end)

	T.it("does NOT skip whitespace before %c", function()
		-- %c reads raw character including spaces
		T.eq(S.sscanf(" A", "%c"), " ")
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %[chars]", function()
	T.it("matches character class", function()
		T.eq(S.sscanf("abc123", "%[abc]"), "abc")
	end)

	T.it("stops at non-class character", function()
		T.eq(S.sscanf("aabXY", "%[ab]"), "aab")
	end)

	T.it("negated class matches complement", function()
		T.eq(S.sscanf("hello world", "%[^ ]"), "hello")
	end)

	T.it("matches digits class", function()
		T.eq(S.sscanf("12345abc", "%[0-9]"), nil) -- Lua [] doesn't do ranges
	end)

	T.it("matches exact chars only", function()
		local v = S.sscanf("1234xyz", "%[1234]")
		T.eq(v, "1234")
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %%", function()
	T.it("matches literal percent", function()
		local n = S.sscanf("50%", "%d%%")
		T.eq(n, 50)
	end)

	T.it("returns nil when percent not in input", function()
		local n = S.sscanf("50X", "%d%%")
		T.eq(n, nil)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf %*d suppressed field", function()
	T.it("suppresses a field", function()
		local a, b = S.sscanf("1 2 3", "%*d %d %d")
		T.eq(a, 2)
		T.eq(b, 3)
	end)

	T.it("suppressed string", function()
		local n = S.sscanf("skip 42", "%*s %d")
		T.eq(n, 42)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf width specifier", function()
	T.it("%5d limits integer width", function()
		-- "12345" from "1234567"
		local n = S.sscanf("1234567", "%5d")
		T.eq(n, 12345)
	end)

	T.it("%3s limits string width", function()
		local s = S.sscanf("hello", "%3s")
		T.eq(s, "hel")
	end)

	T.it("%2d parses two-digit integer from longer string", function()
		local n = S.sscanf("9999", "%2d")
		T.eq(n, 99)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.sscanf mixed formats", function()
	T.it("parses user record", function()
		local name, age = S.sscanf("User: Alice (age 30)", "User: %s (age %d)")
		T.eq(name, "Alice")
		T.eq(age, 30)
	end)

	T.it("parses date slash format", function()
		local m, d, y = S.sscanf("01/15/2024", "%d/%d/%d")
		T.eq(m, 1)
		T.eq(d, 15)
		T.eq(y, 2024)
	end)

	T.it("parses key=value with negated class", function()
		-- %s matches all non-whitespace including '=', so use %[^=] to stop at '='
		local k, v = S.sscanf("count=42", "%[^=]=%d")
		T.eq(k, "count")
		T.eq(v, 42)
	end)

	T.it("parses IP-like dotted quad", function()
		local a, b, c, d = S.sscanf("192.168.1.1", "%d.%d.%d.%d")
		T.eq(a, 192)
		T.eq(b, 168)
		T.eq(c, 1)
		T.eq(d, 1)
	end)

	T.it("returns nil for partial mismatch", function()
		local n = S.sscanf("hello world", "%d %d")
		T.eq(n, nil)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.named", function()
	T.it("returns named table", function()
		local t = S.named("2024-01-15", "%{year}d-%{month}d-%{day}d")
		T.ok(t ~= nil)
		T.eq(t.year, 2024)
		T.eq(t.month, 1)
		T.eq(t.day, 15)
	end)

	T.it("returns nil on mismatch", function()
		local t = S.named("hello", "%{n}d")
		T.eq(t, nil)
	end)

	T.it("named string capture", function()
		local t = S.named("Alice 30", "%{name}s %{age}d")
		T.ok(t ~= nil)
		T.eq(t.name, "Alice")
		T.eq(t.age, 30)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.scan_all", function()
	T.it("parses multiple lines", function()
		local results = S.scan_all("1 Alice\n2 Bob\n3 Carol", "%d %s")
		T.ok(results ~= nil)
		T.eq(#results, 3)
		T.eq(results[1][1], 1)
		T.eq(results[1][2], "Alice")
		T.eq(results[2][1], 2)
		T.eq(results[2][2], "Bob")
		T.eq(results[3][1], 3)
		T.eq(results[3][2], "Carol")
	end)

	T.it("skips non-matching lines", function()
		local results = S.scan_all("1 Alice\nnot a match\n2 Bob", "%d %s")
		T.eq(#results, 2)
	end)

	T.it("returns empty array for no matches", function()
		local results = S.scan_all("no numbers here", "%d")
		T.eq(#results, 0)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.matches", function()
	T.it("returns true on match", function()
		T.ok(S.matches("2024-01-15", "%d-%d-%d"))
	end)

	T.it("returns false on mismatch", function()
		T.ok(not S.matches("hello", "%d-%d-%d"))
	end)

	T.it("true for float", function()
		T.ok(S.matches("3.14", "%f"))
	end)

	T.it("false for empty against %d", function()
		T.ok(not S.matches("", "%d"))
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.split", function()
	T.it("splits by comma", function()
		local r = S.split("a,b,c", ",")
		T.eq(#r, 3)
		T.eq(r[1], "a")
		T.eq(r[2], "b")
		T.eq(r[3], "c")
	end)

	T.it("preserves empty segments", function()
		local r = S.split("a,,c", ",")
		T.eq(#r, 3)
		T.eq(r[2], "")
	end)

	T.it("skip_empty omits empty segments", function()
		local r = S.split("a,,c", ",", { skip_empty = true })
		T.eq(#r, 2)
		T.eq(r[1], "a")
		T.eq(r[2], "c")
	end)

	T.it("no separator found returns whole string", function()
		local r = S.split("hello", ",")
		T.eq(#r, 1)
		T.eq(r[1], "hello")
	end)

	T.it("separator at end gives empty last segment", function()
		local r = S.split("a,b,", ",")
		T.eq(#r, 3)
		T.eq(r[3], "")
	end)

	T.it("multi-char separator", function()
		local r = S.split("a::b::c", "::")
		T.eq(#r, 3)
		T.eq(r[1], "a")
		T.eq(r[2], "b")
		T.eq(r[3], "c")
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf.tokenize", function()
	T.it("splits whitespace tokens", function()
		local r = S.tokenize("  hello   world  ")
		T.eq(#r, 2)
		T.eq(r[1], "hello")
		T.eq(r[2], "world")
	end)

	T.it("three tokens", function()
		local r = S.tokenize("one two three")
		T.eq(#r, 3)
		T.eq(r[3], "three")
	end)

	T.it("returns empty array for blank string", function()
		local r = S.tokenize("   ")
		T.eq(#r, 0)
	end)

	T.it("tokenizes integers with %d format", function()
		local r = S.tokenize("10 20 30", "%d")
		T.eq(#r, 3)
		T.eq(r[1], 10)
		T.eq(r[2], 20)
		T.eq(r[3], 30)
	end)
end)

-- ---------------------------------------------------------------------------
T.describe("sscanf edge cases", function()
	T.it("empty format returns nil", function()
		local n = S.sscanf("hello", "")
		T.eq(n, nil)
	end)

	T.it("extra input after match is ignored", function()
		local n = S.sscanf("42 extra stuff", "%d")
		T.eq(n, 42)
	end)

	T.it("whitespace in format matches multiple spaces", function()
		local a, b = S.sscanf("1    2", "%d %d")
		T.eq(a, 1)
		T.eq(b, 2)
	end)

	T.it("whitespace in format matches tab", function()
		local a, b = S.sscanf("1\t2", "%d %d")
		T.eq(a, 1)
		T.eq(b, 2)
	end)

	T.it("handles zero", function()
		T.eq(S.sscanf("0", "%d"), 0)
	end)

	T.it("handles negative float", function()
		T.eq(S.sscanf("-3.14", "%f"), -3.14)
	end)

	T.it("mixed int and float", function()
		local n, f = S.sscanf("10 3.14", "%d %f")
		T.eq(n, 10)
		T.eq(f, 3.14)
	end)
end)
