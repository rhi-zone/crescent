-- lib/safe_regex/safe_regex_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local SR = require("lib.safe_regex")

-- Helper: assert a pattern is safe.
local function safe(pat)
  local ok, err = SR.validate_pattern(pat)
  T.ok(ok, "expected SAFE for " .. string.format("%q", pat) ..
    " but got error: " .. tostring(err))
  T.eq(err, nil)
end

-- Helper: assert a pattern is unsafe (or malformed). If `needle` is
-- given, the error message must contain it (substring match).
local function unsafe(pat, needle)
  local ok, err = SR.validate_pattern(pat)
  T.eq(ok, false, "expected UNSAFE for " .. string.format("%q", pat))
  T.ok(type(err) == "string", "expected errmsg string")
  if needle then
    T.ok(string.find(err, needle, 1, true) ~= nil,
      "errmsg " .. string.format("%q", err) ..
      " did not contain " .. string.format("%q", needle))
  end
end

T.describe("safe_regex positive cases (safe patterns accepted)", function()
  T.it("single quantifier on a literal", function() safe("a+b") end)
  T.it("quantifier on a non-quantified group", function() safe("(ab)+c") end)
  T.it("bounded fixed count", function() safe("a{3}") end)
  T.it("bounded sequence", function() safe("a{3}b{2}") end)
  T.it("quantifier on a character class", function() safe("[a-z]+") end)
  T.it("shorthand class with quantifier", function() safe("\\d+") end)
  T.it("non-capturing group with quantifier", function() safe("(?:abc)+") end)
  T.it("sibling capturing groups", function() safe("(a)(b)(c)") end)
  T.it("anchors don't compose with quantifiers", function() safe("^a+$") end)
  T.it("empty pattern is safe", function() safe("") end)
  T.it("single literal", function() safe("a") end)
  T.it("alternation of simple atoms", function() safe("foo|bar|baz") end)
  T.it("alternation with one quantified branch", function() safe("a+|b+") end)
  T.it("dot with quantifier", function() safe(".+") end)
  T.it("optional then quantified literal", function() safe("a?b+") end)
  T.it("escaped specials", function() safe("\\.\\+\\*") end)
  T.it("named group without quantifier on quantified child", function()
    safe("(?<name>abc)+")
  end)
  T.it("hex escape", function() safe("\\x41+") end)
  T.it("unicode escape", function() safe("\\u0041+") end)
  T.it("unicode brace escape", function() safe("\\u{1F600}+") end)
  T.it("word boundary", function() safe("\\bword\\b") end)
  T.it("backref alone", function() safe("(a)\\1") end)
  T.it("named backref", function() safe("(?<x>a)\\k<x>") end)
  T.it("lookahead containing only non-quantified content", function()
    safe("(?=abc)x")
  end)
  T.it("bounded {0,1} acts like ?", function() safe("a{0,1}") end)
  T.it("bounded {3,3}", function() safe("a{3,3}") end)
  T.it("bounded count on quantified-free group", function() safe("(ab){3}") end)
  T.it("alternation in non-capturing group", function() safe("(?:a|b)+") end)
end)

T.describe("safe_regex negative cases (catastrophic patterns rejected)", function()
  T.it("(a+)+", function() unsafe("(a+)+", "nested quantifier") end)
  T.it("(a*)*", function() unsafe("(a*)*", "nested quantifier") end)
  T.it("(a+)*b", function() unsafe("(a+)*b", "nested quantifier") end)
  T.it("(\\d+)+", function() unsafe("(\\d+)+", "nested quantifier") end)
  T.it("(a*)+", function() unsafe("(a*)+", "nested quantifier") end)
  T.it("non-capturing wrapping nested", function()
    unsafe("(?:a+)+", "nested quantifier")
  end)
  T.it("named group nesting", function()
    unsafe("(?<x>a+)+", "nested quantifier")
  end)
  T.it("lookahead containing (.+)+", function()
    unsafe("(?=(.+)+)x", "nested quantifier")
  end)
  T.it("deeply nested groups stacking quantifiers", function()
    unsafe("((a+)+)+", "nested quantifier")
  end)
  T.it("alternation branch contributes unbounded", function()
    -- (a|b+)+ -- the inner b+ makes the whole alternation unbounded,
    -- and the outer + then nests on it.
    unsafe("(a|b+)+", "nested quantifier")
  end)
  T.it("bounded outer on unbounded inner -- (a+){3}", function()
    -- Documents: outer is {3} (bounded) but inner '+' is unbounded.
    -- Per the documented rule, the inner unbounded loop supplies
    -- the exponential alternative count regardless of outer kind,
    -- so we reject.
    unsafe("(a+){3}", "nested quantifier")
  end)
  T.it("range that's effectively unbounded -- (a+){2,5}", function()
    unsafe("(a+){2,5}", "nested quantifier")
  end)
end)

T.describe("safe_regex edge cases", function()
  T.it("anchor with star is rejected", function()
    unsafe("^*", "anchor")
  end)
  T.it("anchor with plus is rejected", function()
    unsafe("\\b+", "anchor")
  end)
  T.it("'?' after group is bounded so safe", function()
    safe("(abc)?")
  end)
  T.it("'?' on a quantified-free child is bounded", function()
    safe("a?")
  end)
  T.it("'{0,0}' is bounded", function() safe("a{0,0}") end)
  T.it("literal '{' (not a quantifier)", function() safe("a{xyz}b") end)
  T.it("non-quantifier brace doesn't cascade", function() safe("a{") end)
end)

T.describe("safe_regex malformed patterns", function()
  T.it("unbalanced '('", function() unsafe("(abc", "malformed") end)
  T.it("unbalanced ')'", function() unsafe("abc)", "malformed") end)
  T.it("unbalanced '['", function() unsafe("[abc", "malformed") end)
  T.it("trailing backslash", function() unsafe("abc\\", "malformed") end)
  T.it("quantifier with no atom", function() unsafe("+abc", "malformed") end)
  T.it("star with no atom", function() unsafe("*", "malformed") end)
  T.it("unknown group prefix", function() unsafe("(?Zabc)", "malformed") end)
  T.it("unterminated named group", function() unsafe("(?<name", "malformed") end)
  T.it("unterminated lookahead", function() unsafe("(?=", "malformed") end)
end)

T.describe("safe_regex known limitations (v1)", function()
  -- KNOWN LIMITATION: alternation overlap is not detected by this
  -- validator. Patterns of the form (a|aa)+ are catastrophic on
  -- rejecting input but pass the structural nesting check because
  -- neither branch of the alternation contains a quantifier. A
  -- stronger pass (Thompson-NFA ambiguity analysis) is planned.
  -- These tests pin current behavior so we notice if it changes.
  T.it("(a|aa)+ is currently accepted (KNOWN LIMITATION)", function()
    safe("(a|aa)+")
  end)
  T.it("(a|a)+ is currently accepted (KNOWN LIMITATION)", function()
    safe("(a|a)+")
  end)
  T.it("(.|.)+ is currently accepted (KNOWN LIMITATION)", function()
    safe("(.|.)+")
  end)
end)
