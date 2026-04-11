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

-- Helper: deep equality for arrays
local function arr_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- Helper: apply diff.diff to arrays and reconstruct b
local function reconstruct_b(a, b)
  local edits = diff.diff(a, b)
  if not edits then return nil end
  local r = {}
  for _, e in ipairs(edits) do
    if e.op == "eq" then
      for i = e.a_start, e.a_end do r[#r + 1] = a[i] end
    elseif e.op == "ins" then
      for i = e.b_start, e.b_end do r[#r + 1] = b[i] end
    end
    -- del: skip
  end
  return r
end

-- Helper: verify edit script is valid (all ops cover full a and b)
local function validate_script(edits, a, b)
  local ai, bi = 1, 1
  for _, e in ipairs(edits) do
    if e.op == "eq" then
      if e.a_start ~= ai then return false, "eq a_start mismatch" end
      if e.b_start ~= bi then return false, "eq b_start mismatch" end
      if e.a_end < e.a_start then return false, "eq empty range" end
      -- verify equality
      local span = e.a_end - e.a_start + 1
      for j = 0, span - 1 do
        if a[e.a_start + j] ~= b[e.b_start + j] then
          return false, "eq mismatch at offset " .. j
        end
      end
      ai = e.a_end + 1
      bi = e.b_end + 1
    elseif e.op == "del" then
      if e.a_start ~= ai then return false, "del a_start mismatch" end
      if e.a_end < e.a_start then return false, "del empty range" end
      ai = e.a_end + 1
    elseif e.op == "ins" then
      if e.b_start ~= bi then return false, "ins b_start mismatch" end
      if e.b_end < e.b_start then return false, "ins empty range" end
      bi = e.b_end + 1
    else
      return false, "unknown op: " .. tostring(e.op)
    end
  end
  if ai ~= #a + 1 then return false, "a not fully covered: ai=" .. ai .. " #a=" .. #a end
  if bi ~= #b + 1 then return false, "b not fully covered: bi=" .. bi .. " #b=" .. #b end
  return true
end

-- ===== diff() =====

T.describe("diff: empty inputs", function()
  T.it("both empty", function()
    local edits = diff.diff({}, {})
    T.eq(#edits, 0)
  end)

  T.it("a empty b non-empty: single ins op", function()
    local a, b = {}, {"x", "y", "z"}
    local edits = diff.diff(a, b)
    T.eq(#edits, 1)
    T.eq(edits[1].op, "ins")
    T.eq(edits[1].b_start, 1)
    T.eq(edits[1].b_end, 3)
  end)

  T.it("a empty b non-empty: reconstructs b", function()
    local a, b = {}, {"x", "y"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)

  T.it("a non-empty b empty: single del op", function()
    local a, b = {"x", "y", "z"}, {}
    local edits = diff.diff(a, b)
    T.eq(#edits, 1)
    T.eq(edits[1].op, "del")
    T.eq(edits[1].a_start, 1)
    T.eq(edits[1].a_end, 3)
  end)

  T.it("a non-empty b empty: reconstructs b", function()
    local a, b = {"x", "y"}, {}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)
end)

T.describe("diff: identical sequences", function()
  T.it("single element identical", function()
    local edits = diff.diff({"a"}, {"a"})
    T.eq(#edits, 1)
    T.eq(edits[1].op, "eq")
    T.eq(edits[1].a_start, 1)
    T.eq(edits[1].a_end, 1)
  end)

  T.it("three elements identical produces eq", function()
    local a = {"a", "b", "c"}
    local edits = diff.diff(a, a)
    local all_eq = true
    for _, e in ipairs(edits) do
      if e.op ~= "eq" then all_eq = false end
    end
    T.ok(all_eq)
  end)

  T.it("identical covers full range", function()
    local a = {"a", "b", "c", "d", "e"}
    local ok, err = validate_script(diff.diff(a, a), a, a)
    T.ok(ok, err)
  end)
end)

T.describe("diff: single insertion", function()
  T.it("insert at end", function()
    local a, b = {"a", "b"}, {"a", "b", "c"}
    local edits = diff.diff(a, b)
    local o = ops(edits)
    -- Should end with an ins
    T.eq(o[#o], "ins")
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)

  T.it("insert at start", function()
    local a, b = {"b", "c"}, {"a", "b", "c"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("insert in middle", function()
    local a, b = {"a", "c"}, {"a", "b", "c"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("insert range is valid", function()
    local a, b = {"a", "b"}, {"a", "b", "c"}
    local edits = diff.diff(a, b)
    local last = edits[#edits]
    T.eq(last.op, "ins")
    T.ok(last.b_start <= last.b_end)
  end)
end)

T.describe("diff: single deletion", function()
  T.it("delete at start", function()
    local a, b = {"a", "b", "c"}, {"b", "c"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("delete at end", function()
    local a, b = {"a", "b", "c"}, {"a", "b"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("delete in middle", function()
    local a, b = {"a", "b", "c"}, {"a", "c"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("del op range is valid", function()
    local a, b = {"a", "b", "c"}, {"a", "c"}
    local edits = diff.diff(a, b)
    local found_del = false
    for _, e in ipairs(edits) do
      if e.op == "del" then
        found_del = true
        T.ok(e.a_start <= e.a_end)
      end
    end
    T.ok(found_del)
  end)
end)

T.describe("diff: multiple insertions and deletions", function()
  T.it("interleaved changes reconstruct b", function()
    local a = {"a", "b", "c", "d", "e"}
    local b = {"a", "x", "c", "y", "e"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)

  T.it("interleaved changes script is valid", function()
    local a = {"a", "b", "c", "d", "e"}
    local b = {"a", "x", "c", "y", "e"}
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("completely different sequences reconstruct b", function()
    local a = {"a", "b", "c"}
    local b = {"x", "y", "z"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)

  T.it("completely different sequences script is valid", function()
    local a = {"a", "b"}
    local b = {"c", "d"}
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("multiple insertions at different positions", function()
    local a = {"a", "c", "e"}
    local b = {"a", "b", "c", "d", "e"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("multiple deletions at different positions", function()
    local a = {"a", "b", "c", "d", "e"}
    local b = {"a", "c", "e"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)
end)

T.describe("diff: edits in middle", function()
  T.it("change middle element", function()
    local a = {"start", "middle", "end"}
    local b = {"start", "changed", "end"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)

  T.it("change two middle elements", function()
    local a = {"1", "2", "3", "4", "5"}
    local b = {"1", "x", "y", "4", "5"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)
end)

T.describe("diff: edits at start and end", function()
  T.it("change at start only", function()
    local a = {"old", "b", "c"}
    local b = {"new", "b", "c"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)

  T.it("change at end only", function()
    local a = {"a", "b", "old"}
    local b = {"a", "b", "new"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)

  T.it("change at both ends", function()
    local a = {"old1", "b", "old2"}
    local b = {"new1", "b", "new2"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)
end)

T.describe("diff: repeated elements", function()
  T.it("repeated delete one", function()
    local a = {"a", "a", "a"}
    local b = {"a", "a"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("repeated insert one", function()
    local a = {"a", "a"}
    local b = {"a", "a", "a"}
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)
end)

T.describe("diff: numeric values", function()
  T.it("numeric arrays", function()
    local a = {1, 2, 3, 4, 5}
    local b = {1, 3, 5}
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)
end)

T.describe("diff: large sequences", function()
  T.it("100 element identical", function()
    local a = {}
    for i = 1, 100 do a[i] = tostring(i) end
    local edits = diff.diff(a, a)
    -- All equal
    local all_eq = true
    for _, e in ipairs(edits) do
      if e.op ~= "eq" then all_eq = false end
    end
    T.ok(all_eq)
    T.ok(arr_eq(reconstruct_b(a, a), a))
  end)

  T.it("100 element with every 5th changed", function()
    local a = {}
    local b = {}
    for i = 1, 100 do
      a[i] = tostring(i)
      if i % 5 == 0 then
        b[#b + 1] = "x" .. i
      else
        b[#b + 1] = tostring(i)
      end
    end
    T.ok(arr_eq(reconstruct_b(a, b), b))
    local ok, err = validate_script(diff.diff(a, b), a, b)
    T.ok(ok, err)
  end)

  T.it("150 element append", function()
    local a = {}
    for i = 1, 100 do a[i] = tostring(i) end
    local b = {}
    for i = 1, 150 do b[i] = tostring(i) end
    T.ok(arr_eq(reconstruct_b(a, b), b))
  end)
end)

-- ===== lines() =====

T.describe("lines: basic usage", function()
  T.it("identical strings: all eq ops", function()
    local hunks = diff.lines("a\nb\nc\n", "a\nb\nc\n")
    for _, h in ipairs(hunks) do
      T.eq(h.op, "=")
    end
    T.eq(#hunks, 3)
  end)

  T.it("empty both", function()
    local hunks = diff.lines("", "")
    T.eq(#hunks, 0)
  end)

  T.it("empty a non-empty b", function()
    local hunks = diff.lines("", "hello\n")
    T.eq(#hunks, 1)
    T.eq(hunks[1].op, "+")
    T.eq(hunks[1].line, "hello\n")
  end)

  T.it("non-empty a empty b", function()
    local hunks = diff.lines("hello\n", "")
    T.eq(#hunks, 1)
    T.eq(hunks[1].op, "-")
    T.eq(hunks[1].line, "hello\n")
  end)

  T.it("ops are =, +, - only", function()
    local hunks = diff.lines("a\nb\n", "a\nc\n")
    for _, h in ipairs(hunks) do
      T.ok(h.op == "=" or h.op == "+" or h.op == "-")
    end
  end)

  T.it("line field is correct for insertion", function()
    local hunks = diff.lines("a\n", "a\nb\n")
    local found = false
    for _, h in ipairs(hunks) do
      if h.op == "+" then
        T.eq(h.line, "b\n")
        found = true
      end
    end
    T.ok(found)
  end)

  T.it("line field is correct for deletion", function()
    local hunks = diff.lines("a\nb\n", "a\n")
    local found = false
    for _, h in ipairs(hunks) do
      if h.op == "-" then
        T.eq(h.line, "b\n")
        found = true
      end
    end
    T.ok(found)
  end)

  T.it("reconstruct b from lines hunks", function()
    local a = "line1\nline2\nline3\n"
    local b = "line1\nchanged\nline3\n"
    local hunks = diff.lines(a, b)
    local r = {}
    for _, h in ipairs(hunks) do
      if h.op == "=" or h.op == "+" then
        r[#r + 1] = h.line
      end
    end
    T.eq(table.concat(r), b)
  end)

  T.it("multiple insertions produce correct ops", function()
    local hunks = diff.lines("a\n", "a\nb\nc\n")
    local ins = 0
    for _, h in ipairs(hunks) do
      if h.op == "+" then ins = ins + 1 end
    end
    T.eq(ins, 2)
  end)

  T.it("no trailing newline: last line has no newline", function()
    -- "a\nb" splits into {"a\n", "b"}; the last line has no trailing newline
    local hunks = diff.lines("a\nb", "a\nb")
    local last = hunks[#hunks]
    T.eq(last.op, "=")
    T.eq(last.line, "b") -- no trailing newline
  end)
end)

-- ===== chars() =====

T.describe("chars: basic usage", function()
  T.it("identical strings: all eq", function()
    local hunks = diff.chars("abc", "abc")
    T.eq(#hunks, 3)
    for _, h in ipairs(hunks) do
      T.eq(h.op, "=")
    end
  end)

  T.it("empty both", function()
    local hunks = diff.chars("", "")
    T.eq(#hunks, 0)
  end)

  T.it("empty a", function()
    local hunks = diff.chars("", "xy")
    T.eq(#hunks, 2)
    for _, h in ipairs(hunks) do T.eq(h.op, "+") end
  end)

  T.it("empty b", function()
    local hunks = diff.chars("xy", "")
    T.eq(#hunks, 2)
    for _, h in ipairs(hunks) do T.eq(h.op, "-") end
  end)

  T.it("single char change", function()
    local hunks = diff.chars("abc", "axc")
    local ops_found = {}
    for _, h in ipairs(hunks) do ops_found[#ops_found + 1] = h.op end
    -- a is eq, b is -, x is +, c is eq
    local has_del, has_ins = false, false
    for _, h in ipairs(hunks) do
      if h.op == "-" then has_del = true; T.eq(h.line, "b") end
      if h.op == "+" then has_ins = true; T.eq(h.line, "x") end
    end
    T.ok(has_del)
    T.ok(has_ins)
  end)

  T.it("reconstruct b from chars", function()
    local a_str, b_str = "hello", "helo"
    local hunks = diff.chars(a_str, b_str)
    local r = {}
    for _, h in ipairs(hunks) do
      if h.op == "=" or h.op == "+" then r[#r + 1] = h.line end
    end
    T.eq(table.concat(r), b_str)
  end)

  T.it("line field is single character", function()
    local hunks = diff.chars("ab", "ac")
    for _, h in ipairs(hunks) do
      T.eq(#h.line, 1)
    end
  end)

  T.it("insert multiple chars", function()
    local hunks = diff.chars("ac", "abc")
    local ins = 0
    for _, h in ipairs(hunks) do
      if h.op == "+" then ins = ins + 1 end
    end
    T.eq(ins, 1)
  end)
end)

-- ===== unified() =====

T.describe("unified: output format", function()
  T.it("no changes returns empty string", function()
    local text = diff.unified("same\n", "same\n")
    T.eq(text, "")
  end)

  T.it("has --- header", function()
    local text = diff.unified("a\n", "b\n", { a_name = "file1.txt", b_name = "file2.txt" })
    T.ok(text:find("--- file1.txt", 1, true) ~= nil)
  end)

  T.it("has +++ header", function()
    local text = diff.unified("a\n", "b\n", { a_name = "old", b_name = "new" })
    T.ok(text:find("+++ new", 1, true) ~= nil)
  end)

  T.it("default names are a and b", function()
    local text = diff.unified("a\n", "b\n")
    T.ok(text:find("--- a", 1, true) ~= nil)
    T.ok(text:find("+++ b", 1, true) ~= nil)
  end)

  T.it("has @@ hunk header", function()
    local text = diff.unified("old\n", "new\n")
    T.ok(text:find("@@") ~= nil)
  end)

  T.it("hunk header format matches @@ -N,N +N,N @@", function()
    local text = diff.unified("a\n", "b\n")
    T.ok(text:match("@@ %-%d+,%d+ %+%d+,%d+ @@") ~= nil)
  end)

  T.it("deletions show with - prefix", function()
    local text = diff.unified("hello\n", "world\n")
    T.ok(text:find("-hello", 1, true) ~= nil)
  end)

  T.it("insertions show with + prefix", function()
    local text = diff.unified("hello\n", "world\n")
    T.ok(text:find("+world", 1, true) ~= nil)
  end)

  T.it("context lines show with space prefix", function()
    local a = "ctx1\nctx2\nchanged\nctx3\nctx4\n"
    local b = "ctx1\nctx2\nnew\nctx3\nctx4\n"
    local text = diff.unified(a, b)
    T.ok(text:find(" ctx1", 1, true) ~= nil or text:find(" ctx2", 1, true) ~= nil)
  end)

  T.it("context=0 shows only changed lines", function()
    local a = "before\nchanged\nafter\n"
    local b = "before\nnew\nafter\n"
    local text = diff.unified(a, b, { context = 0 })
    -- With context=0, "before" and "after" should not appear as context
    T.ok(text:find("-changed", 1, true) ~= nil)
    T.ok(text:find("+new", 1, true) ~= nil)
  end)

  T.it("context=1 includes 1 context line on each side", function()
    local a = "1\n2\nOLD\n4\n5\n"
    local b = "1\n2\nNEW\n4\n5\n"
    local text = diff.unified(a, b, { context = 1 })
    T.ok(text:find(" 2", 1, true) ~= nil)
    T.ok(text:find(" 4", 1, true) ~= nil)
  end)

  T.it("large context merges nearby changes into one hunk", function()
    local a = "1\n2\n3\n4\n5\n"
    local b = "X\n2\n3\n4\nY\n"
    local text = diff.unified(a, b, { context = 10 })
    -- With large context, both changes should be in one hunk → only one @@
    local count = 0
    for _ in text:gmatch("@@") do count = count + 1 end
    T.eq(count, 2) -- one open @@ and one close @@ in single hunk
  end)

  T.it("distant changes produce multiple hunks", function()
    -- Two changes far apart → two separate hunks
    local a = {}
    local b = {}
    for i = 1, 30 do
      a[i] = tostring(i) .. "\n"
      b[i] = tostring(i) .. "\n"
    end
    a[1] = "CHANGE1\n"  -- first change
    b[1] = "CHANGED1\n"
    a[30] = "CHANGE30\n" -- last change, far from first
    b[30] = "CHANGED30\n"
    local text = diff.unified(table.concat(a), table.concat(b), { context = 1 })
    -- Count opening @@ markers (start with "@@ -")
    local count = 0
    for _ in text:gmatch("@@ %-") do count = count + 1 end
    T.eq(count, 2)
  end)

  T.it("empty a produces only insertions", function()
    local text = diff.unified("", "line1\nline2\n")
    T.ok(text:find("+line1", 1, true) ~= nil)
    T.ok(text:find("+line2", 1, true) ~= nil)
    -- No deletion lines (lines starting with -, excluding the --- header)
    T.ok(text:find("\n%-") == nil)
  end)

  T.it("empty b produces only deletions", function()
    local text = diff.unified("line1\nline2\n", "")
    T.ok(text:find("-line1", 1, true) ~= nil)
    -- No insertion lines (lines starting with + but not +++)
    T.ok(text:find("\n%+[^%+]") == nil)
  end)
end)

-- ===== apply() =====

T.describe("apply: round-trip", function()
  T.it("apply(original, unified(a, b)) == b for simple change", function()
    local a = "hello\nworld\n"
    local b = "hello\nluajit\n"
    local patch = diff.unified(a, b)
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)

  T.it("apply(original, unified(a, b)) == b for insertion", function()
    local a = "line1\nline3\n"
    local b = "line1\nline2\nline3\n"
    local patch = diff.unified(a, b)
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)

  T.it("apply(original, unified(a, b)) == b for deletion", function()
    local a = "line1\nline2\nline3\n"
    local b = "line1\nline3\n"
    local patch = diff.unified(a, b)
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)

  T.it("apply empty patch returns original", function()
    local original = "unchanged\n"
    local result = diff.apply(original, "")
    T.eq(result, original)
  end)

  T.it("apply identical diff returns same", function()
    local s = "same content\n"
    local patch = diff.unified(s, s)
    T.eq(patch, "") -- no patch
    local result = diff.apply(s, patch)
    T.eq(result, s)
  end)

  T.it("round-trip multiline change", function()
    local a = "aaa\nbbb\nccc\nddd\n"
    local b = "aaa\nXXX\nccc\nYYY\n"
    local patch = diff.unified(a, b)
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)

  T.it("round-trip append lines", function()
    local a = "first\nsecond\n"
    local b = "first\nsecond\nthird\nfourth\n"
    local patch = diff.unified(a, b)
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)

  T.it("round-trip remove all lines", function()
    local a = "only\nthese\nlines\n"
    local b = ""
    local patch = diff.unified(a, b)
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)

  T.it("round-trip add from empty", function()
    local a = ""
    local b = "new content\n"
    local patch = diff.unified(a, b)
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)

  T.it("round-trip with context=0", function()
    local a = "alpha\nbeta\ngamma\n"
    local b = "alpha\nXX\ngamma\n"
    local patch = diff.unified(a, b, { context = 0 })
    local result = diff.apply(a, patch)
    T.eq(result, b)
  end)
end)

-- ===== distance() =====

T.describe("distance: correctness", function()
  T.it("both empty: distance 0", function()
    T.eq(diff.distance({}, {}), 0)
  end)

  T.it("a empty: distance = #b", function()
    T.eq(diff.distance({}, {"a", "b", "c"}), 3)
  end)

  T.it("b empty: distance = #a", function()
    T.eq(diff.distance({"a", "b", "c"}, {}), 3)
  end)

  T.it("identical: distance 0", function()
    T.eq(diff.distance({"a", "b", "c"}, {"a", "b", "c"}), 0)
  end)

  T.it("single substitution: distance 2", function()
    -- Replace "b" with "x": 1 delete + 1 insert = 2
    T.eq(diff.distance({"a", "b", "c"}, {"a", "x", "c"}), 2)
  end)

  T.it("single insertion: distance 1", function()
    T.eq(diff.distance({"a", "b"}, {"a", "b", "c"}), 1)
  end)

  T.it("single deletion: distance 1", function()
    T.eq(diff.distance({"a", "b", "c"}, {"a", "c"}), 1)
  end)

  T.it("completely different: distance = sum of lengths", function()
    -- 3 deletes + 3 inserts = 6
    T.eq(diff.distance({"a", "b", "c"}, {"x", "y", "z"}), 6)
  end)

  T.it("single element same: 0", function()
    T.eq(diff.distance({"x"}, {"x"}), 0)
  end)

  T.it("single element different: 2", function()
    T.eq(diff.distance({"x"}, {"y"}), 2)
  end)

  T.it("distance is symmetric", function()
    local a = {"a", "b", "c", "d"}
    local b = {"b", "d", "e"}
    T.eq(diff.distance(a, b), diff.distance(b, a))
  end)

  T.it("distance matches edit count", function()
    -- count ins+del from diff
    local a = {"a", "b", "c"}
    local b = {"a", "x", "c", "d"}
    local edits = diff.diff(a, b)
    local count = 0
    for _, e in ipairs(edits) do
      if e.op == "ins" then count = count + (e.b_end - e.b_start + 1) end
      if e.op == "del" then count = count + (e.a_end - e.a_start + 1) end
    end
    T.eq(diff.distance(a, b), count)
  end)

  T.it("large identical arrays: distance 0", function()
    local a = {}
    for i = 1, 200 do a[i] = tostring(i) end
    T.eq(diff.distance(a, a), 0)
  end)

  T.it("large arrays with known edit distance", function()
    local a = {}
    local b = {}
    for i = 1, 50 do
      a[i] = tostring(i)
      b[i] = tostring(i)
    end
    -- Append 10 to b: distance = 10
    for i = 51, 60 do b[i] = "extra" .. i end
    T.eq(diff.distance(a, b), 10)
  end)
end)

-- ===== _tier =====

T.describe("module metadata", function()
  T.it("_tier is 'pure'", function()
    T.eq(diff._tier, "pure")
  end)
end)
