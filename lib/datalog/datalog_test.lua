if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local datalog = require("lib.datalog")

--- Helper: sort results for deterministic comparison.
local function sort_results(results)
  table.sort(results, function(a, b)
    for i = 1, math.max(#a, #b) do
      if (a[i] or "") ~= (b[i] or "") then
        return (a[i] or "") < (b[i] or "")
      end
    end
    return false
  end)
  return results
end

--- Helper: sort binding results by a specific key order.
local function sort_bindings(results, keys)
  table.sort(results, function(a, b)
    for _, k in ipairs(keys) do
      if a[k] ~= b[k] then return (a[k] or "") < (b[k] or "") end
    end
    return false
  end)
  return results
end

--- Helper: check that sorted results match expected.
local function check_results(actual, expected, msg)
  sort_results(actual)
  sort_results(expected)
  T.eq(#actual, #expected, msg .. " (count)")
  for i = 1, #expected do
    for j = 1, #expected[i] do
      T.eq(actual[i][j], expected[i][j], msg .. " [" .. i .. "][" .. j .. "]")
    end
  end
end

T.describe("datalog", function()

  T.describe("facts", function()
    T.it("asserts and queries facts", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      local r = db:query("parent", "tom", "?")
      check_results(r, {{"tom", "bob"}, {"tom", "liz"}}, "parent tom ?")
    end)

    T.it("returns empty for no matching facts", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      local r = db:query("parent", "alice", "?")
      T.eq(#r, 0, "no match")
    end)

    T.it("returns empty on empty database", function()
      local db = datalog.new()
      local r = db:query("parent", "?", "?")
      T.eq(#r, 0, "empty db")
    end)

    T.it("deduplicates identical facts", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "bob")
      local r = db:query("parent", "?", "?")
      T.eq(#r, 1, "dedup")
    end)

    T.it("queries with all constants", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      local r = db:query("parent", "tom", "bob")
      T.eq(#r, 1, "exact match found")
      local r2 = db:query("parent", "tom", "alice")
      T.eq(#r2, 0, "exact match not found")
    end)
  end)

  T.describe("rules", function()
    T.it("derives simple rule (single level ancestor)", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      db:rule("ancestor", {"X", "Y"}, {
        {"parent", "X", "Y"},
      })
      local r = db:query("ancestor", "tom", "?")
      check_results(r, {{"tom", "bob"}, {"tom", "liz"}}, "ancestor single level")
    end)

    T.it("derives recursive rule (transitive ancestor)", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "bob", "ann")
      db:assert("parent", "bob", "pat")
      db:rule("ancestor", {"X", "Y"}, {
        {"parent", "X", "Y"},
      })
      db:rule("ancestor", {"X", "Y"}, {
        {"parent", "X", "Z"},
        {"ancestor", "Z", "Y"},
      })
      local r = db:query("ancestor", "tom", "?")
      check_results(r, {
        {"tom", "bob"},
        {"tom", "ann"},
        {"tom", "pat"},
      }, "ancestor transitive")
    end)

    T.it("queries wildcard in first position", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      db:assert("parent", "bob", "ann")
      db:rule("ancestor", {"X", "Y"}, {
        {"parent", "X", "Y"},
      })
      db:rule("ancestor", {"X", "Y"}, {
        {"parent", "X", "Z"},
        {"ancestor", "Z", "Y"},
      })
      local r = db:query("ancestor", "?", "ann")
      check_results(r, {{"bob", "ann"}, {"tom", "ann"}}, "ancestor ? ann")
    end)

    T.it("queries wildcard in second position", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      local r = db:query("parent", "tom", "?")
      check_results(r, {{"tom", "bob"}, {"tom", "liz"}}, "parent tom ?")
    end)

    T.it("supports guard function (sibling)", function()
      local db = datalog.new()
      db:assert("parent", "bob", "ann")
      db:assert("parent", "bob", "pat")
      db:rule("sibling", {"X", "Y"}, {
        {"parent", "Z", "X"},
        {"parent", "Z", "Y"},
      }, function(b) return b.X ~= b.Y end)
      local r = db:query("sibling", "ann", "?")
      check_results(r, {{"ann", "pat"}}, "sibling ann ?")
    end)

    T.it("handles graph reachability (transitive closure)", function()
      local db = datalog.new()
      db:assert("edge", "a", "b")
      db:assert("edge", "b", "c")
      db:assert("edge", "c", "d")
      db:rule("reachable", {"X", "Y"}, {
        {"edge", "X", "Y"},
      })
      db:rule("reachable", {"X", "Y"}, {
        {"edge", "X", "Z"},
        {"reachable", "Z", "Y"},
      })
      local r = db:query("reachable", "a", "?")
      check_results(r, {
        {"a", "b"}, {"a", "c"}, {"a", "d"},
      }, "reachable from a")
    end)

    T.it("handles multiple rules for same predicate (union)", function()
      local db = datalog.new()
      db:assert("mother", "mary", "bob")
      db:assert("father", "tom", "bob")
      db:rule("parent_of", {"X", "Y"}, {
        {"mother", "X", "Y"},
      })
      db:rule("parent_of", {"X", "Y"}, {
        {"father", "X", "Y"},
      })
      local r = db:query("parent_of", "?", "bob")
      check_results(r, {{"mary", "bob"}, {"tom", "bob"}}, "union rules")
    end)

    T.it("terminates on cyclic rules", function()
      local db = datalog.new()
      db:assert("edge", "a", "b")
      db:assert("edge", "b", "c")
      db:assert("edge", "c", "a")
      db:rule("reachable", {"X", "Y"}, {
        {"edge", "X", "Y"},
      })
      db:rule("reachable", {"X", "Y"}, {
        {"edge", "X", "Z"},
        {"reachable", "Z", "Y"},
      })
      local r = db:query("reachable", "a", "?")
      check_results(r, {
        {"a", "a"}, {"a", "b"}, {"a", "c"},
      }, "cyclic reachable")
    end)

    T.it("supports 3-way join in body", function()
      local db = datalog.new()
      db:assert("enrolled", "alice", "cs101")
      db:assert("enrolled", "bob", "cs101")
      db:assert("enrolled", "alice", "math201")
      db:assert("enrolled", "carol", "math201")
      db:assert("teaches", "prof_x", "cs101")
      db:assert("teaches", "prof_y", "math201")
      -- classmates who share a teacher: student X and Y enrolled in same course taught by T
      db:rule("shares_teacher", {"X", "Y"}, {
        {"enrolled", "X", "C"},
        {"enrolled", "Y", "C"},
        {"teaches", "T", "C"},
      }, function(b) return b.X ~= b.Y end)
      local r = db:query("shares_teacher", "alice", "?")
      check_results(r, {
        {"alice", "bob"},
        {"alice", "carol"},
      }, "3-way join")
    end)

    T.it("supports constants in rule body with wildcard", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      db:assert("parent", "bob", "ann")
      -- Anyone who is a parent is human
      db:rule("human", {"X"}, {
        {"parent", "X", "?"},
      })
      local r = db:query("human", "?")
      -- tom and bob are parents
      check_results(r, {{"tom"}, {"bob"}}, "constants in rules")
    end)
  end)

  T.describe("query_bindings", function()
    T.it("returns binding maps", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      db:assert("parent", "bob", "ann")
      db:assert("parent", "bob", "pat")
      db:rule("ancestor", {"X", "Y"}, {
        {"parent", "X", "Y"},
      })
      db:rule("ancestor", {"X", "Y"}, {
        {"parent", "X", "Z"},
        {"ancestor", "Z", "Y"},
      })
      local r = db:query_bindings("ancestor", {"X", "Y"}, { X = "tom" })
      sort_bindings(r, {"X", "Y"})
      T.eq(#r, 4, "binding count")
      T.eq(r[1].X, "tom") T.eq(r[1].Y, "ann")
      T.eq(r[2].X, "tom") T.eq(r[2].Y, "bob")
      T.eq(r[3].X, "tom") T.eq(r[3].Y, "liz")
      T.eq(r[4].X, "tom") T.eq(r[4].Y, "pat")
    end)
  end)

  T.describe("retract", function()
    T.it("removes a fact and reflects in query", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      T.eq(#db:query("parent", "tom", "?"), 2, "before retract")
      db:retract("parent", "tom", "liz")
      local r = db:query("parent", "tom", "?")
      T.eq(#r, 1, "after retract")
      T.eq(r[1][1], "tom")
      T.eq(r[1][2], "bob")
    end)
  end)

  T.describe("assert_all", function()
    T.it("bulk inserts facts", function()
      local db = datalog.new()
      db:assert_all({
        {"edge", "a", "b"},
        {"edge", "b", "c"},
        {"edge", "c", "d"},
      })
      local r = db:query("edge", "?", "?")
      T.eq(#r, 3, "bulk insert count")
    end)
  end)

  T.describe("inspection", function()
    T.it("lists facts for a predicate", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      local r = db:facts("parent")
      sort_results(r)
      T.eq(#r, 2, "facts count")
      T.eq(r[1][1], "tom") T.eq(r[1][2], "bob")
      T.eq(r[2][1], "tom") T.eq(r[2][2], "liz")
    end)

    T.it("lists all predicates", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("edge", "a", "b")
      db:rule("ancestor", {"X", "Y"}, {{"parent", "X", "Y"}})
      local preds = db:predicates()
      table.sort(preds)
      T.eq(#preds, 3, "predicate count")
      T.eq(preds[1], "ancestor")
      T.eq(preds[2], "edge")
      T.eq(preds[3], "parent")
    end)

    T.it("counts facts for a predicate", function()
      local db = datalog.new()
      db:assert("parent", "tom", "bob")
      db:assert("parent", "tom", "liz")
      db:assert("parent", "bob", "ann")
      T.eq(db:count("parent"), 3, "count")
      T.eq(db:count("nonexistent"), 0, "count nonexistent")
    end)
  end)
end)
