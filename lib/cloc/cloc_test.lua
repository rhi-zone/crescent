-- lib/cloc/cloc_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local cloc = require("lib.cloc")

T.describe("cloc.count_string", function()
  T.it("counts lua code, comments, and blank lines", function()
    local src = table.concat({
      "-- a comment",
      "local x = 1",
      "",
      "-- another comment",
      "return x",
    }, "\n")
    local counts = cloc.count_string(src, "lua")
    T.ok(counts ~= nil, "counts not nil")
    T.eq(counts.comment, 2)
    T.eq(counts.blank, 1)
    T.eq(counts.code, 2)
  end)

  T.it("handles block comments in lua", function()
    local src = table.concat({
      "local x = 1",
      "--[[",
      "  block comment",
      "]]",
      "return x",
    }, "\n")
    local counts = cloc.count_string(src, "lua")
    T.ok(counts ~= nil, "counts not nil")
    -- line with --[[ is a comment, middle line is a comment, ]] line is a comment
    T.eq(counts.comment, 3)
    T.eq(counts.code, 2)
  end)

  T.it("counts python lines", function()
    local src = table.concat({
      "# comment",
      "x = 1",
      "  ",
      "y = 2",
    }, "\n")
    local counts = cloc.count_string(src, "py")
    T.ok(counts ~= nil, "counts not nil")
    T.eq(counts.comment, 1)
    T.eq(counts.blank, 1)
    T.eq(counts.code, 2)
  end)

  T.it("returns nil for unknown extension", function()
    local counts = cloc.count_string("hello", "xyz_unknown_ext")
    T.eq(counts, nil)
  end)

  T.it("handles empty string", function()
    local counts = cloc.count_string("", "lua")
    T.ok(counts ~= nil, "counts not nil for empty")
    T.eq(counts.code, 0)
    T.eq(counts.comment, 0)
    T.eq(counts.blank, 0)
  end)
end)

T.describe("cloc.count_file", function()
  T.it("reads and counts a known string", function()
    local fake_fs = {
      ["/fake/hello.lua"] = "local x = 1\n-- comment\n",
    }
    local read_fn = function(path) return fake_fs[path] end
    local counts = cloc.count_file("/fake/hello.lua", read_fn)
    T.ok(counts ~= nil, "counts not nil")
    T.eq(counts.code, 1)
    T.eq(counts.comment, 1)
    T.eq(counts.blank, 0)
  end)

  T.it("returns nil when read_fn returns nil", function()
    local counts = cloc.count_file("/nonexistent.lua", function(_) return nil end)
    T.eq(counts, nil)
  end)

  T.it("returns nil for unrecognised extension", function()
    local counts = cloc.count_file("/foo.xyz_unknown", function(_) return "x=1" end)
    T.eq(counts, nil)
  end)
end)

T.describe("cloc.count_dir", function()
  T.it("aggregates counts across multiple files", function()
    local fake_fs = {
      ["/proj/a.lua"] = "local x = 1\n-- comment\n",
      ["/proj/b.lua"] = "return 2\n",
      ["/proj/c.py"]  = "# py comment\nx = 1\n",
    }
    local read_fn = function(path) return fake_fs[path] end

    -- Build a fake walk_fn that iterates a flat list
    local tree = {
      { name = "a.lua", path = "/proj/a.lua", is_dir = false },
      { name = "b.lua", path = "/proj/b.lua", is_dir = false },
      { name = "c.py",  path = "/proj/c.py",  is_dir = false },
    }
    local walk_fn = function(_)
      local idx = 0
      return function()
        idx = idx + 1
        return tree[idx]
      end, nil
    end

    local result = cloc.count_dir("/proj", read_fn, walk_fn)
    T.ok(result["lua"] ~= nil, "lua extension present")
    T.ok(result["py"]  ~= nil, "py extension present")
    -- a.lua: code=1 comment=1; b.lua: code=1 → lua total code=2
    T.eq(result["lua"].code, 2)
    T.eq(result["lua"].comment, 1)
    T.eq(result["py"].code, 1)
    T.eq(result["py"].comment, 1)
  end)

  T.it("ignores .git directories", function()
    local visited = {}
    local fake_fs = { ["/r/x.lua"] = "local x=1\n" }
    local tree_root = {
      { name = ".git", path = "/r/.git", is_dir = true },
      { name = "x.lua", path = "/r/x.lua", is_dir = false },
    }
    local walk_fn = function(path)
      visited[path] = true
      local items = path == "/r" and tree_root or {}
      local idx = 0
      return function()
        idx = idx + 1
        return items[idx]
      end, nil
    end
    cloc.count_dir("/r", function(p) return fake_fs[p] end, walk_fn)
    T.eq(visited["/r/.git"], nil, ".git should not be walked")
  end)
end)
