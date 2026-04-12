-- lib/pagination/pagination_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local P = require("lib.pagination")

-- Helper: build a list of n numbers
local function range(n)
  local t = {}
  for i = 1, n do t[i] = i end
  return t
end

-- ---------------------------------------------------------------------------
-- encode_cursor / decode_cursor
-- ---------------------------------------------------------------------------
T.describe("encode_cursor / decode_cursor", function()
  T.it("round-trips a simple string", function()
    local enc = P.encode_cursor("hello")
    T.ok(type(enc) == "string", "encoded is string")
    local dec = P.decode_cursor(enc)
    T.eq(dec, "hello")
  end)

  T.it("round-trips empty string", function()
    local enc = P.encode_cursor("")
    T.eq(type(enc), "string")
    local dec = P.decode_cursor(enc)
    T.eq(dec, "")
  end)

  T.it("round-trips numeric string", function()
    local enc = P.encode_cursor("42")
    local dec = P.decode_cursor(enc)
    T.eq(dec, "42")
  end)

  T.it("round-trips a longer string", function()
    local s = "the quick brown fox"
    local enc = P.encode_cursor(s)
    local dec = P.decode_cursor(enc)
    T.eq(dec, s)
  end)

  T.it("returns nil for invalid base64", function()
    local dec = P.decode_cursor("!!!invalid!!!")
    T.ok(dec == nil, "invalid cursor returns nil")
  end)

  T.it("returns nil for non-string input to encode_cursor", function()
    local enc, err = P.encode_cursor(42)
    T.ok(enc == nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil for non-string input to decode_cursor", function()
    local dec, err = P.decode_cursor(42)
    T.ok(dec == nil)
    T.ok(type(err) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- M.window
-- ---------------------------------------------------------------------------
T.describe("window", function()
  T.it("returns correct slice", function()
    local items = range(10)
    local w = P.window(items, 0, 3)
    T.eq(#w, 3)
    T.eq(w[1], 1)
    T.eq(w[3], 3)
  end)

  T.it("offset into middle", function()
    local items = range(10)
    local w = P.window(items, 5, 3)
    T.eq(#w, 3)
    T.eq(w[1], 6)
    T.eq(w[3], 8)
  end)

  T.it("limit beyond end returns remaining items", function()
    local items = range(5)
    local w = P.window(items, 3, 10)
    T.eq(#w, 2)
    T.eq(w[1], 4)
    T.eq(w[2], 5)
  end)

  T.it("offset beyond end returns empty", function()
    local items = range(5)
    local w = P.window(items, 10, 3)
    T.eq(#w, 0)
  end)

  T.it("empty list returns empty", function()
    local w = P.window({}, 0, 5)
    T.eq(#w, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.offset
-- ---------------------------------------------------------------------------
T.describe("offset pagination", function()
  T.it("basic first page", function()
    local items = range(25)
    local r = P.offset(items, { offset = 0, limit = 10 })
    T.eq(#r.items, 10)
    T.eq(r.items[1], 1)
    T.eq(r.total, 25)
    T.eq(r.page, 1)
    T.eq(r.pages, 3)
    T.ok(not r.has_prev)
    T.ok(r.has_next)
    T.eq(r.prev_offset, 0)
    T.eq(r.next_offset, 10)
  end)

  T.it("middle page", function()
    local items = range(25)
    local r = P.offset(items, { offset = 10, limit = 10 })
    T.eq(#r.items, 10)
    T.eq(r.items[1], 11)
    T.eq(r.page, 2)
    T.ok(r.has_prev)
    T.ok(r.has_next)
    T.eq(r.prev_offset, 0)
    T.eq(r.next_offset, 20)
  end)

  T.it("last page (partial)", function()
    local items = range(25)
    local r = P.offset(items, { offset = 20, limit = 10 })
    T.eq(#r.items, 5)
    T.eq(r.items[1], 21)
    T.eq(r.page, 3)
    T.ok(r.has_prev)
    T.ok(not r.has_next)
  end)

  T.it("offset beyond end returns empty items", function()
    local items = range(5)
    local r = P.offset(items, { offset = 100, limit = 10 })
    T.eq(#r.items, 0)
    T.ok(not r.has_next)
  end)

  T.it("empty list", function()
    local r = P.offset({}, { offset = 0, limit = 10 })
    T.eq(#r.items, 0)
    T.eq(r.total, 0)
    T.eq(r.pages, 1)
    T.ok(not r.has_prev)
    T.ok(not r.has_next)
  end)

  T.it("exact page boundary", function()
    -- 20 items, limit 10: page 2 is exactly full and is the last page
    local items = range(20)
    local r = P.offset(items, { offset = 10, limit = 10 })
    T.eq(#r.items, 10)
    T.eq(r.page, 2)
    T.eq(r.pages, 2)
    T.ok(not r.has_next)
  end)

  T.it("error on limit < 1", function()
    local r, err = P.offset(range(5), { limit = 0 })
    T.ok(r == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error on negative offset", function()
    local r, err = P.offset(range(5), { offset = -1 })
    T.ok(r == nil)
    T.ok(type(err) == "string")
  end)

  T.it("default opts", function()
    local items = range(5)
    local r = P.offset(items)
    T.eq(r.total, 5)
    T.eq(#r.items, 5)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.pages
-- ---------------------------------------------------------------------------
T.describe("page pagination", function()
  T.it("basic first page", function()
    local items = range(25)
    local r = P.pages(items, { page = 1, per_page = 10 })
    T.eq(#r.items, 10)
    T.eq(r.items[1], 1)
    T.eq(r.total, 25)
    T.eq(r.page, 1)
    T.eq(r.pages, 3)
    T.eq(r.per_page, 10)
    T.ok(not r.has_prev)
    T.ok(r.has_next)
  end)

  T.it("last page partial", function()
    local items = range(25)
    local r = P.pages(items, { page = 3, per_page = 10 })
    T.eq(#r.items, 5)
    T.eq(r.items[1], 21)
    T.ok(r.has_prev)
    T.ok(not r.has_next)
  end)

  T.it("single page fits all", function()
    local items = range(5)
    local r = P.pages(items, { page = 1, per_page = 10 })
    T.eq(#r.items, 5)
    T.eq(r.pages, 1)
    T.ok(not r.has_prev)
    T.ok(not r.has_next)
  end)

  T.it("page out of range is clamped to last page", function()
    local items = range(10)
    local r = P.pages(items, { page = 99, per_page = 10 })
    T.eq(r.page, 1)
    T.eq(#r.items, 10)
  end)

  T.it("empty list", function()
    local r = P.pages({}, { page = 1, per_page = 10 })
    T.eq(#r.items, 0)
    T.eq(r.total, 0)
    T.eq(r.pages, 1)
  end)

  T.it("error on page < 1", function()
    local r, err = P.pages(range(5), { page = 0 })
    T.ok(r == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error on per_page < 1", function()
    local r, err = P.pages(range(5), { per_page = 0 })
    T.ok(r == nil)
    T.ok(type(err) == "string")
  end)

  T.it("default opts", function()
    local items = range(5)
    local r = P.pages(items)
    T.eq(r.total, 5)
    T.eq(#r.items, 5)
    T.eq(r.page, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.cursor
-- ---------------------------------------------------------------------------
T.describe("cursor pagination", function()
  T.it("first page (no cursor)", function()
    local items = range(25)
    local r = P.cursor(items, { limit = 10 })
    T.eq(#r.items, 10)
    T.eq(r.items[1], 1)
    T.ok(r.has_more)
    T.ok(r.cursor ~= nil)
  end)

  T.it("second page via cursor", function()
    local items = range(25)
    local r1 = P.cursor(items, { limit = 10 })
    local r2 = P.cursor(items, { cursor = r1.cursor, limit = 10 })
    T.eq(#r2.items, 10)
    T.eq(r2.items[1], 11)
    T.ok(r2.has_more)
  end)

  T.it("last page has no cursor", function()
    local items = range(25)
    local r1 = P.cursor(items, { limit = 10 })
    local r2 = P.cursor(items, { cursor = r1.cursor, limit = 10 })
    local r3 = P.cursor(items, { cursor = r2.cursor, limit = 10 })
    T.eq(#r3.items, 5)
    T.ok(not r3.has_more)
    T.ok(r3.cursor == nil)
  end)

  T.it("cursor past end returns empty", function()
    local items = range(5)
    local r1 = P.cursor(items, { limit = 5 })
    -- r1 has no cursor (last page), simulate by manually encoding beyond end
    local cur = P.encode_cursor("100")
    local r2 = P.cursor(items, { cursor = cur, limit = 5 })
    T.eq(#r2.items, 0)
    T.ok(not r2.has_more)
  end)

  T.it("empty list returns empty result", function()
    local r = P.cursor({}, { limit = 10 })
    T.eq(#r.items, 0)
    T.ok(not r.has_more)
    T.ok(r.cursor == nil)
  end)

  T.it("error on limit < 1", function()
    local r, err = P.cursor(range(5), { limit = 0 })
    T.ok(r == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error on invalid cursor", function()
    local r, err = P.cursor(range(5), { cursor = "!!!bad!!!" })
    T.ok(r == nil)
    T.ok(type(err) == "string")
  end)

  T.it("key function: cursor by item key", function()
    local items = {}
    for i = 1, 15 do items[i] = { id = i * 10, name = "item" .. i } end
    local key_fn = function(item) return item.id end
    local r1 = P.cursor(items, { limit = 5, key = key_fn })
    T.eq(#r1.items, 5)
    T.eq(r1.items[1].id, 10)
    T.ok(r1.has_more)
    local r2 = P.cursor(items, { cursor = r1.cursor, limit = 5, key = key_fn })
    T.eq(#r2.items, 5)
    T.eq(r2.items[1].id, 60)
    T.ok(r2.has_more)
    local r3 = P.cursor(items, { cursor = r2.cursor, limit = 5, key = key_fn })
    T.eq(#r3.items, 5)
    T.eq(r3.items[1].id, 110)
    T.ok(not r3.has_more)
  end)

  T.it("default opts", function()
    local items = range(5)
    local r = P.cursor(items)
    T.eq(r.total_fetched or #r.items, 5)
    T.ok(not r.has_more)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.paginator (stateful)
-- ---------------------------------------------------------------------------
T.describe("paginator", function()
  T.it("basic navigation", function()
    local pg = P.paginator(range(25), { per_page = 10 })
    T.eq(pg.total_items, 25)
    T.eq(pg.total_pages, 3)
    T.eq(pg.current_page, 1)
  end)

  T.it(":page(n) returns correct page", function()
    local pg = P.paginator(range(25), { per_page = 10 })
    local r = pg:page(2)
    T.eq(r.page, 2)
    T.eq(#r.items, 10)
    T.eq(r.items[1], 11)
    T.ok(r.has_prev)
    T.ok(r.has_next)
    T.eq(pg.current_page, 2)
  end)

  T.it(":next() advances page", function()
    local pg = P.paginator(range(25), { per_page = 10 })
    local r1 = pg:page(1)
    T.eq(r1.page, 1)
    local r2 = pg:next()
    T.eq(r2.page, 2)
    local r3 = pg:next()
    T.eq(r3.page, 3)
    local r4 = pg:next()
    T.ok(r4 == nil, "next() on last page returns nil")
  end)

  T.it(":prev() goes back", function()
    local pg = P.paginator(range(25), { per_page = 10 })
    pg:page(3)
    local r = pg:prev()
    T.eq(r.page, 2)
    local r2 = pg:prev()
    T.eq(r2.page, 1)
    local r3 = pg:prev()
    T.ok(r3 == nil, "prev() on first page returns nil")
  end)

  T.it(":first() goes to page 1", function()
    local pg = P.paginator(range(25), { per_page = 10 })
    pg:page(3)
    local r = pg:first()
    T.eq(r.page, 1)
    T.eq(pg.current_page, 1)
  end)

  T.it(":last() goes to last page", function()
    local pg = P.paginator(range(25), { per_page = 10 })
    local r = pg:last()
    T.eq(r.page, 3)
    T.eq(#r.items, 5)
    T.eq(pg.current_page, 3)
  end)

  T.it("single page list", function()
    local pg = P.paginator(range(5), { per_page = 10 })
    T.eq(pg.total_pages, 1)
    local r = pg:first()
    T.eq(#r.items, 5)
    T.ok(not r.has_prev)
    T.ok(not r.has_next)
  end)

  T.it("empty list", function()
    local pg = P.paginator({}, { per_page = 10 })
    T.eq(pg.total_items, 0)
    T.eq(pg.total_pages, 1)
    local r = pg:first()
    T.eq(#r.items, 0)
  end)

  T.it("error on per_page < 1", function()
    local pg, err = P.paginator(range(5), { per_page = 0 })
    T.ok(pg == nil)
    T.ok(type(err) == "string")
  end)

  T.it(":page() clamps out-of-range page", function()
    local pg = P.paginator(range(10), { per_page = 5 })
    local r = pg:page(99)
    T.eq(r.page, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- M.lazy_paginator
-- ---------------------------------------------------------------------------
T.describe("lazy_paginator", function()
  local function make_lazy(n, per_page)
    local data = range(n)
    local function fetch_fn(offset, limit)
      return P.window(data, offset, limit)
    end
    local function count_fn()
      return n
    end
    return P.lazy_paginator(fetch_fn, count_fn, { per_page = per_page or 10 })
  end

  T.it("basic first page", function()
    local pg = make_lazy(25, 10)
    T.eq(pg.total_items, 25)
    T.eq(pg.total_pages, 3)
    local r = pg:page(1)
    T.eq(#r.items, 10)
    T.eq(r.items[1], 1)
    T.ok(r.has_next)
    T.ok(not r.has_prev)
  end)

  T.it(":next() and :prev()", function()
    local pg = make_lazy(25, 10)
    pg:page(1)
    local r2 = pg:next()
    T.eq(r2.page, 2)
    T.eq(r2.items[1], 11)
    local r1 = pg:prev()
    T.eq(r1.page, 1)
    local nil_prev = pg:prev()
    T.ok(nil_prev == nil)
  end)

  T.it(":first() and :last()", function()
    local pg = make_lazy(25, 10)
    pg:page(2)
    local r = pg:first()
    T.eq(r.page, 1)
    local rl = pg:last()
    T.eq(rl.page, 3)
    T.eq(#rl.items, 5)
  end)

  T.it("error on non-function fetch_fn", function()
    local pg, err = P.lazy_paginator("not a fn", function() return 0 end)
    T.ok(pg == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error on non-function count_fn", function()
    local pg, err = P.lazy_paginator(function() return {} end, "not a fn")
    T.ok(pg == nil)
    T.ok(type(err) == "string")
  end)

  T.it("error on per_page < 1", function()
    local pg, err = P.lazy_paginator(
      function() return {} end,
      function() return 0 end,
      { per_page = 0 }
    )
    T.ok(pg == nil)
    T.ok(type(err) == "string")
  end)
end)
