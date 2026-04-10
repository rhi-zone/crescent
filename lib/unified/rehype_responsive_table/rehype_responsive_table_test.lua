-- lib/unified/rehype_responsive_table/rehype_responsive_table_test.lua
-- Tests for the rehype_responsive_table plugin.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T              = require("lib.test.assert")
local unified        = require("lib.unified")
local responsiveTable = require("lib.unified.rehype_responsive_table")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

local function text(value)
  return { type = "text", value = value }
end

local function root(children)
  return { type = "root", children = children }
end

local function make_proc(opts)
  local p = unified.new()
  p:use(responsiveTable, opts)
  return p
end

local function run(tree, opts)
  local result, err = make_proc(opts):run(tree)
  if not result then error(err) end
  return result
end

-- Depth-first find first node with given tag.
local function find_tag(node, tag)
  if node.type == "element" and node.tag == tag then return node end
  if node.children then
    for _, c in ipairs(node.children) do
      local found = find_tag(c, tag)
      if found then return found end
    end
  end
  return nil
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_responsive_table: basic wrapping", function()
  T.it("table is wrapped in a div.table-wrapper", function()
    local tree = root({ el("table", {}, { el("tr", {}, { el("td", {}, { text("cell") }) }) }) })
    local out  = run(tree)
    -- Root child should now be a div, not a table.
    local wrapper = out.children[1]
    T.eq(wrapper.type, "element")
    T.eq(wrapper.tag, "div")
    T.eq(wrapper.props.class, "table-wrapper")
    T.eq(wrapper.props.style, "overflow-x: auto;")
    -- The table is the wrapper's child.
    T.eq(wrapper.children[1].tag, "table")
  end)

  T.it("wrapper contains exactly the original table node", function()
    local tbl  = el("table", {}, {})
    local tree = root({ tbl })
    local out  = run(tree)
    T.eq(out.children[1].children[1].tag, "table")
  end)

  T.it("non-table elements are unchanged", function()
    local tree = root({ el("p", {}, { text("hello") }), el("h1", {}, { text("title") }) })
    local out  = run(tree)
    T.eq(#out.children, 2)
    T.eq(out.children[1].tag, "p")
    T.eq(out.children[2].tag, "h1")
  end)
end)

T.describe("rehype_responsive_table: options", function()
  T.it("opts.class changes the wrapper class", function()
    local tree = root({ el("table", {}, {}) })
    local out  = run(tree, { class = "scroll-box" })
    T.eq(out.children[1].props.class, "scroll-box")
  end)

  T.it("opts.style changes the wrapper style", function()
    local tree = root({ el("table", {}, {}) })
    local out  = run(tree, { style = "overflow: scroll;" })
    T.eq(out.children[1].props.style, "overflow: scroll;")
  end)

  T.it("opts.tag changes the wrapper element tag", function()
    local tree = root({ el("table", {}, {}) })
    local out  = run(tree, { tag = "section" })
    T.eq(out.children[1].tag, "section")
  end)
end)

T.describe("rehype_responsive_table: nested tables", function()
  T.it("table nested inside a div is also wrapped", function()
    -- <div><table>...</table></div>
    local tree = root({
      el("div", {}, {
        el("table", {}, { el("tr", {}, {}) }),
      }),
    })
    local out = run(tree)
    -- The outer div should still be there.
    local outer = out.children[1]
    T.eq(outer.tag, "div")
    -- Inside the outer div, the table should now be wrapped.
    local wrapper = outer.children[1]
    T.eq(wrapper.tag, "div")
    T.eq(wrapper.props.class, "table-wrapper")
    T.eq(wrapper.children[1].tag, "table")
  end)

  T.it("multiple tables at root level are each wrapped", function()
    local tree = root({ el("table", {}, {}), el("table", {}, {}) })
    local out  = run(tree)
    T.eq(#out.children, 2)
    T.eq(out.children[1].tag, "div")
    T.eq(out.children[2].tag, "div")
    T.eq(out.children[1].children[1].tag, "table")
    T.eq(out.children[2].children[1].tag, "table")
  end)
end)
