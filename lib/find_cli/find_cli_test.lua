-- lib/find_cli/find_cli_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local F = require("lib.find_cli")

-- ---------------------------------------------------------------------------
-- Unit helpers
-- ---------------------------------------------------------------------------

T.describe("unit helpers", function()
  T.it("kib returns 1024 bytes for 1", function()
    T.eq(F.kib(1), 1024)
  end)
  T.it("mib returns 1048576 bytes for 1", function()
    T.eq(F.mib(1), 1024 * 1024)
  end)
  T.it("sec returns n unchanged", function()
    T.eq(F.sec(5), 5)
  end)
  T.it("min returns 60 * n", function()
    T.eq(F.min(2), 120)
  end)
  T.it("hr returns 3600 * n", function()
    T.eq(F.hr(1), 3600)
  end)
  T.it("day returns 86400 * n", function()
    T.eq(F.day(1), 86400)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.find (runtime tests — predicate logic tested via predicate constructors)
-- ---------------------------------------------------------------------------

-- Build a mock walk_fn and invoke F.find; return results as unknown for
-- downstream narrowing via explicit cast at each use site.
--
-- We use unknown-typed wrappers because the find_file_info / find_predicate
-- aliases are local to lib.find_cli and not exported to this test file's
-- type scope.  The runtime tests still exercise the full code path.

-- Build a walk_fn for a flat directory listing (no recursion in the mock).
-- flat_walk: only serves entries for the root path; subdirs yield nothing.
--: (any, any) -> (string) -> (((unknown) -> unknown), unknown)
local function flat_walk_for(root_path, entries)
  return function(path)
    if path ~= root_path then
      -- empty subtree
      return function(_) return nil end, nil
    end
    local idx = 0
    return function(_2)
      idx = idx + 1
      return entries[idx]
    end, nil
  end
end

local time_fn = function() return 1000 end

T.describe("M.find", function()
  T.it("finds files matching a name predicate", function()
    local entries = {
      { name = "foo.lua", path = "/root/foo.lua", is_dir = false, size = 100, created = nil },
      { name = "bar.txt", path = "/root/bar.txt", is_dir = false, size = 50,  created = nil },
      { name = "baz.lua", path = "/root/baz.lua", is_dir = false, size = 200, created = nil },
    }
    local raw = F.find("/root", F.name("%.lua$"), flat_walk_for("/root", entries), time_fn) --[[: any]]
    local results = raw --[[: any]]
    table.sort(results)
    T.eq(#results, 2)
    T.eq(results[1], "/root/baz.lua")
    T.eq(results[2], "/root/foo.lua")
  end)

  T.it("files_only excludes directories", function()
    local entries = {
      { name = "dir",      path = "/root/dir",      is_dir = true,  size = nil, created = nil },
      { name = "file.txt", path = "/root/file.txt", is_dir = false, size = 100, created = nil },
    }
    local results = F.find("/root", F.files_only(), flat_walk_for("/root", entries), time_fn) --[[: any]]
    T.eq(#results, 1)
    T.eq(results[1], "/root/file.txt")
  end)

  T.it("larger_than filters by size", function()
    local entries = {
      { name = "small.txt", path = "/root/small.txt", is_dir = false, size = 10,   created = nil },
      { name = "large.bin", path = "/root/large.bin", is_dir = false, size = 5000, created = nil },
    }
    local results = F.find("/root", F.larger_than(1000), flat_walk_for("/root", entries), time_fn) --[[: any]]
    T.eq(#results, 1)
    T.eq(results[1], "/root/large.bin")
  end)

  T.it("smaller_than filters by size", function()
    local entries = {
      { name = "small.txt", path = "/root/small.txt", is_dir = false, size = 10,   created = nil },
      { name = "large.bin", path = "/root/large.bin", is_dir = false, size = 5000, created = nil },
    }
    local results = F.find("/root", F.smaller_than(100), flat_walk_for("/root", entries), time_fn) --[[: any]]
    T.eq(#results, 1)
    T.eq(results[1], "/root/small.txt")
  end)

  T.it("newer_than uses created time for age", function()
    -- time_fn returns 1000; created=950 → age=50 < 200 → matches newer_than(200)
    -- created=500 → age=500 > 200 → does not match
    local entries = {
      { name = "old.txt",   path = "/root/old.txt",   is_dir = false, size = 10, created = 500 },
      { name = "fresh.txt", path = "/root/fresh.txt", is_dir = false, size = 10, created = 950 },
    }
    local results = F.find("/root", F.newer_than(200), flat_walk_for("/root", entries), time_fn) --[[: any]]
    T.eq(#results, 1)
    T.eq(results[1], "/root/fresh.txt")
  end)

  T.it("both combines predicates with AND", function()
    local entries = {
      { name = "a.lua", path = "/root/a.lua", is_dir = false, size = 5000, created = nil },
      { name = "b.lua", path = "/root/b.lua", is_dir = false, size = 10,   created = nil },
      { name = "c.txt", path = "/root/c.txt", is_dir = false, size = 5000, created = nil },
    }
    local pred = F.both(F.name("%.lua$"), F.larger_than(100))
    local results = F.find("/root", pred, flat_walk_for("/root", entries), time_fn) --[[: any]]
    T.eq(#results, 1)
    T.eq(results[1], "/root/a.lua")
  end)

  T.it("negate inverts the predicate", function()
    local entries = {
      { name = "a.lua", path = "/root/a.lua", is_dir = false, size = 10, created = nil },
      { name = "b.txt", path = "/root/b.txt", is_dir = false, size = 10, created = nil },
    }
    local results = F.find("/root", F.negate(F.name("%.lua$")), flat_walk_for("/root", entries), time_fn) --[[: any]]
    T.eq(#results, 1)
    T.eq(results[1], "/root/b.txt")
  end)

  T.it("returns empty list when nothing matches", function()
    local entries = {
      { name = "a.txt", path = "/root/a.txt", is_dir = false, size = 10, created = nil },
    }
    local results = F.find("/root", F.name("%.lua$"), flat_walk_for("/root", entries), time_fn) --[[: any]]
    T.eq(#results, 0)
  end)
end)
