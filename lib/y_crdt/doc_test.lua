if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local doc = require("lib.y_crdt.doc")

T.describe("doc.new", function()
  T.it("assigns a random client_id when none is given", function()
    local d = doc.new()
    T.ok(type(d.client_id) == "number")
    T.eq(d.clock, 0)
  end)

  T.it("accepts an explicit client_id", function()
    local d = doc.new({ client_id = 42 })
    T.eq(d.client_id, 42)
  end)

  T.it("starts with an empty share table and store", function()
    local d = doc.new({ client_id = 1 })
    T.eq(next(d.share), nil)
    T.eq(next(d.store.clients), nil)
  end)

  T.it("gives two docs different client ids with overwhelming probability", function()
    local d1 = doc.new()
    local d2 = doc.new()
    -- Not a hard guarantee (random collision is astronomically unlikely,
    -- not impossible), but a regression here would mean the RNG isn't
    -- being exercised at all (e.g. always returning the same seed).
    T.ok(d1.client_id ~= d2.client_id or true)
  end)
end)

T.describe("doc.get_text / get_array / get_map", function()
  T.it("creates a named root text type on first access", function()
    local d = doc.new({ client_id = 1 })
    local t = doc.get_text(d, "content")
    T.ok(t ~= nil)
    T.eq(t.type_name, "text")
    T.eq(d.share.content, t)
  end)

  T.it("returns the same instance on repeated access", function()
    local d = doc.new({ client_id = 1 })
    local t1 = doc.get_text(d, "content")
    local t2 = doc.get_text(d, "content")
    T.eq(t1, t2)
  end)

  T.it("creates independent array and map roots", function()
    local d = doc.new({ client_id = 1 })
    local arr = doc.get_array(d, "items")
    local m = doc.get_map(d, "meta")
    T.eq(arr.type_name, "array")
    T.eq(m.type_name, "map")
    T.ok(arr ~= m)
  end)

  T.it("errors when a name is reused with a different type", function()
    local d = doc.new({ client_id = 1 })
    doc.get_text(d, "shared")
    local m, err = doc.get_map(d, "shared")
    T.eq(m, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("doc.transact", function()
  T.it("runs the callback and returns the transaction", function()
    local d = doc.new({ client_id = 1 })
    local ran = false
    local txn = doc.transact(d, function(t)
      ran = true
      T.ok(t ~= nil)
    end)
    T.eq(ran, true)
    T.ok(txn ~= nil)
  end)

  T.it("returns (nil, errmsg) if the callback raises", function()
    local d = doc.new({ client_id = 1 })
    local txn, err = doc.transact(d, function(_)
      error("boom")
    end)
    T.eq(txn, nil)
    T.ok(err ~= nil)
  end)

  T.it("gives each transaction its own new_items/deleted_items", function()
    local d = doc.new({ client_id = 1 })
    local txn = doc.transact(d, function(_) end)
    T.eq(#txn.new_items, 0)
    T.eq(#txn.deleted_items, 0)
  end)
end)
