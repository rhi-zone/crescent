-- lib/api-tree/page_test.lua
-- Tests for lib/api-tree/page.lua (the runtime pagination-shape sniff).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local page = require("lib.api-tree.page")

T.describe("lib.api-tree.page", function()

  T.describe("is_cursor_page", function()

    T.it("accepts a cursor page with a cursor", function()
      T.eq(page.is_cursor_page({ items = { 1, 2 }, cursor = "abc", hasMore = true }), true)
    end)

    T.it("accepts a last page with no cursor", function()
      T.eq(page.is_cursor_page({ items = { 1 }, hasMore = false }), true)
    end)

    T.it("accepts an empty page — the common last-page case", function()
      T.eq(page.is_cursor_page({ items = {}, hasMore = false }), true)
    end)

    T.it("rejects an offset page", function()
      T.eq(page.is_cursor_page({ items = {}, offset = 0, total = 0, hasMore = false }), false)
    end)

    T.it("rejects a table with no hasMore", function()
      T.eq(page.is_cursor_page({ items = { 1 }, cursor = "x" }), false)
    end)

    T.it("rejects a non-boolean hasMore", function()
      T.eq(page.is_cursor_page({ items = { 1 }, hasMore = "yes" }), false)
    end)

    T.it("rejects a table whose items is a map, not a list", function()
      T.eq(page.is_cursor_page({ items = { a = 1 }, hasMore = false }), false)
    end)

    T.it("rejects a table with no items", function()
      T.eq(page.is_cursor_page({ hasMore = false }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(page.is_cursor_page(nil), false)
      T.eq(page.is_cursor_page("page"), false)
      T.eq(page.is_cursor_page(3), false)
    end)

  end)

  T.describe("is_offset_page", function()

    T.it("accepts an offset page", function()
      T.eq(page.is_offset_page({ items = { 1, 2 }, offset = 0, total = 7, hasMore = true }), true)
    end)

    T.it("accepts an empty offset page", function()
      T.eq(page.is_offset_page({ items = {}, offset = 0, total = 0, hasMore = false }), true)
    end)

    T.it("rejects a cursor page", function()
      T.eq(page.is_offset_page({ items = { 1 }, cursor = "x", hasMore = true }), false)
    end)

    T.it("rejects a missing total", function()
      T.eq(page.is_offset_page({ items = { 1 }, offset = 0, hasMore = false }), false)
    end)

    T.it("rejects a non-numeric offset", function()
      T.eq(page.is_offset_page({ items = { 1 }, offset = "0", total = 1, hasMore = false }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(page.is_offset_page(nil), false)
      T.eq(page.is_offset_page(false), false)
    end)

  end)

  T.describe("the two styles are mutually exclusive", function()

    T.it("an offset page is not a cursor page", function()
      local p = { items = {}, offset = 0, total = 0, hasMore = false }
      T.eq(page.is_offset_page(p), true)
      T.eq(page.is_cursor_page(p), false)
    end)

    T.it("a cursor page is not an offset page", function()
      local p = { items = {}, cursor = "c", hasMore = true }
      T.eq(page.is_cursor_page(p), true)
      T.eq(page.is_offset_page(p), false)
    end)

  end)

  T.describe("is_page_shape", function()

    T.it("accepts a cursor page", function()
      T.eq(page.is_page_shape({ items = {}, hasMore = false }), true)
    end)

    T.it("accepts an offset page", function()
      T.eq(page.is_page_shape({ items = {}, offset = 0, total = 0, hasMore = false }), true)
    end)

    T.it("rejects an ordinary handler return value", function()
      T.eq(page.is_page_shape({ id = "b1", title = "Dune" }), false)
    end)

    T.it("rejects a bare list", function()
      T.eq(page.is_page_shape({ 1, 2, 3 }), false)
    end)

    T.it("rejects a Result", function()
      T.eq(page.is_page_shape({ kind = "ok", value = 1 }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(page.is_page_shape(nil), false)
      T.eq(page.is_page_shape("x"), false)
    end)

  end)

  T.describe("wire field names", function()

    T.it("hasMore is camelCase — snake_case is not recognized", function()
      T.eq(page.is_page_shape({ items = {}, has_more = false }), false)
      T.eq(page.is_page_shape({ items = {}, hasMore = false }), true)
    end)

  end)

end)
