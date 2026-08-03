-- lib/fractal/tags_test.lua
-- Tests for lib/fractal/tags.lua (resolve_tags, map_nodes).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local tags    = require("lib.fractal.tags")
local fractal = require("lib.fractal")

T.describe("lib.fractal.tags", function()

  -- ── resolve_tags ──────────────────────────────────────────────────────

  T.describe("resolve_tags", function()

    T.it("empty bag leaves every tag unknown", function()
      local r = tags.resolve_tags({})
      T.eq(r.readOnly, nil)
      T.eq(r.idempotent, nil)
      T.eq(r.destructive, nil)
      T.eq(r.openWorld, nil)
      T.eq(r.streaming, nil)
      T.eq(r.deprecated, nil)
      T.eq(r.conflict, nil)
    end)

    T.it("readOnly implies idempotent when idempotent is unknown", function()
      local r = tags.resolve_tags({ readOnly = true })
      T.eq(r.readOnly, true)
      T.eq(r.idempotent, true)
    end)

    T.it("an explicit idempotent=false survives readOnly's implication", function()
      local r = tags.resolve_tags({ readOnly = true, idempotent = false })
      T.eq(r.idempotent, false)
    end)

    T.it("readOnly=false implies nothing about idempotent", function()
      local r = tags.resolve_tags({ readOnly = false })
      T.eq(r.readOnly, false)
      T.eq(r.idempotent, nil)
    end)

    T.it("readOnly and destructive both true is a conflict", function()
      local r = tags.resolve_tags({ readOnly = true, destructive = true })
      T.ok(r.conflict ~= nil, "expected a conflict message")
      T.ok(r.conflict:find("mutually exclusive", 1, true) ~= nil, "conflict names the contradiction")
    end)

    T.it("destructive alone is not a conflict", function()
      local r = tags.resolve_tags({ destructive = true })
      T.eq(r.destructive, true)
      T.eq(r.conflict, nil)
    end)

    T.it("destructive with idempotent is valid (the DELETE case)", function()
      local r = tags.resolve_tags({ destructive = true, idempotent = true })
      T.eq(r.destructive, true)
      T.eq(r.idempotent, true)
      T.eq(r.conflict, nil)
    end)

    T.it("readOnly=true with destructive=false is not a conflict", function()
      local r = tags.resolve_tags({ readOnly = true, destructive = false })
      T.eq(r.conflict, nil)
      T.eq(r.idempotent, true)
    end)

    T.it("a stream output type derives streaming when streaming is unknown", function()
      local r = tags.resolve_tags({}, { shape = { kind = "stream" } })
      T.eq(r.streaming, true)
    end)

    T.it("a non-stream output type derives nothing", function()
      local r = tags.resolve_tags({}, { shape = { kind = "object" } })
      T.eq(r.streaming, nil)
    end)

    T.it("an explicit streaming=false beats the stream output type", function()
      local r = tags.resolve_tags({ streaming = false }, { shape = { kind = "stream" } })
      T.eq(r.streaming, false)
    end)

    T.it("an explicit streaming=true passes through with no output type", function()
      local r = tags.resolve_tags({ streaming = true })
      T.eq(r.streaming, true)
    end)

    T.it("openWorld and deprecated pass through untouched", function()
      local r = tags.resolve_tags({ openWorld = true, deprecated = false })
      T.eq(r.openWorld, true)
      T.eq(r.deprecated, false)
    end)

    T.it("custom tag keys are ignored by the lattice", function()
      local r = tags.resolve_tags({ myCustomTag = true, readOnly = true })
      T.eq(r.myCustomTag, nil)
      T.eq(r.readOnly, true)
    end)

    T.it("unvalidated is outside the lattice entirely", function()
      local r = tags.resolve_tags({ unvalidated = true })
      T.eq(r.unvalidated, nil)
      T.eq(r.conflict, nil)
    end)

    T.it("the tag-name constants match the bag keys", function()
      T.eq(tags.TAG_READ_ONLY, "readOnly")
      T.eq(tags.TAG_IDEMPOTENT, "idempotent")
      T.eq(tags.TAG_DESTRUCTIVE, "destructive")
      T.eq(tags.TAG_OPEN_WORLD, "openWorld")
      T.eq(tags.TAG_STREAMING, "streaming")
      T.eq(tags.TAG_DEPRECATED, "deprecated")
      T.eq(tags.TAG_UNVALIDATED, "unvalidated")
    end)

    T.it("the input bag is not mutated", function()
      local bag = { readOnly = true } --[[: { [string]: boolean }]]
      tags.resolve_tags(bag)
      local keys = 0
      for _ in pairs(bag) do keys = keys + 1 end
      T.eq(keys, 1) -- no derived `idempotent` written back into the caller's bag
      T.eq(bag.readOnly, true)
    end)

  end)

  -- ── map_nodes ─────────────────────────────────────────────────────────

  T.describe("map_nodes", function()

    --: (unknown) -> unknown
    local function id(x) return x end

    T.it("applies fn to a lone leaf", function()
      local leaf = fractal.op(id, { description = "d" })
      local out = tags.map_nodes(leaf, function(n)
        return { handler = n.handler, meta = { description = "mapped" } }
      end)
      T.eq(out.meta.description, "mapped")
    end)

    T.it("visits every child", function()
      local tree = fractal.api({
        a = fractal.op(id),
        b = fractal.op(id),
      })
      local seen = 0
      tags.map_nodes(tree, function(n) seen = seen + 1; return n end)
      T.eq(seen, 3) -- root + two children
    end)

    T.it("recurses into nested children", function()
      local tree = fractal.api({
        outer = fractal.api({ inner = fractal.op(id) }),
      })
      local seen = 0
      tags.map_nodes(tree, function(n) seen = seen + 1; return n end)
      T.eq(seen, 3) -- root + outer + inner
    end)

    T.it("visits the fallback subtree", function()
      local subtree = fractal.api({ read = fractal.op(id) })
      local tree = fractal.api({}, { fallback = { name = "bookId", subtree = subtree } })
      local seen = 0
      tags.map_nodes(tree, function(n) seen = seen + 1; return n end)
      T.eq(seen, 3) -- root + subtree + subtree's child
    end)

    T.it("preserves the fallback name", function()
      local subtree = fractal.api({})
      local tree = fractal.api({}, { fallback = { name = "bookId", subtree = subtree } })
      local out = tags.map_nodes(tree, id)
      T.eq(out.fallback.name, "bookId")
    end)

    T.it("is pre-order: fn sees a node before its children are walked", function()
      local order = {}
      local n = 0
      local tree = fractal.api({ child = fractal.op(id, { name = "child" }) }, { meta = { name = "root" } })
      tags.map_nodes(tree, function(node)
        n = n + 1
        order[n] = node.meta.name
        return node
      end)
      T.eq(order[1], "root")
      T.eq(order[2], "child")
    end)

    T.it("a fn rewriting a node's children is honored before the walk descends", function()
      local tree = fractal.api({ a = fractal.op(id, { tag = "a" }) })
      local out = tags.map_nodes(tree, function(node)
        if node.children ~= nil and node.children.a ~= nil then
          return fractal.api({ a = node.children.a, b = fractal.op(id, { tag = "b" }) }, { meta = node.meta })
        end
        return node
      end)
      T.eq(out.children.a.meta.tag, "a")
      T.eq(out.children.b.meta.tag, "b")
    end)

    T.it("does not mutate the input tree", function()
      local leaf = fractal.op(id, { v = 1 })
      local tree = fractal.api({ a = leaf })
      tags.map_nodes(tree, function(node)
        return { handler = node.handler, children = node.children, meta = { v = 2 } }
      end)
      T.eq(leaf.meta.v, 1)
      T.eq(tree.children.a, leaf)
    end)

    T.it("returns a new node table, not the input one", function()
      local tree = fractal.api({})
      local out = tags.map_nodes(tree, id)
      T.ok(out ~= tree, "map_nodes copies rather than returning the input node")
    end)

    T.it("carries non-structural keys through the copy", function()
      local tree = fractal.api({ a = fractal.op(id) }, { meta = { description = "root" } })
      local out = tags.map_nodes(tree, id)
      T.eq(out.meta.description, "root")
    end)

    T.it("pushing a tag down to descendants composes as an explicit transform", function()
      -- The inheritance case the removed closest-wins walk used to cover:
      -- a caller writes it as its own transform over map_nodes.
      local tree = fractal.api({ a = fractal.op(id, { tags = { readOnly = true } }) })
      local out = tags.map_nodes(tree, function(node)
        local meta = fractal.merge_meta({ tags = { deprecated = true } }, node.meta)
        return { handler = node.handler, children = node.children, fallback = node.fallback, meta = meta }
      end)
      T.eq(out.meta.tags.deprecated, true)
      T.eq(out.children.a.meta.tags.deprecated, true)
      T.eq(out.children.a.meta.tags.readOnly, true)
    end)

  end)

end)
