-- lib/api-tree/direct_test.lua
-- Tests for lib/api-tree/direct.lua (the zero-protocol-overhead projection).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local async   = require("lib.async")
local api_tree = require("lib.api-tree")
local direct  = require("lib.api-tree.direct")

-- The slice of lib/async's promise this file reads, with the `...`
-- structural-subtyping marker its own declaration uses.
--:: PromiseView = { _state: string, is_resolved: (self: PromiseView) -> boolean, ... }

--: (v: unknown) -> v is PromiseView
local function is_promise(v)
  if type(v) ~= "table" then return false end
  return v._state ~= nil
end

--: (v: unknown) -> v is (input: unknown) -> unknown
local function is_fn(v) return type(v) == "function" end

-- Invoke a projected node, whether it is a bare function (a plain leaf) or a
-- table carrying a `handler` key (a leaf that also has children).
--: (f: unknown, input: unknown) -> unknown
local function invoke(f, input)
  if is_fn(f) then return f(input) end
  if type(f) ~= "table" then error("invoke: not callable") end
  local handler = f.handler
  if not is_fn(handler) then error("invoke: table has no handler") end
  return handler(input)
end

-- Every leaf callable returns a promise (lib/async's transparent-coroutine
-- convention). A synchronous handler settles it before the call returns, so
-- driving it to a value needs no event loop.
--: (f: unknown, input: unknown) -> (unknown, unknown)
local function call(f, input)
  local p = invoke(f, input)
  if not is_promise(p) then error("call: expected a promise") end
  return async.run(p)
end

T.describe("lib.api-tree.direct", function()

  T.describe("leaf shape", function()

    T.it("a bare leaf projects to a function", function()
      local api = direct.create_direct_api(api_tree.op(function(input) return input end))
      T.eq(type(api), "function")
    end)

    T.it("a leaf callable returns a promise", function()
      local api = direct.create_direct_api(api_tree.op(function(_) return 1 end))
      local p = invoke(api, nil)
      T.eq(is_promise(p), true)
      -- A synchronous handler settles the promise before the call returns.
      if is_promise(p) then T.eq(p:is_resolved(), true) end
    end)

    T.it("the handler's return value is the resolved value", function()
      local api = direct.create_direct_api(api_tree.op(function(input) return input.n * 2 end))
      local v, e = call(api, { n = 21 })
      T.eq(e, nil)
      T.eq(v, 42)
    end)

    T.it("a handler raising an error rejects the promise", function()
      local api = direct.create_direct_api(api_tree.op(function(_) error("boom") end))
      local v, e = call(api, nil)
      T.eq(v, nil)
      T.ok(e ~= nil, "expected a rejection reason")
    end)

    T.it("a handler returning a promise is awaited, not double-wrapped", function()
      local api = direct.create_direct_api(api_tree.op(function(_) return async.resolved("inner") end))
      local v, e = call(api, nil)
      T.eq(e, nil)
      T.eq(v, "inner")
    end)

    T.it("a leaf called with no input passes nil through", function()
      -- The handler echoes its input, so the resolved value IS what it saw.
      local api = direct.create_direct_api(api_tree.op(function(input) return input end))
      local v, e = call(api, nil)
      T.eq(e, nil)
      T.eq(v, nil)
    end)

  end)

  T.describe("branch shape", function()

    T.it("a branch projects to a table keyed by child name", function()
      local api = direct.create_direct_api(api_tree.api({
        list = api_tree.op(function(_) return "listed" end),
      }))
      T.eq(type(api), "table")
      T.eq(type(api.list), "function")
    end)

    T.it("calls a child leaf", function()
      local api = direct.create_direct_api(api_tree.api({
        list = api_tree.op(function(_) return "listed" end),
      }))
      local v = call(api.list, nil)
      T.eq(v, "listed")
    end)

    T.it("nests arbitrarily deep", function()
      local api = direct.create_direct_api(api_tree.api({
        books = api_tree.api({
          reviews = api_tree.api({
            list = api_tree.op(function(_) return "deep" end),
          }),
        }),
      }))
      T.eq(call(api.books.reviews.list, nil), "deep")
    end)

    T.it("an empty branch projects to an empty table", function()
      local api = direct.create_direct_api(api_tree.api({}))
      T.eq(type(api), "table")
      T.eq(next(api), nil)
    end)

  end)

  T.describe("leaf with children", function()

    T.it("projects to a table, not a function", function()
      local node = api_tree.api({ child = api_tree.op(function(_) return "child" end) })
      --: (input: unknown) -> unknown
      node.handler = function(_) return "self" end
      local api = direct.create_direct_api(node)
      T.eq(type(api), "table")
    end)

    T.it("is callable via its handler key", function()
      local node = api_tree.api({ child = api_tree.op(function(_) return "child" end) })
      --: (input: unknown) -> unknown
      node.handler = function(_) return "self" end
      local api = direct.create_direct_api(node)
      T.eq(call(api.handler, nil), "self")
    end)

    T.it("its children are ordinary keys on the same table", function()
      local node = api_tree.api({ child = api_tree.op(function(_) return "child" end) })
      --: (input: unknown) -> unknown
      node.handler = function(_) return "self" end
      local api = direct.create_direct_api(node)
      T.eq(call(api.child, nil), "child")
    end)

  end)

  T.describe("fallback and slug binding", function()

    T.it("a fallback projects to a function under its own name", function()
      local subtree = api_tree.api({ read = api_tree.op(function(_) return "read" end) })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(type(api.bookId), "function")
    end)

    T.it("calling the fallback yields the subtree's API", function()
      local subtree = api_tree.api({ read = api_tree.op(function(_) return "read" end) })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(call(api.bookId("123").read, nil), "read")
    end)

    T.it("the slug value is seeded into a descendant leaf's input", function()
      local subtree = api_tree.api({ read = api_tree.op(function(input) return input.bookId end) })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(call(api.bookId("123").read, nil), "123")
    end)

    T.it("a caller-supplied field wins over the seeded slug", function()
      local subtree = api_tree.api({ read = api_tree.op(function(input) return input.bookId end) })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(call(api.bookId("123").read, { bookId = "explicit" }), "explicit")
    end)

    T.it("caller fields and seeded slugs merge", function()
      local subtree = api_tree.api({
        read = api_tree.op(function(input) return input.bookId .. "/" .. input.fields end),
      })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(call(api.bookId("7").read, { fields = "title" }), "7/title")
    end)

    T.it("nested fallbacks accumulate every slug", function()
      local inner = api_tree.api({
        read = api_tree.op(function(input) return input.bookId .. ":" .. input.reviewId end),
      })
      local subtree = api_tree.api({}, { fallback = { name = "reviewId", subtree = inner } })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(call(api.bookId("b1").reviewId("r2").read, nil), "b1:r2")
    end)

    T.it("two sibling slug values do not leak into each other", function()
      local subtree = api_tree.api({ read = api_tree.op(function(input) return input.bookId end) })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      local a = api.bookId("first")
      local b = api.bookId("second")
      T.eq(call(a.read, nil), "first")
      T.eq(call(b.read, nil), "second")
    end)

    T.it("a non-table input is passed through rather than merged into", function()
      local subtree = api_tree.api({ read = api_tree.op(function(input) return input end) })
      local api = direct.create_direct_api(
        api_tree.api({}, { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(call(api.bookId("1").read, "raw"), "raw")
    end)

    T.it("a leaf under no fallback receives the caller's input unchanged", function()
      local given = { a = 1 }
      local api = direct.create_direct_api(
        api_tree.api({ read = api_tree.op(function(input) return input end) }))
      T.eq(call(api.read, given), given) -- same reference: nothing to merge
    end)

    T.it("a branch carrying both children and a fallback exposes both", function()
      local subtree = api_tree.api({ read = api_tree.op(function(_) return "sub" end) })
      local api = direct.create_direct_api(api_tree.api(
        { list = api_tree.op(function(_) return "list" end) },
        { fallback = { name = "bookId", subtree = subtree } }))
      T.eq(call(api.list, nil), "list")
      T.eq(call(api.bookId("1").read, nil), "sub")
    end)

  end)

  T.describe("the source tree is not mutated", function()

    T.it("projecting leaves the tree untouched", function()
      local leaf = api_tree.op(function(_) return 1 end)
      local tree = api_tree.api({ a = leaf })
      direct.create_direct_api(tree)
      T.eq(tree.children.a, leaf)
      T.eq(getmetatable(tree), nil)
    end)

  end)

end)
