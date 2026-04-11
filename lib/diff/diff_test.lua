if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local diff = require("lib.diff")

-- Helper: collect ops from edit script
local function ops(edits)
  local r = {}
  for i = 1, #edits do r[i] = edits[i].op end
  return r
end

-- Helper: collect vals from edit script
local function vals(edits)
  local r = {}
  for i = 1, #edits do r[i] = edits[i].val end
  return r
end

-- Helper: deep equality for arrays
local function arr_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

T.describe("split_lines", function()
  T.it("splits simple multiline string", function()
    local lines = diff.split_lines("a\nb\nc")
    T.eq(#lines, 3)
    T.eq(lines[1], "a\n")
    T.eq(lines[2], "b\n")
    T.eq(lines[3], "c")
  end)

  T.it("handles empty string", function()
    local lines = diff.split_lines("")
    T.eq(#lines, 0)
  end)

  T.it("handles single line no newline", function()
    local lines = diff.split_lines("hello")
    T.eq(#lines, 1)
    T.eq(lines[1], "hello")
  end)

  T.it("handles trailing newline", function()
    local lines = diff.split_lines("a\n")
    T.eq(#lines, 1)
    T.eq(lines[1], "a\n")
  end)

  T.it("handles multiple trailing newlines", function()
    local lines = diff.split_lines("a\n\n")
    T.eq(#lines, 2)
    T.eq(lines[1], "a\n")
    T.eq(lines[2], "\n")
  end)
end)

T.describe("diff", function()
  T.it("both empty", function()
    local edits = diff.diff({}, {})
    T.eq(#edits, 0)
  end)

  T.it("a empty, b non-empty", function()
    local edits = diff.diff({}, {"x", "y"})
    T.eq(#edits, 2)
    T.eq(edits[1].op, "insert")
    T.eq(edits[1].val, "x")
    T.eq(edits[1].b_idx, 1)
    T.eq(edits[2].op, "insert")
    T.eq(edits[2].val, "y")
    T.eq(edits[2].b_idx, 2)
  end)

  T.it("a non-empty, b empty", function()
    local edits = diff.diff({"x", "y"}, {})
    T.eq(#edits, 2)
    T.eq(edits[1].op, "delete")
    T.eq(edits[1].val, "x")
    T.eq(edits[1].a_idx, 1)
    T.eq(edits[2].op, "delete")
    T.eq(edits[2].val, "y")
    T.eq(edits[2].a_idx, 2)
  end)

  T.it("identical sequences", function()
    local edits = diff.diff({"a", "b", "c"}, {"a", "b", "c"})
    T.eq(#edits, 3)
    for i = 1, 3 do
      T.eq(edits[i].op, "equal")
    end
  end)

  T.it("completely different", function()
    local edits = diff.diff({"a", "b"}, {"c", "d"})
    local ins, del = 0, 0
    for i = 1, #edits do
      if edits[i].op == "insert" then ins = ins + 1 end
      if edits[i].op == "delete" then del = del + 1 end
    end
    T.eq(del, 2)
    T.eq(ins, 2)
  end)

  T.it("single insertion at end", function()
    local edits = diff.diff({"a", "b"}, {"a", "b", "c"})
    local o = ops(edits)
    T.ok(arr_eq(o, {"equal", "equal", "insert"}))
    T.eq(edits[3].val, "c")
    T.eq(edits[3].b_idx, 3)
  end)

  T.it("single insertion at start", function()
    local edits = diff.diff({"b", "c"}, {"a", "b", "c"})
    local o = ops(edits)
    T.ok(arr_eq(o, {"insert", "equal", "equal"}))
    T.eq(edits[1].val, "a")
  end)

  T.it("single deletion", function()
    local edits = diff.diff({"a", "b", "c"}, {"a", "c"})
    local o = ops(edits)
    T.ok(arr_eq(o, {"equal", "delete", "equal"}))
    T.eq(edits[2].val, "b")
    T.eq(edits[2].a_idx, 2)
  end)

  T.it("single element arrays identical", function()
    local edits = diff.diff({"x"}, {"x"})
    T.eq(#edits, 1)
    T.eq(edits[1].op, "equal")
    T.eq(edits[1].val, "x")
  end)

  T.it("single element arrays different", function()
    local edits = diff.diff({"x"}, {"y"})
    T.eq(#edits, 2)
    -- Should be delete x, insert y (or insert y, delete x)
    local has_del, has_ins = false, false
    for i = 1, #edits do
      if edits[i].op == "delete" and edits[i].val == "x" then has_del = true end
      if edits[i].op == "insert" and edits[i].val == "y" then has_ins = true end
    end
    T.ok(has_del)
    T.ok(has_ins)
  end)

  T.it("multiple changes interspersed", function()
    local a = {"a", "b", "c", "d", "e"}
    local b = {"a", "x", "c", "y", "e"}
    local edits = diff.diff(a, b)
    -- Must contain equal for a, c, e and changes for b->x, d->y
    local eq_vals = {}
    for i = 1, #edits do
      if edits[i].op == "equal" then
        eq_vals[#eq_vals + 1] = edits[i].val
      end
    end
    T.ok(arr_eq(eq_vals, {"a", "c", "e"}))
  end)

  T.it("indices are correct for mixed operations", function()
    local edits = diff.diff({"a", "b"}, {"a", "c"})
    -- a is equal, b is deleted, c is inserted
    T.eq(edits[1].op, "equal")
    T.eq(edits[1].a_idx, 1)
    T.eq(edits[1].b_idx, 1)
  end)

  T.it("numeric values", function()
    local edits = diff.diff({1, 2, 3}, {1, 3})
    local o = ops(edits)
    T.ok(arr_eq(o, {"equal", "delete", "equal"}))
    T.eq(edits[2].val, 2)
  end)
end)

T.describe("diff_strings", function()
  T.it("identical strings", function()
    local edits = diff.diff_strings("hello\nworld\n", "hello\nworld\n")
    T.eq(#edits, 2)
    T.eq(edits[1].op, "equal")
    T.eq(edits[2].op, "equal")
  end)

  T.it("single line change", function()
    local edits = diff.diff_strings("a\nb\nc\n", "a\nx\nc\n")
    local eq_count = 0
    for i = 1, #edits do
      if edits[i].op == "equal" then eq_count = eq_count + 1 end
    end
    T.eq(eq_count, 2) -- a and c lines are equal
  end)

  T.it("empty strings", function()
    local edits = diff.diff_strings("", "")
    T.eq(#edits, 0)
  end)

  T.it("one empty one not", function()
    local edits = diff.diff_strings("", "hello\n")
    T.eq(#edits, 1)
    T.eq(edits[1].op, "insert")
  end)

  T.it("added lines", function()
    local edits = diff.diff_strings("a\n", "a\nb\nc\n")
    local ins = 0
    for i = 1, #edits do
      if edits[i].op == "insert" then ins = ins + 1 end
    end
    T.eq(ins, 2)
  end)
end)

T.describe("patch", function()
  T.it("roundtrip empty", function()
    local a, b = {}, {}
    local result = diff.patch(a, diff.diff(a, b))
    T.eq(#result, 0)
  end)

  T.it("roundtrip identical", function()
    local a = {"a", "b", "c"}
    local result = diff.patch(a, diff.diff(a, a))
    T.ok(arr_eq(result, a))
  end)

  T.it("roundtrip insertion", function()
    local a = {"a", "c"}
    local b = {"a", "b", "c"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("roundtrip deletion", function()
    local a = {"a", "b", "c"}
    local b = {"a", "c"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("roundtrip complete replacement", function()
    local a = {"x", "y"}
    local b = {"a", "b"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("roundtrip complex", function()
    local a = {"the", "quick", "brown", "fox"}
    local b = {"the", "slow", "brown", "dog"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("roundtrip a empty", function()
    local a = {}
    local b = {"x", "y", "z"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("roundtrip b empty", function()
    local a = {"x", "y", "z"}
    local b = {}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("roundtrip single element change", function()
    local a = {"a"}
    local b = {"b"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("roundtrip long sequences", function()
    local a = {}
    local b = {}
    for i = 1, 20 do a[i] = tostring(i) end
    for i = 1, 20 do
      if i % 3 == 0 then
        b[#b + 1] = "new" .. i
      else
        b[#b + 1] = tostring(i)
      end
    end
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)
end)

T.describe("lcs", function()
  T.it("both empty", function()
    local result = diff.lcs({}, {})
    T.eq(#result, 0)
  end)

  T.it("one empty", function()
    local result = diff.lcs({"a", "b"}, {})
    T.eq(#result, 0)
  end)

  T.it("identical", function()
    local result = diff.lcs({"a", "b", "c"}, {"a", "b", "c"})
    T.ok(arr_eq(result, {"a", "b", "c"}))
  end)

  T.it("no common elements", function()
    local result = diff.lcs({"a", "b"}, {"c", "d"})
    T.eq(#result, 0)
  end)

  T.it("classic example", function()
    local result = diff.lcs({"a", "b", "c", "d", "e"}, {"a", "c", "e"})
    T.ok(arr_eq(result, {"a", "c", "e"}))
  end)

  T.it("subsequence is correct length", function()
    local a = {"x", "a", "y", "b", "z"}
    local b = {"a", "b", "c"}
    local result = diff.lcs(a, b)
    T.ok(arr_eq(result, {"a", "b"}))
  end)

  T.it("single common element", function()
    local result = diff.lcs({"a", "x"}, {"y", "a"})
    T.ok(arr_eq(result, {"a"}))
  end)
end)

T.describe("unified", function()
  T.it("no changes returns empty", function()
    local text = diff.unified({"a", "b", "c"}, {"a", "b", "c"})
    T.eq(text, "")
  end)

  T.it("has header lines", function()
    local text = diff.unified({"a"}, {"b"}, { a_name = "file1", b_name = "file2" })
    T.ok(text:find("--- file1", 1, true) ~= nil)
    T.ok(text:find("+++ file2", 1, true) ~= nil)
  end)

  T.it("has hunk header", function()
    local text = diff.unified({"a"}, {"b"})
    T.ok(text:find("@@") ~= nil)
  end)

  T.it("shows deletions with minus", function()
    local text = diff.unified({"a", "b"}, {"a"})
    T.ok(text:find("%-b", 1) ~= nil)
  end)

  T.it("shows insertions with plus", function()
    local text = diff.unified({"a"}, {"a", "b"})
    T.ok(text:find("%+b", 1) ~= nil)
  end)

  T.it("default names are a and b", function()
    local text = diff.unified({"x"}, {"y"})
    T.ok(text:find("--- a", 1, true) ~= nil)
    T.ok(text:find("+++ b", 1, true) ~= nil)
  end)

  T.it("context lines included", function()
    local a = {"1", "2", "3", "4", "5"}
    local b = {"1", "2", "X", "4", "5"}
    local text = diff.unified(a, b, { context = 1 })
    -- Should include context around the change
    T.ok(text:find(" 2", 1, true) ~= nil)
    T.ok(text:find(" 4", 1, true) ~= nil)
  end)
end)

T.describe("edge cases", function()
  T.it("repeated elements", function()
    local a = {"a", "a", "a"}
    local b = {"a", "a"}
    local edits = diff.diff(a, b)
    local result = diff.patch(a, edits)
    T.ok(arr_eq(result, b))
  end)

  T.it("all same then one different", function()
    local a = {"x", "x", "x"}
    local b = {"x", "x", "y"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("prefix match", function()
    local a = {"a", "b", "c"}
    local b = {"a", "b", "c", "d", "e"}
    local edits = diff.diff(a, b)
    local ins = 0
    for i = 1, #edits do
      if edits[i].op == "insert" then ins = ins + 1 end
    end
    T.eq(ins, 2)
    T.ok(arr_eq(diff.patch(a, edits), b))
  end)

  T.it("suffix match", function()
    local a = {"c", "d", "e"}
    local b = {"a", "b", "c", "d", "e"}
    local edits = diff.diff(a, b)
    local ins = 0
    for i = 1, #edits do
      if edits[i].op == "insert" then ins = ins + 1 end
    end
    T.eq(ins, 2)
    T.ok(arr_eq(diff.patch(a, edits), b))
  end)

  T.it("interleaved insertions and deletions", function()
    local a = {"a", "b", "c", "d"}
    local b = {"w", "a", "x", "c", "y"}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)

  T.it("boolean values", function()
    local a = {true, false, true}
    local b = {true, true}
    local result = diff.patch(a, diff.diff(a, b))
    T.ok(arr_eq(result, b))
  end)
end)
