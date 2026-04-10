-- lib/unified/unist_util_visit/unist_util_visit_test.lua
-- Tests for unist-util-visit: depth-first tree visitor.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local visit = require("lib.unified.unist_util_visit")

-- ── Fixture trees ─────────────────────────────────────────────────────────────

-- A small mdast-style tree:
--   root
--     paragraph
--       text "Hello "
--       strong
--         text "world"
--       text "!"
--     paragraph
--       text "Bye"
local function make_mdast()
  return {
    type = "root",
    children = {
      {
        type = "paragraph",
        children = {
          { type = "text", value = "Hello " },
          {
            type = "strong",
            children = {
              { type = "text", value = "world" },
            },
          },
          { type = "text", value = "!" },
        },
      },
      {
        type = "paragraph",
        children = {
          { type = "text", value = "Bye" },
        },
      },
    },
  }
end

-- A small hast-style tree:
--   root
--     element p  []
--       text "hello"
--     element a  [href="#"]
--       text "link"
local function make_hast()
  return {
    type = "root",
    children = {
      {
        type = "element", tag = "p", props = {},
        children = {
          { type = "text", value = "hello" },
        },
      },
      {
        type = "element", tag = "a", props = { href = "#" },
        children = {
          { type = "text", value = "link" },
        },
      },
    },
  }
end

-- A small nlcst-style tree:
--   RootNode
--     ParagraphNode
--       SentenceNode
--         WordNode
--           TextNode "Hi"
--         WhiteSpaceNode
--           TextNode " "
--         WordNode
--           TextNode "there"
local function make_nlcst()
  return {
    type = "RootNode",
    children = {
      {
        type = "ParagraphNode",
        children = {
          {
            type = "SentenceNode",
            children = {
              { type = "WordNode",       children = { { type = "TextNode", value = "Hi"    } } },
              { type = "WhiteSpaceNode", children = { { type = "TextNode", value = " "     } } },
              { type = "WordNode",       children = { { type = "TextNode", value = "there" } } },
            },
          },
        },
      },
    },
  }
end

-- ── Basic type filter ─────────────────────────────────────────────────────────

T.describe("visit by type", function()
  T.it("collects all text nodes", function()
    local tree = make_mdast()
    local values = {}
    visit(tree, "text", function(node)
      values[#values + 1] = node.value
    end)
    T.eq(#values, 4)
    T.eq(values[1], "Hello ")
    T.eq(values[2], "world")
    T.eq(values[3], "!")
    T.eq(values[4], "Bye")
  end)

  T.it("visits multiple types (array)", function()
    local tree = make_mdast()
    local types = {}
    visit(tree, { "paragraph", "strong" }, function(node)
      types[#types + 1] = node.type
    end)
    -- depth-first: paragraph -> strong -> paragraph
    T.eq(#types, 3)
    T.eq(types[1], "paragraph")
    T.eq(types[2], "strong")
    T.eq(types[3], "paragraph")
  end)

  T.it("visits all nodes when no type given", function()
    local tree = make_mdast()
    local count = 0
    visit(tree, function() count = count + 1 end)
    -- root + 2 paragraphs + strong + 4 text nodes = 8
    T.eq(count, 8)
  end)
end)

-- ── SKIP signal ───────────────────────────────────────────────────────────────

T.describe("SKIP signal", function()
  T.it("SKIP prevents visiting children of a node", function()
    local tree = make_mdast()
    local values = {}
    -- Visit all nodes; SKIP when we hit a strong node.
    visit(tree, function(node)
      if node.type == "strong" then
        return visit.SKIP
      end
      if node.type == "text" then
        values[#values + 1] = node.value
      end
    end)
    -- "world" is inside strong, so it should be skipped.
    T.eq(#values, 3)
    T.eq(values[1], "Hello ")
    T.eq(values[2], "!")
    T.eq(values[3], "Bye")
  end)
end)

-- ── EXIT signal ───────────────────────────────────────────────────────────────

T.describe("EXIT signal", function()
  T.it("EXIT stops the entire traversal", function()
    local tree = make_mdast()
    local count = 0
    visit(tree, "text", function(node)
      count = count + 1
      if node.value == "world" then
        return visit.EXIT
      end
    end)
    -- "Hello " (1), "world" (2) — exit fires immediately after "world"
    T.eq(count, 2)
  end)
end)

-- ── REMOVE signal ─────────────────────────────────────────────────────────────

T.describe("REMOVE signal", function()
  T.it("REMOVE removes the node and does not skip its former sibling", function()
    local tree = make_mdast()
    -- Remove the strong node from the first paragraph.
    -- Before: [text "Hello ", strong, text "!"]
    -- After:  [text "Hello ", text "!"]
    local removed = false
    visit(tree, "strong", function()
      removed = true
      return visit.REMOVE
    end)
    T.ok(removed, "visitor was called")
    local para = tree.children[1]
    T.eq(#para.children, 2)
    T.eq(para.children[1].value, "Hello ")
    T.eq(para.children[2].value, "!")
  end)

  T.it("sibling after removed node is still visited", function()
    local tree = make_mdast()
    -- Remove "Hello " (first text of first paragraph).
    -- Then "!" (which shifts to index 2) should still be visited.
    local seen = {}
    visit(tree, "text", function(node)
      if node.value == "Hello " then
        return visit.REMOVE
      end
      seen[#seen + 1] = node.value
    end)
    -- "world", "!", "Bye" should be visited; "Hello " was removed.
    local found_bang = false
    for _, v in ipairs(seen) do
      if v == "!" then found_bang = true end
    end
    T.ok(found_bang, "sibling after removal is visited")
  end)
end)

-- ── Explicit index return ─────────────────────────────────────────────────────

T.describe("explicit index return", function()
  T.it("returning a number jumps to that index in parent.children", function()
    local tree = make_mdast()
    local para = tree.children[1]
    -- children: [text "Hello ", strong, text "!"]
    -- When we visit index 1 ("Hello "), return 3 to jump past strong.
    local seen_values = {}
    local jumped = false
    visit(tree, function(node, index, parent)
      if node.type == "text" and node.value == "Hello " and parent == para then
        jumped = true
        return 3   -- skip to index 3, bypassing strong
      end
      if node.type == "text" then
        seen_values[#seen_values + 1] = node.value
      end
    end)
    T.ok(jumped, "jump was triggered")
    -- "world" (inside strong) should not have been visited via that path
    -- because we jumped from 1 to 3, skipping strong entirely.
    local found_world = false
    for _, v in ipairs(seen_values) do
      if v == "world" then found_world = true end
    end
    T.ok(not found_world, "strong's children were skipped by index jump")
    -- "!" at index 3 and "Bye" should still be visited
    local found_bang = false
    local found_bye = false
    for _, v in ipairs(seen_values) do
      if v == "!" then found_bang = true end
      if v == "Bye" then found_bye = true end
    end
    T.ok(found_bang, "! was visited")
    T.ok(found_bye, "Bye was visited")
  end)
end)

-- ── Exit visitor ──────────────────────────────────────────────────────────────

T.describe("exit visitor", function()
  T.it("exit visitor is called after children", function()
    local tree = make_mdast()
    local log = {}
    visit(tree, "paragraph",
      function(node) log[#log + 1] = "enter:" .. node.type end,
      function(node) log[#log + 1] = "exit:" .. node.type end
    )
    -- Two paragraphs; each enter fires before exit.
    T.eq(#log, 4)
    T.eq(log[1], "enter:paragraph")
    T.eq(log[2], "exit:paragraph")
    T.eq(log[3], "enter:paragraph")
    T.eq(log[4], "exit:paragraph")
  end)

  T.it("exit can return EXIT to stop traversal", function()
    local tree = make_mdast()
    local exit_count = 0
    visit(tree, "paragraph",
      function() end,
      function()
        exit_count = exit_count + 1
        return visit.EXIT
      end
    )
    T.eq(exit_count, 1)
  end)
end)

-- ── with_parents variant ──────────────────────────────────────────────────────

T.describe("with_parents", function()
  T.it("provides ancestor chain to visitor", function()
    local tree = make_mdast()
    local ancestor_counts = {}
    visit.with_parents(tree, "text", function(node, ancestors)
      ancestor_counts[node.value] = #ancestors
    end)
    -- "Hello " is under root > paragraph, so 2 ancestors
    T.eq(ancestor_counts["Hello "], 2)
    -- "world" is under root > paragraph > strong, so 3 ancestors
    T.eq(ancestor_counts["world"], 3)
    -- "Bye" is under root > paragraph, so 2 ancestors
    T.eq(ancestor_counts["Bye"], 2)
  end)

  T.it("last ancestor is the direct parent", function()
    local tree = make_mdast()
    local parents = {}
    visit.with_parents(tree, "text", function(node, ancestors)
      parents[node.value] = ancestors[#ancestors]
    end)
    -- Direct parent of "world" should be the strong node
    T.ok(parents["world"] ~= nil, "parent found")
    T.eq(parents["world"].type, "strong")
  end)

  T.it("works without type filter", function()
    local tree = make_mdast()
    local root_visits = 0
    visit.with_parents(tree, function(node, ancestors)
      if node.type == "root" then
        root_visits = root_visits + 1
        T.eq(#ancestors, 0)
      end
    end)
    T.eq(root_visits, 1)
  end)
end)

-- ── hast tree ─────────────────────────────────────────────────────────────────

T.describe("hast tree", function()
  T.it("visits element nodes by type", function()
    local tree = make_hast()
    local tags = {}
    visit(tree, "element", function(node)
      tags[#tags + 1] = node.tag
    end)
    T.eq(#tags, 2)
    T.eq(tags[1], "p")
    T.eq(tags[2], "a")
  end)

  T.it("visits text nodes inside hast elements", function()
    local tree = make_hast()
    local values = {}
    visit(tree, "text", function(node)
      values[#values + 1] = node.value
    end)
    T.eq(#values, 2)
    T.eq(values[1], "hello")
    T.eq(values[2], "link")
  end)
end)

-- ── nlcst tree ────────────────────────────────────────────────────────────────

T.describe("nlcst tree", function()
  T.it("visits WordNode nodes", function()
    local tree = make_nlcst()
    local count = 0
    visit(tree, "WordNode", function() count = count + 1 end)
    T.eq(count, 2)
  end)

  T.it("visits TextNode leaves inside nlcst", function()
    local tree = make_nlcst()
    local values = {}
    visit(tree, "TextNode", function(node)
      values[#values + 1] = node.value
    end)
    T.eq(#values, 3)
    T.eq(values[1], "Hi")
    T.eq(values[2], " ")
    T.eq(values[3], "there")
  end)

  T.it("with_parents gives correct depth for nlcst", function()
    local tree = make_nlcst()
    local word_depths = {}
    visit.with_parents(tree, "WordNode", function(node, ancestors)
      word_depths[#word_depths + 1] = #ancestors
    end)
    -- WordNode lives at: RootNode > ParagraphNode > SentenceNode => depth 3
    T.eq(#word_depths, 2)
    T.eq(word_depths[1], 3)
    T.eq(word_depths[2], 3)
  end)
end)
