-- lib/suffix_array/suffix_array_test.lua
-- Tests for lib/suffix_array

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local SA = require("lib.suffix_array")

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

local function sorted_eq(a, b)
  if #a ~= #b then return false end
  local ca, cb = {}, {}
  for i, v in ipairs(a) do ca[i] = v end
  for i, v in ipairs(b) do cb[i] = v end
  table.sort(ca); table.sort(cb)
  for i = 1, #ca do
    if ca[i] ~= cb[i] then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- "banana" — canonical suffix array example
-- ---------------------------------------------------------------------------

T.describe("suffix array: banana", function()
  local sa = SA.new("banana")

  T.it("sa:len()", function()
    T.eq(sa:len(), 6)
  end)

  T.it("sa:str()", function()
    T.eq(sa:str(), "banana")
  end)

  T.it("sa:array() gives [6,4,2,1,5,3]", function()
    local arr = sa:array()
    T.eq(#arr, 6)
    -- Sorted suffixes of "banana":
    --   a        (pos 6)
    --   ana      (pos 4)
    --   anana    (pos 2)
    --   banana   (pos 1)
    --   na       (pos 5)
    --   nana     (pos 3)
    local expected = {6, 4, 2, 1, 5, 3}
    for i = 1, 6 do
      T.eq(arr[i], expected[i])
    end
  end)

  T.it("sa:lcp() gives [0,1,3,0,0,2]", function()
    local lcp = sa:lcp()
    T.eq(#lcp, 6)
    local expected = {0, 1, 3, 0, 0, 2}
    for i = 1, 6 do
      T.eq(lcp[i], expected[i])
    end
  end)

  T.it("sa:search('an') returns [2,4]", function()
    local res = sa:search("an")
    T.ok(sorted_eq(res, {2, 4}), "expected {2,4}, got " .. table.concat(res, ","))
  end)

  T.it("sa:count('a') = 3", function()
    T.eq(sa:count("a"), 3)
  end)

  T.it("sa:count('an') = 2", function()
    T.eq(sa:count("an"), 2)
  end)

  T.it("sa:count('banana') = 1", function()
    T.eq(sa:count("banana"), 1)
  end)

  T.it("sa:find('nan') = 3", function()
    T.eq(sa:find("nan"), 3)
  end)

  T.it("sa:find('a') returns 1-indexed position", function()
    local pos = sa:find("a")
    T.ok(pos == 2 or pos == 4 or pos == 6, "expected 2, 4 or 6, got " .. tostring(pos))
  end)

  T.it("sa:contains('nan') = true", function()
    T.ok(sa:contains("nan"))
  end)

  T.it("sa:contains('xyz') = false", function()
    T.ok(not sa:contains("xyz"))
  end)

  T.it("sa:contains('banana') = true", function()
    T.ok(sa:contains("banana"))
  end)

  T.it("sa:contains('bananax') = false (longer than string)", function()
    T.ok(not sa:contains("bananax"))
  end)

  T.it("sa:search('xyz') returns {}", function()
    T.eq(#sa:search("xyz"), 0)
  end)

  T.it("pattern longer than string → 0 results", function()
    T.eq(sa:count("bananana"), 0)
    T.eq(#sa:search("bananana"), 0)
    T.ok(not sa:contains("bananana"))
  end)

  T.it("empty pattern → all positions", function()
    local res = sa:search("")
    T.eq(#res, 6)
    T.eq(sa:count(""), 6)
  end)
end)

-- ---------------------------------------------------------------------------
-- "abcabc" — repeated substring tests
-- ---------------------------------------------------------------------------

T.describe("suffix array: abcabc", function()
  local sa = SA.new("abcabc")

  T.it("sa:len() = 6", function()
    T.eq(sa:len(), 6)
  end)

  T.it("sa:longest_repeated() has length 3 ('abc' or 'bc' or 'c')", function()
    local r = sa:longest_repeated()
    -- Maximum LCP entry should be 3 (abc repeated twice)
    T.eq(#r, 3)
  end)

  T.it("sa:search('abc') returns {1,4}", function()
    local res = sa:search("abc")
    T.ok(sorted_eq(res, {1, 4}), "expected {1,4}, got " .. table.concat(res, ","))
  end)

  T.it("sa:count('abc') = 2", function()
    T.eq(sa:count("abc"), 2)
  end)

  T.it("sa:count('bc') = 2", function()
    T.eq(sa:count("bc"), 2)
  end)

  T.it("sa:find('abc') = 1 (first occurrence)", function()
    T.eq(sa:find("abc"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Single character string
-- ---------------------------------------------------------------------------

T.describe("suffix array: single char 'a'", function()
  local sa = SA.new("a")

  T.it("sa:len() = 1", function()
    T.eq(sa:len(), 1)
  end)

  T.it("sa:array() = {1}", function()
    local arr = sa:array()
    T.eq(#arr, 1)
    T.eq(arr[1], 1)
  end)

  T.it("sa:lcp() = {0}", function()
    local lcp = sa:lcp()
    T.eq(#lcp, 1)
    T.eq(lcp[1], 0)
  end)

  T.it("sa:search('a') = {1}", function()
    local res = sa:search("a")
    T.eq(#res, 1)
    T.eq(res[1], 1)
  end)

  T.it("sa:contains('a') = true", function()
    T.ok(sa:contains("a"))
  end)

  T.it("sa:contains('b') = false", function()
    T.ok(not sa:contains("b"))
  end)

  T.it("sa:count('a') = 1", function()
    T.eq(sa:count("a"), 1)
  end)

  T.it("sa:longest_repeated() = ''", function()
    T.eq(sa:longest_repeated(), "")
  end)
end)

-- ---------------------------------------------------------------------------
-- All-same characters
-- ---------------------------------------------------------------------------

T.describe("suffix array: 'aaaa'", function()
  local sa = SA.new("aaaa")

  T.it("sa:array() sorted correctly", function()
    local arr = sa:array()
    -- Sorted suffixes: a(4), aa(3), aaa(2), aaaa(1) → positions [4,3,2,1]
    T.eq(arr[1], 4)
    T.eq(arr[2], 3)
    T.eq(arr[3], 2)
    T.eq(arr[4], 1)
  end)

  T.it("sa:lcp() for 'aaaa' = {0,1,2,3}", function()
    local lcp = sa:lcp()
    T.eq(lcp[1], 0)
    T.eq(lcp[2], 1)
    T.eq(lcp[3], 2)
    T.eq(lcp[4], 3)
  end)

  T.it("sa:count('a') = 4", function()
    T.eq(sa:count("a"), 4)
  end)

  T.it("sa:count('aa') = 3", function()
    T.eq(sa:count("aa"), 3)
  end)

  T.it("sa:count('aaa') = 2", function()
    T.eq(sa:count("aaa"), 2)
  end)

  T.it("sa:count('aaaa') = 1", function()
    T.eq(sa:count("aaaa"), 1)
  end)

  T.it("sa:count('aaaaa') = 0", function()
    T.eq(sa:count("aaaaa"), 0)
  end)

  T.it("sa:longest_repeated() has length 3", function()
    T.eq(#sa:longest_repeated(), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- Longest repeated substring edge cases
-- ---------------------------------------------------------------------------

T.describe("longest_repeated", function()
  T.it("no repeated substrings in 'abc'", function()
    local sa = SA.new("abc")
    T.eq(sa:longest_repeated(), "")
  end)

  T.it("'mississippi' has repeated substrings", function()
    local sa = SA.new("mississippi")
    local r = sa:longest_repeated()
    -- The longest repeated substring of "mississippi" is "issi" (length 4)
    T.eq(#r, 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- Longest common substring (static M.lcs_str)
-- ---------------------------------------------------------------------------

T.describe("M.lcs_str", function()
  T.it("'abcdef' and 'bcdefg' → 'bcdef'", function()
    local r = SA.lcs_str("abcdef", "bcdefg")
    T.eq(r, "bcdef")
  end)

  T.it("'abcdef' and 'bcdefg' has length 5", function()
    T.eq(#SA.lcs_str("abcdef", "bcdefg"), 5)
  end)

  T.it("'abc' and 'xyz' → ''", function()
    T.eq(SA.lcs_str("abc", "xyz"), "")
  end)

  T.it("'abc' and 'abc' → 'abc'", function()
    T.eq(SA.lcs_str("abc", "abc"), "abc")
  end)

  T.it("empty first string → ''", function()
    T.eq(SA.lcs_str("", "abc"), "")
  end)

  T.it("empty second string → ''", function()
    T.eq(SA.lcs_str("abc", ""), "")
  end)

  T.it("'banana' and 'bandana' → 'ban' or 'ana' (length >= 3)", function()
    local r = SA.lcs_str("banana", "bandana")
    T.ok(#r >= 3, "expected length >= 3, got " .. tostring(#r))
  end)

  T.it("'hello world' and 'world peace' → 'world'", function()
    local r = SA.lcs_str("hello world", "world peace")
    T.eq(r, "world")
  end)

  T.it("single chars that match", function()
    T.eq(SA.lcs_str("a", "a"), "a")
  end)

  T.it("single chars that don't match", function()
    T.eq(SA.lcs_str("a", "b"), "")
  end)
end)

-- ---------------------------------------------------------------------------
-- Correctness: verify every search result actually matches
-- ---------------------------------------------------------------------------

T.describe("search correctness invariants", function()
  local function all_matches_valid(s, p)
    local sa = SA.new(s)
    local res = sa:search(p)
    for _, pos in ipairs(res) do
      if s:sub(pos, pos + #p - 1) ~= p then return false end
    end
    return true
  end

  local function all_matches_found(s, p)
    local sa = SA.new(s)
    local res = sa:search(p)
    local found = {}
    for _, pos in ipairs(res) do found[pos] = true end
    -- Brute-force check
    local i = 1
    while i <= #s - #p + 1 do
      if s:sub(i, i + #p - 1) == p then
        if not found[i] then return false end
      end
      i = i + 1
    end
    return true
  end

  T.it("all 'an' results in 'banana' are valid", function()
    T.ok(all_matches_valid("banana", "an"))
  end)

  T.it("all 'an' results in 'banana' are complete (no miss)", function()
    T.ok(all_matches_found("banana", "an"))
  end)

  T.it("all 'a' results in 'abracadabra' are valid", function()
    T.ok(all_matches_valid("abracadabra", "a"))
  end)

  T.it("all 'a' results in 'abracadabra' are complete", function()
    T.ok(all_matches_found("abracadabra", "a"))
  end)

  T.it("all 'bra' results in 'abracadabra' valid+complete", function()
    T.ok(all_matches_valid("abracadabra", "bra"))
    T.ok(all_matches_found("abracadabra", "bra"))
  end)

  T.it("'abracadabra': sa:count('abra') = 2", function()
    local sa = SA.new("abracadabra")
    T.eq(sa:count("abra"), 2)
  end)

  T.it("'abracadabra': sa:count('abracadabra') = 1", function()
    local sa = SA.new("abracadabra")
    T.eq(sa:count("abracadabra"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Numeric / binary content
-- ---------------------------------------------------------------------------

T.describe("binary-safe strings", function()
  T.it("string with repeated bytes", function()
    local s = string.rep("\xff\x00", 4)  -- 8 chars
    local sa = SA.new(s)
    T.eq(sa:len(), 8)
    T.eq(sa:count("\xff\x00"), 4)
  end)
end)
