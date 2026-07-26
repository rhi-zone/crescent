if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local shared_type = require("lib.y_crdt.shared_type")

T.describe("item.new", function()
  T.it("creates an item with the given fields", function()
    local iid = id.new(1, 0)
    local it = item.new(iid, nil, nil, nil, nil, content.string("abc"))
    T.eq(it.id.client, 1)
    T.eq(it.id.clock, 0)
    T.eq(it.origin, nil)
    T.eq(it.origin_right, nil)
    T.eq(it.left, nil)
    T.eq(it.right, nil)
    T.eq(it.parent, nil)
    T.eq(it.parent_sub, nil)
    T.eq(it.length, 3)
    T.eq(it.deleted, false)
  end)

  T.it("derives length from content", function()
    local it = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("hello"))
    T.eq(it.length, 5)
  end)
end)

T.describe("item.is_countable / item.is_deleted", function()
  T.it("string content is countable", function()
    local it = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("x"))
    T.eq(item.is_countable(it), true)
  end)

  T.it("deleted content is not countable", function()
    local it = item.new(id.new(1, 0), nil, nil, nil, nil, content.deleted(1))
    T.eq(item.is_countable(it), false)
  end)

  T.it("format content is not countable", function()
    local it = item.new(id.new(1, 0), nil, nil, nil, nil, content.format("bold", true))
    T.eq(item.is_countable(it), false)
  end)

  T.it("a fresh item is not deleted", function()
    local it = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("x"))
    T.eq(item.is_deleted(it), false)
  end)
end)

T.describe("item.last_id", function()
  T.it("equals id when length is 1", function()
    local iid = id.new(1, 5)
    local it = item.new(iid, nil, nil, nil, nil, content.string("x"))
    local last = item.last_id(it)
    T.eq(last.client, 1)
    T.eq(last.clock, 5)
  end)

  T.it("is clock + length - 1 for multi-char items", function()
    local it = item.new(id.new(1, 5), nil, nil, nil, nil, content.string("hello"))
    local last = item.last_id(it)
    T.eq(last.client, 1)
    T.eq(last.clock, 9)
  end)
end)

T.describe("item.split", function()
  T.it("splits a string item into two adjacent items", function()
    local it = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("hello"))
    local right = item.split(it, 2)
    T.eq(it.length, 2)
    T.eq(it.content.str, "he")
    T.eq(right.length, 3)
    T.eq(right.content.str, "llo")
    T.eq(right.id.client, 1)
    T.eq(right.id.clock, 2)
    T.eq(right.origin.client, 1)
    T.eq(right.origin.clock, 1)
  end)

  T.it("wires the split halves into the existing linked list", function()
    local left = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("hello"))
    local far_right = item.new(id.new(2, 0), nil, nil, nil, nil, content.string("!"))
    left.right = far_right
    far_right.left = left

    local mid = item.split(left, 2)
    T.eq(left.right, mid)
    T.eq(mid.left, left)
    T.eq(mid.right, far_right)
    T.eq(far_right.left, mid)
  end)

  T.it("errors when splitting non-splittable content", function()
    local it = item.new(id.new(1, 0), nil, nil, nil, nil, content.format("bold", true))
    local right, err = item.split(it, 0)
    T.eq(right, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("item.merge_with", function()
  T.it("merges adjacent same-client string items with consecutive clocks", function()
    local left = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("he"))
    local right = item.new(id.new(1, 2), id.new(1, 1), nil, nil, nil, content.string("llo"))
    left.right = right
    right.left = left

    local merged = item.merge_with(left, right)
    T.eq(merged, true)
    T.eq(left.content.str, "hello")
    T.eq(left.length, 5)
    T.eq(left.right, nil)
  end)

  T.it("refuses to merge items with non-consecutive clocks", function()
    local left = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("he"))
    local right = item.new(id.new(1, 5), id.new(1, 1), nil, nil, nil, content.string("llo"))
    left.right = right
    right.left = left
    T.eq(item.merge_with(left, right), false)
  end)

  T.it("refuses to merge items from different clients", function()
    local left = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("he"))
    local right = item.new(id.new(2, 0), id.new(1, 1), nil, nil, nil, content.string("llo"))
    left.right = right
    right.left = left
    T.eq(item.merge_with(left, right), false)
  end)

  T.it("refuses to merge when deleted state differs", function()
    local left = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("he"))
    local right = item.new(id.new(1, 2), id.new(1, 1), nil, nil, nil, content.string("llo"))
    left.right = right
    right.left = left
    right.deleted = true
    T.eq(item.merge_with(left, right), false)
  end)

  T.it("propagates keep from right to left", function()
    local left = item.new(id.new(1, 0), nil, nil, nil, nil, content.string("he"))
    local right = item.new(id.new(1, 2), id.new(1, 1), nil, nil, nil, content.string("llo"))
    left.right = right
    right.left = left
    right.keep = true
    T.eq(item.merge_with(left, right), true)
    T.eq(left.keep, true)
  end)
end)

T.describe("item.delete", function()
  T.it("marks an item deleted and adjusts parent length", function()
    local parent = shared_type.new("text")
    parent.length = 5
    local it = item.new(id.new(1, 0), nil, nil, parent, nil, content.string("hello"))
    local txn = { doc = nil, new_items = {}, deleted_items = {} }
    item.delete(txn, it)
    T.eq(it.deleted, true)
    T.eq(parent.length, 0)
    T.eq(#txn.deleted_items, 1)
  end)

  T.it("is idempotent", function()
    local parent = shared_type.new("text")
    parent.length = 5
    local it = item.new(id.new(1, 0), nil, nil, parent, nil, content.string("hello"))
    local txn = { doc = nil, new_items = {}, deleted_items = {} }
    item.delete(txn, it)
    item.delete(txn, it)
    T.eq(parent.length, 0)
    T.eq(#txn.deleted_items, 1)
  end)

  T.it("does not adjust length for a Map entry (parent_sub set)", function()
    local parent = shared_type.new("map")
    parent.length = 1
    local it = item.new(id.new(1, 0), nil, nil, parent, "key", content.any({ 42 }))
    local txn = { doc = nil, new_items = {}, deleted_items = {} }
    item.delete(txn, it)
    T.eq(parent.length, 1)
  end)
end)
