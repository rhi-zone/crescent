-- lib/api-tree/input_test.lua
-- Tests for lib/api-tree/input.lua (assemble).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local input = require("lib.api-tree.input")

T.describe("lib.api-tree.input", function()

  T.describe("assemble", function()

    T.it("no params yields an empty bag", function()
      local out = input.assemble({ query = { q = "x" } }, {}, {}, "query")
      T.eq(next(out), nil)
    end)

    T.it("reads a param from the primary store", function()
      local out = input.assemble({ query = { q = "hello" } }, { "q" }, {}, "query")
      T.eq(out.q, "hello")
    end)

    T.it("reads several params from the primary store", function()
      local out = input.assemble({ body = { title = "t", author = "a" } }, { "title", "author" }, {}, "body")
      T.eq(out.title, "t")
      T.eq(out.author, "a")
    end)

    T.it("a param the primary store lacks is absent from the bag", function()
      local out = input.assemble({ query = {} }, { "q" }, {}, "query")
      T.eq(out.q, nil)
    end)

    T.it("a missing store resolves to nothing rather than erroring", function()
      local out = input.assemble({}, { "q" }, {}, "query")
      T.eq(out.q, nil)
    end)

    -- ── step 1: path params win ─────────────────────────────────────────

    T.it("a path param name reads from the path store", function()
      local stores = { path = { bookId = "123" }, query = { bookId = "wrong" } }
      local out = input.assemble(stores, { "bookId" }, {}, "query", { "bookId" })
      T.eq(out.bookId, "123")
    end)

    T.it("a path param beats an explicit source override", function()
      local stores = { path = { id = "from-path" }, header = { id = "from-header" } }
      local source_map = { id = { store = "header" } }
      local out = input.assemble(stores, { "id" }, source_map, "query", { "id" })
      T.eq(out.id, "from-path")
    end)

    T.it("path params and primary-store params coexist", function()
      local stores = { path = { bookId = "123" }, query = { fields = "title" } }
      local out = input.assemble(stores, { "bookId", "fields" }, {}, "query", { "bookId" })
      T.eq(out.bookId, "123")
      T.eq(out.fields, "title")
    end)

    -- ── step 2: source overrides ────────────────────────────────────────

    T.it("an override redirects a param to another store", function()
      local stores = { query = { token = "q-token" }, header = { token = "h-token" } }
      local out = input.assemble(stores, { "token" }, { token = { store = "header" } }, "query")
      T.eq(out.token, "h-token")
    end)

    T.it("an override's key renames the lookup within the store", function()
      local stores = { header = { ["x-request-id"] = "abc" } }
      local source_map = { requestId = { store = "header", key = "x-request-id" } }
      local out = input.assemble(stores, { "requestId" }, source_map, "query")
      T.eq(out.requestId, "abc")
    end)

    T.it("an override with no key defaults to the param name", function()
      local stores = { header = { token = "abc" } }
      local out = input.assemble(stores, { "token" }, { token = { store = "header" } }, "query")
      T.eq(out.token, "abc")
    end)

    T.it("an override naming a store that isn't present resolves to nothing", function()
      local out = input.assemble({ query = { t = "x" } }, { "t" }, { t = { store = "cookie" } }, "query")
      T.eq(out.t, nil)
    end)

    T.it("only overridden params diverge; the rest follow the convention", function()
      local stores = { query = { a = "qa", b = "qb" }, header = { a = "ha" } }
      local out = input.assemble(stores, { "a", "b" }, { a = { store = "header" } }, "query")
      T.eq(out.a, "ha")
      T.eq(out.b, "qb")
    end)

    -- ── step 3: the primary-store convention ────────────────────────────

    T.it("an empty primary store skips step 3 entirely", function()
      local stores = { query = { q = "x" } }
      local out = input.assemble(stores, { "q" }, {}, "")
      T.eq(out.q, nil)
    end)

    T.it("an empty primary store still honors path params", function()
      local stores = { path = { id = "9" }, query = { q = "x" } }
      local out = input.assemble(stores, { "id", "q" }, {}, "", { "id" })
      T.eq(out.id, "9")
      T.eq(out.q, nil)
    end)

    T.it("an empty primary store still honors overrides", function()
      local stores = { header = { t = "h" } }
      local out = input.assemble(stores, { "t" }, { t = { store = "header" } }, "")
      T.eq(out.t, "h")
    end)

    -- ── general ─────────────────────────────────────────────────────────

    T.it("path_param_names is optional", function()
      local out = input.assemble({ query = { q = "x" } }, { "q" }, {}, "query")
      T.eq(out.q, "x")
    end)

    T.it("non-string values pass through unchanged", function()
      local nested = { a = 1 }
      local stores = { body = { count = 42, flag = false, nested = nested } }
      local out = input.assemble(stores, { "count", "flag", "nested" }, {}, "body")
      T.eq(out.count, 42)
      T.eq(out.flag, false)
      T.eq(out.nested, nested)
    end)

    T.it("the caller store is readable like any other", function()
      local stores = { caller = { userId = "u1" } }
      local out = input.assemble(stores, { "userId" }, { userId = { store = "caller" } }, "")
      T.eq(out.userId, "u1")
    end)

    T.it("stores are not mutated", function()
      local query = { q = "x" }
      input.assemble({ query = query }, { "q" }, {}, "query")
      T.eq(query.q, "x")
      local keys = 0
      for _ in pairs(query) do keys = keys + 1 end
      T.eq(keys, 1)
    end)

  end)

end)
