-- lib/table_ext/table_ext_test.lua
-- Tests for lib/table_ext

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local E = require("lib.table_ext")

-- ---------------------------------------------------------------------------
-- map
-- ---------------------------------------------------------------------------
T.describe("map", function()
	T.it("doubles each element", function()
		local r = E.map({1, 2, 3}, function(v) return v * 2 end)
		T.eq(r[1], 2) T.eq(r[2], 4) T.eq(r[3], 6)
	end)
	T.it("provides index", function()
		local r = E.map({"a", "b"}, function(v, i) return i end)
		T.eq(r[1], 1) T.eq(r[2], 2)
	end)
	T.it("empty array", function()
		T.eq(#E.map({}, function(v) return v end), 0)
	end)
end)

-- ---------------------------------------------------------------------------
-- filter
-- ---------------------------------------------------------------------------
T.describe("filter", function()
	T.it("keeps evens", function()
		local r = E.filter({1, 2, 3, 4}, function(v) return v % 2 == 0 end)
		T.eq(#r, 2) T.eq(r[1], 2) T.eq(r[2], 4)
	end)
	T.it("empty result", function()
		T.eq(#E.filter({1, 3, 5}, function(v) return v % 2 == 0 end), 0)
	end)
	T.it("all pass", function()
		local r = E.filter({1, 2}, function() return true end)
		T.eq(#r, 2)
	end)
end)

-- ---------------------------------------------------------------------------
-- reduce
-- ---------------------------------------------------------------------------
T.describe("reduce", function()
	T.it("sums with init 0", function()
		T.eq(E.reduce({1, 2, 3, 4}, function(a, v) return a + v end, 0), 10)
	end)
	T.it("builds string", function()
		local r = E.reduce({"a", "b", "c"}, function(a, v) return a .. v end, "")
		T.eq(r, "abc")
	end)
	T.it("empty array returns init", function()
		T.eq(E.reduce({}, function(a, v) return a + v end, 42), 42)
	end)
end)

-- ---------------------------------------------------------------------------
-- each
-- ---------------------------------------------------------------------------
T.describe("each", function()
	T.it("visits all elements", function()
		local sum = 0
		E.each({1, 2, 3}, function(v) sum = sum + v end)
		T.eq(sum, 6)
	end)
end)

-- ---------------------------------------------------------------------------
-- flat_map
-- ---------------------------------------------------------------------------
T.describe("flat_map", function()
	T.it("maps and flattens one level", function()
		local r = E.flat_map({1, 2, 3}, function(v) return {v, v * 10} end)
		T.eq(#r, 6)
		T.eq(r[1], 1) T.eq(r[2], 10) T.eq(r[3], 2) T.eq(r[4], 20)
	end)
	T.it("empty inner arrays", function()
		local r = E.flat_map({1, 2}, function() return {} end)
		T.eq(#r, 0)
	end)
end)

-- ---------------------------------------------------------------------------
-- flatten
-- ---------------------------------------------------------------------------
T.describe("flatten", function()
	T.it("default depth 1", function()
		local r = E.flatten({{1, 2}, {3, 4}})
		T.eq(#r, 4) T.eq(r[1], 1) T.eq(r[4], 4)
	end)
	T.it("depth 2", function()
		local r = E.flatten({{{1}}, {{2}}}, 2)
		T.eq(#r, 2) T.eq(r[1], 1) T.eq(r[2], 2)
	end)
	T.it("infinite depth", function()
		local r = E.flatten({1, {2, {3, {4}}}}, nil)
		T.eq(#r, 4) T.eq(r[4], 4)
	end)
	T.it("depth 0 leaves structure intact", function()
		local r = E.flatten({{1, 2}, {3}}, 0)
		-- items are still sub-tables
		T.ok(type(r[1]) == "table")
	end)
end)

-- ---------------------------------------------------------------------------
-- find / find_index / index_of / contains
-- ---------------------------------------------------------------------------
T.describe("find", function()
	T.it("finds first even", function()
		local v, i = E.find({1, 3, 4, 6}, function(x) return x % 2 == 0 end)
		T.eq(v, 4) T.eq(i, 3)
	end)
	T.it("returns nil when not found", function()
		T.eq(E.find({1, 3, 5}, function(x) return x % 2 == 0 end), nil)
	end)
end)

T.describe("find_index", function()
	T.it("returns index of first match", function()
		T.eq(E.find_index({10, 20, 30}, function(v) return v > 15 end), 2)
	end)
	T.it("nil when not found", function()
		T.eq(E.find_index({1, 2}, function(v) return v > 100 end), nil)
	end)
end)

T.describe("index_of", function()
	T.it("finds value", function()
		T.eq(E.index_of({"a", "b", "c"}, "b"), 2)
	end)
	T.it("nil when absent", function()
		T.eq(E.index_of({"a", "b"}, "z"), nil)
	end)
end)

T.describe("contains", function()
	T.it("true when present", function()
		T.ok(E.contains({1, 2, 3}, 2))
	end)
	T.it("false when absent", function()
		T.ok(not E.contains({1, 2, 3}, 9))
	end)
end)

-- ---------------------------------------------------------------------------
-- any / all / none
-- ---------------------------------------------------------------------------
T.describe("any", function()
	T.it("true if one matches", function()
		T.ok(E.any({1, 2, 3}, function(v) return v == 2 end))
	end)
	T.it("false if none match", function()
		T.ok(not E.any({1, 3}, function(v) return v == 2 end))
	end)
	T.it("false on empty", function()
		T.ok(not E.any({}, function() return true end))
	end)
end)

T.describe("all", function()
	T.it("true if all match", function()
		T.ok(E.all({2, 4, 6}, function(v) return v % 2 == 0 end))
	end)
	T.it("false if one fails", function()
		T.ok(not E.all({2, 3, 6}, function(v) return v % 2 == 0 end))
	end)
	T.it("true on empty", function()
		T.ok(E.all({}, function() return false end))
	end)
end)

T.describe("none", function()
	T.it("true if none match", function()
		T.ok(E.none({1, 3, 5}, function(v) return v % 2 == 0 end))
	end)
	T.it("false if one matches", function()
		T.ok(not E.none({1, 2, 3}, function(v) return v == 2 end))
	end)
end)

-- ---------------------------------------------------------------------------
-- count / sum / min / max
-- ---------------------------------------------------------------------------
T.describe("count", function()
	T.it("counts with predicate", function()
		T.eq(E.count({1, 2, 3, 4}, function(v) return v % 2 == 0 end), 2)
	end)
	T.it("counts all when no fn", function()
		T.eq(E.count({1, 2, 3}), 3)
	end)
end)

T.describe("sum", function()
	T.it("sums numbers", function() T.eq(E.sum({1, 2, 3, 4}), 10) end)
	T.it("empty returns 0", function() T.eq(E.sum({}), 0) end)
end)

T.describe("min/max", function()
	T.it("min", function() T.eq(E.min({3, 1, 4, 1, 5}), 1) end)
	T.it("max", function() T.eq(E.max({3, 1, 4, 1, 5}), 5) end)
	T.it("min_by", function()
		local r = E.min_by({"banana", "fig", "apple"}, function(s) return #s end)
		T.eq(r, "fig")
	end)
	T.it("max_by", function()
		local r = E.max_by({"banana", "fig", "apple"}, function(s) return #s end)
		T.eq(r, "banana")
	end)
end)

-- ---------------------------------------------------------------------------
-- sort_by
-- ---------------------------------------------------------------------------
T.describe("sort_by", function()
	T.it("sorts by length", function()
		local r = E.sort_by({"banana", "fig", "apple"}, function(s) return #s end)
		T.eq(r[1], "fig") T.eq(r[3], "banana")
	end)
	T.it("does not mutate original", function()
		local orig = {3, 1, 2}
		E.sort_by(orig, function(v) return v end)
		T.eq(orig[1], 3)
	end)
end)

-- ---------------------------------------------------------------------------
-- group_by
-- ---------------------------------------------------------------------------
T.describe("group_by", function()
	T.it("groups by modulo", function()
		local r = E.group_by({1, 2, 3, 4, 5, 6}, function(v) return v % 3 end)
		T.eq(#r[0], 2)  -- 3, 6
		T.eq(#r[1], 2)  -- 1, 4
		T.eq(#r[2], 2)  -- 2, 5
	end)
	T.it("groups strings by length", function()
		local r = E.group_by({"a", "bb", "cc", "ddd"}, function(s) return #s end)
		T.eq(#r[1], 1) T.eq(#r[2], 2) T.eq(#r[3], 1)
	end)
end)

-- ---------------------------------------------------------------------------
-- unique / unique_by
-- ---------------------------------------------------------------------------
T.describe("unique", function()
	T.it("removes duplicates preserving order", function()
		local r = E.unique({1, 2, 1, 3, 2})
		T.eq(#r, 3) T.eq(r[1], 1) T.eq(r[2], 2) T.eq(r[3], 3)
	end)
	T.it("no-op on already unique", function()
		T.eq(#E.unique({1, 2, 3}), 3)
	end)
end)

T.describe("unique_by", function()
	T.it("deduplicates by key", function()
		local r = E.unique_by({"apple", "ant", "banana"}, function(s) return s:sub(1, 1) end)
		T.eq(#r, 2)
		T.eq(r[1], "apple")
		T.eq(r[2], "banana")
	end)
end)

-- ---------------------------------------------------------------------------
-- zip / unzip
-- ---------------------------------------------------------------------------
T.describe("zip", function()
	T.it("zips two arrays", function()
		local r = E.zip({1, 2, 3}, {"a", "b", "c"})
		T.eq(#r, 3)
		T.eq(r[1][1], 1) T.eq(r[1][2], "a")
		T.eq(r[3][1], 3) T.eq(r[3][2], "c")
	end)
	T.it("stops at shortest", function()
		local r = E.zip({1, 2, 3}, {"a", "b"})
		T.eq(#r, 2)
	end)
	T.it("three arrays", function()
		local r = E.zip({1}, {2}, {3})
		T.eq(#r[1], 3) T.eq(r[1][3], 3)
	end)
end)

T.describe("unzip", function()
	T.it("unzips pairs", function()
		local a, b = E.unzip({{1, "a"}, {2, "b"}, {3, "c"}})
		T.eq(#a, 3) T.eq(a[2], 2)
		T.eq(#b, 3) T.eq(b[1], "a")
	end)
end)

-- ---------------------------------------------------------------------------
-- chunk
-- ---------------------------------------------------------------------------
T.describe("chunk", function()
	T.it("even split", function()
		local r = E.chunk({1, 2, 3, 4}, 2)
		T.eq(#r, 2)
		T.eq(r[1][1], 1) T.eq(r[1][2], 2)
		T.eq(r[2][1], 3) T.eq(r[2][2], 4)
	end)
	T.it("last chunk smaller", function()
		local r = E.chunk({1, 2, 3, 4, 5}, 2)
		T.eq(#r, 3) T.eq(#r[3], 1) T.eq(r[3][1], 5)
	end)
	T.it("chunk size >= length", function()
		local r = E.chunk({1, 2}, 10)
		T.eq(#r, 1) T.eq(#r[1], 2)
	end)
end)

-- ---------------------------------------------------------------------------
-- take / drop / reverse / compact / concat
-- ---------------------------------------------------------------------------
T.describe("take", function()
	T.it("takes first n", function()
		local r = E.take({1, 2, 3, 4, 5}, 3)
		T.eq(#r, 3) T.eq(r[3], 3)
	end)
	T.it("n > length returns all", function()
		T.eq(#E.take({1, 2}, 10), 2)
	end)
end)

T.describe("drop", function()
	T.it("drops first n", function()
		local r = E.drop({1, 2, 3, 4}, 2)
		T.eq(#r, 2) T.eq(r[1], 3)
	end)
	T.it("drop 0 returns copy", function()
		T.eq(#E.drop({1, 2, 3}, 0), 3)
	end)
end)

T.describe("reverse", function()
	T.it("reverses", function()
		local r = E.reverse({1, 2, 3})
		T.eq(r[1], 3) T.eq(r[3], 1)
	end)
end)

T.describe("compact", function()
	T.it("removes nil and false", function()
		-- nil in constructor truncates sequence; use explicit false values only
		local t = {1, false, 2, false, 3}
		local r = E.compact(t)
		T.eq(#r, 3) T.eq(r[1], 1) T.eq(r[2], 2) T.eq(r[3], 3)
	end)
end)

T.describe("concat arrays", function()
	T.it("concatenates", function()
		local r = E.concat({1, 2}, {3, 4}, {5})
		T.eq(#r, 5) T.eq(r[5], 5)
	end)
end)

-- ---------------------------------------------------------------------------
-- range / repeat_val
-- ---------------------------------------------------------------------------
T.describe("range", function()
	T.it("basic range", function()
		local r = E.range(1, 5)
		T.eq(#r, 5) T.eq(r[1], 1) T.eq(r[5], 5)
	end)
	T.it("step 2", function()
		local r = E.range(0, 10, 2)
		T.eq(#r, 6) T.eq(r[1], 0) T.eq(r[6], 10)
	end)
	T.it("descending", function()
		local r = E.range(5, 1, -1)
		T.eq(#r, 5) T.eq(r[1], 5) T.eq(r[5], 1)
	end)
	T.it("single element", function()
		local r = E.range(3, 3)
		T.eq(#r, 1) T.eq(r[1], 3)
	end)
end)

T.describe("repeat_val", function()
	T.it("repeats value", function()
		local r = E.repeat_val("x", 4)
		T.eq(#r, 4) T.eq(r[1], "x") T.eq(r[4], "x")
	end)
	T.it("n=0 returns empty", function()
		T.eq(#E.repeat_val(1, 0), 0)
	end)
end)

-- ---------------------------------------------------------------------------
-- keys / values / entries / from_entries
-- ---------------------------------------------------------------------------
T.describe("keys", function()
	T.it("sorted string keys", function()
		local r = E.keys({b = 2, a = 1, c = 3})
		T.eq(r[1], "a") T.eq(r[2], "b") T.eq(r[3], "c")
	end)
end)

T.describe("values", function()
	T.it("matches key order", function()
		local r = E.values({b = 2, a = 1, c = 3})
		-- keys sorted: a, b, c → values 1, 2, 3
		T.eq(r[1], 1) T.eq(r[2], 2) T.eq(r[3], 3)
	end)
end)

T.describe("entries", function()
	T.it("returns k/v pairs sorted by key", function()
		local r = E.entries({b = 2, a = 1})
		T.eq(r[1][1], "a") T.eq(r[1][2], 1)
		T.eq(r[2][1], "b") T.eq(r[2][2], 2)
	end)
end)

T.describe("from_entries", function()
	T.it("builds map", function()
		local r = E.from_entries({{"a", 1}, {"b", 2}})
		T.eq(r.a, 1) T.eq(r.b, 2)
	end)
	T.it("round-trips entries", function()
		local orig = {x = 10, y = 20}
		local r = E.from_entries(E.entries(orig))
		T.eq(r.x, 10) T.eq(r.y, 20)
	end)
end)

-- ---------------------------------------------------------------------------
-- map_keys / map_values / filter_keys / filter_values
-- ---------------------------------------------------------------------------
T.describe("map_keys", function()
	T.it("uppercases keys", function()
		local r = E.map_keys({a = 1, b = 2}, function(k) return k:upper() end)
		T.eq(r.A, 1) T.eq(r.B, 2)
	end)
end)

T.describe("map_values", function()
	T.it("doubles values", function()
		local r = E.map_values({a = 1, b = 2}, function(v) return v * 2 end)
		T.eq(r.a, 2) T.eq(r.b, 4)
	end)
end)

T.describe("filter_keys", function()
	T.it("keeps matching keys", function()
		local r = E.filter_keys({a = 1, b = 2, c = 3}, function(k) return k ~= "b" end)
		T.eq(r.a, 1) T.eq(r.b, nil) T.eq(r.c, 3)
	end)
end)

T.describe("filter_values", function()
	T.it("keeps values > 1", function()
		local r = E.filter_values({a = 1, b = 2, c = 3}, function(v) return v > 1 end)
		T.eq(r.a, nil) T.eq(r.b, 2) T.eq(r.c, 3)
	end)
end)

-- ---------------------------------------------------------------------------
-- merge / deep_merge
-- ---------------------------------------------------------------------------
T.describe("merge", function()
	T.it("later wins", function()
		local r = E.merge({a = 1, b = 2}, {b = 99, c = 3})
		T.eq(r.a, 1) T.eq(r.b, 99) T.eq(r.c, 3)
	end)
	T.it("three tables", function()
		local r = E.merge({a = 1}, {b = 2}, {c = 3})
		T.eq(r.a, 1) T.eq(r.b, 2) T.eq(r.c, 3)
	end)
end)

T.describe("deep_merge", function()
	T.it("merges nested tables", function()
		local r = E.deep_merge(
			{a = {x = 1, y = 2}, b = 10},
			{a = {y = 99, z = 3}, c = 20}
		)
		T.eq(r.b, 10) T.eq(r.c, 20)
		T.eq(r.a.x, 1) T.eq(r.a.y, 99) T.eq(r.a.z, 3)
	end)
	T.it("non-table wins over table", function()
		local r = E.deep_merge({a = {x = 1}}, {a = 42})
		T.eq(r.a, 42)
	end)
	T.it("does not mutate inputs", function()
		local t1 = {a = {x = 1}}
		E.deep_merge(t1, {a = {y = 2}})
		T.eq(t1.a.y, nil)
	end)
end)

-- ---------------------------------------------------------------------------
-- pick / omit
-- ---------------------------------------------------------------------------
T.describe("pick", function()
	T.it("keeps only specified keys", function()
		local r = E.pick({a = 1, b = 2, c = 3}, {"a", "c"})
		T.eq(r.a, 1) T.eq(r.b, nil) T.eq(r.c, 3)
	end)
end)

T.describe("omit", function()
	T.it("removes specified keys", function()
		local r = E.omit({a = 1, b = 2, c = 3}, {"b"})
		T.eq(r.a, 1) T.eq(r.b, nil) T.eq(r.c, 3)
	end)
end)

-- ---------------------------------------------------------------------------
-- invert / has_key
-- ---------------------------------------------------------------------------
T.describe("invert", function()
	T.it("swaps keys and values", function()
		local r = E.invert({a = 1, b = 2})
		T.eq(r[1], "a") T.eq(r[2], "b")
	end)
end)

T.describe("has_key", function()
	T.it("true when key exists", function()
		T.ok(E.has_key({a = 1}, "a"))
	end)
	T.it("false when key absent", function()
		T.ok(not E.has_key({a = 1}, "b"))
	end)
end)

-- ---------------------------------------------------------------------------
-- shallow_copy / deep_copy / eq (deep equality)
-- ---------------------------------------------------------------------------
T.describe("shallow_copy", function()
	T.it("copies top-level values", function()
		local orig = {a = 1, b = {x = 2}}
		local copy = E.shallow_copy(orig)
		T.eq(copy.a, 1)
		-- same sub-table reference
		T.ok(copy.b == orig.b)
	end)
end)

T.describe("deep_copy", function()
	T.it("copies nested tables", function()
		local orig = {a = 1, b = {x = 2, y = {z = 3}}}
		local copy = E.deep_copy(orig)
		T.eq(copy.b.y.z, 3)
		T.ok(copy.b ~= orig.b)
	end)
end)

T.describe("eq (deep equality)", function()
	T.it("equal tables", function()
		T.ok(E.eq({a = 1, b = {2, 3}}, {a = 1, b = {2, 3}}))
	end)
	T.it("different values", function()
		T.ok(not E.eq({a = 1}, {a = 2}))
	end)
	T.it("missing key", function()
		T.ok(not E.eq({a = 1}, {a = 1, b = 2}))
	end)
	T.it("scalars equal", function()
		T.ok(E.eq(42, 42))
	end)
	T.it("scalars not equal", function()
		T.ok(not E.eq(1, 2))
	end)
	T.it("different types", function()
		T.ok(not E.eq(1, "1"))
	end)
end)

-- ---------------------------------------------------------------------------
-- size / is_array / is_empty
-- ---------------------------------------------------------------------------
T.describe("size", function()
	T.it("counts array keys", function()
		T.eq(E.size({10, 20, 30}), 3)
	end)
	T.it("counts string keys", function()
		T.eq(E.size({a = 1, b = 2}), 2)
	end)
end)

T.describe("is_array", function()
	T.it("true for contiguous integer keys", function()
		T.ok(E.is_array({1, 2, 3}))
	end)
	T.it("false for mixed", function()
		local t = {1, 2}
		t.x = 3
		T.ok(not E.is_array(t))
	end)
	T.it("true for empty", function()
		T.ok(E.is_array({}))
	end)
end)

T.describe("is_empty", function()
	T.it("true for empty table", function()
		T.ok(E.is_empty({}))
	end)
	T.it("false for non-empty", function()
		T.ok(not E.is_empty({1}))
	end)
end)

-- ---------------------------------------------------------------------------
-- shuffle / sample (smoke tests — deterministic only checks length/membership)
-- ---------------------------------------------------------------------------
T.describe("shuffle", function()
	T.it("returns same table in-place", function()
		local t = {1, 2, 3, 4}
		local r = E.shuffle(t)
		T.ok(r == t)
		T.eq(#r, 4)
		-- all original elements still present
		T.ok(E.contains(r, 1) and E.contains(r, 4))
	end)
end)

T.describe("sample", function()
	T.it("returns n elements", function()
		local r = E.sample({1, 2, 3, 4, 5}, 3)
		T.eq(#r, 3)
		-- all elements come from original
		for _, v in ipairs(r) do
			T.ok(E.contains({1, 2, 3, 4, 5}, v))
		end
	end)
end)
