-- lib/fractal/fractal_test.lua
-- Tests for lib/fractal's op/api/merge_meta (init.lua).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local fractal = require("lib.fractal")

-- Deep structural equality for plain tables (T.eq is reference/value `==`,
-- which is not useful for comparing merged meta tables).
--: (unknown, unknown) -> boolean
local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

--: (unknown, unknown, string | nil) -> nil
local function assert_deep_eq(a, b, msg)
  T.ok(deep_eq(a, b), (msg and msg .. ": " or "") .. "tables not deeply equal")
end

T.describe("lib.fractal", function()

  -- ── merge_meta ────────────────────────────────────────────────────────

  T.describe("merge_meta", function()

    T.it("no args returns empty table", function()
      assert_deep_eq(fractal.merge_meta(), {})
    end)

    T.it("nil args are skipped, don't blank out earlier bags", function()
      local out = fractal.merge_meta({ a = 1 }, nil, { b = 2 })
      assert_deep_eq(out, { a = 1, b = 2 })
    end)

    T.it("scalars: later wins", function()
      local out = fractal.merge_meta({ verb = "GET" }, { verb = "POST" })
      T.eq(out.verb, "POST")
    end)

    T.it("arrays concatenate in order", function()
      local out = fractal.merge_meta({ directives = { "a", "b" } }, { directives = { "c" } })
      assert_deep_eq(out.directives, { "a", "b", "c" })
    end)

    T.it("plain tables merge recursively", function()
      local out = fractal.merge_meta({ tags = { readOnly = true } }, { tags = { deprecated = true } })
      assert_deep_eq(out.tags, { readOnly = true, deprecated = true })
    end)

    T.it("recursive merge: later scalar wins on a shared nested key", function()
      local out = fractal.merge_meta({ http = { verb = "GET" } }, { http = { verb = "POST", path = "/x" } })
      assert_deep_eq(out.http, { verb = "POST", path = "/x" })
    end)

    T.it("type mismatch (existing array, incoming table): incoming table wins outright", function()
      local out = fractal.merge_meta({ x = { 1, 2, 3 } }, { x = { key = "val" } })
      assert_deep_eq(out.x, { key = "val" })
    end)

    T.it("type mismatch (existing table, incoming array): incoming array wins outright", function()
      local out = fractal.merge_meta({ x = { key = "val" } }, { x = { 1, 2 } })
      assert_deep_eq(out.x, { 1, 2 })
    end)

    T.it("type mismatch (existing scalar, incoming table): incoming table wins outright", function()
      local out = fractal.merge_meta({ x = "scalar" }, { x = { a = 1 } })
      assert_deep_eq(out.x, { a = 1 })
    end)

    T.it("a key absent from an earlier bag is simply added", function()
      local out = fractal.merge_meta({ a = 1 }, { b = 2 })
      assert_deep_eq(out, { a = 1, b = 2 })
    end)

    T.it("three-way fold is left to right", function()
      local out = fractal.merge_meta({ v = 1 }, { v = 2 }, { v = 3 })
      T.eq(out.v, 3)
    end)

  end)

  -- ── op ────────────────────────────────────────────────────────────────

  T.describe("op", function()

    T.it("op(fn) has empty meta and the handler set", function()
      --: (unknown) -> unknown
      local fn = function(x) return x end
      local node = fractal.op(fn)
      T.eq(node.handler, fn)
      assert_deep_eq(node.meta, {})
    end)

    T.it("op(fn, meta) uses the single bag as-is (no merge)", function()
      --: (unknown) -> unknown
      local fn = function(x) return x end
      local meta = { description = "hi" }
      local node = fractal.op(fn, meta)
      T.eq(node.meta, meta) -- same reference, not a copy
    end)

    T.it("op(fn, m1, m2) deep-merges left to right, later wins", function()
      --: (unknown) -> unknown
      local fn = function(x) return x end
      local node = fractal.op(fn, { tags = { readOnly = true } }, { tags = { deprecated = true }, description = "d" })
      assert_deep_eq(node.meta, { tags = { readOnly = true, deprecated = true }, description = "d" })
    end)

    T.it("op(fn, m1, m2, m3) folds all three left to right", function()
      --: (unknown) -> unknown
      local fn = function(x) return x end
      local node = fractal.op(fn, { v = 1 }, { v = 2 }, { v = 3, w = 1 })
      assert_deep_eq(node.meta, { v = 3, w = 1 })
    end)

  end)

  -- ── api ───────────────────────────────────────────────────────────────

  T.describe("api", function()

    T.it("api(children) has empty meta and no fallback key", function()
      local leaf = fractal.op(function(x) return x end)
      local node = fractal.api({ getBook = leaf })
      T.eq(node.children.getBook, leaf)
      assert_deep_eq(node.meta, {})
      T.eq(node.fallback, nil)
    end)

    T.it("api(children, { meta = ... }) sets meta", function()
      local node = fractal.api({}, { meta = { description = "root" } })
      assert_deep_eq(node.meta, { description = "root" })
    end)

    T.it("api(children, { fallback = ... }) sets fallback, leaves meta empty by default", function()
      local subtree = fractal.api({})
      local node = fractal.api({}, { fallback = { name = "bookId", subtree = subtree } })
      T.eq(node.fallback.name, "bookId")
      T.eq(node.fallback.subtree, subtree)
      assert_deep_eq(node.meta, {})
    end)

    T.it("api(children, { meta = ..., fallback = ... }) sets both", function()
      local subtree = fractal.api({})
      local node = fractal.api({}, { meta = { description = "x" }, fallback = { name = "id", subtree = subtree } })
      assert_deep_eq(node.meta, { description = "x" })
      T.eq(node.fallback.name, "id")
    end)

    T.it("both handler and children is valid (uncommon but valid)", function()
      --: (unknown) -> unknown
      local fn = function(x) return x end
      local leaf = fractal.op(fn)
      local node = fractal.api({ child = leaf })
      node.handler = fn -- constructing "both" directly, per Node's own shape (op/api each build one half)
      T.eq(node.handler, fn)
      T.eq(node.children.child, leaf)
    end)

  end)

end)
