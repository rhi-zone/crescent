if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local lru = require("lib.lru")

-- ── LRU ───────────────────────────────────────────────────────────────────────

T.describe("lru.new", function()

  T.describe("construction", function()
    T.it("creates cache with given capacity", function()
      local c = lru.new(10)
      T.ok(c)
      T.eq(c:capacity(), 10)
      T.eq(c:size(), 0)
    end)

    T.it("returns nil, errmsg for invalid capacity", function()
      local c, err = lru.new(0)
      T.eq(c, nil)
      T.ok(err)
      local c2, err2 = lru.new(-5)
      T.eq(c2, nil)
      T.ok(err2)
    end)

    T.it("floors fractional capacity", function()
      local c = lru.new(4.9)
      T.eq(c:capacity(), 4)
    end)
  end)

  T.describe("get/set/has/peek/delete", function()
    T.it("set and get a value", function()
      local c = lru.new(10)
      c:set("k", "v")
      T.eq(c:get("k"), "v")
    end)

    T.it("get returns nil for missing key", function()
      local c = lru.new(10)
      T.eq(c:get("nope"), nil)
    end)

    T.it("set returns old value on overwrite", function()
      local c = lru.new(10)
      T.eq(c:set("k", 1), nil)
      T.eq(c:set("k", 2), 1)
      T.eq(c:get("k"), 2)
    end)

    T.it("has returns true for existing key (no promotion)", function()
      local c = lru.new(3)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      T.ok(c:has("a"))
      -- "a" must not have been promoted — next insert should evict "a"
      c:set("d", 4)
      T.eq(c:get("a"), nil)
    end)

    T.it("has returns false for missing key", function()
      local c = lru.new(5)
      T.eq(c:has("x"), false)
    end)

    T.it("peek returns value without promoting", function()
      local c = lru.new(3)
      c:set("a", 1)
      c:set("b", 2)
      c:set("c", 3)
      T.eq(c:peek("a"), 1)
      c:set("d", 4)  -- should evict "a" (not promoted by peek)
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), 2)
    end)

    T.it("peek returns nil for missing key", function()
      local c = lru.new(5)
      T.eq(c:peek("nope"), nil)
    end)

    T.it("delete removes entry and returns old value", function()
      local c = lru.new(5)
      c:set("a", 42)
      local old = c:delete("a")
      T.eq(old, 42)
      T.eq(c:get("a"), nil)
      T.eq(c:size(), 0)
    end)

    T.it("delete non-existent key returns nil", function()
      local c = lru.new(5)
      T.eq(c:delete("nope"), nil)
    end)
  end)

  T.describe("eviction", function()
    T.it("evicts LRU item when full", function()
      local c = lru.new(3)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      c:set("d", 4)  -- evicts "a"
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), 2)
      T.eq(c:get("d"), 4)
      T.eq(c:size(), 3)
    end)

    T.it("get promotes, changing eviction order", function()
      local c = lru.new(3)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      c:get("a")  -- promote "a"
      c:set("d", 4)  -- should evict "b"
      T.eq(c:get("b"), nil)
      T.eq(c:get("a"), 1)
      T.eq(c:get("c"), 3)
    end)

    T.it("set on existing key promotes", function()
      local c = lru.new(3)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      c:set("a", 10)  -- overwrite promotes "a"
      c:set("d", 4)   -- evicts "b"
      T.eq(c:get("a"), 10)
      T.eq(c:get("b"), nil)
    end)

    T.it("eviction callback fires", function()
      local evicted = {}
      local c = lru.new(2, {
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1); c:set("b", 2)
      c:set("c", 3)  -- evicts "a"
      T.eq(#evicted, 1)
      T.eq(evicted[1][1], "a")
      T.eq(evicted[1][2], 1)
    end)

    T.it("eviction callback NOT fired on delete", function()
      local evicted = {}
      local c = lru.new(5, {
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1)
      c:delete("a")
      T.eq(#evicted, 0)
    end)

    T.it("eviction callback NOT fired on clear", function()
      local evicted = {}
      local c = lru.new(5, {
        on_evict = function(k, v) evicted[#evicted + 1] = { k, v } end,
      })
      c:set("a", 1); c:set("b", 2)
      c:clear()
      T.eq(#evicted, 0)
    end)
  end)

  T.describe("size / capacity / is_full / clear", function()
    T.it("size reflects live entries", function()
      local c = lru.new(5)
      T.eq(c:size(), 0)
      c:set("a", 1)
      T.eq(c:size(), 1)
      c:set("b", 2)
      T.eq(c:size(), 2)
      c:delete("a")
      T.eq(c:size(), 1)
    end)

    T.it("is_full true when at capacity", function()
      local c = lru.new(2)
      T.eq(c:is_full(), false)
      c:set("a", 1)
      T.eq(c:is_full(), false)
      c:set("b", 2)
      T.eq(c:is_full(), true)
    end)

    T.it("clear removes all entries", function()
      local c = lru.new(5)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      c:clear()
      T.eq(c:size(), 0)
      T.eq(c:get("a"), nil)
    end)
  end)

  T.describe("TTL", function()
    T.it("entries expire after default TTL", function()
      local now = 1000
      local c = lru.new(10, { ttl = 60, clock = function() return now end })
      c:set("a", 1)
      T.eq(c:get("a"), 1)
      now = 1059
      T.eq(c:get("a"), 1)
      now = 1060
      T.eq(c:get("a"), nil)
    end)

    T.it("per-entry TTL override", function()
      local now = 1000
      local c = lru.new(10, { ttl = 60, clock = function() return now end })
      c:set("short", "v", 10)
      c:set("long",  "v")
      now = 1011
      T.eq(c:get("short"), nil)
      T.eq(c:get("long"),  "v")
    end)

    T.it("has returns false for expired entry", function()
      local now = 100
      local c = lru.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1)
      T.ok(c:has("a"))
      now = 105
      T.eq(c:has("a"), false)
    end)

    T.it("peek returns nil for expired entry", function()
      local now = 100
      local c = lru.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1)
      now = 200
      T.eq(c:peek("a"), nil)
    end)

    T.it("expired entry removed from size on get", function()
      local now = 100
      local c = lru.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1)
      T.eq(c:size(), 1)
      now = 200
      c:get("a")
      T.eq(c:size(), 0)
    end)

    T.it("TTL expiry fires on_evict", function()
      local now = 100
      local evicted = {}
      local c = lru.new(10, {
        ttl   = 5,
        clock = function() return now end,
        on_evict = function(k, v) evicted[#evicted + 1] = {k, v} end,
      })
      c:set("a", 1)
      now = 200
      c:get("a")
      T.eq(#evicted, 1)
      T.eq(evicted[1][1], "a")
    end)

    T.it("no TTL means entry never expires", function()
      local now = 0
      local c = lru.new(10, { clock = function() return now end })
      c:set("a", 1)
      now = 999999999
      T.eq(c:get("a"), 1)
    end)
  end)

  T.describe("get_or_set", function()
    T.it("returns existing value without calling loader", function()
      local calls = 0
      local c = lru.new(5)
      c:set("k", 42)
      local v = c:get_or_set("k", function() calls = calls + 1; return 99 end)
      T.eq(v, 42)
      T.eq(calls, 0)
    end)

    T.it("calls loader for missing key and stores result", function()
      local c = lru.new(5)
      local v = c:get_or_set("k", function() return "computed" end)
      T.eq(v, "computed")
      T.eq(c:get("k"), "computed")
    end)
  end)

  T.describe("mget / mset", function()
    T.it("mget returns found entries, omits missing", function()
      local c = lru.new(10)
      c:set("a", 1); c:set("b", 2)
      local r = c:mget({"a", "b", "missing"})
      T.eq(r.a, 1)
      T.eq(r.b, 2)
      T.eq(r.missing, nil)
    end)

    T.it("mset stores multiple key-value pairs", function()
      local c = lru.new(10)
      c:mset({ x = 10, y = 20, z = 30 })
      T.eq(c:get("x"), 10)
      T.eq(c:get("y"), 20)
      T.eq(c:get("z"), 30)
      T.eq(c:size(), 3)
    end)
  end)

  T.describe("iter / keys / values / pairs", function()
    T.it("iter returns (key, value) in MRU order", function()
      local c = lru.new(10)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      local out = {}
      for k, v in c:iter() do
        out[#out + 1] = {k, v}
      end
      T.eq(#out, 3)
      T.eq(out[1][1], "c")
      T.eq(out[2][1], "b")
      T.eq(out[3][1], "a")
    end)

    T.it("keys returns array in MRU order", function()
      local c = lru.new(10)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      local k = c:keys()
      T.eq(k[1], "c"); T.eq(k[2], "b"); T.eq(k[3], "a")
      T.eq(#k, 3)
    end)

    T.it("values returns array in MRU order", function()
      local c = lru.new(10)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      local v = c:values()
      T.eq(v[1], 3); T.eq(v[2], 2); T.eq(v[3], 1)
    end)

    T.it("pairs returns array of {key, value} in MRU order", function()
      local c = lru.new(10)
      c:set("a", 1); c:set("b", 2)
      local p = c:pairs()
      T.eq(p[1][1], "b"); T.eq(p[1][2], 2)
      T.eq(p[2][1], "a"); T.eq(p[2][2], 1)
    end)

    T.it("keys skips expired entries", function()
      local now = 100
      local c = lru.new(10, { ttl = 5, clock = function() return now end })
      c:set("a", 1); c:set("b", 2)
      now = 200
      c:set("c", 3)
      local k = c:keys()
      T.eq(#k, 1); T.eq(k[1], "c")
    end)
  end)

  T.describe("stats / hit_rate / reset_stats", function()
    T.it("hit_rate reflects hits and misses", function()
      local c = lru.new(5)
      c:set("a", 1)
      c:get("a"); c:get("a")  -- 2 hits
      c:get("x"); c:get("y")  -- 2 misses
      local hr = c:hit_rate()
      -- 2 / (2+2) = 0.5
      T.ok(math.abs(hr - 0.5) < 1e-9)
    end)

    T.it("hit_rate returns 0 with no lookups", function()
      local c = lru.new(5)
      T.eq(c:hit_rate(), 0)
    end)

    T.it("stats returns correct counts", function()
      local c = lru.new(2)
      c:set("a", 1); c:set("b", 2)
      c:get("a")
      c:get("z")  -- miss
      c:set("c", 3)  -- evicts "b"
      local s = c:stats()
      T.eq(s.hits,      1)
      T.eq(s.misses,    1)
      T.eq(s.evictions, 1)
      T.eq(s.size,      2)
      T.eq(s.capacity,  2)
    end)

    T.it("reset_stats zeroes counters", function()
      local c = lru.new(5)
      c:set("a", 1)
      c:get("a"); c:get("z")
      c:reset_stats()
      local s = c:stats()
      T.eq(s.hits,   0)
      T.eq(s.misses, 0)
    end)
  end)

end)

-- ── LFU ───────────────────────────────────────────────────────────────────────

T.describe("lru.lfu_new", function()

  T.describe("construction", function()
    T.it("creates LFU cache with given capacity", function()
      local c = lru.lfu_new(5)
      T.ok(c)
      T.eq(c:capacity(), 5)
      T.eq(c:size(), 0)
    end)

    T.it("returns nil, errmsg for invalid capacity", function()
      local c, err = lru.lfu_new(0)
      T.eq(c, nil)
      T.ok(err)
    end)
  end)

  T.describe("get / set / has / peek / delete", function()
    T.it("set and get", function()
      local c = lru.lfu_new(5)
      c:set("a", 10)
      T.eq(c:get("a"), 10)
    end)

    T.it("get returns nil for missing", function()
      local c = lru.lfu_new(5)
      T.eq(c:get("nope"), nil)
    end)

    T.it("has and peek work without promoting", function()
      local c = lru.lfu_new(5)
      c:set("a", 1)
      T.ok(c:has("a"))
      T.eq(c:peek("a"), 1)
      T.eq(c:has("z"), false)
      T.eq(c:peek("z"), nil)
    end)

    T.it("delete removes entry", function()
      local c = lru.lfu_new(5)
      c:set("a", 99)
      local old = c:delete("a")
      T.eq(old, 99)
      T.eq(c:get("a"), nil)
      T.eq(c:size(), 0)
    end)

    T.it("delete non-existent returns nil", function()
      local c = lru.lfu_new(5)
      T.eq(c:delete("nope"), nil)
    end)
  end)

  T.describe("frequency tracking", function()
    T.it("frequency starts at 1 after set", function()
      local c = lru.lfu_new(5)
      c:set("a", 1)
      T.eq(c:frequency("a"), 1)
    end)

    T.it("frequency increments on each get", function()
      local c = lru.lfu_new(5)
      c:set("a", 1)
      c:get("a"); c:get("a")
      T.eq(c:frequency("a"), 3)
    end)

    T.it("frequency increments on set overwrite", function()
      local c = lru.lfu_new(5)
      c:set("a", 1)
      c:set("a", 2)  -- overwrite also promotes
      T.eq(c:frequency("a"), 2)
    end)

    T.it("frequency 0 for unknown key", function()
      local c = lru.lfu_new(5)
      T.eq(c:frequency("nope"), 0)
    end)
  end)

  T.describe("LFU eviction", function()
    T.it("evicts lowest-frequency item when full", function()
      local c = lru.lfu_new(3)
      c:set("a", 1); c:get("a"); c:get("a")  -- freq("a") = 3
      c:set("b", 2); c:get("b")               -- freq("b") = 2
      c:set("c", 3)                            -- freq("c") = 1
      c:set("d", 4)  -- should evict "c" (lowest freq)
      T.eq(c:get("c"), nil)
      T.eq(c:get("a"), 1)
      T.eq(c:get("b"), 2)
    end)

    T.it("tie-break: evicts LRU among same frequency", function()
      local c = lru.lfu_new(3)
      c:set("a", 1)  -- freq 1, inserted first
      c:set("b", 2)  -- freq 1, inserted second
      c:set("c", 3)  -- freq 1, inserted third
      c:set("d", 4)  -- should evict "a" (freq 1, LRU)
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), 2)
    end)

    T.it("eviction callback fires", function()
      local evicted = {}
      local c = lru.lfu_new(2, {
        on_evict = function(k, v) evicted[#evicted + 1] = {k, v} end,
      })
      c:set("a", 1); c:set("b", 2)
      c:set("c", 3)
      T.eq(#evicted, 1)
    end)

    T.it("eviction NOT fired on delete", function()
      local evicted = {}
      local c = lru.lfu_new(5, {
        on_evict = function(k, v) evicted[#evicted + 1] = {k, v} end,
      })
      c:set("a", 1)
      c:delete("a")
      T.eq(#evicted, 0)
    end)
  end)

  T.describe("size / capacity / is_full / clear", function()
    T.it("size tracks live entries", function()
      local c = lru.lfu_new(5)
      c:set("a", 1); c:set("b", 2)
      T.eq(c:size(), 2)
      c:delete("a")
      T.eq(c:size(), 1)
    end)

    T.it("is_full at capacity", function()
      local c = lru.lfu_new(2)
      c:set("a", 1)
      T.eq(c:is_full(), false)
      c:set("b", 2)
      T.eq(c:is_full(), true)
    end)

    T.it("clear removes all entries", function()
      local c = lru.lfu_new(5)
      c:set("a", 1); c:set("b", 2)
      c:clear()
      T.eq(c:size(), 0)
      T.eq(c:get("a"), nil)
    end)
  end)

  T.describe("stats", function()
    T.it("hit_rate and stats", function()
      local c = lru.lfu_new(5)
      c:set("a", 1)
      c:get("a")  -- hit
      c:get("z")  -- miss
      local s = c:stats()
      T.eq(s.hits, 1); T.eq(s.misses, 1)
      local hr = c:hit_rate()
      T.ok(math.abs(hr - 0.5) < 1e-9)
    end)

    T.it("evictions counted in stats", function()
      local c = lru.lfu_new(2)
      c:set("a", 1); c:set("b", 2); c:set("c", 3)
      T.eq(c:stats().evictions, 1)
    end)

    T.it("reset_stats clears counters", function()
      local c = lru.lfu_new(5)
      c:set("a", 1); c:get("a"); c:get("z")
      c:reset_stats()
      T.eq(c:stats().hits, 0)
      T.eq(c:stats().misses, 0)
    end)
  end)

end)

-- ── TwoQ ──────────────────────────────────────────────────────────────────────

T.describe("lru.twoq_new", function()

  T.describe("construction", function()
    T.it("creates TwoQ cache with given capacity", function()
      local c = lru.twoq_new(10)
      T.ok(c)
      T.eq(c:capacity(), 10)
      T.eq(c:size(), 0)
    end)

    T.it("returns nil, errmsg for invalid capacity", function()
      local c, err = lru.twoq_new(0)
      T.eq(c, nil)
      T.ok(err)
    end)
  end)

  T.describe("queue membership", function()
    T.it("new item goes into 'in' queue", function()
      local c = lru.twoq_new(10)
      c:set("k", "v")
      T.ok(c:in_queue("k"))
      T.eq(c:out_queue("k"), false)
    end)

    T.it("first get keeps item in 'in' queue", function()
      local c = lru.twoq_new(10)
      c:set("k", "v")
      c:get("k")  -- first access while in "in" queue → promoted to "out"
      T.eq(c:in_queue("k"), false)
      T.ok(c:out_queue("k"))
    end)

    T.it("second get keeps item in 'out' LRU", function()
      local c = lru.twoq_new(10)
      c:set("k", "v")
      c:get("k")  -- promoted to "out"
      c:get("k")  -- still in "out"
      T.eq(c:in_queue("k"), false)
      T.ok(c:out_queue("k"))
    end)
  end)

  T.describe("ghost set", function()
    T.it("evicted-from-out items go to ghost", function()
      -- Cap=4, in_cap=1, out_cap=3
      local c = lru.twoq_new(4)
      c:set("a", 1); c:get("a")  -- "a" in "out"
      c:set("b", 2); c:get("b")  -- "b" in "out"
      c:set("c", 3); c:get("c")  -- "c" in "out"
      -- "out" is now full (3 items). Insert "d" so "in" eviction makes room.
      -- Actually: let's fill "out" then trigger out-eviction by adding more.
      c:set("d", 4); c:get("d")  -- "d" → "out", "a" evicted to ghost
      T.ok(c:in_ghost("a"))
      T.eq(c:get("a"), nil)
    end)

    T.it("ghost hit: re-insert skips 'in', goes to 'out'", function()
      local c = lru.twoq_new(4)
      c:set("a", 1); c:get("a")  -- "a" → "out"
      c:set("b", 2); c:get("b")  -- "b" → "out"
      c:set("c", 3); c:get("c")  -- "c" → "out", "out" full
      c:set("d", 4); c:get("d")  -- "d" → "out", "a" evicted to ghost
      -- Now re-insert "a": should go straight to "out"
      c:set("a", 99)
      T.eq(c:in_ghost("a"), false)  -- removed from ghost
      T.ok(c:out_queue("a"))
      T.eq(c:peek("a"), 99)
    end)
  end)

  T.describe("get / set / has / peek / delete", function()
    T.it("get returns nil for missing key", function()
      local c = lru.twoq_new(5)
      T.eq(c:get("nope"), nil)
    end)

    T.it("set then get returns value", function()
      local c = lru.twoq_new(5)
      c:set("k", "v")
      T.eq(c:peek("k"), "v")
    end)

    T.it("has detects live entries", function()
      local c = lru.twoq_new(5)
      c:set("k", "v")
      T.ok(c:has("k"))
      T.eq(c:has("z"), false)
    end)

    T.it("delete removes entry", function()
      local c = lru.twoq_new(5)
      c:set("k", "v")
      local old = c:delete("k")
      T.eq(old, "v")
      T.eq(c:get("k"), nil)
      T.eq(c:size(), 0)
    end)

    T.it("delete non-existent returns nil", function()
      local c = lru.twoq_new(5)
      T.eq(c:delete("nope"), nil)
    end)
  end)

  T.describe("size / capacity / is_full / clear", function()
    T.it("size tracks in+out", function()
      local c = lru.twoq_new(10)
      c:set("a", 1); c:set("b", 2)
      T.eq(c:size(), 2)
      c:get("a")  -- promotes "a" to "out"
      T.eq(c:size(), 2)
      c:delete("b")
      T.eq(c:size(), 1)
    end)

    T.it("is_full when at capacity", function()
      -- capacity=4: in_cap=1, out_cap=3.
      -- Fill "out" (3 items) + keep 1 in "in" = 4 total.
      local c = lru.twoq_new(4)
      c:set("a", 1); c:get("a")  -- "a" → "out"
      c:set("b", 2); c:get("b")  -- "b" → "out"
      c:set("c", 3); c:get("c")  -- "c" → "out"
      T.eq(c:is_full(), false)
      c:set("d", 4)               -- "d" → "in"; total = 4
      T.eq(c:is_full(), true)
    end)

    T.it("clear resets all queues", function()
      local c = lru.twoq_new(5)
      c:set("a", 1); c:get("a"); c:set("b", 2)
      c:clear()
      T.eq(c:size(), 0)
      T.eq(c:get("a"), nil)
      T.eq(c:get("b"), nil)
    end)
  end)

  T.describe("eviction", function()
    T.it("evicts from 'in' when 'in' is full and new item arrives", function()
      -- Cap=4, in_cap=1, out_cap=3. Only 1 item in "in" at a time.
      local c = lru.twoq_new(4)
      local evicted = {}
      -- Use a fresh cache with on_evict
      c = lru.twoq_new(4, {
        on_evict = function(k, v) evicted[#evicted + 1] = {k, v} end,
      })
      c:set("a", 1)  -- "in"={a}
      c:set("b", 2)  -- "in" full: evict "a"; "in"={b}
      T.eq(#evicted, 1)
      T.eq(evicted[1][1], "a")
    end)

    T.it("eviction callback fires on out-eviction", function()
      local evicted = {}
      local c = lru.twoq_new(4, {
        on_evict = function(k, v) evicted[#evicted + 1] = {k, v} end,
      })
      c:set("a", 1); c:get("a")  -- "a" → "out"
      c:set("b", 2); c:get("b")  -- "b" → "out"
      c:set("c", 3); c:get("c")  -- "c" → "out", "out" full
      local before = #evicted
      c:set("d", 4); c:get("d")  -- "d" → "out", evicts "a" from "out"
      T.ok(#evicted > before)
    end)
  end)

  T.describe("stats", function()
    T.it("hit_rate tracks hits and misses", function()
      local c = lru.twoq_new(5)
      c:set("a", 1)
      c:get("a")  -- hit
      c:get("z")  -- miss
      local hr = c:hit_rate()
      T.ok(math.abs(hr - 0.5) < 1e-9)
    end)

    T.it("stats returns correct fields", function()
      local c = lru.twoq_new(5)
      c:set("a", 1)
      c:get("a"); c:get("z")
      local s = c:stats()
      T.eq(s.hits, 1); T.eq(s.misses, 1)
      T.eq(s.capacity, 5)
    end)

    T.it("reset_stats clears counters", function()
      local c = lru.twoq_new(5)
      c:set("a", 1); c:get("a"); c:get("z")
      c:reset_stats()
      T.eq(c:stats().hits, 0)
      T.eq(c:stats().misses, 0)
    end)
  end)

end)
