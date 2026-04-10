if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local regex = require("lib.regex")

-- Also try loading both tiers for parity testing
local has_system, system = pcall(require, "lib.regex.system")
local pure = require("lib.regex.pure")

T.describe("regex", function()
	T.it("has a known _tier value", function()
		T.ok(regex._tier == "system-pcre2" or regex._tier == "pure-lua",
			"_tier is " .. tostring(regex._tier))
	end)

	T.it("matches a basic literal", function()
		T.eq(regex.match("hello", "say hello world"), "hello")
	end)

	T.it("supports case-insensitive flag", function()
		local r, err = regex.compile("hello", "i")
		T.ok(r, err)
		T.eq(r:match("Say HELLO World"), "HELLO")
	end)

	T.it("supports ^ anchor", function()
		T.eq(regex.match("^hello", "hello world"), "hello")
		T.eq(regex.match("^hello", "say hello"), nil)
	end)

	T.it("supports $ anchor", function()
		T.eq(regex.match("world$", "hello world"), "world")
		T.eq(regex.match("world$", "world hello"), nil)
	end)

	T.it("supports character classes [abc]", function()
		T.eq(regex.match("[aeiou]", "hello"), "e")
		T.eq(regex.match("[xyz]", "hello"), nil)
	end)

	T.it("supports character ranges [a-z]", function()
		T.eq(regex.match("[0-9]+", "abc123def"), "123")
	end)

	T.it("supports negated classes [^x]", function()
		T.eq(regex.match("[^a-z]", "abc1def"), "1")
	end)

	T.it("supports * quantifier", function()
		T.eq(regex.match("ab*c", "ac"), "ac")
		T.eq(regex.match("ab*c", "abc"), "abc")
		T.eq(regex.match("ab*c", "abbc"), "abbc")
	end)

	T.it("supports + quantifier", function()
		T.eq(regex.match("ab+c", "ac"), nil)
		T.eq(regex.match("ab+c", "abc"), "abc")
		T.eq(regex.match("ab+c", "abbc"), "abbc")
	end)

	T.it("supports ? quantifier", function()
		T.eq(regex.match("ab?c", "ac"), "ac")
		T.eq(regex.match("ab?c", "abc"), "abc")
		T.eq(regex.match("ab?c", "abbc"), nil)
	end)

	T.it("dot matches any character", function()
		T.eq(regex.match("h.llo", "hello"), "hello")
		T.eq(regex.match("h.llo", "hxllo"), "hxllo")
	end)

	T.it("supports \\d \\w \\s shorthand classes", function()
		T.eq(regex.match("\\d+", "abc123"), "123")
		T.eq(regex.match("\\w+", "hello world"), "hello")
		T.eq(regex.match("\\s+", "hello world"), " ")
	end)

	T.it("supports capture groups", function()
		local user, domain = regex.match("(\\w+)@(\\w+)", "user@host")
		T.eq(user, "user")
		T.eq(domain, "host")
	end)

	T.it("find returns positions", function()
		local s, e = regex.find("world", "hello world")
		T.eq(s, 7)
		T.eq(e, 11)
	end)

	T.it("gmatch iterates all matches", function()
		local results = {}
		for m in regex.gmatch("\\w+", "one two three") do
			results[#results + 1] = m
		end
		T.eq(#results, 3)
		T.eq(results[1], "one")
		T.eq(results[2], "two")
		T.eq(results[3], "three")
	end)

	T.it("gsub replaces with string", function()
		local result, count = regex.gsub("\\d+", "a1b2c3", "N")
		T.eq(result, "aNbNcN")
		T.eq(count, 3)
	end)

	T.it("gsub replaces with function", function()
		local result, count = regex.gsub("\\d+", "a1b22c333", function(m)
			return "[" .. m .. "]"
		end)
		T.eq(result, "a[1]b[22]c[333]")
		T.eq(count, 3)
	end)

	T.it("gsub respects count limit", function()
		local result, count = regex.gsub("\\d+", "a1b2c3", "N", 2)
		T.eq(result, "aNbNc3")
		T.eq(count, 2)
	end)

	T.it("split by pattern", function()
		local parts = regex.split("[,;]+", "a,b;;c,d")
		T.eq(#parts, 4)
		T.eq(parts[1], "a")
		T.eq(parts[2], "b")
		T.eq(parts[3], "c")
		T.eq(parts[4], "d")
	end)

	T.it("compiled regex can be reused", function()
		local r = regex.compile("\\d+")
		T.ok(r)
		T.eq(r:match("abc123"), "123")
		T.eq(r:match("456def"), "456")
		T.eq(r:match("no digits"), nil)
	end)

	T.it("returns nil on no match", function()
		T.eq(regex.match("xyz", "hello"), nil)
		T.eq(regex.find("xyz", "hello"), nil)
	end)

	T.it("returns nil and errmsg on invalid pattern", function()
		local r, err = regex.compile("[unclosed")
		T.eq(r, nil)
		T.ok(type(err) == "string", "error is a string")
	end)

	T.it("supports alternation cat|dog", function()
		T.eq(regex.match("cat|dog", "I have a cat"), "cat")
		T.eq(regex.match("cat|dog", "I have a dog"), "dog")
		T.eq(regex.match("cat|dog", "I have a fish"), nil)
	end)

	T.it("supports nested groups", function()
		local outer, inner = regex.match("((\\w+)@\\w+)", "user@host")
		T.eq(outer, "user@host")
		T.eq(inner, "user")
	end)
end)

-- Parity tests: if both tiers are available, run the same inputs through each
-- and verify identical results on the common subset.
if has_system and system then
	T.describe("regex parity (system vs pure)", function()
		local cases = {
			{ pat = "hello",       subj = "say hello world" },
			{ pat = "\\d+",        subj = "abc123def" },
			{ pat = "\\w+",        subj = "hello world" },
			{ pat = "[aeiou]",     subj = "hello" },
			{ pat = "ab*c",        subj = "abbc" },
			{ pat = "ab+c",        subj = "abc" },
			{ pat = "ab?c",        subj = "ac" },
			{ pat = "cat|dog",     subj = "I have a dog" },
			{ pat = "^hello",      subj = "hello world" },
			{ pat = "world$",      subj = "hello world" },
		}
		for _, c in ipairs(cases) do
			T.it("match parity: /" .. c.pat .. "/ on '" .. c.subj .. "'", function()
				local sm = system.match(c.pat, c.subj)
				local pm = pure.match(c.pat, c.subj)
				T.eq(sm, pm, "match result differs")
			end)
			T.it("find parity: /" .. c.pat .. "/ on '" .. c.subj .. "'", function()
				local ss, se = system.find(c.pat, c.subj)
				local ps, pe = pure.find(c.pat, c.subj)
				T.eq(ss, ps, "find start differs")
				T.eq(se, pe, "find end differs")
			end)
		end
	end)
end

T.describe("regex (pure tier directly)", function()
	T.it("has correct _tier", function()
		T.eq(pure._tier, "pure-lua")
	end)

	T.it("basic match works", function()
		T.eq(pure.match("hello", "say hello world"), "hello")
	end)

	T.it("captures work", function()
		local u, d = pure.match("(\\w+)@(\\w+)", "user@host")
		T.eq(u, "user")
		T.eq(d, "host")
	end)

	T.it("find returns positions", function()
		local s, e = pure.find("world", "hello world")
		T.eq(s, 7)
		T.eq(e, 11)
	end)

	T.it("gmatch iterates", function()
		local results = {}
		for m in pure.gmatch("\\w+", "one two three") do
			results[#results + 1] = m
		end
		T.eq(#results, 3)
		T.eq(results[1], "one")
	end)

	T.it("split works", function()
		local parts = pure.split(",", "a,b,c")
		T.eq(#parts, 3)
		T.eq(parts[1], "a")
		T.eq(parts[2], "b")
		T.eq(parts[3], "c")
	end)
end)
