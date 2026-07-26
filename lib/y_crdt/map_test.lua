if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local doc = require("lib.y_crdt.doc")
local map = require("lib.y_crdt.map")
local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local integrate = require("lib.y_crdt.integrate")

T.describe("map.set / map.get", function()
  T.it("sets and gets a value", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      T.ok(map.set(m, txn, "name", "alice"))
    end)
    T.eq(map.get(m, "name"), "alice")
  end)

  T.it("returns nil for an unset key", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    T.eq(map.get(m, "missing"), nil)
  end)

  T.it("overwrite replaces the value for a key", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      map.set(m, txn, "count", 1)
      map.set(m, txn, "count", 2)
    end)
    T.eq(map.get(m, "count"), 2)
  end)

  T.it("rejects a non-string key", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      local ok, err = map.set(m, txn, 5, "x")
      T.eq(ok, nil)
      T.ok(err ~= nil)
    end)
  end)
end)

T.describe("map.delete / map.has", function()
  T.it("delete removes a key", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      map.set(m, txn, "name", "alice")
      map.delete(m, txn, "name")
    end)
    T.eq(map.get(m, "name"), nil)
    T.eq(map.has(m, "name"), false)
  end)

  T.it("has is true for a set key and false otherwise", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      map.set(m, txn, "name", "alice")
    end)
    T.eq(map.has(m, "name"), true)
    T.eq(map.has(m, "other"), false)
  end)

  T.it("delete on an unset key is a no-op", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      T.ok(map.delete(m, txn, "missing"))
    end)
  end)
end)

T.describe("map.to_table / map.keys / map.entries", function()
  T.it("to_table reflects all set, non-deleted keys", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      map.set(m, txn, "a", 1)
      map.set(m, txn, "b", 2)
      map.set(m, txn, "c", 3)
      map.delete(m, txn, "b")
    end)
    local t = map.to_table(m)
    T.eq(t.a, 1)
    T.eq(t.b, nil)
    T.eq(t.c, 3)
  end)

  T.it("keys iterates only non-deleted keys", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      map.set(m, txn, "a", 1)
      map.set(m, txn, "b", 2)
      map.delete(m, txn, "b")
    end)
    local seen = {}
    local n = 0
    for k in map.keys(m) do
      seen[k] = true
      n = n + 1
    end
    T.eq(n, 1)
    T.eq(seen.a, true)
    T.eq(seen.b, nil)
  end)

  T.it("entries iterates non-deleted key/value pairs", function()
    local d = doc.new({ client_id = 1 })
    local m = doc.get_map(d, "meta")
    doc.transact(d, function(txn)
      map.set(m, txn, "a", 1)
      map.set(m, txn, "b", 2)
      map.delete(m, txn, "b")
    end)
    local seen = {}
    local n = 0
    for k, v in map.entries(m) do
      seen[k] = v
      n = n + 1
    end
    T.eq(n, 1)
    T.eq(seen.a, 1)
    T.eq(seen.b, nil)
  end)
end)

T.describe("map concurrent sets (last-writer-wins by clock/client)", function()
  T.it("converges to the same value regardless of integration order", function()
    -- Two concurrent writes to the same key from an empty map, same (nil)
    -- origin: client 1 writes "A" at clock 0, client 2 writes "B" at clock
    -- 0. YATA is order-independent by construction, so the winner must be
    -- determined by (clock, client) alone, not by integration order --
    -- traced through integrate.lua's same-origin conflict-resolution rule
    -- ("lower client id goes left"): client 1 (lower) always ends up as
    -- the left/superseded neighbor and client 2 (higher) always ends up
    -- as the current map value, in *either* integration order. (Verified
    -- by hand-tracing both orders through integrate.lua's Map-entry
        -- branch before writing this assertion -- not assumed.)
    --: (first: "a" | "b") -> unknown
    local function build(first)
      local d = doc.new({ client_id = 99 })
      local m = doc.get_map(d, "meta")
      doc.transact(d, function(txn)
        local item_a = item.new(id.new(1, 0), nil, nil, m, "key", content.any({ "A" }))
        local item_b = item.new(id.new(2, 0), nil, nil, m, "key", content.any({ "B" }))
        if first == "a" then
          integrate.integrate(txn, item_a)
          integrate.integrate(txn, item_b)
        else
          integrate.integrate(txn, item_b)
          integrate.integrate(txn, item_a)
        end
      end)
      return map.get(m, "key")
    end

    local v1 = build("a")
    local v2 = build("b")
    T.eq(v1, v2)
    T.eq(v1, "B")
  end)
end)
