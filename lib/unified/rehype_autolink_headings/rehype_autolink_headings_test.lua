-- lib/rehype_autolink_headings/rehype_autolink_headings_test.lua
-- Tests for lib/rehype_autolink_headings.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T                      = require("lib.test.assert")
local unified                = require("lib.unified")
local rehypeSlug             = require("lib.unified.rehype_slug")
local rehypeAutolinkHeadings = require("lib.unified.rehype_autolink_headings")

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

-- Build a processor with slug + autolink, optionally with autolink opts.
local function make_processor(opts)
  return unified.new()
    :use(rehypeSlug)
    :use(rehypeAutolinkHeadings, opts)
end

local function run(tree, opts)
  local result, err = make_processor(opts):run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_autolink_headings", function()

  T.describe("wrap mode (default)", function()

    T.it("wraps heading children in an anchor", function()
      local tree = root({ el("h1", {}, { text("Hello") }) })
      local out  = run(tree)
      local h1   = out.children[1]
      -- h1 should have one child: an <a> element
      T.eq(#h1.children, 1)
      local anchor = h1.children[1]
      T.eq(anchor.type, "element")
      T.eq(anchor.tag, "a")
      T.eq(anchor.props.href, "#hello")
      -- The anchor's child should be the original text node
      T.eq(#anchor.children, 1)
      T.eq(anchor.children[1].type, "text")
      T.eq(anchor.children[1].value, "Hello")
    end)

    T.it("wraps multiple children", function()
      local tree = root({
        el("h2", {}, { text("Hello "), el("strong", {}, { text("World") }) }),
      })
      local out    = run(tree)
      local h2     = out.children[1]
      local anchor = h2.children[1]
      T.eq(anchor.tag, "a")
      T.eq(anchor.props.href, "#hello-world")
      T.eq(#anchor.children, 2)
    end)

    T.it("is the default when behavior is not specified", function()
      local tree = root({ el("h1", {}, { text("Test") }) })
      local out  = run(tree, {})
      local h1   = out.children[1]
      T.eq(h1.children[1].tag, "a")
    end)

  end)

  T.describe("prepend mode", function()

    T.it("prepends an anchor before children", function()
      local tree = root({ el("h1", {}, { text("Hello") }) })
      local out  = run(tree, { behavior = "prepend" })
      local h1   = out.children[1]
      -- Two children: anchor first, then original text
      T.eq(#h1.children, 2)
      local anchor = h1.children[1]
      T.eq(anchor.tag, "a")
      T.eq(anchor.props.href, "#hello")
      T.eq(anchor.props["aria-hidden"], "true")
      -- Default content is pilcrow
      T.eq(anchor.children[1].type, "text")
      T.eq(anchor.children[1].value, "\xC2\xB6")
      -- Original child preserved
      T.eq(h1.children[2].type, "text")
      T.eq(h1.children[2].value, "Hello")
    end)

    T.it("uses custom string content", function()
      local tree = root({ el("h1", {}, { text("Hello") }) })
      local out  = run(tree, { behavior = "prepend", content = "#" })
      local h1   = out.children[1]
      local anchor = h1.children[1]
      T.eq(anchor.children[1].value, "#")
    end)

    T.it("uses custom hast node content", function()
      local icon = el("span", { ["aria-hidden"] = "true" }, { text("§") })
      local tree = root({ el("h1", {}, { text("Hello") }) })
      local out  = run(tree, { behavior = "prepend", content = icon })
      local h1   = out.children[1]
      local anchor = h1.children[1]
      T.eq(anchor.children[1].tag, "span")
    end)

  end)

  T.describe("append mode", function()

    T.it("appends an anchor after children", function()
      local tree = root({ el("h1", {}, { text("Hello") }) })
      local out  = run(tree, { behavior = "append" })
      local h1   = out.children[1]
      -- Two children: original text, then anchor
      T.eq(#h1.children, 2)
      local anchor = h1.children[2]
      T.eq(anchor.tag, "a")
      T.eq(anchor.props.href, "#hello")
      T.eq(anchor.props["aria-hidden"], "true")
      T.eq(anchor.children[1].value, "\xC2\xB6")
      -- Original child preserved
      T.eq(h1.children[1].type, "text")
      T.eq(h1.children[1].value, "Hello")
    end)

  end)

  T.describe("headings without id", function()

    T.it("skips headings that have no id property", function()
      -- Build tree without using rehype_slug so no id is set.
      local tree = root({ el("h1", {}, { text("No ID") }) })
      local p = unified.new():use(rehypeAutolinkHeadings)
      local out, err = p:run(tree)
      if not out then error(err) end
      local h1 = out.children[1]
      -- Children should be unchanged (one text node, no anchor wrapping)
      T.eq(#h1.children, 1)
      T.eq(h1.children[1].type, "text")
      T.eq(h1.children[1].value, "No ID")
    end)

  end)

  T.describe("non-heading elements", function()

    T.it("does not touch paragraphs", function()
      local tree = root({ el("p", {}, { text("plain") }) })
      local out  = run(tree)
      local p    = out.children[1]
      T.eq(p.tag, "p")
      T.eq(#p.children, 1)
      T.eq(p.children[1].type, "text")
    end)

  end)

end)
