-- lib/lru_cache/lru_cache_test.lua
-- Tests for the LRU cache implementation.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local LRU = require("lib.lru_cache")

-- ── Helpers ────────────────────────────────────────────────────────────────────

local function keys_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- ── Basic get/set/has ─────────────────────────────────────────────────────────

T.describe("lru_cache: basic get/set/has", function()
  T.it("get on empty cache returns nil", function()
    local c = LRU.new(3)
    T.eq(c:get("x"), nil)
  end)

  T.it("set and get a value", function()
    local c = LRU.new(3)
    c:set("a", 10)
    T.eq(c:get("a"), 10)
  end)

  T.it("has returns true for present key", function()
    local c = LRU.new(3)
    c:set("a", 1)
    T.ok(c:has("a"))
  end)

  T.it("has returns false for absent key", function()
    local c = LRU.new(3)
    T.ok(not c:has("z"))
  end)

  T.it("set multiple keys and retrieve each", function()
    local c = LRU.new(5)
    c:set("x", 100)
    c:set("y", 200)
    c:set("z", 300)
    T.eq(c:get("x"), 100)
    T.eq(c:get("y"), 200)
    T.eq(c:get("z"), 300)
  end)

  T.it("overwrite existing key value", function()
    local c = LRU.new(3)
    c:set("k", 1)
    c:set("k", 99)
    T.eq(c:get("k"), 99)
  end)

  T.it("size reflects number of entries", function()
    local c = LRU.new(5)
    T.eq(c:size(), 0)
    c:set("a", 1)
    T.eq(c:size(), 1)
    c:set("b", 2)
    T.eq(c:size(), 2)
  end)
end)

-- ── Eviction order ─────────────────────────────────────────────────────────────

T.describe("lru_cache: eviction order", function()
  T.it("evicts LRU entry when at capacity", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    -- "a" is LRU; inserting "d" should evict "a"
    c:set("d", 4)
    T.ok(not c:has("a"))
    T.ok(c:has("b"))
    T.ok(c:has("c"))
    T.ok(c:has("d"))
  end)

  T.it("get promotes key; updated LRU is evicted", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    -- promote "a" to MRU
    c:get("a")
    -- "b" is now LRU; inserting "d" should evict "b"
    c:set("d", 4)
    T.ok(c:has("a"))
    T.ok(not c:has("b"))
    T.ok(c:has("c"))
    T.ok(c:has("d"))
  end)

  T.it("set on existing key promotes to MRU", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    -- re-set "a" → moves to MRU, "b" becomes LRU
    c:set("a", 11)
    c:set("d", 4)
    T.ok(c:has("a"))
    T.eq(c:get("a"), 11)
    T.ok(not c:has("b"))
    T.ok(c:has("c"))
    T.ok(c:has("d"))
  end)

  T.it("multiple evictions in order", function()
    local c = LRU.new(2)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)  -- evicts "a"
    T.ok(not c:has("a"))
    c:set("d", 4)  -- evicts "b"
    T.ok(not c:has("b"))
    T.ok(c:has("c"))
    T.ok(c:has("d"))
  end)

  T.it("sequential access pattern — oldest always evicted", function()
    local c = LRU.new(3)
    local evicted = {}
    c:evict_callback(function(k, _) evicted[#evicted + 1] = k end)
    for i = 1, 6 do
      c:set(tostring(i), i)
    end
    -- evicted should be "1","2","3" in order
    T.eq(evicted[1], "1")
    T.eq(evicted[2], "2")
    T.eq(evicted[3], "3")
  end)
end)

-- ── Delete ─────────────────────────────────────────────────────────────────────

T.describe("lru_cache: delete", function()
  T.it("delete returns true for existing key", function()
    local c = LRU.new(3)
    c:set("a", 1)
    T.ok(c:delete("a"))
  end)

  T.it("delete returns false for missing key", function()
    local c = LRU.new(3)
    T.ok(not c:delete("z"))
  end)

  T.it("key not accessible after delete", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:delete("a")
    T.eq(c:get("a"), nil)
    T.ok(not c:has("a"))
  end)

  T.it("size decrements after delete", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    T.eq(c:size(), 2)
    c:delete("a")
    T.eq(c:size(), 1)
  end)

  T.it("deleted slot can be reused", function()
    local c = LRU.new(2)
    c:set("a", 1)
    c:set("b", 2)
    c:delete("a")
    c:set("c", 3)  -- should not evict "b"
    T.ok(c:has("b"))
    T.ok(c:has("c"))
    T.eq(c:size(), 2)
  end)
end)

-- ── Size and clear ─────────────────────────────────────────────────────────────

T.describe("lru_cache: size and clear", function()
  T.it("size is 0 on new cache", function()
    local c = LRU.new(10)
    T.eq(c:size(), 0)
  end)

  T.it("size does not exceed capacity", function()
    local c = LRU.new(3)
    for i = 1, 10 do c:set(i, i) end
    T.eq(c:size(), 3)
  end)

  T.it("clear removes all entries", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    c:clear()
    T.eq(c:size(), 0)
    T.ok(not c:has("a"))
    T.ok(not c:has("b"))
    T.ok(not c:has("c"))
  end)

  T.it("cache is usable after clear", function()
    local c = LRU.new(2)
    c:set("x", 9)
    c:clear()
    c:set("y", 8)
    c:set("z", 7)
    T.eq(c:get("y"), 8)
    T.eq(c:get("z"), 7)
    T.eq(c:size(), 2)
  end)
end)

-- ── Keys order ─────────────────────────────────────────────────────────────────

T.describe("lru_cache: keys order", function()
  T.it("keys returns empty array for empty cache", function()
    local c = LRU.new(3)
    T.eq(#c:keys(), 0)
  end)

  T.it("keys returns MRU→LRU order after inserts", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    -- MRU is "c", LRU is "a"
    T.ok(keys_eq(c:keys(), { "c", "b", "a" }))
  end)

  T.it("get promotes key to front in keys()", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    c:get("a")
    T.ok(keys_eq(c:keys(), { "a", "c", "b" }))
  end)

  T.it("set on existing key moves it to front", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    c:set("a", 10)
    T.ok(keys_eq(c:keys(), { "a", "c", "b" }))
  end)

  T.it("keys after eviction excludes evicted key", function()
    local c = LRU.new(2)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)  -- evicts "a"
    local ks = c:keys()
    T.eq(#ks, 2)
    T.ok(ks[1] == "c")
    T.ok(ks[2] == "b")
  end)
end)

-- ── Peek ───────────────────────────────────────────────────────────────────────

T.describe("lru_cache: peek", function()
  T.it("peek returns value without promoting", function()
    local c = LRU.new(3)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    -- "a" is LRU; peek should not promote it
    T.eq(c:peek("a"), 1)
    -- keys order should still be c,b,a
    T.ok(keys_eq(c:keys(), { "c", "b", "a" }))
  end)

  T.it("peek on missing key returns nil", function()
    local c = LRU.new(3)
    T.eq(c:peek("nope"), nil)
  end)

  T.it("peek does not prevent LRU eviction", function()
    local c = LRU.new(2)
    c:set("a", 1)
    c:set("b", 2)
    c:peek("a")  -- peek at LRU — should not promote
    c:set("c", 3)  -- should evict "a"
    T.ok(not c:has("a"))
    T.ok(c:has("b"))
    T.ok(c:has("c"))
  end)
end)

-- ── Evict callback ─────────────────────────────────────────────────────────────

T.describe("lru_cache: evict callback", function()
  T.it("callback fires with correct key and value", function()
    local c = LRU.new(2)
    local fired_key, fired_val
    c:evict_callback(function(k, v) fired_key = k; fired_val = v end)
    c:set("a", 42)
    c:set("b", 43)
    c:set("c", 44)  -- evicts "a"
    T.eq(fired_key, "a")
    T.eq(fired_val, 42)
  end)

  T.it("callback fires for each eviction", function()
    local c = LRU.new(1)
    local count = 0
    c:evict_callback(function() count = count + 1 end)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    T.eq(count, 2)
  end)

  T.it("no callback when updating existing key", function()
    local c = LRU.new(3)
    local count = 0
    c:evict_callback(function() count = count + 1 end)
    c:set("a", 1)
    c:set("a", 2)  -- update, no eviction
    T.eq(count, 0)
  end)

  T.it("callback can be cleared by passing nil", function()
    local c = LRU.new(1)
    local count = 0
    c:evict_callback(function() count = count + 1 end)
    c:set("a", 1)
    c:evict_callback(nil)
    c:set("b", 2)  -- evicts "a" but no callback
    T.eq(count, 0)
  end)
end)

-- ── Capacity 1 edge case ───────────────────────────────────────────────────────

T.describe("lru_cache: capacity 1", function()
  T.it("only holds one entry", function()
    local c = LRU.new(1)
    c:set("a", 1)
    c:set("b", 2)
    T.ok(not c:has("a"))
    T.ok(c:has("b"))
    T.eq(c:size(), 1)
  end)

  T.it("get then set evicts the gotten key", function()
    local c = LRU.new(1)
    c:set("a", 1)
    c:get("a")
    c:set("b", 2)
    T.ok(not c:has("a"))
    T.ok(c:has("b"))
  end)

  T.it("keys returns single entry", function()
    local c = LRU.new(1)
    c:set("x", 99)
    T.ok(keys_eq(c:keys(), { "x" }))
  end)

  T.it("evict callback fires on every insert past 1", function()
    local evicted = {}
    local c = LRU.new(1)
    c:evict_callback(function(k, v) evicted[#evicted + 1] = { k, v } end)
    c:set("a", 1)
    c:set("b", 2)
    c:set("c", 3)
    T.eq(#evicted, 2)
    T.eq(evicted[1][1], "a")
    T.eq(evicted[2][1], "b")
  end)

  T.it("set same key on cap-1 cache doesn't evict", function()
    local c = LRU.new(1)
    local count = 0
    c:evict_callback(function() count = count + 1 end)
    c:set("a", 1)
    c:set("a", 2)
    T.eq(count, 0)
    T.eq(c:get("a"), 2)
  end)
end)

-- ── Module metadata ────────────────────────────────────────────────────────────

T.describe("lru_cache: module metadata", function()
  T.it("_tier is 'pure'", function()
    T.eq(LRU._tier, "pure")
  end)

  T.it("new returns a distinct cache per call", function()
    local c1 = LRU.new(2)
    local c2 = LRU.new(2)
    c1:set("x", 1)
    T.ok(not c2:has("x"))
  end)
end)
